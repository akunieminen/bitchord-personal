# PR #932 for the personal fork: carry it, but only with fixes

## 1. Verdict: yes, with fixes

**Don't take it as it stands.** It breaks even with the setting off, which is the default. In the fallback at `PlaybackService.kt:4578-4579`, `replaceMediaItem` with the marked URI resets the position to 0 before `seekTo(currentIndex, activePlayer.currentPosition)` reads it. So every quality upgrade restarts the song at 0:00. v1.8.1 used `now.position`, read before the replace.

With the setting on, there are four more serious bugs (ranked below): silence plus a wiped queue, a revert being undone, music stopping after you press play, and queue edits being lost.

**It's worth carrying once fixed.** It's the only thing that removes the cut where prefetch can't help: the first track of a session, cold taps, skip-arounds, and every HLS/DASH addon track. The handover plumbing is sound: listener rebind, session owner and audio focus, filter and loudness roles, and the shared audio session ID. It also fixes an existing v1.8.1 bug: after a version swap, CrossfadeController's listener stayed on the old player.

With the fixes it adds about 90 lines, all in `PlaybackService.kt`.

**Checked so far:** the three patches below apply to the exact pr-932 and v1.8.1 file versions. I compiled them with kotlinc 2.3.20 against the app's prodRelease classes and the Media3 1.11 jars, twice (patch 1 alone, and all three), with 0 errors. I copied everything into `/tmp` and did not touch the fork's working tree or the running build. Nothing has been run on a device, and there's no unit test because this code needs real ExoPlayer instances.

## 2. Issues, worst first

Line numbers are on pr-932.

| # | Severity | Issue | Fix |
|---|---|---|---|
| 1 | blocker | Fallback reads the position after the replace, so every upgrade restarts at 0:00 (4578-4579). Default path. | `seekTo(currentIndex, now.position)` |
| 2 | major | Upgrade swap and version swap share `spare`; neither checks the other (2045 / 4569-4573). Whichever loses runs `stop()/clearMediaItems()` on what is now the session player (2128/2222/4729-4730): silence and an empty queue. | Upgrade side: shelve while `versionSwapJob` is active. Version side: defer, then retry once `sourceSwapActive` clears (not dropped, so your tap still counts). |
| 3 | major | The wait loops only re-check player, index and mediaId (4608-4613, 4678-4683). Revert-to-original keeps the same mediaId and index, so the upgrade is adopted anyway: the track is pinned to the original but plays the upgrade, and the revert button is hidden. A `recoverFrom` that forgets the parked stream gets adopted with nothing behind it (the "two files, one key" cache case the guard at 4874 exists for). | `stillWanted()` = player, index, `swapPointFor(mediaId)?.uri == now.uri` (covers pin and marker), `forcedStream != null`. Checked every tick and before both adopts. |
| 4 | major | The queue copied at 4587 is adopted up to ~6 s later. AutoPlay appends (3003), Play next, remove/move and repeat changes made in between are lost; AutoPlay only refills at STATE_ENDED, after a gap. | `adopt()` copies the live items before and after the current one onto the standby, plus repeat/shuffle, in the same main-thread slice. |
| 5 | major (short window) | Paused swap: `wasPlaying` is read once (4590). Pressing play while it buffers → the paused standby is adopted → the music stops (4717-4723). | Paused branch: `if (!stillWanted() \|\| activePlayer.playWhenReady) return false`. |
| 6 | major (size not measured) | The re-sync seek's resume time R is never compensated (4645-4655). The standby enters the 300 ms fade R ms behind, heard as a flam or echo. Only drift over 300 ms aborts (4686). | Patch 2: wait until the standby's position moves, measure lag, seek ahead by it once, log it. The 15 ms threshold is a tuning knob. |
| 7 | minor | Equal-power gains on two aligned copies of the same master add in amplitude: about +1.5 dB at mid-fade, and can clip on loud masters (4695-4701). | Patch 2: linear gains (`progress` / `1 - progress`). |
| 8 | minor | During a call (playback suppressed, `playWhenReady` still true) the standby has no focus handling and fades in over the call. | Require `playbackSuppressionReason == NONE` in `canCrossfade` and `stillWanted()`. |
| 9 | minor | Aborts (skip, seek, cancel) don't shelve the upgrade, so a proved and cached upgrade is thrown away (4612, 4682, 4688, finally). | Outer finally: shelve unless `forcedStream` was dropped. |
| 10 | minor | After a same-track adopt, `currentAudioInputFormat = null` (2426) and it is never set again, so output telemetry still reports Opus. | `= incoming.audioFormat; applyOutputRoute()` |
| 11 | minor | Upgrade during an Advanced Automix tempo ease-back: the standby runs at your normal speed, then the tempo snaps after adopt (4598). | Shelve while `playbackParameters.speed != AppSettings.playbackSpeed`; it is re-offered when the ease finishes. |

**Not fixed, on purpose:**
- **Late Automix starts.** While the swap runs, the crossfade can't arm (that is how the PR keeps them apart), so a blend due in that window can start late and lose its Advanced Automix beat alignment. Usually well under 2 s; worst case about 6 s. A real fix needs a "time until arm" API on CrossfadeController. A cheap option is cutting the 5 s ready timeout at 4612 (`5_000L`) to about 1.5 s.
- **Different master that passes the length check.** You hear a smear plus a jump, the same jump as v1.8.1's cut. Lower the length tolerance setting if you hear it (section 3).

**Where the review was wrong:**
- No Up-next re-shuffle: the app's shuffle is QueueShuffle, and ExoPlayer's own shuffle stays off.
- No backward jump when the standby takes over: the outgoing gain is already 0 and nothing seeks.
- A pinned manifest stalls and then plays (`replayAsManifest`); it doesn't fail outright.
- `SourceResolver.kt` does *not* import StreamContainer. Patch 3 adds the import and uses `bestAcross`'s existing `accept` parameter, so a non-manifest runner-up can still win.

### Patch 1: correctness (fixes 1-5 and 8-11). `/tmp/pr932-fork-fixes/0001-fork-fix-PR-932-correctness.patch`
```diff
--- a/app/src/main/java/com/music/bitchord/playback/PlaybackService.kt
+++ b/app/src/main/java/com/music/bitchord/playback/PlaybackService.kt
@@ -2046,6 +2046,18 @@ class PlaybackService : MediaLibraryService() {
             TrackLog.d("BitChord", "version swap deferred: Automix is mid-transition", about = currentItem.mediaId)
             return
         }
+        // Nor while a quality upgrade owns the standby. It lets go within ~1-2s, so run
+        // this right after rather than dropping a switch the listener asked for.
+        if (sourceSwapActive) {
+            TrackLog.d("BitChord", "version swap deferred: a quality upgrade owns the standby", about = currentItem.mediaId)
+            scope.launch {
+                while (sourceSwapActive) delay(50)
+                if (player?.currentMediaItem?.mediaId == currentItem.mediaId) {
+                    smoothSwapCurrentTrackVersion(targetMediaItem, onSwapCommitted)
+                }
+            }
+            return
+        }
 
         val sourceSong = currentItem.toSong()
         val targetSong = targetMediaItem.toSong()
@@ -2423,7 +2435,9 @@ class PlaybackService : MediaLibraryService() {
         refreshCustomLayouts()
 
         if (isSameTrack) {
-            currentAudioInputFormat = null
+            // Its format event fired before formatListener moved here; read it off the player.
+            currentAudioInputFormat = incoming.audioFormat
+            applyOutputRoute()
             activeTrackIsDolbyAtmos = NerdStats.declaredFormat(incoming.currentMediaItem?.mediaId)?.isDolbyAtmos == true
             applySpatialAudioEnabled()
             publishNerdStats()
@@ -4569,14 +4583,27 @@ class PlaybackService : MediaLibraryService() {
         val canCrossfade = standbyPlayer != null &&
             AppSettings.sourceCrossfadeEnabled.value &&
             (activePlayer.isPlaying || activePlayer.playbackState == Player.STATE_READY) &&
+            // A call or other transient focus loss: the standby has no focus handling and would be heard over it.
+            activePlayer.playbackSuppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_NONE &&
             crossfade?.isTransitioning() != true &&
             !ListenTogether.state.value.inParty
 
+        // Busy rather than unable: a version swap owns the standby, or an Advanced Automix
+        // tempo ease-back is still running. Neither share it nor hard-cut under it; the
+        // next progress tick re-offers the shelved stream.
+        if (canCrossfade && (versionSwapJob?.isActive == true ||
+                abs(activePlayer.playbackParameters.speed - AppSettings.playbackSpeed.value) > 0.001f)
+        ) {
+            QualityUpgrade.shelve(mediaId, stream)
+            return false
+        }
+
         if (!canCrossfade || standbyPlayer == null) {
             swappingMediaId = mediaId
             swapCutAt = SystemClock.elapsedRealtime()
             activePlayer.replaceMediaItem(currentIndex, upgradedItem)
-            activePlayer.seekTo(currentIndex, activePlayer.currentPosition)
+            // now.position, as v1.8.1: after a replace with a new URI Media3 reports 0.
+            activePlayer.seekTo(currentIndex, now.position)
             activePlayer.prepare()
             return true
         }
@@ -4602,15 +4629,39 @@ class PlaybackService : MediaLibraryService() {
             standbyPlayer.playWhenReady = false
             standbyPlayer.prepare()
 
+            // Everything swapIn checked once is re-checked here, because this suspends:
+            // a skip, a revert (pin + new URI, same mediaId and index), a recovery that
+            // dropped the parked stream, or a call can all land in between.
+            // swapPointFor covers the player, current item, pin and marker.
+            fun stillWanted() = player === activePlayer &&
+                activePlayer.currentMediaItemIndex == currentIndex &&
+                swapPointFor(mediaId)?.uri == now.uri &&
+                QualityUpgrade.forcedStream(Uri.parse(upgradedUri)) != null &&
+                activePlayer.playbackSuppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_NONE
+
+            // Main thread, no suspension until adoptPlayerForVersionSwap: queue edits made
+            // while this buffered (AutoPlay append, Play next, remove/move) are carried
+            // over instead of being dropped with the outgoing player.
+            fun adopt() {
+                val live = (0 until activePlayer.mediaItemCount).map(activePlayer::getMediaItemAt)
+                val tail = live.subList(currentIndex + 1, live.size)
+                if (tail != newItems.subList(currentIndex + 1, newItems.size)) {
+                    standbyPlayer.replaceMediaItems(currentIndex + 1, standbyPlayer.mediaItemCount, tail)
+                }
+                val head = live.subList(0, currentIndex)
+                if (head != newItems.subList(0, currentIndex)) {
+                    standbyPlayer.replaceMediaItems(0, currentIndex, head)
+                }
+                standbyPlayer.repeatMode = activePlayer.repeatMode
+                standbyPlayer.shuffleModeEnabled = activePlayer.shuffleModeEnabled
+                adoptPlayerForVersionSwap(outgoing = activePlayer, incoming = standbyPlayer, isSameTrack = true)
+                adopted = true
+            }
+
             val timeoutAt = SystemClock.elapsedRealtime() + 5_000L
             var isReady = false
             while (coroutineContext.isActive && SystemClock.elapsedRealtime() < timeoutAt) {
-                if (player !== activePlayer ||
-                    activePlayer.currentMediaItemIndex != currentIndex ||
-                    activePlayer.currentMediaItem?.mediaId != mediaId
-                ) {
-                    return false
-                }
+                if (!stillWanted()) return false
                 if (crossfade?.isTransitioning() == true) {
                     QualityUpgrade.shelve(mediaId, stream)
                     TrackLog.d("BitChord", "upgrade for $mediaId shelved: a crossfade started")
@@ -4675,12 +4726,7 @@ class PlaybackService : MediaLibraryService() {
                         val elapsed = SystemClock.elapsedRealtime() - fadeStart
                         val progress = (elapsed.toFloat() / swapCrossfadeMs).coerceIn(0f, 1f)
 
-                        if (player !== activePlayer ||
-                            activePlayer.currentMediaItemIndex != currentIndex ||
-                            activePlayer.currentMediaItem?.mediaId != mediaId
-                        ) {
-                            return false
-                        }
+                        if (!stillWanted()) return false
 
                         // Check for user seeking / scrubbing during the crossfade
                         if (abs(activePlayer.currentPosition - standbyPlayer.currentPosition) > 300L) {
@@ -4704,28 +4750,26 @@ class PlaybackService : MediaLibraryService() {
                         delay(16)
                     }
 
-                    adoptPlayerForVersionSwap(
-                        outgoing = activePlayer,
-                        incoming = standbyPlayer,
-                        isSameTrack = true,
-                    )
-                    adopted = true
+                    adopt()
                 } finally {
                     loudnessA.setBlendTrim(1f)
                     loudnessB.setBlendTrim(1f)
                 }
             } else {
+                // Play pressed while this buffered: wasPlaying is stale, and adopting the
+                // paused standby would stop the music the listener just started.
+                if (!stillWanted() || activePlayer.playWhenReady) return false
                 standbyPlayer.volume = 1f
-                adoptPlayerForVersionSwap(
-                    outgoing = activePlayer,
-                    incoming = standbyPlayer,
-                    isSameTrack = true,
-                )
-                adopted = true
+                adopt()
             }
             return true
         } finally {
             if (!adopted) {
+                // Proved and cached: keep it for the re-offer (skip, seek, abort), unless a
+                // recovery dropped the parked stream, which must stay dropped.
+                if (QualityUpgrade.forcedStream(Uri.parse(upgradedUri)) != null) {
+                    QualityUpgrade.shelve(mediaId, stream)
+                }
                 standbyPlayer.stop()
                 standbyPlayer.clearMediaItems()
                 standbyPlayer.volume = 1f
```

### Patch 2: audio polish (fixes 6 and 7). `/tmp/pr932-fork-fixes/0002-fork-PR-932-audio-polish.patch`
Apply after patch 1.
```diff
@@ -4704,6 +4704,26 @@ class PlaybackService : MediaLibraryService() {
                     QualityUpgrade.shelve(mediaId, stream)
                     return false
                 }
+                // The resync seek resumes R ms late while the active player keeps going, so the
+                // standby would enter the fade R ms behind (a flam/echo). Measure R once its audio
+                // is moving, seek ahead by it once, and fade only when that audio is moving too.
+                // ponytail: assumes R repeats seek to seek; expect ±10-20ms left. The log is the knob.
+                suspend fun awaitMoving() {
+                    val from = standbyPlayer.currentPosition
+                    val by = SystemClock.elapsedRealtime() + 300L
+                    while (coroutineContext.isActive && standbyPlayer.currentPosition == from &&
+                        SystemClock.elapsedRealtime() < by
+                    ) {
+                        delay(5)
+                    }
+                }
+                awaitMoving()
+                val lag = activePlayer.currentPosition - standbyPlayer.currentPosition
+                TrackLog.d("BitChord", "upgrade crossfade: standby ${lag}ms behind before compensation", about = mediaId)
+                if (lag in 15L until 300L) {
+                    standbyPlayer.seekTo(currentIndex, activePlayer.currentPosition + lag)
+                    awaitMoving()
+                }
             } else {
@@ -4738,13 +4758,10 @@ class PlaybackService : MediaLibraryService() {
-                        val inGain = sin(progress * (PI / 2.0)).toFloat()
-                        val outGain = cos(progress * (PI / 2.0)).toFloat()
-                        standbyPlayer.volume = inGain
-                        activePlayer.volume = outGain
-                        val swapTrim = 1f / sqrt((inGain + outGain).coerceAtLeast(1f))
-                        loudnessA.setBlendTrim(swapTrim)
-                        loudnessB.setBlendTrim(swapTrim)
+                        // Two aligned copies of one master add in amplitude, so gains that sum
+                        // to 1 keep the level flat; equal-power swells ~+1.5dB mid-fade here.
+                        standbyPlayer.volume = progress
+                        activePlayer.volume = 1f - progress
```
Patch 2 depends on how ExoPlayer reports position right after a seek, which I couldn't check without a device. Watch the `standby Xms behind` log. If it does no good, drop the patch; patch 1 doesn't depend on it.

### Patch 3: manifest guard for your ADDON prefetch commit. `/tmp/pr932-fork-fixes/0003-fork-no-manifest-pins-from-prefetch.patch`
This file is the same in v1.8.1 and pr-932, so the patch applies to either.
```diff
--- a/app/src/main/java/com/music/bitchord/data/sources/SourceResolver.kt
+++ b/app/src/main/java/com/music/bitchord/data/sources/SourceResolver.kt
@@ -7,6 +7,7 @@ import com.music.bitchord.data.model.Song
 import com.music.bitchord.data.settings.AudioQuality
 import com.music.bitchord.data.settings.DownloadQuality
+import com.music.bitchord.playback.StreamContainer
 import kotlinx.coroutines.CancellationException
@@ -326,7 +327,11 @@ object SourceResolver {
         if (quick.isEmpty()) return null
-        val (source, stream) = bestAcross(quick, target, requestForNow()) ?: return null
+        // No manifests: pinned here one reaches the queued item's progressive source and
+        // fails at 0ms. Unpinned, it takes the start-on-YouTube-then-upgrade path.
+        val (source, stream) = bestAcross(quick, target, requestForNow()) { _, s ->
+            !StreamContainer.isManifest(s.url)
+        } ?: return null
```

## 3. How it fits with the prefetch patch and Crossfade/Automix

**Prefetch.** The two don't touch the same files. For a plain-FLAC addon, prefetch pins the *next* track to the addon, so most cuts go away without #932. Upgrades still happen in these cases, and #932 smooths them:
- The first or cold-tapped track.
- Anything past the immediate next track, since only `videoIds.firstOrNull()` gets pinned (`AudioCache.kt:1262`). That covers double skips and queue jumps.
- Skipping before the addon lookup returns.
- A pinned stream that isn't lossless.
- Manual "Upgrade quality".
- Every HLS/DASH track.

If your addon serves manifests (the reference addon serves HLS at `/dash/{id}`), patch 3 is required. Without it, prefetch pins the manifest, the next track fails at 0 ms and stalls while it re-prepares, and any Crossfade/Automix into it falls back to a plain cut. To check which case you're in, look in logcat for `as a manifest; starting on YouTube`, `warmed: … from <addon>` and `upgraded to`.

**Crossfade / Automix / Advanced Automix.** The guards hold:
- An upgrade never runs during an arm, fade or bail.
- There's a 5 s grace after each transition.
- `sourceSwapActive` blocks arming while the swap runs.
- The CrossfadeController state after the swap is consistent.

What's left: the late-start limitation above (not fixed), and the tempo ease-back, which fix 11 covers. In a Listen Together party it falls back to the hard swap, now at the right position.

**Settings:**
- **Seamless source crossfade:** turn it on, but only on a build with patch 1. Without patch 1, upgrades restart the song even with it off.
- **Crossfade / Automix / Advanced Automix:** leave as you like them; nothing needs changing.
- **Sources → Track length tolerance (default 3 s):** lower to 1-2 s only if you hear doubled bars at a swap (a different master that passed the check). The cost is that more tracks stay on YouTube.
- Smart version alignment and prefer-music-only don't affect upgrades. Video items never get upgraded.

**Device checks (logcat):**
1. Setting off: an upgrade at around 1:10 keeps playing from there.
2. Tap Revert while "Upgrading quality" is showing: it stays on YouTube.
3. Pause, then press play just as an upgrade lands: the music keeps playing.
4. Tap "Play next" during an upgrade: the item stays in the queue.
5. Toggle audio/video during an upgrade: you see `version swap deferred`, then the switch happens.

## 4. Carrying it in the fork

Do this after the running build finishes:
```sh
git switch -c fork v1.8.1
#   commit 1: SourceKind.ADDON worthPrefetching = true  +  git am 0003 (or squash it in)
git cherry-pick -x dc82057 9c1dbb2 b8c4f2d          # PR #932, unmodified
git am /tmp/pr932-fork-fixes/0001-*.patch /tmp/pr932-fork-fixes/0002-*.patch   # separate fork commits
git config rerere.enabled true
```
- **Never edit the PR commits.** If upstream merges #932 unchanged, `git rebase` recognises identical patches and drops the three cherry-picks by itself; the `-x` note in the message doesn't affect that. If upstream squashes or modifies it, drop the three yourself and run `git range-diff` to see which parts of 0001/0002 still apply.
- **Rebase onto upstream's next release branch, not `main`.** Upstream works on version branches: #932's base is branch `v1.8.1` (= 7d956f2), which is 59 commits ahead of `main`. After each sync, run `gh pr view 932 -R kushagrasinghx/BitChord --json state,mergeCommit`. The PR is currently OPEN, BLOCKED, review required, with no comments.
- **Expect conflicts in three places:** the swapIn call-site hunk, the `adoptPlayerForVersionSwap` signature, and the KDoc that the PR placed above `seamlessSwapToStream`. Take upstream's version and re-apply the fork hunk.
- **Optional:** add a one-line fork commit that flips the `sourceCrossfadeEnabled` default to true. If upstream later renames the setting key, you get a visible conflict instead of the feature silently switching off.

Files are in `/tmp/pr932-fork-fixes/`, so copy them somewhere permanent before `/tmp` gets cleared:
- `0001-fork-fix-PR-932-correctness.patch`
- `0002-fork-PR-932-audio-polish.patch`
- `0003-fork-no-manifest-pins-from-prefetch.patch`

The scratch repo they came from is `/tmp/pr932scratch`.
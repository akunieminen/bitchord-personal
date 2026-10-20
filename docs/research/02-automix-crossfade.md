# Addendum: Crossfade and Automix with the prefetched hi-res addon stream

Line numbers are from the read-only clone (main `edc1e6f3`, paths under `app/src/main/java/com/music/bitchord/`). The fork at `/home/aku/Documents/bitchord-work/fork` (v1.8.1, `7d956f2`) has identical `CrossfadeController.kt`, `StreamChoice.kt`, `SourceResolver.kt` and `QualityUpgrade.kt`. Its `AudioCache.kt` is about +307 lines in `prefetchQueue`, and its `PlaybackService.kt` is +6 at the resolver and +28/+45 at the upgrade code.

"Basic patch" here means the other run's one-liner, `SourceKind.ADDON.worthPrefetching = true` (research-plan.md §2).

## 1. With only the basic patch: does the incoming track play hi-res from its first sample?

**Usually yes, and no CrossfadeController change is needed for it.** This was confirmed by reading the code, not on a device.

How it works:
- Both players share one media source factory: `PlaybackService.kt:1655-1659` and `:3171`.
- The standby gets unchanged copies of the queue items. It starts N+1 at the cue by start position and prepares silently (`CrossfadeController.kt:1226`, `:1258`, `:1270-1271`).
- Every handoff runs `adoptPlayer` → `onTrackBecameCurrent` → `prefetchAround` (`PlaybackService.kt:3214-3219`, `:3518`). That pins N+1 straight away (`AudioCache.kt:969-973`). Only the byte fetch waits 8 s (`:983`).
- The first open of N+1 hits the pin before any race (`PlaybackService.kt:1498-1547`).
- A pin with `isLossless == true` is never marked for upgrade (`:1532-1535`), so `swapIn` has nothing to do.
- A cut *during* a blend is already impossible. `swapIn` polls while a blend runs (`:4553-4559`), waits until 5 s after it ends (`:4577-4583`, `UPGRADE_AFTER_CROSSFADE_MS` at `:8793`), and shelves the swap if a blend is still running (`:4585-4595`). What can still happen is the hard cut 5 s or more after the fade (`:4646-4659`).

Cases where it still falls back or cuts:

| # | Case | What you hear | Where |
|---|---|---|---|
| 1 | **N+1 is opened before its pin exists.** Media3 opens the next item as soon as the current one is fully buffered (8 MB cap, `PlaybackService.kt:8715`, `:6093-6102`; Media3 1.11 bytecode, read in the earlier pass). That is seconds into an Opus, lossy or short N, and can be on the standby mid-blend, before the handoff that pins N+1. A hi-res FLAC N is only fully buffered in roughly its last 10-40 s, so this mostly happens after the addon missed N. | Race. The pre-warmed YouTube URL (`AudioCache.kt:988-999`) wins, so the mix starts on Opus and a pending upgrade is queued (`PlaybackService.kt:5277-5282`). The cut comes 5 s or more after landing. Then the late prefetch overwrites the YouTube pin (`AudioCache.kt:973`, `StreamChoice.kt:100`), which can splice two files under `#alt`. | as cited |
| 2 | Re-runs: pause/resume (`PlaybackService.kt:881`, `:5978-5983`, `AudioCache.kt:1022-1026`), or a queue edit in the next two slots (`:904-907`) | A new lookup overwrites the pin, with the same splice risk as row 1 | `AudioCache.kt:973` |
| 3 | The pin is older than 15 min when N+1 opens. The list dedupe (`:904`) never re-pins it. | Race (row 1) | `StreamChoice.kt:178` |
| 4 | The bridge states no codec, so `isLossless` is null | Upgrade hunt, and a cut after the fade if a better copy turns up | `PlaybackService.kt:1532-1543`, `AddonSource.kt:380-406` |
| 5 | The bridge returns a DASH/HLS manifest. The pinned branch has no manifest guard; only the race does (`:5212`). | The standby errors, the 12 s timeout fires and logs `bail from ARMING`, and you get a plain transition | `CrossfadeController.kt:1389-1395`, `:2760` |
| 6 | A YouTube Opus copy is already cached under `#alt`. These are kept origins (`AudioCache.kt:452-471`, `:731-757`), and a cache hit never reaches the resolver (`:803-841`). | A complete copy plays Opus. Under crossfade there is no cut, because `adoptCachedTrack` needs a format the standby never reports (`PlaybackService.kt:3357-3363`, `:4392-4396`). A partial copy gets Opus and FLAC spliced together. | as cited |
| 7 | The Automix analysis fallback pull for an unpinned N+1, which only runs when its Opus head fails | Race (row 1) | `AudioCache.kt:1375-1392` |
| 8 | Not substitutable: addon not ranked above YouTube, a video item, an "original version" pin, or a music-only video next | Plain YouTube, as today | `SourceResolver.kt:324-328`, `:736-737`; `AudioCache.kt:948`; `PlaybackService.kt:5950-5974` |
| 9 | A cold or slow bridge at an Automix cue: header plus a FLAC seek over the network inside the 4 s arm lead | The fade starts late and is squeezed by the end-driven progress, or it bails | `CrossfadeController.kt:1414-1416`, `:1575-1580`, `:2716` |
| 10 | Rows picked from the Addons search (`source://`) | Already addon-only, with no YouTube start and no cut (`PlaybackService.kt:1362-1400`). They are never analysed (`TrackAnalyzer.kt:819-847`), so you get a plain fade. | — |

## 2. The minimal extra change

**No change** is needed in `CrossfadeController.kt`, `TrackAnalyzer.kt`, `AutomixAnalysisSource`, `TransitionFilterProcessor.kt`, `DynamicLruCacheEvictor.kt`, `PlayerConnection.kt`, `AppSettings.kt` or `SettingsSheet.kt`.

The transition filter's 16-bit-only `onConfigure` (`TransitionFilterProcessor.kt:233-241`) is not on the path that matters. The filter runs in float through `PrecisionAudioSink` (`audio/PrecisionAudioSink.kt:144-151`, `audio/DspChain.kt:44-49`), so a 24-bit incoming track still gets bass swaps and filter sweeps.

**Required:** one file, `playback/AudioCache.kt`. It covers rows 1, 2, 3 (the cases where a re-pin would have refreshed it), 5 and 6. It replaces the research plan's "extra B" (same lines, so don't apply both). It sits alongside the SourceKind one-liner.

What it changes:
1. The first pin wins, and an existing pin is reused and re-stamped.
2. The track after the next one is pinned too (URL only), so the standby's early preload finds a pin. Steady-state lookups stay at one per track.
3. No pin is made over a cached YouTube `#alt` copy.
4. No pin is made for a manifest.

```diff
--- a/app/src/main/java/com/music/bitchord/playback/AudioCache.kt
+++ b/app/src/main/java/com/music/bitchord/playback/AudioCache.kt
@@ -966,18 +966,11 @@
                 // leaves nothing pinned, and this falls through to the same
                 // URL-only warm-up it did before — YouTube resolves the track at
                 // playback time as usual.
-                val warmed = if (substitutable && target != null && !pinnedToYouTube) {
-                    runCatching { SourceResolver.prefetchSubstitute(target) }
-                        .onFailure { TrackLog.d(TAG, "warm-up substitute failed for $next: ${it.message}", about = next) }
-                        .getOrNull()
-                        ?.also { StreamChoice.remember(next, it, substituted = true) }
-                } else {
-                    null
-                }
+                val warmed = substitutable && target != null && !pinnedToYouTube && pinSubstitute(next, target)
                 // Safe to fill for the same reason in both cases: either nothing
                 // outranks YouTube and read-ahead is the only writer, or a
                 // source has been pinned and every writer now resolves to it.
-                val cacheBytes = (!substitutable || warmed != null) && !pinnedToYouTube
+                val cacheBytes = (!substitutable || warmed) && !pinnedToYouTube
                 if (cacheBytes) {
                     launch(TrackLog.about(next)) {
                         delay(PREFETCH_DELAY_MS)
@@ -985,6 +978,19 @@
                         fetchWhole(next)
                     }
                 }
+                // ponytail: the track after next is pinned too, URL only. Media3
+                // opens a player's next item as soon as its current one is fully
+                // buffered — seconds into an Opus or short track, and on a
+                // crossfade's standby before the handoff that brings this call
+                // round for it — and an unpinned open races to YouTube and books
+                // an upgrade cut. Same lookups per track as before (the head
+                // reuses this pin); a skip past it wastes one.
+                videoIds.getOrNull(1)?.let { after ->
+                    val afterTarget = upcoming.firstOrNull { it.mediaId == after }?.target
+                    if (substitutable && afterTarget != null && !OriginalVersion.isPinned(after)) {
+                        pinSubstitute(after, afterTarget)
+                    }
+                }
                 launch {
                     delay(PREFETCH_DELAY_MS)
                     for (id in videoIds.take(QUEUE_LOOKAHEAD + 1).let { if (cacheBytes) it.drop(1) else it }) {
@@ -992,7 +998,7 @@
                         // for a YouTube URL: nothing will ask for one, and
                         // minting it spends a client walk to fill a cache entry
                         // that is never read.
-                        if (id == next && warmed != null) continue
+                        if (id == next && warmed) continue
                         runCatching { StreamResolver.resolve(id) }
                             .onFailure { TrackLog.d(TAG, "queue warm-up skipped $id: ${it.message}", about = id) }
                         delay(QUEUE_RESOLVE_STAGGER_MS)
@@ -1003,6 +1009,48 @@
     }
 
     /**
+     * Pins a quick source's copy of [id] in [StreamChoice], and says whether
+     * [id] is now held by a substitute.
+     *
+     * ponytail: the first pin wins. A player may already be filling `#alt`
+     * from the stream it was handed, and swapping the pin under it splices two
+     * files — what [StreamChoice] exists to stop. Check-then-put, not atomic;
+     * give StreamChoice a putIfAbsent if a flip ever shows in the log.
+     */
+    private suspend fun pinSubstitute(id: String, target: TrackMatcher.Target): Boolean {
+        StreamChoice.of(id)?.let { pinned ->
+            if (!StreamChoice.isSubstitute(id)) return false
+            // Re-stamped, so a pin made a track early doesn't age out before
+            // its own fade arms. Ceiling: the URL is then trusted up to a track
+            // past TTL_MS; a bridge whose URLs die sooner shows as a 403 on a
+            // re-open (a seek), not as a cut.
+            StreamChoice.remember(id, pinned, substituted = true)
+            return true
+        }
+        // A YouTube copy an earlier play left under `#alt` is read off disk
+        // ahead of any pin, and a partial one would be finished from the
+        // pinned file. Such a track stays YouTube's.
+        val alt = keyFactory.buildCacheKey(DataSpec(Uri.parse("bitchord://watch?v=$id")))
+        val youTubeOnDisk = runCatching {
+            cache.getCachedSpans(alt).isNotEmpty() &&
+                cache.getContentMetadata(alt).get(META_ORIGIN, null as String?) == Origin.YOUTUBE.name
+        }.getOrDefault(false)
+        if (youTubeOnDisk) {
+            TrackLog.d(TAG, "not pinning $id: a YouTube copy is already cached under $alt", about = id)
+            return false
+        }
+        val stream = runCatching { SourceResolver.prefetchSubstitute(target) }
+            .onFailure { TrackLog.d(TAG, "warm-up substitute failed for $id: ${it.message}", about = id) }
+            .getOrNull() ?: return false
+        // The pinned branch of the resolver has no manifest check (the race
+        // has); a pinned DASH/HLS URL fails the standby and drops the blend.
+        if (StreamContainer.isManifest(stream.url)) return false
+        if (StreamChoice.of(id) != null) return StreamChoice.isSubstitute(id)
+        StreamChoice.remember(id, stream, substituted = true)
+        return true
+    }
+
+    /**
      * A queued track as read-ahead needs it.
      *
      * [target] is what a cross-source match is made on, and read-ahead cannot
```

**Optional but recommended: a guarantee of no cut after a fade.** This covers any fallback the diff above can't prevent (rows 3-4, a slow bridge). The trade-off is that a track that blended in on a lower-quality stream stays on it for that one play. Tapping "Upgrade quality" by hand still works.

```diff
--- a/app/src/main/java/com/music/bitchord/playback/PlaybackService.kt
+++ b/app/src/main/java/com/music/bitchord/playback/PlaybackService.kt
@@ -3524,6 +3524,7 @@
         // ExoPlayer preparing the next item while this one played, so
         // it is pending by now; the ones that aren't are picked up by
         // the sampler in [reportProgress].
+        blendedIn = mediaItem?.mediaId?.takeIf { alreadyAudible && reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO }
         cancelStaleUpgradeJob()
         lookForBetterCopy(exoPlayer)
         // Covers crossfades too: a blended advance never reaches
@@ -3536,6 +3537,11 @@
     /** The background hunt for a better copy of whatever is playing. */
     private var upgradeJob: Job? = null
 
+    // ponytail: a track that arrived inside a crossfade/Automix keeps its
+    // stream for this play; an automatic swap would cut the mix that just
+    // landed. "Upgrade quality" by hand clears it.
+    private var blendedIn: String? = null
+
     /** Which track [upgradeJob] is hunting for — see [lookForBetterCopy]. */
     private var upgradeFor: String? = null
 
@@ -4216,6 +4222,10 @@
         val alreadyPending = QualityUpgrade.isPending(mediaId)
         val shelved = QualityUpgrade.shelvedFor(mediaId)
         if (shelved == null && !alreadyPending && !QualityUpgrade.couldStillUpgrade(mediaId, uri)) return
+        if (mediaId == blendedIn) {
+            NerdStats.onLosslessRaceEnd(mediaId)
+            return
+        }
         if (upgradeJob?.isActive == true) {
             // Already hunting for this track. One left over from a track the
             // queue has moved past is a different matter: it can only come
@@ -4359,6 +4369,7 @@
         SourceRegistry.clearCompletedAddonTrackCalls()
         QualityUpgrade.askByHand(mediaId)
         TrackLog.d("BitChord", "upgrade asked for by hand for $mediaId", about = mediaId)
+        blendedIn = null
         lookForBetterCopy(player)
     }
```

Notes on the optional diff:
- The only caller that passes `AUTO` with `alreadyAudible = true` is the crossfade handoff (`:3214-3218`). Version swaps pass `PLAYLIST_CHANGED` (`:2144`, `:2408`).
- `onLosslessRaceEnd` clears the racing badge, so the manual-upgrade check at `:4338` doesn't block "Upgrade quality".

**Checks run:**
- Both diffs pass `git apply --check` on main and on v1.8.1.
- On a throwaway copy of v1.8.1 with `0001-addon-prefetch.patch` and both diffs applied, `:app:compileProdReleaseKotlin` succeeded. I confirmed `pinSubstitute` and `blendedIn` are in the compiled classes.
- There is no unit test, because the helper needs `SimpleCache` and `SourceResolver` as real objects; the log lines in §4 are the check.
- Nothing has been run on a device.

**Not in the diff, but available to tune:** `ARM_LEAD_MS` (`CrossfadeController.kt:2716`, 4 s).
- Raise it to about 8 s only if the logs show late fade starts.
- If you also apply the plan's "extra C" (a 3 s head start in the race), raise it as well. Otherwise an unpinned standby can spend 3 of its 4 s lead waiting.

**Corrections to the earlier research:**
- **"Discard the entry; it fails safely if locked" is wrong.** In Media3 1.11, `SimpleCache.removeResource` just loops over the cached spans and removes each one with no lock check (I read the bytecode of media3-datasource-1.11.0 with javap). That is why the diff skips the pin instead of deleting the entry.
- **v1.8.1 no longer wipes the audio cache on an update.** It uses `AudioCache` `CACHE_FORMAT` instead (fork `AudioCache.kt:242-247`, `BitChordApplication.kt:157-162`); main still wipes (`BitChordApplication.kt:157-158`). Uninstalling to switch signing keys empties the cache once. After that, the row 6 guard is what protects you.

## 3. Automix analysis: keep the YouTube Opus analysis

Keep it.
- Analysis is pinned to the plain-key Opus copy (`AutomixAnalysisSource.kt:15-16`, used at `TrackAnalyzer.kt:306`, `:499`, `:717`).
- It is stored per track (`TrackAnalyzer.kt:402`).
- It needs at most a 16 MB head. Analysing the FLAC would need the whole file and two to four times the heap at hi-res rates.
- The diff only pins when a source is ranked above YouTube (`AudioCache.kt:938`, `:969`). That keeps the addon's bytes under `#alt` (`:406`) and away from the analysis key.

**Alignment risk:**
- Nothing measures or corrects an offset between the Opus copy and the FLAC master.
- The cue is applied as-is (`CrossfadeController.kt:1034`, `:1258`).
- Phase lock compares beat grid against beat grid (`:2493-2507`), so a shifted master stays shifted.
- The only safeguard is a duration check with a 1.0 s tolerance (`TrackAnalyzer.kt:615-633`, `:749-760`, `:1342`).
- One new effect: once N+1 is prepared, its expected duration becomes the FLAC's (`CrossfadeController.kt:1142-1150`). If the addon file's length differs by more than 1 s, an analysis that hasn't finished yet is rejected and you get a plain fade.

**Free test, before you uninstall the official app:** today's upgrade cut re-seeks to the same millisecond (`PlaybackService.kt:4658`). If the music picks up exactly where it was after the gap, the masters line up. If it jumps or repeats, beat-locked mixes into that track will be off by the same amount.

## 4. Risks, unknowns, and how to check them on the phone

**Logging:**
- TrackLog lines (tags `BitChord`, `DECODE`) only reach logcat in debug builds (`data/innertube/AndroidStreamHooks.kt:26-35`). On a release build, use Settings → Copy log.
- Plain `Log` tags always appear: `BitChordCrossfade` (`CrossfadeController.kt:2692`), `BitChordTrackAnalyzer` (`TrackAnalyzer.kt:1291`), `BCFetchDebug` (`AudioCache.kt:905`).
- Command: `adb logcat -v time -s BitChordCrossfade BitChordTrackAnalyzer BCFetchDebug BitChord DECODE`

**A good transition looks like this:**
1. `BCFetchDebug prefetchQueue: head A -> B` at each handoff.
2. `warmed: '<title>' from <addon> at FLAC …` (`SourceResolver.kt:330-333`), now for the track after the next one. The time between the head line and this line is your bridge's lookup latency.
3. `arm smart|standard fade=… end=…` (`CrossfadeController.kt:1235-1243`).
4. `blend start at cue=… out=…` (`:1451`), then `handoff at …` (`:1480`), then `finish from …`.
5. No `upgrade for … holding`, no `upgraded to …`, no `swap seam` (`PlaybackService.kt:4580`, `:4661`, `:1193`).
6. Stats for nerds on the track that came in shows the addon and FLAC, because the pinned branch records it (`:1514-1519`).
7. There will be no `DECODE` line for a track that crossfaded in, because the format listener only sits on the session player (`:3357-3363`).

**Bad signs and what they mean:**
- `upgraded to` or `swap seam` after a blend: the incoming track wasn't pinned, or isn't marked lossless (rows 1, 3, 4).
- `bail from ARMING`: manifest, dead URL, or a bridge slower than 12 s.
- `out=` in the `blend start` line is more than about 300 ms past `end − fade`: late start, raise `ARM_LEAD_MS`.
- `not pinning …: a YouTube copy is already cached`: row 6.
- `Rendition … rejected for …` or `Head rendition … rejected`: the masters have different lengths.
- `warm-up substitute failed`: the bridge is erroring.

**Unknowns, none measured:**
- Bridge lookup latency compared with how fast N buffers.
- Whether it states a codec.
- Whether it ever returns manifests.
- URL lifetime. With the re-stamp, a URL can now be used for up to 15 min plus one track; an expired one shows up as a 403 when the player re-opens it after a seek.
- Two concurrent range readers on the same URL (the outgoing player's preload plus the standby).
- Whether the FLAC files have a SEEKTABLE, which decides how slow seeking to an Automix cue is (row 9).
- Master alignment (§3).
- The check-then-put window in `pinSubstitute`.
- Media3 preload timing, which comes from reading bytecode, not from measurement.

Diff files: `/tmp/bcpatch/required.diff`, `/tmp/bcpatch/optionA.diff`. Neither repo was modified.
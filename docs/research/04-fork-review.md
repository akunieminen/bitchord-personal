# Review: fork 'personal' (v1.8.1 + 12 commits): surviving issues

All diffs are against the working tree at `/home/aku/Documents/bitchord-work/fork` (HEAD = `personal` = 2eeb606). The CI diff applies to `/home/aku/Documents/bitchord-work/bitchord-personal`. I checked every hunk's context against the current files. Nothing was edited and nothing was built.

## Surviving issues, worst first

### 1. FLAC gets spliced onto a partial YouTube `#alt` copy (merges cache-F1 and race-F2)
**Where:** `AudioCache.kt:1343-1354` and `PlaybackService.kt:1511, 1567, 5516-5517`.

**Trigger:**
- An earlier play left a partial Opus file under `X#alt` (origin YOUTUBE), and the 15-minute pin has lapsed or the process restarted.
- `pinSubstitute` sees that Opus file, returns false, and pins nothing.
- The player reads the Opus prefix from disk, then opens upstream at offset P. The resolver races, and the 4s head start now lets the addon win.
- The FLAC from `bytes=P-` is written after the WebM prefix, so `MatroskaExtractor` fails mid-song. Recovery then refuses substitutes for 10 minutes.

`MainViewModel.kt:2388` (`prefetchTopResult`) reaches the same splice through the pinned branch. The fix goes in the resolver before the pinned branch, so it covers every open, including that one.

```diff
--- a/app/src/main/java/com/music/bitchord/playback/AudioCache.kt
+++ b/app/src/main/java/com/music/bitchord/playback/AudioCache.kt
@@ -1343,12 +1343,7 @@
-        // A YouTube copy an earlier play left under `#alt` is read off disk
-        // ahead of any pin, and a partial one would be finished from the
-        // pinned file. Such a track stays YouTube's.
-        val alt = keyFactory.buildCacheKey(DataSpec(Uri.parse("bitchord://watch?v=$id")))
-        val youTubeOnDisk = runCatching {
-            cache.getCachedSpans(alt).isNotEmpty() &&
-                cache.getContentMetadata(alt).get(META_ORIGIN, null as String?) == Origin.YOUTUBE.name
-        }.getOrDefault(false)
-        if (youTubeOnDisk) {
-            TrackLog.d(TAG, "not pinning $id: a YouTube copy is already cached under $alt", about = id)
+        // A YouTube copy an earlier play left under `#alt` is read off disk
+        // ahead of any pin, and the resolver finishes it from YouTube (see
+        // [holdsYouTubeBytes]). Such a track stays YouTube's.
+        if (holdsYouTubeBytes(DataSpec(Uri.parse("bitchord://watch?v=$id")))) {
+            TrackLog.d(TAG, "not pinning $id: a YouTube copy is already cached under #alt", about = id)
             return false
         }
@@ -1362,3 +1357,10 @@
         StreamChoice.remember(id, stream, substituted = true)
         return true
     }
+
+    /** Fork: whether the entry [spec] reads already holds YouTube bytes; finishing it from another file splices two containers. */
+    fun holdsYouTubeBytes(spec: DataSpec): Boolean = ::cache.isInitialized && runCatching {
+        val key = spec.key ?: keyFactory.buildCacheKey(spec)
+        cache.getCachedSpans(key).isNotEmpty() &&
+            cache.getContentMetadata(key).get(META_ORIGIN, null as String?) == Origin.YOUTUBE.name
+    }.getOrDefault(false)
--- a/app/src/main/java/com/music/bitchord/playback/PlaybackService.kt
+++ b/app/src/main/java/com/music/bitchord/playback/PlaybackService.kt
@@ -1510,2 +1510,5 @@
             // [StreamChoice].
-            StreamChoice.of(videoId)?.let { serving ->
+            // Fork: an entry already holding YouTube bytes is finished from YouTube, pinned or not.
+            val youTubeOnDisk = AudioCache.holdsYouTubeBytes(dataSpec)
+            StreamChoice.of(videoId)?.takeUnless { youTubeOnDisk && StreamChoice.isSubstitute(videoId) }?.let { serving ->
@@ -1567 +1570 @@
-            if (!SourceResolver.canSubstituteForYouTube()) {
+            if (!SourceResolver.canSubstituteForYouTube() || youTubeOnDisk) {
```
The plain branch already calls `remember(substituted = false)`, so later opens stay on YouTube. Lossless then arrives through QualityUpgrade on `#hifi`, which also needs fix 4.

Not done: dropping a partial YouTube `#alt` so the addon can be pinned from byte 0. A player may already hold that entry open; add this only behind a "not open" check.

### 2. Lock probe passes on an already-cached head, so read-ahead pulls bytes into a locked hole (about 1MB × 4 attempts per transition)
**Where:** `AudioCache.kt:2198-2218`, which every read-ahead caller goes through.

**Trigger:**
- The player opens the next pinned FLAC first and pauses while still holding the lock on `[P0, ∞)`.
- In `cacheWholeOnce`, a chunk whose first 64kB is on disk "passes" the probe with no network traffic. The full pull then reads the locked hole upstream and writes nothing.
- The retry repeats this 4 times, 5s apart.

The verifier corrected the size from about 8MB to about 4MB.

```diff
--- a/app/src/main/java/com/music/bitchord/playback/AudioCache.kt
+++ b/app/src/main/java/com/music/bitchord/playback/AudioCache.kt
@@ -2197,3 +2197,8 @@
         if (upstreamFactory == null) return
         if (cache.getCachedBytes(cacheKey, position, length) >= length) return
+        // Fork: knock at the first byte not on disk. A probe over a cached head
+        // "lands" without the network, and the pull behind it reads a locked hole into nowhere.
+        val head = cache.getCachedLength(cacheKey, position, length).coerceAtLeast(0)
+        val from = position + head
+        val rest = length - head
 
@@ -2214,5 +2219,5 @@
-        if (length > LOCK_PROBE_BYTES) {
-            pull(cacheKey, uri, position, LOCK_PROBE_BYTES, pinKey)
-            if (cache.getCachedBytes(cacheKey, position, LOCK_PROBE_BYTES) < LOCK_PROBE_BYTES) return
+        if (rest > LOCK_PROBE_BYTES) {
+            pull(cacheKey, uri, from, LOCK_PROBE_BYTES, pinKey)
+            if (cache.getCachedBytes(cacheKey, from, LOCK_PROBE_BYTES) < LOCK_PROBE_BYTES) return
         }
-        pull(cacheKey, uri, position, length, pinKey)
+        pull(cacheKey, uri, from, rest, pinKey)
     }
```
Remaining limit: a lock that starts later than `from` inside the same chunk still wastes the rest of that chunk. That needs a narrow race.

### 3. Lookahead pins JioSaavn's 0.4s 320k AAC, and the addon is never asked (pr932-1)
**Where:** `SourceResolver.kt:333`.

**Trigger:**
- Only happens when JioSaavn is enabled; it is opt-in.
- `bestAcross` breaks on the first usable answer and cancels the addon.
- "First pin wins" only re-stamps on later passes, so the addon is never asked again. A blended track then stays on AAC (see fix 4).

```diff
--- a/app/src/main/java/com/music/bitchord/data/sources/SourceResolver.kt
+++ b/app/src/main/java/com/music/bitchord/data/sources/SourceResolver.kt
@@ -333 +333,5 @@
-        val (source, stream) = bestAcross(quick, target, requestForNow()) ?: return null
+        // Fork: off the critical path, so wait for the addon instead of pinning whichever lossy answer lands first.
+        val (source, stream) = bestAcross(
+            quick, target, requestForNow(),
+            waitForAll = quick.any { it.kind == SourceKind.ADDON },
+        ) ?: return null
```
Only JioSaavn is `worthPrefetching`, so this changes nothing unless both the addon and JioSaavn are enabled. It makes the 2-ahead pin slower; pair it with minor item M3.

### 4. `blendedIn` blocks every automatic upgrade, including PR #932's 300ms smooth swap, now on by default (race-F1, split vote)
**Where:** `PlaybackService.kt:4304`.

A crossfade or Automix track that arrives lossy (pin failed, or the JioSaavn pin from fix 3) plays lossy to its end. The "would cut the mix" reason only holds when `sourceCrossfadeEnabled` is off. Commit 2eeb606 already lines the copies up before fading.

```diff
--- a/app/src/main/java/com/music/bitchord/playback/PlaybackService.kt
+++ b/app/src/main/java/com/music/bitchord/playback/PlaybackService.kt
@@ -4304 +4304 @@
-        if (ForkSettings.noUpgradeAfterBlend.value && mediaId == blendedIn) {
+        if (ForkSettings.noUpgradeAfterBlend.value && !AppSettings.sourceCrossfadeEnabled.value && mediaId == blendedIn) {
```
What remains: the rare hard-cut fallback (call or Listen Together with no spare player) can still cut.

### 5. Fork revision collides with upstream's patch number, so updates stop after a 2-part release (upd-2part-version)
**Where:** `app/build.gradle.kts:72-73`, `bitchord-personal/.github/workflows/build.yml:102-103`.

**Trigger:** upstream tags v1.9, and CI publishes 1.9.45. Upstream then tags v1.9.1, and CI publishes 1.9.1.46. `isNewer("1.9.1.46", "1.9.45")` is false, so no update is offered until 1.10.x.

```diff
--- a/app/build.gradle.kts
+++ b/app/build.gradle.kts
@@ -71,3 +71,7 @@
         // Fork: CI appends its build number (1.8.1 -> 1.8.1.7) so the in-app updater sees each fork build as newer.
-        versionName = (rootProject.extra["bitchordVersionName"] as String) +
-            (findProperty("bitchord.forkRevision")?.let { ".$it" } ?: "")
+        // Padded to three parts first (1.9 -> 1.9.0.45), or 1.9.1.46 would compare older than 1.9.45.
+        versionName = (rootProject.extra["bitchordVersionName"] as String).let { base ->
+            findProperty("bitchord.forkRevision")?.let { rev ->
+                (base.split('.') + listOf("0", "0")).take(3).joinToString(".") + ".$rev"
+            } ?: base
+        }
--- a/.github/workflows/build.yml
+++ b/.github/workflows/build.yml
@@ -97,7 +97,6 @@
-          ./gradlew --console=plain assembleProdRelease \
+          ./gradlew --console=plain :app:assembleProdRelease \
             -Pbitchord.forkRevision=${{ github.run_number }} -Pbitchord.bundleWear=false
 
       - name: Publish
         run: |
-          base=$(sed -n 's/^extra\["bitchordVersionName"\] = "\(.*\)"$/\1/p' build.gradle.kts)
-          version="$base.${{ github.run_number }}"
+          version=$(jq -r '.elements[0].versionName' app/build/outputs/apk/prod/release/output-metadata.json)
```
- Reading the version back from the built APK means the tag can't drift from what was built.
- The schedule's `grep "^$tag\."` check still matches v1.9.0.N.
- The `:app:` prefix is the CI-time fix (ci-builds-tv-wear).

## Refuted findings
- None was fully refuted; every finding has at least one "not refuted" vote.
- race-F1 (`blendedIn`) got one refute vote, which called it a preference rather than a bug. It still survives and is item 4.
- Claims inside surviving findings that did not hold:
  - The "about 8MB, frontier at 4.1MB" figure in cache-F2 cannot happen, because the player commits in 5MB fragments. The real waste is about 1MB per attempt, about 4MB per transition.
  - "A complete YouTube `#alt` blocks the lookahead on replay" is a design trade-off, not corruption.
  - "The CI sed returns an empty base if the variable moves" has no trigger at 1.8.1.

## Minor, worth doing
- **M1** (cache-F4, `AudioCache.kt:1333`): `pinSubstitute` ignores the refusal, so a just-failed addon URL is re-pinned and about 50MB is read ahead into `#alt` for nothing. Fix: first line `if (StreamChoice.substitutesRefused(id)) return false`.
- **M2** (cache-F3, `AudioCache.kt:1422-1446`): if a FLAC read-ahead outlives the 15-minute TTL, the next chunk resolves to YouTube and writes Opus at FLAC offsets.
  - Fix: in `fetchWhole`, capture `val pin = StreamChoice.of(id)?.takeIf { StreamChoice.isSubstitute(id) }` and pass it to `cacheWholeOnce`.
  - Then per chunk: `if (pin != null) { if (StreamChoice.of(id) !== pin) return false; StreamChoice.remember(id, pin, substituted = true) }`.
- **M3** (cache-F5, `AudioCache.kt:1301-1306`): the 2-ahead `pinSubstitute` runs inline, which delays next's YouTube warm-up behind a lookup with no timeout. Fix 3 makes this worse. Fix: wrap that block in `launch { … }`.
- **M4** (race-F4, `PlaybackService.kt:3574-3580` and `watchSleepTimer`): a sleep-timer pause keeps reading ahead (whole FLACs overnight). Fix: call `cancelPrefetch()` after the sleep pause instead of `prefetchAround`.
- **M5** (race-F3, `CrossfadeController.kt:885, 1036`): the 4s head start eats the standby's 4s `ARM_LEAD`, so blends start late or drop when the bridge is slow. Fix: add `ForkSettings.headStartMs.value` to both arm thresholds.
- **M6** (race-F5, `PlaybackService.kt:886-893`): resume never retries read-ahead, because `preferredPrefetchRequest` and `pendingQueue` aren't cleared. Fix: expose `AudioCache.warming = job?.isActive == true`; on `isPlaying`, call `if (!AudioCache.warming) cancelPrefetch()` before `prefetchAround`.
- **M7** (race-F6, `PlaybackService.kt:1137`): editing the queue while paused keeps downloading the old next track. Fix: `if (exoPlayer.isPlaying || (preferredPrefetchRequest != null && !exoPlayer.playWhenReady)) prefetchAround(exoPlayer)`.
- **M8** (cache-F6): addon misses aren't remembered, so there are about 3 bridge lookups per missed track, plus more on every stall. Fix: a `pinMisses` map with a 10-minute TTL, checked in `pinSubstitute`, recorded only on a null result while still active.
- **M9** (pr932-2, `PlaybackService.kt:4611-4616`): a stale speed mismatch makes the busy guard shelve and re-audition the FLAC every 5s. Fix: add `fun isEasing() = easing != null` to `CrossfadeController` and use `crossfade?.isEasing() == true` in place of the speed comparison.
- **M10** (upd-tv, `AppUpdateChecker.kt:45`): TV builds poll the fork repo and get prompted on every launch, with no TV APK to install. Fix: make it a `val` that points TV builds at upstream when `BuildConfig.UPDATE_APK_PREFIX == "BitChordTV-"`.
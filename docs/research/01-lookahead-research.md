# BitChord addon lookahead on your phone: recommendation

The patch is one line. It gets rid of the cut for most tracks that play on through a queue. It does not fix the first track you tap, and a few edge cases still cut. Line numbers below are from the read-only clone at `edc1e6f3`, which is upstream main. Paths are relative to `app/src/main/java/com/music/bitchord/` unless they start with `app/` or `shared/`.

## 1. Verdict

**Effort: small.** The fix is one line, plus a one-time keystore and app reinstall, plus about 30 minutes setting up CI so updates happen on their own.

**Why the cut happens today.**
- When a track opens, `resolveWithModulePriority` races your addon against YouTube. The race is at `playback/PlaybackService.kt:5167-5196`.
- Read-ahead has already fetched the YouTube URL for the next track (`playback/AudioCache.kt:988-1000`), so YouTube almost always wins. The code's own comment says so (`PlaybackService.kt:5129-5136`).
- The addon lookup that lost is handed to QualityUpgrade (`PlaybackService.kt:5277-5282`).
- QualityUpgrade then swaps the stream mid-song with `replaceMediaItem` + `seekTo` + `prepare` (`PlaybackService.kt:4646-4659`). That is a hard cut with no fade. `QualityUpgrade.kt:33-35` even admits "a short break in the audio".
- There is no setting that avoids this.

**What the patch changes.**
- It sets `worthPrefetching = true` on `SourceKind.ADDON`. The only production code that reads this flag is `data/sources/SourceResolver.kt:327`.
- `AudioCache.prefetchQueue` will then look up the next queued track on your addon while the current one plays, and pin the result with `StreamChoice.remember(..., substituted = true)` (`AudioCache.kt:969-973`).
- When ExoPlayer opens that next track, the resolver checks the pin before any race (`PlaybackService.kt:1498-1547`). The track starts on the addon from the first note, with no YouTube start and no swap.
- If the decoder reports flac/alac/raw, the upgrade logic marks the track done and leaves it alone (`QualityUpgrade.kt:361-362`).
- This is the same line PR #911 added (`gh pr diff 911`, SourceKind hunk `@@ -76,6 +76,7 @@`). I left out its settings toggle.

**Tracks that will be clean:**
- Each next track in a queue, radio or album played straight through. This assumes the addon answers `/search` + `/stream` before ExoPlayer opens that next track.
- The top search result, if the lookup finishes before you tap it. `prefetchSubstitute` has a second caller, `ui/MainViewModel.kt:2363`, that pre-resolves the top result.
- Replays of songs whose cached copy is already addon FLAC.

**Tracks that will still cut:**

| Case | Why | Mitigation |
|---|---|---|
| First track you tap (outside search), or a skip two or more places ahead | Only `videoIds.firstOrNull()` is pinned (`AudioCache.kt:939`). Everything else goes through the race, where a warmed YouTube URL wins. | Optional extra C below |
| Songs you have played before | A complete YouTube Opus copy is kept under `videoId#alt` (`AudioCache.kt:401-407`, `456-462`, `731-757`). A cache hit never reaches the resolver (`AudioCache.kt:62-67`), so the pin is ignored. | Clear the song cache once (`ui/.../SettingsSheet.kt:1665`). A fresh install (needed anyway, see section 3) also starts with an empty cache. |
| JioSaavn enabled (it is off by default, `SourceRegistry.kt:40`) | JioSaavn also prefetches. `bestAcross` takes the first usable answer (`SourceResolver.kt:841-849`), so JioSaavn's 320k copy usually gets pinned, and you get a JioSaavn-to-FLAC swap instead. | Leave JioSaavn off, or apply extra A |
| Addon stream with no stated codec (`isLossless == null`) | The pinned track is marked for an upgrade (`PlaybackService.kt:1532-1543`, `shared/.../StreamFormat.kt:32-33`). | Make the bridge state its codec: a `.flac` URL, a mime type, or a lossless quality label (`AddonSource.kt:380-405`) |
| Bridge returns HLS/DASH manifests | The pinned branch has no manifest guard (it exists only at `PlaybackService.kt:5212`). | Use direct progressive FLAC |
| Slow bridge | A late pin loses to the open-time race. | Extra B stops a late answer from overwriting a pin that is already in use |
| A pinned URL fails | The track falls back to YouTube, and upgrades for it are blocked for 10 minutes (`PlaybackService.kt:3860-3900`, `StreamChoice.kt:188`). | – |

**Server load.** Every next track and every search top result costs 1-3 `/search` calls and 1-3 `/stream` calls. Once a pin exists, `cacheBytes` becomes true and the next track is also byte-prefetched (`AudioCache.kt:980-986`). By my reading of the code this stops at a 64 KiB probe because of a key mismatch (`AudioCache.kt:1787-1831` against `:406`), but I have not checked that on a device. This extra load is what the owner objected to. It only matters to you if the bridge is someone else's.

## 2. The patch

**Minimal patch.** It applies cleanly to main and to v1.8.1 (the `SourceKind.kt` blob `06c02bfc` is the same in both). It also applied to every release from v1.5.2 to v1.8.1 in a `git apply --check` loop. `SourceKind.kt` has had only 6 commits in its whole history.

```diff
--- a/app/src/main/java/com/music/bitchord/data/sources/SourceKind.kt
+++ b/app/src/main/java/com/music/bitchord/data/sources/SourceKind.kt
@@ -76,6 +76,7 @@ enum class SourceKind(
         labels = listOf("FLAC", "Lossless", "Hi-Res"),
         needsServer = true,
         canServeLossless = true,
+        worthPrefetching = true,
         // Literal, not [USER_ADDED]: an enum entry is constructed before
         // its own companion exists.
         rank = 0,
```

- Keep the default 3 lines of diff context. With `-U1`, the context `canServeLossless = true,` followed by `// Literal…` also matches `CUSTOM_MODULE` (`SourceKind.kt:97-98`), so the patch could land in the wrong place.
- No test asserts `ADDON.worthPrefetching` (`app/src/test/.../SourcesTest.kt:1114-1129`).
- The prepared file `/tmp/bitchord-maint/personal/patches/0001-addon-prefetch.patch` is the same change plus one `// fork:` comment line. It applies cleanly; use whichever you prefer.

**Optional extras.** Each lives in a file that changes more often, so add them only when you need them.

- **A. JioSaavn enabled.** One line at `SourceResolver.kt:329`. It makes prefetch wait for the slowest source, and it only helps if the addon's answer is recognised as lossless.
  ```kotlin
  val (source, stream) = bestAcross(quick, target, requestForNow(), waitForAll = true) ?: return null
  ```
- **B. Late-pin overwrite guard.** One line at `AudioCache.kt:972`, inserted after `.getOrNull()`:
  ```kotlin
  ?.takeIf { StreamChoice.of(next) == null }
  ```
- **C. Head start for the open-time race.** This covers the first tap and skips. It is +2/-1 lines in `PlaybackService.kt`. Change `:5183` from `val quick: SourceStream? = select {` to:
  ```kotlin
  val quick: SourceStream? = withTimeoutOrNull(MODULE_HEAD_START_MS) { lookup.await() } ?: select {
  ```
  and add `const val MODULE_HEAD_START_MS = 3_000L` next to `SUBSTITUTE_TIMEOUT_MS` (`:8755`).
  - A verifier compiled this exact expression on its own (Kotlin 2.3.20 + coroutines 1.10.2) and checked it: a timeout does not cancel `lookup`, and YouTube still resolves in parallel.
  - Cost: up to N ms of silence on a cold start or skip when YouTube is already warm. Continuous playback costs nothing, because the next item is resolved while the previous one plays.
  - Upstream deliberately removed a similar head start (comment at `:5110-5118`).
  - Conflict risk is low. The `select` block last changed on 2026-08-27, and main...v1.8.1 has no hunk in the 5146-5285 range.
- **D. Soften the swaps that remain.** Cherry-pick open PR #932: a 300 ms dual-player crossfade, opt-in through `sourceCrossfadeEnabled`, +281/-21 lines.
  - It touches `PlaybackService.kt`, which has 138 commits, so expect conflicts.
  - Drop it if upstream merges it.
  - Its own caveat: there is no time alignment, so an offset between the masters may still be audible.
  - I'd skip D until you've lived with the patch plus C.

## 3. Build, install and migration

**Base it on the v1.8.1 release tag (`7d956f21`), not main.**
- main has `bitchordVersionCode = 28` and a `beta1` suffix (`build.gradle.kts:44,66`). v1.8.1 has 29 and an empty suffix.
- v1.8.1 is 59 commits ahead of main and 0 behind.
- `/home/aku/Documents/bitchord-work/fork` is already a clean checkout at `7d956f2`, and its warm-up `assembleProdRelease` build succeeded with JDK 17 (`JAVA_HOME` in `~/.zshrc`).
- JDK 25 can't run Gradle 8.11.1.

**Signing blocks an in-place update.** I verified the upstream v1.8.1 APKs with apksigner: package `com.music.bitchord`, versionCode 29, signer `CN=Kushagra Singh`, SHA-256 `b5895722…d921`. An APK you sign yourself can't update that install. It fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.

**Step 1: try it side by side with no keystore.**
```sh
cd /home/aku/Documents/bitchord-work/fork
git apply /tmp/bitchord-maint/personal/patches/0001-addon-prefetch.patch
./gradlew :app:assembleProdBenchmark -Pbitchord.bundleWear=false
adb install app/build/outputs/apk/prod/benchmark/app-prod-arm64-v8a-benchmark.apk   # name inferred, not built yet
```
- This produces `com.music.bitchord.benchmark`: R8-optimised, signed with the debug key (`app/build.gradle.kts:184-189`), installed next to the existing app.
- Its launcher label is also "BitChord", and its data is empty. Add your addon, move it above YouTube, play an album, and check for the cut.
- Logcat lines to look for: `warmed: '<title>' from <addon>` (`SourceResolver.kt:330-333`) and the absence of `swap seam` (`PlaybackService.kt:1185-1196`). TrackLog only writes to logcat on debug builds, so with benchmark use Settings → Copy Log instead.

**Step 2: the permanent build, which replaces the official app.**
1. In the official app, go to Settings → Export data (`SettingsSheet.kt:329-355`). The backup contains every preference except secrets, plus listening history and search history (`data/stats/Backup.kt:62-80`, `AppSettings.kt:1899-1902`).
2. Uninstall the official app. This deletes its downloads, cache and login.
3. Install your release build, then Import data.
4. Redo by hand what the backup leaves out:
   - YouTube sign-in (`auth/AuthStore.kt:24`)
   - the addon URL and source order (stored in `bitchord_sources`, `SourceRegistry.kt:109`)
   - Last.fm, ListenBrainz and Discord credentials
   - local playlists (`bitchord_local_playlists`)
   - "original version" pins
   - downloads, which must be downloaded again

Network policy is the same as upstream (prod has `usesCleartextTraffic=false`, `app/src/main/AndroidManifest.xml:54`), so an addon that works now keeps working.

## 4. Repo and automatic updates

**Use a private standalone repo, not a GitHub fork.**
- A fork of a public repo can't be private.
- Upstream's 9 workflows would run in a fork, and none of them has a repository guard.
- CI can't push synced upstream commits: `GITHUB_TOKEN` can't push changes under `.github/workflows/*`, and upstream touched workflow files in 22 commits, most recently on 2026-10-17.

Instead, the repo holds only the patch and one workflow that builds upstream's latest release tag with the patch applied. The prepared files are in `/tmp/bitchord-maint/personal/`. They passed actionlint, and I dry-ran the tag-pick step: it picked `v1.8.1` and decided to build. No real Actions run has happened yet.

**One-time setup:**
```sh
cd ~ && keytool -genkey -v -keystore bitchord-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias bitchord
#   PKCS12 default: use the SAME password for store and key. Back up the .jks + password offline.
cp -r /tmp/bitchord-maint/personal ~/bitchord-personal && cd ~/bitchord-personal
git init -b main && git add -A && git commit -m "addon prefetch patch + build workflow"
gh repo create akunieminen/bitchord-personal --private --source . --push
base64 -w0 ~/bitchord-release.jks | gh secret set KEYSTORE_BASE64 -R akunieminen/bitchord-personal
gh secret set KEYSTORE_PASSWORD -R akunieminen/bitchord-personal   # prompts
gh secret set KEY_PASSWORD      -R akunieminen/bitchord-personal   # same value
echo -n bitchord | gh secret set KEY_ALIAS -R akunieminen/bitchord-personal
gh workflow run build.yml -R akunieminen/bitchord-personal && gh run watch -R akunieminen/bitchord-personal
```

**Workflow** (`.github/workflows/build.yml`, exactly as prepared):
```yaml
name: Build patched BitChord
on:
  schedule:
    - cron: '23 5,17 * * *'
  workflow_dispatch:
    inputs:
      tag: { description: Upstream tag to build (blank = latest release), required: false }
      force: { description: Rebuild even if already released here, type: boolean, default: false }
permissions:
  contents: write
concurrency: { group: build, cancel-in-progress: false }
env:
  UPSTREAM: kushagrasinghx/BitChord
  GH_TOKEN: ${{ github.token }}
jobs:
  check:
    runs-on: ubuntu-latest
    outputs:
      tag: ${{ steps.pick.outputs.tag }}
      build: ${{ steps.pick.outputs.build }}
    steps:
      - id: pick
        env: { TAG_IN: '${{ inputs.tag }}', FORCE: '${{ inputs.force }}' }
        run: |
          tag="${TAG_IN:-$(gh release view -R "$UPSTREAM" --json tagName -q .tagName)}"
          echo "tag=$tag" >> "$GITHUB_OUTPUT"
          if [ "$FORCE" = true ] || ! gh release view "$tag" -R "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
            echo "build=true" >> "$GITHUB_OUTPUT"
          fi
  build:
    needs: check
    if: needs.check.outputs.build == 'true'
    runs-on: ubuntu-latest
    timeout-minutes: 75
    env: { TAG: '${{ needs.check.outputs.tag }}' }
    steps:
      - uses: actions/checkout@v4
        with: { repository: kushagrasinghx/BitChord, ref: '${{ needs.check.outputs.tag }}', fetch-depth: 0 }
      - uses: actions/checkout@v4
        with: { path: own }
      - run: git apply --3way -v own/patches/*.patch
      - uses: actions/setup-java@v4
        with: { java-version: '17', distribution: temurin, cache: gradle }
      - env:
          KEYSTORE_BASE64: ${{ secrets.KEYSTORE_BASE64 }}
          KEYSTORE_PASSWORD: ${{ secrets.KEYSTORE_PASSWORD }}
          KEY_ALIAS: ${{ secrets.KEY_ALIAS }}
          KEY_PASSWORD: ${{ secrets.KEY_PASSWORD }}
          LASTFM_API_KEY: ${{ secrets.LASTFM_API_KEY }}
          LASTFM_SECRET: ${{ secrets.LASTFM_SECRET }}
        run: |
          printf 'LASTFM_API_KEY=%s\nLASTFM_SECRET=%s\n' "$LASTFM_API_KEY" "$LASTFM_SECRET" > local.properties
          echo "$KEYSTORE_BASE64" | base64 -d > bitchord-release.jks
          test -s bitchord-release.jks || { echo "KEYSTORE_BASE64 secret missing"; exit 1; }
          printf 'storeFile=bitchord-release.jks\nstorePassword=%s\nkeyAlias=%s\nkeyPassword=%s\n' \
            "$KEYSTORE_PASSWORD" "$KEY_ALIAS" "$KEY_PASSWORD" > keystore.properties
      - run: chmod +x gradlew && ./gradlew assembleProdRelease -Pbitchord.bundleWear=false
      - run: |
          gh release delete "$TAG" -R "$GITHUB_REPOSITORY" --yes --cleanup-tag 2>/dev/null || true
          gh release create "$TAG" app/build/outputs/apk/prod/release/*.apk \
            -R "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" \
            --title "BitChord $TAG + addon prefetch" \
            --notes "Upstream $UPSTREAM@$TAG ($(git rev-parse --short HEAD)) with: $(cd own/patches && ls)"
```

**How the phone gets updates.** Use Obtainium:
- Add app → `https://github.com/akunieminen/bitchord-personal`.
- Add a fine-grained PAT with Contents: read-only on that repo.
- Set "Filter APKs by regex" to `arm64-v8a`. Confirm your phone's ABI first with `adb shell getprop ro.product.cpu.abi`.
- Turn on background updates.

Release tags match upstream (`v1.8.1`), so Obtainium's version check lines up with `versionName`. One catch: a forced rebuild of the same tag is not seen as an update, so install that one by hand.

**Ongoing:**
- New upstream release → a build within about 12 hours → Obtainium update.
- If the patch stops applying, the run fails and GitHub emails you. To fix it: `git checkout <tag>`, `git apply --3way` the patch, resolve the conflict, then `git diff > patches/0001-addon-prefetch.patch` and push.
- Cost: Actions minutes on a private repo come from the free 2,000 min/month. Estimate about 100-130 min/month (no-op checks plus 2-4 builds of 12-17 min each). Scheduled workflows in private repos are not auto-disabled after 60 days.
- The in-app updater still polls upstream with no way to turn it off (`ui/MainViewModel.kt:1469-1474`, `data/AppUpdateChecker.kt:45-46`). Its upstream APK won't install over your key, so it is a harmless reminder. To silence it, point `LATEST_RELEASE_URL` at your repo (a 404 is ignored, `AppUpdateChecker.kt:72-73`).

## 5. Risks and unknowns

- **Nothing has been tested on a device.** The pin-before-race ordering is confirmed in the code. Whether pins arrive in time depends on how fast your bridge is. If it takes longer than it takes for the current Opus track to finish buffering (8 MB cap, `PlaybackService.kt:8715`), the next track still races. Check the `warmed:` and `swap seam` log lines.
- **Bridge behaviour decides several branches.** It needs to state lossless (codec, mime, `.flac` or a quality label). It needs to return direct files, not manifests. Its URLs need to last past about 15 minutes, because the pin lifetime is `StreamChoice.kt:178` and `expiresAt` is not parsed.
- **Whose server is it?** If the bridge is shared or run by someone else, this creates the double load the owner refused (PR #911, OWNER comment 2026-10-19 09:25Z). If it is yours, only you pay for it.
- **Partial Opus `#alt` cache entries** left from before the patch could have FLAC spliced into them. Clearing the cache once, or doing the fresh install, avoids this.
- **Upstream release branching** moves around: v1.6 was released from branch v1.5.3, v1.7 from v1.6.1, v1.8.1 from v1.8.1. The workflow follows `releases/latest`, so this doesn't matter unless upstream stops publishing GitHub Releases.
- **Not verified:**
  - exact APK output names for the benchmark and signed release builds
  - a full CI run of `build.yml`
  - whether a slow addon that misses with extra C adds audible silence on skips
- **Other caveats:**
  - Pairing a Wear OS watch needs a watch build signed with the same key, so remove `-Pbitchord.bundleWear=false` in that case.
  - Losing the `.jks` forces another uninstall and reinstall.

**Files:**
- `/tmp/bitchord-maint/personal/patches/0001-addon-prefetch.patch`
- `/tmp/bitchord-maint/personal/.github/workflows/build.yml`
- `/home/aku/Documents/bitchord-work/fork` (v1.8.1 checkout for local builds)
- Target file: `/home/aku/Documents/bitchord-work/BitChord/app/src/main/java/com/music/bitchord/data/sources/SourceKind.kt:72-82`

The read-only clone was not modified.
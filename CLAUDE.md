# bitchord-personal — developer notes

Personal build of [kushagrasinghx/BitChord](https://github.com/kushagrasinghx/BitChord): upstream's latest
release + `patches/*.patch`, built and signed by CI, installed through the app's own updater.
This file is the hand-over: read it before touching the patches. Deeper background is in `docs/research/`.

## Layout

- `patches/` — the fork, as `git format-patch` output; `patches/BASE` = the upstream tag they were made on.
- `scripts/setup-fork.sh` — clones upstream next to this repo (`../fork`) and rebuilds branch `personal` from the patches.
- `scripts/export-patches.sh` — writes branch `personal` back into `patches/`.
- `.github/workflows/build.yml` — every 6 h: newest upstream release + `git am --3way patches/*.patch` → signed APK → GitHub Release. A push to `patches/**` also builds. Keeps itself alive past GitHub's 60-day cutoff.
- `docs/research/` — today's reports: lookahead design, Automix, PR #932 review, fork review, addon backends, QOL sweep.

## New PC setup

1. JDK **17** (Gradle 8.11.1 does not run on JDK 25). Android SDK with platform 37, NDK 27.1.12297006, CMake 3.22.1.
2. AGP 8.10.1 wants `platforms/android-37`, but sdkmanager installs `android-37.0`. Copy it to `android-37` and set
   `AndroidVersion.ApiLevel=37` in `source.properties` and `platforms;android-37` / `<api-level>37</api-level>` in `package.xml`.
3. `scripts/setup-fork.sh` → `../fork` on branch `personal`. Add `local.properties` (`sdk.dir=…`).
4. Signing key: private repo `akunieminen/bitchord-signing` → put `keystore.properties` (fix `storeFile` path) in `../fork`.
   Every APK must be signed with this key or Android refuses the update. CI has it as repo secrets.

## Change loop

```sh
cd ../fork                                   # branch personal
# edit, then commit (one concern per commit; prefix "fork:" or "fix(...):")
JAVA_HOME=<jdk17> ./gradlew :app:assembleProdRelease -Pbitchord.forkRevision=7 -Pbitchord.bundleWear=false
aapt2 dump badging app/build/outputs/apk/prod/release/app-prod-arm64-v8a-release.apk | head -1   # CHECK versionName
adb install -r app/build/outputs/apk/prod/release/app-prod-arm64-v8a-release.apk
cd ../bitchord-personal && scripts/export-patches.sh && git add -A && git commit -m "…" && git push   # CI publishes
```

- Local test builds use `forkRevision` 1–99; CI uses `100 + run_number`, so a CI release always outranks a local build
  and the in-app updater offers it. Version = upstream base padded to 3 parts + `.rev` (1.8.1.102).
- Always check the APK's versionName before installing: a Gradle daemon that dies under memory pressure leaves the
  previous APK in place, and `adb install` will happily reinstall it.
- `e: … Module was compiled with an incompatible version of Kotlin` from `:sharedUi:lintVitalAnalyzeRelease` is noise.
- `v1.8.1` is both a tag and a branch upstream: use `refs/tags/v1.8.1` in git commands.
- Upstream cuts releases from version branches, not `main` (v1.8.1 was 59 commits ahead of main). Base on tags.
- New upstream release breaks a patch → CI fails and GitHub emails. Fix: `git fetch origin tag vNEW`,
  `git rebase --onto refs/tags/vNEW refs/tags/vOLD personal`, resolve, build, `scripts/export-patches.sh vNEW`, push.
  Drop the three PR #932 commits once upstream merges that PR.

## Phone testing

- WiFi adb: `adb mdns services` → `adb connect adb-<serial>._adb._tcp`. Auth expires after ~7 days (tap Allow on the phone).
- App log: `adb logcat -v threadtime --uid=$(adb shell pm list packages -U com.music.bitchord | sed 's/.*uid://')`.
  TrackLog reaches logcat in release builds (a fork patch). Useful tags: `BitChord` (resolve, `warmed:`, `upgrade…`,
  `AutoPlay extended`), `DECODE`, `AUDIO_OUT`, `BCFetchDebug` (read-ahead head), `BitChordCrossfade`
  (`arm` / `blend start` / `handoff` / `finish`), `BitChordTrackAnalyzer`.
- System side (EQ/effects): `AS.MusicFxHelper` (`open/close MusicFx session N`), `EffectDP` (`DP_reset` = an EQ
  re-attaching), `EffectChain`. `adb shell dumpsys media.audio_flinger` maps tracks → sessions → effects.
- A clean transition: next track `warmed: … from <addon>`, no `upgraded to`, no `swap seam`, and at a crossfade
  handoff no MusicFx close/open.

## Patch map (patches on v1.8.1; `ls patches` for the current list)

| Concern | Where |
|---|---|
| Fork settings (`ForkSettings`, Settings → Fork tweaks, English only, own prefs file) | `data/settings/ForkSettings.kt`, `ui/screens/ForkTweaksGroup.kt`, 1-line hooks |
| Addon lookahead: ADDON joins `prefetchSubstitute`; pins next **and** next+1 (`pinSubstitute`: first pin wins, re-stamp, no pin over YouTube bytes, no manifests, misses remembered 10 min); 2 s read-ahead; read-ahead while paused | `SourceResolver.kt`, `AudioCache.kt`, `PlaybackService.kt` |
| Upstream bug: read-ahead checked the plain key but wrote `#alt` → stopped at 64 kB; whole-file length from `Content-Range` | `AudioCache.kt` |
| Head start: an unpinned open waits `headStartMs` (4 s) for the addons before YouTube; skipped for known misses | `PlaybackService.resolveWithModulePriority` |
| No upgrade after a blend (only when the smooth swap is off) | `PlaybackService.kt` (`blendedIn`) |
| PR #932 (3 commits, unmodified) + fork fixes (position, version-swap contention, queue carry-over, lag compensation, linear gains) | `PlaybackService.kt`, `CrossfadeController.kt` |
| Keep mix tempo after beat-matched Automix (the speed reset was an audible stop) | `CrossfadeController.kt` |
| AutoPlay length setting (25) + load more 10 rows before the queue's end (`QueueEndHook` → `ACTION_LOAD_MORE_AUTOPLAY`) | `Autoplay.kt`, `PlayerQueue.kt` (sharedUi), `PlayerConnection.kt`, `PlaybackService.kt`, `MainActivity.kt` |
| Audio sessions: two fixed sessions, both advertised to effect apps | `PlaybackService.kt` |
| QOL: BT reconnect resume, unplayable toast, sleep fade + 5/10 min, source on stats line | `PlaybackService.kt`, `SleepTimer.kt`, `PlayerControls.kt` |
| Updater → this repo; `.forkRevision` versionName; TrackLog to logcat | `AppUpdateChecker.kt`, `app/build.gradle.kts`, `AndroidStreamHooks.kt` |
| Upgrade swap: offset measured on the audio (`VersionAudioAligner.findRenditionOffsetMs`, decodes both cached heads), then the muted standby is **speed-nudged** to within 20 ms (never re-seeked) and a 150 ms blend; no fade at all if it can't align; 5 misses end the re-offers | `PlaybackService.kt` (`seamlessSwapToStream`, `measureUpgradeOffset`), `VersionAudioAligner.kt` |
| `#src` key: a track whose `#alt` holds a kept YouTube copy *and that an addon has served* (`bc_addon_has` flag) is filed under `#src`, so replays (Listen again) start from the addon; memoized per process, never chosen offline | `AudioCache.kt` (`substituteKey`, `recordServed`, `completeSibling`) |
| Addon trouble ≠ miss: `AddonClient.lastTroubleAtMs` (429/5xx/timeouts); misses only remembered when no trouble during the lookup; spoiled next-track lookups retried 3 × 20 s | `AddonClient.kt`, `AudioCache.kt` |

## Gotchas learned the hard way

- **Media3 1.11 assigns `audioSessionId` on a background thread.** Read right after `build()` it is UNSET, so upstream's
  `spare.audioSessionId = active.audioSessionId` is a no-op. A truly *shared* session is worse with a volume-controller
  effect (Wavelet's DynamicsProcessing): AudioFlinger hands it one track's volume for the whole session, so both tracks
  fade together. Fix in place: two fixed sessions, both opened via `ACTION_OPEN_AUDIO_EFFECT_CONTROL_SESSION` while playing.
- **Cache keys:** with a source ranked above YouTube, `keyFactory` files a track under `id#alt` (upgrades under
  `id#<rendition>`). Anything checking cached bytes must use the same key. Never finish a YouTube prefix from another
  file (splice → mid-song decoder failure).
- **`StreamChoice` pins** live 15 min; the player trusts a pin before any race. Re-pinning while a player fills `#alt`
  splices two files — hence "first pin wins".
- **The YouTube URL warm-up is also where a track's loudness figure comes from**; skipping it for pinned tracks
  silently disabled volume levelling.
- **Addons are raced, not ordered:** the first acceptable answer wins and losers still get requests. Keep the set small
  (Qobuz addon first, then the lossless bridge). A dead addon costs up to the 20 s substitute timeout on every lookup.
- **Advanced Automix speed changes are audible** on this phone + Bluetooth (AudioTrack params on float output, Sonic
  on 16-bit). Automix is off on the owner's phone; plain Crossfade is fine.
- **Never align two copies by seeking.** Every seek restarts output with 150–250 ms of unpredictable latency, and
  `currentPosition` right after a seek is not trustworthy; overlapping copies a few hundred ms apart sound like a
  doubling or a repeated bar. Settle ~0.6 s, average several reads, nudge speed on the muted player.
- Upstream keeps YouTube/JioSaavn copies ("kept origins") but drops addon FLACs after playback, so before the `#src`
  key every replayed song started on YouTube.
- The shared Qobuz addon rate-limits (429 → `This addon is rate limiting BitChord`); a self-hosted addon on the
  owner's own subscription is the real fix (protocol: `data/sources/addon/AddonModels.kt`).
- Builds get OOM-killed while workflows run: `./gradlew --stop`, `--max-workers=4`, and always check the APK's
  versionName before `adb install`.
- Bluetooth output is never lossless (`lossless output: capable=false`); FLAC still saves one lossy generation.

## Backlog (offered, not done)

Bigger features: long-press menu on queue rows; save queue as playlist; radio from a playlist; Wi-Fi-only full-FLAC
read-ahead; keep complete addon FLACs in cache; "remove from history"; playlist reorder past 100 songs; double-tap seek
(touches a large, busy upstream file). Rejected: `setPrioritizeTimeOverSizeThresholds` hi-res buffer (+~50 MB heap
on an app already at its 256 MB cap).

Review leftovers (see `docs/research/04-fork-review.md`, `06-qol-sweep.md`): pin TTL vs a long read-ahead; the
next+1 pin runs inline before the URL warm-up; head start vs `ARM_LEAD_MS` when Automix is on; queue edits while
paused keep reading the old next; TV builds poll this repo.

Upstream candidates — **ask the owner before posting anything public**: the 64 kB read-ahead fix; PR #932's
restart-at-0:00 bug; the audio-session bug above.

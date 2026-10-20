# bitchord-personal — developer notes

Personal build of [kushagrasinghx/BitChord](https://github.com/kushagrasinghx/BitChord): upstream's latest
release + `patches/*.patch`, built and signed by CI, installed through the app's own updater.
This file is the hand-over: read it before touching the patches. Deeper background is in `docs/research/`.

## Layout

- `patches/` — the fork, as `git format-patch` output; `patches/BASE` = the upstream tag they were made on.
- `scripts/setup-fork.sh` — clones upstream next to this repo (`../fork`) and rebuilds branch `personal` from the patches.
- `scripts/export-patches.sh` — writes branch `personal` back into `patches/`.
- `.github/workflows/build.yml` — every 6 h: `git am patches/*.patch` on `patches/BASE`, `git rebase` onto upstream's newest release tag → signed APK → GitHub Release. A push to `patches/**` also builds. Keeps itself alive past GitHub's 60-day cutoff. Never rename it: `run_number` (the revision) restarts at 1.
- `docs/research/` — today's reports: lookahead design, Automix, PR #932 review, fork review, addon backends, QOL sweep.

## New PC setup

1. JDK **17** (Gradle 8.11.1 does not run on JDK 25; Fedora packages only 21/25, this PC has Temurin in `~/.jdks/jdk-17.0.19+10`).
   `sdkmanager "platforms;android-36" "platforms;android-37.0" "ndk;27.0.12077973" "cmake;3.22.1"` (NDK = AGP 8.10.1's
   default, no `ndkVersion` is set; CI installs the same). `git config --global user.name/user.email` (`git am` needs a committer).
2. AGP 8.10.1 wants `platforms/android-37`, but sdkmanager installs `android-37.0`. Copy it to `android-37` and set
   `AndroidVersion.ApiLevel=37` in `source.properties` and `platforms;android-37` / `<api-level>37</api-level>` in `package.xml`.
3. `scripts/setup-fork.sh` → `../fork` on branch `personal` (refuses an existing `personal`: export first, or `FORCE=1`).
   Add `local.properties` (`sdk.dir=…`).
4. Signing key: private repo `akunieminen/bitchord-signing` → put `keystore.properties` (fix `storeFile` path) in `../fork`.
   Every APK must be signed with this key or Android refuses the update. CI has it as repo secrets. A wrong `storeFile`
   does not fail the build: it writes `…-release-unsigned.apk` and leaves any old signed APK in place.

## Change loop

```sh
cd ../fork                                   # branch personal
# edit, then commit (one concern per commit; prefix "fork:" or "fix(...):")
apk=app/build/outputs/apk/prod/release/app-prod-arm64-v8a-release.apk
rm -f "$apk" &&                              # a killed build can't leave an old APK to install
JAVA_HOME=<jdk17> ./gradlew :app:assembleProdRelease -Pbitchord.forkRevision=7 -Pbitchord.bundleWear=false &&
~/Android/Sdk/build-tools/36.0.0/aapt2 dump badging "$apk" | head -1 &&   # CHECK versionName
adb install -r "$apk"
cd ../bitchord-personal && git pull --rebase && scripts/export-patches.sh && git add -A && git commit -m "…" && git push   # CI publishes
```

- Local test builds use `forkRevision` 1–99; CI uses `100 + run_number`, so a CI release always outranks a local build
  and the in-app updater offers it. Version = upstream base padded to 3 parts + `.rev` (1.8.1.102).
- Always check the APK's versionName before installing: a Gradle daemon that dies under memory pressure leaves the
  previous APK in place, and `adb install` will happily reinstall it.
- `e: … Module was compiled with an incompatible version of Kotlin` from `:sharedUi:lintVitalAnalyzeRelease` is noise.
- `v1.8.1` is both a tag and a branch upstream: use `refs/tags/v1.8.1` in git commands.
- Upstream cuts releases from version branches, not `main` (v1.8.1 was 59 commits ahead of main). Base on tags.
- **Export and push after every fork commit that goes on the phone.** CI builds only `patches/`, and its
  revision (100+) outranks local builds, so the updater offers an older CI build over a newer local one.
- New upstream release: `git fetch origin tag vNEW`, `git rebase --onto refs/tags/vNEW refs/tags/vOLD personal`,
  resolve, build, `scripts/export-patches.sh vNEW`, push. Needed when a patch breaks (CI fails and GitHub emails)
  **and** when CI built vNEW fine: the phone then has vNEW's higher versionCode (1.8→1.8.1 went 26→29), so a vOLD
  build fails `adb install` with `INSTALL_FAILED_VERSION_DOWNGRADE`. The export script refuses a tag `personal` isn't on.
- PR #932 merged upstream unchanged: the rebase (and CI) drops its three commits itself. Merged with edits: the rebase
  stops at "feat(settings)…" — `git rebase --skip` those three, then re-resolve the later PR-932/upgrade-crossfade patches.
- The CI keepalive pushes an empty commit to `main` after 50 quiet days: `git pull --rebase` before pushing.
- Imports are the most common rebase conflict: in upstream files, prefer a fully qualified name over a new import.

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
| Addon lookahead: ADDON joins `prefetchSubstitute`; pins next **and** next+1 (`pinSubstitute`: first pin wins, re-stamp, no pin over YouTube bytes, misses remembered 10 min); the lookahead and tapped-track races prefer a plain file over a DASH/HLS manifest (a manifest-only answer is the last resort); 2 s read-ahead; read-ahead while paused | `SourceResolver.kt`, `AudioCache.kt`, `PlaybackService.kt` |
| Upstream bug: read-ahead checked the plain key but wrote `#alt` → stopped at 64 kB; whole-file length from `Content-Range` | `AudioCache.kt` |
| Head start: an unpinned open waits `headStartMs` (4 s) for the addons before YouTube; skipped for known misses | `PlaybackService.resolveWithModulePriority` |
| No upgrade after a blend (only when the smooth swap is off) | `PlaybackService.kt` (`blendedIn`) |
| PR #932 (3 commits, unmodified) + fork fixes (position, version-swap contention, queue carry-over, lag compensation, linear gains) | `PlaybackService.kt`, `CrossfadeController.kt` |
| Keep mix tempo after beat-matched Automix (the speed reset was an audible stop) | `CrossfadeController.kt` |
| AutoPlay length setting (25) + load more 10 rows before the queue's end (`QueueEndHook` → `ACTION_LOAD_MORE_AUTOPLAY`) | `Autoplay.kt`, `PlayerQueue.kt` (sharedUi), `PlayerConnection.kt`, `PlaybackService.kt`, `MainActivity.kt` |
| Audio sessions: two fixed sessions, both advertised to effect apps | `PlaybackService.kt` |
| QOL: BT reconnect resume, unplayable toast, sleep fade + 5/10 min, source on stats line | `PlaybackService.kt`, `SleepTimer.kt`, `PlayerControls.kt` |
| Updater → this repo; `.forkRevision` versionName; TrackLog to logcat | `AppUpdateChecker.kt`, `app/build.gradle.kts`, `AndroidStreamHooks.kt` |
| Upgrade swap: offset measured on the audio (`VersionAudioAligner.findRenditionOffsetMs`, decodes both cached heads), then the muted standby is **speed-nudged** to within 20 ms (seek aimed ahead by a learned seek lag, never re-seeked) and a 150 ms blend; no fade at all if it can't align; 5 misses end the re-offers | `PlaybackService.kt` (`seamlessSwapToStream`, `measureUpgradeOffset`), `VersionAudioAligner.kt` |
| `#src` key: a track whose `#alt` holds a kept YouTube copy *and that an addon has served* (`bc_addon_has` flag) is filed under `#src`, so replays (Listen again) start from the addon; memoized per process, never chosen offline | `AudioCache.kt` (`substituteKey`, `recordServed`, `completeSibling`) |
| Loudness for pinned tracks: one YouTube resolve per minute for the current and next track, only for the loudness figure | `PlaybackService.ensureLoudnessFigure` |
| Final audit (2026-10-20, 29 fixes): lapsed pins honoured for their own entry; a pin barred by the cellular ceiling dropped only if no entry holds its bytes; `#src`→`#alt` when YouTube wins a replay; no pins for local/SMB/WebDAV or while casting; one upgrade swap owns the standby, hands it back before a crossfade arms; sleep fade in the loudness stage; reconnect resume and AutoPlay load-more re-check when they fire | `AudioCache.kt`, `StreamChoice.kt`, `PlaybackService.kt`, `CrossfadeController.kt`, `PlayerQueue.kt` |
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
  splices two files — hence "first pin wins". A lapsed substitute pin is still honoured while its entry holds (or is
  filling with) addon bytes (`AudioCache.pinFor`, `StreamChoice.lapsed`): a dead URL then 403s into recovery.
- An entry's first 5 MB (Media3's CacheDataSink fragment) is not a span until committed: "is this entry in use" is
  the `bc_origin` tag `recordServed` writes before the first byte (`AudioCache.fillerOf`), not `getCachedSpans`.
- Only the queue's lookahead asks addons (`prefetchSubstitute(withAddons = true)`); the search top-result warm-up is
  upstream's (JioSaavn only), because it overwrites pins.
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

Review leftovers (see `docs/research/04-fork-review.md`, `06-qol-sweep.md`): the next+1 pin runs inline before the
URL warm-up; head start vs `ARM_LEAD_MS` when Automix is on; an upgrade swap vs an *Automix* arm point (plain crossfade
is handled); queue edits while paused keep reading the old next; TV builds poll this repo; `#src` copies the old build
already duplicated stay until LRU eviction; a signing secret equal to the word `bitchord` masks it in CI logs. Final-audit critic's open nice-to-haves: Advanced
Automix phase lock drops the kept tempo; AutoPlay load-more can still fire from the Now-playing auto-scroll with queue
history on and <18 tracks ahead; `StreamChoice.isSubstitute` stays true for an expired addon choice; an upgrade
started <34 s before the end downloads a head it then abandons; no unit tests for `StreamChoice.lapsed`/`msBeforeArm`.

Upstream candidates — **ask the owner before posting anything public**: the 64 kB read-ahead fix; PR #932's
restart-at-0:00 bug; the audio-session bug above.

## Addon backends: what to add and in what order

| Backend | What it proxies | Works? | Median search + stream | Match rate (7 songs) | Quality | Range / URL expiry | Verdict |
|---|---|---|---|---|---|---|---|
| **Current bridge** (`bitchord-lossless-bridge…workers.dev`) | Monochrome/Tidal, then GD Studio (Kuwo/NetEase), then Internet Archive. Checks every file is real FLAC. | Yes | 3.8 s + 0.9 s ≈ **4.7 s**. 1 in 3 searches took 9–16 s. | 7/7 | All FLAC. 3/7 24-bit (up to 24/88.2), the rest 16/44.1. Get Lucky's Tidal copy is AAC, so it fell back to GD (16-bit, sometimes 24-bit via NetEase, 2–5 s). | 206. Monochrome links never expire. GD/NetEase links last about 25 min. | **Keep, as #2** |
| **qobuz-addon.vercel.app** | Qobuz (signed Akamai links). Falls back to Monochrome when Qobuz misses. | Yes | 0.73 s + 0.38 s ≈ **1.1 s**. Repeat queries come from cache in 0.05 s. | 7/7 | All FLAC. **6/7 24-bit** (24/44.1 to 24/96). The one 16-bit result (Dreams) came from a duplicate row; the row the app would pick is 24/96. | 206. Qobuz links expire after about 1 h. | **Add, as #1** |
| gglos.ggottes.deno.net/s1 | Monochrome only (same catalogue as the bridge) | Yes | 1.43 s + 0.31 s ≈ 1.7 s. One cold search took 6.9 s. | 7/7 | 5 FLAC (3 at 24-bit). **Get Lucky's album cut is AAC 320.** | 206, never expires | Skip |
| gglos.ggottes.deno.net (root) | Same as /s1, plus `tidal:` rows that always fail | Yes | 2.36 s + 0.30 s ≈ 2.7 s. The failing rows waste 0.3–4.5 s each. | 7/7 | Same as /s1 | 206, never expires | Skip |
| OreoMuncher …/manifest.json | Old-style module list (Monochrome + archive.org), not an addon | Saves only as a "Custom module" | Not measured in the app (the services behind it took about 1.6 s) | 6/7 FLAC | 24-bit where Tidal has it. Rejects Get Lucky. archive.org results are noise. | 206, never expires | Skip |
| deezer.nom.deno.net/u/<token>… and /u/<token> | Probably Deezer | **Dead**: the whole project is suspended (503 USAGE_EXCEEDED) | – | – | At best 16/44.1 even when it works | – | Skip |
| lastbabe-addon.de.deplexo.com | Nothing deployed | **Dead** (404 "App not found") | – | – | – | – | Skip |

The "Says" test target of about 550 s was wrong; the real track is 498 s. Every working backend found the correct 498 s recording, so I counted it as a match.

### What to add, in order
1. **`https://qobuz-addon.vercel.app`**: drag it to the top. It is the fastest and has the most 24-bit. At about 1.1 s it fits easily inside the app's ~4 s wait when you tap a track, so it wins nearly every race. Its streams only say `quality: "LOSSLESS"`, but v1.8.1 reads that label as FLAC (`AddonSource.kt:387`). So the app treats them as final and won't swap tracks mid-song.
2. **Current bridge**, second. It is slower, so it only wins when Qobuz has nothing. It adds GD Studio and Internet Archive coverage, and it never passes AAC off as FLAC. Qobuz has `allowDownloads: 0`, so **downloads will come from the bridge**.

**Settings for each addon:** there is nothing to set, because the app has no per-addon settings screen. It sends `quality=lossless` to both automatically. That is Qobuz's top tier, and it still returned 24-bit. The bridge also gets its default `prefer=studio`.

**App-wide settings:**
- Set the quality ceiling to **Lossless on both Wi-Fi and mobile**. "High" turns off every addon.
- Leave JioSaavn off.
- Leave addon lookahead on (the default).
- Dolby Atmos makes no difference with these two, since neither serves Atmos.

**Qobuz caveats:**
- It looks like a free proxy running on one shared Qobuz account, so it could disappear or get rate-limited. The bridge behind it covers that.
- Its links expire after about 1 h. The app fetches a fresh link after 5 min anyway, so only a pause of over an hour needs a new lookup.
- Untested: whether its Monochrome fallback filters out AAC the way the bridge does.

### What to skip and why
- **Both gglos URLs.** They are the same Monochrome catalogue the bridge and Qobuz's fallback already use, so they add no coverage. They are also faster than the bridge, so they would beat it, and sometimes Qobuz on cached searches. What they would win with:
  - AAC 320 for Get Lucky, which plays first and then gets swapped mid-song;
  - 16-bit where Qobuz has 24/96. Any FLAC counts as final, and the app ignores bit depth when comparing.

  They are also set to `checkValidLossless=1`, so they silently turn off on the phone speaker or AAC/SBC Bluetooth. The root URL also has the failing `tidal:` rows. Never add both: /s1 and the root are the same deployment.
- **OreoMuncher.** It saves as a Custom module, which is never looked up ahead of time and runs in a slow script sandbox. It adds no catalogue, and its archive.org module returns unrelated live recordings.
- **Both deezer tokens and lastbabe.** They are dead, and the app refuses to add them. Even when it was up, Deezer would only give 16/44.1, and the two tokens are on the same suspended host.

### Do more addons cost speed or load?
Yes. Every enabled addon is searched for every track: the two queued tracks ahead, the track you open, quality upgrades, and the search screen's top result. The losing addons still get their requests.
- **Load** grows with every addon, whatever the order.
- **Quality:** the race goes to the fastest answer, not the best one. More addons means a better chance that a lossy, 16-bit or wrong copy wins.
- **Dead addons** get retried on every lookup. Failures are never cached, and each one can take up to 20 s.
- **Upgrades and downloads** wait for the slowest addon, and downloads go through addons one at a time in list order.

Order barely matters for normal playback, because it's a race. It does matter for downloads. **Two addons is the right number: Qobuz first, then the bridge.**

Raw probe data is under `/tmp/addon-eval/`.

---

## How the app uses several addons (code reading)

# How BitChord v1.8.1 uses several addon sources at once

Base path: `/home/aku/Documents/bitchord-work/fork/app/src/main/java/com/music/bitchord/`. All paths below are relative to it unless they start with `shared/`. This comes from reading the code only, with no network calls.

## TL;DR
- **For streaming, all addons are raced, not walked in order.** Every enabled addon is asked at once, and the first acceptable answer wins. List order only breaks ties between answers that arrive in the same sweep.
- **"Acceptable" is a low bar on the live paths.** Any matched stream counts, including a lossy fallback (marked below request) or a stream that doesn't say what it is. So a fast addon with a worse copy beats a slow addon holding hi-res FLAC.
- **Once anything lossless is playing, the search stops.** A fast 16-bit FLAC locks out a slower 24-bit one for that play.
- **Order does matter in two places:** download source selection, and the lossless walk for tracks pinned to JioSaavn. Both go through sources one at a time in rank order.
- **Adding many addons is harmful:** load grows linearly, the chance that a worse copy wins the race goes up, and one slow or failing addon holds up upgrades and downloads.

## 1. Registry: rank, order, eligibility
- `SourceKind.rank` (`data/sources/SourceKind.kt`): ADDON and CUSTOM_MODULE = 0 (`:81`, `:100`), MODULE = 1 (`:127`), JIOSAAVN = 2 (`:137`), YOUTUBE = 3 (`:153`). Every addon always ranks above YouTube.
- `SourceRegistry.active()` (`data/sources/SourceRegistry.kt:186-193`) does four things in this order:
  1. keeps enabled and complete configs (`:226-227`);
  2. drops `awaitsLosslessOutput` (`:191`);
  3. does a stable `sortedBy { kind.rank }` (`:192`);
  4. maps to the cached instances.
- Because the sort is stable, the order among addons is just the order of the stored list.
- `reorderAddons` (`:311-336`) rewrites that stored order. It is called from the drag UI (`ui/screens/SourcesScreen.kt:268-272`). Fixed kinds can't be dragged (`SourcesScreen.kt:217-230`).
- `activeForPlayback()` (`:241-244`) also filters by the connection ceiling (`data/settings/AppSettings.kt:38-46`):
  - LOSSLESS lets every source through.
  - **HIGH excludes every addon**, because `canServeLossless` is true for addons.
  - MEDIUM and LOW leave only YouTube.
  - So **the Wi-Fi and mobile ceilings must both be "Lossless"** for addons to be asked at all on that network.
- `rankedAbove(youtube)` (`data/sources/SourceResolver.kt:749-752`) is the candidate list for all YouTube-queued playback: every enabled addon, plus JioSaavn if it is on.
- Two code comments are out of date. They say sources are "tried in order" (`SourceRegistry.kt:76-78`) and that the registry "walks them in order" (`AddonSource.kt:31`). The live paths actually race them (see section 2).

## 2. Race or walk, path by path
The core is `bestAcross` (`SourceResolver.kt:807-859`):
- It starts `async` `matchAndStream` for **every** source at once (`:816-829`).
- It loops on `select { onAwait }` (`:833-835`). In kotlinx, `select` favours the first-listed clause, which follows rank order.
- It also folds in any other source that has already finished (`:840`) and keeps the best by `isBetter`. A candidate replaces the current best only if strictly better (`:846`), so on a tie the earlier-ranked one wins.
- With `waitForAll=false` it breaks on the **first non-null** answer (`:853`) and cancels the rest (`:856`).

| Path | Who is asked | Raced or walked | When it stops |
|---|---|---|---|
| **(a) `prefetchSubstitute`** (`:324-339`). Called by read-ahead for the next track and, with `pinTwoAhead`, the one after (`playback/AudioCache.kt:1282`, `:1303-1304`, `:1355-1362`), and by the search screen's top result (`ui/MainViewModel.kt:2356-2393`) | JioSaavn plus addons when `ForkSettings.addonLookahead` is on (default on, `data/settings/ForkSettings.kt:30`) (`:328-331`) | Raced, `waitForAll=false` | First non-null answer, which gets **pinned** in StreamChoice. At open time a pinned stream skips the race entirely (`playback/PlaybackService.kt:1511-1560`) |
| **(b) open-time race**: `resolveWithModulePriority` → `substituteForYouTube` (`PlaybackService.kt:5476-5620`, `SourceResolver.kt:252-272`) | All of `rankedAbove(youtube)` | Raced across addons. YouTube resolves in parallel (`:5504`). Addons get a `headStartMs` = 4 s head start (`:5516-5517`, `ForkSettings.kt:63`), then `select` against YouTube (`:5518-5531`). The whole lookup is capped at 20 s (`:5498`, `SUBSTITUTE_TIMEOUT_MS` `:9123`) | First non-null answer. If YouTube wins, the still-running lookup is handed to QualityUpgrade as `inFlight` (`:5612-5617`) |
| **(c) `upgradeFor`** (`SourceResolver.kt:392-455`), via `QualityUpgrade.lookAgain` (`playback/QualityUpgrade.kt:465-503`). It first checks the handed-over `inFlight` result | Every source above YouTube except the one already serving (`:430`) | Raced, but `waitForAll=true` (`:433`) means it **waits for every source** before choosing. Also `strictLength` ±2 s and `requireSharedArtist` (`:434-435`) | After all sources finish. The best by `isBetter` among answers that pass `worthSwapping`. No overall timeout (`PlaybackService.kt:4375-4377`) |
| `resolve()` for a source-pinned row (`:163-227`) | Pinned source first. If the pin can't serve lossless (in practice a JioSaavn row), **addons are walked one by one in rank order** (`:185-200`). If the pin fails, `bestAcross` over the rest (`:221-224`) | Walked, then raced | First genuinely lossless answer (`:196`) |
| `forDownload` (`:535-668`) | Lossless-capable sources (addons) | **Walked one by one in rank order** (`:616-646`). Lossy sources are raced alongside (`:582-610`). Budget is 85 s (`download/Downloads.kt:1360`) | First lossless or Atmos answer wins outright, and nothing else is asked (`:630-639`) |

## 3. What "clears the bar" means
- **Matching** (`matchAndStream`, `:882-943`):
  - Queries come from `TrackMatcher.queries`: "title artist", then "title", plus an extra query in the other script for kana titles (`shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/sources/TrackMatcher.kt:83-102`).
  - Up to 15 rows per query (`SourceResolver.kt:1144`) are scored by `TrackMatcher.score`. Title and version markers must agree, the artist must be credited (a credit mismatch is only excused if runtimes agree within 2 s), and the duration must be within 30 s (`TrackMatcher.kt:205-296`, `:694-705`, `:798`).
  - `preferred` keeps only candidates within ±3 s if any exist, and puts Atmos first, then LOSSLESS-tier rows (`SourceResolver.kt:990-1014`).
  - The live paths use the loose duration window. Only the upgrade and download paths use `strictLength` ±2 s (`:936-938`, `:1165`).
- **Per source** (`streamBest`, `:1025-1070`):
  - Opens up to 3 matching rows (`:1154`).
  - On a Lossless request it accepts the first stream that is `isLossless`, Atmos, **or `statesNothingLossy`** (no codec and no kbps, `:1045`, `:1114-1115`).
  - Otherwise it returns the best lossy fallback, marked below request (`:1067-1069`).
  - **That fallback is non-null, so it wins the race in (a) and (b).**
- **Ranking between answers**: `isBetter` (`:1085-1100`) orders Atmos, then lossless, then kbps. **It ignores bit depth and sample rate.** Two FLACs tie unless the addons state a kbps (`AddonModels.kt:389-390`).
- **The lossless request**: `requestForNow()` gives `Lossless` when the ceiling is LOSSLESS (`:55-71`). The addon tier becomes `quality` (`AddonSource.kt:413-419`). `quality` is negotiated against the manifest's option *values* (`AddonClient.kt:204-216`, `matchTier` `:282-292`):
  - First an exact match on `LOSSLESS`.
  - Then the first option, in manifest order, containing a lossless word (`:424`).
  - Then `options.first()`.
  - This **overrides the manifest default**. So an addon offering `HI_RES_LOSSLESS` and `LOSSLESS` gets `LOSSLESS`, which is the CD tier.
- **Upgrade bar**: `worthSwapping` (`:700-711`):
  - Never swaps away from Atmos.
  - Lossless or Atmos always passes.
  - Lossy needs at least `UPGRADE_MIN_GAIN_KBPS` = 96 kbps (`:1200`) more than what is playing. If the playing bitrate is unknown, lossy never passes.
- **When an upgrade is attempted at all**:
  - The pinned path checks `isLossless != true` (`PlaybackService.kt:1545-1547`).
  - The race path checks `belowRequest` (`:5588-5602`).
  - Follow-ups only happen for non-lossless, non-Atmos streams (`QualityUpgrade.kt:106-109`).
  - So **any FLAC, even 16-bit, is final.** An undescribed stream that won the race is also never upgraded on the race path, because it is not marked below request.

## 4. Load per played track, per enabled addon (defaults: Lossless ceiling, lookahead on, two-ahead on)
- **Manifest**: at most 1 per 10 min (`AddonClient.kt:480`). It is shared through `SharedCalls`, and `admitted()` and `settingsFor()` read the cache (`AddonSource.kt:87-91`, `AddonClient.kt:205`).
- **Search**: usually 1. A second ("title only") is sent only if no row matched, and a third only for kana titles (`SourceResolver.kt:890-941`). Results are cached for 10 min (`AddonClient.kt:483`), keyed on query plus all parameters (`:137-146`). That cache is shared by prefetch, the open race, upgrades and downloads.
- **Stream**: 1 call if the first row is lossless or undescribed, up to 3 if rows come back lossy (`:1154`). Cached for 5 min (`AddonClient.kt:493`).
- **Losers aren't spared.** Every addon is searched for every track no matter which one wins. Cancelling a loser only stops its *next* call. A call already sent still completes in the client's own scope (`AddonClient.kt:48`, `module/SharedCalls.kt:91`).
- **Upgrade pass**: only when the first stream wasn't lossless or Atmos. Every non-serving addon then gets roughly 1–3 stream calls (the search is usually a cache hit).
- **Failures cost more.** Failures are never cached (`SharedCalls.kt:97`). `AddonSource.search` turns a failure into an empty list (`AddonSource.kt:195-198`), so the resolver moves on to the next query. A down addon therefore gets about 2 searches **on every lookup**: prefetch ×2, open, upgrade, and search-screen top result. Each can take up to the 20 s `callTimeout` (`AddonClient.kt:520-524`). A 429 is retried twice with 0.5–8 s backoff (`:357-372`, `:495-497`).
- **Extra triggers**:
  - the search-screen top result (`MainViewModel.kt:2356-2393`);
  - the manual "Upgrade quality" button, which clears the caches (`SourceRegistry.kt:260-264`, `PlaybackService.kt:4448`);
  - health checks on the Sources screen (manifest only).

## 5. Does a slow or failing addon delay the others?
- **Prefetch and the open race: no.** Sources run concurrently, and a failure is just a null result (`attempt`, `:1126-1133`). But a *fast* addon with a worse answer preempts the others. The code admits this trade-off at `:370-374`.
- **Upgrade: yes.** `waitForAll=true` (`:433`, `:853`) waits for the slowest addon even when a FLAC is already in hand. With no outer timeout, the seam lands later in the song.
- **Downloads and the JioSaavn-pin walk: yes.** They go one source at a time in rank order (`:616`, `:186`), so a slow or failing addon early in the list costs its full timeouts.

## 6. `checkValidLossless` gating
- The flag is stored on the config (`SourceRegistry.kt:46-57`). It is set when the addon is added (`:389`) and refreshed whenever the manifest is read (`AddonSource.kt:93-94`, `SourceRegistry.kt:210-223`).
- While no lossless output is detected (`playback/audio/LosslessOutput.kt:63`: wired, USB, HDMI, dock, or Bluetooth on LDAC/LHDC/aptX Lossless), the addon is removed from `active()` (`:191`). It gets zero requests for playback and downloads alike.
- `AddonSource.admitted` checks again before every request (`AddonSource.kt:75-91`).
- The Sources row shows it as waiting for an output (`SourcesScreen.kt:244`), with a Bluetooth-permission prompt (`:286-290`).
- So with phone speakers or AAC/SBC Bluetooth, a gated addon silently drops out.

## 7. Per-addon settings UI
- **There is none.** The manifest's `settings` are read only for their defaults and their `quality` options (`data/sources/addon/AddonModels.kt:47-61`, `:101-118`).
- Every declared default, such as `prefer`, is always sent. `quality` is overwritten by the negotiation in section 3. `atmos=auto` is added when Dolby Atmos is on in Settings and the device can decode it (`AddonClient.kt:231`, `:268-271`).
- **The only way to choose non-default settings** is an addon whose configure page bakes the choice into the URL path (the `/u/<id>` style).
- Settings in a query string break things. `manifestUrl` appends `/manifest.json` after the query (`AddonClient.kt:456`), so the manifest fetch and quality negotiation fail.

## Conclusion
- **Does order matter?** Barely for streaming: speed decides, and rank only breaks same-sweep ties. It **does** matter for downloads and the JioSaavn-pin walk, where the first lossless answer in list order wins outright.
- **Best ordering**: put the **best-quality and most reliable** addon first. Ideally that is one serving direct 24-bit FLAC, like the current bridge. Ordering "fastest first" achieves nothing, because the race already favours speed. What matters for streaming is **which addons are enabled at all**.
  - A second, fallback addon is only safe if it is **slower** than the primary on tracks both hold, or serves equal or better quality. Otherwise it wins races with a lesser copy.
  - Any addon that answers 16-bit FLAC faster than the hi-res one will lock in 16-bit, because lossless is final and `isBetter` ignores bit depth.
  - Also leave JioSaavn off (its default, `SourceRegistry.kt:40`). Its roughly 0.4 s 320 kbps answer wins the race and forces a mid-track swap.
- **Are many addons harmful?** Yes:
  - load multiplies by N, regardless of order;
  - more addons raise the chance that a lossy, 16-bit, undescribed or wrongly matched copy wins (the live match window is 30 s);
  - dead addons get re-hit on every lookup;
  - the slowest addon holds up upgrades and downloads.
  - Two entries that front the same service (for example two tokens on the same host, or `/s1` and the root of the same deployment) only double the requests, for no extra coverage.
- **Recommendation**: 1 primary hi-res addon, plus at most 1 fallback chosen for catalogue gaps, after checking that it is slower or equal in quality. Set both Wi-Fi and mobile ceilings to Lossless. Turn Dolby Atmos off in Settings if you always want FLAC, because Atmos ranks above lossless (`SourceResolver.kt:1097`).
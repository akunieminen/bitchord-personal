## Regressions from fork commits

1. **Volume normalization is skipped for addon-pinned tracks.** Caused by 926e159 (`fork: addon lookahead …`).
   - At `AudioCache.kt:1330` the fork added `|| StreamChoice.isSubstitute(id)` to the warm-up skip. Upstream v1.8.1 (`:1302`) only had `id == next && warmed != null`.
   - `pinTwoAhead` (on by default) pins the track after next right away (`:1317-1319`), before the warm-up loop runs 2 s later. So every AutoPlay track that Qobuz or the bridge serves never gets a YouTube lookup. With no lookup there is no loudness figure, so it plays at gain 1 (`PlaybackService.kt:7147-7158`).
   - On the JBL you hear this as a jump of several dB between levelled and unlevelled songs.
2. **Loading more AutoPlay freezes the UI.** Caused by 3f6790d and f255d10 (the 25-track batches and load-more).
   - `loadMoreAutoplay` (`PlaybackService.kt:2949-2971`, fork-only code) runs the regex de-dup on `Dispatchers.Main`.
   - At about 250-300 queued tracks this freezes the UI for 0.3-0.6 s (session1.log:8403-8408, "Skipped 36/32 frames").
3. **Minor, only when Automix is on:** 926e159 and 00bc478 expose a stale 5 s memo of cache entries (`AudioCache.kt:158/1997`). It re-downloads about 3 MB per analysis that is then thrown away. Nothing happens while Automix is OFF; it's in the low-value list.

## Top items

| # | Title | What you notice | Size | Files | Risk |
|---|---|---|---|---|---|
| 1 | **[REGRESSION] Volume levelling for addon-pinned tracks** | Volume jumps several dB between songs on the JBL | 1 line (full fix ~28) | AudioCache.kt (a line only the fork owns); full fix: PlaybackService.kt | Very low |
| 2 | **[FORK-CAUSED] AutoPlay de-dup off the main thread** | No 0.3-0.6 s freeze when the queue loads more | ~10 | Autoplay.kt, PlaybackService.kt (`loadMoreAutoplay`, fork-only) | Low |
| 3 | Hi-res FLAC buffer stops dropping to under 0.5 s | Fewer dropouts and rebuffers on tapped or streamed 24-bit tracks | 1 | PlaybackService.kt `:6525-6534` | Low; uses more memory (about 45-65 MB) |
| 4 | Resume when the Bluetooth speaker reconnects | The JBL drops out, comes back within 10 min, and music continues | ~26 | PlaybackService.kt, ForkSettings.kt, ForkTweaksGroup.kt | Low |
| 5 | Long-press a queue row for the track menu | Like, add to playlist, dislike or open the artist of an upcoming AutoPlay track | ~14 | QueueEndHook.kt, PlayerQueue.kt, MainActivity.kt | Low |
| 6 | Source name on the stats line | "Qobuz · FLAC · 24-bit · 96.0 kHz …" without opening a dialog | 3 | PlayerControls.kt | Very low |
| 7 | Toast when a track is skipped as unplayable | "Couldn't play 'X' — skipped" instead of a song silently vanishing | ~10 | PlaybackService.kt | Very low |
| 8 | Sleep timer fades out over 15 s, plus 5 and 10 min presets | No dead stop mid-song | ~17 | SleepTimer.kt, PlaybackService.kt `watchSleepTimer` | Low |
| 9 | Double-tap the artwork to seek ±10 s | YouTube Music gesture for re-hearing a line or skipping an intro | ~16 | NowPlayingScreen.kt | Medium (large file upstream edits often) |
| 10 | Playlist Reorder page shows songs past 100 | Can reorder long playlists, and the saved order is correct | ~6 | InnertubeParser.kt (shared/) | Low |
| 11 | Save queue as playlist | Keep a good AutoPlay run | ~40 | QueueEndHook, PlayerQueue, 2× strings, MainActivity, MainViewModel | Medium |
| 12 | Start radio from a playlist | Endless mix seeded by a whole playlist | ~40 | Innertube, YtMusicRepository, Autoplay, BrowseActionsSheet, MainActivity | Medium |
| 13 | Opt-in: keep complete addon FLACs in the cache | Replays start instantly from disk in FLAC and work offline (needs a 2-4 GB cache) | ~14 | AudioCache.kt, ForkSettings.kt, ForkTweaksGroup.kt | Low-medium |
| 14 | "Remove from history" on History rows | Clean up signed-in history and recommendations | ~51 | InnertubeParser, YtMusicRepository, MainViewModel, SongActionsSheet, MainActivity, strings | Medium |

Two pairs share code and should be done together:
- 4 and 13 both add a ForkSettings toggle and a ForkTweaksGroup row.
- 5 and 11 share the QueueEndHook hook and the MainActivity `DisposableEffect` at `:924-927`.

## Implementation notes

**1. Volume levelling regression**
- **Minimal fix, a line only the fork owns:** at `AudioCache.kt:1330` replace the line with:
  ```kotlin
  if ((id == next && warmed) || (StreamChoice.isSubstitute(id) && !AppSettings.loudnessNormalization.value)) continue
  ```
  - `AppSettings` is already imported (`:28`).
  - This restores upstream's per-track YouTube lookup for the track after next. Every queue track then has its figure before it becomes next.
  - The pin still serves the bytes: `PlaybackService.kt:1516` checks the pin first.
- **Full fix, if volume still jumps:** this covers the first next after a tap, Play next, and cached tracks after a restart (upstream #562).
  - Port the warm-up from closed PR #582 into `PlaybackService.kt`, next to `scheduleLoudnessRetry` (`:7201`).
  - For the current and next item with a `bitchord://watch` URI and no figure yet (`StreamResolver.loudnessDbFor(id) == null`), try at most once per 60 s per id (a `ConcurrentHashMap<String, Long>`): `scope.launch { runCatching { withContext(Dispatchers.IO) { StreamResolver.resolve(id) } }; if (player?.currentMediaItem?.mediaId == id) publishLoudnessFor(id) }`. `scope` is already Main (`:706`).
  - Call it in three places: after `:1144` (`activeLoudness().nextMediaId = …`), after `scheduleLoudnessRetry(...)` at `:3479`, and inside the `loudnessNormalization.collect` block at `:7055-7058`.

**2. AutoPlay de-dup off the main thread**
- In `Autoplay.kt`:
  - Add imports `kotlinx.coroutines.Dispatchers` and `kotlinx.coroutines.withContext` (only `CancellationException` is imported now, `:13`).
  - Change `:108` to `val extra = withContext(Dispatchers.Default) { QueueBuilder.extend(existing, related, limit) }`. This also covers upstream's top-up.
- In `PlaybackService.kt`, replace `:2964-2967` with:
  ```kotlin
  val now = player?.let { p -> (0 until p.mediaItemCount).map { p.getMediaItemAt(it).toSong() } } ?: return@launch
  val (fresh, items) = withContext(Dispatchers.Default) {
      val f = more.filterNot { song -> now.any { QueueBuilder.isSameRecording(it, song) } }
      f to f.map { it.toMediaItem() }
  }
  val latest = player ?: return@launch // a source crossfade may have swapped players meanwhile
  if (items.isNotEmpty()) latest.addMediaItems(items)
  ```
  Keep the `sessionSongHistory += fresh` and TrackLog lines.
- Left out: normalizing each title once inside QueueBuilder. That file is shared with upstream.

**3. Hi-res buffer**
- In `PlaybackService.kt`, in `farBufferingLoadControl` (`:6525-6534`), add `.setPrioritizeTimeOverSizeThresholds(true)` before `.build()`.
- Use the generic setter, not `…ForStreaming`. The streaming variant stops `build()` from copying the custom start, resume and max durations to local playback.
- The cause: the 8 MB ceiling (`:9154`) is smaller than the 30 s back buffer (`:9160`) at 24/96 and above, so the buffer ahead drains to almost nothing about every 14 s. With the flag it stays about 50 s ahead.
- Check before and after with `adb logcat -s DefaultLoadControl` while a 24/96 track streams (tap a song that hasn't been read ahead):
  - Before the fix, "Target buffer size reached with less than 500ms…" should repeat about every 14 s.
  - After the fix it should be gone.

**4. Resume on Bluetooth reconnect**
- `ForkSettings.kt`: add `val resumeOnReconnect = Toggle("resume_on_reconnect", true)` and add it to the `listOf(...)` at `:68`.
- `PlaybackService.kt`:
  - Add the field `private var noisyPausedAt = 0L` next to `outputDeviceCallback` (`:538`).
  - As the first line of `onPlayWhenReadyChanged` (`:953`): `noisyPausedAt = if (!playWhenReady && reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY) SystemClock.elapsedRealtime() else 0L`.
  - At the end of `onAudioDevicesAdded` (`:539-546`):
    ```kotlin
    val pausedAt = noisyPausedAt
    if (ForkSettings.resumeOnReconnect.value && pausedAt != 0L &&
        SystemClock.elapsedRealtime() - pausedAt < DEFAULT_FOREGROUND_SERVICE_TIMEOUT_MS &&
        addedDevices.any { it.isSink && it.type in setOf(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLE_SPEAKER, AudioDeviceInfo.TYPE_BLE_HEADSET) }
    ) {
        noisyPausedAt = 0L
        // ponytail: fixed 1.5s for the A2DP route to settle; tune if the first note leaks to the phone speaker
        scope.launch { delay(1_500); mediaSession?.player?.takeIf { !it.playWhenReady }?.play() }
    }
    ```
  - The 10 min window is Media3's foreground-service timeout. After it, `play()` from the background could be blocked.
  - Any other `playWhenReady` change (user pause, sleep timer) resets `noisyPausedAt`, so it cancels the pending resume.
- `ForkTweaksGroup.kt`: add `RowDivider()` and `ToggleRow(Icons.Rounded.Bluetooth, "Resume on reconnect", "Speaker back within 10 min keeps playing", ForkSettings.resumeOnReconnect)`, plus the icon import.

**5. Queue row long-press menu**
- `QueueEndHook.kt`: add `var onRowMenu: (Song) -> Unit = {}` and import `data.model.Song`.
- `PlayerQueue.kt`:
  - Replace `:755` with `.combinedClickable(enabled = !locked, onClick = onClick, onLongClick = { QueueEndHook.onRowMenu(song) })`, with `@OptIn(ExperimentalFoundationApi::class)`.
  - On the drag-handle Icon, add `.pointerInput(Unit) { awaitEachGesture { awaitFirstDown(requireUnconsumed = false).consume() } }`. Without it, holding the handle would open the menu and cancel the drag.
- `MainActivity.kt`: in the `DisposableEffect` at `:925-926`, add `QueueEndHook.onRowMenu = openSongMenu` (defined at `:629`) and reset it to `{}` in `onDispose`.
- Known limits: "Play next" adds a copy instead of moving the row, and Dislike doesn't remove the upcoming row.

**6. Source on the stats line**
- In `PlayerControls.kt`, `describe()` (`:1812-1830`), replace the last line (`:1829`) with:
  ```kotlin
  if (parts.isEmpty()) return null
  return (listOfNotNull(sourceName?.takeIf { it != "Unknown" }) + parts).joinToString(" · ")
  ```
- The source is only shown once a format has been measured. Before that, `currentSourceName` guesses "YouTube".
- The stats line only shows when Settings > "Show nerd stats" is on.

**7. Toast on unplayable skip**
- In `PlaybackService.kt`, `skipPastUnplayable` (`:4256`), after the mediaId check:
  ```kotlin
  val title = exoPlayer.currentMediaItem?.mediaMetadata?.title ?: "this track"
  val hasNext = exoPlayer.hasNextMediaItem()
  unplayableToast?.cancel() // ponytail: one slot; a run of region-locked tracks replaces rather than queues
  unplayableToast = Toast.makeText(applicationContext, if (hasNext) "Couldn't play “$title” — skipped" else "Couldn't play “$title”", Toast.LENGTH_SHORT).also { it.show() }
  ```
- Use `hasNext` in the existing `if`, and add the field `private var unplayableToast: Toast? = null`.
- The text is hardcoded, so strings.xml isn't touched.

**8. Sleep timer fade and presets**
- `SleepTimer.kt:33`: change to `val PRESETS = listOf(5, 10, 15, 30, 45, 60)` and add `const val FADE_MS = 15_000L`.
- `PlaybackService.kt`, `watchSleepTimer` (`:6468-6480`): replace the `collectLatest` body. Keep the fork's `cancelPrefetch()`.
  ```kotlin
  if (deadline == null) return@collectLatest
  delay(deadline - SleepTimer.FADE_MS - SystemClock.elapsedRealtime())
  try {
      while (true) {
          val left = deadline - SystemClock.elapsedRealtime()
          if (left <= 0) break
          // ponytail: re-applied every tick, so a source swap that resets volume is overridden within 200ms
          player?.volume = (left.toFloat() / SleepTimer.FADE_MS).coerceIn(0f, 1f)
          delay(minOf(left, 200L))
      }
      player?.pause(); SleepTimer.cancel(); cancelPrefetch()
  } finally { player?.volume = 1f }
  ```
- If the timer is extended or cancelled mid-fade, `collectLatest` cancels the loop and `finally` restores full volume. The TV dialog (`TvSongActionsDialog.kt:372`) is left as is.

**9. Double-tap artwork seek**
- `NowPlayingScreen.kt`:
  - Import `detectTapGestures` near `:35-39`.
  - Near `:1441`, add `val seekTo by rememberUpdatedState(onSeek)`.
  - In the card-slot Box (around `:3076-3090`), after `graphicsLayer` and before the `queueOpen || lyricsOpen` clickable:
    ```kotlin
    .pointerInput(queueOpen, lyricsOpen, spotifyCanvasPresentation, controlsLocked) {
        if (queueOpen || lyricsOpen || spotifyCanvasPresentation) return@pointerInput
        detectTapGestures(onDoubleTap = { o ->
            if (controlsLocked) { onBlockedControl(); return@detectTapGestures }
            val back = o.x < size.width / 2
            haptics.play(if (back) Haptic.SkipPrevious else Haptic.SkipNext)
            seekTo(position.positionMs + if (back) -10_000L else 10_000L) // onSeek clamps both ends
        })
    }
    ```
- Upstream declined this (#13), so the patch will stay fork-only.
- Test on the phone that these still work: sideways swipe to skip, swipe up for the queue, swipe down to close, and the Spotify Canvas tap.

**10. Reorder past 100**
- In `InnertubeParser.kt`, `parsePlaylistShelf` (`:526-531`):
  - Make `scope` a `JsonObject` and add `?: root.a("onResponseReceivedActions")?.firstNotNullOfOrNull { it.o("appendContinuationItemsAction") }` after `continuationContents`.
  - Add to `playlistScope`: `?: scope.takeIf { s -> s.a("continuationItems")?.any { it.o("musicResponsiveListItemRenderer") != null } == true }`. This uses the append action as the shelf only when it holds track rows directly, so the Suggestions shelf (wrapped in `musicShelfRenderer`) still works.
- Optional regression test: add one next to `SearchPagingTest.kt:533`.

**11. Save queue as playlist**
- `QueueEndHook.kt`: add `var onSaveQueue: ((List<Song>) -> Unit)? = null`.
- `PlayerQueue.kt`, in the header Row before Clear (`:296`): show an `IconButton(PlaylistAdd)` when the hook is set and `queue.size > currentIndex + 1`. It calls `save(queue.drop(currentIndex))`.
- Add one sharedUi string, `save_queue`.
- `MainActivity.kt`:
  - Add `var queueToSave by remember { mutableStateOf<List<Song>?>(null) }` next to `:641`.
  - Set the hook in the `:925` effect.
  - At `:4442`, extend the picker condition with `|| queueToSave != null`.
  - In onCreate, filter out local, WebDAV, SMB and `SourceRegistry.parseTrackKey` ids, then call `viewModel.createPlaylistWithVideoIds(...)` (`MainViewModel.kt:1073`) and show a Toast (the in-app notice is hidden under the player).
- `MainViewModel.kt`: guard `isSignedIn && videoIds.isNotEmpty()`, so an all-local queue is saved locally instead of as an empty YouTube playlist.

**12. Playlist radio**
- `Innertube.kt` (around `:604`): `suspend fun playlistRadio(id: String) = postMusic("next") { put("playlistId", "RDAMPL" + id.removePrefix("VL")); put("isAudioOnly", true) }`.
- `YtMusicRepository.kt` (around `:557`): wrap it with `parseWatchQueue`.
- `Autoplay.kt`: add `loadPlaylistRadio`, which runs `QueueBuilder.extend(emptyList(), it, limit)` and maps the results to AUTOPLAY-tier entries.
- `BrowseActionsSheet.kt`: add `onStartRadio: (() -> Unit)? = null` and an ActionRow after Shuffle.
- `MainActivity.kt`, in the browseMenuBody call (around `:4565`): load the radio first, then `beginRadioQueue` / `playSongs` / `commitRadioQueue`.
- The strings `start_radio` and `radio_started` already exist.

**13. Keep complete addon FLACs (make it opt-in)**
- `ForkSettings.kt`: add `val keepAddonAudio = Toggle("keep_addon_audio", false)`. The default is false because with the 512 MB default cache, 30-150 MB FLACs would push your cached YouTube songs out.
- Add a ForkTweaksGroup row whose subtitle says to raise the cache to 2-4 GB.
- `AudioCache.kt`:
  - After `:1044`, add `if (foreign && ForkSettings.keepAddonAudio.value && isComplete(key)) return@forEach`. Only complete files are kept; entries the cache has trimmed part of still get deleted.
  - After `:1453`, add `if (isComplete(key)) return true`. This stops a re-pin to a different-sized file from writing past the end of the kept FLAC.

**14. Remove from history**
- `InnertubeParser.kt`, next to `collectSongsDeep` (`:478`): add `historyRemoveTokens()`. It reads the `REMOVE_FROM_HISTORY` feedback token from each row's menu and collects all tokens per videoId, because history has one row per play.
- `YtMusicRepository.kt`:
  - Add a `ConcurrentHashMap<String, List<String>>` of tokens, refilled in `fetchHistory` (`:141`).
  - Add `removeFromHistory(id)`, which sends every token through the existing `Innertube.sendFeedback` (`Innertube.kt:941`).
- `MainViewModel.kt`: add a remove method that also drops the row from `_history`.
- `SongActionsSheet.kt`: add an `onRemoveFromHistory` row after `:296-306`.
- `MainActivity.kt`, next to `onRemoveFromCache` (`:4266`): wire it only on the History route and not from the player.
- Add one string, `remove_from_history`.

## Dropped / low value
These two are low value while Automix is OFF. Both are 2-3 safe lines; do them together if you turn Automix on again.
- **Stale rendition memo:** add `about?.let { renditionKeys.remove(it) }` at the end of `AudioCache.pull()`.
- **CacheMediaDataSource leak:** in `AudioCache.kt:2165` `closeUpstream()`, call `runCatching { dataSource.close() }` without the `if (isOpen)` guard.

Nothing else was dropped. There were no duplicates; items 4+13 and 5+11 only share code.
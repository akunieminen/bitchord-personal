# bitchord-personal

Personal build of [BitChord](https://github.com/kushagrasinghx/BitChord) (GPL-3.0): upstream's latest
release plus the patches in `patches/`. Every song from a lossless addon starts in hi-res, with no
YouTube-to-FLAC cut.

Not affiliated with upstream. Upstream deliberately keeps addon lookahead off to spare shared addon
servers; this build turns it on for one listener.

## How updates work

1. Every 6 h, `.github/workflows/build.yml` checks upstream's latest release.
2. A new release gets the patches applied (on their own base tag, then rebased onto the new one), is
   built, signed with the personal key (repo secrets), and published here as `vX.Y.Z.<100 + run number>`.
3. The app's own updater reads this repo's latest release (patched `AppUpdateChecker`) and offers
   "Install Now".

Pushing a change to `patches/` also triggers a build.

## When a patch stops applying

The run fails and GitHub emails you. To fix it (also do this when the new release built fine, before
your next change: the phone then has the new release's higher versionCode):

```sh
cd ~/Documents/bitchord-work/fork
git fetch origin tag vNEW
git rebase --onto refs/tags/vNEW refs/tags/vOLD personal   # resolve conflicts; rerere remembers them
cd ../bitchord-personal && git pull --rebase && scripts/export-patches.sh vNEW   # replaces patches/*, updates BASE
git add -A && git commit -m "Rebase patches onto vNEW" && git push
```

If upstream merges PR #932 unchanged, the rebase (and CI) drops its three commits by itself.

## Patches

Fork settings live under **Settings → Fork tweaks**.

| Patch | What |
|---|---|
| settings group | the switches below |
| addon lookahead | pins the next two songs to the addon; 2 s read-ahead; keeps reading ahead while paused |
| read-ahead key fix | upstream bug: a pinned substitute was cached only to 64 kB |
| head start | a tapped song waits up to N s (slider) for the addon before starting on YouTube |
| no swap after a mix | a song that crossfaded in keeps its stream for that play |
| keep mix tempo | after a beat-matched Automix the song keeps the matched speed instead of a stop-inducing reset |
| review fixes | no FLAC spliced onto a cached YouTube prefix; read-ahead probes the first missing byte |
| replays from the addon | a song an addon served is cached under its own key (`#src`), so Listen again starts in FLAC |
| rate limits | an addon that was rate limiting or failing doesn't count as a miss; the next song's lookup is retried 3 × 20 s |
| AutoPlay | queue length setting (default 25); scrolling near the end loads more |
| fewer lookups | addon misses remembered 10 min; sleep timer stops read-ahead; resume re-runs it |
| EQ sessions | each player keeps its own audio session, both advertised, so Wavelet-style EQs don't re-attach at crossfades |
| QOL | Bluetooth reconnect resumes; unplayable-skip toast; sleep timer fade + 5/10 min; source on the stats line |
| PR #932 + fixes | an upgrade that still happens mid-song is lined up on the audio (speed nudge to within 20 ms), then a 150 ms blend; no swap if it can't line up |
| updater / version / logs | updates from this repo, `.N` version suffix, TrackLog in logcat |
| final review fixes | a half-cached addon song is finished from its own file after a long pause; searches don't re-pin; one upgrade swap at a time, handed back before a crossfade; sleep fade survives crossfades; AutoPlay load-more only on your own scroll |

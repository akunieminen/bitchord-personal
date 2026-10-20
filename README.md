# bitchord-personal

Personal build of [BitChord](https://github.com/kushagrasinghx/BitChord) (GPL-3.0): upstream's latest
release plus the patches in `patches/`. Every song from a lossless addon starts in hi-res, with no
YouTube-to-FLAC cut.

Not affiliated with upstream. Upstream deliberately keeps addon lookahead off to spare shared addon
servers; this build turns it on for one listener.

## How updates work

1. Every 6 h, `.github/workflows/build.yml` checks upstream's latest release.
2. A new release gets the patches applied (`git am --3way`), is built, signed with the personal key
   (repo secrets), and published here as `vX.Y.Z.<run>`.
3. The app's own updater reads this repo's latest release (patched `AppUpdateChecker`) and offers
   "Install Now".

Pushing a change to `patches/` also triggers a build.

## When a patch stops applying

The run fails and GitHub emails you. To fix it:

```sh
cd ~/Documents/bitchord-work/fork
git fetch --depth 50 origin tag vNEW
git rebase --onto vNEW vOLD personal      # resolve conflicts; rerere remembers them
git format-patch -o ../bitchord-personal/patches --zero-commit --no-signature vNEW..personal
cd ../bitchord-personal && git add -A && git commit -m "Rebase patches onto vNEW" && git push
```

Drop the PR #932 commits once upstream merges that PR.

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
| AutoPlay | queue length setting (default 25); scrolling near the end loads more |
| fewer lookups | addon misses remembered 10 min; sleep timer stops read-ahead; resume re-runs it |
| EQ sessions | each player keeps its own audio session, both advertised, so Wavelet-style EQs don't re-attach at crossfades |
| QOL | Bluetooth reconnect resumes; unplayable-skip toast; sleep timer fade + 5/10 min; source on the stats line |
| PR #932 + fixes | 300 ms crossfade instead of a cut when an upgrade still happens |
| updater / version / logs | updates from this repo, `.N` version suffix, TrackLog in logcat |

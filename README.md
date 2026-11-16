# Hertz

A Nothing OS-inspired focus, relax and sleep sound player for the macOS menu bar.

<p align="center"><img src="docs/hertz.gif" width="336" alt="Hertz's panel playing Lofi, Rain and Sharp, with a live dot-matrix spectrum"></p>

- **Five gapless mixes:** Sharp (40 Hz binaural, use headphones), Brown Noise, Lofi, Rain, Pink Noise
- **Timers:** 25/45/90 minutes or Pomodoro (25/5, 50/10) with chimes
- **Media keys**, a **widget**, and a URL scheme: `hertz://toggle`, `hertz://mix/<id>`

## Install

macOS 14+. Download `Hertz.zip` from the [latest release](../../releases/latest), move `Hertz.app` to Applications, then (the app is unsigned):

```sh
xattr -dr com.apple.quarantine /Applications/Hertz.app
```

## Build

Needs Xcode Command Line Tools, `ffmpeg`, and Python 3 with NumPy.

```sh
python3 tools/make_loops.py   # build audio loops
sh build.sh                   # build, install, launch
sh build.sh release           # universal build → build/Hertz.zip
```

Your own mixes can go in a git-ignored `personal/` folder (see `tools/make_loops.py` and `Sources/Model.swift`).

## License

Code [MIT](LICENSE). Audio credits in [audio/src/CREDITS.md](audio/src/CREDITS.md). Not affiliated with Nothing Technology Limited.

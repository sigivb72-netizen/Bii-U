# Bii-U

A Wii U emulator for iPadOS, tuned for **Bayonetta (Wii U)** on a 10th-gen iPad (A14, 4 GB RAM).

Bii-U is a fork of [MeloCafe](https://github.com/stossy11/MeloCafe) (itself based on [Cemu](https://github.com/cemu-project/Cemu)),
with fixes ported from [EspressU](https://github.com/EspressU/EspressU-Emu), [MuffinEMU](https://github.com/kiddreads/MuffinEMU)
and upstream Cemu. It is licensed under the [MPL-2.0](LICENSE.txt); the copyright notices in the source files are kept.
The on-screen controller package (Melo-Controller) is GPL-3.0.

**No games, keys or firmware are included.** Use your own dumps from your own Wii U.

## Download

Every push builds an unsigned IPA on GitHub Actions (macOS runner) and publishes it as a GitHub Release.
The newest build is always at:

`https://github.com/sigivb72-netizen/Bii-U/releases/latest/download/BiiU.ipa`

Open that link on the iPad (or on your phone and send the file across with AirDrop/Files).
The release notes of each build say what changed and what to test.

## Install (no computer needed)

1. Download `BiiU.ipa` in Safari on the iPad. It lands in Files > Downloads.
2. Open **LiveContainer** > **+** > pick `BiiU.ipa`.
3. Raise the memory limit with **GetMoreRam** for LiveContainer (under LiveContainer, LiveContainer's own
   entitlements apply, not the ones inside the IPA).
4. Enable JIT with **StikDebug** for LiveContainer, then launch Bii-U from LiveContainer.
5. Put your game somewhere in Files and add it from the Bii-U library.

## Diagnostics

* **Settings > Diagnostics > Performance overlay**: FPS, a frame-time graph (green < 20 ms, yellow < 50 ms,
  red > 50 ms), hitches, shader/pipeline compiles, JIT state, audio buffer fill and underruns, cutscene
  video decode time, memory and heat.
* **Share log** (in Settings, or the share icon on the overlay): writes one `.txt` report with device info,
  JIT state, counters, crash logs, breadcrumbs and the emulator log of this and the previous session,
  and opens the iOS share sheet.
* After a crash, the next launch offers to share the log.

## Building

Push to GitHub; `.github/workflows/build-ipa.yml` does the rest. Locally on a Mac:

```sh
git clone --recursive <this repo> && cd Bii-U
brew install ninja ccache xcodegen
ci/build-core.sh                       # Cemu.framework -> build-ios/out
cd MeloCafe && xcodegen generate
xcodebuild -project BiiU.xcodeproj -scheme BiiU -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO build
```

Upstream MeloCafe's README is kept in [docs/UPSTREAM-MeloCafe-README.md](docs/UPSTREAM-MeloCafe-README.md).

# P10 Entrancer

iPad video sampler / live mixer / glitch processor. Hybrid of the Edirol P-10 visual sampler and Korg KAOSS Pad Entrancer, with a simulated NTSC pipeline featuring Archer-Video-Enhancer-style signal-domain glitch FX.

Free, open source (MIT). Targets M2 iPad Pro on iPadOS 17+. Faster iPads perform better; M2 is the floor.

## What it does

- **9 input pads** — each can hold a video file, image, live iPad camera, USB UVC camera feed, or the master output fed back as input
- **Two output channels** with a master mixer (5 transitions: blur crossfade, linear swipe, star swipe, chroma key, luma key) and position fader
- **Per-pad RGB FX** — blur, internal feedback, chroma distort, YUV phaser, luma phaser, edge enhance
- **Pad-to-pad chroma/luma keyer** routable as a virtual channel
- **Simulated NTSC pipeline** with knobs-on-the-signal glitch effects: chroma boost, HSync wobble, subcarrier drift, Y/C delay, dropouts, luma/chroma noise — produces real NTSC artifacts because they happen on the modulated composite signal, not faked in RGB
- **HDMI external display** via USB-C dongle, switchable HD 720p / NTSC 4:3
- **Per-pad audio** mixed to master via AVAudioEngine
- **CoreMIDI input** for note triggers + CC parameter mappings
- **Mix recorder** captures the master output to mp4; tap stop and the recording auto-loads into pad 1

## Project structure

```
project.yml                          xcodegen spec — source of truth for the .xcodeproj
P10Entrancer.xcodeproj/              GENERATED — regenerate via `xcodegen generate`
P10Entrancer/
  App/                               SwiftUI @main + AppState
  Render/                            Metal context, render engine, texture pool
  Sources/                           Pad sources (video / image / camera / UVC / feedback)
  Shaders/                           .metal files for FX, mixer, NTSC, keyer, grid
  FX/                                FXChain + 6 effects + parameter descriptors
  Mixer/                             MasterMixerOffscreen, ScreenPresenter, KeyerRenderer
  NTSC/                              NTSCPipeline + state
  Audio/                             AVAudioEngine graph, MixerRecorder
  MIDI/                              CoreMIDI router + bindings
  Scenes/                            UIScene-based external display delegate
  UI/                                SwiftUI views (ContentView, PadGrid, BottomControlBar, FX inspector)
  System/                            ThermalMonitor, ScreenshotCapturer, P10Logger
  Pads/                              PadSlot, PadSystem, GridRenderer
  Resources/                         Info.plist, Assets.xcassets, TestAssets/ (bundled clips)
P10EntrancerTests/                   XCTest unit tests for routing, MIDI, FX state
diagnostics/                         Synthetic test patterns for dev (not bundled)
scripts/                             fetch.sh, deploy.sh — devicectl helpers
ATTRIBUTIONS.md                      License + source for bundled demo clips
LICENSE                              MIT
```

## Build & run

Prerequisites:
- macOS with **Xcode 15+** (App Store)
- iOS Simulator runtime + Metal Toolchain (`xcodebuild -downloadPlatform iOS`, `xcodebuild -downloadComponent MetalToolchain`)
- [flox](https://flox.dev) for the dev toolchain (`xcodegen`, `ffmpeg`, `git-lfs`, `coreutils`, `libimobiledevice`, `poppler-utils`)
- Apple Developer account configured in Xcode for device deployment
- **Git LFS** clone: `git lfs install` once; subsequent clones automatically pull binaries

```
flox activate -- xcodegen generate
open P10Entrancer.xcodeproj
```

In Xcode: select your iPad as the run destination, set your team in Signing & Capabilities, hit Run (⌘R).

### Headless deploy from the CLI

After Xcode has minted a provisioning profile (you've run on device once via Xcode UI), subsequent builds + deploys can be CLI-only:

```
flox activate -- xcodegen generate
xcodebuild -project P10Entrancer.xcodeproj -scheme P10Entrancer \
  -sdk iphoneos -destination "id=<your-iPad-UDID>" \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device <udid> \
  ~/Library/Developer/Xcode/DerivedData/P10Entrancer-*/Build/Products/Debug-iphoneos/P10Entrancer.app
xcrun devicectl device process launch --device <udid> com.p10entrancer.app
```

### Tests

```
xcodebuild -project P10Entrancer.xcodeproj -scheme P10Entrancer \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test
```

Covers MixerState routing, MIDI bindings, FX chain wiring.

### Diagnostics

`scripts/fetch.sh` pulls `Documents/p10e.log` and (with `--shots`) `Documents/screenshots/*.png` from the iPad over a paired USB connection. Useful for debugging from the command line without Xcode console.

## Required hardware

- **USB-C HDMI dongle** must be **DP-Alt-Mode** (not DisplayLink) for the external display to work at full rate.
- **USB-C powered hub** if combining HDMI + UVC camera + USB-MIDI on iPad — bus power can otherwise brown out.

## License

Source: MIT (see `LICENSE`).

Bundled demo clips: see `ATTRIBUTIONS.md`. All sourced from public-domain or CC-BY material on archive.org.

## Reference manuals

The project root contains the original manuals for both reference devices, used during design and helpful when adding features that mirror their behavior:

- `p10_manual_e2.pdf` — Edirol P-10
- `KPE1_EFG1.pdf` — Korg KAOSS PAD Entrancer

These are tracked via Git LFS along with bundled video clips.

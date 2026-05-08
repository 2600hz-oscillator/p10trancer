# p10trancer — developer notes

For the user-facing manual, see `P10Entrancer/Resources/Manual.md` (also
viewable in-app via the splash **DOCS** button).

This document covers the build / test / deploy / contribute workflow.

---

## What it is

iPad-only video sampler / live mixer / signal-domain glitch processor.
Targets M2 iPad Pro on iPadOS 17+; faster iPads are fine, M2 is the
floor we test against. Free, open source under MIT.

---

## Project structure

```
project.yml                          xcodegen spec — source of truth for the .xcodeproj
P10Entrancer.xcodeproj/              GENERATED — regenerate via `xcodegen generate`
P10Entrancer/
  App/                               SwiftUI @main + AppState + LiveRecordingsStore
  Render/                            Metal context, render engine, texture pool
  Sources/                           Pad sources (video / image / camera / UVC / feedback / keyer)
  Shaders/                           .metal files for FX, mixer, NTSC, keyer, grid
  FX/                                FXChain + 6 effects + parameter descriptors
  Mixer/                             MasterMixerOffscreen, ScreenPresenter, KeyerRenderer, KeyerSystem
  NTSC/                              NTSCPipeline + state
  Audio/                             AVAudioEngine graph, MixerRecorder
  MIDI/                              CoreMIDI router + bindings + AutomationEngine
  Scenes/                            UIScene-based external display delegate
  Sessions/                          SessionSpec + SessionStore + SessionCapture
  UI/                                SwiftUI views (ContentView, Splash, PadGrid, BottomControlBar, sheets)
  System/                            ThermalMonitor, ScreenshotCapturer, P10Logger
  Pads/                              PadSlot, PadSystem, GridRenderer
  Resources/                         Info.plist, Assets.xcassets, Manual.md, TestAssets/ (bundled clips)
P10EntrancerTests/                   XCTest unit tests for routing, MIDI, FX, sessions
diagnostics/                         Synthetic test patterns for dev (not bundled)
scripts/                             fetch.sh, deploy.sh — devicectl helpers
ATTRIBUTIONS.md                      License + source for bundled demo clips
LICENSE                              MIT
```

---

## Build & run

Prerequisites:
- macOS with **Xcode 15+**
- iOS Simulator runtime + Metal Toolchain (`xcodebuild -downloadPlatform iOS`, `xcodebuild -downloadComponent MetalToolchain`)
- [flox](https://flox.dev) for the dev toolchain (`xcodegen`, `ffmpeg`, `git-lfs`, `coreutils`, `libimobiledevice`)
- Apple Developer account configured in Xcode for device deployment
- **Git LFS** clone: `git lfs install` once; subsequent clones automatically pull binaries

```
flox activate -- xcodegen generate
open P10Entrancer.xcodeproj
```

In Xcode: select your iPad as the run destination, set your team in
Signing & Capabilities, hit Run (⌘R).

### Headless deploy from the CLI

After Xcode has minted a provisioning profile (you've run on device
once via Xcode UI), subsequent builds + deploys can be CLI-only:

```
flox activate -- xcodegen generate
flox activate -- xcodebuild -project P10Entrancer.xcodeproj -scheme P10Entrancer \
  -sdk iphoneos -destination "id=<your-iPad-UDID>" \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device <udid> \
  ~/Library/Developer/Xcode/DerivedData/P10Entrancer-*/Build/Products/Debug-iphoneos/P10Entrancer.app
xcrun devicectl device process launch --device <udid> com.p10entrancer.app
```

### Tests

```
flox activate -- xcodebuild -project P10Entrancer.xcodeproj -scheme P10Entrancer \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test
```

Covers MixerState routing, channel sources, MIDI bindings (in + out),
FX chain wiring.

### Diagnostics

`scripts/fetch.sh` pulls `Documents/p10e.log` and (with `--shots`)
`Documents/screenshots/*.png` from the iPad over a paired USB
connection. Useful for debugging from the command line without Xcode
console.

---

## Required hardware

- **USB-C HDMI dongle** must be **DP-Alt-Mode** (not DisplayLink) for
  the external display to work at full rate.
- **USB-C powered hub** if combining HDMI + UVC camera + USB-MIDI on
  iPad — bus power can otherwise brown out.

---

## Architecture

A render engine driven by a single `CADisplayLink` owns:

- A `MasterMixerOffscreen` that composites the two channels each frame
- A pool of `KeyerRenderer`s — one per `KeyerSystem.keyers` instance
  (currently 2)
- An `NTSCPipeline` chained off the master mixer's output when NTSC
  mode is selected
- A `MixerRecorder` that taps the master output for MP4 encoding when
  recording is armed

Pads are sources. The current source set: `VideoFileSource`,
`ImageSource`, `CameraSource` / `BuiltInCameraSource` (via
`CameraRegistry`), `KeyerPadSource`, `MasterFeedbackSource`. Each
implements a tiny `PadSource` protocol exposing the latest texture.

State (mixer, keyer, NTSC, FX) is `@MainActor ObservableObject` — Combine
publishers fan out to the SwiftUI views and to MIDI bindings.

For the engineering plan, see `.myrobots/plan.md`.

---

## License

Source: MIT (see `LICENSE`). Bundled demo clips: see `ATTRIBUTIONS.md`.

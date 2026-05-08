# P10 Entrancer — iPad Video Sampler & NTSC-Glitch Mixer

## Context

Greenfield iPadOS app inspired by the Edirol P-10 visual sampler and Korg KAOSS PAD Entrancer. Target: M2 iPad Pro (gen 6), iPadOS 17+. Faster iPads should perform better; M2 is the floor.

The app is a 9-pad video sampler / playback / live-mixer. Each pad holds a video file, still image, or live camera feed (built-in iPad camera or UVC USB camera). Pads have per-pad RGB FX and an optional NTSC simulation stage. Two output channels feed a master mixer with transitions; final output goes to a top-of-screen preview and full-screen over an HDMI dongle, switchable between 720p HD and a true simulated NTSC 4:3 pipeline with Archer-Video-Enhancer-style glitch FX. Per-pad audio mixes to master output. CoreMIDI input triggers pads and controls FX.

The differentiator vs. the reference devices is the simulated NTSC encode→corrupt→decode pipeline: glitch FX operate on the simulated composite signal so they produce real NTSC artifacts (chroma bleed, dot crawl, sync tearing, subcarrier drift) rather than RGB-domain fakes.

Working dir already contains both reference manuals (`p10_manual_e2.pdf`, `KPE1_EFG1.pdf`) and a `.flox/` env with `poppler-utils` for reading them. App will be a sibling Xcode project.

## Stack

- Native Swift, iPad-only, deployment target iPadOS 17.0, build/test on iPadOS 18+.
- SwiftUI shell + UIKit-wrapped Metal surfaces for live render.
- Metal for the entire video pipeline; one `CADisplayLink`-driven render loop at 60 Hz.
- AVFoundation: **`AVAssetReader` per pad** for video files (not `AVPlayer` — see Risks). `AVCaptureSession` for cameras: built-in via standard discovery; UVC via `.external` device type (iPadOS 17+). Two independent `AVCaptureSession` instances when running built-in + UVC simultaneously (`AVCaptureMultiCamSession` doesn't accept `.external`).
- VideoToolbox HW H.264/HEVC decode via AVAssetReader's track outputs.
- AVAudioEngine for per-pad audio summing. `AVAssetReaderAudioMixOutput` → `AVAudioPlayerNode.scheduleBuffer:`. Audio drives the timeline; video frames are pulled to match (`playerNode.playerTime(forNodeTime:)`), per P-10 model.
- CoreMIDI for MIDI input; class-compliant USB-MIDI auto-discovers.
- **External display via UIScene**, role `UIWindowSceneSessionRoleExternalDisplayNonInteractive`, declared in `UIApplicationSceneManifest`. (UIScreen API is deprecated as of iPadOS 16 — do not use.)
- No third-party dependencies.

## Architecture

### Render topology

Single `RenderEngine` owns one `CADisplayLink`, all `MTLTexture`s, all command-buffer scheduling. Three render surfaces:

1. **Pad grid surface** — one `MTKView` containing a 3×3 composite of pad thumbnails (downsampled, e.g. 320×180 each). Single MTKView is meaningfully cheaper than 9 separate ones (≈30% less command-buffer overhead) and makes pad-to-pad keying trivial since all 9 pad textures already live in one render graph. SwiftUI overlays 9 hit-test rectangles on top for tap/long-press.
2. **Main output preview MTKView** — top of screen, larger than a pad row, renders the master mixer output.
3. **External display MTKView** — full-screen on HDMI scene, renders master output (same texture as #2 but at the chosen output resolution: 720p HD or 720×480 4:3 NTSC).

All MTKViews configured `enableSetNeedsDisplay = false`, `isPaused = true`, drawn manually from the engine's display-link callback. Main-preview render and external-display render use **separate `MTLCommandBuffer`s** to avoid drawable-acquisition deadlock.

Drawables on `CAMetalLayer.colorspace` tagged BT.709 for the external-display layer; Display P3 for the on-device layers. (Skip explicit colorspace in NTSC mode — the simulation is intentionally outside standard color management.)

### Signal flow per frame

```
Source → Source MTLTexture (full-res for active-channel pads, downsampled for thumbnails)
  → RGB FX chain (blur, internal feedback, chroma distort, YUV phaser, luma phaser, edge enhance)
  → optional per-pad NTSC stage (encoder → glitch → decoder)
  → Pad output texture (cached)

Pad-to-pad key (optional): PadA over PadB via chroma|luma key → virtual pad output

Channel routing: tap pad → currently-selected channel slot binds to pad's output texture

Master mixer:
  Ch1.texture + Ch2.texture
  → mixer transition shader (blur / linear swipe / star swipe / chroma key / luma key) with fader
  → master output texture

Output stage:
  if HDMI mode = HD          → master output → external display directly at 1280×720
  if HDMI mode = NTSC 4:3    → master output → master NTSC pipeline at 720×480
                              → external display
  Always: master output → on-screen preview MTKView
```

### NTSC simulation pipeline

Self-contained Metal module, used both per-pad (optional stage) and as the master output mode.

- **Encoder pass**: RGB → YIQ → 1D composite-signal texture, **4× horizontal oversample** (2880×480 internal for 720×480 visible). Color burst, chroma subcarrier modulation at 3.58 MHz simulated, sync timing explicit.
- **Glitch passes** (Archer-style controls, MIDI-mappable):
  - Chroma boost / bleed
  - Luma peaking / ring (detail knob)
  - Color burst phase shift (whole-frame hue rotate)
  - Subcarrier drift (free-running chroma)
  - HSYNC wobble (per-line jitter — must run in encoded domain before decode)
  - VSYNC slip / roll
  - Y/C delay mismatch
  - Comb filter strength (1D notch ↔ 2D comb; 2D needs 1-line delay texture read)
  - Composite dropouts
  - Independent luma / chroma noise
- **Decoder pass**: demodulate chroma → YIQ → RGB.

Implementation rules: **`half4` precision throughout**, `MTLStorageModePrivate` textures, **fused passes via tile shading / programmable blending** (Apple Silicon supports it, see WWDC20 10602), single command buffer for the whole NTSC chain. Pipeline is bandwidth-bound, not ALU-bound, so pass fusion is the lever.

### Internal-feedback ordering

Per pad, two `MTLStorageModePrivate` textures `A` / `B` and a `currentWriteIndex`. Each frame:

1. Read from texture written *last* frame.
2. Write to the other.
3. Encode all per-pad passes into the pad's command buffer.
4. Commit command buffer.
5. **After commit**, flip `currentWriteIndex`.

Single command buffer per pad means encoder ordering is sufficient; no `MTLEvent`/`MTLFence` needed.

## Module / file layout

```
P10Entrancer.xcodeproj
P10Entrancer/
  App/
    P10EntrancerApp.swift              SwiftUI @main, scene config
    Info.plist                         Scene manifest + usage strings
  Scenes/
    MainSceneDelegate.swift            UIWindowSceneDelegate, primary scene
    ExternalDisplaySceneDelegate.swift Role: ExternalDisplayNonInteractive,
                                       sets preferredMode + overscanCompensation = .none
  Render/
    RenderEngine.swift                 CADisplayLink, command-buffer scheduling
    MetalContext.swift                 device, queue, library, pipeline cache
    TexturePool.swift                  reusable MTLTexture allocator
    PingPong.swift                     two-texture feedback helper
  Sources/
    PadSource.swift                    protocol → MTLTexture + audio buffer hook
    VideoFileSource.swift              AVAssetReader; video output + audio mix output;
                                       teardown-and-recreate for retrigger (one-shot)
    ImageSource.swift                  static MTLTexture
    BuiltInCameraSource.swift          AVCaptureSession + CVMetalTextureCache
    UVCCameraSource.swift              .external device, format negotiation
                                       (prefer 420v/yuvs over MJPEG)
    DecodePolicy.swift                 thumbnail vs active-channel rate gating
  Shaders/
    Common.metal                       color space helpers, samplers
    FX_Blur.metal
    FX_Feedback.metal
    FX_ChromaDistort.metal
    FX_YUVPhaser.metal
    FX_LumaPhaser.metal
    FX_EdgeEnhance.metal
    Mixer_Transitions.metal            blur, linear swipe, star swipe, chroma key, luma key
    Keyer.metal                        pad-to-pad chroma/luma
    NTSC.metal                         encoder + glitch + decoder, fused, half4
    Composite_Grid.metal               9-pad grid composite for thumbnails
  FX/
    FXChain.swift                      ordered list of effects per pad, parameter automation
    Parameter.swift                    AnimatableParameter w/ MIDI binding
  Mixer/
    MasterMixer.swift                  Ch1/Ch2 slots, transition selection, fader
    OutputStage.swift                  HD vs NTSC mode dispatch
  Audio/
    AudioEngine.swift                  AVAudioEngine graph, master mix
    PadAudio.swift                     per-pad AVAudioPlayerNode + buffer scheduler
    Timeline.swift                     audio-driven master clock; render reads via
                                       playerNode.playerTime(forNodeTime:)
  MIDI/
    MIDIRouter.swift                   CoreMIDI input, mach_absolute_time → audio timeline
    MIDIBindings.swift                 note→pad, CC→parameter, persisted
  UI/
    ContentView.swift                  layout: output preview top, 3×3 pad grid mid,
                                       right rail (channel select, mixer, output mode)
    PadGridView.swift                  hit-test overlay over composite MTKView
    OutputPreviewView.swift            wraps main preview MTKView
    FXInspectorView.swift              slides in on long-press, parameter editors
    MIDIMappingView.swift              learn-mode binding UI
  Persistence/
    Project.swift                      Codable, versioned envelope; banks of pad+FX state
    ProjectStore.swift                 UIDocumentPickerViewController integration
  System/
    ThermalMonitor.swift               ProcessInfo.thermalState observer; degrade rules
    SessionInterruption.swift          AVAudioSession + AVCaptureSession lifecycle
```

## UI layout (landscape iPad)

- Top ~45%: main output preview MTKView with HD/NTSC mode badge + Ch1/Ch2 indicator strip.
- Middle ~45%: pad-grid composite MTKView with 3×3 SwiftUI hit-test overlay. Tap routes to active channel; long-press opens FX Inspector.
- Right rail ~10%: Channel select (Ch1/Ch2 toggle), transition selector + fader, output mode (HD / NTSC), record/sample, MIDI status, project menu.

## Phased delivery

Each phase ends with a build runnable on the M2 iPad Pro.

**Phase 0 — scaffolding** (1–2 days)
Xcode project, Metal context, render engine skeleton, single test MTKView at 60 Hz on device.

**Phase 1 — sources + grid** (3–5 days)
Pad-grid composite MTKView. ImageSource and VideoFileSource (AVAssetReader-based) into 9 pads. Source assignment UI. **Validate concurrent decode budget on M2 with 9 mixed video files** — this is the first risk to confirm.

**Phase 2 — cameras** (2–3 days)
BuiltInCameraSource. UVCCameraSource via `.external` with hot-plug via `AVCaptureDevice.DiscoverySession` KVO. Test with the on-hand UVC camera; document working-format requirements.

**Phase 3 — channel routing + master mixer** (3–4 days)
Ch1/Ch2 slots, channel-select toggle, tap-to-route. Mixer transitions (blur, linear swipe, star swipe, chroma key, luma key). Main-preview MTKView.

**Phase 4 — RGB per-pad FX** (4–6 days)
Six FX shaders. PingPong helper for internal feedback. FXChain + Parameter. FX Inspector UI.

**Phase 5 — pad-to-pad keying** (1–2 days)
Virtual pad from Pad A keyed over Pad B; channel-routable.

**Phase 6 — HDMI external display** (2–3 days)
UIScene-based external display delegate. Mode selection (1280×720 / 720×480). `overscanCompensation = .none`. BT.709 colorspace tag in HD mode. Output mode toggle wired.

**Phase 7 — NTSC pipeline** (5–8 days, deepest phase)
Clean encode→decode round-trip first; verify it's near-transparent. Then glitch ops one at a time. Fuse passes via tile shading. Wire as per-pad stage and as master NTSC output mode. Reference: ntsc-rs, LMP88959/NTSC-CRT, svofski composite-video-simulator (port the math, do not link).

**Phase 8 — audio** (2–3 days)
AVAudioEngine. Per-pad AVAudioPlayerNode fed from AVAssetReaderAudioMixOutput. Audio-driven timeline; render loop pulls video frames to match audio time. Master volume.

**Phase 9 — MIDI** (2–3 days)
CoreMIDI input. Note → pad trigger. CC → parameter (learn mode). Schedule events on AVAudioEngine timeline using `mach_timebase_info` conversion. Mappings persisted with project.

**Phase 10 — persistence + polish** (3–5 days)
Project Codable schema (versioned). Banks of pad+FX+mapping state. Sample/capture (Entrancer-style still + 6-second clip). Thermal degrade path. Drawable-stall and color-management audit.

Estimated total: ~5–7 weeks focused.

## Risks & mitigations

1. **Concurrent video decode limit.** Apple imposes an undocumented per-process VTDecompressionSession cap (~4 floor). Using `AVAssetReader` (not `AVPlayer`) is meaningfully lighter; thumbnail pads pull at 15 fps; only active-channel pads pull at 60 fps. Validate Phase 1.
2. **AVAssetReader is one-shot — no seek.** Retrigger requires teardown + recreate. Cheap but must be designed in. For pads that loop with frequent retriggering, fall back to `AVPlayerItemVideoOutput`.
3. **UVC format negotiation.** Cheap dongles often expose only MJPEG at 1080p30 — pay an MJPEG decode cost. Inspect `activeFormat.formatDescription`; prefer `420v`/`yuvs`. Some HDMI-input dongles advertise unsupported intervals and stall.
4. **HDMI dongle compatibility.** Require **DP-Alt-Mode** USB-C HDMI dongles — DisplayLink-chip hubs will not work for full-rate external display. Document hardware requirements in README.
5. **USB-C bus power.** HDMI dongle + UVC camera + USB-MIDI overload bus power. Require a powered USB-C hub. Document.
6. **Drawable acquisition stalls.** Render external display and main preview in **separate command buffers** to avoid 3-drawables-in-flight deadlock.
7. **Thermal throttling.** Sustained 60 Hz with 9 decode streams + NTSC + external display will throttle in 10–20 min in a warm room. Observe `ProcessInfo.thermalState`; degrade rules: drop thumbnail rate first, then NTSC oversample to 2×, then disable per-pad NTSC.
8. **NTSC pipeline performance.** 4× oversample × 8–10 passes is bandwidth-bound. Use `half4` end-to-end; fuse passes via tile shading; single command buffer per pipeline run. Profile in Phase 7 before piling on glitch ops.
9. **Audio/video sync.** Drive video from audio timeline (P-10 model). `AVAudioEngine` `lastRenderTime` + `playerNode.playerTime(forNodeTime:)` is the canonical pattern; do not use `MTAudioProcessingTap`.
10. **MIDI timing jitter.** CoreMIDI timestamps are `mach_absolute_time`; convert via `mach_timebase_info` and schedule on the audio timeline, not display-link ticks.
11. **Background/foreground.** AVCaptureSession tears down on background; AVAudioSession needs `.playback` or `.playAndRecord` category with explicit interruption handling. Test home-button-then-return.
12. **Project format versioning.** `Codable` envelope with explicit schema version from day one. Decide explicitly: feedback texture state does **not** persist across save/load (resets on project open).

## Critical files (to be authored first, in order)

1. `Render/RenderEngine.swift` — single source of truth for timing and command-buffer ordering.
2. `Render/MetalContext.swift` + `TexturePool.swift` — foundation.
3. `Sources/PadSource.swift` (protocol) + `VideoFileSource.swift` + `ImageSource.swift` — earliest end-to-end test of the engine.
4. `Scenes/ExternalDisplaySceneDelegate.swift` + Info.plist scene manifest — get external display path verified before deep FX work.
5. `Shaders/NTSC.metal` — biggest research task; spike early as a vertical-slice prototype after Phase 3.
6. `Audio/Timeline.swift` — once introduced, becomes the master clock; design before Phase 8 to avoid retrofitting.

## Apple framework reference (no third-party deps)

- `AVCaptureDevice.DeviceType.external` (iPadOS 17+, WWDC23 session 10105)
- `AVAssetReader` + `AVAssetReaderTrackOutput` + `AVAssetReaderAudioMixOutput`
- `CVMetalTextureCache` for capture→Metal interop (set `kCVPixelBufferMetalCompatibilityKey: true` on capture outputs)
- `UIWindowSceneSessionRoleExternalDisplayNonInteractive` (iPadOS 16+, WWDC22 10061)
- `UIScreen.availableModes` / `preferredMode` / `overscanCompensation`
- `CAMetalLayer.colorspace` for BT.709 vs P3 tagging
- `MTKView` with manual driving (`isPaused = true`, `enableSetNeedsDisplay = false`)
- Tile shading / programmable blending on Apple Silicon (WWDC20 10602)
- `AVAudioEngine`, `AVAudioPlayerNode.scheduleBuffer:`, `playerTime(forNodeTime:)` (WWDC14 502, WWDC17 501)
- `MIDIClientCreate`, `MIDISourceConnect`, `MIDIPacketList` with `mach_absolute_time` timestamps
- `ProcessInfo.thermalStateDidChangeNotification`

## Info.plist requirements

- `NSCameraUsageDescription`
- `NSMicrophoneUsageDescription` (UVC audio capture triggers this)
- `UIApplicationSceneManifest` with primary + external-display scene roles
- `UIRequiredDeviceCapabilities`: `metal`, `arm64`
- `UISupportedInterfaceOrientations~ipad`: landscape-only
- (No special USB entitlement; class-compliant UVC and USB-MIDI go through AVFoundation/CoreMIDI.)

## Verification

End-to-end checks to run on the M2 iPad Pro at the end of each phase:

- **Phase 1**: 9 mixed video files load, all 9 thumbnails update, no frame drops in pad grid; profile decode session count.
- **Phase 2**: Plug/unplug UVC camera mid-session, source recovers; built-in + UVC simultaneously visible on two pads.
- **Phase 3**: Tap each pad → routes to active channel within one frame; mixer transitions look clean at 60 Hz.
- **Phase 4**: Each FX visually correct standalone; internal feedback stable (no runaway, no flicker — confirms ping-pong ordering).
- **Phase 5**: Chroma-keyed Pad A over Pad B routable to channel; clean composite.
- **Phase 6**: HDMI dongle attach → external scene appears; mode toggle changes external resolution; on-screen preview matches external content; colorspace correct (HD mode whites match between iPad and HDMI display).
- **Phase 7**: Clean NTSC round-trip is visually near-transparent; each glitch op produces the expected artifact (chroma bleed, dot crawl on edges, sync tearing, etc.); 60 Hz sustained with all glitches at moderate settings.
- **Phase 8**: Pad video audio plays through device speakers and line-out; audio in sync with video on retrigger; master volume works.
- **Phase 9**: MIDI controller triggers pads with sub-10 ms perceived latency; CC moves a mapped FX parameter smoothly; mappings persist across app restart.
- **Phase 10**: Save project → kill app → reopen → all banks/pads/FX state restored; thermal state goes serious → app degrades gracefully without dropping frames hard.

Hardware to test against (all on hand): M2 iPad Pro, USB-C-to-HDMI dongle (DP-Alt-Mode), UVC USB camera, class-compliant USB-MIDI controller, powered USB-C hub.

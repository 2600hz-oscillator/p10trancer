# MIDI Control Scheme

P10 Entrancer responds to incoming MIDI on **any channel**. Both class-compliant USB-MIDI controllers (plug into iPad's USB-C) and Bluetooth MIDI work. The CoreMIDI router auto-discovers connected sources.

## Quick map

```
PADS                          (route current pad to active channel)
PC  1 …  9   →  Pad  1 …  9
Note 36-44   →  Pad  1 …  9   (MPC / Akai pad layout)
Note 60-68   →  Pad  1 …  9   (keyboard middle-C upward)

ACTIVE CHANNEL
PC  10       →  Select CH1
PC  11       →  Select CH2

TRANSITION KIND
PC  12       →  Blur (crossfade)
PC  13       →  Linear Swipe
PC  14       →  Star Swipe
PC  15       →  Chroma Key
PC  16       →  Luma Key

OUTPUT MODE
PC  17       →  Toggle HD ↔ NTSC 4:3

KEYER
PC  18       →  Toggle keyer enable
PC  19       →  Route keyer → CH1
PC  20       →  Route keyer → CH2

RECORD
PC  21       →  Toggle record start/stop

CONTINUOUS CONTROLLERS (CC)
CC   1       →  Mixer position fader (Ch1 ↔ Ch2 fade)
CC   2       →  Master volume
CC   3       →  Keyer threshold
CC   4       →  Keyer softness        (mapped 0…0.5)
CC   5 …  13 →  Pad 1 … 9 audio volume
CC  14       →  NTSC: Chroma boost    (mapped 0…3×)
CC  15       →  NTSC: HSync wobble
CC  16       →  NTSC: Subcarrier drift (mapped 0…0.5)
CC  17       →  NTSC: Burst phase      (mapped −0.5…+0.5)
CC  18       →  NTSC: Y/C delay        (mapped −8…+8)
CC  19       →  NTSC: Dropout rate
CC  20       →  NTSC: Luma noise       (mapped 0…0.3)
CC  21       →  NTSC: Chroma noise     (mapped 0…0.3)
CC  22       →  NTSC: Luma peaking     (mapped 0…3)

PER-PAD FX (selects a pad first, then drives that pad's FX)
PC  22 … 30  →  Inspect pad 1 … 9 (subsequent CCs 23-34 target that pad)
CC  23       →  Blur radius         (0 = off, > 0 = on)
CC  24       →  Chroma hue
CC  25       →  Chroma saturation
CC  26       →  Chroma RGB split
CC  27       →  YUV phaser phase
CC  28       →  YUV phaser depth
CC  29       →  Luma phaser strength
CC  30       →  Luma phaser curve
CC  31       →  Edge enhance
CC  32       →  Feedback mix         (0 = off, > 0 = on)
CC  33       →  Feedback zoom        (mapped 0.85…1.15)
CC  34       →  Feedback decay       (mapped 0.5…1.0)
```

## Reverse direction: iPad → host (record gestures as automation)

P10 Entrancer publishes a **CoreMIDI virtual source named "P10 Entrancer"** that emits the same scheme outbound when you touch UI controls. Move a fader or tap a pad on the iPad, and the corresponding CC / PC flows out as MIDI.

In Bitwig (or any DAW): add a track, set its **MIDI input** to the iPad's "P10 Entrancer" port, arm record on a parameter, then perform live on the iPad — every gesture lands in Bitwig as automation. Replay the track and your gestures fire back into the iPad over the inbound channel.

Feedback-loop guard: when MIDI arrives over the inbound side, the outbound side is muted for the duration of dispatch — so the iPad doesn't echo received messages. Round-tripping (Bitwig → iPad → Bitwig) is safe.

Endpoint name on the host: `P10 Entrancer` (channel-agnostic, MIDI 1.0 protocol).

## Bitwig workflow example

Suppose you want to *fade pad 2 to pad 3 over 4 bars while ramping feedback on pad 2 simultaneously*. In Bitwig:

1. Track 1 ("pad assigns") — clip with `Note Out` modules sending PC 2 (sets active channel pad to 2) at the start.
2. Track 2 ("position fader") — clip with `CC Out` (CC 1, channel 1) automated 0 → 127 over 4 bars. This is the Ch1↔Ch2 crossfade.
3. Track 3 ("pad-2 feedback ramp") — clip starts with `Note Out` PC 23 (= inspect pad 2) on the downbeat, then `CC Out` CC 32 (Feedback mix) automated 0 → 127 over the same 4 bars.

When the scene launches, all three clips fire together: pad 2 → CH1, position ramps to CH2 (which already has pad 3), and pad 2's internal feedback ramps up. Hit stop and pad 1 holds the recorded result if you also armed the recorder (PC 21 toggle).

Notes on the inspector PC + FX CC pattern: changing the inspected pad doesn't reset prior pads' FX values, so you can layer ramps across multiple pads by inserting an "inspect pad N" PC just before that pad's CC stream. Each pad keeps its own FX state independently.

## Example controller mappings

### Korg nanoKONTROL2

The default factory layout fits this scheme cleanly:

| Element | MIDI | Function |
|---|---|---|
| Track 1–8 sliders | CC 0…7 | not currently used (could be mapped) |
| Track knobs 1–8 | CC 16…23 | NTSC FX (close to the bindings) |
| S/M/R buttons | various | not currently used |
| Cycle / track</br>controls | n/a | not currently used |

For closest match, reconfigure the nanoKONTROL2 via the Korg KONTROL Editor:
- Slider 1 → CC 1 (position)
- Slider 2 → CC 2 (master volume)
- Sliders 3-9 → CC 5-11 (pad volumes, partial)
- Knobs 1-8 → CC 14-21 (NTSC FX)
- S buttons 1-9 → PC 1-9 (pad triggers)

### AKAI APC mini / APC Key 25

- 8×8 grid of buttons → Notes 36-99. Bottom row 36-43 = pads 1-8. Custom-map a 9th button or use track/scene buttons for pad 9.
- 9 vertical sliders → CC 48-56 (factory). Reconfigure to CC 1, 2, 5-11.

### Novation Launchpad / Launchkey

- Pads send Notes 36+; first 9 pads work out of the box for pad triggering.
- Faders/knobs map to Sustainable CC ranges; configure CC 1, 2 for the two main faders.

## Notes

- All values arrive in 0–127 range; the binding code scales each to its destination. NTSC params with bipolar ranges (burst phase, Y/C delay) are centered at CC value 64.
- Keyer threshold/softness CC sets `mixer.keyThreshold` for the master mixer chroma/luma transitions AND `keyer.threshold/softness` for the pad-to-pad keyer simultaneously, so one knob controls both consistently.
- PCs are 1-indexed in the table above (the convention controllers display). CoreMIDI delivers them as 0–127; binding code subtracts 1 internally where needed.
- A CC-learn / PC-learn UI is on the roadmap. For now the scheme is hardcoded.

## Testing

The full scheme is exercised in `P10EntrancerTests/MIDIBindingsTests.swift`. Run via:

```
xcodebuild -project P10Entrancer.xcodeproj -scheme P10Entrancer \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,id=<sim-udid>' test
```

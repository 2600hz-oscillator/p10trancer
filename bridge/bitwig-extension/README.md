# P10 Entrancer Bitwig Bridge

Bitwig 5.3+ Controller Extension that exposes every iPad-side P10 Entrancer parameter as a named, automatable Bitwig hardware control. Move/automate the Bitwig control → MIDI flows out to the iPad → app responds.

## What it gives you

A virtual hardware controller in Bitwig with ~50 controls:

- **9 pad-trigger buttons** (sends PC 1-9)
- **5 transition buttons** (Blur / Swipe / Star / Chroma / Luma)
- **2 channel-select buttons** (active CH1 / CH2)
- **5 system buttons**: HDMI HD↔NTSC toggle, keyer toggle, keyer→CH1, keyer→CH2, record toggle
- **Mixer knobs**: position (Ch1↔Ch2), master volume, keyer threshold, keyer softness
- **9 pad-volume knobs**
- **9 NTSC FX knobs**: chroma boost, HSync wobble, drift, burst phase, Y/C delay, dropout, luma noise, chroma noise, peaking
- **9 inspect-pad buttons** (PC 22-30 — selects which pad subsequent FX knobs target)
- **12 per-pad FX knobs**: blur, chroma hue/sat/split, YUV phase/depth, luma strength/curve, edge, feedback mix/zoom/decay

Each one is a Bitwig hardware control that can be:
- Automated in clips (record automation, draw curves)
- Driven by Bitwig Modulators (LFOs, envelopes, beat dividers)
- Mapped to track Macros for one-knob-many-things control
- Wired to Grid `CC Out` / `Note Out` modules via Generic Hardware mapping
- Triggered by clip launches (button bindings)

## Build

```
cd bridge/bitwig-extension
gradle build
# output: build/bwextension/P10EBridge.bwextension
```

Drop the `.bwextension` file into:

- macOS: `~/Documents/Bitwig Studio/Extensions/`
- Windows: `Documents\Bitwig Studio\Extensions\`
- Linux: `~/Bitwig Studio/Extensions/`

In Bitwig: Settings → Controllers → `+ Add controller` → vendor `P10 Entrancer` → `Bridge`. Set the controller's MIDI Output to your iPad-bound port (IAC Driver, Network Session, or USB-MIDI device).

## Workflow example: "fade pad 2 to pad 3 + ramp feedback on pad 2 over 4 bars"

1. Add a clip on Track A. In its automation lane, draw a curve on the **`P10E Bridge → Mixer Position`** parameter going 0 → 1 over 4 bars. (This is CC 1, the Ch1↔Ch2 fade.)
2. On the same clip's downbeat, add Note Events on a **virtual track bound to** the bridge's `P10E Bridge → Pad 2` and `Inspect Pad 2 for FX` actions. (Or use Action / Note `chasers` in Bitwig's clip events.)
3. Add a parallel automation lane on the **`P10E Bridge → FX: Feedback Mix`** parameter ramping 0 → 0.7 over the same 4 bars.
4. Launch the clip. Pad 2 routes to the active channel, position fader sweeps Ch1→Ch2, and pad 2's internal feedback ramps up — all timed perfectly to the beat clock.

The "Inspect Pad N" buttons select which pad the FX knobs target. Hit one, then move FX knobs, then hit another and move the same knobs to control a different pad's FX. Each pad keeps its own FX state — switching inspection doesn't reset anyone.

## Notes / limitations

- This extension only **emits** MIDI. It doesn't read iPad state. So Bitwig and iPad can drift if you also touch the iPad UI directly. For now, treat Bitwig as the master.
- Each knob is unipolar 0…1 in Bitwig. Bipolar params (NTSC burst phase, Y/C delay) are remapped to bipolar ranges on the receiver side. So in Bitwig, 0.5 = center.
- The build script is a starter. You may need to adjust `extension-api` version and the bwextension packaging step depending on your Gradle setup. See [Bitwig extension samples](https://github.com/bitwig/bitwig-extensions) for canonical Gradle config.

## License

MIT, same as the iPad app.

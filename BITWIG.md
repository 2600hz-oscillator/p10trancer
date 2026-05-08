# Bitwig → P10 Entrancer Bridge

P10 Entrancer accepts standard MIDI on iPadOS via CoreMIDI. Bitwig Studio talks to it through the **P10 Entrancer Bridge** controller extension at `bridge/bitwig-extension/`. See `MIDI.md` for the receiver-side scheme.

## Prerequisites

- Bitwig Studio 5.3+ (extension API v22 or higher)
- iPad running P10 Entrancer
- A MIDI transport between them (see "Network setup" below)

## Install the extension

```
cd bridge/bitwig-extension
flox activate -- gradle build
cp build/bwextension/P10EBridge-0.1.0.bwextension ~/Documents/Bitwig\ Studio/Extensions/
```

Restart Bitwig (or rescan extensions from Settings). Then **Settings → Controllers → + Add controller → vendor `P10 Entrancer` → product `Bridge` → Add**. Set the new controller's **Out** dropdown to whichever MIDI port reaches the iPad. You'll see a popup "P10 Entrancer Bridge ready".

## Network setup (Mac → iPad)

Ranked by latency:

1. **USB-C cable, IDAM mode** (lowest latency, no Wi-Fi).
   - Plug iPad to Mac via USB-C
   - macOS: Audio MIDI Setup → Window → Show MIDI Studio → click iPad icon → **Enable** under MIDI
   - iPad now appears as a CoreMIDI port; pick it as the Bridge's Out
2. **Wired Ethernet RTP-MIDI** (sub-3 ms typical)
   - macOS: Audio MIDI Setup → MIDI Studio → Network → create session, enable
   - iPad: open P10 Entrancer (instantiates CoreMIDI network driver). The iPad appears in the Mac's Network Session "Directory" → click **Connect**
3. **Wi-Fi RTP-MIDI** — same setup, 5-20 ms latency. Fine for clip-launch granularity, edge-of-tolerable for sample-accurate FX.
4. **Bluetooth MIDI** — last resort.

## Bitwig 6 note: Macro device is gone

Bitwig 6 consolidated the standalone Macro device into **Track Macros** (8 knobs in every track's inspector) and **Modulators** (LFO, Curve, Steps, Note Sidechain, etc.). For our workflow:

- Use **Modulators** when you want a parameter to move automatically (LFO ramps, Curve sweeps, Steps sequenced values).
- Use **Track Macros** for one-knob-many-things grouping (8 macro knobs in the track inspector that map to multiple targets).
- Use **clip automation lanes** for static recorded curves that play with a clip.

Anywhere these target a parameter, the **P10 Entrancer Bridge** controls show up as valid mapping destinations. Right-click any P10E Bridge control once mapped and you can edit the binding.

## The three-track workflow

This is the recommended layout for the "fade pad 2 to pad 3 + ramp feedback on pad 2 over 4 bars" style of composition.

### Track A — "Pad Triggers"

Sends MIDI notes that the iPad treats as pad triggers (Notes 36-44 = Pads 1-9, MPC-style).

1. Add an **Instrument track**, name it `Pad Triggers`
2. Set its **MIDI output** (in the track inspector) to the iPad port — same one you set on the Bridge controller's Out
3. In the track's clip launcher, create a Note clip
4. Open the clip in the editor and place notes:
   - C1 (note 36) → Pad 1
   - C#1 (37) → Pad 2
   - D1 (38) → Pad 3
   - … through G#1 (44) → Pad 9
5. When the clip plays, each note instant-routes that pad to the active channel

### Track B — "Continuous"

Drives the master fader and any other CC parameters (master vol, NTSC FX, keyer threshold/softness).

1. Add an Instrument track named `Continuous`
2. In the track inspector, expand **Remote Controls** — assign one slot:
   - Click the slot's `+` → choose **P10 Entrancer Bridge → Mixer Position**
   - Repeat for `Master Volume`, `NTSC HSync Wobble`, etc.
3. Now those Remote Controls are automatable on this track — open a clip, view automation lanes, draw curves
4. Bonus: drop a **Curve** modulator on the track, target a Remote Control, set the Curve's `Amount` to be clip-automatable

### Track C — "Per-Pad FX"

Drives FX on a specific pad, picked at clip start via the Inspect-PC.

1. Add an Instrument track named `Per-Pad FX`
2. MIDI output → iPad port (or via Bridge)
3. In a clip:
   - At bar 0, place a single MIDI event triggering the **`Inspect Pad 2 for FX`** button on the Bridge — easiest path: assign that button to a Remote Control then automate it as a one-shot pulse
   - Add a Remote Control mapped to **`P10 Entrancer Bridge → FX: Feedback Mix`**
   - Draw an automation curve on that Remote Control 0 → 0.7 over 4 bars

The clip is now self-contained: when launched, it picks pad 2 for inspection then ramps its feedback. Drop another clip with `Inspect Pad 5` + a different curve and you've layered effects across pads.

## Saving templates for reuse

Once you've built the three-track setup, save it as a starter project or track preset:

- **Track preset**: right-click a track header → **Save Track…** → name it `P10E_Triggers.bwpreset` etc. Bitwig saves to `~/Documents/Bitwig Studio/Library/Tracks/`.
- **Project template**: File → Save → name as `P10E_Composer.bwproject` and save inside `~/Documents/Bitwig Studio/Library/Templates/` so it shows in Bitwig's startup project picker.

Tell me where you saved them and I'll commit them to `bridge/bitwig-presets/` so the next person doesn't have to rebuild.

## Why this scheme

- All routing is via standard MIDI — works with the iPad in any state, with or without the Bridge extension. Even if you remove the Bridge extension and configure raw MIDI tracks, the iPad still receives the same messages.
- The Bridge extension's value is the **named hardware controls** so you don't have to remember "CC 14 = NTSC chroma boost" — Bitwig shows you "P10 Entrancer Bridge → NTSC Chroma Boost" in dropdowns.
- Note triggers (36-44) work without the extension at all if you'd rather not run it. The extension's pad-trigger buttons send PC 1-9, which is a one-shot alternative — useful when bound to a Bitwig button that only fires events.

## Troubleshooting

- **Vendor not in list**: extension didn't load. Check `~/Library/Logs/Bitwig/BitwigStudio.log` for "extension-registry" errors. Common cause is a missing `META-INF/services/com.bitwig.extension.ExtensionDefinition` resource (the SPI file).
- **Notes flow but CC doesn't**: check that the Bridge controller's Out port is set, AND that the receiving track's MIDI output is also routed (these are independent — the Bridge sends knob CCs through ITS own port; tracks send notes through their OWN port; both need to point to the iPad).
- **Latency feels off**: switch to USB-C IDAM. Wi-Fi RTP-MIDI can be jittery if other Wi-Fi traffic is heavy.

## References

- [Bitwig User Guide — Hardware](https://www.bitwig.com/userguide/latest/hardware/)
- [Bitwig User Guide — Grid Modules](https://www.bitwig.com/userguide/latest/grid_modules/)
- [bitwig-extensions samples (GitHub)](https://github.com/bitwig/bitwig-extensions)
- [Apple — Transfer MIDI between apps (IAC)](https://support.apple.com/guide/audio-midi-setup/transfer-midi-information-between-apps-ams1013/mac)

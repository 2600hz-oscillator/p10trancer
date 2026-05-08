# P10 Entrancer

An iPad-native video sampler, live mixer, and signal-domain glitch processor.
A modern reimagining of two cult-classic visual instruments from the early
2000s, built for the M2 iPad Pro.

> The implementation lives on the [`MVP1` branch](../../tree/MVP1) — see the
> [open MVP1 pull request](../../pulls?q=is%3Apr+head%3AMVP1) for the full
> development history.

---

## Heritage

P10 Entrancer is descended from three pieces of analog/digital hardware that
defined a brief and beautiful era of live visual performance:

### Edirol P-10 Visual Sampler (Roland, 2003)

A 9-pad video sampler conceived as a "Korg KAOSS Pad for video": load nine
clips into nine pads, hit a pad to play, blend two pads on a master fader,
swap clips between two output channels using a transition selector. The P-10
pioneered the muscle-memory grid layout that this project preserves.

The original [P-10 manual is included in this repo](./p10_manual_e2.pdf) (Git
LFS) and was used as a primary reference when designing the routing,
transitions, and the channel-mixer model.

### Korg KAOSS Pad Entrancer (KPE-1, 2003)

Korg's contemporary answer: a touch-XY pad driving real-time effects on a
live video signal, plus a 6-second sampler. The Entrancer's "knobs on
glitches" performance vocabulary — chroma flutter, scanline tearing, frame
slip, edge enhancement — drives this project's per-pad RGB FX rack.

The [KPE-1 manual is included in this repo](./KPE1_EFG1.pdf) (Git LFS) and was
the reference for FX naming and behavior ranges.

### Archer Video Enhancer (and the lineage of consumer NTSC processors)

The last, and the most opinionated, of the three references. The Archer (and
its cousins from RCA, Showtime, etc.) was a 1980s consumer "video stabilizer"
device — a small box you'd plug a VCR into to "enhance" the picture. In
practice these boxes were composite-domain processors: they demodulated NTSC,
mangled the chroma and luma in analog (chroma boost, luma peaking, sync
massaging), and re-encoded. When you turned the knobs past sensible settings,
they produced gorgeous, characteristic NTSC artifacts: chroma bleed, dot
crawl, sync tearing, subcarrier drift, color burst phase shift.

P10 Entrancer's NTSC pipeline is a Metal-based **simulation of this exact
signal path**. Frames are encoded into a simulated composite waveform with
4× horizontal oversampling, glitch effects mutate the encoded composite (not
the RGB), and the result is decoded back. The artifacts are real-NTSC-shaped
because they're produced by the same kind of operations the analog devices
performed.

---

## Goals

1. **Preserve the gestural model** of the P-10 / Entrancer: 9 pads, two
   channels, one master fader, immediate tactile playback. The interface
   intentionally does not present timeline, trackview, or beat grids.
2. **Modernize the hardware floor**: built-in iPad cameras, USB-C UVC
   cameras, USB-C HDMI output (DP-Alt-Mode), CoreMIDI in/out, RTP-MIDI to a
   computer.
3. **NTSC artifacts as an instrument**: signal-domain glitches with knob
   ranges that go from "subtle period grading" through "obviously broken" to
   "completely shredded." Every artifact has a real composite-video origin.
4. **Round-trip MIDI for performance recall**: emit your gestures as MIDI
   while you play, capture them in the iPad's automation engine (or in
   Bitwig as a clip), and play them back later — round-trip-locked to MIDI
   Clock so the recalled performance hits the same beats.
5. **Free, open-source, App Store**: MIT-licensed, no in-app purchases,
   built so that anyone with an iPad and an HDMI dongle can do this.

---

## Status

This is an MVP. The implementation branch (`MVP1`) currently contains:

- 9-pad grid with video / image / camera / UVC / master-feedback sources
- Two output channels with the 5 mixer transitions and a master fader
- 6-effect per-pad RGB FX rack with internal feedback
- Pad-to-pad chroma/luma keyer
- Full simulated NTSC pipeline with the Archer-style glitch ops
- HDMI external display via UIScene (HD 720p / NTSC 4:3)
- Per-pad audio routed through AVAudioEngine with master volume + capture
- CoreMIDI in/out + RTP-MIDI for DAW integration
- A tick-locked **AutomationEngine**: arm record, hit play in your DAW, perform
  on iPad, hit stop — the take is captured in MIDI clock space and replays
  exactly when the DAW transport sends a Start. Overdub mode preserves
  unrelated streams when re-recording specific knobs.
- A Bitwig Studio extension exposing 8 cursor-track macros for zero-config
  automation recording on the DAW side, plus all 128 CCs and notes for
  manual mapping.

See the [`MVP1` branch](../../tree/MVP1) for the implementation,
build instructions, and the engineering plan in
[`.myrobots/plan.md`](../../blob/MVP1/.myrobots/plan.md).

---

## License & attribution

Source code: MIT (see `LICENSE`).

Heritage manuals (`p10_manual_e2.pdf`, `KPE1_EFG1.pdf`) are tracked under Git
LFS and bundled for reference. They remain copyright their respective
manufacturers (Roland Corporation / Korg, Inc.). The bundled video clips on
the `MVP1` branch are sourced from public-domain or CC-BY material; see
`ATTRIBUTIONS.md` on that branch for full credits.

P10 Entrancer is not affiliated with Roland, Korg, or any other rights
holder named here. The names *Edirol P-10*, *KAOSS PAD Entrancer*, and *Archer
Video Enhancer* are used only to describe heritage and inspiration.

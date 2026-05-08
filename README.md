# p10trancer

An app for visual artists and VJs, inspired by the rich lineage of video
mixers and samplers.

Nine pads, two output channels, a master mixer, six per-pad effects,
two independent keyers, a full simulated composite-NTSC signal pipeline
with knob-driven glitch effects, HDMI external display, MIDI in and
out, and DAW-clock-locked automation recording. Free, open-source,
iPad-only.

> The implementation lives on the [`MVP1` branch](../../tree/MVP1). See
> the [open MVP1 pull request](../../pulls?q=is%3Apr+head%3AMVP1) for
> the full diff and design notes.

---

## Why

Live video performance has spent twenty-plus years split between
software toolkits that can do anything but require coding, and consumer
gear that's intuitive but limited. The middle ground — the
performance-first, gestural device — has been mostly missing since the
era of dedicated hardware video samplers and effects pads ended.

p10trancer puts that middle ground on the iPad. Nine pads in a 3×3
grid. Two channels. A master fader. A few transitions. Per-pad
effects you can dial in by feel. A glitch pipeline that goes from
"subtle period grading" to "completely shredded" without ever feeling
like a software patch graph.

It's built for taking out, plugging into a club PA, hitting record,
and seeing what happens.

---

## Goals

1. **Preserve the gestural model** of dedicated video samplers: 9
   pads, two channels, one master fader, immediate tactile playback.
   No timeline, no track view, no beat grid.
2. **Modernize the hardware floor**: built-in iPad cameras, USB-C UVC
   cameras, USB-C HDMI output, CoreMIDI in/out, RTP-MIDI to a
   computer.
3. **NTSC artifacts as an instrument**: signal-domain glitches with
   knob ranges that go from "subtle period grading" through
   "obviously broken" to "completely shredded." Every artifact has a
   real composite-video origin.
4. **Round-trip MIDI for performance recall**: emit your gestures as
   MIDI while you play, and capture them in the iPad's automation
   engine locked to any device that sends MIDI Clock and Start/Stop.
   No DAW-specific plugin or extension.
5. **Free, open-source, App Store**: MIT-licensed, no in-app
   purchases, built so anyone with an iPad and an HDMI dongle can do
   this.

---

## Status

This is an MVP. The implementation branch (`MVP1`) currently
contains:

- 9-pad grid with video / image / camera / UVC / master-feedback / keyer
  sources
- Two output channels with five mixer transitions and a master fader
- Six-effect per-pad RGB FX rack with internal feedback
- Two independent pad-to-pad keyers, chainable and self-feedbackable
- Full simulated NTSC pipeline with signal-domain glitch ops
- HDMI external display via UIScene (HD 720p / NTSC 4:3)
- Per-pad audio routed through AVAudioEngine with master capture
- CoreMIDI in/out + RTP-MIDI
- A tick-locked **AutomationEngine**: arm record, hit play on any
  MIDI-Clock source, perform on iPad, hit stop — the take is captured
  in MIDI clock space and replays exactly when the source sends a
  Start. Overdub mode preserves unrelated streams when re-recording
  specific controls.
- Session save/load with named presets and a default-on-launch setting.
- An in-app manual covering everything above.

See the [`MVP1` branch](../../tree/MVP1) for the implementation, build
instructions, and the engineering plan in
[`.myrobots/plan.md`](../../blob/MVP1/.myrobots/plan.md).

---

## License & attribution

Source code: MIT (see `LICENSE`).

Bundled sample clips on `MVP1` are sourced from public-domain or CC-BY
material. Full credits in `ATTRIBUTIONS.md` on that branch.

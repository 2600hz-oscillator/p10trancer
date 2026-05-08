# p10trancer

An app for visual artists and VJs, inspired by the rich lineage of video
mixers and samplers.

Nine pads, two output channels, a master mixer, six per-pad effects,
two independent keyers, a full simulated composite-NTSC signal pipeline,
HDMI external display, MIDI in and out, automation recording locked to
your DAW's transport.

---

## Quick start

1. Tap **ENTRANCE ME** on the splash screen.
2. The 3×3 pad grid loads with nine sample clips. Each pad has its own FX
   chain, fully bypassed by default.
3. Tap a pad: it routes to the **active channel**. The big **CH 1** /
   **CH 2** buttons in the bottom bar tell you (and switch) which channel
   you're routing to.
4. Drag the **POSITION** fader to fade between CH 1 and CH 2 using the
   currently selected **TRANSITION** (Blur / Swipe / Star / Chroma / Luma).
5. Drag **MASTER VOL** to bring the audio up.
6. Long-press a pad for source options: load a video file, point at a
   camera, route a keyer's output, or use the master output as a
   feedback source.

---

## Pads

### Source assignment

Long-press any pad to open the source menu:

- **Load Video…** — pick an mp4/mov from the iCloud Drive picker. The file
  is copied into the app's `UserVideos/` folder so you keep working even
  if the original goes away.
- **Camera ▶** — submenu of every camera the app sees. Front camera, back
  camera, USB-C UVC cameras (HDMI capture dongles, webcams) all show up
  here as soon as they're plugged in. If a camera disconnects, the pad
  goes black; it comes back automatically when reconnected.
- **Keyer ▶** — set the pad's source to **Keyer 1** or **Keyer 2**'s
  output composite. See "Keyers" below; this is how chained or
  feedback-driven composites are built.
- **Master Feedback** — the master output of the mixer feeds back into
  this pad. Combined with crossfade transitions and a slight position
  ramp, you get classic last-frame trail effects.
- **Reset to Bundled** — go back to the original sample clip for that
  pad position.

Tapping a pad's video routes it into the active channel, identified by
the highlighted **CH 1** or **CH 2** button.

### Per-pad effects

Tap **INSPECT…** in the bottom bar to open the effects rack for the
inspected pad. Switch which pad is inspected with the segmented control
at the top of the sheet.

The chain runs in this order, each effect is bypassable:

1. **Blur** — single-radius gaussian blur. Use sparingly; large radius
   on every pad costs frame budget.
2. **Chroma** — hue rotate, saturation push, RGB channel split. The
   split parameter offsets red/green/blue independently for chroma
   bleeding.
3. **YUV Phaser** — modulates the YUV color planes against each other.
   Animated saturation flicker.
4. **Luma Phaser** — bands the luminance into staircase steps. The curve
   parameter sharpens or softens the steps.
5. **Edge Enhance** — local-contrast sharpen. Pairs well with NTSC
   peaking; turn one or the other down to avoid stacking.
6. **Feedback** — internal feedback (this pad's previous frame ↦ this
   pad's current frame). Mix is the dry/wet, Zoom and Rotate transform
   the feedback texture each pass, Decay damps the loop. Mix above ~0.6
   self-amplifies if Decay is too close to 1.0. Pull Decay down to 0.92
   for a stable bloom.

Effects are reset to "off" by every fresh app launch and by the SESSION
DEFAULT button.

---

## Channels and the master mixer

### CH 1 / CH 2

The big **CH 1** and **CH 2** buttons in the bottom bar do two things:

1. Show what each channel currently sources (the pad number or keyer
   index in small text under the channel label).
2. **Tap to make it the active channel.** Tapping a pad after that
   routes the pad into the active channel.

The active channel is the only one that changes when you tap a pad. The
inactive channel stays where it is.

### Position fader

`POSITION` mixes between CH 1 (fully left) and CH 2 (fully right) using
the selected transition. With Blur transition selected, the position is
a straight crossfade with optional cross-blur during the transition.
With Swipe / Star, position drives the wipe geometry. With Chroma /
Luma key, position drives the threshold.

### Transition kinds

- **Blur** — crossfade with a slight blur in the middle of the
  transition. The default; works for everything.
- **Swipe** — linear directional wipe.
- **Star** — radial wipe from the center.
- **Chroma** — keys CH 1 over CH 2 by chroma threshold. Drag position
  to sweep the threshold.
- **Luma** — same but luminance.

### Master volume

Audio from each pad's video source mixes through the master node. Audio
follows whichever channel its pad is routed to: silent pads contribute
nothing. Master volume scales the final output to your speakers / line
out / HDMI audio.

### Recording the mix

The big red **REC** button records the final mixer output to an MP4 in
`Documents/UserVideos/recording-YYYYMMDD-HHMMSS.mp4`. While recording, a
thumbnail is reserved in the **LIVE RECORDINGS** row at the bottom; on
Stop, the thumbnail populates with the first-frame preview.

### Live recordings reel

The bottom row holds your eight most recent live recordings from this
session. Tap a thumbnail to **select** it (green border). Tap any pad
in the 3×3 grid to assign that recording into the pad. Selection clears
on assignment. The mp4s persist on disk regardless of what's in the
reel; reach them through the iPad's Files app under the app's
Documents folder.

---

## Keyers

Two independent keyers (**Keyer 1**, **Keyer 2**), each producing a
composite from a foreground pad keyed over a background pad.

### Routing keyers

There are two ways to use a keyer's output:

- **Direct to a channel:** open `KEYER CONTROLS…` → tap `→ CH 1` or
  `→ CH 2`. The channel now sources that keyer instead of a pad.
- **As a pad source:** long-press a pad → `Keyer ▶` → pick Keyer 1 or
  Keyer 2. The pad now contains the keyer's composite, which you can
  further FX, route to a channel, key into another keyer, etc.

Pad-as-keyer is the path to **chaining** and **feedback**:

- Keyer 1 reads pad N. Pad N's source = Keyer 2. Keyer 1 sees Keyer 2's
  previous-frame output. Two keys cascading.
- Keyer 1 reads pad N. Pad N's source = Keyer 1. Keyer 1 sees its own
  previous frame. Self-feedback at one frame of delay — useful for
  smearing a keyed shape against itself.

### Keyer parameters

Open `KEYER CONTROLS…` to access them. Each keyer has its own:

- **Foreground / Background pad** — which two pads feed it.
- **Kind** — Chroma (matches a key color, default green) or Luma
  (matches dark vs. light by threshold).
- **Threshold** — how aggressively to cut. Low = tight key. High =
  generous key.
- **Softness** — feather around the key edge.

Keyers always run when their FG/BG pads resolve to textures. There's no
explicit on/off toggle.

---

## NTSC pipeline

Toggle between **HD** (1280×720 RGB) and **NTSC 4:3** (720×480
simulated composite) using the buttons next to `HDMI` in the bottom
bar. NTSC mode runs the master output through a Metal-based simulation
of the analog composite signal path:

1. Encode RGB → YIQ → composite waveform with simulated chroma
   subcarrier and color burst (4× horizontal oversampling).
2. Mutate the encoded composite signal — chroma boost, sync timing
   wobble, subcarrier phase drift, dropouts, banded noise.
3. Decode back through a chroma demodulator and notch comb filter.

The artifacts are real-NTSC-shaped because they're produced by analog-
style operations on the simulated composite, not faked in RGB. Open the
INSPECT sheet while in NTSC mode for the full glitch panel:

- Chroma boost (0–3×)
- Luma peaking (0–3×)
- HSync wobble (per-line jitter)
- Burst phase shift (whole-frame hue rotate)
- Subcarrier drift (free-running chroma)
- Y/C delay (mismatch between luma and chroma alignment)
- Dropout rate
- Luma noise / Chroma noise (independent)

---

## HDMI output

Plug a **DP-Alt-Mode USB-C HDMI dongle** into the iPad's USB-C port.
DisplayLink-chip dongles will not work — they don't carry full-rate
video. Once attached, an external display window appears automatically.

The HD / NTSC 4:3 toggle drives both the on-screen preview and the
external display, so what you see locally is what's going to the
projector / TV / capture box. Unplugging mid-session is safe; plug back
in to restore the external scene.

If you're combining HDMI out + a UVC camera + USB-MIDI, use a **powered
USB-C hub.** Bus power on the iPad isn't enough for all three.

---

## Sessions and presets

The **SESSION…** button opens the preset manager:

- **DEFAULT** — reset every pad to its bundled clip, all FX off, both
  keyers to defaults, mixer/master/NTSC to defaults. Also clears the
  live-recordings reel. Confirmation alert prevents accidents.
- **SAVE…** — name the current configuration and store it as a JSON in
  `Documents/Sessions/`. Saves: pad sources, FX state, keyer
  configurations, mixer state, NTSC state, and the names of your
  recent live recordings.
- **LOAD** any preset from the list — DEFAULT (factory clean slate) is
  always at the top, your saved presets follow alphabetically.
- **DELETE** removes a saved preset from disk.

The **SETTINGS** gear inside the SESSION sheet lets you choose which
preset loads automatically on app start. The factory `factory` preset
is always available; pick any saved preset as your launch default.

---

## MIDI

p10trancer responds to incoming MIDI on **any channel**. USB-MIDI
controllers (plug into the iPad's USB-C port), Bluetooth MIDI, and
Network MIDI (RTP-MIDI from your computer) all work and auto-discover.

p10trancer also publishes its own outbound virtual MIDI source. When
you touch a fader or button on the iPad, the corresponding MIDI flows
out so a DAW can receive and record it.

### Inbound scheme — Program Changes

| PC | Action |
| --- | --- |
| 1–9 | Route pad 1–9 to the active channel |
| 10 | Active channel = CH 1 |
| 11 | Active channel = CH 2 |
| 12 | Transition = Blur (crossfade) |
| 13 | Transition = Swipe |
| 14 | Transition = Star |
| 15 | Transition = Chroma |
| 16 | Transition = Luma |
| 17 | Toggle HD ↔ NTSC 4:3 |
| 18 | Toggle keyer enable (legacy; both keyers are always live now) |
| 19 | Route Keyer 1 → CH 1 |
| 20 | Route Keyer 1 → CH 2 |
| 21 | Toggle record start/stop |
| 22–30 | Inspect pad 1–9 (subsequent CC 23–34 target the inspected pad) |

### Inbound scheme — Notes

| Note range | Action |
| --- | --- |
| 36–44 | Trigger pad 1–9 (Akai/MPC pad layout) |
| 60–68 | Trigger pad 1–9 (middle C upward) |

### Inbound scheme — Continuous Controllers

All CCs accept 0–127 and the receiver scales to the destination range.

| CC | Function | Range |
| --- | --- | --- |
| 1 | Position fader (CH 1 ↔ CH 2) | 0…1 |
| 2 | Master volume | 0…1 |
| 3 | Keyer threshold | 0…1 |
| 4 | Keyer softness | 0…0.5 |
| 5–13 | Pad 1–9 audio volume | 0…1 each |
| 14 | NTSC chroma boost | 0…3× |
| 15 | NTSC HSync wobble | 0…1 |
| 16 | NTSC subcarrier drift | 0…0.5 |
| 17 | NTSC burst phase shift | -0.5…+0.5 |
| 18 | NTSC Y/C delay | -8…+8 |
| 19 | NTSC dropout rate | 0…1 |
| 20 | NTSC luma noise | 0…0.3 |
| 21 | NTSC chroma noise | 0…0.3 |
| 22 | NTSC luma peaking | 0…3 |
| 23 | (inspected pad) Blur radius | 0…6 |
| 24 | Chroma hue | 0…1 |
| 25 | Chroma saturation | 0…3 |
| 26 | Chroma RGB split | 0…3 |
| 27 | YUV phaser phase | 0…1 |
| 28 | YUV phaser depth | 0…1 |
| 29 | Luma phaser strength | 0…1 |
| 30 | Luma phaser curve | 0.5…8 |
| 31 | Edge enhance strength | 0…3 |
| 32 | Feedback mix | 0…1 |
| 33 | Feedback zoom | 0.85…1.15 |
| 34 | Feedback decay | 0.5…1.0 |

### Outbound

The same scheme is emitted on the outbound virtual source whenever a
control changes from the on-screen UI. Receiving and re-emitting are
muted-during-inbound so the iPad never echoes received messages back
to the host — a Bitwig / Logic / Reaper round-trip is safe.

Endpoint name on the host: `p10trancer` (channel-agnostic, MIDI 1.0).

---

## Recording your performance with a DAW

The iPad's **AutomationEngine** records every gesture you make as MIDI
events, locked to MIDI Clock. The engine is **DAW-agnostic** — works
with any DAW or hardware that outputs MIDI Clock + Start/Stop. There
is no plugin or extension to install.

### One-time setup

1. On macOS: open Audio MIDI Setup → Network. Click the green dot to
   enable network MIDI. (Or use any USB-MIDI / Bluetooth-MIDI source
   that sends Clock + Start/Stop.)
2. On the source side, route a MIDI output to the iPad. The iPad's
   `p10trancer` virtual port is also available as a MIDI input back on
   the source.
3. On the source, enable **MIDI Clock** + **Start/Stop** transmission
   to that network session.

### Recording a take

1. On iPad, tap **AUTO…** → **ARM REC**.
2. Hit play (or record + play) on the source.
3. Perform on iPad — every fader, button, and parameter is captured
   tick-for-tick against the incoming transport.
4. Hit stop on the source. Take saved.

### Playing a take back

1. Tap **AUTO…**, select a take from the list, tap **ARM PLAY**.
2. Hit play on the source. The take re-performs in tempo lock; faders
   and buttons on the iPad animate exactly as you played them.

### Overdub

1. Select the take, toggle **OVERDUB**, tap **ARM REC**.
2. Hit play on the source. The existing take plays back while you
   record. Only the streams you wiggle (specific CCs, notes, PCs) get
   replaced in the take. Untouched streams from earlier passes survive.

That's the full integration. No DAW-specific configuration required —
any device that sends MIDI Clock + Start/Stop drives p10trancer.

---

## Hardware requirements

- **iPad Pro M2 or newer** running iPadOS 17 or later. Older iPads may
  work but are not supported.
- **DP-Alt-Mode USB-C HDMI dongle** for external display. DisplayLink
  dongles will not work.
- **Powered USB-C hub** if you're combining HDMI + UVC + USB-MIDI on
  the iPad's single port.

---

## Files on disk

Reachable from the iPad's Files app under "On My iPad → p10trancer":

- `UserVideos/` — videos you've loaded into pads, plus mix recordings
  (`recording-YYYYMMDD-HHMMSS.mp4`).
- `Sessions/` — saved presets as JSON.
- `Automations/` — saved DAW-locked automation takes as JSON.
- `p10e.log` — last-session log; useful when reporting a bug.

You can copy these out via Files, share them, back them up. The app
never writes anywhere outside its own sandbox.

---

## License

p10trancer is MIT licensed. Bundled sample clips ship under
public-domain or CC-BY licenses; full credits in `ATTRIBUTIONS.md`.

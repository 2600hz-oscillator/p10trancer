# Needed assets for 1.0

Inventory of every visual asset that ships with the App Store build and the
GitHub README, what we have, and what we still need. Update this file as
items are produced and committed.

---

## Brand & naming

- **Display name:** `p10trancer` (lowercase, joke on Roland's *Entrancer*)
- **Stylized form for marketing:** `p.10trancer` — chunky letterforms
  with chroma offset for an NTSC-artifact aesthetic. The "p." reads as
  a stylized abbreviation
- **Bundle ID:** `com.p10entrancer.app` (kept; do not change)
- **GitHub repo:** `2600hz-oscillator/p10trancer`

When writing copy: prefer **p10trancer** in body text; use **p.10trancer**
where the stylized brand mark is appropriate (loading screens, hero
images, App Store hero).

---

## App icon

| Asset | Status | Source / path |
| --- | --- | --- |
| 1024×1024 master PNG | **Provided** ✓ | `P10Entrancer/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (user-supplied photograph of the user's modular gear, p.10trancer wordmark composited on top with chroma fringing) |
| Source PSD/AI of wordmark | TODO | If we ever want to redo the wordmark independent of the photo, need an editable source |

**Notes:**
- iPadOS 17+ uses the universal 1024 icon; Apple downsamples for all other
  sizes automatically. No separate spotlight/notification sizes needed.
- Confirm the icon clears Apple's review for "no third-party trademark in
  background." The photo is of the user's own gear with no visible foreign
  logos — confirmed.
- Icon should still read clearly when downsampled to 76×76 (iPad home
  screen). If at that size the wordmark is illegible, future revision may
  need to either drop the wordmark or zoom in on it.

---

## Launch screen

| Asset | Status | Path |
| --- | --- | --- |
| Launch storyboard / SwiftUI launch view | TODO | `P10Entrancer/Resources/Info.plist > UILaunchScreen` (currently bare) |

**Spec:** plain black background with the `p.10trancer` wordmark centered
small, no spinner, no version text. Goal: looks like a piece of broadcast
gear powering up. Should use the same wordmark crop as the app icon for
visual continuity.

---

## App Store Connect — listing imagery

Required for App Store submission. None of these exist yet.

| Asset | Required size | Count | Status |
| --- | --- | --- | --- |
| **App preview video** (optional but high-impact) | 1600×1200 (iPad landscape) | 1–3 of up to 30s each | TODO |
| **iPad Pro 12.9" / 13" screenshots** | 2048×2732 portrait or 2732×2048 landscape | 3–10 | TODO |
| **iPad Pro 11" screenshots** | 1668×2388 portrait or 2388×1668 landscape | 3–10 | TODO |

**Recommended screenshot set** (capture in landscape on the M2 iPad Pro):
1. Hero — output preview showing NTSC glitch on a pad source, full UI visible
2. Pad grid with all 9 cells live, mid-transition between CH1 and CH2
3. Inspector sheet — per-pad FX with feedback dialed up
4. Keyer Controls — chroma-keyed composite + the keyer config sheet open
5. Live Recordings reel populated, with selection highlighted
6. AutomationEngine panel — recording armed
7. Bitwig running alongside (for the integration story) — split shot of
   iPad screen + Bitwig automation lane

Capture via `scripts/fetch.sh --shots`; trim/crop to App Store dimensions.

---

## README hero imagery

The repository README on `main` (heritage-focused) and the user-facing
docs on `release-1.0` need:

| Asset | Status | Path |
| --- | --- | --- |
| **README hero image** (1600×900-ish, GitHub-friendly) | TODO | `art/hero.jpg` — recommend a captured live mix output frame with mild NTSC artifacts, with the wordmark overlaid bottom-right |
| **Per-section illustrations / screenshots in `USAGE.md`** | TODO | `art/usage/*.png` — one per major feature: pads, channels, FX, NTSC, keyer, automation. Best as actual app screenshots with annotation arrows |
| **Architecture diagram for `DEVELOPER.md`** | TODO | `art/architecture.svg` — boxes for RenderEngine, Pads, Channels, Keyers, NTSC, Output. Can be mermaid markdown rendered inline if SVG is overkill |
| **MIDI scheme cheat sheet image** for `MIDI.md` | TODO | `art/midi-map.png` — visual map of all PCs and CCs, easier to scan than the table |

---

## In-app art

| Asset | Status | Notes |
| --- | --- | --- |
| **Empty live-recordings slot illustration** | Optional | Currently dashed-border outline + transparent fill. A subtle "no signal" SMPTE-bars placeholder would be a nice touch |
| **Empty pad placeholder** when source is `.empty` (e.g., disconnected camera) | Currently black | Could replace with a subtle "no signal" pattern. Low priority — black reads correctly |
| **About / help sheet header art** | TODO | Tiny banner showing the wordmark, used in the About sheet (which itself doesn't exist yet — see USAGE.md plan) |

---

## Audio

The app ships no bundled audio (it samples audio from the user's video
clips). No audio assets needed for the App Store cut.

---

## Bundled video clips (already in place)

`P10Entrancer/Resources/TestAssets/pad1.mp4` … `pad9.mp4` — sourced from
public-domain or CC-BY material on archive.org. See `ATTRIBUTIONS.md` for
the full credits. **No new video assets needed.**

---

## Production checklist (icon → ship)

When all of the above are produced, run through this:

- [ ] AppIcon.png replaced with final 1024
- [ ] Launch screen storyboard / view added
- [ ] App Store Connect listing imagery uploaded (preview + screenshots)
- [ ] README hero image landed in `art/hero.jpg`
- [ ] `USAGE.md` populated with screenshots
- [ ] Architecture diagram in `DEVELOPER.md`
- [ ] About/Help sheet in-app linked to GitHub support page
- [ ] All copy in Info.plist + docs reads as "p10trancer"
- [ ] App icon legible at 76×76 (iPad home screen actual size)

---

*This file is the single source of truth for "what art still needs to be
made." Keep it current — adding a TODO here is preferable to chasing
"oh, also I need…" mid-review.*

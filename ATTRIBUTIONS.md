# Bundled Demo Clips — Attribution & Licenses

The 9 demo clips bundled in `P10Entrancer/Resources/TestAssets/` are sourced from public-domain or permissively-licensed material on archive.org, plus two synthetic test patterns generated locally with ffmpeg. All are cleared for redistribution including in commercial App Store builds.

| Slot | Clip | Source | License | Year |
|---|---|---|---|---|
| 1 | SMPTE Color Bars w/ 1 kHz Tone | [archive.org/details/ColorBarsWTone](https://archive.org/details/ColorBarsWTone) | Public Domain (SMPTE bars are not copyrightable per CBS) | — |
| 2 | Apollo 11 Saturn V Launch — Camera E-8 | [archive.org/details/youtube-DKtVpvzUF1Y](https://archive.org/details/youtube-DKtVpvzUF1Y) | Public Domain (NASA, 17 USC §105) | 1969 |
| 3 | VHS Glitch — Volume 1 | [archive.org/details/vhs_glitch_vol_1](https://archive.org/details/vhs_glitch_vol_1) | **CC BY 4.0** — see attribution below | — |
| 4 | Design for Dreaming | [archive.org/details/Designfo1956](https://archive.org/details/Designfo1956) | Public Domain (no copyright notice / not renewed) | 1956 |
| 5 | Birds of Prey (Erpi Classroom Films) | [archive.org/details/4086_Birds_of_Prey](https://archive.org/details/4086_Birds_of_Prey) | Public Domain (Prelinger Archives) | 1933 |
| 6 | Out of the Inkwell: Fishing | [archive.org/details/FishingCartoon](https://archive.org/details/FishingCartoon) | Public Domain (1921, copyright expired) | 1921 |
| 7 | Koko's Earth Control | [archive.org/details/kokos-earth-control](https://archive.org/details/kokos-earth-control) | Public Domain (1928, copyright expired) | 1928 |
| 8 | SMPTE color bars (synthetic) | Generated via `ffmpeg -f lavfi -i smptebars` | Public Domain | — |
| 9 | Mandelbrot fractal (synthetic) | Generated via `ffmpeg -f lavfi -i mandelbrot` | Public Domain | — |

## Required attribution (CC BY 4.0)

> "VHS Glitch — Volume 1" © Christopher Huppertz, licensed under [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/). Sourced from [archive.org/details/vhs_glitch_vol_1](https://archive.org/details/vhs_glitch_vol_1).

## Notes

- All clips were re-encoded to H.264 480×270 with AAC mono audio (where audio existed) using `ffmpeg`. See `/tmp/p10e-clips/encode.sh` in dev for the exact transcoding command.
- The original archive.org files are larger and at original resolution. Source files are not bundled — only the trimmed/scaled segments shipping in `TestAssets/`.
- Mix recordings made by the user (via the REC button) are stored under `Documents/UserVideos/` in the app's sandbox and appear in the Live Recordings reel; the user assigns them to pads from there.
- Users can load arbitrary video files into any pad via the per-pad context menu (long-press → Load Video…). Those files live in `Documents/UserVideos/` and are licensed however the user obtained them.

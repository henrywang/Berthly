# Berthly DMG — drag-to-install window

Assets for the branded install window `scripts/dmg.sh` assembles: a brand-blue
background with a dotted "mooring line" arrow (the icon's rope motif) pointing
from the app to the Applications symlink, plus the mounted-volume icon.

## Files

| File | Role |
| --- | --- |
| `background.svg` | Background source, authored at 2x (window is 660×420 pt, art is 1320×840). |
| `render_bg.swift` | Non-square NSImage/CoreSVG rasterizer (width×height variant of `../icon/render_svg.swift`). |
| `build.sh` | Renders `background.tiff` (1x + 2x HiDPI TIFF via `tiffutil -cathidpicheck`) and `Berthly-volume.icns` from the margined icon masters. |

Rendered artifacts (`*.png`, `*.tiff`, `*.icns`, `build/`) are gitignored —
`scripts/dmg.sh` runs `build.sh` on demand.

## Design notes

- **Mid-luminance blue, deliberately.** Finder draws icon labels black in
  light mode and white in dark mode, and the background picture can't adapt.
  The brand gradient (`#3F82EC → #1D4FA8`) keeps ≥3.3:1 contrast against
  both, so the layout survives either appearance. Don't swap in a very light
  or very dark background without rechecking that.
- **No `<filter>`, no `rotate()`, absolute coordinates only** — CoreSVG drops
  filters and mishandles rotate transforms (see rendering notes in
  `../icon/README.md` and `build.sh`).
- **Geometry contract with `scripts/dmg.sh`**: window content 660×420, icons
  128 px centered at (170, 195) and (490, 195). The arrow and text in
  `background.svg` are positioned for exactly that layout — change one, change
  both.

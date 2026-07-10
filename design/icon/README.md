# Berthly icon — source

The mark is a **dock bollard with a mooring line made fast** ("C2a") — the app
sits *berthed* at the dock. Brand blue `#2A6FDB`, rope/water tints `#B9D4FB`
and `#8FB6F0`.

## Files

| File | Role |
| --- | --- |
| `gen_icons.py` | Parametric source. Emits the five `.svg` files below. Owns the Apple-squircle math (superellipse, n=5), the 824/1024 body-with-margin layout, and the full-vs-simplified artwork. |
| `berthly-master-1024.svg` | App-icon master, full detail, baked drop shadow. Used for ≥128px. |
| `berthly-small-512.svg` | Simplified master (one heavy rope wrap, chunkier forms) so 16/32px stay legible. |
| `berthly-favicon-512.svg` | Full-bleed squircle for web favicons. |
| `berthly-touch-512.svg` | Full-bleed square for `apple-touch-icon` (iOS applies its own mask). |
| `berthly-menubar-36.svg` | Single-color bollard glyph for the menu-bar template. |
| `render_svg.swift` | NSImage/CoreSVG rasterizer helper (see rendering note). |
| `build.sh` | Regenerates everything and installs the shipping assets into the app catalogs. |

The `.svg` files are emitted by `gen_icons.py`; edit the artwork there, or edit
an `.svg` directly for a one-off — but note a `gen_icons.py` run overwrites them.

## Rebuild

```sh
./build.sh
```

This regenerates the SVGs, rasterizes them, builds `build/Berthly.iconset` +
`build/Berthly.icns`, and copies the shipping PNGs into
`Berthly/Assets.xcassets/{AppIcon.appiconset,MenuBarIcon.imageset}`. The
`build/` output is throwaway (gitignored); the committed shipping assets are
the catalog PNGs.

## Rendering note

No `rsvg`/`inkscape`/`imagemagick` on the machine — macOS's two built-in SVG
rasterizers have complementary bugs:

- **`qlmanage -t`** honors SVG `<filter>` (the `feDropShadow` on the app icon)
  but mis-lays-out canvases below ~512px.
- **NSImage/CoreSVG** (`render_svg.swift`) scales correctly at any size but
  silently ignores `<filter>`.

So shadowed app-icon masters render through `qlmanage` at ≥512 and downsample
with `sips`; filter-free art (menu bar, favicon, touch) renders through the
Swift helper. `build.sh` already routes each file correctly.

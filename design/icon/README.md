# Berthly icon — source

The mark is a **dock bollard with a mooring line made fast** ("C2a") — the app
sits *berthed* at the dock. Brand blue `#2A6FDB`, rope/water tints `#B9D4FB`
and `#8FB6F0`.

## Files

| File | Role |
| --- | --- |
| `gen_icons.py` | Parametric source. Emits the `.svg` files below. Owns the Apple-squircle math (superellipse, n=5) and the full-vs-simplified artwork. |
| `berthly-dock-1024.svg` | **App-icon master** (≥128px sizes). Full-bleed, no margin, no baked shadow — see icon-format note. |
| `berthly-favicon-512.svg` | Full-bleed simplified master (one heavy rope wrap, chunkier forms): web favicons **and** the 16/32px app-icon sizes. |
| `berthly-master-1024.svg` | Big Sur-style margined master with baked shadow. dmg volume icon only. |
| `berthly-small-512.svg` | Margined simplified master. dmg pipeline only. |
| `berthly-touch-512.svg` | Full-bleed square for `apple-touch-icon` (iOS applies its own mask). |
| `berthly-menubar-36.svg` | Single-color bollard glyph for the menu-bar template. |
| `render_svg.swift` | NSImage/CoreSVG rasterizer helper (see rendering note). |
| `build.sh` | Regenerates everything and installs the shipping assets into the app catalogs. |

## Icon-format note (macOS 26 "Tahoe")

Berthly targets macOS 26+, and Tahoe changed the rules: legacy asset-catalog
icons whose artwork is **smaller than the canvas** (the classic Big Sur
824/1024 body + transparent margin + baked shadow) get scaled down and placed
on a white system backdrop — the "icon jail" ring. Full-bleed artwork is
displayed as-is, with the system supplying mask and shadow. So the app-icon
PNGs are generated **full-bleed** with no baked shadow; the margined masters
survive only for the dmg volume icon, which macOS still renders the old way.

The fully-native path would be an Icon Composer `.icon` package (layered,
Liquid Glass); the layered SVG sources here are ready for that conversion.

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

So the shadowed dmg masters render through `qlmanage` at ≥512 and downsample
with `sips`; all filter-free art (app icon, menu bar, favicon, touch) renders
through the Swift helper. `build.sh` already routes each file correctly.

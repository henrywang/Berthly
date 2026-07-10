#!/bin/bash
# Regenerate the full Berthly icon pack from the SVG sources in this directory
# and install the shipping assets into the app's asset catalogs.
#
# Rendering note: with no rsvg/inkscape/imagemagick on the machine, macOS gives
# two built-in SVG rasterizers with complementary bugs —
#   - qlmanage honors SVG <filter> (feDropShadow) but mis-lays-out canvases <512px
#   - NSImage/CoreSVG (render_svg.swift) scales at any size but drops <filter>
# So: shadowed masters go through qlmanage at >=512 then downsample; filter-free
# small art (menu bar, favicon) goes through the Swift renderer.
set -e
cd "$(dirname "$0")"
DIR="$(pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
CATALOG="$REPO/Berthly/Assets.xcassets"

render() { swift "$DIR/render_svg.swift" "$1" "$2" "$3"; }

# 1. (re)emit SVG sources from the parametric generator
python3 "$DIR/gen_icons.py" >/dev/null

# 2. rasterize masters
#    app icon (macOS 26+): FULL-BLEED, no margin/shadow — Tahoe puts
#    smaller-than-canvas artwork on a white system backdrop ("icon jail")
#    and supplies its own mask + shadow for full-bleed art.
#    All full-bleed masters are filter-free -> NSImage renderer.
render berthly-dock-1024.svg   berthly-dock-1024.png   1024
render berthly-favicon-512.svg berthly-favicon-512.png 512
render berthly-touch-512.svg   berthly-touch-512.png   512
render berthly-menubar-36.svg  berthly-menubar-144.png 144
#    margined Big Sur-style masters (dmg volume icon only) -> qlmanage
#    (>=512, honors the baked feDropShadow)
qlmanage -t -s 1024 -o . berthly-master-1024.svg >/dev/null 2>&1 && mv -f berthly-master-1024.svg.png berthly-master-1024.png
qlmanage -t -s 512  -o . berthly-small-512.svg   >/dev/null 2>&1 && mv -f berthly-small-512.svg.png   berthly-small-512.png

# 3. app icon set + .icns (staged in build/)
IS="$DIR/build/Berthly.iconset"
mkdir -p "$IS"
cp berthly-dock-1024.png "$IS/icon_512x512@2x.png"
sips -z 512 512 berthly-dock-1024.png   --out "$IS/icon_512x512.png"    >/dev/null
cp "$IS/icon_512x512.png" "$IS/icon_256x256@2x.png"
sips -z 256 256 berthly-dock-1024.png   --out "$IS/icon_256x256.png"    >/dev/null
cp "$IS/icon_256x256.png" "$IS/icon_128x128@2x.png"
sips -z 128 128 berthly-dock-1024.png   --out "$IS/icon_128x128.png"    >/dev/null
sips -z 64  64  berthly-favicon-512.png --out "$IS/icon_32x32@2x.png"   >/dev/null
sips -z 32  32  berthly-favicon-512.png --out "$IS/icon_32x32.png"      >/dev/null
cp "$IS/icon_32x32.png" "$IS/icon_16x16@2x.png"
sips -z 16  16  berthly-favicon-512.png --out "$IS/icon_16x16.png"      >/dev/null
iconutil -c icns "$IS" -o "$DIR/build/Berthly.icns"

# 4. install shipping assets into the app catalogs
cp "$IS"/icon_*.png "$CATALOG/AppIcon.appiconset/"
sips -z 18 18 berthly-menubar-144.png --out "$CATALOG/MenuBarIcon.imageset/berthly-Template.png"    >/dev/null
sips -z 36 36 berthly-menubar-144.png --out "$CATALOG/MenuBarIcon.imageset/berthly-Template-2x.png" >/dev/null

echo "Icon pack rebuilt and installed into $CATALOG"

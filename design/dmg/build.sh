#!/bin/bash
# Render the DMG assets consumed by scripts/dmg.sh:
#   background.tiff     — drag-to-install window background (1x + 2x HiDPI TIFF)
#   Berthly-volume.icns — mounted-volume icon
#
# Background renders through the NSImage/CoreSVG helper, not qlmanage:
# qlmanage square-pads a non-square canvas (this art is 1320x840), and
# CoreSVG both honors <text> and needs no <filter> here. Note CoreSVG
# mishandles rotate() transforms — background.svg keeps all geometry in
# absolute coordinates.
#
# The volume icon uses the margined Big Sur-style masters (see
# ../icon/README.md): Finder still renders volume icons the pre-Tahoe way,
# so full-bleed art would show unmasked square corners. The masters render
# here from their SVGs (render_volume_icon.swift), NOT from ../icon's
# qlmanage PNGs — qlmanage composites onto opaque white, which puts a white
# square behind the squircle.
set -e
cd "$(dirname "$0")"
ICON="../icon"

# ── background: 1x + 2x combined into one HiDPI TIFF ────────────────────────
swift render_bg.swift background.svg background@2x.png 1320 840
sips -z 420 660 background@2x.png --out background.png >/dev/null
tiffutil -cathidpicheck background.png background@2x.png -out background.tiff

# ── volume icon ─────────────────────────────────────────────────────────────
MASTER="build/volume-master-1024.png"
SMALL="build/volume-small-512.png"
IS="build/BerthlyVolume.iconset"
mkdir -p "$IS"
swift render_volume_icon.swift "$ICON/berthly-master-1024.svg" "$MASTER" 1024
swift render_volume_icon.swift "$ICON/berthly-small-512.svg"   "$SMALL"  512
cp "$MASTER" "$IS/icon_512x512@2x.png"
sips -z 512 512 "$MASTER" --out "$IS/icon_512x512.png"  >/dev/null
cp "$IS/icon_512x512.png" "$IS/icon_256x256@2x.png"
sips -z 256 256 "$MASTER" --out "$IS/icon_256x256.png"  >/dev/null
cp "$IS/icon_256x256.png" "$IS/icon_128x128@2x.png"
sips -z 128 128 "$MASTER" --out "$IS/icon_128x128.png"  >/dev/null
sips -z 64  64  "$SMALL"  --out "$IS/icon_32x32@2x.png" >/dev/null
sips -z 32  32  "$SMALL"  --out "$IS/icon_32x32.png"    >/dev/null
cp "$IS/icon_32x32.png" "$IS/icon_16x16@2x.png"
sips -z 16  16  "$SMALL"  --out "$IS/icon_16x16.png"    >/dev/null
iconutil -c icns "$IS" -o Berthly-volume.icns

echo "DMG assets rebuilt: background.tiff, Berthly-volume.icns"

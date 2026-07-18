#!/bin/bash
#
# Assemble the branded drag-to-install DMG.
#
#   usage: scripts/dmg.sh <Berthly.app> <version> <output.dmg>
#
# Window: 660x420 content, no toolbar/statusbar, 128px icons —
# Berthly.app at (170,195), Applications symlink at (490,195), brand-blue
# background with a dotted mooring-line arrow between them, custom volume
# icon. Assets render from design/dmg (geometry contract documented there).
#
# Finder persists the layout in the volume's .DS_Store, which can only be
# written on a mounted read-write image — hence: staging folder → UDRW image
# → attach → Finder AppleScript → detach → convert to compressed UDZO.
# The AppleScript step needs Automation permission for Finder (one-time TCC
# prompt on first run from a given terminal).
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <Berthly.app> <version> <output.dmg>" >&2
  exit 1
fi
APP="$1"
VERSION="$2"
OUT="$3"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$REPO/design/dmg"
VOLNAME="Berthly $VERSION"

"$ASSETS/build.sh" >/dev/null

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGING="$WORK/staging"
RW_DMG="$WORK/rw.dmg"

mkdir -p "$STAGING/.background"
ditto "$APP" "$STAGING/Berthly.app"
ln -s /Applications "$STAGING/Applications"
cp "$ASSETS/background.tiff" "$STAGING/.background/background.tiff"

hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDRW "$RW_DMG"

# A stale mount from a crashed run would make this one mount at
# "<volname> 1", desyncing the AppleScript's disk name — clear it first.
if [[ -d "/Volumes/$VOLNAME" ]]; then
  hdiutil detach "/Volumes/$VOLNAME" -force
fi
ATTACH_OUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
MOUNT="$(grep -o '/Volumes/.*' <<<"$ATTACH_OUT" | head -1)"

osascript <<EOF
tell application "Finder"
  tell disk "$(basename "$MOUNT")"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- bounds include the ~28pt title bar; content area is 660x420
    set the bounds of container window to {200, 120, 860, 568}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Berthly.app" of container window to {170, 195}
    set position of item "Applications" of container window to {490, 195}
    update without registering applications
    delay 1
    -- again: Finder drops a bounds set that lands mid-open-animation
    set the bounds of container window to {200, 120, 860, 568}
    delay 1
    close
  end tell
end tell
EOF

# Volume icon: .VolumeIcon.icns on the mounted volume plus the
# kHasCustomIcon Finder flag on its root (FinderInfo byte 8 = 0x04; SetFile
# is deprecated, the xattr is not). Both must happen *after* the layout
# pass — hdiutil create -srcfolder drops a staged .VolumeIcon.icns, and the
# Finder AppleScript above deletes the file and rewrites the root's
# FinderInfo when it saves the window state (verified empirically).
cp "$ASSETS/Berthly-volume.icns" "$MOUNT/.VolumeIcon.icns"
xattr -wx com.apple.FinderInfo \
  "0000000000000000040000000000000000000000000000000000000000000000" "$MOUNT"

sync
hdiutil detach "$MOUNT"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT"

#!/bin/bash
#
# Release pipeline for Berthly (see PLAN/UPGRADE.md):
#   archive → Developer ID export → notarize + staple → zip → generate_appcast → GitHub release
#
# One-time setup this script assumes (all done 2026-07-14):
#   - "Developer ID Application" certificate in the login keychain
#   - notarytool credentials stored:  xcrun notarytool store-credentials berthly-notary ...
#   - Sparkle EdDSA key in the login keychain (generate_keys); its public half is
#     SUPublicEDKey in Config/Info.plist
#
# Usage:
#   scripts/release.sh
#
# The version comes from MARKETING_VERSION — bump it (plus CURRENT_PROJECT_VERSION)
# before running. The appcast only carries the newest release: Sparkle just needs the
# latest entry to offer an update, and single-entry feeds sidestep stale download URLs
# when each release hosts its own assets. (Delta updates need past zips kept around —
# revisit if release cadence ever makes full downloads annoying.)

set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${BERTHLY_NOTARY_PROFILE:-berthly-notary}"
TEAM_ID="4H628G9PWH"
REPO_URL="https://github.com/henrywang/Berthly"
DIST="dist"

# ── Preflight ────────────────────────────────────────────────────────────────
if ! command -v gh >/dev/null; then
  echo "error: gh CLI not found (brew install gh)" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "error: no Developer ID Application identity in the keychain." >&2
  echo "  Xcode → Settings → Accounts → Manage Certificates… → + → Developer ID Application" >&2
  exit 1
fi

SPARKLE_BIN=$(find "$HOME/Library/Developer/Xcode/DerivedData" -type d \
  -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin" 2>/dev/null | head -1)
if [[ -z "$SPARKLE_BIN" ]]; then
  echo "error: Sparkle tools not found in DerivedData — build Berthly once so SPM fetches them." >&2
  exit 1
fi

VERSION=$(xcodebuild -project Berthly.xcodeproj -scheme Berthly -showBuildSettings 2>/dev/null |
  awk '/MARKETING_VERSION/ { print $3; exit }')
TAG="v$VERSION"
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "error: release $TAG already exists — bump MARKETING_VERSION first." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "warning: working tree is dirty; the archive will include uncommitted changes." >&2
fi

echo "──> Releasing Berthly $VERSION as $TAG"
rm -rf "$DIST"
mkdir -p "$DIST"

# ── Archive & export with Developer ID ───────────────────────────────────────
ARCHIVE="$DIST/Berthly.xcarchive"
xcodebuild archive \
  -project Berthly.xcodeproj -scheme Berthly \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE" | tail -2

cat > "$DIST/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$DIST/ExportOptions.plist" \
  -exportPath "$DIST/export" | tail -2

APP="$DIST/export/Berthly.app"

# ── Notarize, staple, final zip ──────────────────────────────────────────────
# Submit a zip, but staple the .app (tickets can't attach to zips) and re-zip:
# the stapled copy keeps Gatekeeper happy even offline.
ZIP_NAME="Berthly-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$DIST/notarize-$ZIP_NAME"
echo "──> Notarizing (waits for Apple; typically a few minutes)…"
xcrun notarytool submit "$DIST/notarize-$ZIP_NAME" \
  --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl -a -vv "$APP"

APPCAST_DIR="$DIST/appcast"
mkdir -p "$APPCAST_DIR"
ditto -c -k --keepParent "$APP" "$APPCAST_DIR/$ZIP_NAME"

# ── Appcast (EdDSA-signed from the keychain key) ─────────────────────────────
"$SPARKLE_BIN/generate_appcast" "$APPCAST_DIR" \
  --download-url-prefix "$REPO_URL/releases/download/$TAG/" \
  --link "$REPO_URL"

# ── GitHub release ───────────────────────────────────────────────────────────
# SUFeedURL points at releases/latest/download/appcast.xml, so attaching the feed
# to every release automatically serves the newest one.
gh release create "$TAG" \
  "$APPCAST_DIR/$ZIP_NAME" \
  "$APPCAST_DIR/appcast.xml" \
  --title "Berthly $VERSION" \
  --generate-notes

echo "──> Done: $REPO_URL/releases/tag/$TAG"

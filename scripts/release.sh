#!/bin/bash
#
# Release pipeline for Berthly (see PLAN/UPGRADE.md):
#   archive → Developer ID export → DMG → notarize + staple → generate_appcast → GitHub release
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
# when each release hosts its own assets. (Delta updates need past DMGs kept around —
# revisit if release cadence ever makes full downloads annoying.)
#
# Ships a DMG, not a zip: zip can't hold com.apple.provenance (a kernel-set,
# unremovable xattr every build file carries), so `ditto -c` AppleDouble-encodes
# it — `ditto -x`/Finder reconstitutes that fine on extraction, but plain
# `unzip` doesn't, and materializes literal ._* files that corrupt Sparkle's
# nested Installer.xpc seal (see 2026-07-16 incident: v1.0 shipped this way
# and failed spctl for anyone who extracted with `unzip`). A DMG is a real
# filesystem image — xattrs live on it natively, no encoding involved — and
# Sparkle 2.x supports .dmg update packages directly, so this covers both the
# manual download and the in-app auto-update with one artifact.

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
DEVID_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" |
  head -1 | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ "(.*)"$/\1/')
if [[ -z "$DEVID_IDENTITY" ]]; then
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

# ── Test gate + coverage for the notes ───────────────────────────────────────
# A release refuses to ship on a red unit suite, and the run doubles as the
# source of the release notes' Testing section: test count plus line coverage
# of the logic layer (Berthly/Core). Core, not whole-app: SwiftUI view bodies
# dominate the app's line count and are deliberately covered by the UI/E2E
# suites instead of unit tests (see CLAUDE.md), so whole-app line coverage
# would understate how tested the logic actually is.
echo "──> Running unit tests (release gate + coverage)…"
RESULT_BUNDLE="$DIST/tests.xcresult"
xcodebuild -project Berthly.xcodeproj -scheme Berthly \
  -destination "platform=macOS" \
  test -only-testing:BerthlyTests \
  -enableCodeCoverage YES -resultBundlePath "$RESULT_BUNDLE" \
  > "$DIST/test.log" 2>&1 || {
    echo "error: unit tests failed — not releasing. See $DIST/test.log" >&2
    exit 1
  }
UNIT_COUNT=$(grep -cE "Test case .* passed" "$DIST/test.log")
# Two numbers: Core overall, and Core minus the I/O plumbing (daemon XPC,
# PTY bridge, notifications, updater) that is deliberately covered by the
# real-daemon E2E suite instead of in-process unit tests. Keep IO_FILES in
# sync when a new I/O-heavy Core file appears.
read -r CORE_COVERAGE LOGIC_COVERAGE < <(xcrun xccov view --report --json "$RESULT_BUNDLE" | /usr/bin/python3 -c '
import json, sys
IO_FILES = {"LiveContainerService.swift", "TerminalSession.swift", "AppNotifier.swift", "UpdaterService.swift"}
report = json.load(sys.stdin)
core_c = core_t = logic_c = logic_t = 0
for target in report.get("targets", []):
    for f in target.get("files", []):
        path = f.get("path", "")
        if "/Berthly/Core/" not in path:
            continue
        c, t = f.get("coveredLines", 0), f.get("executableLines", 0)
        core_c += c; core_t += t
        if path.split("/")[-1] not in IO_FILES:
            logic_c += c; logic_t += t
pct = lambda c, t: f"{100 * c / t:.0f}" if t else "?"
print(pct(core_c, core_t), pct(logic_c, logic_t))
')
UI_COUNT=$(grep -rh "func test" BerthlyUITests/*.swift | wc -l | tr -d " ")
E2E_COUNT=$(grep -rh "func test" BerthlyE2ETests/*.swift | wc -l | tr -d " ")
echo "──> Gate passed: $UNIT_COUNT unit tests, Core coverage ${CORE_COVERAGE}%"

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

# ── DMG, notarize, staple ─────────────────────────────────────────────────
# Standard drag-to-install layout: the app plus an /Applications symlink.
DMG_NAME="Berthly-$VERSION.dmg"
DMG_PATH="$DIST/$DMG_NAME"
STAGING="$DIST/dmg-staging"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Berthly.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Berthly $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING"

codesign --force --sign "$DEVID_IDENTITY" "$DMG_PATH"
echo "──> Notarizing (waits for Apple; typically a few minutes)…"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
spctl -a -vv "$DMG_PATH"

APPCAST_DIR="$DIST/appcast"
mkdir -p "$APPCAST_DIR"
cp "$DMG_PATH" "$APPCAST_DIR/$DMG_NAME"

# ── Appcast (EdDSA-signed from the keychain key) ─────────────────────────────
"$SPARKLE_BIN/generate_appcast" "$APPCAST_DIR" \
  --download-url-prefix "$REPO_URL/releases/download/$TAG/" \
  --link "$REPO_URL"

# ── Release notes ────────────────────────────────────────────────────────────
# Hand `gh` a notes file instead of --generate-notes: auto-notes are built from
# merged PRs and this repo ships direct commits, so they came out empty. The
# Testing section carries the numbers the gate above measured — evidence, not
# a claim. Edit $DIST/notes.md between the marker comments before running if a
# release wants human highlights on top.
NOTES="$DIST/notes.md"
PREV_TAG=$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || true)
cat > "$NOTES" <<EOF
## Testing

This release shipped only after its gate run passed on the release commit:

- **$UNIT_COUNT unit tests** passed — **${LOGIC_COVERAGE}% line coverage of the pure
  logic layer** (\`Berthly/Core\` models, mapping, and planning; ${CORE_COVERAGE}%
  including the daemon/terminal I/O plumbing, which the end-to-end suite
  exercises against a real daemon instead).
- **$UI_COUNT UI tests** (deterministic mock-daemon XCUITest) and
  **$E2E_COUNT real-daemon end-to-end journeys** guard the UI wiring and the
  daemon integration. SwiftUI view bodies are covered by these suites, not
  unit tests, by design.
EOF
if [[ -n "$PREV_TAG" ]]; then
  printf '\n**Full Changelog**: %s/compare/%s...%s\n' "$REPO_URL" "$PREV_TAG" "$TAG" >> "$NOTES"
fi

# ── GitHub release ───────────────────────────────────────────────────────────
# SUFeedURL points at releases/latest/download/appcast.xml, so attaching the feed
# to every release automatically serves the newest one.
gh release create "$TAG" \
  "$APPCAST_DIR/$DMG_NAME" \
  "$APPCAST_DIR/appcast.xml" \
  --title "Berthly $VERSION" \
  --notes-file "$NOTES"

echo "──> Done: $REPO_URL/releases/tag/$TAG"

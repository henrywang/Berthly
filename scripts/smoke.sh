#!/bin/bash
#
# Smoke test for the *installed, shipped* Berthly.app — distribution-artifact
# integrity that BerthlyE2ETests structurally can't reach. e2e.sh strips the
# app-sandbox entitlement and re-signs the runner ad-hoc (see CLAUDE.md), so
# it never exercises the real notarized, Hardened Runtime, Developer
# ID-signed binary a user actually downloads. This script checks that
# artifact instead: code signing, Gatekeeper/notarization acceptance,
# Info.plist sanity, the Sparkle appcast's reachability and shape, and a bare
# launch/quit. It does not touch app logic or UI journeys — that's
# BerthlyTests/BerthlyUITests/BerthlyE2ETests's job.
#
# Usage:
#   scripts/smoke.sh                                  # /Applications/Berthly.app
#   BERTHLY_APP_PATH=/path/to/Berthly.app scripts/smoke.sh
#
# Exits non-zero if any check fails. Runs every check regardless of earlier
# failures so one broken thing doesn't hide the rest of the report.

set -uo pipefail
cd "$(dirname "$0")/.."

APP="${BERTHLY_APP_PATH:-/Applications/Berthly.app}"
APP_NAME="Berthly"
EXPECTED_BUNDLE_ID="app.berthly.Berthly"

FAILURES=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILURES=$((FAILURES + 1)); }

echo "── Smoke test: $APP ──────────────────────────────────────────────"

if [[ ! -d "$APP" ]]; then
  echo "error: app not found at $APP (set BERTHLY_APP_PATH)" >&2
  exit 1
fi

# ── Code signing ─────────────────────────────────────────────────────────
echo
echo "Code signing"
if VERIFY_OUT=$(codesign --verify --deep --strict "$APP" 2>&1); then
  pass "codesign --verify --deep --strict"
else
  fail "codesign --verify --deep --strict: $VERIFY_OUT"
fi

CODESIGN_INFO=$(codesign -dv "$APP" 2>&1)
if grep -q "flags=0x10000(runtime)" <<<"$CODESIGN_INFO"; then
  pass "Hardened Runtime enabled"
else
  fail "Hardened Runtime not enabled (expected flags=0x10000(runtime) from codesign -dv)"
fi

if grep -q "^TeamIdentifier=" <<<"$CODESIGN_INFO" && ! grep -q "^TeamIdentifier=not set" <<<"$CODESIGN_INFO"; then
  pass "Signed with a Developer ID team"
else
  fail "no Developer ID team identifier (ad-hoc signed?)"
fi

ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)
if grep -A1 "com.apple.security.app-sandbox" <<<"$ENTITLEMENTS" | grep -q "<true/>"; then
  fail "app-sandbox entitlement is true — would block CLI/XPC access to the container daemon"
else
  pass "not app-sandboxed (required to reach the container daemon)"
fi

# ── Gatekeeper / notarization ─────────────────────────────────────────────
echo
echo "Gatekeeper / notarization"
if SPCTL_OUT=$(spctl -a -vvv -t exec "$APP" 2>&1); then
  pass "spctl accepts ($(grep -o 'source=.*' <<<"$SPCTL_OUT" || echo "$SPCTL_OUT"))"
else
  fail "spctl rejected: $SPCTL_OUT"
fi

# ── Info.plist sanity ──────────────────────────────────────────────────────
echo
echo "Info.plist"
PLIST="$APP/Contents/Info.plist"
plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }

ACTUAL_BUNDLE_ID=$(plist_get CFBundleIdentifier)
if [[ "$ACTUAL_BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]]; then
  pass "CFBundleIdentifier == $EXPECTED_BUNDLE_ID"
else
  fail "CFBundleIdentifier == '$ACTUAL_BUNDLE_ID', expected $EXPECTED_BUNDLE_ID"
fi

VERSION=$(plist_get CFBundleShortVersionString)
[[ -n "$VERSION" ]] && pass "CFBundleShortVersionString = $VERSION" \
  || fail "CFBundleShortVersionString missing"

ED_KEY=$(plist_get SUPublicEDKey)
[[ -n "$ED_KEY" ]] && pass "SUPublicEDKey present" \
  || fail "SUPublicEDKey missing"

FEED_URL=$(plist_get SUFeedURL)
[[ -n "$FEED_URL" ]] && pass "SUFeedURL = $FEED_URL" \
  || fail "SUFeedURL missing"

# ── Sparkle appcast ─────────────────────────────────────────────────────────
# The check that would have caught the private-repo 404: a perfectly signed,
# notarized app can still point at a dead update feed.
echo
echo "Sparkle appcast"
if [[ -n "$FEED_URL" ]]; then
  if ! APPCAST=$(curl -fsSL "$FEED_URL" 2>&1); then
    fail "could not fetch SUFeedURL ($FEED_URL): $APPCAST"
  elif ! grep -q "<rss" <<<"$APPCAST"; then
    fail "SUFeedURL did not return RSS/appcast XML"
  else
    pass "appcast fetched and looks like RSS"
    if grep -q "sparkle:edSignature=" <<<"$APPCAST"; then
      pass "enclosure has sparkle:edSignature"
    else
      fail "enclosure missing sparkle:edSignature"
    fi
  fi
else
  fail "skipped appcast check (no SUFeedURL)"
fi

# ── Launch / quit ────────────────────────────────────────────────────────
echo
echo "Launch / quit"
BINARY="$APP/Contents/MacOS/$APP_NAME"
running() { pgrep -f "$BINARY" >/dev/null 2>&1; }
not_running() { ! running; }
wait_until() { for _ in $(seq 1 20); do "$1" && return 0; sleep 0.5; done; return 1; }

if running; then
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  wait_until not_running || fail "could not quit pre-existing instance before test"
fi

open "$APP"
if wait_until running; then
  pass "app launched"
  sleep 1
  if running; then
    pass "still running 1s after launch (no immediate crash)"
  else
    fail "exited within 1s of launch"
  fi
else
  fail "app did not launch within 10s"
fi

osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
if wait_until not_running; then
  pass "app quit cleanly"
else
  fail "still running 10s after quit"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "──────────────────────────────────────────────────────────────────"
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All checks passed."
  exit 0
else
  echo "$FAILURES check(s) failed."
  exit 1
fi

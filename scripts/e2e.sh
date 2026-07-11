#!/bin/bash
#
# Local-only end-to-end suite runner. This is the front door for BerthlyE2ETests:
# the tests XCTSkip unless BERTHLY_E2E=1, which only this script sets — so plain
# `xcodebuild test`, Xcode's ⌘U, and CI can never mutate real daemon state by accident.
#
# Usage:
#   scripts/e2e.sh                 # whole E2E suite
#   scripts/e2e.sh TestClass/test  # one test, e.g. RunContainerJourneyTests/testRunContainerFromSheet_containerExistsWithCorrectImage

set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER="${BERTHLY_CONTAINER_CLI:-/usr/local/bin/container}"
FIXTURE_IMAGE="alpine:latest"

# ── Preflight ────────────────────────────────────────────────────────────────
if [[ ! -x "$CONTAINER" ]]; then
  echo "error: container CLI not found at $CONTAINER" >&2
  exit 1
fi

if ! "$CONTAINER" system status >/dev/null 2>&1; then
  echo "error: container daemon is not running. Start it first:" >&2
  echo "  container system start" >&2
  exit 1
fi

# Pre-pull the fixture so pull latency lands here, once, instead of inside a test timeout.
if ! "$CONTAINER" image ls 2>/dev/null | grep -q alpine; then
  echo "Pulling fixture image $FIXTURE_IMAGE …"
  "$CONTAINER" image pull "$FIXTURE_IMAGE"
fi

# Sweep debris from previous crashed runs before starting (tests also sweep per-test).
STALE=$("$CONTAINER" ls -a -q 2>/dev/null | grep '^berthly-e2e' || true)
if [[ -n "$STALE" ]]; then
  echo "Removing stale E2E containers: $STALE"
  # shellcheck disable=SC2086
  "$CONTAINER" rm -f $STALE || true
fi

# ── Build, then desandbox the runner ─────────────────────────────────────────
# Xcode signs the xctrunner with com.apple.security.app-sandbox=true and a
# mach-lookup allowlist limited to testmanagerd services. A sandboxed runner's
# child processes inherit that seatbelt, so the container CLI can reach the
# daemon neither by XPC (mach-lookup denied) nor by path (HOME points into the
# runner's container), and launchctl submit is denied too. ENABLE_APP_SANDBOX
# on the test target is ignored for xctrunners. The only working approach:
# build first, strip the entitlement, re-sign ad-hoc (CI already proves ad-hoc
# runners work with CODE_SIGN_IDENTITY=-), then test-without-building.
xcodebuild build-for-testing \
  -project Berthly.xcodeproj \
  -scheme Berthly \
  -destination 'platform=macOS'

PRODUCTS=$(xcodebuild -project Berthly.xcodeproj -scheme Berthly -destination 'platform=macOS' \
  -showBuildSettings build-for-testing 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/ {print $3; exit}')
RUNNER="$PRODUCTS/BerthlyE2ETests-Runner.app"
if [[ ! -d "$RUNNER" ]]; then
  echo "error: runner not found at $RUNNER" >&2
  exit 1
fi

ENTITLEMENTS=$(mktemp -t berthly-e2e-entitlements).plist
codesign -d --entitlements :"$ENTITLEMENTS" "$RUNNER"
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.app-sandbox' "$ENTITLEMENTS"
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$RUNNER"
  echo "Desandboxed $RUNNER"
fi
rm -f "$ENTITLEMENTS"

# ── Run ──────────────────────────────────────────────────────────────────────
ONLY="BerthlyE2ETests"
if [[ $# -ge 1 ]]; then
  ONLY="BerthlyE2ETests/$1"
fi

# TEST_RUNNER_ prefix forwards the variable into the test-runner process, where
# BerthlyE2ETestCase checks it as the opt-in gate. test-without-building keeps
# the desandboxed runner intact (a plain `xcodebuild test` would re-sign it).
exec env TEST_RUNNER_BERTHLY_E2E=1 xcodebuild test-without-building \
  -project Berthly.xcodeproj \
  -scheme Berthly \
  -destination 'platform=macOS' \
  -only-testing:"$ONLY"

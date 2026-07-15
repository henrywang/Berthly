#!/bin/bash
#
# Local-only end-to-end suite runner. This is the front door for BerthlyE2ETests:
# the tests XCTSkip unless BERTHLY_E2E=1, which only this script sets — so plain
# `xcodebuild test`, Xcode's ⌘U, and CI can never mutate real daemon state by accident.
#
# Usage:
#   scripts/e2e.sh                            # whole E2E suite
#   scripts/e2e.sh TestClass/test              # one test, e.g. RunContainerJourneyTests/testRunContainerFromSheet_containerExistsWithCorrectImage
#   scripts/e2e.sh --coverage                  # whole suite, instrumented for code coverage
#   scripts/e2e.sh --coverage TestClass/test   # one test, instrumented for code coverage
#
# Coverage is opt-in (off by default): -enableCodeCoverage instruments the binary at
# build time, which is a slower build and not something every local run needs.

set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER="${BERTHLY_CONTAINER_CLI:-/usr/local/bin/container}"
FIXTURE_IMAGE="alpine:latest"

COVERAGE=0
ONLY_FILTER=""
for arg in "$@"; do
  case "$arg" in
    --coverage) COVERAGE=1 ;;
    *) ONLY_FILTER="$arg" ;;
  esac
done

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
BUILD_ARGS=(-project Berthly.xcodeproj -scheme Berthly -destination 'platform=macOS')
if [[ "$COVERAGE" -eq 1 ]]; then
  # Coverage instrumentation is baked in at compile time — enabling it only on the
  # later `test-without-building` step would be a no-op, so it has to go here.
  BUILD_ARGS+=(-enableCodeCoverage YES)
fi

xcodebuild build-for-testing "${BUILD_ARGS[@]}"

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
if [[ -n "$ONLY_FILTER" ]]; then
  ONLY="BerthlyE2ETests/$ONLY_FILTER"
fi

TEST_ARGS=(test-without-building -project Berthly.xcodeproj -scheme Berthly \
  -destination 'platform=macOS' -only-testing:"$ONLY")

RESULT_BUNDLE=""
if [[ "$COVERAGE" -eq 1 ]]; then
  RESULT_BUNDLE="$(mktemp -d -t berthly-e2e-coverage)/e2e.xcresult"
  TEST_ARGS+=(-enableCodeCoverage YES -resultBundlePath "$RESULT_BUNDLE")
fi

# TEST_RUNNER_ prefix forwards the variable into the test-runner process, where
# BerthlyE2ETestCase checks it as the opt-in gate. test-without-building keeps
# the desandboxed runner intact (a plain `xcodebuild test` would re-sign it).
# Not `exec`'d (unlike before) — coverage reporting below needs to run after.
set +e
env TEST_RUNNER_BERTHLY_E2E=1 xcodebuild "${TEST_ARGS[@]}"
STATUS=$?
set -e

if [[ "$COVERAGE" -eq 1 ]]; then
  echo
  echo "── Code coverage ────────────────────────────────────────────────────────────"
  xcrun xccov view --report --only-targets "$RESULT_BUNDLE" || true
  echo
  echo "Result bundle: $RESULT_BUNDLE"
  echo "File-level detail: xcrun xccov view --report --files-for-target Berthly.app $RESULT_BUNDLE"
fi

exit "$STATUS"

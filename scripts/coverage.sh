#!/bin/bash
#
# Merged code-coverage diagnostic: unit + mock-mode UI suites in one
# instrumented run, reported per target and with the Core logic/IO split the
# release notes use.
#
# This is a dead-code / never-exercised-path finder, NOT a release gate or a
# quality headline: UI-test line coverage measures that a line *executed*
# while the tests drove the app, not that anything asserted its behavior —
# blending it with unit coverage inflates the number without inflating
# confidence. The release pipeline (scripts/release.sh) gates on the unit
# suite alone and reports that run's evidence.
#
# Usage:
#   scripts/coverage.sh            # unit + mock-mode UI tests, merged report
#   scripts/coverage.sh --unit     # unit tests only (fast)
#
# The real-daemon E2E layer cannot merge into this report: e2e.sh strips the
# runner's sandbox entitlement and re-signs it between build and test (see
# CLAUDE.md), so its coverage data belongs to a differently-signed binary.
# Run `scripts/e2e.sh --coverage` separately for that layer's numbers.

set -euo pipefail
cd "$(dirname "$0")/.."

TEST_SELECTION=(-skip-testing:BerthlyE2ETests)
if [[ "${1:-}" == "--unit" ]]; then
  TEST_SELECTION=(-only-testing:BerthlyTests)
fi

OUT="dist/coverage"
rm -rf "$OUT"
mkdir -p "$OUT"
BUNDLE="$OUT/coverage.xcresult"

echo "──> Running instrumented tests (UI tests launch and drive the app)…"
set -o pipefail
xcodebuild test \
  -project Berthly.xcodeproj -scheme Berthly \
  -destination 'platform=macOS' \
  "${TEST_SELECTION[@]}" \
  -enableCodeCoverage YES \
  -resultBundlePath "$BUNDLE" \
  > "$OUT/test.log" 2>&1 || {
    echo "error: test run failed — coverage below reflects a partial run. See $OUT/test.log" >&2
  }
# -i: Swift Testing prints "Test case", XCTest prints "Test Case" — count both.
grep -icE "Test case .* passed" "$OUT/test.log" | xargs -I{} echo "──> {} test cases passed"

xcrun xccov view --report --json "$BUNDLE" > "$OUT/coverage.json"
/usr/bin/python3 - "$OUT/coverage.json" <<'EOF'
import json, sys

# Keep in sync with scripts/release.sh: Core files whose coverage belongs to
# the real-daemon E2E layer, not in-process tests.
IO_FILES = {"LiveContainerService.swift", "TerminalSession.swift", "AppNotifier.swift", "UpdaterService.swift"}

report = json.load(open(sys.argv[1]))

def pct(c, t):
    return f"{100 * c / t:5.1f}% ({c}/{t} lines)" if t else "  n/a"

print("\nPer target:")
for target in report.get("targets", []):
    c, t = target.get("coveredLines", 0), target.get("executableLines", 0)
    if t:
        print(f"  {target.get('name', '?'):24} {pct(c, t)}")

def bucket(pred):
    c = t = 0
    for target in report.get("targets", []):
        if not target.get("name", "").startswith("Berthly.app"):
            continue
        for f in target.get("files", []):
            if pred(f.get("path", "")):
                c += f.get("coveredLines", 0)
                t += f.get("executableLines", 0)
    return c, t

print("\nApp breakdown:")
for label, pred in [
    ("Core (all)", lambda p: "/Berthly/Core/" in p),
    ("Core logic (minus I/O)", lambda p: "/Berthly/Core/" in p and p.split("/")[-1] not in IO_FILES),
    ("Views", lambda p: "/Berthly/Views/" in p),
    ("Design", lambda p: "/Berthly/Design/" in p),
]:
    c, t = bucket(pred)
    if t:
        print(f"  {label:24} {pct(c, t)}")
EOF

echo
echo "──> Per-file detail: xcrun xccov view --report $BUNDLE"

# Linting — run before every commit

Before committing, run and get clean output from:

- `swiftlint lint --strict` — config in `.swiftlint.yml`; the repo is at zero
  findings, so `--strict` treats any new warning as a failure. CI runs the
  same command with the same pinned SwiftLint version (`ci.yml`'s `swiftlint`
  job), so a locally-clean run is authoritative.
- `shellcheck scripts/*.sh design/icon/build.sh` — whenever a shell script
  changed.

Fix findings rather than suppressing them. A `swiftlint:disable` needs a
one-line justification comment and the narrowest possible scope (`:next` /
`:this`, or a `disable`/`enable` pair around a fixture block) — see
`MockContainerService.swift` and `LiveContainerService.swift` for the
existing precedents. Size-metric thresholds in `.swiftlint.yml` are a
ratchet set just above the current largest offender: don't raise them to
absorb growth.

# Testing

Three layers — BerthlyTests proves logic, BerthlyUITests (mock mode) proves
UI wiring, BerthlyE2ETests proves real-daemon behavior (local only; CI lacks
nested virtualization).

**Unit tests (`BerthlyTests`)** — Swift Testing (`import Testing`, `@Test`,
`#expect`). Changes to `Berthly/Core/` (services, models, argument/mapping
logic) need a corresponding test here; SwiftUI view files (`Views/`) are
exempt — view bodies are layout, not logic. If logic is trapped inside a view
(a computed property, a button action, a helper that builds CLI args), extract
it to a plain function or to `Core/` so it can be tested —
`LiveContainerService.buildArguments(for:)` is the pattern: pure,
`nonisolated`, no `Process`/XPC involved. Run tests after Core changes before
considering the work done.

Memory-leak tests: allocate inside a `do` block, keep a `weak` reference,
assert it's `nil` after the block exits — see
`MockContainerServiceTests.doesNotLeakAfterGoingOutOfScope()`. Scope these to
`MockContainerService`, not `LiveContainerService` (the live service dials a
real daemon and writes to Application Support on init).

**UI tests (`BerthlyUITests`)** — XCTest/XCUITest, default to mock mode
(`UITEST_USE_MOCK_SERVICE`). Before writing, modifying, or debugging any UI
or performance test — and especially before chasing a CI-only flake — load
the **`ui-testing` skill**: it holds the launch-environment contract, the
XCUITest reliability/speed playbook, `measure` baselining rules, and the
hard-won CI deflaking lore. Non-negotiables even without the skill loaded:
never `sleep()` (wait for a condition), launch via `XCUIApplication.berthly()`
not `XCUIApplication()`, and query by unique accessibility identifiers, not
labels or indices.

**E2E tests (`BerthlyE2ETests`)** — run **only via `scripts/e2e.sh`**; a plain
⌘U / `xcodebuild test` re-signs the runner into the app sandbox and the tests
`XCTSkip` (by design — they mutate real daemon state). Load the
**`e2e-testing` skill** before touching this layer or the script.

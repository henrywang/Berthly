# Testing

Changes to `Berthly/Core/` (services, models, argument/mapping logic) need a
corresponding test in `BerthlyTests`, using Swift Testing (`import Testing`,
`@Test`, `#expect`). SwiftUI view files (`Views/`) are exempt — view bodies
are layout, not logic, and aren't worth unit testing.

If logic is trapped inside a view (a computed property, a button action, a
helper that builds CLI args or transforms data), prefer extracting it to a
plain function or to `Core/` so it can be tested, rather than leaving it
untested in place. `LiveContainerService.buildArguments(for:)` is the
pattern: pure, `nonisolated`, no `Process`/XPC involved.

Run tests after Core changes before considering the work done.

## UI tests (BerthlyUITests)

Uses `XCTest` (`XCUIApplication`, `measure`), not Swift Testing — UI
automation and performance metrics aren't supported by Swift Testing yet.

`BerthlyApp.swift` reads two launch-environment variables so tests don't
depend on a real daemon connection:

- `UITEST_USE_MOCK_SERVICE` — boots with `MockContainerService` instead of
  `LiveContainerService`.
- `UITEST_INITIAL_DAEMON_STATE` — seeds `daemonState` (`installedButStopped`,
  `notInstalled`, `checking`) for tests that need a specific connection state.

New UI tests should default to mock mode for determinism. Only skip it (via
`XCTSkip` when the relevant button is disabled/absent, matching
`testBuildSheetOpensAndClosesWithoutCrashing`) when the test's whole point is
exercising the real daemon integration — e.g. an actual build or machine
create, which the mock can't meaningfully substitute for.

## E2E tests (BerthlyE2ETests) — local-only, real daemon

Third layer: BerthlyTests proves logic, BerthlyUITests (mock) proves UI wiring,
`BerthlyE2ETests` proves the UI produces the right **real daemon** behavior — the
layer CI can never cover (hosted runners lack nested virtualization).

- **Run via `scripts/e2e.sh`** (pre-pulls `alpine:latest`, sweeps stale resources,
  sets the `TEST_RUNNER_BERTHLY_E2E=1` opt-in). Tests `XCTSkip` without that env,
  on CI, without the CLI, or with the daemon down — so ⌘U / plain `xcodebuild test`
  can never mutate real state by accident.
- **Code coverage is opt-in**: `scripts/e2e.sh --coverage` (composes with the
  single-test filter: `scripts/e2e.sh --coverage TestClass/test`). Off by default
  because `-enableCodeCoverage` instruments the binary at `build-for-testing` time
  (coverage can't be bolted on at `test-without-building` — it's a compile-time
  flag), which is a slower build not every local run needs. When on, the script
  prints a per-target `xccov` summary and the `.xcresult` path afterward.
- **The script is mandatory, not convenience**: Xcode signs the xctrunner with
  `app-sandbox=true` plus a mach-lookup allowlist limited to testmanagerd services,
  and child processes inherit that seatbelt — so the `container` CLI spawned from a
  sandboxed runner can reach the daemon neither by XPC (mach-lookup denied) nor by
  path (HOME points into the runner's container), and `launchctl submit` is denied
  as an escape. `ENABLE_APP_SANDBOX = NO` on the test target is *ignored* for
  xctrunners. e2e.sh therefore does `build-for-testing` → strips the app-sandbox
  entitlement → re-signs the runner ad-hoc → `test-without-building` (a plain
  `xcodebuild test` would rebuild and re-sign the runner, restoring the sandbox).
- **Style**: few LONG journey tests, not one per control (mock mode covers that).
  Drive via UI, assert via `container` CLI (`ls`/`inspect`) — and the reverse
  (create via CLI, assert the sidebar notices) to cover the observation path.
- **Hygiene**: everything is named `berthly-e2e-<uuid>`; `BerthlyE2ETestCase`
  sweeps that prefix in both setUp (crashed-run debris) and tearDown.
- **Generous timeouts are fine here** (pulls/boots take seconds); this suite trades
  speed for fidelity and must never become a required gate.
- Extending coverage to more sheet controls: add accessibility identifiers to the
  fields in `RunContainerSheet` first (like `runSubmitButton`); don't query by
  placeholder text.

## Memory-leak tests

Pattern: allocate inside a `do` block, keep a `weak` reference, assert it's
`nil` after the block exits — this catches retain cycles (a `Task` or closure
capturing `self` instead of `[weak self]`). See
`MockContainerServiceTests.doesNotLeakAfterGoingOutOfScope()`.

Scope these to `MockContainerService`, not `LiveContainerService` — the live
service dials a real daemon and writes to Application Support on init, which
doesn't belong in a unit test's side effects.

## Performance tests (CPU/memory)

Use `measure(metrics: [XCTMemoryMetric(), XCTCPUMetric()])` in
`BerthlyUITests`, same as the existing `testLaunchPerformance`. These metrics
have no built-in pass/fail threshold — after adding or changing one, run it
once in Xcode (Report Navigator → the test → each metric's trend icon → "Set
Baseline") so future runs are flagged on regression. Re-baseline whenever a
change intentionally shifts memory/CPU usage.

Check the relative standard deviation of each collected sub-metric before
baselining it: a metric measuring a near-zero delta (e.g. incremental
`Memory Physical` during a short interaction) can swing 50%+ between runs on
noise alone. Baselining a metric like that against Xcode's default 10%
regression threshold produces a flaky gate, not a real signal — leave it
un-baselined (or widen its threshold) rather than baseline noise.

GPU usage isn't covered — XCTest has no public API for it. Profile it
manually with Instruments (Metal System Trace / Core Animation) instead.

## SwiftUI macOS E2E Testing (XCUITest) — Best Practices

Framework: **XCUITest** (native, ships with Xcode). Use `.click()` on macOS (not `.tap()`).

### Core Principles

- **Control all inputs** (data, network, clock, animation state); **assert on outputs**, never guess at timing.
- **Do the least UI work** needed to exercise the logic: deep-link in, seed state, assert, done.
- **Every test is independent** — no shared mutable state, no ordering assumptions.

### Reliability

- **Never `sleep()`.** Wait for a condition instead. This is the #1 flake source.
  ```swift
  let button = app.buttons["saveButton"]
  XCTAssertTrue(button.waitForExistence(timeout: 5))
  button.click()
  ```
- **Wait for complex conditions with expectations:**
  ```swift
  let enabled = NSPredicate(format: "isEnabled == true")
  expectation(for: enabled, evaluatedWith: button)
  waitForExpectations(timeout: 5)
  ```
- **Assert existence/hittability before acting.** Interacting with an unrendered element throws or silently misses.
- **Reset app state on every launch** via launch arguments (see below).
- **Launch through `XCUIApplication.berthly()`, never `XCUIApplication()` directly.** It adds
  `-ApplePersistenceIgnoreState YES`: Berthly is a menu-bar app, so quitting it with the main
  window closed makes macOS window restoration relaunch it with *zero* windows — the process
  runs, menus appear, but every `waitForExistence` times out. This is machine state, not a code
  regression: it fails previously-green tests at the same commit.
- **Mock the network**, seed a known data fixture, use a fixed clock/locale. Real network calls are the #2 flake source.
- **Set stable accessibility identifiers** on everything you query. Never rely on:
  - visible text (breaks with localization)
  - index-based lookups like `app.buttons.element(boundBy: 2)` (breaks with layout changes)
  ```swift
  Button("Save") { save() }
      .accessibilityIdentifier("saveButton")
  ```
- **Watch for SwiftUI accessibility-tree flattening.** SwiftUI may merge child views into one element, hiding controls. Use `.accessibilityElement(children: .contain)` on the container to expose them.

### Speed

- **Disable animations** under the UI-test flag. They waste wall-clock time and cause "not hittable" mid-transition. Gate SwiftUI transitions/animations behind `-uitesting`.
- **Launch as few times as possible.** `app.launch()` costs ~1–3s. Group related assertions into one test where isolation allows.
- **Deep-link to the screen under test** — don't navigate through multiple taps. Single biggest speedup for deep screens.
  ```swift
  app.launchArguments += ["-startScreen", "orderDetail", "-orderID", "42"]
  ```
- **Seed data directly via launch environment**, skip driving the login/setup UI each time.
- **Query narrowly.** `app.buttons["id"]` beats `app.descendants(matching:)` over the whole tree. Scope queries to a container in large hierarchies.
- **Keep timeouts as low as reliably passes** — 5s is plenty for most; don't default to 30.

### Launch Configuration Hook

```swift
// Test
app.launchArguments += ["-uitesting"]
app.launchEnvironment["MOCK_API"] = "1"
app.launch()

// App
if CommandLine.arguments.contains("-uitesting") {
    // seed fixtures, skip animations, use mock API, fixed clock/locale
}
```

### Structure

- **Page Object pattern:** wrap each screen in a struct exposing its elements and actions. Selectors live in one place; tests read cleanly.
- **`continueAfterFailure = false`** for faster feedback (stop on first failure).

### Reference Pattern

```swift
final class OrderDetailTests: XCTestCase {
    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launchArguments += ["-uitesting", "-startScreen", "orderDetail"]
        app.launchEnvironment["MOCK_API"] = "1"
        app.launch()
    }

    func testSaveConfirms() {
        let save = app.buttons["saveButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.click()
        XCTAssertTrue(app.staticTexts["savedBanner"].waitForExistence(timeout: 5))
    }
}
```

### CI

- Run: `xcodebuild test -scheme YourScheme -destination 'platform=macOS'`
- Grant Automation/Accessibility permissions; reset TCC in setup: `tccutil reset All your.bundle.id`
- Use a real or virtualized macOS runner (`macos-latest` on GitHub Actions, or self-hosted Mac hardware).

### CI & high-load flakes (hard-won, Berthly-specific)

A test that is green locally but red only on the GitHub runner is almost always a **timing race**,
not a code bug — the runner is slower, headless, and CPU-contended, so it loses races the fast local
machine wins. Berthly's `.github/workflows/ci.yml` has an advisory "UI tests (mock mode)" job; these
lessons come from deflaking `testMemoryAndCPUUsageDuringSheetChurn` across three CI rounds.

- **Read the failure from the XCUITest event trace, not just the assertion line.** `gh run view <run-id>
  --log-failed` dumps the whole job; the `t = 0.00s …` trace shows what *physically* happened —
  `Synthesize event`, `Wait for … to idle`, and especially `Falling back to element center point:
  {x,y}`, which means XCUITest could not compute a hittable point and clicked stale coordinates. The
  `.swift:NNN` assertion line is often just where the *consequence* surfaced, not the cause.

- **`app.buttons["Run"]` matches accessibility identifier OR label**, so two controls sharing a label
  collide. `waitForExistence` passes (needs ≥1 match) but `.click()` throws "Multiple matching elements
  found" (needs exactly 1). Give the control you drive a unique `.accessibilityIdentifier(...)` and query
  *that* — never query by a label another visible view also uses. (The toolbar Run button and
  `RunContainerSheet`'s submit button both read "Run"; `runToolbarButton` disambiguates.)

- **Dismiss an animated sheet with a key event, not a coordinate `.click()`.** A `.click()` on a Cancel
  button races the sheet's present/dismiss animation: XCUITest falls back to a stale center point, misses
  the live control, and the sheet never closes. Prefer `app.typeKey(.escape, modifierFlags: [])` — Berthly
  sheet Cancel/Close buttons bind `.keyboardShortcut(.cancelAction)`, and a key event routes to the focused
  window with **no coordinates to race**. Only safe when nothing auto-focuses a text field in the sheet
  (no `@FocusState`/`defaultFocus`/`.focused`), or the field swallows Escape.

- **Inside `measure {}`, gate the loop's last line on `waitForNonExistence`.** The measure closure runs
  several times; if it re-enters while the previous sheet is still animating out, the next control isn't
  hittable yet and the click is lost. Make the settle-wait (`XCTAssertTrue(x.waitForNonExistence(timeout:
  10))`) the final statement so both the next iteration and the next closure invocation start from a
  settled window. And **assert your waits** (`XCTAssertTrue(...)`) rather than discarding them (`_ = …`):
  a discarded timeout falls through to a later `.click()` that fails with a misleading "no matches".

- **Reproduce CI-only flakes locally under load, but don't trust "0/N under load" as proof.** Peg the
  cores with `yes >/dev/null &` (one per core ≈ realistic CI load; 2×/core is pathological and adds its
  own launch/activation failures) and loop the single test ~10×. This surfaces *contention* races — but
  **hittability races depend on the runner's rendering timing, not CPU load**, so a coordinate-click flake
  can pass 0/10 locally and still fail on CI. When load-looping can't reproduce it, the real evidence is a
  *mechanism* that removes the race class (e.g. key-event dismiss has no coordinates), confirmed by one
  clean unloaded run — not a green load loop.

- **Don't push blind.** Each CI round is ~15–20 min. Diagnose from the trace, fix, and validate the
  specific test locally (`-only-testing:BerthlyUITests/BerthlyUITests/<testName>`) before pushing.

- **Animations ARE disabled in UI-test mode** (since 2026-07-16): `BerthlyApp.disableAnimations` is
  true when `UITEST_USE_MOCK_SERVICE` or `UITEST_DISABLE_ANIMATIONS` is set. Two layers: a
  `.transaction` transform on each scene root nils SwiftUI animations subtree-wide, and
  `NSAutomaticWindowAnimationsEnabled=false` + `NSWindowResizeTime=0.001` (set in `BerthlyApp.init`)
  kill the AppKit window/sheet slide that transactions can't reach. Mock-mode tests get this
  automatically; real-daemon E2E can opt in via `UITEST_DISABLE_ANIMATIONS=1`. The sheet-dismiss
  race guidance above still applies as defense-in-depth (settle-waits cost nothing when transitions
  are instant), but the race windows themselves are now near-zero.

- **"Timed out while enabling automation mode"** (runner fails to init, all tests "not run"): a
  wedged `automationmode-writer` / `AutomationModeUI` process from a previous session blocks the
  handshake — `pkill -9 -f AutomationMode` (both processes), then rerun. Killing `testmanagerd`
  alone does not fix it.

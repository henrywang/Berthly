---
name: ui-testing
description: XCUITest playbook for BerthlyUITests — mock-mode launch config, reliability/speed rules, performance (measure) baselines, and hard-won CI deflaking lore. Load BEFORE writing, modifying, or debugging any UI or performance test, and when diagnosing a UI-test failure that is CI-only or flaky.
user-invocable: true
---

# UI tests (BerthlyUITests)

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

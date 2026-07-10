# Contributing to Berthly

Thanks for your interest in improving Berthly! This document covers everything
you need to build the app, run the tests, and get a pull request merged.

## Prerequisites

- **An Apple Silicon Mac.** Apple's `container` runs Linux containers in
  lightweight VMs and requires Apple Silicon — there is no Intel path.
- **macOS 26 or later** (the app's deployment target).
- **Xcode 26 or later**, including the **Metal toolchain** component —
  SwiftTerm compiles Metal shaders. Install it via
  Xcode → Settings → Components, or:
  ```sh
  xcodebuild -downloadComponent MetalToolchain
  ```
- **[Apple's `container`](https://github.com/apple/container) installed and
  running** — needed to exercise real functionality. Unit tests and mock-mode
  UI tests run without it.

## Building

```sh
git clone https://github.com/henrywang/Berthly.git
cd Berthly
open Berthly.xcodeproj
```

Build and run the **Berthly** scheme (⌘R). Swift Package Manager resolves
dependencies on first open; this can take a few minutes.

## Project layout

| Path | What lives there |
| --- | --- |
| `Berthly/Core/` | Services, models, argument-building and mapping logic — everything testable |
| `Berthly/Views/` | SwiftUI views (layout only, logic belongs in `Core/`) |
| `Berthly/Design/` | Shared design primitives |
| `BerthlyTests/` | Unit tests ([Swift Testing](https://github.com/apple/swift-testing)) |
| `BerthlyUITests/` | UI & performance tests (XCUITest) |

## Testing

Run the full suite:

```sh
xcodebuild test -project Berthly.xcodeproj -scheme Berthly -destination 'platform=macOS'
```

or ⌘U in Xcode. CI runs the unit tests (`BerthlyTests`) as the required
check on every pull request, plus the mock-mode UI tests as an advisory job;
tests that need the real container daemon skip themselves on CI, so run
those locally.

### The rules

- **Changes to `Berthly/Core/` need a corresponding unit test** in
  `BerthlyTests`, using Swift Testing (`import Testing`, `@Test`, `#expect`).
- **SwiftUI view files are exempt** — view bodies are layout, not logic.
- **Don't leave logic trapped inside a view.** If a view grows a computed
  property, button action, or helper that builds CLI arguments or transforms
  data, extract it to a plain function or to `Core/` so it can be tested.
  `LiveContainerService.buildArguments(for:)` is the pattern to follow: pure,
  `nonisolated`, no `Process` or XPC involved.
- **Run the tests before opening a PR**, and keep the build warning-free.

### UI tests

`BerthlyUITests` uses XCUITest (UI automation isn't supported by Swift
Testing yet). New UI tests should default to **mock mode** for determinism —
`BerthlyApp` reads two launch-environment variables:

- `UITEST_USE_MOCK_SERVICE` — boots with `MockContainerService` instead of
  the live daemon connection.
- `UITEST_INITIAL_DAEMON_STATE` — seeds the daemon state
  (`installedButStopped`, `notInstalled`, `checking`).

Launch through the `XCUIApplication.berthly()` helper rather than
`XCUIApplication()` directly, use stable accessibility identifiers, and never
`sleep()` — wait for a condition with `waitForExistence(timeout:)`. Only skip
mock mode when the test's whole point is real daemon integration.

## Commit messages

- Imperative mood, with a conventional-commit prefix:
  `feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`.
- Example: `fix: silence main-actor isolation warning on ANSIEscape.regex`

## Pull requests

1. Fork, branch from `main`, make your change.
2. Add tests for any `Core/` change; run the suite.
3. Keep PRs small and focused — one logical change per PR.
4. Describe **what** changed and **why**; include a screenshot for UI changes.
5. CI must pass before review.

## Reporting bugs & requesting features

Please use the issue templates — they ask for the environment details
(macOS version, `container` version, hardware) we need to reproduce problems.

## Security issues

Please **do not** open a public issue — see [SECURITY.md](SECURITY.md).

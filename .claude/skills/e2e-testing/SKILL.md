---
name: e2e-testing
description: How to run and extend BerthlyE2ETests — the local-only, real-daemon UI test layer. Load BEFORE touching BerthlyE2ETests or scripts/e2e.sh, running E2E tests, or debugging why the container CLI can't reach the daemon from a test runner (xctrunner sandbox).
user-invocable: true
---

# E2E tests (BerthlyE2ETests) — local-only, real daemon

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
- **Animations**: real-daemon E2E can opt into animation disabling via
  `UITEST_DISABLE_ANIMATIONS=1` (mock-mode tests get it automatically).
- Extending coverage to more sheet controls: add accessibility identifiers to the
  fields in `RunContainerSheet` first (like `runSubmitButton`); don't query by
  placeholder text.

The XCUITest reliability/speed playbook (waits, accessibility identifiers,
sheet-dismiss races, CI flake diagnosis) lives in the `ui-testing` skill — it
applies to this layer too.

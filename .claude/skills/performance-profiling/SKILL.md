---
name: performance-profiling
description: Measure and diagnose Berthly launch time, CPU usage, memory growth, and leaks using XCTest performance metrics, leaks, and xctrace/Instruments. Load BEFORE running performance or profiling work, investigating high CPU or memory, adding performance tests, setting baselines, or claiming that Berthly is leak-free.
user-invocable: true
---

# Performance profiling

Use complementary measurements rather than treating one green test as proof:

1. Unit lifetime tests catch known retain cycles deterministically.
2. Mock-mode UI churn measures repeatable interaction cost.
3. A live-service idle run exposes the five-second daemon polling path.
4. `leaks` finds currently reachable leak roots in one process snapshot.
5. Time Profiler identifies where sampled CPU time is spent.

Load the `ui-testing` skill before changing or debugging any XCTest UI
performance test. Load `e2e-testing` before profiling workflows that mutate or
exercise the real daemon through BerthlyE2ETests. Idle live-service profiling is
read-only and must not start, stop, or modify daemon resources.

## Environment record

Record this with every result so numbers are not compared across unlike hosts:

```sh
xcodebuild -version
system_profiler SPHardwareDataType \
  | grep -E 'Model Name|Model Identifier|Chip|Total Number of Cores|Memory'
git rev-parse --short HEAD
git status --short
```

State the build configuration and whether the app used mock mode or the live
service. Never compare absolute XCTest or Instruments numbers from different
machines, Xcode versions, build configurations, thermal states, or daemon data
sets as if they were regressions.

## Existing automated measurements

Run the existing performance tests with an explicit result bundle:

```sh
rm -rf /tmp/BerthlyPerformance.xcresult
xcodebuild test \
  -project Berthly.xcodeproj \
  -scheme Berthly \
  -destination 'platform=macOS' \
  -resultBundlePath /tmp/BerthlyPerformance.xcresult \
  -only-testing:BerthlyUITests/BerthlyUITests/testMemoryAndCPUUsageDuringSheetChurn \
  -only-testing:BerthlyUITests/BerthlyUITests/testMemoryAndCPUUsageDuringTerminalTabChurn \
  -only-testing:BerthlyUITests/BerthlyUITests/testLaunchPerformance \
  -only-testing:BerthlyUITests/LargeInventoryTests/testLargeInventorySectionAndDetailPerformance \
  | tee /tmp/berthly-performance.log
```

Extract the measurements without summarizing thousands of UI event lines:

```sh
grep -E 'Test Case .*measured|Test Case .*passed|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)' \
  /tmp/berthly-performance.log
```

Run all unit tests so the explicit weak-reference lifetime checks execute along
with the rest of the service/task lifecycle coverage:

```sh
rm -rf /tmp/BerthlyUnitTests.xcresult
xcodebuild test -quiet \
  -project Berthly.xcodeproj \
  -scheme Berthly \
  -destination 'platform=macOS' \
  -resultBundlePath /tmp/BerthlyUnitTests.xcresult \
  -only-testing:BerthlyTests \
  | tee /tmp/berthly-unit-tests.log
```

Confirm that `MockContainerServiceTests/doesNotLeakAfterGoingOutOfScope()`,
`MockContainerServiceTests/doesNotLeakWithLargeDatasetAfterGoingOutOfScope()`,
and `BuildJobManagerTests/doesNotLeakAfterGoingOutOfScope()` appear as passed. A
mistyped `-only-testing` filter can select zero Swift Testing tests while
`xcodebuild` still exits successfully, so never infer execution from exit status
alone — Swift Testing identifiers need the trailing `()` (e.g.
`-only-testing:"BerthlyTests/MockContainerServiceTests/doesNotLeakAfterGoingOutOfScope()"`,
quoted so the shell doesn't eat the parens); omitting it silently matches
nothing rather than erroring.

## Interpreting XCTest metrics

XCTest performance metrics do not fail on an absolute limit by default. A
passing test means the interaction completed, not that CPU, memory, or launch
time are acceptable. Report the raw values, relative standard deviation (RSD),
iteration count, and whether an Xcode baseline exists.

- CPU Time/Cycles with RSD below 10% are generally stable enough to consider for
  a baseline.
- A near-zero `Memory Physical` delta often has very high RSD. Do not baseline
  noise or call it a leak.
- `Memory Peak Physical` from a measured interval is not the app's total resident
  footprint. Preserve XCTest's metric name and units instead of relabeling it.
- `XCTApplicationLaunchMetric` reports launch duration in seconds. Report its
  individual iterations and RSD; an RSD below 10% is generally stable enough to
  consider for a baseline. It measures process/UI launch, not steady-state
  polling or time until daemon data finishes loading. Keep window-restoration
  state and build configuration identical between comparisons, and rerun rather
  than discarding an inconvenient outlier when thermal or machine load intrudes.
- Set or update baselines in Xcode's Report Navigator only after checking RSD and
  only when the user asks. Do not silently bless a regression.

A leak requires sustained growth or retained objects across repeated lifecycles;
one positive memory delta does not establish one.

## Idle CPU and resident-memory sampling

Build the configuration being assessed first. Prefer Release for product-level
numbers and Debug when diagnosing source-level behavior:

```sh
xcodebuild build -quiet \
  -project Berthly.xcodeproj \
  -scheme Berthly \
  -configuration Release \
  -destination 'platform=macOS'
```

Resolve the product from build settings; do not hardcode a DerivedData hash:

```sh
build_settings=$(xcodebuild -project Berthly.xcodeproj -scheme Berthly \
  -configuration Release -destination 'platform=macOS' -showBuildSettings)
target_build_dir=$(printf '%s\n' "$build_settings" \
  | awk -F ' = ' '/ TARGET_BUILD_DIR = / { print $2; exit }')
full_product_name=$(printf '%s\n' "$build_settings" \
  | awk -F ' = ' '/ FULL_PRODUCT_NAME = / { print $2; exit }')
executable_name=$(printf '%s\n' "$build_settings" \
  | awk -F ' = ' '/ EXECUTABLE_NAME = / { print $2; exit }')
app="$target_build_dir/$full_product_name"
executable="$app/Contents/MacOS/$executable_name"
test -x "$executable"
```

Tell the user that the currently running app will be closed, then terminate it
before launching the measured copy. Prefer stopping an Xcode-run process with
Xcode's Stop button (⌘.) first. A process whose `ps` state contains `X` is being
traced/debugged; this project has produced `SX` Berthly processes that survive
even `kill -9` until Xcode releases them. Inspect before escalating:

```sh
pgrep -x Berthly | while IFS= read -r existing_pid; do
  ps -p "$existing_pid" -o pid=,stat=,command=
done
```

If a remaining process is Xcode-debugged, stop the active run in Xcode. When GUI
control is unavailable, the observed fallback is:

```sh
osascript -e 'tell application "Xcode" to stop workspace document 1'
```

That command stops the active run for workspace document 1 and must not be run
blindly when Xcode has multiple workspaces or unrelated jobs open. After Xcode
releases a debugged process, use normal `kill`/`pkill` if it remains and verify
`pgrep -x Berthly` is empty.

Launch the executable directly so the shell captures Berthly's PID; `$!` from
`open` would be the short-lived `open` helper instead. Use one of these forms:

```sh
# Deterministic mock baseline
UITEST_USE_MOCK_SERVICE=1 "$executable" >/tmp/berthly-profile-app.log 2>&1 &
pid=$!

# Deterministic mock baseline, large inventory (100 containers, 20 machines,
# 50 images, 40 volumes, 20 networks) — for stress-profiling idle CPU/RSS or
# leaks against LargeMockFixture's dataset instead of the small default one.
# UITEST_USE_MOCK_SERVICE=1 UITEST_MOCK_DATASET=large "$executable" >/tmp/berthly-profile-app.log 2>&1 &
# pid=$!

# Live-service polling profile
# "$executable" >/tmp/berthly-profile-app.log 2>&1 &
# pid=$!

kill -0 "$pid"
ps -p "$pid" -o pid=,stat=,command=
```

Keep this shell alive for the remaining commands; `pid` is consumed by the RSS,
`leaks`, and Time Profiler sections. Add a cleanup trap when running the steps in
one script:

```sh
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
```

If the launch, sampling, `leaks`, and Time Profiler steps can't literally run in
one continuous shell (an agent tool that resets shell state between calls, not a
human's Terminal session), `disown "$pid"` after launch and persist `$pid` to a
file instead of relying on a variable to survive; reread it from the file in the
next step to reattach and clean up. Without `disown`, the background job is tied
to that shell and can be reaped when the tool ends the shell between steps.

Allow at least 15 seconds of warm-up, then sample for at least 45 seconds so
multiple five-second polls occur. Capture `%CPU` and RSS once per second,
reporting average, maximum, minimum, and first-to-last RSS. Treat one-time
framework/cache allocation as warm-up; look for a repeated upward staircase that
does not settle.

`ps` sampling is coarse and can miss short spikes. Use it to establish shape and
resident-memory stability, not as a substitute for Time Profiler.

## Leak snapshot

Against the warmed process:

```sh
leaks "$pid" | tee /tmp/berthly-leaks.log
```

Report the process's allocated nodes/bytes and the exact leak count. `0 leaks`
means the tool found no leak roots in that snapshot. It does not prove that every
UI lifecycle, asynchronous task, terminal session, or real-daemon operation is
leak-free. Pair it with churn and weak-reference tests.

## Time Profiler

Prefer attaching to the already launched, warmed PID. This avoids measuring only
startup and avoids LaunchServices selecting another installed app with the same
bundle identifier:

```sh
rm -rf /tmp/BerthlyTimeProfile.trace
xcrun xctrace record \
  --template 'Time Profiler' \
  --time-limit 30s \
  --output /tmp/BerthlyTimeProfile.trace \
  --attach "$pid"
```

Export and inspect the table of contents before interpreting samples:

```sh
xcrun xctrace export \
  --input /tmp/BerthlyTimeProfile.trace \
  --toc \
  --output /tmp/berthly-time-toc.xml
```

Verify all of the following:

- The trace exists and its duration is close to the requested limit.
- The target PID and binary are the process launched for this checkout.
- The end reason is the time limit, not a crash.
- Samples cover warmed steady state rather than only startup.

Zero rows in the exported `time-profile` table is a valid outcome for a
genuinely idle process (e.g. large-dataset mock mode with ~0% `ps` CPU) — it
means there was nothing to sample, not that the trace failed. Trust the TOC
checks above over the row count.

`xctrace` may return a nonzero status when it terminates a launched target at the
time limit. Never ignore a nonzero status blindly: accept the trace only after
the TOC proves it completed for the intended process. Attaching to a warmed PID
is preferred.

Export the `time-profile` table for scripted inspection when needed:

```sh
xcrun xctrace export \
  --input /tmp/BerthlyTimeProfile.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  --output /tmp/berthly-time-profile.xml
```

Resolve XML `id`/`ref` entries before aggregating stacks; counting only inline
`frame` elements undercounts deduplicated frames. Report the dominant Berthly
call path and its sample count, not just leaf system calls. For idle CPU, compare
polling stacks such as `startPolling → poll → refreshAll` against UI/AppKit and
startup work. A sampled stack identifies an optimization target, not elapsed time
by itself.

Use Instruments Allocations/Leaks interactively when the snapshot or RSS trend
is suspicious. Use Metal System Trace/Core Animation for GPU concerns; XCTest
has no public GPU metric.

## Reporting

Every report must include:

- Commit, hardware, macOS/Xcode, and build configuration.
- Exact commands or result-bundle/trace paths.
- Tests executed and failures, including proof that lifetime tests ran.
- Launch, CPU, and memory metric values with RSD and baseline status.
- Idle average/peak CPU and RSS min/max/first-to-last after warm-up.
- `leaks` count with the snapshot limitation stated.
- Dominant Time Profiler call paths and whether the target binary was verified.
- A clear separation between observed facts, suspected causes, and recommended
  changes.

Do not claim “no memory leak” from a single green XCTest metric. Say “no leak was
detected in these exercised paths” unless repeated lifecycle tests, stable RSS,
and leak inspection all support the stronger conclusion.

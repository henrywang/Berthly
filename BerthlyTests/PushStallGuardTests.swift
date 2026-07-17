// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Testing
import TerminalProgress
@testable import Berthly

struct ProgressClassificationTests {

    /// The exact regression this guards: a planning-only batch (the daemon announcing scope before
    /// any network I/O) must not be mistaken for real forward progress, or the stall watchdog
    /// disarms permanently on the very first callback even if zero bytes ever move afterward.
    @Test func planningOnlyEventsAreNotRealProgress() {
        #expect(!containsRealProgress([.addTotalItems(5), .addTotalSize(145_000_000)]))
        #expect(!containsRealProgress([.setTotalItems(5), .setDescription("Pushing")]))
        #expect(!containsRealProgress([.setItemsName("blobs"), .custom("resolving manifest")]))
        #expect(!containsRealProgress([]))
    }

    @Test func completionEventsAreRealProgress() {
        #expect(containsRealProgress([.addItems(1)]))
        #expect(containsRealProgress([.addSize(1024)]))
        #expect(containsRealProgress([.setItems(3)]))
        #expect(containsRealProgress([.setSize(2048)]))
        // A mixed batch counts if any element is real completion.
        #expect(containsRealProgress([.addTotalItems(5), .addItems(1)]))
    }

    @Test func zeroValuedCompletionEventsDoNotCount() {
        #expect(!containsRealProgress([.addItems(0)]))
        #expect(!containsRealProgress([.addSize(0)]))
    }
}

struct PushStallGuardTests {

    @Test func throwsWhenNoProgressWithinTimeout() async {
        let monitor = PushStallMonitor()
        await #expect(throws: PushStalledError.self) {
            try await monitor.watch(timeout: .milliseconds(80), checkInterval: .milliseconds(20))
        }
    }

    @Test func neverThrowsOnceProgressHasArrived() async throws {
        let monitor = PushStallMonitor()
        await monitor.markProgress()

        let task = Task {
            try await monitor.watch(timeout: .milliseconds(50), checkInterval: .milliseconds(10))
        }
        // Outlast the timeout window entirely; since progress was already recorded, `watch` must
        // still be running (not thrown) — only cancellation should end it.
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}

struct RaceAgainstStallTests {

    /// The exact bug in the first version of this fix: it used `withThrowingTaskGroup`, which
    /// implicitly awaits every child before returning — including the operation that just lost the
    /// race. An XPC call to the daemon (what `operation` stands in for here) has no obligation to
    /// honor Swift's cooperative cancellation, so awaiting it after cancelling it can hang forever.
    /// This operation deliberately swallows `CancellationError` in a loop to simulate exactly that
    /// non-cooperative shape, and asserts the race still returns promptly rather than waiting for it.
    @Test func returnsPromptlyEvenWhenOperationIgnoresCancellation() async throws {
        let monitor = PushStallMonitor()
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: PushStalledError.self) {
            try await raceAgainstStall(timeout: .milliseconds(80), monitor: monitor) {
                for _ in 0..<50 {
                    try? await Task.sleep(for: .milliseconds(100))  // ignores cancellation via try?
                }
                return ()
            }
        }

        // Must return around the 80ms timeout, not the ~5s the ignored-cancellation operation
        // would otherwise run for. The bound is deliberately loose: on a contended CI runner,
        // task-scheduling latency alone can add over a second (observed 1.4s on a cold
        // GitHub macos-26 runner), and the regression this guards produces ~5s, not ~2s.
        #expect(clock.now - start < .seconds(2.5))
    }

    @Test func returnsTheOperationsResultWhenItWinsTheRace() async throws {
        let monitor = PushStallMonitor()
        let result = try await raceAgainstStall(timeout: .seconds(5), monitor: monitor) {
            await monitor.markProgress()
            return "done"
        }
        #expect(result == "done")
    }

    @Test func propagatesTheOperationsOwnError() async {
        struct SomeError: Error {}
        let monitor = PushStallMonitor()
        await #expect(throws: SomeError.self) {
            try await raceAgainstStall(timeout: .seconds(5), monitor: monitor) {
                throw SomeError()
            }
        }
    }
}

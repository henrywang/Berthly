// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
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

struct PushOperationTrackerTests {

    @Test func blocksDuplicateDestinationUntilTheFirstOperationFinishes() async {
        let tracker = PushOperationTracker()

        #expect(await tracker.begin("registry.example/app:latest"))
        #expect(!(await tracker.begin("registry.example/app:latest")))

        await tracker.finish("registry.example/app:latest")
        #expect(await tracker.begin("registry.example/app:latest"))
    }
}

struct RaceAgainstStallTests {

    /// The exact bug in the first version of this fix: it used `withThrowingTaskGroup`, which
    /// implicitly awaits every child before returning — including the operation that just lost the
    /// race. An XPC call to the daemon (what `operation` stands in for here) has no obligation to
    /// honor Swift's cooperative cancellation, so awaiting it after cancelling it can hang forever.
    ///
    /// Asserts ordering, not wall-clock time: an earlier `< 2.5s` bound flaked on CI (2.72s
    /// observed while a trivial sibling test took 2.67s). That version's operation also looped
    /// `try? await Task.sleep`, which returns immediately once cancelled — so a regressed
    /// task-group implementation would have finished in ~80ms and passed anyway.
    @Test func returnsWhileOperationIgnoringCancellationIsStillRunning() async {
        let monitor = PushStallMonitor()
        let gate = UncancellableGate()
        // Keeps a regressed implementation (one that waits for the operation) from hanging the suite.
        let safetyValve = Task {
            try? await Task.sleep(for: .seconds(10))
            gate.open()
        }

        await #expect(throws: PushStalledError.self) {
            try await raceAgainstStall(timeout: .milliseconds(80), monitor: monitor) {
                await gate.wait()
            }
        }

        let raceReturnedBeforeOperation = gate.open()
        safetyValve.cancel()
        #expect(raceReturnedBeforeOperation, "raceAgainstStall waited for the abandoned operation to finish")
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

/// Parks callers until `open()`, deliberately ignoring task cancellation — the shape of a daemon
/// XPC call that never checks for it.
private final class UncancellableGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !isOpen else {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    /// Returns `false` if the gate was already open.
    @discardableResult
    func open() -> Bool {
        lock.lock()
        guard !isOpen else {
            lock.unlock()
            return false
        }
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
        return true
    }
}

// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import TerminalProgress

/// Whether any event is genuine forward progress (an item/byte actually moved), not a
/// planning event like `.addTotalItems`/`.addTotalSize` that just describes scope and can
/// fire once before any I/O happens. `PushStallMonitor` must only arm on the former, or a
/// daemon reporting "N blobs, X bytes total" up front would disarm the watchdog even while
/// stuck in a pre-auth retry loop with zero bytes ever moving.
nonisolated func containsRealProgress(_ events: [ProgressUpdateEvent]) -> Bool {
    events.contains { event in
        switch event {
        case .addItems(let n), .setItems(let n): n > 0
        case .addSize(let n), .setSize(let n):    n > 0
        default: false
        }
    }
}

/// Safety net for a real bug in the vendored `ContainerizationOCI` registry client: on a
/// 401/403 it fetches a fresh Bearer token and retries, with an escape hatch
/// (`TokenResponse.isValid(scope:)`) meant to stop the retries once a good token is in hand.
/// That check defaults `expiresIn` to 0 when a registry omits it, so "elapsed < expiresIn" is
/// false forever and the hatch never fires. That retry branch also has no `maxRetries` cap, so
/// a registry that keeps issuing scope-insufficient tokens loops forever with no thrown error —
/// reproduced pushing to a registry that requires sign-in with none configured. Not fixable
/// here: it's Apple's code, not Berthly's.
///
/// A real transfer reports progress well before any reasonable timeout, so "zero progress yet"
/// is a safe cancel signal — it won't false-positive on a large or slow push.
actor PushStallMonitor {
    private var hasProgress = false

    func markProgress() {
        hasProgress = true
    }

    /// Keeps looping harmlessly after progress arrives (never returns) so it can't "win" the
    /// race in `raceAgainstStall` — only `timeout` elapsing with zero progress throws.
    func watch(timeout: Duration, checkInterval: Duration = .milliseconds(500)) async throws {
        var elapsedWithoutProgress: Duration = .zero
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: checkInterval)
            if hasProgress { continue }
            elapsedWithoutProgress += checkInterval
            if elapsedWithoutProgress >= timeout {
                throw PushStalledError()
            }
        }
    }
}

struct PushStalledError: LocalizedError {
    var errorDescription: String? {
        "Push made no progress and timed out. The daemon operation may still be stopping; "
            + "wait before trying this destination again. This registry may require sign-in."
    }
}

struct PushAlreadyInProgressError: LocalizedError {
    let destination: String

    var errorDescription: String? {
        "A push to \(destination) is already running or still stopping after a timeout. "
            + "If this continues indefinitely, restart Berthly to clear the blocked destination."
    }
}

actor PushOperationTracker {
    private var destinations: Set<String> = []

    func begin(_ destination: String) -> Bool {
        destinations.insert(destination).inserted
    }

    func finish(_ destination: String) {
        destinations.remove(destination)
    }
}

/// Guards `continuation.resume` from firing twice (a runtime crash) when both sides of the
/// `raceAgainstStall` race settle nearly simultaneously. A plain locked class, not an actor,
/// because `fire()` must be callable synchronously from a non-async `Task` closure.
private final class OnceGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// Not `withThrowingTaskGroup`: it implicitly awaits every remaining child before returning,
/// even one that threw the group out early. `operation` is an XPC round-trip to the container
/// daemon, and Swift's cancellation only works if the callee checks for it — there's no
/// guarantee Apple's XPC push handler does. If it doesn't, the group's implicit "await
/// everyone" wedges forever and the watchdog's error can never propagate out. (This is exactly
/// what happened: that version passed its unit tests, which had no uncancellable sibling to
/// wedge the teardown, but hung in the real app against an actual unauthenticated push.)
///
/// If `operation` loses the race and ignores cancellation, it keeps running invisibly (a
/// leaked task, not a hang) — the caller gets an answer, at the cost of not being able to
/// prove the abandoned work stopped.
func raceAgainstStall<T: Sendable>(
    timeout: Duration,
    monitor: PushStallMonitor,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let onceGuard = OnceGuard()
    return try await withCheckedThrowingContinuation { continuation in
        let opTask = Task {
            do {
                let result = try await operation()
                if onceGuard.fire() { continuation.resume(returning: result) }
            } catch {
                if onceGuard.fire() { continuation.resume(throwing: error) }
            }
        }
        let watchdogTask = Task {
            do {
                try await monitor.watch(timeout: timeout)
            } catch {
                if onceGuard.fire() {
                    continuation.resume(throwing: error)
                    opTask.cancel()
                }
            }
        }
        // If the operation wins the race, stop the watchdog rather than let it spin forever
        // (harmless once progress has started — see `watch` — but still an unbounded leaked task).
        // This cleanup task may itself wait a long time for an uncancellable `opTask`, but that's
        // fine: nothing here is awaited by `raceAgainstStall`'s own continuation.
        Task {
            _ = await opTask.value
            watchdogTask.cancel()
        }
    }
}

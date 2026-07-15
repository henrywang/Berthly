// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import TerminalProgress

/// Whether any event in the batch represents genuine forward progress (an item or byte actually
/// completed), as opposed to a planning/metadata event like `.addTotalItems`/`.addTotalSize` that
/// only describes the scope of work and can fire once, immediately, before any network I/O has
/// happened at all. `PushStallMonitor` must only arm on the former — the daemon plausibly reports
/// "N blobs, X bytes total" right away, and treating that alone as "progress" would permanently
/// disarm the stall watchdog even though zero bytes ever move afterward (exactly the bug this
/// guards against: stuck in a pre-auth retry loop before the first blob transfer even begins).
nonisolated func containsRealProgress(_ events: [ProgressUpdateEvent]) -> Bool {
    events.contains { event in
        switch event {
        case .addItems(let n), .setItems(let n): n > 0
        case .addSize(let n), .setSize(let n):    n > 0
        default: false
        }
    }
}

/// Watches a transfer for progress and throws if none arrives within a timeout — a safety net for
/// a real bug in the vendored `ContainerizationOCI` registry client: on a 401/403, it fetches a
/// fresh Bearer token and retries, with a designed escape hatch ("I already have a token that
/// should work, stop retrying") gated on `TokenResponse.isValid(scope:)`. That check defaults
/// `expiresIn` to 0 when a registry's token response omits it (an optional OAuth2 field), which
/// makes "elapsed < expiresIn" false forever — so the escape hatch never fires. Combined with that
/// retry branch having no `maxRetries` cap at all (unlike the other retry path), a registry that
/// keeps issuing scope-insufficient tokens instead of hard-rejecting the request causes an infinite
/// loop with no thrown error — reproduced pushing to a registry requiring sign-in with none
/// configured. Not fixable from here: it's Apple's code, not Berthly's.
///
/// A real transfer reports progress well before any reasonable timeout once it's actually under
/// way, so "zero progress yet" is a safe signal to cancel on — it won't false-positive on a
/// legitimately large or slow push.
actor PushStallMonitor {
    private var hasProgress = false

    func markProgress() {
        hasProgress = true
    }

    /// Polls every `checkInterval` until progress is recorded — at which point it keeps looping
    /// harmlessly (never returning normally) so a caller racing this against the real transfer via
    /// `raceAgainstStall` never has this task "win" the race — or `timeout` total elapses with
    /// none, in which case it throws `PushStalledError`. Cancellation (once the real transfer
    /// finishes and this task is cancelled by the caller) exits it via the standard
    /// `CancellationError`.
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
        "Push made no progress and was cancelled. This registry may require sign-in — add credentials in Registries, then try again."
    }
}

/// Guards `continuation.resume` being called more than once (a runtime crash) when both sides of a
/// race settle at nearly the same instant — used by `raceAgainstStall`. A plain class with a lock
/// (not an actor) because `fire()` must be callable synchronously from a non-async `Task` closure.
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

/// Runs `operation` racing it against a stall watchdog (`monitor`, see `PushStallMonitor`) —
/// **without** ever waiting for `operation` to actually finish once the watchdog fires.
///
/// A first attempt at this used `withThrowingTaskGroup`: add the operation and the watchdog as
/// child tasks, take whichever finishes first via `group.next()`. That's broken for this use case
/// specifically because `withThrowingTaskGroup` *implicitly awaits every remaining child* before
/// it can return — including one that threw the group out via an early exit. `operation` here is
/// an XPC round-trip to the container daemon; Swift's cooperative cancellation only works if the
/// callee explicitly checks for it, and there's no reason to assume Apple's XPC push handler does.
/// If it doesn't, cancelling the push task never makes it finish, so the task group's implicit
/// "await everyone" wedges forever — the watchdog's error gets thrown *internally* but can never
/// propagate out, and the caller hangs exactly as if there were no watchdog at all. (This is
/// exactly what happened: the first fix passed its unit tests, because those tested the watchdog in
/// isolation with no uncancellable sibling to wedge the teardown — but hung in the real app against
/// an actual unauthenticated push.)
///
/// This version races via a manually-resumed continuation instead of structured concurrency, so
/// there is no "wait for every child" step. Whichever of `operation`/the watchdog finishes first
/// resumes the continuation and `raceAgainstStall` returns immediately; the loser is sent a
/// best-effort `.cancel()` and otherwise abandoned — if `operation` doesn't honor cancellation, it
/// keeps running invisibly in the background (a leaked task, not a hang), which is the correct
/// trade-off: the caller gets an answer, at the cost of not being able to prove the abandoned work
/// actually stopped.
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

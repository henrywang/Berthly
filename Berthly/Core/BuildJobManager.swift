// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppKit
import Foundation
import Observation

// MARK: - BuildJob

/// One image build, running or finished. Owned by `BuildJobManager` so it outlives the
/// Build sheet — the sheet can be dismissed while the build keeps going, and any view
/// (toolbar popover, reopened sheet) can observe the same job.
@MainActor
@Observable
final class BuildJob: Identifiable {
    struct LogLine: Identifiable {
        let id = UUID()
        let text: String
    }

    enum Status: Equatable {
        case building
        case succeeded
        case failed(message: String)
    }

    nonisolated static let maxLogLineCount = 5_000
    private nonisolated static let logTrimCount = 1_000

    let id = UUID()
    let reference: String
    let startedAt = Date()
    private(set) var finishedAt: Date?
    private(set) var logLines: [LogLine] = []
    private(set) var status: Status = .building

    /// Whether the user has already seen this job's final state (watched it finish in the
    /// sheet, or opened the builds popover). Drives the toolbar badge.
    var seen = false

    /// The running build task. Held so `cancel` works; cleared when the build ends.
    fileprivate var task: Task<Void, Never>?

    init(reference: String) {
        self.reference = reference
    }

    var isFinished: Bool { status != .building }

    func appendLog(_ text: String) {
        logLines.append(LogLine(text: text))
        if logLines.count > Self.maxLogLineCount {
            // Trim in batches so sustained output doesn't shift a 5,000-element array per line.
            logLines.removeFirst(Self.logTrimCount)
        }
    }

    fileprivate func finish(_ status: Status) {
        self.status = status
        finishedAt = Date()
    }

    /// Awaits the underlying build task's completion (including after a cancel), so tests
    /// can deterministically observe the final state instead of polling.
    func waitUntilFinished() async {
        await task?.value
    }

    /// Wall-clock duration so far (while building) or total (once finished).
    var duration: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }
}

// MARK: - BuildJobManager

/// App-level registry of image builds. Builds started here run detached from any sheet,
/// so the user can keep working (run containers, create machines, browse System) while
/// they proceed, and find the result later via the toolbar builds indicator.
@MainActor
@Observable
final class BuildJobManager {
    private(set) var jobs: [BuildJob] = []

    /// Called when a build finishes while its job is still listed (i.e. not cancelled).
    /// Default bounces the Dock icon if the app is in the background, and posts a user
    /// notification when the user isn't looking at the app (window closed or app inactive
    /// — see `AppNotifier.postBuildFinished`). Replaceable so unit tests don't poke
    /// `NSApp` or the notification center.
    var notifyFinished: @MainActor (BuildJob) -> Void = { job in
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
        AppNotifier.shared.postBuildFinished(job)
    }

    var activeCount: Int { jobs.filter { !$0.isFinished }.count }
    var isBuilding: Bool { activeCount > 0 }
    var unseenFinishedCount: Int { jobs.filter { $0.isFinished && !$0.seen }.count }
    var hasUnseenFailure: Bool {
        jobs.contains { job in
            if case .failed = job.status { return !job.seen }
            return false
        }
    }

    /// Starts `options` as a background job and returns it immediately; the job's
    /// observable state (`logLines`, `status`) updates as the build proceeds. On success
    /// the build context is persisted for Rebuild, same as the old in-sheet flow.
    @discardableResult
    func start(options: BuildOptions, service: ContainerServiceBase) -> BuildJob {
        let job = BuildJob(reference: options.reference)
        jobs.insert(job, at: 0)
        job.task = Task { [weak self] in
            do {
                try await service.buildImage(options: options) { [weak job] line in
                    job?.appendLog(line)
                }
                service.saveBuildContext(BuildContext(options: options), for: options.reference)
                job.finish(.succeeded)
                await service.refresh()
            } catch is CancellationError {
                // `cancel(_:)` already removed the job; nothing to record.
            } catch {
                job.finish(.failed(message: error.localizedDescription))
            }
            job.task = nil
            if let self, self.jobs.contains(where: { $0.id == job.id }), job.isFinished {
                self.notifyFinished(job)
            }
        }
        return job
    }

    /// Cancels a running build and drops it from the list (a cancelled build has no
    /// result worth surfacing — matches the old sheet's cancel-resets-everything).
    /// `job.task` stays set until the task itself winds down, so `waitUntilFinished`
    /// still works after a cancel.
    func cancel(_ job: BuildJob) {
        job.task?.cancel()
        remove(job)
    }

    /// Removes a finished job from the list. No-op on the task: finished jobs have none.
    func remove(_ job: BuildJob) {
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.isFinished }
    }

    func markFinishedSeen() {
        for job in jobs where job.isFinished {
            job.seen = true
        }
    }
}

// MARK: - Helpers

extension BuildContext {
    /// The persistable subset of `BuildOptions` (machine-specific fields like
    /// cpus/memory/secrets/pull intentionally reset on Rebuild).
    nonisolated init(options: BuildOptions) {
        self.init(
            contextPath: options.contextPath,
            dockerfilePath: options.dockerfilePath,
            platform: options.platform,
            buildArgs: options.buildArgs,
            labels: options.labels,
            target: options.target,
            noCache: options.noCache
        )
    }
}

/// "42s", "3m 12s", "1h 4m" — compact duration for build status rows.
nonisolated func formatBuildDuration(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m \(seconds)s" }
    return "\(seconds)s"
}

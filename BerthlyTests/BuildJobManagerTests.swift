// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Berthly

/// A build service with scriptable outcomes, so tests can drive success, failure, and
/// long-running (cancellable) builds without the mock's 300 ms-per-line pacing.
/// Subclasses `ContainerServiceBase` (not `MockContainerService`, which is final); the
/// base class's in-memory `saveBuildContext` is all these tests need.
@MainActor
private final class ScriptedBuildService: ContainerServiceBase {
    enum Behavior {
        case succeed
        case fail(message: String)
        case hang
    }

    var behavior: Behavior = .succeed
    private(set) var refreshCount = 0

    override func buildImage(
        options: BuildOptions,
        onLog: @MainActor @escaping (String) -> Void
    ) async throws {
        onLog("step 1/2")
        switch behavior {
        case .succeed:
            onLog("step 2/2")
        case .fail(let message):
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        case .hang:
            try await Task.sleep(for: .seconds(60))
        }
    }

    override func refresh() async {
        refreshCount += 1
    }
}

@MainActor
struct BuildJobManagerTests {

    private func makeManager() -> BuildJobManager {
        let manager = BuildJobManager()
        // The default bounces the Dock icon and posts a user notification — not for unit tests.
        manager.notifyFinished = { _ in }
        return manager
    }

    private var options: BuildOptions {
        BuildOptions(reference: "local/test:1.0", contextPath: "/tmp/ctx")
    }

    @Test func successfulBuildFinishesAndSavesContext() async {
        let service = ScriptedBuildService()
        let manager = makeManager()

        let job = manager.start(options: options, service: service)
        #expect(job.status == .building)
        #expect(!job.isFinished)
        #expect(manager.activeCount == 1)
        #expect(manager.isBuilding)

        await job.waitUntilFinished()

        #expect(job.status == .succeeded)
        #expect(job.isFinished)
        #expect(job.finishedAt != nil)
        #expect(job.logLines.map(\.text) == ["step 1/2", "step 2/2"])
        #expect(service.buildContexts["local/test:1.0"]?.contextPath == "/tmp/ctx")
        #expect(service.refreshCount == 1)
        #expect(manager.activeCount == 0)
        #expect(manager.jobs.count == 1)
    }

    @Test func failedBuildRecordsMessageAndSkipsContextSave() async {
        let service = ScriptedBuildService()
        service.behavior = .fail(message: "no space left on device")
        let manager = makeManager()

        let job = manager.start(options: options, service: service)
        await job.waitUntilFinished()

        #expect(job.status == .failed(message: "no space left on device"))
        #expect(service.buildContexts["local/test:1.0"] == nil)
        #expect(service.refreshCount == 0)
    }

    @Test func cancelRemovesJobWithoutNotifying() async {
        let service = ScriptedBuildService()
        service.behavior = .hang
        let manager = makeManager()
        var notified = false
        manager.notifyFinished = { _ in notified = true }

        let job = manager.start(options: options, service: service)
        manager.cancel(job)
        #expect(manager.jobs.isEmpty)

        await job.waitUntilFinished()
        #expect(!notified)
        #expect(!job.isFinished)
    }

    @Test func buildLogKeepsOnlyTheNewestLines() async {
        let job = BuildJob(reference: "local/test:1.0")
        for index in 0...(BuildJob.maxLogLineCount + 999) {
            job.appendLog("line \(index)")
        }

        #expect(job.logLines.count == BuildJob.maxLogLineCount)
        #expect(job.logLines.first?.text == "line 1000")
        #expect(job.logLines.last?.text == "line \(BuildJob.maxLogLineCount + 999)")
    }

    @Test func finishNotifiesWithTheFinishedJob() async {
        let service = ScriptedBuildService()
        let manager = makeManager()
        var notifiedJobID: UUID?
        manager.notifyFinished = { notifiedJobID = $0.id }

        let job = manager.start(options: options, service: service)
        await job.waitUntilFinished()
        #expect(notifiedJobID == job.id)
    }

    @Test func unseenBadgeCountsFinishedJobsUntilMarkedSeen() async {
        let service = ScriptedBuildService()
        let manager = makeManager()

        let job = manager.start(options: options, service: service)
        #expect(manager.unseenFinishedCount == 0)  // still building — no badge

        await job.waitUntilFinished()
        #expect(manager.unseenFinishedCount == 1)
        #expect(!manager.hasUnseenFailure)

        manager.markFinishedSeen()
        #expect(manager.unseenFinishedCount == 0)
    }

    @Test func hasUnseenFailureFlagsOnlyUnseenFailedJobs() async {
        let service = ScriptedBuildService()
        service.behavior = .fail(message: "boom")
        let manager = makeManager()

        let job = manager.start(options: options, service: service)
        await job.waitUntilFinished()
        #expect(manager.hasUnseenFailure)

        manager.markFinishedSeen()
        #expect(!manager.hasUnseenFailure)
    }

    @Test func clearFinishedKeepsRunningJobs() async {
        let service = ScriptedBuildService()
        let manager = makeManager()

        let finished = manager.start(options: options, service: service)
        await finished.waitUntilFinished()

        service.behavior = .hang
        let running = manager.start(
            options: BuildOptions(reference: "local/other:2.0", contextPath: "/tmp/ctx2"),
            service: service
        )

        manager.clearFinished()
        #expect(manager.jobs.map(\.id) == [running.id])

        manager.cancel(running)
        await running.waitUntilFinished()
    }

    @Test func removeDropsOneJob() async {
        let service = ScriptedBuildService()
        let manager = makeManager()

        let job = manager.start(options: options, service: service)
        await job.waitUntilFinished()

        manager.remove(job)
        #expect(manager.jobs.isEmpty)
    }

    /// Same pattern as `MockContainerServiceTests.doesNotLeakAfterGoingOutOfScope`: the
    /// build task must not create a retain cycle keeping the manager or job alive.
    @Test func doesNotLeakAfterGoingOutOfScope() async {
        weak var weakManager: BuildJobManager?
        weak var weakJob: BuildJob?
        do {
            let service = ScriptedBuildService()
            let manager = makeManager()
            let job = manager.start(options: options, service: service)
            await job.waitUntilFinished()
            weakManager = manager
            weakJob = job
        }
        #expect(weakManager == nil)
        #expect(weakJob == nil)
    }
}

// MARK: - BuildContext(options:)

struct BuildContextFromOptionsTests {

    @Test func keepsPersistedFieldsAndDropsMachineSpecificOnes() {
        let options = BuildOptions(
            reference: "local/app:1.0",
            contextPath: "/src/app",
            dockerfilePath: "/src/app/Containerfile",
            platform: "linux/arm64",
            buildArgs: ["NODE_ENV": "production"],
            noCache: true,
            labels: ["team": "infra"],
            target: "release",
            cpus: 8,
            memory: "4g",
            secrets: ["id=token,env=TOKEN"],
            pull: true
        )
        let ctx = BuildContext(options: options)
        #expect(ctx.contextPath == "/src/app")
        #expect(ctx.dockerfilePath == "/src/app/Containerfile")
        #expect(ctx.platform == "linux/arm64")
        #expect(ctx.buildArgs == ["NODE_ENV": "production"])
        #expect(ctx.labels == ["team": "infra"])
        #expect(ctx.target == "release")
        #expect(ctx.noCache)
    }
}

// MARK: - buildFinishedNotificationText

struct BuildFinishedNotificationTextTests {

    @Test func successMentionsReferenceAndDuration() {
        let text = buildFinishedNotificationText(reference: "local/app:1.0", status: .succeeded, duration: 42)
        #expect(text.title == "Image Built")
        #expect(text.body == "local/app:1.0 built in 42s.")
    }

    @Test func failureCarriesTheErrorMessage() {
        let text = buildFinishedNotificationText(
            reference: "local/app:1.0",
            status: .failed(message: "no space left on device"),
            duration: 3
        )
        #expect(text.title == "Build Failed")
        #expect(text.body == "local/app:1.0: no space left on device")
    }
}

// MARK: - formatBuildDuration

struct FormatBuildDurationTests {

    @Test func secondsOnly() {
        #expect(formatBuildDuration(0) == "0s")
        #expect(formatBuildDuration(42) == "42s")
    }

    @Test func minutesAndSeconds() {
        #expect(formatBuildDuration(60) == "1m 0s")
        #expect(formatBuildDuration(192) == "3m 12s")
    }

    @Test func hoursAndMinutes() {
        #expect(formatBuildDuration(3840) == "1h 4m")
    }

    @Test func negativeClampsToZero() {
        #expect(formatBuildDuration(-5) == "0s")
    }

    @Test func fractionalSecondsRound() {
        #expect(formatBuildDuration(41.6) == "42s")
    }
}

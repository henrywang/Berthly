// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

// MARK: - Recreate Container Sheet

/// Watchtower-style update flow: pull the container's tag (when the registry has something
/// newer), then stop/delete/recreate it from its stored configuration and restore the prior run
/// state. Modeled on `PullImageSheet` (idle → working → done in one frame) because the pull is
/// the dominant-duration phase; the recreate steps append to the same log as `STEP` lines.
struct RecreateContainerSheet: View {
    let container: Container

    @Environment(ContainerServiceBase.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var phase: RecreatePhase?
    @State private var isWorking = false
    @State private var isDone = false
    @State private var result: RecreateResult?
    @State private var errorMessage: String?
    @State private var progress = TransferProgressState.pull()
    @State private var recreateTask: Task<Void, Never>?
    @State private var reclaim: ReclaimPhase = .idle

    private enum ReclaimPhase: Equatable { case idle, working, freed(UInt64) }

    /// Only the pull phase is cancellable. `phase == nil` while working must NOT qualify: in the
    /// no-pull path the service runs several awaits before its first phase report, and a cancel
    /// landing there would dismiss the sheet while XPC calls that ignore cancellation continue
    /// replacing the container behind it (the service double-checks cancellation right before
    /// its replace window, but the button shouldn't invite the race at all).
    private var canCancel: Bool { phase == .pullingImage }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: "arrow.triangle.2.circlepath",
                title: "Recreate \(container.name)",
                subtitle: "\(container.image)"
            )

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                if isWorking || isDone {
                    activeContent
                } else {
                    idleContent
                }
                if let error = errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
            }
            .padding(20)

            Divider()

            SheetSubmitFooter(
                phase: isDone ? .done : (isWorking ? .working : .idle),
                submitLabel: "Recreate",
                busyLabel: "Recreating…",
                submitIdentifier: "recreateSubmitButton",
                onCancel: cancelRecreate,
                workingCancelDisabledHelp: canCancel ? nil : "Replacing the container — this step can't be cancelled.",
                onSubmit: startRecreate
            )
        }
        .frame(width: 480)
        // The replace window must finish even if the sheet goes away mid-flight — only an
        // explicit Cancel during the pull phase stops the task.
        .interactiveDismissDisabled(isWorking)
    }

    // MARK: - Idle (confirm)

    @ViewBuilder
    private var idleContent: some View {
        SheetCallout(tint: .statusPaused) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.statusPaused)
                    .imageScale(.small)
                    .padding(.top, 1)
                Text("""
                The container is deleted and recreated from its image. Changes inside the \
                container's own filesystem are discarded. Data on volumes is kept. If \
                "Remove when stopped" was enabled, that setting cannot be preserved by recreation.
                """)
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 4) {
            Text(stalenessContext)
                .fixedSize(horizontal: false, vertical: true)
            if container.status == .running {
                Text("\(container.name) will be stopped, recreated, and started again.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var stalenessContext: LocalizedStringKey {
        switch service.staleness(of: container) {
        case .remoteUpdateAvailable:
            return "A newer image is available for this tag — it will be pulled first."
        case .localImageNewer:
            return "A newer image was already pulled — the container will be recreated from it."
        case .current:
            return "The image is up to date — this recreates the container in a fresh state."
        }
    }

    // MARK: - Working / done

    @ViewBuilder
    private var activeContent: some View {
        if isWorking, phase == .pullingImage {
            TransferProgressHeader(title: "Pulling latest image", progress: progress)
        }
        if isWorking, let phase {
            Text(phase.logLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("recreatePhaseLabel")
        }

        TransferLogView(lines: progress.logLines)

        if isDone, let result {
            SheetStatusCallout(symbol: "checkmark.circle.fill", tint: .green, title: "Container recreated", alignment: .center) {
                SheetCalloutDetail(
                    text: result.wasRunning
                        ? "\(container.name) is running on the updated image."
                        : "\(container.name) was recreated and left stopped.",
                    monospaced: false
                )
            }
            if result.oldImageReclaimable {
                reclaimRow
            }
        }
    }

    @ViewBuilder
    private var reclaimRow: some View {
        switch reclaim {
        case .idle:
            HStack(spacing: 8) {
                Button("Reclaim Old Image Space") { performReclaim() }
                    .accessibilityIdentifier("reclaimOldImageButton")
                Text("The previous image version is no longer used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reclaiming…").font(.caption).foregroundStyle(.secondary)
            }
        case .freed(let bytes):
            Label("Freed \(formatDiskBytes(bytes))", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityIdentifier("reclaimFreedLabel")
        }
    }

    // MARK: - Actions

    private func startRecreate() {
        guard !isWorking else { return }
        isWorking = true
        isDone = false
        errorMessage = nil
        phase = nil
        // Skip the pull when the user already pulled (that *is* the localImageNewer state);
        // otherwise let the service decide — a cached-tag pull is a cheap no-op.
        let willPull = service.staleness(of: container) != .localImageNewer
        progress = TransferProgressState.pull()
        if willPull {
            progress.start(reference: container.image)
        } else {
            progress.appendLog(tag: "STEP", text: "using the already-pulled local image")
        }

        recreateTask = Task {
            do {
                let outcome = try await service.recreateContainer(
                    container.id, pullFirst: willPull,
                    progress: progress.handler,
                    onPhase: { newPhase in
                        phase = newPhase
                        if newPhase != .pullingImage {
                            // The log box is a terminal-style trace (same convention as the
                            // unlocalized "unpacking image"/"resolving manifest" lines elsewhere),
                            // so a resolved plain String is fine here — only the on-screen
                            // caption above needs the LocalizedStringResource itself.
                            progress.appendLog(tag: "STEP", text: String(localized: newPhase.logLine))
                        }
                    }
                )
                progress.appendLog(tag: "DONE", text: outcome.wasRunning
                    ? "\(container.name) recreated and started"
                    : "\(container.name) recreated")
                result = outcome
                isWorking = false
                isDone = true
            } catch is CancellationError {
                isWorking = false
                phase = nil
            } catch {
                errorMessage = error.localizedDescription
                isWorking = false
                phase = nil
            }
            recreateTask = nil
        }
    }

    private func cancelRecreate() {
        guard canCancel else { return }
        recreateTask?.cancel()
        recreateTask = nil
        isWorking = false
        phase = nil
        errorMessage = nil
    }

    private func performReclaim() {
        reclaim = .working
        Task {
            do {
                reclaim = .freed(try await service.reclaimOrphanedImageBlobs())
            } catch {
                errorMessage = error.localizedDescription
                reclaim = .idle
            }
        }
    }
}

#Preview {
    RecreateContainerSheet(container: MockContainerService().containers[2])
        .environment(MockContainerService() as ContainerServiceBase)
}

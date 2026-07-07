// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppKit
import SwiftUI

/// Replaces content with a contextual screen when the daemon isn't connected.
/// Sidebar is always visible; only the content/detail area is gated.
struct DaemonGateView<Content: View>: View {
    @Environment(ContainerServiceBase.self) private var service
    @ViewBuilder private let content: () -> Content

    /// An in-flight install/update. Held here — NOT inside the per-state gate subviews — because
    /// the operation itself changes `daemonState` (stop → installedButStopped → connecting…),
    /// which tears the current gate down mid-flight. State at this level survives those
    /// transitions, so the progress screen stays up until the operation actually finishes.
    @State private var operationMessage: String?
    @State private var operationLogs: [String] = []
    @State private var operationTask: Task<Void, Never>?
    @State private var operationError: OperationError?

    private struct OperationError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        Group {
            if let message = operationMessage {
                ProgressLogScreen(message: message, logLines: operationLogs) {
                    operationTask?.cancel()
                }
            } else {
                gate
            }
        }
        .alert(
            operationError?.title ?? "Operation Failed",
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )
        ) {
            Button("OK") { operationError = nil }
        } message: {
            Text(operationError?.message ?? "")
        }
    }

    @ViewBuilder private var gate: some View {
        switch service.daemonState {
        case .connected:
            content()

        case .checking:
            progressScreen(message: "Checking daemon…")

        case .connecting:
            progressScreen(message: "Starting container system…")

        case .stopping:
            progressScreen(message: "Stopping container system…")

        case .notInstalled:
            InstallGate {
                runOperation(
                    message: "Installing container v\(ContainerCompatibility.requiredVersion)…",
                    failureTitle: "Install Failed"
                ) { service, onLog in
                    try await service.installContainer(onLog: onLog)
                }
            }

        case .installedButStopped:
            ContentUnavailableView {
                Label("Container System Stopped", systemImage: "circle")
            } description: {
                Text("The container daemon is installed but not running.")
            } actions: {
                Button("Start Container System") {
                    Task { await service.startDaemon() }
                }
                .buttonStyle(.borderedProminent)
            }

        case .versionMismatch(let installed, let required):
            switch ContainerCompatibility.mismatch(installed: installed, required: required) {
            case .tooNew:
                TooNewGate(installed: installed, required: required)
            case .tooOld, nil:
                // nil can't actually happen (the state only exists because the check failed),
                // but falling into the upgrade gate is the sane answer if it somehow does.
                VersionMismatchGate(installed: installed, required: required) {
                    runOperation(
                        message: "Updating container to v\(required)…",
                        failureTitle: "Update Failed"
                    ) { service, onLog in
                        try await service.upgradeContainer(onLog: onLog)
                    }
                }
            }

        case .error(let message):
            ContentUnavailableView {
                Label("Connection Error", systemImage: "exclamationmark.circle")
            } description: {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } actions: {
                Button("Retry") {
                    Task { await service.refresh() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Runs a privileged maintenance operation with the shared progress screen. Activates the
    /// app first so the admin-password dialog appears on the user's current space instead of
    /// wherever the app's window happens to live. Cancellation (the progress screen's Cancel)
    /// is not an error — the service kills the elevated process and we just return to the gate.
    private func runOperation(
        message: String,
        failureTitle: String,
        _ work: @escaping (ContainerServiceBase, @MainActor @escaping (String) -> Void) async throws -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        operationMessage = message
        operationLogs = []
        operationTask = Task {
            do {
                try await work(service) { line in
                    operationLogs.append(line)
                }
            } catch is CancellationError {
                // User hit Cancel — no alert.
            } catch {
                operationError = OperationError(title: failureTitle, message: error.localizedDescription)
            }
            operationMessage = nil
            operationTask = nil
        }
    }

    // MARK: - Not installed

    /// Guided first-time install: download the pinned release's signed pkg, verify it, run the
    /// installer elevated, start the daemon — all via `service.installContainer`. The manual
    /// GitHub-releases route stays as a secondary link for users who'd rather run the pkg
    /// themselves.
    private struct InstallGate: View {
        let onConfirm: () -> Void
        @State private var showInstallConfirm = false

        var body: some View {
            ContentUnavailableView {
                Label("Container Not Installed", systemImage: "shippingbox")
            } description: {
                Text("Berthly manages containers through Apple's container tool, which isn't installed on this Mac.")
            } actions: {
                VStack(spacing: 8) {
                    Button("Install container v\(ContainerCompatibility.requiredVersion)…") {
                        showInstallConfirm = true
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("installContainerButton")

                    Button("Download manually from GitHub…") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/apple/container/releases/latest")!)
                    }
                    .buttonStyle(.link)
                }
            }
            .alert("Install container v\(ContainerCompatibility.requiredVersion)?", isPresented: $showInstallConfirm) {
                Button("Install") { onConfirm() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Berthly downloads Apple's signed installer package from GitHub, verifies it, and installs it. You'll be asked for your admin password.")
            }
        }
    }

    // MARK: - Version mismatch (too old)

    /// The version-mismatch gate blocks every page — including the System page, where the update
    /// button normally lives — so the fix has to be offered right here or the user is stuck being
    /// told to update with no way to do it. Confirms, then hands off to `service.upgradeContainer`
    /// (stop daemon → run the upstream update script with an admin prompt → restart).
    private struct VersionMismatchGate: View {
        let installed: String
        let required: String
        let onConfirm: () -> Void
        @State private var showUpdateConfirm = false

        var body: some View {
            ContentUnavailableView {
                Label("Update Required", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Installed: v\(installed) · Required: v\(required) or newer")
            } actions: {
                Button("Update Container to v\(required)…") {
                    showUpdateConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("updateContainerButton")
            }
            .alert("Update container to v\(required)?", isPresented: $showUpdateConfirm) {
                Button("Update", role: .destructive) { onConfirm() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This stops every running container on this Mac, not just ones Berthly manages, while the update runs. You'll be asked for your admin password.")
            }
        }
    }

    // MARK: - Version mismatch (too new)

    /// A container from a newer major release can't be downgraded in place (upstream requires a
    /// full uninstall first), so Berthly never touches it — the fix is a newer Berthly.
    private struct TooNewGate: View {
        let installed: String
        let required: String

        var body: some View {
            // No action button: Berthly has no public releases page yet, and once Sparkle lands
            // the app menu's "Check for Updates…" is the canonical way to get a newer Berthly.
            ContentUnavailableView {
                Label("Update Berthly", systemImage: "arrow.up.circle")
            } description: {
                Text("The installed container (v\(installed)) is newer than this version of Berthly supports (v\(required)).\nUpdate Berthly to keep using it — your container installation won't be touched.")
            }
        }
    }

    // MARK: - Shared progress + log screen

    /// Spinner, status line, scrolling monospaced log, and a Cancel button — shared by the
    /// install and update flows so both privileged operations report progress identically.
    /// The update script's output only arrives when it finishes (`do shell script` doesn't
    /// stream), so the hint below the spinner is what tells the user an admin prompt is coming.
    /// `fileprivate` (not `private`) so the preview at the bottom of this file can render it.
    fileprivate struct ProgressLogScreen: View {
        let message: String
        let logLines: [String]
        let onCancel: () -> Void

        var body: some View {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("operationProgressMessage")
                Text("You may be asked for your admin password. This can take a few minutes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if !logLines.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxWidth: 480, maxHeight: 160)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
                }
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .accessibilityIdentifier("cancelOperationButton")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func progressScreen(message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Stopped") {
    DaemonGateView {
        Text("content")
    }
    .environment({
        let s = MockContainerService()
        s.daemonState = .installedButStopped
        return s as ContainerServiceBase
    }())
    .frame(width: 600, height: 500)
}

#Preview("Not installed") {
    DaemonGateView {
        Text("content")
    }
    .environment({
        let s = MockContainerService()
        s.daemonState = .notInstalled
        return s as ContainerServiceBase
    }())
    .frame(width: 600, height: 500)
}

#Preview("Version mismatch (too old)") {
    DaemonGateView {
        Text("content")
    }
    .environment({
        let s = MockContainerService()
        s.daemonState = .versionMismatch(installed: "1.0.2", required: "1.1.0")
        return s as ContainerServiceBase
    }())
    .frame(width: 600, height: 500)
}

#Preview("Version mismatch (too new)") {
    DaemonGateView {
        Text("content")
    }
    .environment({
        let s = MockContainerService()
        s.daemonState = .versionMismatch(installed: "2.0.0", required: "1.1.0")
        return s as ContainerServiceBase
    }())
    .frame(width: 600, height: 500)
}

#Preview("Connected") {
    DaemonGateView {
        Text("Live content here")
    }
    .environment(MockContainerService() as ContainerServiceBase)
    .frame(width: 600, height: 500)
}

#Preview("Operation in progress") {
    DaemonGateView<Text>.ProgressLogScreen(
        message: "Updating container to v1.1.0…",
        logLines: [
            "Updating to release version 1.1.0",
            "Downloading package from: https://github.com/apple/container/releases/…",
            "Installing package to /usr/local…",
        ],
        onCancel: {}
    )
    .frame(width: 600, height: 500)
}

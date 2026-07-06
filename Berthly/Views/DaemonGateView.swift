// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppKit
import SwiftUI

/// Replaces content with a contextual screen when the daemon isn't connected.
/// Sidebar is always visible; only the content/detail area is gated.
struct DaemonGateView<Content: View>: View {
    @Environment(ContainerServiceBase.self) private var service
    @ViewBuilder private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
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
            ContentUnavailableView {
                Label("Container Not Installed", systemImage: "xmark.circle")
            } description: {
                Text("Berthly manages containers through Apple's container CLI, which isn't installed on this Mac.\nOnce installed, Berthly detects it automatically.")
            } actions: {
                Button("Get container…") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/apple/container/releases/latest")!)
                }
                .buttonStyle(.borderedProminent)
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
            VersionMismatchGate(installed: installed, required: required)

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

    // MARK: - Version mismatch

    /// The version-mismatch gate blocks every page — including the System page, where the update
    /// button normally lives — so the fix has to be offered right here or the user is stuck being
    /// told to update with no way to do it. Reuses `service.upgradeContainer` (the System page's
    /// flow): stop daemon → run the upstream update script with an admin prompt → restart.
    private struct VersionMismatchGate: View {
        let installed: String
        let required: String
        @Environment(ContainerServiceBase.self) private var service
        @State private var showUpdateConfirm = false
        @State private var isUpdating = false
        @State private var logLines: [String] = []
        @State private var errorMessage: String?

        var body: some View {
            Group {
                if isUpdating {
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Updating container to v\(required)…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Update Required", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Installed: v\(installed) · Required: v\(required)")
                    } actions: {
                        Button("Update Container to v\(required)…") {
                            showUpdateConfirm = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .alert("Update container to v\(required)?", isPresented: $showUpdateConfirm) {
                Button("Update", role: .destructive) { startUpdate() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This stops every running container on this Mac, not just ones Berthly manages, while the update runs. You'll be asked for your admin password.")
            }
            .alert("Update Failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }

        private func startUpdate() {
            isUpdating = true
            logLines = []
            Task {
                do {
                    try await service.upgradeContainer { line in
                        logLines.append(line)
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
                isUpdating = false
            }
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

#Preview("Version mismatch") {
    DaemonGateView {
        Text("content")
    }
    .environment({
        let s = MockContainerService()
        s.daemonState = .versionMismatch(installed: "0.9.0", required: "1.0.0")
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

// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

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

        case .notInstalled:
            ContentUnavailableView {
                Label("Container Not Installed", systemImage: "xmark.circle")
            } description: {
                Text("Install the container CLI, then relaunch Berthly.")
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
            ContentUnavailableView {
                Label("Version Mismatch", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Installed: v\(installed) · Required: v\(required)\nUpdate the container CLI to continue.")
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

#Preview("Connected") {
    DaemonGateView {
        Text("Live content here")
    }
    .environment(MockContainerService() as ContainerServiceBase)
    .frame(width: 600, height: 500)
}

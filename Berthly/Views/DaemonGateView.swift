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
            InstallGate()

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
                VersionMismatchGate(installed: installed, required: required)
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

    // MARK: - Not installed

    /// Guided first-time install: download the pinned release's signed pkg, verify it, run the
    /// installer elevated, start the daemon — all via `service.installContainer`. The manual
    /// GitHub-releases route stays as a secondary link for users who'd rather run the pkg
    /// themselves.
    private struct InstallGate: View {
        @Environment(ContainerServiceBase.self) private var service
        @State private var showInstallConfirm = false
        @State private var isInstalling = false
        @State private var logLines: [String] = []
        @State private var errorMessage: String?

        var body: some View {
            Group {
                if isInstalling {
                    ProgressLogScreen(
                        message: "Installing container v\(ContainerCompatibility.requiredVersion)…",
                        logLines: logLines
                    )
                } else {
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
                }
            }
            .alert("Install container v\(ContainerCompatibility.requiredVersion)?", isPresented: $showInstallConfirm) {
                Button("Install") { startInstall() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Berthly downloads Apple's signed installer package from GitHub, verifies it, and installs it. You'll be asked for your admin password.")
            }
            .alert("Install Failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }

        private func startInstall() {
            isInstalling = true
            logLines = []
            Task {
                do {
                    try await service.installContainer { line in
                        logLines.append(line)
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
                isInstalling = false
            }
        }
    }

    // MARK: - Version mismatch (too old)

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
                    ProgressLogScreen(message: "Updating container to v\(required)…", logLines: logLines)
                } else {
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

    /// Spinner, status line, and a scrolling monospaced log — shared by the install and update
    /// flows so both privileged operations report progress identically.
    private struct ProgressLogScreen: View {
        let message: String
        let logLines: [String]

        var body: some View {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(message)
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

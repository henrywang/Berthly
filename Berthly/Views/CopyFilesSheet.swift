// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppKit
import SwiftUI

/// Copies a file or folder between the host and a container's filesystem, either direction. The
/// host side always uses a native file panel (pick a file *or* folder); the container side is a
/// typed path, because the API exposes copy-by-path but no directory listing to browse. Launched
/// from the container detail header.
struct CopyFilesSheet: View {
    let service: ContainerServiceBase
    let containerID: String
    let targetName: String

    @Environment(\.dismiss) private var dismiss

    @State private var direction: CopyDirection

    init(service: ContainerServiceBase, containerID: String, targetName: String, initialDirection: CopyDirection = .intoContainer) {
        self.service = service
        self.containerID = containerID
        self.targetName = targetName
        _direction = State(initialValue: initialDirection)
    }
    /// Host side: the source (a file or folder) when copying in; the *destination folder* when
    /// copying out — see `startCopy()` for how the folder becomes a concrete target path.
    @State private var hostPath = ""
    /// Container side: the destination when copying in, the source when copying out.
    @State private var containerPath = ""

    @State private var isCopying = false
    @State private var result: CopyResult?
    @State private var copyTask: Task<Void, Never>?

    private enum CopyResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            fields
                .padding(20)
                .submitsOnReturn(when: canCopy && !isCopying, action: startCopy)
            Divider()
            footer
        }
        .frame(width: 520)
    }

    // MARK: - Header

    private var header: some View {
        SheetHeader(
            systemImage: "folder",
            title: "Copy Files",
            subtitle: "Move a file or folder between your Mac and \(targetName)"
        )
    }

    // MARK: - Fields

    @ViewBuilder
    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Direction", selection: $direction) {
                Text("Into Container").tag(CopyDirection.intoContainer)
                Text("Out of Container").tag(CopyDirection.outOfContainer)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isCopying)
            // The two sides swap roles (source ⇄ destination) between directions, so a path left
            // over from the other direction would almost always be wrong — clear on flip.
            .onChange(of: direction) { _, _ in
                hostPath = ""
                containerPath = ""
                result = nil
            }

            switch direction {
            case .intoContainer:
                hostField(title: "From — your Mac", placeholder: "Choose a file or folder…", pick: pickHostSource)
                containerField(title: "To — path in \(targetName)", placeholder: "/app  or  /tmp/data")
            case .outOfContainer:
                containerField(title: "From — path in \(targetName)", placeholder: "/var/log/app.log")
                hostField(title: "To — folder on your Mac", placeholder: "Choose a folder…", pick: pickHostDestinationFolder)
                if !trimmedHost.isEmpty, !trimmedContainer.isEmpty {
                    Text("Saves as  \(LiveContainerService.resolvedHostDestination(folder: trimmedHost, containerSource: trimmedContainer))")
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let result {
                resultBanner(result)
            }
        }
    }

    private func hostField(title: String, placeholder: String, pick: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(placeholder, text: $hostPath)
                    .accessibilityIdentifier("copyHostPathField")
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .disabled(isCopying)
                Button("Choose…", action: pick)
                    .disabled(isCopying)
            }
        }
    }

    private func containerField(title: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $containerPath)
                .accessibilityIdentifier("copyContainerPathField")
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .disabled(isCopying)
        }
    }

    @ViewBuilder
    private func resultBanner(_ result: CopyResult) -> some View {
        switch result {
        case .success(let message):
            banner(icon: "checkmark.circle.fill", tint: .green, message: message)
        case .failure(let message):
            banner(icon: "xmark.circle.fill", tint: .red, message: message)
        }
    }

    private func banner(icon: String, tint: Color, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(4)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.2), lineWidth: 0.5))
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            if isCopying {
                Button("Cancel") { cancelCopy() }.keyboardShortcut(.cancelAction)
                Button {} label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Copying…")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(true)
            } else if case .success = result {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            } else {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Copy") { startCopy() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCopy)
                    .keyboardShortcut(.return)
                    .accessibilityIdentifier("copyFilesSubmitButton")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - State

    private var trimmedHost: String { hostPath.trimmingCharacters(in: .whitespaces) }
    private var trimmedContainer: String { containerPath.trimmingCharacters(in: .whitespaces) }
    private var canCopy: Bool { !trimmedHost.isEmpty && !trimmedContainer.isEmpty }

    // MARK: - Actions

    private func pickHostSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the file or folder to copy into the container"
        if panel.runModal() == .OK, let url = panel.url { hostPath = url.path }
    }

    private func pickHostDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder to save the copied item into"
        if panel.runModal() == .OK, let url = panel.url { hostPath = url.path }
    }

    private func startCopy() {
        guard canCopy, !isCopying else { return }
        // copyOut writes to an exact path, so turn the chosen destination *folder* into
        // folder/<source-name>. copyIn takes the host path (a file or folder) as-is.
        let host = direction == .outOfContainer
            ? LiveContainerService.resolvedHostDestination(folder: trimmedHost, containerSource: trimmedContainer)
            : trimmedHost
        let container = trimmedContainer
        let dir = direction

        isCopying = true
        result = nil
        copyTask = Task {
            do {
                try await service.copyFiles(direction: dir, containerID: containerID, hostPath: host, containerPath: container)
                let landed = dir == .intoContainer ? container : host
                result = .success("Copied to \(landed)")
            } catch is CancellationError {
                result = nil
            } catch {
                result = .failure(error.localizedDescription)
            }
            isCopying = false
            copyTask = nil
        }
    }

    private func cancelCopy() {
        copyTask?.cancel()
        copyTask = nil
        isCopying = false
        result = nil
    }
}

#Preview("Into container") {
    CopyFilesSheet(service: MockContainerService(), containerID: "abc123", targetName: "web-frontend")
}

#Preview("Out of container") {
    CopyFilesSheet(service: MockContainerService(), containerID: "abc123", targetName: "web-frontend",
                   initialDirection: .outOfContainer)
}

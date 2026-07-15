// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI
import TerminalProgress

// MARK: - Install state

@MainActor
@Observable
private final class KernelInstallState {
    var isInstalling = false
    var statusText = ""
    var fraction: Double? = nil
    var errorMessage: String?

    private var totalBytes: Int64 = 0
    private var downloadedBytes: Int64 = 0

    func start() {
        isInstalling = true
        statusText = "Starting…"
        fraction = nil
        errorMessage = nil
        totalBytes = 0
        downloadedBytes = 0
    }

    func handle(_ events: [ProgressUpdateEvent]) {
        for event in events {
            switch event {
            case .setDescription(let text): statusText = text
            case .addTotalSize(let n):      totalBytes += n
            case .addSize(let n):           downloadedBytes += n
            default: break
            }
        }
        if totalBytes > 0 {
            fraction = min(1.0, Double(downloadedBytes) / Double(totalBytes))
        }
    }

    var handler: ProgressUpdateHandler {
        { [weak self] events in
            await self?.handle(events)
        }
    }
}

// MARK: - Sheet

struct SetKernelSheet: View {
    let service: ContainerServiceBase
    let currentKernel: KernelInfo?

    @Environment(\.dismiss) private var dismiss

    enum Source: String, CaseIterable, Identifiable {
        case binary = "Binary"
        case tar = "Tar"
        var id: String { rawValue }
    }

    init(service: ContainerServiceBase, currentKernel: KernelInfo?, initialSource: Source = .tar) {
        self.service = service
        self.currentKernel = currentKernel
        _source = State(initialValue: initialSource)
    }

    @State private var source: Source
    @State private var binaryPath = ""
    @State private var tarSource = ""
    @State private var tarBinaryPath = ""
    @State private var architecture: String = {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }()
    @State private var force = false
    @State private var state = KernelInstallState()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Form {
                Section {
                    Picker("Source", selection: $source) {
                        ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Picker("Architecture", selection: $architecture) {
                        Text("arm64").tag("arm64")
                        Text("amd64").tag("amd64")
                    }
                    .pickerStyle(.segmented)
                }

                sourceSection

                Section {
                    Toggle("Force re-install", isOn: $force)
                } footer: {
                    Text("Re-applies even if the selected kernel already matches the active one.")
                }

                if state.isInstalling {
                    Section {
                        progressRow
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 520)
            .disabled(state.isInstalling)
            .task { prefillFromRecommendedIfEmpty() }
            .onChange(of: service.systemConfigInfo) { prefillFromRecommendedIfEmpty() }
            .submitsOnReturn(when: isValid && !state.isInstalling, action: install)

            Divider()
            footer
        }
        .frame(width: 540)
        .errorAlert($state.errorMessage)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cpu")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set Kernel")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var subtitle: String {
        guard let currentKernel else { return "Guest kernel for new microVMs" }
        let name = URL(fileURLWithPath: currentKernel.path).lastPathComponent
        return "Guest kernel for new microVMs · current \(name)"
    }

    @ViewBuilder
    private var sourceSection: some View {
        switch source {
        case .binary: binarySection
        case .tar: tarSection
        }
    }

    private var binarySection: some View {
        Section {
            pathField("Binary", prompt: "/path/to/vmlinux", text: $binaryPath, chooser: pickBinaryFile)
        } header: {
            Text("Kernel Binary")
        } footer: {
            Text("A vmlinux binary already on disk.")
        }
    }

    private var tarSection: some View {
        Section {
            pathField("Archive", prompt: "/path/to/kernel.tar.zst or https://…", text: $tarSource, chooser: pickTarFile)
            pathField("Path inside archive", prompt: "opt/kata/share/kata-containers/vmlinux", text: $tarBinaryPath, chooser: nil)
        } header: {
            HStack {
                Text("Tar Archive")
                Spacer()
                if service.systemConfigInfo != nil {
                    Button("Use Recommended") { prefillFromRecommended() }
                        .buttonStyle(.link)
                        .textCase(nil)
                }
            }
        } footer: {
            Text("Pre-filled from config.toml's recommended kernel — edit to install a different one.")
        }
    }

    /// A label-above row with a monospaced path field and an optional "Choose…" file-picker
    /// button. Label-above (rather than `LabeledContent`'s left label) keeps long paths and
    /// URLs readable at full row width.
    private func pathField(_ label: String, prompt: String, text: Binding<String>, chooser: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("", text: text, prompt: Text(prompt))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity)
                if let chooser {
                    Button("Choose…", action: chooser)
                }
            }
        }
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let fraction = state.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("New VMs pick up the kernel · running containers are unaffected.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            if state.isInstalling {
                Button("Cancel") {}.disabled(true)
                Button {} label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Installing…")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(true)
            } else {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set Kernel") { install() }
                    .buttonStyle(.borderedProminent)
                    .tint(.berthlyAccent)
                    .disabled(!isValid)
                    .keyboardShortcut(.return)
            }
        }
        .padding(16)
    }

    // MARK: - Helpers

    private var isValid: Bool {
        switch source {
        case .binary: return !binaryPath.trimmingCharacters(in: .whitespaces).isEmpty
        case .tar:
            return !tarSource.trimmingCharacters(in: .whitespaces).isEmpty
                && !tarBinaryPath.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func prefillFromRecommended() {
        guard let config = service.systemConfigInfo else { return }
        tarSource = config.kernelURL
        tarBinaryPath = config.kernelBinaryPath
    }

    private func prefillFromRecommendedIfEmpty() {
        guard tarSource.isEmpty, tarBinaryPath.isEmpty else { return }
        prefillFromRecommended()
    }

    // MARK: - Actions

    private func pickBinaryFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a kernel binary"
        if panel.runModal() == .OK, let url = panel.url {
            binaryPath = url.path(percentEncoded: false)
        }
    }

    private func pickTarFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a kernel tar archive"
        if panel.runModal() == .OK, let url = panel.url {
            tarSource = url.path(percentEncoded: false)
        }
    }

    private func install() {
        state.start()
        Task {
            do {
                switch source {
                case .binary:
                    try await service.setKernel(options: KernelSetOptions(
                        binaryPath: binaryPath, tarSource: nil, architecture: architecture, force: force
                    ))
                case .tar:
                    try await service.setKernel(
                        options: KernelSetOptions(
                            binaryPath: tarBinaryPath, tarSource: tarSource, architecture: architecture, force: force
                        ),
                        progress: state.handler
                    )
                }
                state.isInstalling = false
                dismiss()
            } catch {
                state.isInstalling = false
                state.errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview("Binary tab") {
    SetKernelSheetPreviewHarness(source: .binary)
}

#Preview("Tar tab") {
    SetKernelSheetPreviewHarness(source: .tar)
}

private struct SetKernelSheetPreviewHarness: View {
    let source: SetKernelSheet.Source
    private let mock = MockContainerService()

    var body: some View {
        SetKernelSheet(
            service: mock,
            currentKernel: KernelInfo(path: "/opt/kata/share/kata-containers/vmlinux-6.18.15-186", platform: "linux/arm64"),
            initialSource: source
        )
        .task { try? await mock.fetchSystemConfig() }
    }
}

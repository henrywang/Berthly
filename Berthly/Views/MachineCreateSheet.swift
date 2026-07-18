// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

// MARK: - Create-machine state

@MainActor
@Observable
private final class MachineCreateState {
    enum Result {
        case success(reference: String)
        case failure(message: String)
    }

    var isRunning = false
    var result: Result?
    var runTask: Task<Void, Never>?
}

private enum HomeMountChoice: String, CaseIterable {
    case `default` = ""
    case rw = "rw"
    case ro = "ro"
    case none = "none"

    var label: String {
        switch self {
        case .default: return "Default (rw)"
        case .rw:      return "Read/write"
        case .ro:      return "Read-only"
        case .none:    return "None"
        }
    }
}

/// Only 6 fields total, so unlike RunContainerSheet this stays a flat form — a categorized
/// sidebar would be mostly empty space for this few options.
struct MachineCreateSheet: View {
    let service: ContainerServiceBase

    @Environment(\.dismiss) private var dismiss

    @State private var reference = ""
    @State private var name = ""
    @State private var platformChoice: SheetPlatformChoice = .default
    @State private var cpus = ""
    @State private var memory = ""
    @State private var bootImmediately = true

    @State private var showAdvanced = false
    @State private var homeMountChoice: HomeMountChoice = .default
    @State private var setDefault = false
    @State private var insecureRegistry = false

    @State private var state = MachineCreateState()

    init(service: ContainerServiceBase) {
        self.service = service
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: "desktopcomputer",
                title: "Create Machine",
                subtitle: "Provision a new container machine from an image"
            )

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if state.isRunning || state.result != nil {
                        activeContent
                    } else {
                        idleContent
                    }
                }
                .padding(20)
                .submitsOnReturn(when: canCreate, action: startSubmit)
            }
            .frame(maxHeight: 420)

            Divider()

            SheetSubmitFooter(
                phase: footerPhase,
                submitLabel: "Create",
                busyLabel: "Creating…",
                canSubmit: canCreate,
                submitIdentifier: "machineCreateSubmitButton",
                onCancel: cancelRun,
                onSubmit: startSubmit
            )
        }
        .frame(width: 520)
    }

    private var footerPhase: SheetSubmitFooter.Phase {
        switch state.result {
        case .success: return .done
        case .failure: return .failed
        case nil:      return state.isRunning ? .working : .idle
        }
    }

    private var canCreate: Bool {
        !reference.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Idle

    @ViewBuilder
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Image")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            LocalImageReferenceField(reference: $reference, images: service.images, fieldIdentifier: "machineImageField")
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Name")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Optional — auto-generated if left blank", text: $name)
                .accessibilityIdentifier("machineNameField")
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
        }

        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CPUs")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("4", text: $cpus)
                    .accessibilityIdentifier("machineCpusField")
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Memory")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("8G", text: $memory)
                    .accessibilityIdentifier("machineMemoryField")
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
        }

        PlatformPicker(title: "Platform", selection: $platformChoice)

        Toggle("Boot immediately", isOn: $bootImmediately)
            .toggleStyle(.checkbox)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                showAdvanced.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("Advanced")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("machineAdvancedDisclosure")

            if showAdvanced {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Home directory mount")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Picker("Home directory mount", selection: $homeMountChoice) {
                            ForEach(HomeMountChoice.allCases, id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }

                    Toggle("Set as default machine", isOn: $setDefault)
                        .toggleStyle(.checkbox)

                    InsecureRegistryToggle(isOn: $insecureRegistry)
                }
                .padding(.top, 10)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }

    // MARK: - Active / done

    @ViewBuilder
    private var activeContent: some View {
        switch state.result {
        case .success(let ref):
            SheetStatusCallout(symbol: "checkmark.circle.fill", tint: .green, title: "Machine created", alignment: .center) {
                SheetCalloutDetail(text: ref)
            }

        case .failure(let msg):
            SheetCallout(tint: .red, padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.title3)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }

        case nil:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Creating…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Actions

    private func startSubmit() {
        guard canCreate, !state.isRunning else { return }
        let ref = reference.trimmingCharacters(in: .whitespaces)
        let nameTrimmed = name.trimmingCharacters(in: .whitespaces)
        let platform = platformChoice == .default ? nil : platformChoice.rawValue
        let cpusValue = Int(cpus.trimmingCharacters(in: .whitespaces))
        let memoryTrimmed = memory.trimmingCharacters(in: .whitespaces)
        let homeMount = homeMountChoice == .default ? nil : homeMountChoice.rawValue

        state.isRunning = true
        state.result = nil

        let options = MachineCreateOptions(
            reference: ref,
            name: nameTrimmed.isEmpty ? nil : nameTrimmed,
            platform: platform,
            cpus: cpusValue,
            memory: memoryTrimmed.isEmpty ? nil : memoryTrimmed,
            homeMount: homeMount,
            boot: bootImmediately,
            setDefault: setDefault,
            insecureRegistry: insecureRegistry
        )

        state.runTask = Task {
            do {
                try await service.createMachine(options: options)
                state.result = .success(reference: nameTrimmed.isEmpty ? ref : nameTrimmed)
            } catch is CancellationError {
                state.result = nil
            } catch {
                state.result = .failure(message: error.localizedDescription)
            }
            state.isRunning = false
            state.runTask = nil
        }
    }

    private func cancelRun() {
        state.runTask?.cancel()
        state.runTask = nil
        state.isRunning = false
        state.result = nil
    }
}

// MARK: - Preview

#Preview {
    MachineCreateSheet(service: MockContainerService())
}

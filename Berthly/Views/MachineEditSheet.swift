// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

/// Edit an existing machine's boot settings — `container machine set` as a form. Follows
/// MachineCreateSheet's flat layout (few fields, no sidebar). CPU/memory fields left blank keep
/// the current values (the service only sends what's filled in); the home-mount picker is
/// prefilled with the machine's current choice, so re-applying it is a harmless no-op.
struct MachineEditSheet: View {
    let machine: Machine
    let service: ContainerServiceBase

    @Environment(\.dismiss) private var dismiss

    @State private var cpus = ""
    @State private var memory = ""
    @State private var homeMountChoice: EditHomeMountChoice
    @State private var isApplying = false
    @State private var errorMessage: String?

    init(machine: Machine, service: ContainerServiceBase) {
        self.machine = machine
        self.service = service
        _homeMountChoice = State(initialValue: EditHomeMountChoice(machine.homeMount))
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: "slider.horizontal.3",
                title: "Edit \(machine.name)",
                subtitle: "Currently \(machine.resources)"
            )

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CPUs")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("Unchanged", text: $cpus)
                            .accessibilityIdentifier("machineEditCpusField")
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Memory")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("Unchanged", text: $memory)
                            .accessibilityIdentifier("machineEditMemoryField")
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                }

                HStack {
                    Text("Home directory mount")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("Home directory mount", selection: $homeMountChoice) {
                        ForEach(EditHomeMountChoice.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                Text(machine.status == .running
                     ? "\(machine.name) is running — changes take effect after you stop and start it."
                     : "Changes take effect the next time the machine boots.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .submitsOnReturn(when: canApply, action: apply)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if isApplying {
                    Button {} label: {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Applying…")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                } else {
                    Button("Apply") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canApply)
                        .keyboardShortcut(.return)
                        .accessibilityIdentifier("machineEditApplyButton")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 420)
        .errorAlert($errorMessage)
    }

    /// A non-numeric CPU entry would cost a round-trip to the daemon just to be rejected — catch
    /// it here. Blank fields are fine (they mean "keep current").
    private var canApply: Bool {
        let cpusTrimmed = cpus.trimmingCharacters(in: .whitespaces)
        return cpusTrimmed.isEmpty || Int(cpusTrimmed) != nil
    }

    private func apply() {
        guard canApply, !isApplying else { return }
        let options = MachineUpdateOptions(
            cpus: Int(cpus.trimmingCharacters(in: .whitespaces)),
            memory: memory.trimmingCharacters(in: .whitespaces),
            homeMount: homeMountChoice.rawValue
        )
        isApplying = true
        Task {
            do {
                try await service.updateMachine(machine.id, options: options)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isApplying = false
        }
    }
}

/// Home-mount options for editing. Unlike the create sheet there's no "Default" case — an
/// existing machine always has a concrete value, which the picker is prefilled with.
private enum EditHomeMountChoice: String, CaseIterable {
    case rw
    case ro
    case none

    init(_ mount: MachineHomeMount) {
        switch mount {
        case .readWrite: self = .rw
        case .readOnly:  self = .ro
        case .none:      self = .none
        }
    }

    var label: String {
        switch self {
        case .rw:   return "Read/write"
        case .ro:   return "Read-only"
        case .none: return "None"
        }
    }
}

// MARK: - Preview

#Preview {
    let mock = MockContainerService()
    return MachineEditSheet(machine: mock.machines[0], service: mock)
}

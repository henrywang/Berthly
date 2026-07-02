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
    var result: Result? = nil
    var runTask: Task<Void, Never>? = nil
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
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create machine")
                        .font(.headline)
                    Text("Provision a new container machine from an image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

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
            }
            .frame(maxHeight: 420)

            Divider()

            HStack {
                Spacer()
                switch state.result {
                case .success:
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                case .failure:
                    Button("Close") { dismiss() }
                        .buttonStyle(.bordered)
                case nil:
                    if state.isRunning {
                        Button("Cancel") { cancelRun() }
                        Button {} label: {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Creating…")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                    } else {
                        Button("Cancel") { dismiss() }
                        Button("Create") { startSubmit() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canCreate)
                            .keyboardShortcut(.return)
                            .accessibilityIdentifier("machineCreateSubmitButton")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
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
            TextField("local/myapp:1.0", text: $reference)
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
                .onSubmit { if canCreate { startSubmit() } }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Name")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Optional — auto-generated if left blank", text: $name)
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
        }

        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CPUs")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("e.g. 4", text: $cpus)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Memory")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("e.g. 8G", text: $memory)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
        }

        PlatformPicker(title: "Platform", selection: $platformChoice)

        Toggle("Boot immediately", isOn: $bootImmediately)
            .toggleStyle(.checkbox)

        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
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

                Toggle(isOn: $insecureRegistry) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow insecure registry")
                            .font(.caption.weight(.medium))
                        Text("Forces HTTP instead of HTTPS. Only use for private registries without TLS.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .padding(.top, 10)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }

    // MARK: - Active / done

    @ViewBuilder
    private var activeContent: some View {
        switch state.result {
        case .success(let ref):
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Machine created")
                        .font(.callout.weight(.semibold))
                    Text(ref)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.2), lineWidth: 0.5))

        case .failure(let msg):
            HStack(spacing: 12) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.2), lineWidth: 0.5))

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

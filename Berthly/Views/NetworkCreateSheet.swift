import SwiftUI

/// "Create network" form — the GUI equivalent of `container network create`: a NAT or host-only
/// network for containers, with an optional subnet.
struct NetworkCreateSheet: View {
    @Environment(ContainerServiceBase.self) private var service
    @Environment(\.dismiss) private var dismiss

    private enum Mode: Hashable { case nat, hostOnly }

    @State private var name = ""
    @State private var mode: Mode = .nat
    @State private var subnet = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        !isSubmitting && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create Network")
                        .font(.headline)
                    Text("A NAT or host-only network for containers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("my-network", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .fontDesign(.monospaced)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Mode")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("Mode", selection: $mode) {
                        Text("NAT").tag(Mode.nat)
                        Text("Host-only").tag(Mode.hostOnly)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Text(mode == .nat
                         ? "Containers reach the internet through the host (NAT)."
                         : "Isolated to the host — no outbound internet access.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Subnet")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("192.168.70.0/24", text: $subnet)
                        .textFieldStyle(.roundedBorder)
                        .fontDesign(.monospaced)
                        .frame(width: 220)
                    Text("Optional — the daemon auto-assigns one if left blank.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(4)
                }
            }
            .padding(20)
            // Catches Return from any text field above, not just the one it's typed in —
            // `.keyboardShortcut(.return)` on the Create button below only fires when no field
            // has focus, since a focused TextField's field editor swallows Return itself.
            .onSubmit { if canSubmit { submit() } }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if isSubmitting {
                    Button {} label: {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Creating…")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                } else {
                    Button("Create") { submit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmit)
                        .keyboardShortcut(.return)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 440)
    }

    private func submit() {
        guard canSubmit else { return }
        let trimmedSubnet = subnet.trimmingCharacters(in: .whitespaces)
        let options = NetworkCreateOptions(
            name: name.trimmingCharacters(in: .whitespaces),
            hostOnly: mode == .hostOnly,
            subnet: trimmedSubnet.isEmpty ? nil : trimmedSubnet
        )
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await service.createNetwork(options: options)
                isSubmitting = false
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}

#Preview {
    NetworkCreateSheet()
        .environment(MockContainerService() as ContainerServiceBase)
}

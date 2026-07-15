// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

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
            SheetHeader(
                systemImage: "arrow.triangle.branch",
                title: "Create Network",
                subtitle: "A NAT or host-only network for containers"
            )

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                SheetField("Name") {
                    TextField("my-network", text: $name)
                        .accessibilityIdentifier("networkNameField")
                        .textFieldStyle(.roundedBorder)
                        .fontDesign(.monospaced)
                }

                SheetField("Mode") {
                    Picker("Mode", selection: $mode) {
                        Text("NAT").tag(Mode.nat)
                        Text("Host-only").tag(Mode.hostOnly)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } footer: {
                    SheetFieldHint(mode == .nat
                        ? "Containers reach the internet through the host (NAT)."
                        : "Isolated to the host — no outbound internet access.")
                }

                SheetField("Subnet", hint: "Optional — the daemon auto-assigns one if left blank.") {
                    TextField("192.168.70.0/24", text: $subnet)
                        .textFieldStyle(.roundedBorder)
                        .fontDesign(.monospaced)
                        .frame(width: 220)
                }

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(4)
                }
            }
            .padding(20)
            .submitsOnReturn(when: canSubmit, action: submit)

            Divider()

            SheetSubmitFooter(
                phase: isSubmitting ? .working : .idle,
                submitLabel: "Create",
                busyLabel: "Creating…",
                canSubmit: canSubmit,
                submitIdentifier: "networkCreateSubmitButton",
                onSubmit: submit
            )
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

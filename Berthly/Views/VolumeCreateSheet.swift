import SwiftUI

/// "Create volume" form — the GUI equivalent of `container volume create`: a named volume on the
/// local driver, with an optional size cap.
struct VolumeCreateSheet: View {
    @Environment(ContainerServiceBase.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var size = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        !isSubmitting && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cylinder")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create volume")
                        .font(.headline)
                    Text("A named volume on the local driver")
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
                    TextField("my-volume", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .fontDesign(.monospaced)
                        .onSubmit { if canSubmit { submit() } }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Size")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("e.g. 10G", text: $size)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Text("Optional — leave blank for no size limit. Accepts K, M, G, T, P suffixes.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(4)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
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
        let trimmedSize = size.trimmingCharacters(in: .whitespaces)
        let options = VolumeCreateOptions(
            name: name.trimmingCharacters(in: .whitespaces),
            size: trimmedSize.isEmpty ? nil : trimmedSize
        )
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await service.createVolume(options: options)
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
    VolumeCreateSheet()
        .environment(MockContainerService() as ContainerServiceBase)
}

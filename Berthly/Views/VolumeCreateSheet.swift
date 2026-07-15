// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

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

    /// Inline size-validation message (min 1 MB / max ~16 TB / bad format), or `nil` when the
    /// size is acceptable — pre-empts the daemon's own rejection with friendlier text.
    private var sizeError: String? {
        LiveContainerService.validateVolumeSize(size)
    }

    private var canSubmit: Bool {
        !isSubmitting
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && sizeError == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: "cylinder",
                title: "Create Volume",
                subtitle: "A named volume on the local driver"
            )

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                SheetField("Name") {
                    TextField("my-volume", text: $name)
                        .accessibilityIdentifier("volumeNameField")
                        .textFieldStyle(.roundedBorder)
                        .fontDesign(.monospaced)
                }

                SheetField("Size") {
                    TextField("10G", text: $size)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .accessibilityIdentifier("volumeSizeField")
                } footer: {
                    if let sizeError {
                        Text(sizeError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else {
                        SheetFieldHint("Optional — blank uses the 512 GB default. Accepts K, M, G, T, P suffixes.")
                    }
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
                submitIdentifier: "volumeCreateSubmitButton",
                onSubmit: submit
            )
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

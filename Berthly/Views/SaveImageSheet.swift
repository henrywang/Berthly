// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Save Image Sheet

/// A confirmed request to export an image: destination already chosen via the save panel, so the
/// sheet's only job is progress/outcome. `Identifiable` for `.sheet(item:)`.
struct ImageSaveRequest: Identifiable {
    let id = UUID()
    let reference: String
    let destination: URL
}

/// Ask where to write the image archive. Returns `nil` if the user cancels. The panel owns
/// overwrite confirmation and the default filename comes from the reference
/// (`suggestedArchiveFilename`), so callers go straight from menu action to `ImageSaveRequest`.
@MainActor
func promptForArchiveDestination(imageName: String) -> URL? {
    // E2E-only bypass: NSSavePanel is system UI XCUITest can't drive, and a typed-path form in
    // front of it would trade away overwrite confirmation and .tar enforcement for no real user
    // benefit (unlike a container-side path, a save destination genuinely wants a picker). Same
    // seam pattern as UITEST_USE_MOCK_SERVICE — real users are never affected.
    if let path = ProcessInfo.processInfo.environment["UITEST_SAVE_DESTINATION"] {
        return URL(fileURLWithPath: path)
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedArchiveFilename(for: imageName)
    panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .archive]
    panel.canCreateDirectories = true
    panel.message = "Save \(imageName) as an OCI tar archive"
    return panel.runModal() == .OK ? panel.url : nil
}

/// Exports an image as an OCI tar archive (`container image save -o`). Starts working the moment
/// it appears — the destination was already chosen — and shows indeterminate progress: the
/// daemon's save API reports none.
struct SaveImageSheet: View {
    let request: ImageSaveRequest

    @Environment(ContainerServiceBase.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var isDone = false
    @State private var errorMessage: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: "square.and.arrow.down",
                title: "Save Image to Disk",
                subtitle: "Exports an OCI tar archive that container image load can import"
            )

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                SheetField("Image") {
                    SheetMonospacedValue(text: request.reference)
                }
                SheetField("Destination") {
                    SheetMonospacedValue(text: request.destination.path(percentEncoded: false))
                }

                if isDone {
                    SheetCallout(tint: .green, padding: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.title3)
                            Text("Image saved")
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([request.destination])
                            }
                        }
                    }
                } else if let error = errorMessage {
                    SheetStatusCallout(symbol: "xmark.octagon.fill", tint: .red, title: "Save failed") {
                        SheetCalloutDetail(text: error, monospaced: false, lineLimit: 4)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Writing archive…")
                            .font(.callout.weight(.semibold))
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }
            .padding(20)

            Divider()

            // done/error collapse to a prominent dismiss; while writing, offer only a best-effort
            // Cancel (the XPC save call doesn't observe cancellation, so this abandons the wait
            // rather than stopping the daemon-side write — the archive may still appear).
            SheetSubmitFooter(
                phase: (isDone || errorMessage != nil) ? .done : .working,
                submitLabel: "",
                doneLabel: isDone ? "Done" : "Close",
                showsBusyButton: false,
                onCancel: { saveTask?.cancel(); dismiss() }
            )
        }
        .frame(width: 480)
        .task { await performSave() }
    }

    private func performSave() async {
        let task = Task {
            do {
                try await service.saveImages(references: [request.reference], to: request.destination.path(percentEncoded: false))
                isDone = true
            } catch is CancellationError {
                // Sheet already dismissed.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        saveTask = task
        await task.value
        saveTask = nil
    }
}

#Preview {
    let mock = MockContainerService()
    return SaveImageSheet(request: ImageSaveRequest(
        reference: mock.images[0].fullName,
        destination: URL(fileURLWithPath: "/Users/dev/Downloads/web_1.4.tar")
    ))
    .environment(mock as ContainerServiceBase)
}

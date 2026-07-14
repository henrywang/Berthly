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
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save Image to Disk")
                        .font(.headline)
                    Text("Exports an OCI tar archive that container image load can import")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Image")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(request.reference)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Destination")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(request.destination.path(percentEncoded: false))
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                if isDone {
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
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.2), lineWidth: 0.5))
                } else if let error = errorMessage {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Save failed")
                                .font(.callout.weight(.semibold))
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.2), lineWidth: 0.5))
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

            HStack {
                Spacer()
                if isDone || errorMessage != nil {
                    Button(isDone ? "Done" : "Close") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                } else {
                    // Best-effort: the XPC save call doesn't observe cancellation, so this
                    // abandons the wait rather than stopping the daemon-side write — the archive
                    // may still appear. Matches the push sheet's cancel semantics.
                    Button("Cancel") { saveTask?.cancel(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
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

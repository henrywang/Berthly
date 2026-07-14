import SwiftUI
import UniformTypeIdentifiers

// MARK: - Load Image Sheet

/// A chosen archive to import. `Identifiable` for `.sheet(item:)` so picking the same file twice
/// re-presents a fresh sheet.
struct ImageLoadRequest: Identifiable {
    let id = UUID()
    let url: URL
}

/// Ask which archive to import. Returns `nil` if the user cancels.
@MainActor
func promptForArchiveToLoad() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .archive]
    panel.message = "Choose an OCI image tar archive"
    return panel.runModal() == .OK ? panel.url : nil
}

/// Imports images from an OCI tar archive (`container image load -i`). Starts on appear; the
/// load phase is silent (no daemon progress), then the unpack phase streams real byte/item
/// events into the shared transfer log. One archive can carry several images, so the done state
/// lists every loaded reference.
struct LoadImageSheet: View {
    let archiveURL: URL

    @Environment(ContainerServiceBase.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var summary: ImageLoadSummary?
    @State private var errorMessage: String?
    @State private var loadProgress = TransferProgressState.load()
    @State private var loadTask: Task<Void, Never>?

    private var isLoading: Bool { summary == nil && errorMessage == nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Load Image from Disk")
                        .font(.headline)
                    Text("Imports images from an OCI tar archive into the local store")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Archive")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(archiveURL.path(percentEncoded: false))
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                if isLoading {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Loading image")
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Text(loadProgress.percentText)
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        // No fraction until the unpack phase starts reporting; indeterminate
                        // covers the silent archive-read phase.
                        if let fraction = loadProgress.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                    }
                }

                logView

                if let summary {
                    doneContent(summary)
                }

                if let error = errorMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Load failed")
                                    .font(.callout.weight(.semibold))
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }
                        }
                        // The client rejects archives with invalid member paths outright unless
                        // asked to skip them — offer that retry here, when it's relevant, instead
                        // of a scary up-front checkbox.
                        Button("Load Anyway, Skipping Invalid Files") { startLoad(force: true) }
                            .buttonStyle(.link)
                            .font(.caption.weight(.medium))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.2), lineWidth: 0.5))
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                if summary != nil || errorMessage != nil {
                    Button(summary != nil ? "Done" : "Close") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                } else {
                    // Best-effort, like the save sheet: the XPC load/unpack calls don't observe
                    // cancellation, so this abandons the wait; the image may still land.
                    Button("Cancel") { loadTask?.cancel(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480)
        .onAppear { startLoad(force: false) }
    }

    @ViewBuilder
    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(loadProgress.logLines) { line in
                        HStack(alignment: .top, spacing: 12) {
                            Text(line.tag)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 36, alignment: .leading)
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.tag == "DONE" ? Color.green : Color.primary)
                        }
                        .id(line.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 130)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
            .onChange(of: loadProgress.logLines.count) { _, _ in
                if let last = loadProgress.logLines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func doneContent(_ summary: ImageLoadSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.loadedReferences.count == 1 ? "Image loaded" : "\(summary.loadedReferences.count) images loaded")
                    .font(.callout.weight(.semibold))
                ForEach(summary.loadedReferences, id: \.self) { reference in
                    Text(reference)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.2), lineWidth: 0.5))

        if !summary.rejectedMembers.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.statusPaused)
                    .imageScale(.small)
                    .padding(.top, 1)
                Text("Skipped \(summary.rejectedMembers.count) invalid archive member\(summary.rejectedMembers.count == 1 ? "" : "s") (unsafe paths).")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.statusPaused.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.statusPaused.opacity(0.2), lineWidth: 0.5))
        }
    }

    private func startLoad(force: Bool) {
        guard loadTask == nil else { return }
        errorMessage = nil
        summary = nil
        loadProgress.start(reference: archiveURL.lastPathComponent)
        loadTask = Task {
            do {
                let result = try await service.loadImages(
                    from: archiveURL.path(percentEncoded: false),
                    force: force,
                    progress: loadProgress.handler
                )
                for reference in result.loadedReferences {
                    loadProgress.markDone(reference: reference)
                }
                summary = result
            } catch is CancellationError {
                // Sheet already dismissed.
            } catch {
                errorMessage = error.localizedDescription
            }
            loadTask = nil
        }
    }
}

#Preview {
    let mock = MockContainerService()
    return LoadImageSheet(archiveURL: URL(fileURLWithPath: "/Users/dev/Downloads/alpine_latest.tar"))
        .environment(mock as ContainerServiceBase)
}

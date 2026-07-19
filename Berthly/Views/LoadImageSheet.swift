// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

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
    // E2E-only bypass — see the matching comment on promptForArchiveDestination.
    if let path = ProcessInfo.processInfo.environment["UITEST_LOAD_SOURCE"] {
        return URL(fileURLWithPath: path)
    }
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
            SheetHeader(
                systemImage: "square.and.arrow.down.on.square",
                title: "Load Image from Disk",
                subtitle: "Imports images from an OCI tar archive into the local store"
            )

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                SheetField("Archive") {
                    SheetMonospacedValue(text: archiveURL.path(percentEncoded: false))
                }

                if isLoading {
                    // No fraction until the unpack phase starts reporting; indeterminate covers
                    // the silent archive-read phase.
                    TransferProgressHeader(title: "Loading image", progress: loadProgress)
                }

                TransferLogView(lines: loadProgress.logLines)

                if let summary {
                    doneContent(summary)
                }

                if let error = errorMessage {
                    SheetStatusCallout(symbol: "xmark.octagon.fill", tint: .red, title: "Load failed") {
                        VStack(alignment: .leading, spacing: 10) {
                            SheetCalloutDetail(text: error, monospaced: false, lineLimit: 4)
                            // The client rejects archives with invalid member paths outright
                            // unless asked to skip them — offer that retry here, when it's
                            // relevant, instead of a scary up-front checkbox.
                            Button("Load Anyway, Skipping Invalid Files") { startLoad(force: true) }
                                .buttonStyle(.link)
                                .font(.caption.weight(.medium))
                        }
                    }
                }
            }
            .padding(20)

            Divider()

            // done/error collapse to a single prominent dismiss button; loading offers only a
            // best-effort Cancel (the XPC load/unpack calls don't observe cancellation, so this
            // abandons the wait — the image may still land), so no disabled spinner button.
            SheetSubmitFooter(
                phase: (summary != nil || errorMessage != nil) ? .done : .working,
                submitLabel: "",
                doneLabel: summary != nil ? "Done" : "Close",
                showsBusyButton: false,
                onCancel: { loadTask?.cancel(); dismiss() }
            )
        }
        .frame(width: 480)
        .onAppear { startLoad(force: false) }
    }

    @ViewBuilder
    private func doneContent(_ summary: ImageLoadSummary) -> some View {
        SheetStatusCallout(
            symbol: "checkmark.circle.fill",
            tint: .green,
            title: summary.loadedReferences.count == 1 ? "Image loaded" : "\(summary.loadedReferences.count) images loaded"
        ) {
            ForEach(summary.loadedReferences, id: \.self) { reference in
                SheetCalloutDetail(text: reference, selectable: true)
            }
        }

        if !summary.rejectedMembers.isEmpty {
            SheetCallout(tint: .statusPaused) {
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
            }
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

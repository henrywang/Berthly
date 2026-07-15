// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

// MARK: - BuildsPopover

/// Toolbar popover listing background builds — running ones with a spinner, finished ones
/// with their outcome. Rows open the full log in the build sheet via `onViewJob`.
///
/// Receives `manager` explicitly instead of via `@Environment`: this view is hosted inside
/// `PopoverAnchor`'s `NSHostingController`, which doesn't inherit the SwiftUI environment.
struct BuildsPopover: View {
    let manager: BuildJobManager
    let onViewJob: (BuildJob) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Builds")
                    .font(.headline)
                Spacer()
                if manager.jobs.contains(where: \.isFinished) {
                    Button("Clear Finished") { manager.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if manager.jobs.isEmpty {
                Text("No builds")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(manager.jobs) { job in
                            BuildJobRow(
                                job: job,
                                onView: { onViewJob(job) },
                                onCancel: { manager.cancel(job) },
                                onRemove: { manager.remove(job) }
                            )
                            if job.id != manager.jobs.last?.id {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 340)
        .onAppear { manager.markFinishedSeen() }
    }
}

// MARK: - Row

private struct BuildJobRow: View {
    let job: BuildJob
    let onView: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onView) {
            HStack(spacing: 10) {
                statusIcon
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.reference)
                        .font(.callout)
                        .fontDesign(.monospaced)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if job.isFinished {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from list")
                    .accessibilityLabel("Remove from list")
                    .opacity(isHovering ? 1 : 0)
                } else {
                    Button(action: onCancel) {
                        Image(systemName: "stop.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel build")
                }

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovering ? Color.primary.opacity(0.05) : .clear)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .building:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch job.status {
        case .building:
            return "Building…"
        case .succeeded:
            return "Succeeded in \(formatBuildDuration(job.duration))"
        case .failed:
            return "Failed after \(formatBuildDuration(job.duration))"
        }
    }
}

// MARK: - Toolbar label

/// Label for the toolbar builds indicator. Status-shaped, never action-shaped: the toolbar
/// already has a hammer on the Build button, so this must not show a second hammer — a
/// spinner while building, a green check / red cross for unseen results, and a history
/// icon once everything's been seen.
struct BuildsToolbarLabel: View {
    let isBuilding: Bool
    let unseenFinishedCount: Int
    let hasUnseenFailure: Bool

    init(manager: BuildJobManager) {
        isBuilding = manager.isBuilding
        unseenFinishedCount = manager.unseenFinishedCount
        hasUnseenFailure = manager.hasUnseenFailure
    }

    init(isBuilding: Bool, unseenFinishedCount: Int, hasUnseenFailure: Bool) {
        self.isBuilding = isBuilding
        self.unseenFinishedCount = unseenFinishedCount
        self.hasUnseenFailure = hasUnseenFailure
    }

    /// The icon already tells the story of a single result; the numeric badge only earns
    /// its place when it adds information — several results, or results stacking up
    /// behind a still-running build's spinner.
    private var showsCountBadge: Bool {
        unseenFinishedCount > 1 || (isBuilding && unseenFinishedCount > 0)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if isBuilding {
                    ProgressView()
                        .controlSize(.small)
                } else if hasUnseenFailure {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                } else if unseenFinishedCount > 0 {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
            .frame(width: 22, height: 18)

            if showsCountBadge {
                Text("\(unseenFinishedCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(hasUnseenFailure ? Color.red : Color.green, in: Capsule())
                    .offset(x: 8, y: -6)
            }
        }
    }
}

// MARK: - Previews

#Preview("Toolbar label states") {
    HStack(spacing: 24) {
        BuildsToolbarLabel(isBuilding: true, unseenFinishedCount: 0, hasUnseenFailure: false)
        BuildsToolbarLabel(isBuilding: true, unseenFinishedCount: 2, hasUnseenFailure: false)
        BuildsToolbarLabel(isBuilding: false, unseenFinishedCount: 1, hasUnseenFailure: false)
        BuildsToolbarLabel(isBuilding: false, unseenFinishedCount: 3, hasUnseenFailure: true)
        BuildsToolbarLabel(isBuilding: false, unseenFinishedCount: 0, hasUnseenFailure: false)
    }
    .padding(24)
}

#Preview("Builds popover") {
    let manager = BuildJobManager()
    let service = MockContainerService()
    manager.start(options: BuildOptions(reference: "local/web:1.4", contextPath: "/Users/dev/projects/web"), service: service)
    return BuildsPopover(manager: manager, onViewJob: { _ in })
}

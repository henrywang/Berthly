// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

// MARK: - Commit Container Sheet

/// Snapshots a container's filesystem into a new local image (`container commit`, container
/// 1.6.0). Shows the created reference like TagImageSheet, since normalization can change it.
struct CommitContainerSheet: View {
    let container: Container

    @Environment(ContainerServiceBase.self) private var service

    @State private var target: String
    @State private var isCommitting = false
    @State private var createdReference: String?
    @State private var errorMessage: String?

    init(container: Container) {
        self.container = container
        _target = State(initialValue: "\(container.name.lowercased()):snapshot")
    }

    /// Commit works on a running or stopped container, the states `export` accepts.
    static func canCommit(_ container: Container) -> Bool {
        switch container.status {
        case .running, .stopped: true
        case .error, .paused: false
        }
    }

    private var trimmedTarget: String { target.trimmingCharacters(in: .whitespaces) }
    private var issue: TagTargetIssue? {
        tagTargetIssue(trimmedTarget, existingReferences: service.images.map(\.fullName))
    }
    private var canSubmit: Bool {
        if trimmedTarget.isEmpty || isCommitting { return false }
        if case .invalid = issue { return false }
        return true
    }

    /// A failure stays `.idle` (like TagImageSheet) so the reference can be edited and retried.
    private var phase: SheetSubmitFooter.Phase {
        if createdReference != nil { return .done }
        return isCommitting ? .working : .idle
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: "square.and.arrow.down.on.square",
                title: "Commit to Image",
                subtitle: "Creates a local image from this container's filesystem"
            )

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                if let createdReference {
                    SheetStatusCallout(symbol: "checkmark.circle.fill", tint: .green, title: "Image created", alignment: .center) {
                        SheetCalloutDetail(text: createdReference, selectable: true)
                    }
                } else {
                    idleContent
                }
                if let error = errorMessage {
                    SheetStatusCallout(symbol: "xmark.octagon.fill", tint: .red, title: "Commit failed") {
                        SheetCalloutDetail(text: error, monospaced: false, lineLimit: 4)
                    }
                }
            }
            .padding(20)

            Divider()

            SheetSubmitFooter(
                phase: phase,
                submitLabel: "Commit",
                busyLabel: "Committing…",
                canSubmit: canSubmit,
                submitIdentifier: "commitSubmitButton",
                // Export and load run daemon-side; dismissing mid-way would leave the image to
                // appear later with no feedback.
                workingCancelDisabledHelp: "A commit can't be cancelled once it starts",
                onSubmit: startCommit
            )
        }
        .frame(width: 480)
    }

    @ViewBuilder
    private var idleContent: some View {
        SheetField("Container") {
            SheetMonospacedValue(text: container.name)
        }

        SheetField("Image reference") {
            TextField("team/web:snapshot", text: $target)
                .accessibilityIdentifier("commitTargetField")
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
                .disabled(isCommitting)
                .onSubmit { startCommit() }
        }

        switch issue {
        case .invalid(let why):
            issueHint(why, color: .red, symbol: "xmark.octagon.fill")
        case .replacesExisting:
            issueHint("An image with this name already exists — committing will replace that name.",
                      color: Color.statusPaused, symbol: "exclamationmark.triangle.fill")
        case nil:
            Text("Captures the filesystem and the command the container runs. Volumes and mounts aren't included.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func issueHint(_ text: String, color: Color, symbol: String) -> some View {
        SheetCallout(tint: color) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .imageScale(.small)
                    .padding(.top, 1)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("commitTargetIssue")
    }

    private func startCommit() {
        guard canSubmit else { return }
        isCommitting = true
        errorMessage = nil
        Task {
            do {
                createdReference = try await service.commitContainer(container.id, reference: trimmedTarget)
            } catch {
                errorMessage = error.localizedDescription
            }
            isCommitting = false
        }
    }
}

#Preview {
    let mock = MockContainerService()
    return CommitContainerSheet(container: mock.containers[0])
        .environment(mock as ContainerServiceBase)
}

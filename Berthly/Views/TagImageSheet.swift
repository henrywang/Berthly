// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

// MARK: - Tag Image Sheet

/// Creates an additional local reference for an image (`container image tag`). Tagging is
/// instant — no progress phase — but the sheet still shows a done state rather than silently
/// dismissing, because normalization can create a different name than the user typed
/// (`web:2.0` → `docker.io/library/web:2.0`) and that shouldn't be a surprise found later
/// in the list.
struct TagImageSheet: View {
    let image: ContainerImage

    @Environment(ContainerServiceBase.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var target: String
    @State private var isTagging = false
    @State private var createdReference: String?
    @State private var errorMessage: String?

    init(image: ContainerImage) {
        self.image = image
        _target = State(initialValue: image.fullName)
    }

    private var trimmedTarget: String { target.trimmingCharacters(in: .whitespaces) }
    private var issue: TagTargetIssue? {
        tagTargetIssue(trimmedTarget, existingReferences: service.images.map(\.fullName))
    }
    /// The prefilled target *is* the source — a no-op, disabled without a warning banner.
    private var isUnchanged: Bool { trimmedTarget == image.fullName }
    private var canTag: Bool {
        if trimmedTarget.isEmpty || isUnchanged || isTagging { return false }
        if case .invalid = issue { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: "tag",
                title: "Tag Image",
                subtitle: "Creates an additional name for this image"
            )

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                if let createdReference {
                    doneContent(createdReference)
                } else {
                    idleContent
                }
                if let error = errorMessage {
                    SheetStatusCallout(symbol: "xmark.octagon.fill", tint: .red, title: "Tag failed") {
                        SheetCalloutDetail(text: error, monospaced: false, lineLimit: 4)
                    }
                }
            }
            .padding(20)

            Divider()

            SheetSubmitFooter(
                phase: createdReference != nil ? .done : .idle,
                submitLabel: "Tag",
                canSubmit: canTag,
                submitIdentifier: "tagSubmitButton",
                onSubmit: startTag
            )
        }
        .frame(width: 480)
    }

    @ViewBuilder
    private var idleContent: some View {
        SheetField("Source") {
            SheetMonospacedValue(text: image.fullName)
        }

        SheetField("New reference") {
            TextField("team/web:2.0", text: $target)
                .accessibilityIdentifier("tagTargetField")
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
                .onSubmit { startTag() }
        }

        // The unchanged prefill is a disabled no-op, not a "replaces existing" situation — no
        // banner to read before the user has typed anything.
        if !isUnchanged {
            switch issue {
            case .invalid(let why):
                issueHint(why, color: .red, symbol: "xmark.octagon.fill")
            case .replacesExisting:
                issueHint("An image with this name already exists — tagging will replace that name (its content stays until unused).",
                          color: Color.statusPaused, symbol: "exclamationmark.triangle.fill")
            case nil:
                EmptyView()
            }
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
    }

    private func doneContent(_ reference: String) -> some View {
        SheetStatusCallout(symbol: "checkmark.circle.fill", tint: .green, title: "Image tagged", alignment: .center) {
            SheetCalloutDetail(text: reference, selectable: true)
        }
    }

    private func startTag() {
        guard canTag else { return }
        isTagging = true
        errorMessage = nil
        Task {
            do {
                createdReference = try await service.tagImage(reference: image.fullName, newReference: trimmedTarget)
            } catch {
                errorMessage = error.localizedDescription
            }
            isTagging = false
        }
    }
}

#Preview {
    let mock = MockContainerService()
    return TagImageSheet(image: mock.images[0])
        .environment(mock as ContainerServiceBase)
}

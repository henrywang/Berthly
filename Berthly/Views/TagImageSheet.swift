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
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "tag")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tag Image")
                        .font(.headline)
                    Text("Creates an additional name for this image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                if let createdReference {
                    doneContent(createdReference)
                } else {
                    idleContent
                }
                if let error = errorMessage {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tag failed")
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
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                if createdReference != nil {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Tag") { startTag() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canTag)
                        .keyboardShortcut(.return)
                        .accessibilityIdentifier("tagSubmitButton")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480)
    }

    @ViewBuilder
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(image.fullName)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("New reference")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.2), lineWidth: 0.5))
    }

    private func doneContent(_ reference: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Image tagged")
                    .font(.callout.weight(.semibold))
                Text(reference)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.2), lineWidth: 0.5))
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

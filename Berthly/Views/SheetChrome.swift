// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

// The shared visual language of Berthly's form sheets (create/pull/push/tag/save/load…):
// header row, labeled fields, tinted callout boxes, and the Cancel/submit footer. Sheets
// compose these so a new sheet looks right by construction instead of by copy-paste.

// MARK: - Header

/// Icon + title + subtitle row at the top of a sheet, above the first divider.
struct SheetHeader: View {
    let systemImage: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }
}

// MARK: - Labeled fields

/// The caption-weight label above a sheet form control.
struct SheetFieldLabel: View {
    private let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

/// A hint line under a field's control — the styling `SheetField(_:hint:content:)` applies.
struct SheetFieldHint: View {
    private let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

/// Label-above-control form unit. `footer` renders under the control — a static hint via the
/// `hint:` convenience, or a custom builder for dynamic hints and inline validation errors.
struct SheetField<Content: View, Footer: View>: View {
    private let label: LocalizedStringKey
    private let content: () -> Content
    private let footer: () -> Footer

    init(
        _ label: LocalizedStringKey,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.label = label
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SheetFieldLabel(label)
            content()
            footer()
        }
    }
}

extension SheetField where Footer == EmptyView {
    init(_ label: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.init(label, content: content, footer: { EmptyView() })
    }
}

extension SheetField where Footer == SheetFieldHint {
    init(_ label: LocalizedStringKey, hint: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.init(label, content: content, footer: { SheetFieldHint(hint) })
    }
}

/// Read-only monospaced value row (an image reference or file path shown, not edited).
struct SheetMonospacedValue: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

// MARK: - Callout boxes

/// Rounded, tinted panel: hints, warnings, and result summaries all share this chrome.
struct SheetCallout<Content: View>: View {
    var tint: Color
    var padding: CGFloat = 12
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.2), lineWidth: 0.5))
    }
}

/// Outcome summary in a callout: status icon, semibold title, and detail lines
/// ("Image pulled" + reference, "Push failed" + error). Single-line success boxes center the
/// icon; multi-line/error boxes top-align it — the default follows the more common error case.
struct SheetStatusCallout<Detail: View>: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    var alignment: VerticalAlignment = .top
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        SheetCallout(tint: tint, padding: 14) {
            HStack(alignment: alignment, spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    detail()
                }
            }
        }
    }
}

/// Detail line under a `SheetStatusCallout` title: monospaced for references/paths,
/// proportional (with a line limit) for error text.
struct SheetCalloutDetail: View {
    let text: String
    var monospaced: Bool = true
    var selectable: Bool = false
    var lineLimit: Int? = nil

    var body: some View {
        let base = Text(text)
            .font(.caption)
            .fontDesign(monospaced ? .monospaced : .default)
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
        if selectable {
            base.textSelection(.enabled)
        } else {
            base
        }
    }
}

// MARK: - Footer

/// The Cancel/submit row under a sheet's last divider, driven by the sheet's phase:
/// idle shows Cancel + the primary action, working swaps in a disabled spinner button
/// (and routes Cancel to `onCancel` when the work is cancelable), done/failed collapse
/// to a single dismiss button — prominent for success, plain for failure.
struct SheetSubmitFooter: View {
    enum Phase {
        case idle
        case working
        case done
        case failed
    }

    var phase: Phase
    var submitLabel: LocalizedStringKey
    var busyLabel: LocalizedStringKey = "Working…"
    var doneLabel: LocalizedStringKey = "Done"
    var canSubmit: Bool = true
    /// Accessibility identifier for the idle submit button (UI/E2E tests drive it).
    var submitIdentifier: String? = nil
    /// Hide the disabled spinner button for work that only offers Cancel (save/load).
    var showsBusyButton: Bool = true
    /// Working-phase Cancel action; `nil` keeps the idle behavior of dismissing the sheet.
    var onCancel: (() -> Void)? = nil
    var onSubmit: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Spacer()
            switch phase {
            case .done:
                Button(doneLabel) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            case .failed:
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
            case .working:
                Button("Cancel") { (onCancel ?? { dismiss() })() }
                    .keyboardShortcut(.cancelAction)
                if showsBusyButton {
                    Button {} label: {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(busyLabel)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                }
            case .idle:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(submitLabel) { onSubmit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                    .keyboardShortcut(.return)
                    .accessibilityIdentifier(submitIdentifier ?? "")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - Shared option controls

/// The "Allow insecure registry" checkbox with its warning subtext — identical wherever a
/// sheet talks to a registry (pull, push, machine create, run).
struct InsecureRegistryToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow insecure registry")
                    .font(.caption.weight(.medium))
                Text("Forces HTTP instead of HTTPS. Only use for private registries without TLS.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .toggleStyle(.checkbox)
    }
}

/// Collapsed-by-default "Advanced" options group used by the pull/push sheets.
struct SheetAdvancedSection<Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.top, 10)
        } label: {
            SheetFieldLabel("Advanced")
        }
    }
}

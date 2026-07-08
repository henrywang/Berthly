import SwiftUI

/// The chooser that opens from the toolbar's Run button — replaces a plain text menu since
/// Container and Machine are different-enough flows (30 vs 6 fields, see RunContainerSheet/
/// MachineCreateSheet) to deserve more than a text-only menu item. Shared by both the popover
/// (PopoverAnchor, the primary presentation) and this sheet wrapper (kept as a fallback path).
struct RunTypeMenuContent: View {
    let onSelectContainer: () -> Void
    let onSelectMachine: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            RunTypeOption(
                icon: "shippingbox.fill",
                iconColor: .berthlyAccent,
                title: "Run Container",
                subtitle: "Start a new container from an image",
                shortcut: "⇧⌘R",
                action: onSelectContainer
            )
            RunTypeOption(
                icon: "desktopcomputer",
                iconColor: .statusRunning,
                title: "Create Machine",
                subtitle: "Provision a full Linux VM",
                shortcut: nil,
                action: onSelectMachine
            )
        }
        .padding(6)
        .frame(width: 320)
    }
}

private struct RunTypeOption: View {
    let icon: String
    let iconColor: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let shortcut: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(iconColor.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(iconColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }
}

/// Sheet wrapper around `RunTypeMenuContent` — fallback presentation if the NSPopover bridge
/// (PopoverAnchor) ever needs to be retired.
struct RunTypeChooserSheet: View {
    let onSelectContainer: () -> Void
    let onSelectMachine: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What do you want to run?")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            RunTypeMenuContent(onSelectContainer: onSelectContainer, onSelectMachine: onSelectMachine)
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
        }
        .frame(width: 340)
    }
}

#Preview {
    RunTypeChooserSheet(onSelectContainer: {}, onSelectMachine: {})
}

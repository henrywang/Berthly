import SwiftUI

/// Button style for icon-only row actions (delete, run, etc.) that only become
/// visible when the row itself is hovered. Without this, the icon has no
/// affordance of its own once revealed — `.borderless` gives no hover feedback
/// on macOS, so there's nothing to tell the user the icon under their cursor is
/// clickable versus just decorative.
struct HoverIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverIconLabel(configuration: configuration)
    }

    private struct HoverIconLabel: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(5)
                .background(isHovered ? Color.secondary.opacity(0.15) : .clear, in: Circle())
                .opacity(configuration.isPressed ? 0.6 : 1)
                .onHover { isHovered = $0 }
        }
    }
}

extension ButtonStyle where Self == HoverIconButtonStyle {
    static var hoverIcon: HoverIconButtonStyle { HoverIconButtonStyle() }
}

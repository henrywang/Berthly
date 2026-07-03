import SwiftUI

/// Adds a subtle grow-on-hover cue to system-styled buttons (`.bordered`,
/// `.borderedProminent`) whose native macOS hover feedback is too faint to
/// register as "this is clickable" — small icon-only buttons especially.
/// Unlike swapping in a custom `ButtonStyle`, this preserves the system
/// chrome, tinting, and dark/light adaptation exactly as-is.
private struct HoverScaleModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

extension View {
    func hoverScale() -> some View {
        modifier(HoverScaleModifier())
    }
}

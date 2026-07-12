import SwiftUI

/// The shape-coded lifecycle-status indicator badged onto a compute row's type glyph (and onto
/// the menu-bar type tile). Split out so both surfaces render the badge identically.
///
/// Status is carried by the SHAPE, not just the color (running `circle.fill`, stopped `circle`,
/// error `triangle.fill`, paused `pause.fill`) so colorblind users can still tell states apart —
/// see `ContainerStatus.systemImage`. (Distinct from `StatusBadge`, the text+icon capsule pill
/// on the detail headers.)
struct StatusShapeBadge: View {
    let status: ContainerStatus
    var size: CGFloat = 7
    /// Backs the shape with a window-background circle so it reads against whatever's behind it —
    /// the accent fill of the menu-bar tile. A selectable list row highlights on selection, where
    /// that chip renders window background *over* the accent (a visible hole punched through the
    /// highlight), so the sidebar glyph passes `chipped: false` and lets the shape read on its own.
    var chipped: Bool = true

    var body: some View {
        Image(systemName: status.systemImage)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(status.color)
            .padding(chipped ? 2.5 : 0)
            .background { if chipped { Circle().fill(.background) } }
    }
}

/// Type glyph (container/machine) with the lifecycle-status shape badged on its bottom-trailing
/// corner. Folding type + status into one leading icon lets a mixed container/machine list
/// identify each row's kind and state inline, without a `CONTAINERS`/`MACHINES` sub-header to say
/// so.
///
/// Shares the badge (`StatusBadge`) with the menu-bar type tile so both surfaces speak the same
/// "box = container, monitor = machine, corner = state" language. Unlike the tile this is a bare
/// glyph — no accent-tinted rounded backing — because a source list repeats it twenty times where
/// stacked tiles read as a button grid and the tint fights the sidebar material and the selection
/// highlight; the tile's backing only works in the popover, which has neither.
struct TypeStatusGlyph: View {
    /// Type symbol: `shippingbox` (container) or `desktopcomputer` (machine).
    let typeSystemImage: String
    let status: ContainerStatus
    var glyphSize: CGFloat = 13
    var badgeSize: CGFloat = 7
    /// Stopped rows recede: the type glyph drops from accent to secondary so the STOPPED block
    /// sinks into the background. The status badge stays full-strength regardless — a crashed
    /// (error) or paused row lives under STOPPED too, and its red triangle / amber bars are
    /// exactly what the eye must still catch through the recession.
    var dimmed: Bool = false

    var body: some View {
        Image(systemName: typeSystemImage)
            .font(.system(size: glyphSize))
            .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.berthlyAccent))
            .overlay(alignment: .bottomTrailing) {
                // Unchipped and nudged clear of the glyph's corner (rather than sitting on a
                // background chip over it) so it never punches a hole through a selected row.
                StatusShapeBadge(status: status, size: badgeSize, chipped: false)
                    .offset(x: badgeSize * 0.55, y: badgeSize * 0.35)
            }
            .accessibilityElement()
            .accessibilityLabel("\(typeLabel), \(status.label)")
    }

    // Only two symbols ever reach here; deriving the label keeps callers from repeating it.
    private var typeLabel: String {
        typeSystemImage == "desktopcomputer" ? "Machine" : "Container"
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        ForEach([ContainerStatus.running, .stopped, .error, .paused], id: \.self) { status in
            HStack(spacing: 24) {
                TypeStatusGlyph(typeSystemImage: "shippingbox", status: status)
                TypeStatusGlyph(typeSystemImage: "desktopcomputer", status: status)
                Text(status.label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    .padding(40)
}

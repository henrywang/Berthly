import SwiftUI

/// Title-above-content wrapper for a detail-pane section. `.caption2`/`.tertiary`/`.semibold`
/// title matches the section-header convention used across the app's other detail panes
/// (Image/Machine/Compute detail views).
struct DetailSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }
}

/// Shared key/value row list: one row per pair, secondary label, `.body` value, a `Divider`
/// between rows — no outer card chrome, so it can be dropped into a card that already has its
/// own header row and border. Row rhythm (label width, divider, padding) matches the
/// "Inspect"-style sections used across Image/Machine detail panes, but at `.body` rather than
/// their `.callout` — these values are primary content here, not secondary/expandable detail.
/// Long values (paths, image refs, URLs) are common on the System page, so this truncates the
/// middle rather than wrapping to 3 lines.
struct KeyValueRows: View {
    let rows: [(String, String)]
    var monoKeys: Set<String> = []
    var labelWidth: CGFloat = 110

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, pair in
                HStack(alignment: .top, spacing: 0) {
                    Text(pair.0)
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .leading)
                    Text(pair.1)
                        .fontDesign(monoKeys.contains(pair.0) ? .monospaced : .default)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .font(.body)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                if idx < rows.count - 1 {
                    Divider().padding(.horizontal, 16)
                }
            }
        }
    }
}

// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

struct TintedChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct InspectTable: View {
    let rows: [(String, String)]
    let monospacedKeys: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("INSPECT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 0) {
                        Text(row.0)
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .leading)
                        Text(row.1)
                            .fontDesign(monospacedKeys.contains(row.0) ? .monospaced : .default)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .font(.callout)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)

                    if index < rows.count - 1 {
                        Divider().padding(.horizontal, 16)
                    }
                }
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        }
    }
}

struct TerminalUnavailableView: View {
    let message: LocalizedStringKey

    var body: some View {
        ZStack {
            Color.codeBackground
            VStack(spacing: 14) {
                Image(systemName: "terminal")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.codePrompt)
                Text("Terminal")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

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

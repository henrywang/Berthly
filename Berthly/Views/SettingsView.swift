import SwiftUI

/// Berthly's macOS Settings scene (⌘,). Single pane for now — add a `TabView` if a
/// second settings group ever shows up.
struct SettingsView: View {
    @AppStorage("terminalTheme") private var themeRaw = TerminalTheme.dracula.rawValue

    private var selectedTheme: TerminalTheme { TerminalTheme(rawValue: themeRaw) ?? .dracula }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(TerminalTheme.allCases) { theme in
                        ThemeRow(theme: theme, isSelected: theme == selectedTheme) {
                            themeRaw = theme.rawValue
                        }
                    }
                }
            } header: {
                Text("Terminal Theme")
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Shows the theme's own ANSI swatches (not a generic accent color) so the choice is
/// legible before committing — a collapsed `Picker(.menu)` would hide exactly that.
private struct ThemeRow: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    ForEach(Array(theme.colors.ansi.prefix(8).enumerated()), id: \.offset) { _, hex in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(hex: hex))
                            .frame(width: 14, height: 14)
                    }
                }
                Text(theme.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.berthlyAccent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.berthlyAccent.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SettingsView()
}

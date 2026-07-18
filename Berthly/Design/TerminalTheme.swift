// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftTerm
import SwiftUI

/// A terminal's full color set: base background/foreground/cursor/selection plus the
/// standard 16-value ANSI palette. All dark-only — see `TerminalTheme` for why.
struct TerminalColorSet: Equatable {
    let background: String
    let foreground: String
    let cursor: String
    let selection: String
    /// Exactly 16 hex strings (ANSI 0-15) — `TerminalView.installColors` silently
    /// no-ops if this isn't 16 long.
    let ansi: [String]
}

/// Popular terminal color schemes. Dark-only by design: two of these four
/// (Dracula, One Dark) have no authentic published light variant, and Berthly's
/// other code surfaces (Logs/Stats) already hardcode a dark background regardless
/// of system appearance, so the terminal follows the same convention.
enum TerminalTheme: String, CaseIterable, Identifiable {
    case dracula, solarizedDark, nord, oneDark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dracula: "Dracula"
        case .solarizedDark: "Solarized Dark"
        case .nord: "Nord"
        case .oneDark: "One Dark"
        }
    }

    var colors: TerminalColorSet {
        switch self {
        case .dracula: .dracula
        case .solarizedDark: .solarizedDark
        case .nord: .nord
        case .oneDark: .oneDark
        }
    }
}

extension TerminalColorSet {
    static let dracula = TerminalColorSet(
        background: "282A36", foreground: "F8F8F2", cursor: "F8F8F2", selection: "44475A",
        ansi: [
            "21222C", "FF5555", "50FA7B", "F1FA8C", "BD93F9", "FF79C6", "8BE9FD", "F8F8F2",
            "6272A4", "FF6E6E", "69FF94", "FFFFA5", "D6ACFF", "FF92DF", "A4FFFF", "FFFFFF"
        ])

    static let solarizedDark = TerminalColorSet(
        background: "002B36", foreground: "839496", cursor: "93A1A1", selection: "073642",
        ansi: [
            "073642", "DC322F", "859900", "B58900", "268BD2", "D33682", "2AA198", "EEE8D5",
            "002B36", "CB4B16", "586E75", "657B83", "839496", "6C71C4", "93A1A1", "FDF6E3"
        ])

    static let nord = TerminalColorSet(
        background: "2E3440", foreground: "D8DEE9", cursor: "D8DEE9", selection: "434C5E",
        ansi: [
            "3B4252", "BF616A", "A3BE8C", "EBCB8B", "81A1C1", "B48EAD", "88C0D0", "E5E9F0",
            "4C566A", "BF616A", "A3BE8C", "EBCB8B", "81A1C1", "B48EAD", "88C0D0", "ECEFF4"
        ])

    static let oneDark = TerminalColorSet(
        background: "282C34", foreground: "ABB2BF", cursor: "528BFF", selection: "3E4451",
        ansi: [
            "282C34", "E06C75", "98C379", "E5C07B", "61AFEF", "C678DD", "56B6C2", "ABB2BF",
            "5C6370", "E06C75", "98C379", "E5C07B", "61AFEF", "C678DD", "56B6C2", "FFFFFF"
        ])
}

extension SwiftTerm.Color {
    /// SwiftTerm's channels are 16-bit (0...65535); its own 8-bit convenience init is
    /// internal, so scale an 8-bit hex component the same way it does (`× 257`, i.e.
    /// 0xFF → 0xFFFF). `Color` is a class, so this delegates to the public designated
    /// init rather than assigning stored properties directly (not allowed from an
    /// extension).
    convenience init(hex: String) {
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = UInt16((int >> 16) & 0xFF)
        let g = UInt16((int >> 8) & 0xFF)
        let b = UInt16(int & 0xFF)
        self.init(red: r * 257, green: g * 257, blue: b * 257)
    }
}

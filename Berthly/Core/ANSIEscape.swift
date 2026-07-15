// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation

/// Strips ANSI/VT terminal escape sequences and stray control characters out of a line of log
/// output, so the Log viewer renders clean readable text instead of literal `ESC[0;32m` /
/// `ESC]0;title` garbage.
///
/// Container stdout routinely carries these: a `systemd` boot colorizes its `[  OK  ]` banners
/// with SGR codes, and an interactive shell emits OSC window-title sequences (`ESC]0;user@host`)
/// and bracketed-paste toggles (`ESC[?2004h`). The full Terminal tab (SwiftTerm) *interprets*
/// them; the Log tab is a plain reader, so it deletes them instead.
///
/// Pure and `nonisolated` so it's unit-testable without a `Process`/terminal, following the
/// `buildArguments(for:)` pattern. This is a deleter, not a VT emulator — it does not honor
/// cursor movement or carriage-return overwrites; it removes the escape sequences and leaves the
/// remaining printable text (including literal `[`/`]` that weren't part of an escape) in place.
enum ANSIEscape {
    // Matches, tried left-to-right at each position (ICU alternation is ordered), so the CSI/OSC
    // rules claim `ESC[` / `ESC]` before the catch-all two-byte rule can:
    //   • OSC — `ESC ]` … up to its BEL or ST (`ESC \`) terminator: window-title, hyperlinks…
    //   • CSI — `ESC [` params/intermediates + final byte: SGR color, `?2004h` bracketed paste…
    //   • other two-byte `ESC <Fe>` escapes (0x40–0x5F): charset select (`ESC(B` variants), etc.
    private static let pattern =
        "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)" +
        "|\u{1B}\\[[0-?]*[ -/]*[@-~]" +
        "|\u{1B}[@-_]"

    // Constant pattern with a unit test guarding it, so `try!` can never fire at runtime.
    // `nonisolated` so the `nonisolated` `strip` can read it: `NSRegularExpression` is `Sendable`
    // and its matching methods are thread-safe, so it's safe from any isolation domain.
    private nonisolated static let regex = try! NSRegularExpression(pattern: pattern)

    /// Returns `line` with escape sequences and stray C0/DEL control bytes removed. Tabs are
    /// kept — they carry real column layout in tool output. A line that was *only* control
    /// sequences (e.g. a bare OSC title-set) collapses to `""`; `LogStreamer.lines(from:)` then
    /// drops it via its existing empty-line filter rather than showing a blank row.
    nonisolated static func strip(_ line: String) -> String {
        // The ESC gate keeps the common escape-free line off the regex engine entirely; a line
        // with no ESC can still hold a stray control byte, handled by the scalar filter below.
        let withoutEscapes: String
        if line.contains("\u{1B}") {
            let range = NSRange(line.startIndex..., in: line)
            withoutEscapes = regex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
        } else {
            withoutEscapes = line
        }

        // A C0 control (0x00–0x1F) or DEL (0x7F) that isn't a tab — a lone BEL, backspace, or a
        // `\r` left by a progress redraw. Tabs stay; they carry real column layout.
        func isRemovable(_ scalar: Unicode.Scalar) -> Bool {
            scalar != "\t" && (scalar.value < 0x20 || scalar.value == 0x7F)
        }
        guard withoutEscapes.unicodeScalars.contains(where: isRemovable) else { return withoutEscapes }
        return String(String.UnicodeScalarView(withoutEscapes.unicodeScalars.filter { !isRemovable($0) }))
    }
}

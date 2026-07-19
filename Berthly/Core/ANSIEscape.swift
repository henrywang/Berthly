// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation

/// Strips ANSI/VT escape sequences and stray control characters from a log line, so the Log
/// viewer shows clean text instead of literal `ESC[0;32m` garbage.
///
/// Container stdout carries plenty of these — a `systemd` boot colorizes `[  OK  ]` banners,
/// an interactive shell emits OSC title and bracketed-paste sequences. SwiftTerm interprets
/// them for the Terminal tab; the Log tab is a plain reader, so it deletes them instead.
///
/// A deleter, not a VT emulator: it doesn't honor cursor movement or carriage-return overwrites,
/// just removes escape sequences and leaves the rest in place. Pure and `nonisolated` so it's
/// unit-testable without a `Process`, like `buildArguments(for:)`.
enum ANSIEscape {
    // Ordered so the CSI/OSC alternatives (ICU alternation is tried left-to-right) claim
    // `ESC[`/`ESC]` before the catch-all two-byte rule can:
    //   • OSC — `ESC ]` … up to BEL or ST (`ESC \`): window-title, hyperlinks…
    //   • CSI — `ESC [` params/intermediates + final byte: SGR color, bracketed paste…
    //   • other two-byte `ESC <Fe>` (0x40–0x5F): charset select, etc.
    private static let pattern =
        "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)" +
        "|\u{1B}\\[[0-?]*[ -/]*[@-~]" +
        "|\u{1B}[@-_]"

    // A unit test guards `pattern`, so `try!` can never fire at runtime. `NSRegularExpression`
    // is `Sendable` and thread-safe, so `nonisolated` here is safe from any isolation domain.
    // swiftlint:disable:next force_try
    private nonisolated static let regex = try! NSRegularExpression(pattern: pattern)

    /// Tabs are kept — they carry real column layout. A line that was only control sequences
    /// (e.g. a bare OSC title-set) collapses to `""`; `LogStreamer.lines(from:)` drops it via
    /// its existing empty-line filter.
    nonisolated static func strip(_ line: String) -> String {
        // Keeps the common escape-free line off the regex engine entirely.
        let withoutEscapes: String
        if line.contains("\u{1B}") {
            let range = NSRange(line.startIndex..., in: line)
            withoutEscapes = regex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
        } else {
            withoutEscapes = line
        }

        // Catches leftovers the escape regex doesn't: a lone BEL, backspace, or a `\r` from a
        // progress redraw.
        func isRemovable(_ scalar: Unicode.Scalar) -> Bool {
            scalar != "\t" && (scalar.value < 0x20 || scalar.value == 0x7F)
        }
        guard withoutEscapes.unicodeScalars.contains(where: isRemovable) else { return withoutEscapes }
        return String(String.UnicodeScalarView(withoutEscapes.unicodeScalars.filter { !isRemovable($0) }))
    }
}

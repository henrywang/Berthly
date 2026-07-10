// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Berthly

/// `\u{1B}` is ESC (0x1B), the non-printing byte that leads every escape sequence — it's the byte
/// that gets eaten when this output is pasted into a plain-text field, leaving the visible
/// `[0;32m` / `]0;title` garbage the Log tab used to show. `\u{07}` is BEL, an OSC terminator.
struct ANSIEscapeTests {
    private let esc = "\u{1B}"
    private let bel = "\u{07}"

    // MARK: - The exact lines the user reported

    @Test func stripsShellPromptOSCAndBracketedPaste() {
        // OSC window-title (`ESC]0;…BEL`) + bracketed-paste-on (`ESC[?2004h`), then the literal
        // shell prompt — whose `[`/`]` are real text, not escapes, and must survive.
        let raw = "\(esc)]0;@fedora-44-bind:/\(bel)\(esc)[?2004h[root@fedora-44-bind /]# "
        #expect(ANSIEscape.strip(raw) == "[root@fedora-44-bind /]# ")
    }

    @Test func stripsSystemdOKBanner() {
        let raw = "[ \(esc)[0;32m  OK  \(esc)[0m] Started \(esc)[0;1;39msystemd-journald.service\(esc)[0m - Journal Service."
        #expect(ANSIEscape.strip(raw) == "[   OK  ] Started systemd-journald.service - Journal Service.")
    }

    @Test func stripsSystemdStartingLine() {
        let raw = "Starting \(esc)[0;1;39msystemd-tmpfiles-setup.service\(esc)[0m - Create System Files and Directories..."
        #expect(ANSIEscape.strip(raw) == "Starting systemd-tmpfiles-setup.service - Create System Files and Directories...")
    }

    // MARK: - Sequence families

    @Test func stripsSGRColorCodes() {
        #expect(ANSIEscape.strip("\(esc)[31mred\(esc)[0m plain") == "red plain")
    }

    @Test func stripsOSCTerminatedByStringTerminator() {
        // ST form of OSC: `ESC \` instead of BEL.
        #expect(ANSIEscape.strip("\(esc)]0;title\(esc)\\after") == "after")
    }

    @Test func controlOnlyLineCollapsesToEmpty() {
        // A bare title-set with no trailing text — must become "" so the streamer can drop it.
        #expect(ANSIEscape.strip("\(esc)]0;just a title\(bel)").isEmpty)
    }

    @Test func stripsStrayControlBytesButKeepsTabs() {
        // Lone BEL / carriage-return removed; the tab between columns preserved.
        #expect(ANSIEscape.strip("col1\tcol2\(bel)\r") == "col1\tcol2")
    }

    @Test func leavesCleanTextUntouched() {
        #expect(ANSIEscape.strip("09:01:12 INFO server listening on :8080")
                == "09:01:12 INFO server listening on :8080")
    }

    @Test func leavesLiteralBracketsThatArentEscapes() {
        // No ESC anywhere: brackets are ordinary characters, not a CSI, so nothing is removed.
        #expect(ANSIEscape.strip("array[0] = [value]") == "array[0] = [value]")
    }

    // MARK: - Integration through the streamer's line splitter

    @Test func lineSplitterStripsEscapesAndDropsControlOnlyLines() {
        let payload = "\(esc)]0;title\(bel)\n[ \(esc)[0;32m  OK  \(esc)[0m] Started foo\n"
        let data = Data(payload.utf8)
        // The title-only line vanishes; the banner survives, cleaned.
        #expect(LogStreamer.lines(from: data) == ["[   OK  ] Started foo"])
    }
}

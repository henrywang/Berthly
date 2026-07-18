// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Berthly

struct LogStreamClipboardTests {

    private func line(_ ts: String, _ level: LogStreamView.LogLevel, _ msg: String) -> LogStreamView.LogLine {
        LogStreamView.LogLine(timestamp: ts, level: level, message: msg)
    }

    @Test func structuredLineJoinsTimestampLevelMessage() {
        let text = LogStreamView.clipboardText(for: [line("09:01:12", .info, "server up")])
        #expect(text == "09:01:12 INFO server up")
    }

    @Test func plainLineIsJustTheMessage() {
        // No timestamp and `.other` level (raw stdout) — no leading gutter fields.
        let text = LogStreamView.clipboardText(for: [line("", .other, "added 1423 packages in 12s")])
        #expect(text == "added 1423 packages in 12s")
    }

    @Test func timeOnlyLineDropsTheEmptyLevel() {
        let text = LogStreamView.clipboardText(for: [line("09:01:15", .other, "GET /health 200")])
        #expect(text == "09:01:15 GET /health 200")
    }

    @Test func multipleLinesJoinWithNewlines() {
        let text = LogStreamView.clipboardText(for: [
            line("09:01:12", .info, "server up"),
            line("", .other, "plain stdout"),
            line("09:01:14", .error, "boom")
        ])
        #expect(text == "09:01:12 INFO server up\nplain stdout\n09:01:14 ERROR boom")
    }

    @Test func emptyInputProducesEmptyString() {
        #expect(LogStreamView.clipboardText(for: []).isEmpty)
    }
}

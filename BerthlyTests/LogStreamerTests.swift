// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Berthly

struct LogStreamerTests {

    // MARK: - lines(from:) — pure splitting

    @Test func splitsNewlineDelimitedLines() {
        let data = Data("boot: ok\nsystemd: started\nlogin: ready\n".utf8)
        #expect(LogStreamer.lines(from: data) == ["boot: ok", "systemd: started", "login: ready"])
    }

    @Test func dropsEmptyLines() {
        // Blank lines (including the trailing newline's empty tail) are filtered out.
        let data = Data("a\n\nb\n".utf8)
        #expect(LogStreamer.lines(from: data) == ["a", "b"])
    }

    @Test func lineWithoutTrailingNewlineIsKept() {
        let data = Data("partial line".utf8)
        #expect(LogStreamer.lines(from: data) == ["partial line"])
    }

    @Test func emptyDataYieldsNoLines() {
        #expect(LogStreamer.lines(from: Data()).isEmpty)
    }

    @Test func invalidUTF8YieldsNoLines() {
        // A lone continuation byte isn't valid UTF-8 — decode fails, so nothing is emitted
        // (rather than crashing or surfacing garbage).
        #expect(LogStreamer.lines(from: Data([0xFF, 0xFE])).isEmpty)
    }

    // MARK: - stream(fetch:onLine:) — drains a live handle

    @MainActor final class Collector { var lines: [String] = [] }

    @MainActor
    @Test func streamEmitsExistingBufferedLines() async throws {
        // A Pipe stands in for the daemon's log FileHandle. Writing then closing the write end
        // gives the read end a finite buffer terminated by EOF, so `readDataToEndOfFile` returns.
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("boot: ok\nsystemd: started\n".utf8))
        try pipe.fileHandleForWriting.close()

        let collector = Collector()
        let task = Task { @MainActor in
            try await LogStreamer.stream(
                fetch: { [pipe.fileHandleForReading] },
                onLine: { collector.lines.append($0) }
            )
        }

        // Wait for the initial drain, then cancel the follow loop.
        var waited = 0
        while collector.lines.count < 2, waited < 200 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        task.cancel()
        _ = try? await task.value

        #expect(collector.lines == ["boot: ok", "systemd: started"])
    }

    @MainActor
    @Test func streamReturnsQuietlyWhenNoHandles() async throws {
        let collector = Collector()
        try await LogStreamer.stream(fetch: { [] }, onLine: { collector.lines.append($0) })
        #expect(collector.lines.isEmpty)
    }
}

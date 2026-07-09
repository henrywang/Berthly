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

    @MainActor
    @Test func streamThrowsRatherThanCrashingOnClosedHandle() async throws {
        // Regression test: a handle whose fd is already closed (e.g. the daemon tore down the log
        // pipe out from under a still-polling read) used to raise an uncatchable NSException via
        // the deprecated `readDataToEndOfFile()`/`availableData` APIs, crashing the whole process.
        // The throwing `readToEnd()`/`read(upToCount:)` replacements surface it as a Swift `Error`
        // instead, so `stream` should throw here rather than crash.
        let pipe = Pipe()
        let fh = pipe.fileHandleForReading
        try fh.close()

        let collector = Collector()
        await #expect(throws: (any Error).self) {
            try await LogStreamer.stream(fetch: { [fh] }, onLine: { collector.lines.append($0) })
        }
    }

    @Test func readUpToCountThrowsRatherThanCrashingOnInvalidFd() throws {
        // Isolates the follow loop's exact primitive (`read(upToCount:)`, which wraps
        // `readDataUpToLength:error:` — the selector named in the production crash trace) rather
        // than going through `stream()`, where the drain's `readToEnd()` would throw first and
        // this call would never be reached. If this raises an uncatchable NSException instead of
        // throwing, the test process itself dies here — that's the signal an ObjC try/catch shim
        // is needed, not a plain #expect failure.
        let pipe = Pipe()
        let fh = pipe.fileHandleForReading
        close(fh.fileDescriptor)
        #expect(throws: (any Error).self) { _ = try fh.read(upToCount: 65_536) }
    }

    @MainActor
    @Test func streamThrowsWhenFdIsInvalidatedBehindFileHandlesBack() async throws {
        // Closer to the real crash than `streamThrowsRatherThanCrashingOnClosedHandle`: there,
        // `FileHandle` itself knows it's closed and can short-circuit without a syscall. Here the
        // raw fd is closed via POSIX `close`, so `FileHandle` still believes it's open and the read
        // has to hit the OS and get back EBADF — the exact failure the production trace shows
        // (`readDataUpToLength:error:` raising). This is the discriminating case: if the new
        // throwing API doesn't actually convert this failure to a Swift `Error`, this test crashes
        // the whole test process instead of failing cleanly.
        let pipe = Pipe()
        let fh = pipe.fileHandleForReading
        close(fh.fileDescriptor)

        let collector = Collector()
        await #expect(throws: (any Error).self) {
            try await LogStreamer.stream(fetch: { [fh] }, onLine: { collector.lines.append($0) })
        }
    }
}

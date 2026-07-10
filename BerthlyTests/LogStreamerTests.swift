// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Berthly

// Serialized: several tests below do raw fd surgery (`close(fh.fileDescriptor)`) and now
// `LogStreamer` also closes the handles it's given (fixing a per-view fd leak). A double-close is
// harmless only if no *other* test reuses that fd number in between — which Swift Testing's default
// parallel execution can't guarantee. Serializing this suite removes the intra-suite fd-reuse race.
@Suite(.serialized)
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
        // Regression test: the raw fd is closed via POSIX `close`, so `FileHandle` still believes
        // it's open and the read has to hit the OS and get back EBADF — the exact failure the
        // production trace shows (`readDataUpToLength:error:` raising an uncatchable NSException
        // via the deprecated `readDataToEndOfFile()`/`availableData` APIs). This is the
        // discriminating case: if the throwing `readToEnd()`/`read(upToCount:)` replacements don't
        // actually convert this failure to a Swift `Error`, this test crashes the whole test
        // process instead of failing cleanly.
        let pipe = Pipe()
        let fh = pipe.fileHandleForReading
        close(fh.fileDescriptor)

        let collector = Collector()
        await #expect(throws: (any Error).self) {
            try await LogStreamer.stream(fetch: { [fh] }, onLine: { collector.lines.append($0) })
        }
    }

    @MainActor
    @Test func streamClosesReceivedHandlesOnCompletion() async throws {
        // The daemon's log fds arrive `closeOnDealloc: false` (`XPCMessage.fileHandles(key:)`), so
        // `stream` must close them itself or leak two descriptors per Logs view. Use a non-owning
        // handle over a raw pipe — no `Pipe` to also close it — so the fd being closed afterwards can
        // only be `stream`'s doing.
        var fds = [Int32](repeating: -1, count: 2)
        #expect(pipe(&fds) == 0)
        let readFd = fds[0], writeFd = fds[1]
        FileHandle(fileDescriptor: writeFd, closeOnDealloc: false).write(Data("boot: ok\n".utf8))
        close(writeFd) // finite buffer + EOF so the drain returns
        let readHandle = FileHandle(fileDescriptor: readFd, closeOnDealloc: false)

        let collector = Collector()
        let task = Task { @MainActor in
            try await LogStreamer.stream(fetch: { [readHandle] }, onLine: { collector.lines.append($0) })
        }
        var waited = 0
        while collector.lines.isEmpty, waited < 200 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        task.cancel()
        _ = try? await task.value

        #expect(collector.lines == ["boot: ok"])
        #expect(fcntl(readFd, F_GETFD) == -1) // stream closed the handle it was handed
    }
}

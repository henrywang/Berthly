import Foundation

/// Shared adapter that turns the daemon's log `FileHandle`s into `LogStreamView`'s per-line
/// callback. Both container logs (`ContainerClient().logs(id:)`) and machine logs
/// (`MachineClient().logs(id:)`) hand back `[FileHandle]` of the same shape, so the read-existing/
/// follow-appended loop lives here once instead of being copied into each detail view.
///
/// The `fetch` closure that dials the daemon is injected, so the loop can be exercised in a unit
/// test with an in-memory `Pipe` rather than a live XPC connection. The pure line-splitting step
/// (`lines(from:)`) is the primary test target.
enum LogStreamer {
    /// Emits every existing line from the first handle, then follows appended data until the
    /// surrounding task is cancelled. Runs on the main actor (callers invoke it from a view's
    /// `.task`), hopping to a detached task only for the blocking `FileHandle` reads so the UI
    /// never stalls.
    @MainActor
    static func stream(
        fetch: @escaping () async throws -> [FileHandle],
        onLine: @escaping (String) -> Void
    ) async throws {
        let fhs = try await fetch()
        guard let fh = fhs.first else { return }

        // Drain whatever's already buffered off the main actor. `readToEnd()` (not the deprecated
        // `readDataToEndOfFile()`) surfaces a bad/closed descriptor as a catchable Swift `Error`
        // instead of an uncatchable NSException — the deprecated calls crash the whole process the
        // moment the daemon closes the log pipe out from under a still-polling read.
        let existing = try await Task.detached(priority: .utility) {
            try fh.readToEnd() ?? Data()
        }.value
        for line in lines(from: existing) { onLine(line) }

        // Follow new data. `read(upToCount:)` (not the deprecated `availableData`) returns nil at
        // EOF instead of an empty Data(), so the loop ends cleanly once the source closes rather
        // than polling a dead handle forever.
        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { break }
            guard let data = try await Task.detached(priority: .utility, operation: {
                try fh.read(upToCount: 65_536)
            }).value else { break }
            for line in lines(from: data) { onLine(line) }
        }
    }

    /// Splits a UTF-8 chunk into non-empty newline-delimited lines. Pure and deterministic —
    /// invalid UTF-8 yields no lines, matching the previous per-view behaviour.
    nonisolated static func lines(from data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }
}

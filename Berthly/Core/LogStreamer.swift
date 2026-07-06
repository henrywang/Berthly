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

        // Drain whatever's already buffered off the main actor.
        let existing = await Task.detached(priority: .utility) {
            fh.readDataToEndOfFile()
        }.value
        for line in lines(from: existing) { onLine(line) }

        // Follow new data.
        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { break }
            let data = await Task.detached(priority: .utility) { fh.availableData }.value
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

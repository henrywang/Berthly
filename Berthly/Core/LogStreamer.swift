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
    /// Which of the daemon's two log files to stream. The daemon hands back `[stdio, boot]` for
    /// both containers and machines; the CLI's `logs --boot` flag selects the second — this is
    /// the GUI's equivalent. Raw values feed the Logs tab's segmented picker labels.
    nonisolated enum LogSource: String, CaseIterable, Hashable {
        case stdio = "Output"
        case boot  = "Boot"

        /// Position of this source in the daemon's `[FileHandle]` reply — mirrors the CLI's
        /// `boot ? fhs[1] : fhs[0]` in `ContainerLogs`/`MachineLogs`.
        var handleIndex: Int {
            switch self {
            case .stdio: 0
            case .boot:  1
            }
        }
    }

    /// Emits every existing line from the selected handle, then follows appended data until the
    /// surrounding task is cancelled. Runs on the main actor (callers invoke it from a view's
    /// `.task`), hopping to a detached task only for the blocking `FileHandle` reads so the UI
    /// never stalls.
    @MainActor
    static func stream(
        source: LogSource = .stdio,
        fetch: @escaping () async throws -> [FileHandle],
        onLine: @escaping (String) -> Void
    ) async throws {
        let fhs = try await fetch()
        // The daemon's log fds arrive `closeOnDealloc: false` (`XPCMessage.fileHandles(key:)`), so
        // nothing closes them on our behalf — leaking two descriptors per Logs view unless we do it
        // ourselves. By the time this function returns or throws, every detached read below has
        // already completed (we `await` each), so closing here never races an in-flight read.
        defer { for fh in fhs { try? fh.close() } }
        guard fhs.count > source.handleIndex else { return }
        let fh = fhs[source.handleIndex]

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

    /// Splits a UTF-8 chunk into non-empty newline-delimited lines, stripping ANSI/VT escape
    /// sequences from each (see `ANSIEscape`) so container stdout — `systemd`'s colorized
    /// `[  OK  ]` banners, a shell's OSC title / bracketed-paste noise — reads as clean text in
    /// the Log tab rather than literal `ESC[0m` garbage. Pure and deterministic; invalid UTF-8
    /// yields no lines, matching the previous per-view behaviour. The empty filter runs *after*
    /// stripping, so a line that was only control sequences is dropped instead of shown blank.
    nonisolated static func lines(from data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
            .map(ANSIEscape.strip)
            .filter { !$0.isEmpty }
    }
}

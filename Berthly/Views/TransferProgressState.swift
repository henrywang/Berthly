import SwiftUI
import TerminalProgress

// MARK: - Transfer Progress State

/// Shared live-progress model for image transfers (pull and push): accumulates the daemon's
/// byte/item `ProgressUpdateEvent`s into a fraction + a scrolling log. The verb-specific strings
/// (log tag, opening command line, success line) are injected so pull and push can share the same
/// reducer without duplicating it — use `.pull()` / `.push()`.
@MainActor
@Observable
final class TransferProgressState {
    struct LogLine: Identifiable {
        let id = UUID()
        let tag: String
        let text: String
    }

    private let verb: String                     // "PULL" / "PUSH" — the log gutter tag
    private let commandText: String              // "container image pull" — the opening line
    private let doneText: (String) -> String     // success line, given the reference

    var completedItems: Int = 0
    var totalItems: Int = 0
    var transferredBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var logLines: [LogLine] = []

    private var hasLoggedManifest = false

    init(verb: String, commandText: String, doneText: @escaping (String) -> String) {
        self.verb = verb
        self.commandText = commandText
        self.doneText = doneText
    }

    static func pull() -> TransferProgressState {
        .init(verb: "PULL", commandText: "container image pull",
              doneText: { "\($0) ready · pulled to local store" })
    }

    static func push() -> TransferProgressState {
        .init(verb: "PUSH", commandText: "container image push",
              doneText: { "\($0) pushed · uploaded to registry" })
    }

    static func load() -> TransferProgressState {
        .init(verb: "LOAD", commandText: "container image load",
              doneText: { "\($0) ready · loaded into local store" })
    }

    func start(reference: String) {
        completedItems = 0; totalItems = 0; transferredBytes = 0; totalBytes = 0
        hasLoggedManifest = false
        logLines = [LogLine(tag: verb, text: "\(commandText) \(reference)")]
    }

    func markFetchingComplete() {
        if totalItems > 0 {
            let blobWord = totalItems == 1 ? "blob" : "blobs"
            let sizePart = totalBytes > 0 ? " · \(formatDiskBytes(UInt64(totalBytes)))" : ""
            logLines.append(LogLine(tag: verb, text: "fetching complete · \(totalItems) \(blobWord)\(sizePart)"))
        } else {
            logLines.append(LogLine(tag: verb, text: "fetching complete · all layers cached"))
        }
    }

    func appendLog(tag: String, text: String) {
        logLines.append(LogLine(tag: tag, text: text))
    }

    func markDone(reference: String) {
        logLines.append(LogLine(tag: "DONE", text: doneText(reference)))
    }

    func handle(_ events: [ProgressUpdateEvent]) {
        var dTotalSize: Int64 = 0
        var dSize: Int64 = 0
        var dItems: Int = 0
        var dTotalItems: Int = 0
        for event in events {
            switch event {
            case .addTotalSize(let n):  dTotalSize += n
            case .addSize(let n):       dSize += n
            case .addItems(let n):      dItems += n
            case .addTotalItems(let n): dTotalItems += n
            default: break
            }
        }
        totalBytes       += dTotalSize
        transferredBytes += dSize
        completedItems   += dItems
        totalItems       += dTotalItems

        if !hasLoggedManifest && dTotalSize > 0 {
            hasLoggedManifest = true
            logLines.append(LogLine(tag: verb, text: "resolving manifest ✓"))
        }
    }

    var fraction: Double? {
        if totalBytes > 0 { return min(1.0, Double(transferredBytes) / Double(totalBytes)) }
        if totalItems > 0 { return min(1.0, Double(completedItems) / Double(totalItems)) }
        return nil
    }

    var percentText: String {
        guard let f = fraction else { return "" }
        return "\(Int(f * 100))%"
    }

    var handler: ProgressUpdateHandler {
        { [weak self] events in
            guard let self else { return }
            await self.handle(events)
        }
    }
}

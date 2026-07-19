// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

/// Container Logs' viewer: a follow/filter/wrap/clear toolbar over a scrolling, colorized line
/// list. Callers supply a `stream` closure that emits raw lines via `onLine` for as long as the
/// surrounding `.task(id:)` stays alive; this view owns display state (following, filter, wrap)
/// and re-parses each raw line into a `LogLine`. Daemon Logs uses the simpler, read-only
/// `DaemonLogView` instead — daemon events are occasional health/status info, not something
/// actively searched like container stdout.
struct LogStreamView: View {
    let id: AnyHashable
    let stream: (@escaping @MainActor (String) -> Void) async throws -> Void
    /// When set, the toolbar shows an Output/Boot segmented picker bound to the caller's log
    /// source — the GUI equivalent of the CLI's `logs --boot` flag. The caller must fold the
    /// source into `id` so switching restarts the stream task. `nil` hides the picker (Daemon
    /// Logs and other single-source streams).
    var source: Binding<LogStreamer.LogSource>?

    struct LogLine: Identifiable {
        let id = UUID()
        let timestamp: String
        let level: LogLevel
        let message: String
    }

    enum LogLevel: String {
        case info  = "INFO"
        case warn  = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
        case trace = "TRACE"
        case other = ""

        var color: Color {
            switch self {
            case .info:         .statusRunning
            case .warn:         .statusPaused
            case .error:        .statusError
            case .debug, .trace: Color(NSColor.secondaryLabelColor)
            case .other:        .primary
            }
        }
    }

    @State private var lines: [LogLine]  = []
    @State private var isFollowing       = true
    @State private var filterText        = ""
    @State private var wrapText          = false
    @State private var streamEnded       = false

    private var filteredLines: [LogLine] {
        guard !filterText.isEmpty else { return lines }
        let q = filterText.lowercased()
        return lines.filter {
            $0.message.lowercased().contains(q) ||
            $0.level.rawValue.lowercased().contains(q) ||
            $0.timestamp.contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Button { isFollowing.toggle() } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(streamEnded ? Color.statusError : (isFollowing ? Color.berthlyAccent : Color.secondary))
                            .frame(width: 8, height: 8)
                        Text(streamEnded ? "Stream ended" : "Following")
                            .font(.callout)
                            .foregroundStyle(streamEnded ? Color.statusError : (isFollowing ? Color.berthlyAccent : Color.secondary))
                    }
                }
                .buttonStyle(.plain)
                .disabled(streamEnded)
                .help(streamEnded ? "The log stream ended unexpectedly — the daemon connection may have been lost." : "")

                TextField("Filter logs", text: $filterText)
                    .accessibilityIdentifier("logFilterField")
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)

                if let source {
                    Picker("Log source", selection: source) {
                        ForEach(LogStreamer.LogSource.allCases, id: \.self) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("logSourcePicker")
                }

                Spacer()

                Toggle("Wrap", isOn: $wrapText)
                    .toggleStyle(.button)
                    .controlSize(.small)

                Button("Copy") { copyAll() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(filteredLines.isEmpty)
                    .help("Copy all shown logs to the clipboard")

                Button("Clear") { lines = [] }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    if filteredLines.isEmpty {
                        ContentUnavailableView("No logs", systemImage: "text.alignleft")
                            .foregroundStyle(.secondary)
                            .padding(.top, 60)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredLines) { line in
                                LogStreamLineRow(line: line, wrapText: wrapText)
                            }
                            Color.clear.frame(height: 1).id("log-bottom")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        // Native select + ⌘C / right-click Copy. Log lines are read-only info a
                        // user routinely wants to paste into a bug report or search.
                        .textSelection(.enabled)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .onChange(of: lines.count) {
                    if isFollowing {
                        proxy.scrollTo("log-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .task(id: id) {
            lines = []
            streamEnded = false
            do {
                try await stream { raw in
                    appendLine(Self.parseLine(raw))
                }
            } catch is CancellationError {
                // Expected: the view disappeared or `id` changed, tearing down this task.
            } catch {
                streamEnded = true
            }
        }
    }

    private func appendLine(_ line: LogLine) {
        lines.append(line)
        if lines.count > 5_000 { lines.removeFirst(lines.count - 5_000) }
    }

    /// Copies every currently shown (i.e. filtered) line at once — the convenient counterpart to
    /// per-line drag-select + ⌘C. Copies full untruncated text regardless of the Wrap toggle.
    private func copyAll() {
        let text = Self.clipboardText(for: filteredLines)
        guard !text.isEmpty else { return }
        copyToPasteboard(text)
    }

    /// Flattens lines to one plain-text row each, joining the non-empty timestamp/level/message
    /// fields with a single space — so a structured line reads `09:01:12 INFO server up` and a
    /// plain stdout line is just its message. Pure and `nonisolated` so it's unit-testable
    /// without a `Process`/pasteboard, following `buildArguments(for:)`.
    nonisolated static func clipboardText(for lines: [LogLine]) -> String {
        lines
            .map { line in
                [line.timestamp, line.level == .other ? "" : line.level.rawValue, line.message]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    static func parseLine(_ raw: String) -> LogLine {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return LogLine(timestamp: "", level: .other, message: "") }

        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return LogLine(timestamp: "", level: .other, message: trimmed) }

        func toLevel(_ s: String) -> LogLevel? {
            switch s.uppercased() {
            case "INFO":                 return .info
            case "WARN", "WARNING":      return .warn
            case "ERROR", "ERR":         return .error
            case "DEBUG":                return .debug
            case "TRACE":                return .trace
            default:                     return nil
            }
        }

        let hasTS = parts[0].range(of: #"\d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil

        // HH:MM:SS LEVEL message
        if hasTS, parts.count >= 3, let level = toLevel(parts[1]) {
            return LogLine(timestamp: parts[0], level: level, message: parts[2...].joined(separator: " "))
        }
        // HH:MM:SS message
        if hasTS, parts.count >= 2 {
            return LogLine(timestamp: parts[0], level: .other, message: parts[1...].joined(separator: " "))
        }
        // LEVEL message
        if let level = toLevel(parts[0]), parts.count >= 2 {
            return LogLine(timestamp: "", level: level, message: parts[1...].joined(separator: " "))
        }
        // Level keyword somewhere in the line
        for (i, part) in parts.enumerated() {
            if let level = toLevel(part), i + 1 < parts.count {
                return LogLine(timestamp: hasTS ? parts[0] : "", level: level,
                               message: parts[(i + 1)...].joined(separator: " "))
            }
        }

        return LogLine(timestamp: "", level: .other, message: trimmed)
    }
}

private struct LogStreamLineRow: View {
    let line: LogStreamView.LogLine
    let wrapText: Bool

    /// A line with no parsed timestamp *and* no parsed level is raw container stdout (a `print`,
    /// a stack trace, `npm` output). Reserving the fixed metadata gutters for those would indent
    /// a whole all-plain stream ~116pt with an empty left band — so they render full-width and
    /// flush-left instead. Structured rows (with either a timestamp or a level) keep the fixed
    /// columns so they still align with each other; a given container is almost always uniform,
    /// so the two styles rarely interleave.
    private var isPlain: Bool { line.timestamp.isEmpty && line.level == .other }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if !isPlain {
                Text(line.timestamp)
                    .foregroundStyle(.tertiary)
                    .frame(width: 68, alignment: .leading)

                Text(line.level == .other ? "" : line.level.rawValue)
                    .foregroundStyle(line.level.color)
                    .fontWeight(.medium)
                    .frame(width: 48, alignment: .leading)
            }

            Group {
                if wrapText {
                    Text(line.message)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(line.message)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }
}

#Preview("Full view — toolbar with Copy") {
    LogStreamView(id: "preview") { onLine in
        for raw in [
            "09:01:12 INFO server listening on :8080",
            "09:01:13 WARN slow query took 812ms",
            "09:01:14 ERROR connection refused: db:5432",
            "added 1423 packages in 12s"
        ] {
            await MainActor.run { onLine(raw) }
        }
    }
    .frame(width: 640, height: 260)
}

#Preview("Full view — with source picker") {
    LogStreamView(id: "preview-boot", stream: { onLine in
        for raw in [
            "vminit: mounting rootfs",
            "vminit: starting init process",
            "vminit: ready"
        ] {
            await MainActor.run { onLine(raw) }
        }
    }, source: .constant(.boot))
    .frame(width: 640, height: 220)
}

#Preview("Log rows — structured / mixed / plain") {
    let lines: [LogStreamView.LogLine] = [
        // Fully structured: time + level columns
        .init(timestamp: "09:01:12", level: .info, message: "server listening on :8080"),
        .init(timestamp: "09:01:13", level: .warn, message: "slow query took 812ms"),
        .init(timestamp: "09:01:14", level: .error, message: "connection refused: db:5432"),
        // Time only (level column empty but grid kept)
        .init(timestamp: "09:01:15", level: .other, message: "GET /health 200"),
        // Pure plain stdout — should be flush-left, no gutter
        .init(timestamp: "", level: .other, message: "added 1423 packages in 12s"),
        .init(timestamp: "", level: .other, message: "  at Object.<anonymous> (/app/index.js:42:11)"),
        .init(timestamp: "", level: .other, message: "Building wheel for numpy (pyproject.toml) ...")
    ]
    return VStack(alignment: .leading, spacing: 0) {
        ForEach(lines) { LogStreamLineRow(line: $0, wrapText: false) }
    }
    .font(.system(.caption, design: .monospaced))
    .padding(.vertical, 8)
    .frame(width: 460, alignment: .leading)
}

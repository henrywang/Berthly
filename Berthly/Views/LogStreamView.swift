import SwiftUI

/// Shared by any log viewer (container logs, daemon logs): a follow/filter/wrap/clear toolbar
/// over a scrolling, colorized line list. Callers supply a `stream` closure that emits raw lines
/// via `onLine` for as long as the surrounding `.task(id:)` stays alive; this view owns display
/// state (following, filter, wrap) and re-parses each raw line into a `LogLine`.
struct LogStreamView: View {
    let id: AnyHashable
    let stream: (@escaping @MainActor (String) -> Void) async throws -> Void

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
                            .fill(isFollowing ? Color.berthlyAccent : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text("Following")
                            .font(.callout)
                            .foregroundStyle(isFollowing ? Color.berthlyAccent : Color.secondary)
                    }
                }
                .buttonStyle(.plain)

                TextField("Filter logs", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)

                Spacer()

                Toggle("Wrap", isOn: $wrapText)
                    .toggleStyle(.button)
                    .controlSize(.small)

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
                        .padding(.vertical, 8)
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
            try? await stream { raw in
                appendLine(Self.parseLine(raw))
            }
        }
    }

    private func appendLine(_ line: LogLine) {
        lines.append(line)
        if lines.count > 5_000 { lines.removeFirst(lines.count - 5_000) }
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

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.timestamp)
                .foregroundStyle(.tertiary)
                .frame(width: 68, alignment: .leading)

            Text(line.level == .other ? "" : line.level.rawValue)
                .foregroundStyle(line.level.color)
                .fontWeight(.medium)
                .frame(width: 48, alignment: .leading)

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

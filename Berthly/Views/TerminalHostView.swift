import SwiftTerm
import SwiftUI

/// Which running resource a `TerminalHostView` execs a shell into — a container (`exec`) or a
/// container machine's VM (a login shell in the container backing the machine; see PLAN.md §8).
enum TerminalTarget: Equatable {
    case container(id: String)
    case machine(id: String)
}

/// Wraps SwiftTerm's `TerminalView` and bridges it to a `TerminalSession` exec'd into a running
/// container or machine. One `Coordinator` per view identity owns the session so re-renders
/// (e.g. sibling tab switches that keep this view alive) don't restart the shell underneath the
/// user.
struct TerminalHostView: NSViewRepresentable {
    let target: TerminalTarget
    @AppStorage("terminalTheme") private var themeRaw = TerminalTheme.dracula.rawValue

    private var theme: TerminalTheme { TerminalTheme(rawValue: themeRaw) ?? .dracula }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        context.coordinator.terminalView = view
        applyTheme(theme, to: view)
        context.coordinator.connect(target: target)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        applyTheme(theme, to: nsView)
    }

    // `installColors` (not the lower-level `terminal.installPalette`) both installs the
    // 16-color ANSI table and repaints, so a live theme change while the tab is open takes
    // effect immediately via `updateNSView` — cheap and idempotent to reapply every time.
    private func applyTheme(_ theme: TerminalTheme, to view: TerminalView) {
        let colors = theme.colors
        view.nativeBackgroundColor = NSColor(Color(hex: colors.background))
        view.nativeForegroundColor = NSColor(Color(hex: colors.foreground))
        view.caretColor = NSColor(Color(hex: colors.cursor))
        view.selectedTextBackgroundColor = NSColor(Color(hex: colors.selection))
        view.installColors(colors.ansi.map { SwiftTerm.Color(hex: $0) })
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        // Detach only — an exec session must never kill the container it's attached to,
        // since it may be shared with other sessions or the container's own lifecycle.
        coordinator.session.detach()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        weak var terminalView: TerminalView?
        let session = TerminalSession()
        private var started = false

        func connect(target: TerminalTarget) {
            guard !started else { return }
            started = true

            session.onOutput = { [weak self] data in
                self?.terminalView?.feed(byteArray: ArraySlice(data))
            }
            session.onExit = { [weak self] _ in
                self?.terminalView?.feed(text: "\r\n\u{1b}[2m[session ended]\u{1b}[0m\r\n")
            }

            Task { [weak self] in
                do {
                    switch target {
                    case .container(let id): try await self?.session.start(containerID: id)
                    case .machine(let id): try await self?.session.start(machineID: id)
                    }
                } catch {
                    self?.terminalView?.feed(text: "\u{1b}[31mFailed to start shell: \(error.localizedDescription)\u{1b}[0m\r\n")
                }
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.send(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // `TerminalView` starts at `frame(.zero)` in `makeNSView` and fires this before
            // SwiftUI lays it out — `newCols`/`newRows` can be 0 or negative in that instant.
            // `UInt16(_:)` traps on an out-of-range `Int`; clamp instead of converting directly.
            guard newCols > 0, newRows > 0 else { return }
            let session = self.session
            let cols = UInt16(clamping: newCols)
            let rows = UInt16(clamping: newRows)
            Task { try? await session.resize(cols: cols, rows: rows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

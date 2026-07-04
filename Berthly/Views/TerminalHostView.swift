import SwiftTerm
import SwiftUI

/// Wraps SwiftTerm's `TerminalView` and bridges it to a `TerminalSession` exec'd into a running
/// container. One `Coordinator` per view identity owns the session so re-renders (e.g. sibling
/// tab switches that keep this view alive) don't restart the shell underneath the user.
struct TerminalHostView: NSViewRepresentable {
    let containerID: String

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        context.coordinator.terminalView = view
        context.coordinator.connect(containerID: containerID)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

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

        func connect(containerID: String) {
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
                    try await self?.session.start(containerID: containerID)
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

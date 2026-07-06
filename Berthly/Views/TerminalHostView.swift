import AppKit
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
        // SwiftTerm's `TerminalView` doesn't override `rightMouseDown`/`menu(for:)`, so a
        // right-click falls through to default `NSView` behavior and shows `view.menu`.
        // We set it directly here rather than via a SwiftUI `.contextMenu`, which is
        // unreliable on an `NSViewRepresentable` whose backing view consumes the click.
        // This is the terminal's only signpost to the theme picker (also in Settings, ⌘,).
        view.menu = context.coordinator.makeContextMenu()
        context.coordinator.connect(target: target)
        // By the next runloop tick the representable's view is in the window; grab focus so the
        // Terminal tab is typable on entry. `updateNSView` handles the same latch for the case
        // where it lands first — whichever runs earlier wins, the other is a no-op.
        DispatchQueue.main.async { [weak view, coordinator = context.coordinator] in
            guard let view, !coordinator.hasFocused, let window = view.window else { return }
            coordinator.hasFocused = true
            window.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        applyTheme(theme, to: nsView)
        // Focus the terminal on first appearance so switching to the Terminal tab lets the user
        // type immediately, without an extra click to make it first responder. Guarded so a live
        // theme repaint (another `updateNSView` pass) doesn't yank focus back mid-interaction.
        if !context.coordinator.hasFocused, let window = nsView.window {
            context.coordinator.hasFocused = true
            window.makeFirstResponder(nsView)
        }
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
    final class Coordinator: NSObject, TerminalViewDelegate, NSMenuDelegate {
        weak var terminalView: TerminalView?
        let session = TerminalSession()
        private var started = false
        /// One-shot latch so we make the terminal first responder only on its first appearance,
        /// not on every `updateNSView` (which also fires for live theme changes).
        var hasFocused = false

        // MARK: Context menu

        /// The `@AppStorage` key `TerminalHostView`/`SettingsView` bind the selected theme to.
        /// Writing it via `UserDefaults` from a menu action drives `@AppStorage`, which repaints
        /// the live terminal through `updateNSView` and reflects in Settings if it's open.
        private static let themeKey = "terminalTheme"

        private var currentTheme: TerminalTheme {
            TerminalTheme(rawValue: UserDefaults.standard.string(forKey: Self.themeKey) ?? "") ?? .dracula
        }

        /// Right-click menu: standard Copy/Paste (routed to SwiftTerm via the responder chain),
        /// a Theme submenu with the same live ANSI swatches the Settings picker shows, and a
        /// jump to the full Settings pane. The Theme submenu is the discoverability hook — a user
        /// working in the terminal finds it without knowing to open ⌘, first.
        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self

            let copyItem = NSMenuItem(title: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "")
            let pasteItem = NSMenuItem(title: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "")
            menu.addItem(copyItem)
            menu.addItem(pasteItem)
            menu.addItem(.separator())

            let themeItem = NSMenuItem(title: "Terminal Theme", action: nil, keyEquivalent: "")
            let themeSubmenu = NSMenu()
            for theme in TerminalTheme.allCases {
                let item = NSMenuItem(title: theme.displayName, action: #selector(selectTheme(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = theme.rawValue
                item.image = Self.swatchImage(for: theme)
                themeSubmenu.addItem(item)
            }
            themeItem.submenu = themeSubmenu
            menu.addItem(themeItem)
            menu.addItem(.separator())

            let settings = NSMenuItem(title: "Terminal Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
            settings.target = self
            menu.addItem(settings)
            return menu
        }

        /// Refresh the checkmark on the active theme each time the menu opens — the selection can
        /// change from the Settings pane while a terminal stays open.
        func menuNeedsUpdate(_ menu: NSMenu) {
            let selected = currentTheme.rawValue
            for item in menu.items {
                guard let submenu = item.submenu else { continue }
                for themeItem in submenu.items {
                    themeItem.state = (themeItem.representedObject as? String) == selected ? .on : .off
                }
            }
        }

        @objc private func selectTheme(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String else { return }
            UserDefaults.standard.set(raw, forKey: Self.themeKey)
        }

        @objc private func openSettings(_ sender: NSMenuItem) {
            if #available(macOS 14, *) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }

        /// A compact strip of the theme's first 8 ANSI colors, so each menu entry previews the
        /// scheme — the same rationale as `SettingsView.ThemeRow`. Reuses the `Color(hex:)`
        /// extension already used by `applyTheme`.
        private static func swatchImage(for theme: TerminalTheme) -> NSImage {
            let count = 8
            let w: CGFloat = 8, h: CGFloat = 12, gap: CGFloat = 1
            let size = NSSize(width: CGFloat(count) * w + CGFloat(count - 1) * gap, height: h)
            let image = NSImage(size: size)
            image.lockFocus()
            for (i, hex) in theme.colors.ansi.prefix(count).enumerated() {
                let rect = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: h)
                NSColor(Color(hex: hex)).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            }
            image.unlockFocus()
            return image
        }

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

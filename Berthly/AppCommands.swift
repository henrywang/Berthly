// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

/// The app's command menu. On macOS the menu bar is the canonical command surface — it's where
/// users discover shortcuts, what the Help menu's search indexes, and the accessibility path to
/// every action — so each toolbar action is mirrored here, and the *menu items* own the keyboard
/// shortcuts (the toolbar buttons deliberately don't register their own, to avoid double
/// registration of the same key).
///
/// Actions route through `MenuBarBridge.pendingIntent` exactly like the menu bar extra's entry
/// points: `MainWindowView` picks the intent up via `.onChange`/`.onAppear`, which also covers
/// choosing a menu item while no main window exists (the intent survives until the window mounts).
/// App-menu entry for Sparkle self-updates, in the standard spot under "About Berthly".
/// The button lives in a child View (not directly in the CommandGroup) so reading the
/// `@Observable` updater's `canCheckForUpdates` re-evaluates the menu item when an update
/// session starts/ends.
struct UpdaterCommands: Commands {
    let updater: UpdaterService

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton(updater: updater)
        }
    }

    private struct CheckForUpdatesButton: View {
        let updater: UpdaterService

        var body: some View {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}

struct ContainerCommands: Commands {
    let service: ContainerServiceBase
    let bridge: MenuBarBridge
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Edit > Find, focusing the showing list's search field. Standard macOS muscle memory —
        // without a menu item, ⌘F does nothing even though every list is filterable.
        CommandGroup(after: .textEditing) {
            Button("Find") { bridge.searchFocusToken += 1 }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!service.isConnected)
        }

        // Command palette (⌘K). Sits under the View menu — the standard home for
        // navigation/lookup surfaces — and, per this file's convention, the *menu item* owns the
        // shortcut. Available even while disconnected: it still offers section navigation.
        CommandGroup(after: .sidebar) {
            Button("Command Palette…") { bridge.commandPaletteToken += 1; ensureWindow() }
                .keyboardShortcut("k", modifiers: .command)

            Divider()

            // ⌘1…⌘6 pane switching — standard macOS sidebar muscle memory (Xcode navigators,
            // Mail mailboxes). Menu items own the shortcuts (this file's convention), and each
            // routes through the same `navigate` intent the window reads on `.onChange`/`.onAppear`.
            // Enabled while disconnected: the sections still render their empty/connect states.
            Group {
                paneItem("Compute",    .compute,    "1")
                paneItem("Volumes",    .volumes,    "2")
                paneItem("Networks",   .networks,   "3")
                paneItem("Images",     .images,     "4")
                paneItem("Registries", .registries, "5")
                paneItem("System",     .system,     "6")
            }
        }

        CommandMenu("Container") {
            Button("Run Container…") { send(.openRunContainerSheet) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!service.isConnected)

            Button("Create Machine…") { send(.openCreateMachineSheet) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!service.isConnected)

            Divider()

            Button("Build Image…") { send(.openBuildSheet) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!service.isConnected)

            Button("Pull Image…") { send(.openPullSheet) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!service.isConnected)

            Button("Load Image from Disk…") { send(.openLoadImageSheet) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!service.isConnected)

            Divider()

            Button("Refresh") {
                Task { await service.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!service.isConnected)
        }
    }

    /// A View-menu item that switches to `section` on ⌘<key>, opening a window first if needed.
    private func paneItem(_ title: LocalizedStringKey, _ section: SidebarSelection, _ key: KeyEquivalent) -> some View {
        Button(title) { send(.navigate(section)) }
            .keyboardShortcut(key, modifiers: .command)
    }

    private func send(_ intent: MenuBarBridge.Intent) {
        bridge.pendingIntent = intent
        ensureWindow()
    }

    /// Open the main window if none exists, so a menu action taken with every window closed still
    /// lands somewhere (the token/intent survives until the window mounts and reads it).
    private func ensureWindow() {
        if !bridge.isMainWindowOpen {
            openWindow(id: "main")
        }
    }
}

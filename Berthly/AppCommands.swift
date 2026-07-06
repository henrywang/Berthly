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

            Divider()

            Button("Refresh") {
                Task { await service.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!service.isConnected)
        }
    }

    private func send(_ intent: MenuBarBridge.Intent) {
        bridge.pendingIntent = intent
        if !bridge.isMainWindowOpen {
            openWindow(id: "main")
        }
    }
}

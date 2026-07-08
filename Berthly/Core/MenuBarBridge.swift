// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppKit
import Observation

/// Bridges the `MenuBarExtra` scene to the main window scene. SwiftUI scenes don't share view
/// state, so a menu bar quick action (open a container, open the run form) needs a shared
/// observable both scenes are injected with, rather than being threaded through
/// `ContainerServiceBase` (the data/daemon layer, not a place for UI-navigation intent).
@Observable
@MainActor
final class MenuBarBridge {
    enum Intent: Equatable {
        case selectCompute(ComputeItem)
        case openRunContainerSheet
        case openCreateMachineSheet
        case openBuildSheet
        case openPullSheet
        case openCreateVolumeSheet
        case openCreateNetworkSheet
        case openAddRegistrySheet
    }

    var pendingIntent: Intent?

    /// Bumped by Edit > Find (⌘F). Whichever list view is currently showing observes it and
    /// presents/focuses its own search field — a token (not a Bool) so repeated ⌘F presses
    /// always re-fire even if the field is already visible.
    var searchFocusToken = 0

    /// Bumped by View > Command Palette (⌘K). `MainWindowView` observes it and presents the
    /// palette overlay — a token (not a Bool) for the same reason as `searchFocusToken`: repeated
    /// ⌘K should re-open/re-focus it, and the shortcut can arrive from the menu while no window is
    /// open (the token survives until the window mounts and reads it).
    var commandPaletteToken = 0

    /// Set by the palette's "Open Shell in X" action alongside selecting X. The matching
    /// container/machine detail view consumes it (on both `.onAppear` and `.onChange`, since the
    /// request usually arrives with a *fresh* detail mount) by switching to its Terminal tab, then
    /// clears it. A nil-clearing optional (not a token) so each request fires exactly once and a
    /// new request for a different item always re-fires — same shape as `pendingIntent`.
    var terminalRequest: ComputeItem? = nil

    /// Set by `MainWindowView`'s `.onAppear`/`.onDisappear`. `openWindow(id:)` has no built-in
    /// single-instance behavior for a plain `WindowGroup` — without checking this first, the menu
    /// bar's "Open Berthly"/"Run…"/row-tap actions would open a duplicate window every time one
    /// already exists, instead of focusing it.
    var isMainWindowOpen = false

    /// The `MenuBarExtra(.window)` popover's own `NSWindow`, captured by `MenuBarView` via
    /// `WindowAccessor` on appear. SwiftUI has no public API to dismiss this popover — closing
    /// this directly (rather than guessing at a private window class name, or a style-mask
    /// heuristic that risks matching an open sheet instead) is the precise, non-fragile way to do
    /// it. `weak` since the window's lifecycle belongs to AppKit/SwiftUI, not this bridge.
    weak var menuBarPopoverWindow: NSWindow?
}

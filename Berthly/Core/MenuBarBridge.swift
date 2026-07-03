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
    }

    var pendingIntent: Intent?

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

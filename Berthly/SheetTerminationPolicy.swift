// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppKit

/// Stops open sheets and alerts from vetoing ⌘Q and the menu bar's Quit, which both call `terminate(_:)`.
///
/// AppKit refuses `terminate(_:)` before it even asks the app delegate while a presented window
/// reports `preventsApplicationTerminationWhenModal`, and on macOS 27 SwiftUI's sheet window
/// reports YES. With the Run Container sheet open the app stayed running after ⌘Q, and still did
/// after the sheet was dismissed, so the request is cancelled outright, not deferred. Berthly's
/// sheets are cancelable forms, and builds and pulls run independently of them, so none has a
/// reason to block quitting. One app-wide hook covers sheets, alerts, and future sheets without
/// wiring each `.sheet` call site.
enum SheetTerminationPolicy {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, window.isSheet else { return }
                window.preventsApplicationTerminationWhenModal = false
            }
        }
    }
}

// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppKit
import ObjectiveC

/// Drops redundant `-[NSStatusBarButton setImage:]` calls whose image is pixel-identical to
/// the one already set.
///
/// SwiftUI's MenuBarExtra host KVO-observes the app's key/main window
/// (`AppWindowsController.beginObservingNSAppWindows`) and re-applies the status button on
/// every focus change — calling `setImage` with a freshly rendered (but identical) image each
/// time. `NSButtonCell.setImage:` unconditionally invalidates intrinsic content size, marking
/// the status window as needing a constraints pass; when several of those land inside one
/// animated display cycle (e.g. the main window's detail-pane slide), AppKit's feedback-loop
/// guard throws "window has been marked as needing another Update Constraints in Window pass,
/// but it has already had more … than there are views in the window" and crashes. macOS 26
/// enforces that guard strictly. This dispatch point is SwiftUI-internal — no amount of
/// keeping the MenuBarExtra label/content render-stable prevents it (verified with an lldb
/// breakpoint: 83 setImage calls during 10s of main-window interaction with a fully static
/// scene) — so the redundant calls are filtered here instead, before they can touch the
/// layout engine.
///
/// Only `NSStatusBarButton` is patched (in-process that means exactly our menu bar item), and
/// a genuinely different image still passes through, so a future dynamic icon would keep
/// working.
enum StatusButtonImageDedupe {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        let sel = #selector(setter: NSButton.image)
        guard let method = class_getInstanceMethod(NSStatusBarButton.self, sel) else { return }
        typealias SetImageIMP = @convention(c) (NSStatusBarButton, Selector, NSImage?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: SetImageIMP.self)

        let replacement: @convention(block) (NSStatusBarButton, NSImage?) -> Void = { button, image in
            // The status icon is ~18 pt, so the TIFF comparison is a few KB — cheap next to
            // the constraints pass it avoids.
            if let new = image, let current = button.image,
               new.size == current.size,
               let newData = new.tiffRepresentation,
               let currentData = current.tiffRepresentation,
               newData == currentData {
                return
            }
            original(button, sel, image)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}

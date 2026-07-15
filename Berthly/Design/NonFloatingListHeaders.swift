// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppKit
import SwiftUI

/// Stops the `NSTableView` behind a SwiftUI `List` from *floating* its topmost section header.
///
/// macOS pins the first visible section header as a floating group row and draws that floating
/// copy with its own bottom hairline — a full-width rule crossing the gap between the header
/// (RUNNING/NAMED/LOCAL) and the first row. Because AppKit draws it on the floating copy, no
/// SwiftUI modifier reaches it: `.listRowSeparator(.hidden)`, `.listSectionSeparator(.hidden)`,
/// and even `.listStyle(.plain)` all leave it in place (verified by pixel-scanning captures).
/// Only the topmost header floats, which is why the rule appears under the first section and
/// never under later ones. `floatsGroupRows = false` removes the floating copy entirely; the
/// header then scrolls with its section like any other row, and the hairline disappears.
///
/// Attach via `.nonFloatingSectionHeaders()` on the `List`.
struct NonFloatingListHeaders: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view isn't attached to the window (and the List's table may not exist) during the
        // initial sizing pass — defer, then also retry on every update (same rationale as
        // `WindowAccessor` in MenuBarView).
        DispatchQueue.main.async { Self.apply(around: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(around: nsView) }
    }

    /// Finds the `NSTableView` backing the `List` this accessor is attached to. As a
    /// `.background`, the accessor is hosted in a sibling subtree of the list's scroll view, so
    /// walk a few ancestors up and breadth-first search their descendants.
    private static func apply(around view: NSView) {
        var ancestor: NSView? = view
        for _ in 0..<6 {
            guard let current = ancestor else { return }
            if let table = firstTableView(in: current) {
                if table.floatsGroupRows { table.floatsGroupRows = false }
                return
            }
            ancestor = current.superview
        }
    }

    private static func firstTableView(in root: NSView) -> NSTableView? {
        var queue: [NSView] = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let table = view as? NSTableView { return table }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}

extension View {
    /// See `NonFloatingListHeaders`.
    func nonFloatingSectionHeaders() -> some View {
        background(NonFloatingListHeaders())
    }
}

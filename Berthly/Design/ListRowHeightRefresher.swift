// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppKit
import SwiftUI

/// Re-measures a SwiftUI `List`'s row heights after rows move between sections.
///
/// Moving a row across sections is a delete+insert (see `ComputeListView`'s entry wrappers). If
/// anything forces an AppKit layout pass while that insert animation is in flight — the detail
/// pane re-rendering on the same status change is enough — the backing `NSTableView` latches the
/// row's *interim* animation height and keeps it: 24pt instead of 43pt, image subtitle clipped
/// outside the row bounds, surviving every later poll until the list is rebuilt. Both `Text`s are
/// still in the row (and a genuinely one-line row measures 28pt, not 24) — only the table's
/// cached height is wrong, which is why no SwiftUI-side layout fix reaches it: `fixedSize` and
/// disabling the transaction's animations both leave it latched.
///
/// `noteHeightOfRows` makes the table re-query every row height. Registering it through
/// `CATransaction.setCompletionBlock` from `updateNSView` joins the transaction committing the
/// row move, so it runs strictly after that animation finishes — same rationale as
/// `TerminalHostView.scheduleFocusGrab`, where a fixed wall-clock delay proved unreliable
/// whenever a slowed commit pushed the animation past the timer.
///
/// Attach via `.refreshesRowHeights(on:)` with a value that changes whenever rows change section.
struct ListRowHeightRefresher<Trigger: Equatable>: NSViewRepresentable {
    let trigger: Trigger

    func makeNSView(context: Context) -> NSView {
        context.coordinator.lastTrigger = trigger
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Only on an actual section change: re-measuring on every update pass would fire during
        // unrelated redraws (hover, selection, stats ticks) for no benefit.
        guard context.coordinator.lastTrigger != trigger else { return }
        context.coordinator.lastTrigger = trigger
        CATransaction.setCompletionBlock {
            guard let table = Self.table(around: nsView), table.numberOfRows > 0 else { return }
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< table.numberOfRows))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastTrigger: Trigger?
    }

    /// As a `.background`, this sits in a sibling subtree of the list's scroll view — walk a few
    /// ancestors up and search their descendants (same approach as `NonFloatingListHeaders`).
    private static func table(around view: NSView) -> NSTableView? {
        var ancestor: NSView? = view
        for _ in 0 ..< 6 {
            guard let current = ancestor else { return nil }
            if let table = firstTableView(in: current) { return table }
            ancestor = current.superview
        }
        return nil
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
    /// See `ListRowHeightRefresher`.
    func refreshesRowHeights(on trigger: some Equatable) -> some View {
        background(ListRowHeightRefresher(trigger: trigger))
    }
}

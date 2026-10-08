// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation

/// User-chosen order of pinned items, kept apart from pin membership (a `Set`) so existing
/// pins and `pinned-items.json` files stay valid. Ids missing from the order sort after the
/// ordered ones, in the service's own order.
nonisolated enum PinOrder {

    static func sorted<T: Identifiable>(_ items: [T], by order: [String]) -> [T] where T.ID == String {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted { lhs, rhs in
            switch (rank[lhs.element.id], rank[rhs.element.id]) {
            case let (l?, r?): l < r
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// `visible` is the order currently on screen. The result is that order with `sources`
    /// moved before `target` (to the end when nil), followed by remembered ids that are not on
    /// screen right now, so a pin that is briefly absent during a refresh keeps its slot.
    static func moved(visible: [String], sources: [String], before target: String?, remembered: [String]) -> [String] {
        let moving = visible.filter { sources.contains($0) }
        var result = visible.filter { !sources.contains($0) }
        let index = target.flatMap { result.firstIndex(of: $0) } ?? result.endIndex
        result.insert(contentsOf: moving, at: index)
        return result + remembered.filter { !visible.contains($0) }
    }
}

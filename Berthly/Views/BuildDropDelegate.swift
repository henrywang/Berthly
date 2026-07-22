// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI
import UniformTypeIdentifiers

/// What the hover overlay should say while a drag is over the window. Connectivity-only — there is
/// no synchronous filename signal available during a drag (PLAN/PLAN-drag-drop-build.md §3.2/§5.0).
enum BuildDropHoverState {
    case acceptable
    case disconnected
}

/// Presentation-only: no filesystem logic lives here (that's `BuildDropResolver`). Loads dropped
/// `NSItemProvider`s into plain `BuildDropCandidate` values and hands them to `onDrop` — the caller
/// decides what a valid drop means.
struct BuildDropDelegate: DropDelegate {
    @Binding var hoverState: BuildDropHoverState?
    /// True from the moment `performDrop` starts until a fresh drag begins. Guards `dropUpdated`:
    /// empirically, one more `dropUpdated` call can land *after* `performDrop` has already fired
    /// (right as the drag resolves into a drop), which would otherwise re-set `hoverState` right
    /// after `performDrop` cleared it — and since the drag session has already ended by then,
    /// nothing would ever run again to clear it, leaving the overlay stuck until the next drag.
    @Binding var isDropInFlight: Bool
    /// Bumped synchronously, here, the instant a drop starts — not after provider loading
    /// finishes. Loading is async and variable-length, so if generations were assigned on
    /// completion instead, a slow-loading earlier drop could finish after a fast-loading later
    /// one and get assigned the *higher* number, letting it incorrectly win. Assigning at the
    /// start ties generation order to actual drop order, regardless of how long each one takes
    /// to load or resolve.
    @Binding var dropGeneration: Int
    let isConnected: () -> Bool
    let onDrop: (Int, [BuildDropCandidate]) -> Void

    func dropEntered(info: DropInfo) {
        isDropInFlight = false
    }

    func dropExited(info: DropInfo) {
        hoverState = nil
    }

    /// Evaluated fresh on every call (not captured once) so a connectivity change mid-drag is
    /// reflected. Returning `.forbidden` here hard-blocks `performDrop` — confirmed empirically by
    /// the §5.0 spike, not just a cosmetic cursor hint. Once `isDropInFlight` is set, this stops
    /// touching `hoverState` at all — see the property's doc comment.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard !isDropInFlight else {
            return DropProposal(operation: isConnected() ? .copy : .forbidden)
        }
        if isConnected() {
            hoverState = .acceptable
            return DropProposal(operation: .copy)
        }
        hoverState = .disconnected
        return DropProposal(operation: .forbidden)
    }

    /// `DropInfo` is only valid for the duration of this synchronous call, so only the
    /// already-extracted `providers` array is captured into the `Task`, never `info` itself.
    func performDrop(info: DropInfo) -> Bool {
        // Order matters: flip `isDropInFlight` first so a trailing `dropUpdated` can't win the
        // race and re-set `hoverState` right after this clears it.
        isDropInFlight = true
        hoverState = nil
        dropGeneration += 1
        let generation = dropGeneration
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var candidates: [BuildDropCandidate] = []
            for provider in providers {
                candidates.append(await Self.loadCandidate(provider))
            }
            onDrop(generation, candidates)
        }
        return true
    }

    /// Bridges the one `NSItemProvider` completion callback to `async`/`await`. `NSURL.self`, not
    /// `URL.self` — confirmed by the §5.0 spike as the form that actually resolves for a real
    /// Finder file drag.
    private static func loadCandidate(_ provider: NSItemProvider) async -> BuildDropCandidate {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { reading, _ in
                if let url = reading as? URL {
                    continuation.resume(returning: .url(url))
                } else {
                    continuation.resume(returning: .unreadable)
                }
            }
        }
    }
}

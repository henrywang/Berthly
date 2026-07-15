// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

/// A button label whose leading icon becomes a small spinner while its action is in flight.
///
/// The Start/Stop lifecycle buttons on the container and machine detail headers only went
/// `.disabled` while their `startX()`/`stopX()` call was running — a stopped-looking button with
/// no motion reads as "hung", not "working", especially since a real start/stop can take several
/// seconds. Swapping the SF Symbol for a `ProgressView` (kept at `.controlSize(.small)` so it
/// occupies roughly the icon's footprint and the button doesn't jump) makes the in-progress state
/// legible while the surrounding `.disabled(isWorking)` still blocks a second trigger.
struct LifecycleActionLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isWorking: Bool

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        Button {} label: { LifecycleActionLabel(title: "Start", systemImage: "play.fill", isWorking: false) }
            .buttonStyle(.borderedProminent)
        Button {} label: { LifecycleActionLabel(title: "Start", systemImage: "play.fill", isWorking: true) }
            .buttonStyle(.borderedProminent)
            .disabled(true)
        Button {} label: { LifecycleActionLabel(title: "Stop", systemImage: "stop.fill", isWorking: false) }
            .buttonStyle(.bordered)
        Button {} label: { LifecycleActionLabel(title: "Stop", systemImage: "stop.fill", isWorking: true) }
            .buttonStyle(.bordered)
            .disabled(true)
    }
    .padding(40)
}

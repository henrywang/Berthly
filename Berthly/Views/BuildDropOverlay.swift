// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

/// Full-window overlay shown while dragging a file over the main window. `.allowsHitTesting(false)`
/// — it sits on top of everything else in `contentPane` and must not intercept the drag events the
/// underlying `.onDrop` still needs, or ordinary clicks once it's gone.
struct BuildDropHoverOverlay: View {
    let state: BuildDropHoverState

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(spacing: 12) {
                Image(systemName: state == .disconnected ? "xmark.circle.fill" : "hammer.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(state == .disconnected ? Color.red : Color.berthlyAccent)
                Text(message)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .allowsHitTesting(false)
    }

    private var message: String {
        switch state {
        case .acceptable:   "Drop to build an image"
        case .disconnected: "Connect to the container service to build."
        }
    }
}

/// Transient rejection message shown after a drop that couldn't be used to build. Auto-dismisses on
/// a timer (see `MainWindowView.showDropRejection`), so `.allowsHitTesting(false)` keeps it from
/// blocking clicks on whatever's underneath while it fades out.
struct BuildDropRejectionBanner: View {
    let message: String

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.callout)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 8)
            .padding(.bottom, 24)
        }
        .allowsHitTesting(false)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

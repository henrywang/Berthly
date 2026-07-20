// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

// MARK: - Image update badge

/// Marks an image whose registry has a newer digest for its tag — shown next to `UsageBadge` on
/// the image row. Accent (not the amber caution tint): unlike "used by", this badge is an
/// invitation to act (Pull Latest), and accent is this codebase's interactive color.
struct UpdateAvailableBadge: View {
    let image: ContainerImage

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.up.circle.fill")
                .imageScale(.small)
            Text("update")
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.berthlyAccent)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.berthlyAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
        .help("A newer image is published for \(image.fullName)")
        .accessibilityIdentifier("imageUpdateBadge-\(image.id)")
    }
}

// MARK: - Container staleness glyph

/// Marks a container lagging its image tag, next to the image reference on the compute row and
/// the detail header. A bare glyph, not a text pill: the row's trailing area is already
/// contended (ports/hover actions), and the `.help` text carries the which-kind distinction.
struct ContainerStalenessGlyph: View {
    let staleness: ContainerImageStaleness
    let containerName: String

    var body: some View {
        if staleness != .current {
            Image(systemName: "arrow.up.circle.fill")
                .imageScale(.small)
                .foregroundStyle(Color.berthlyAccent)
                .help(staleness == .remoteUpdateAvailable
                      ? "Update available — pull and recreate to apply it"
                      : "A newer image was pulled — recreate the container to apply it")
                .accessibilityIdentifier("containerUpdateBadge-\(containerName)")
        }
    }
}

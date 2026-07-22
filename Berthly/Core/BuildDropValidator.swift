// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

/// Filename rule for drag-and-drop build (see PLAN/PLAN-drag-drop-build.md §4). Matches on the
/// candidate's own last path component only — never file content, never a resolved symlink
/// target's name.
nonisolated enum BuildDropValidator {
    static func isDockerfileLike(_ filename: String) -> Bool {
        let lowered = filename.lowercased()
        return lowered == "dockerfile"
            || lowered == "containerfile"
            || lowered.hasPrefix("dockerfile.")
            || lowered.hasPrefix("containerfile.")
            || lowered.hasSuffix(".dockerfile")
            || lowered.hasSuffix(".containerfile")
    }
}

// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation

/// A single dropped item, already loaded from its `NSItemProvider` (see
/// `BuildDropDelegate.performDrop`). `.unreadable` preserves a failed load instead of dropping it
/// silently, so `resolve(candidates:)` can tell "nothing here was ever readable" apart from "one
/// file failed, but a later one was a valid Dockerfile" (PLAN/PLAN-drag-drop-build.md §3.3 step 7).
nonisolated enum BuildDropCandidate: Sendable {
    case url(URL)
    case unreadable
}

/// The build context/Dockerfile path resolved from a successful drop — the resolved target's
/// parent directory and its own resolved path, not the (possibly symlinked) dropped item's.
nonisolated struct BuildDropResolution: Sendable, Equatable {
    let contextPath: String
    let dockerfilePath: String
}

/// Why no candidate resolved to a usable Dockerfile. `.unsupportedFile` takes precedence over
/// `.unreadableFile` when both occurred in the same drop — see `resolve(candidates:)`.
nonisolated enum BuildDropRejection: Sendable, Error, Equatable {
    case unsupportedFile
    case unreadableFile
}

/// Walks dropped-file candidates and picks the first one that is a real Dockerfile/Containerfile
/// (PLAN/PLAN-drag-drop-build.md §3.3 steps 2–5). Runs off the main actor — a slow or
/// network-mounted volume must not freeze the drag — so every member here is `nonisolated` and
/// touches only local, synchronous filesystem APIs.
nonisolated enum BuildDropResolver {
    static func resolve(candidates: [BuildDropCandidate]) -> Result<BuildDropResolution, BuildDropRejection> {
        var sawUnsupported = false

        for candidate in candidates {
            guard case .url(let url) = candidate else {
                continue
            }

            // Validate the dropped item's own visible name — never the resolved symlink target's
            // — before touching the filesystem any further (the symlink policy in §3.3).
            guard BuildDropValidator.isDockerfileLike(url.lastPathComponent) else {
                sawUnsupported = true
                continue
            }

            let resolved = url.resolvingSymlinksInPath()

            // A broken symlink's target doesn't exist, so `resolvingSymlinksInPath()` above leaves
            // it unresolved (still pointing at the symlink's own path) rather than throwing —
            // verified empirically, since neither `resourceValues(forKeys:)` nor
            // `checkResourceIsReachable()` throws for it either. `fileExists` is what actually
            // tells a missing target apart from a real (if wrong-typed) file.
            guard FileManager.default.fileExists(atPath: resolved.path) else {
                continue
            }

            let resourceValues: URLResourceValues
            do {
                resourceValues = try resolved.resourceValues(forKeys: [.isRegularFileKey])
            } catch {
                continue
            }

            guard resourceValues.isRegularFile == true else {
                sawUnsupported = true
                continue
            }

            return .success(BuildDropResolution(
                contextPath: resolved.deletingLastPathComponent().path(percentEncoded: false),
                dockerfilePath: resolved.path(percentEncoded: false)
            ))
        }

        return .failure(sawUnsupported ? .unsupportedFile : .unreadableFile)
    }
}

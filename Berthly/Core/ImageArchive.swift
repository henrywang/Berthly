// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerizationOCI
import Foundation

/// Default filename for saving an image as a tar archive: the reference's last name component
/// plus its tag/digest identifier, filesystem-safe. `docker.io/library/alpine:latest` →
/// `alpine_latest.tar`; a digest-only reference keeps a short digest prefix so two untagged
/// pulls don't suggest the same name.
nonisolated func suggestedArchiveFilename(for reference: String) -> String {
    let trimmed = reference.trimmingCharacters(in: .whitespaces)
    var base = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    var identifier: String?
    if let at = base.firstIndex(of: "@") {
        let digest = String(base[base.index(after: at)...])
        base = String(base[..<at])
        let hex = digest.hasPrefix("sha256:") ? String(digest.dropFirst(7)) : digest
        identifier = String(hex.prefix(12))
    } else if let colon = base.firstIndex(of: ":") {
        identifier = String(base[base.index(after: colon)...])
        base = String(base[..<colon])
    }
    if base.isEmpty { base = "image" }
    let stem = ([base] + (identifier.map { [$0] } ?? [])).joined(separator: "_")
    let sanitized = stem.map { ch -> Character in
        ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "." ? ch : "_"
    }
    return String(sanitized) + ".tar"
}

/// Why a tag target can't (or shouldn't silently) be used, checked before the daemon round-trip.
nonisolated enum TagTargetIssue: Equatable {
    /// Malformed reference — blocks the Tag button. Carries the user-facing explanation.
    case invalid(String)
    /// Parses fine but an existing local reference has this name; tagging replaces it (a name
    /// points at exactly one piece of content). Allowed, but worth a warning.
    case replacesExisting
}

/// Pre-flight validation for the tag sheet, using the same `Reference.parse` the daemon-side
/// normalization runs. `nil` means the target is usable with no caveats. An empty/whitespace
/// target returns `nil` too — the sheet disables Tag separately for that, without an error to read.
nonisolated func tagTargetIssue(_ target: String, existingReferences: [String]) -> TagTargetIssue? {
    let trimmed = target.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    guard let parsed = try? Reference.parse(trimmed) else {
        return .invalid("Not a valid reference. Use lowercase name[:tag], e.g. team/web:2.0.")
    }
    if parsed.digest != nil {
        return .invalid("A tag is a name, not a digest — drop the @sha256:… part.")
    }
    parsed.normalize()
    if existingReferences.contains(trimmed) || existingReferences.contains(parsed.description) {
        return .replacesExisting
    }
    return nil
}

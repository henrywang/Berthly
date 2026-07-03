// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation

/// Compares the installed `container` daemon's version against the version Berthly is built
/// against. `container`'s own README states patch releases are compatible but minor releases may
/// include breaking changes until 1.0.0 stabilizes, so compatibility is major.minor equality,
/// patch-agnostic.
enum ContainerCompatibility {
    /// Keep in sync with the `container` SPM package pin (Package.resolved / Package.swift).
    static let requiredVersion = "1.0.0"

    static func isCompatible(installed: String, required: String = requiredVersion) -> Bool {
        guard let installedComponents = majorMinor(of: installed),
              let requiredComponents = majorMinor(of: required) else {
            return false
        }
        return installedComponents == requiredComponents
    }

    /// The health-check ping's `apiServerVersion` isn't a bare version string — it's
    /// `ReleaseVersion.singleLine(appName:)`'s output, e.g. "container-apiserver version 1.0.0
    /// (build: release, commit: abc1234)". Pull the numeric version out of that (or any other
    /// surrounding text) rather than assuming the whole field is already a clean semver — a naive
    /// split on "-" mis-parses "container-apiserver"'s own hyphen.
    static func extractVersion(from raw: String) -> String? {
        guard let range = raw.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else {
            return nil
        }
        return String(raw[range])
    }

    private static func majorMinor(of version: String) -> [Int]? {
        guard let extracted = extractVersion(from: version) else { return nil }
        let parts = extracted.split(separator: ".").prefix(2).compactMap { Int($0) }
        return parts.count == 2 ? parts : nil
    }
}

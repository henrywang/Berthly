// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation

/// Compares the installed `container` daemon's version against the version Berthly is built
/// against. Post-1.0, `container` follows semver: a daemon with the same major version but a
/// newer minor is additive and safe to talk to, an older daemon may lack APIs this client calls,
/// and a different major may break the wire protocol. So compatibility is: same major, and
/// installed minor >= required minor. Patch releases are ignored.
enum ContainerCompatibility {
    /// Keep in sync with the `container` SPM package pin (Package.resolved / Package.swift).
    static let requiredVersion = "1.1.0"

    /// How an incompatible install relates to the required version. `tooOld` is fixable in place
    /// with the upstream update script; `tooNew` (newer major) is not — downgrading requires a
    /// full uninstall, so the only safe advice is to update Berthly instead.
    enum Mismatch: Equatable {
        case tooOld
        case tooNew
    }

    static func isCompatible(installed: String, required: String = requiredVersion) -> Bool {
        mismatch(installed: installed, required: required) == nil
    }

    /// Returns `nil` when compatible. Unparseable versions are `tooOld` — the safe assumption,
    /// since the fix it triggers (reinstall the pinned version) is valid either way.
    static func mismatch(installed: String, required: String = requiredVersion) -> Mismatch? {
        guard let installedComponents = majorMinor(of: installed),
              let requiredComponents = majorMinor(of: required) else {
            return .tooOld
        }
        if installedComponents[0] != requiredComponents[0] {
            return installedComponents[0] > requiredComponents[0] ? .tooNew : .tooOld
        }
        return installedComponents[1] >= requiredComponents[1] ? nil : .tooOld
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

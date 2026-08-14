// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Berthly

struct ContainerCompatibilityTests {

    @Test func exactMatchIsCompatible() {
        #expect(ContainerCompatibility.isCompatible(installed: "1.1.0", required: "1.1.0"))
    }

    @Test func patchDifferenceIsCompatible() {
        #expect(ContainerCompatibility.isCompatible(installed: "1.1.7", required: "1.1.0"))
        #expect(ContainerCompatibility.isCompatible(installed: "1.1.0", required: "1.1.3"))
    }

    // Post-1.0 semver: a daemon with a newer minor is additive and safe for this client.
    @Test func newerMinorIsCompatible() {
        #expect(ContainerCompatibility.isCompatible(installed: "1.2.0", required: "1.1.0"))
    }

    @Test func olderMinorIsIncompatible() {
        #expect(!ContainerCompatibility.isCompatible(installed: "1.0.4", required: "1.1.0"))
    }

    @Test func majorDifferenceIsIncompatible() {
        #expect(!ContainerCompatibility.isCompatible(installed: "2.0.0", required: "1.1.0"))
        #expect(!ContainerCompatibility.isCompatible(installed: "0.9.0", required: "1.1.0"))
    }

    @Test func untaggedBuildSuffixIsIgnored() {
        #expect(ContainerCompatibility.isCompatible(installed: "1.1.0-3-gabcdef", required: "1.1.0"))
    }

    @Test func malformedVersionIsIncompatible() {
        #expect(!ContainerCompatibility.isCompatible(installed: "not-a-version", required: "1.1.0"))
    }

    // Mismatch direction decides which gate the user sees: tooOld offers the in-place update,
    // tooNew must never touch the install (upstream can't downgrade in place).
    @Test func mismatchIsNilWhenCompatible() {
        #expect(ContainerCompatibility.mismatch(installed: "1.1.0", required: "1.1.0") == nil)
        #expect(ContainerCompatibility.mismatch(installed: "1.2.0", required: "1.1.0") == nil)
    }

    @Test func mismatchOlderMinorIsTooOld() {
        #expect(ContainerCompatibility.mismatch(installed: "1.0.4", required: "1.1.0") == .tooOld)
    }

    @Test func mismatchOlderMajorIsTooOld() {
        #expect(ContainerCompatibility.mismatch(installed: "0.9.0", required: "1.1.0") == .tooOld)
    }

    @Test func mismatchNewerMajorIsTooNew() {
        #expect(ContainerCompatibility.mismatch(installed: "2.0.0", required: "1.1.0") == .tooNew)
    }

    // A newer minor within the same major is compatible, so the only way "newer" mismatches is
    // by major — there is no tooNew inside major 1.
    @Test func mismatchMalformedIsTooOld() {
        #expect(ContainerCompatibility.mismatch(installed: "garbage", required: "1.1.0") == .tooOld)
    }

    // Regression: `apiServerVersion` from the health-check ping is `ReleaseVersion.singleLine`'s
    // full descriptive output, not a bare semver — "container-apiserver" contains its own hyphen,
    // which previously broke a naive split(separator: "-") into treating "container" as the version.
    @Test func realApiServerVersionStringIsCompatible() {
        #expect(ContainerCompatibility.isCompatible(
            installed: "container-apiserver version 1.0.0 (build: release, commit: abc1234)",
            required: "1.0.0"
        ))
    }

    @Test func extractVersionPullsNumberOutOfDescriptiveString() {
        #expect(ContainerCompatibility.extractVersion(
            from: "container-apiserver version 1.0.0 (build: release, commit: abc1234)"
        ) == "1.0.0")
    }

    @Test func extractVersionReturnsNilWhenNoVersionPresent() {
        #expect(ContainerCompatibility.extractVersion(from: "not-a-version") == nil)
    }

    // isAtLeast is patch-precise, unlike isCompatible/mismatch's major.minor-only floor — for
    // gating a capability that landed in a specific patch release (e.g. running-container export,
    // added in 1.2.1) rather than overall daemon compatibility.
    @Test func isAtLeastExactMatchIsTrue() {
        #expect(ContainerCompatibility.isAtLeast(installed: "1.2.1", "1.2.1"))
    }

    @Test func isAtLeastNewerPatchIsTrue() {
        #expect(ContainerCompatibility.isAtLeast(installed: "1.2.2", "1.2.1"))
    }

    @Test func isAtLeastOlderPatchIsFalse() {
        #expect(!ContainerCompatibility.isAtLeast(installed: "1.2.0", "1.2.1"))
    }

    @Test func isAtLeastNewerMinorIsTrue() {
        #expect(ContainerCompatibility.isAtLeast(installed: "1.3.0", "1.2.1"))
    }

    @Test func isAtLeastOlderMajorIsFalse() {
        #expect(!ContainerCompatibility.isAtLeast(installed: "0.9.0", "1.2.1"))
    }

    @Test func isAtLeastMalformedIsFalse() {
        #expect(!ContainerCompatibility.isAtLeast(installed: "garbage", "1.2.1"))
    }
}

import Foundation
import Testing
@testable import Berthly

// MARK: - Archive filename suggestion

struct SuggestedArchiveFilenameTests {

    @Test func tagBecomesSuffix() {
        #expect(suggestedArchiveFilename(for: "alpine:latest") == "alpine_latest.tar")
        #expect(suggestedArchiveFilename(for: "local/web:1.4") == "web_1.4.tar")
    }

    @Test func hostAndNamespacesAreDropped() {
        #expect(suggestedArchiveFilename(for: "docker.io/library/alpine:latest") == "alpine_latest.tar")
        #expect(suggestedArchiveFilename(for: "ghcr.io/org/team/app:2.0") == "app_2.0.tar")
    }

    @Test func registryPortIsNotMistakenForATag() {
        // The `:5000` belongs to the host segment, which is dropped with the rest of the path.
        #expect(suggestedArchiveFilename(for: "registry.local:5000/team/web:1.4") == "web_1.4.tar")
    }

    @Test func untaggedReferenceHasNoSuffix() {
        #expect(suggestedArchiveFilename(for: "web") == "web.tar")
    }

    @Test func digestReferenceKeepsAShortDigest() {
        let name = suggestedArchiveFilename(for: "web@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        #expect(name == "web_0123456789ab.tar")
    }

    @Test func unsafeCharactersAreSanitized() {
        // A tag can contain no `/`, but be defensive about anything odd that slips through.
        #expect(!suggestedArchiveFilename(for: "web:a/b").contains("/"))
    }

    @Test func emptyInputStillProducesAName() {
        #expect(suggestedArchiveFilename(for: "") == "image.tar")
    }
}

// MARK: - Tag target validation

struct TagTargetIssueTests {

    private let existing = ["local/web:1.4", "local/api:2.1"]

    @Test func validNewReferenceHasNoIssue() {
        #expect(tagTargetIssue("local/web:2.0", existingReferences: existing) == nil)
        #expect(tagTargetIssue("ghcr.io/org/app:1.0", existingReferences: existing) == nil)
    }

    @Test func emptyTargetIsNotAnError() {
        // The sheet disables Tag for an empty field; there's nothing to explain.
        #expect(tagTargetIssue("", existingReferences: existing) == nil)
        #expect(tagTargetIssue("   ", existingReferences: existing) == nil)
    }

    @Test func malformedReferencesAreInvalid() {
        // OCI repository names must be lowercase.
        #expect(isInvalid(tagTargetIssue("local/Web:2.0", existingReferences: existing)))
        #expect(isInvalid(tagTargetIssue("local/web:tag with spaces", existingReferences: existing)))
    }

    @Test func digestTargetsAreInvalid() {
        let digest = "web@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        #expect(isInvalid(tagTargetIssue(digest, existingReferences: existing)))
    }

    @Test func existingReferenceWarnsAboutReplacement() {
        #expect(tagTargetIssue("local/web:1.4", existingReferences: existing) == .replacesExisting)
    }

    @Test func normalizationIsAppliedBeforeTheDuplicateCheck() {
        // `local/api` normalizes to `local/api:latest`; if that name exists, warn.
        #expect(tagTargetIssue("local/api", existingReferences: ["local/api:latest"]) == .replacesExisting)
    }

    private func isInvalid(_ issue: TagTargetIssue?) -> Bool {
        if case .invalid = issue { return true }
        return false
    }
}

// MARK: - Mock service behavior (what the sheets rely on)

@MainActor
struct MockImageTagSaveLoadTests {

    @Test func tagCreatesASecondNameSharingTheDigest() async throws {
        let mock = MockContainerService()
        let source = mock.images[0]
        let countBefore = mock.images.count

        let created = try await mock.tagImage(reference: source.fullName, newReference: "local/web:2.0")

        #expect(created == "local/web:2.0")
        #expect(mock.images.count == countBefore + 1)
        let tagged = try #require(mock.images.first { $0.fullName == "local/web:2.0" })
        #expect(tagged.digest == source.digest)
        // The source row is untouched.
        #expect(mock.images.contains { $0.fullName == source.fullName })
    }

    @Test func tagOntoAnExistingNameReplacesItInsteadOfDuplicatingTheID() async throws {
        let mock = MockContainerService()
        let source = mock.images[0]
        let victim = mock.images[1]
        let countBefore = mock.images.count

        try await mock.tagImage(reference: source.fullName, newReference: victim.fullName)

        #expect(mock.images.count == countBefore)
        #expect(mock.images.filter { $0.id == victim.id }.count == 1)
        let replaced = try #require(mock.images.first { $0.fullName == victim.fullName })
        #expect(replaced.digest == source.digest)
    }

    @Test func tagOfAMissingSourceThrows() async {
        let mock = MockContainerService()
        await #expect(throws: ContainerCLIError.self) {
            try await mock.tagImage(reference: "nope:missing", newReference: "web:2.0")
        }
    }

    @Test func saveRecordsTheRequest() async throws {
        let mock = MockContainerService()
        let reference = mock.images[0].fullName

        try await mock.saveImages(references: [reference], to: "/tmp/out.tar")

        #expect(mock.lastImageSave?.references == [reference])
        #expect(mock.lastImageSave?.path == "/tmp/out.tar")
    }

    @Test func saveOfAMissingImageThrows() async {
        let mock = MockContainerService()
        await #expect(throws: ContainerCLIError.self) {
            try await mock.saveImages(references: ["nope:missing"], to: "/tmp/out.tar")
        }
    }

    @Test func loadRoundTripsTheSaveFlowFilename() async throws {
        let mock = MockContainerService()

        let summary = try await mock.loadImages(from: "/tmp/alpine_latest.tar")

        #expect(summary.loadedReferences == ["alpine:latest"])
        #expect(summary.rejectedMembers.isEmpty)
        #expect(mock.images.contains { $0.fullName == "alpine:latest" })
    }

    @Test func loadReportsUnpackProgress() async throws {
        let mock = MockContainerService()
        let progress = TransferProgressState.load()

        _ = try await mock.loadImages(from: "/tmp/alpine_latest.tar", progress: progress.handler)

        #expect(progress.totalItems > 0)
        #expect(progress.completedItems == progress.totalItems)
        #expect(progress.fraction == 1.0)
    }
}

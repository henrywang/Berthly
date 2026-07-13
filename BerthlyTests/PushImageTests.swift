import Testing
@testable import Berthly

@MainActor
struct PushImageTests {

    /// Regression test for the exact bug this feature shipped once: pushing to a new destination
    /// retags (same content, new local name), which — before `ContainerImage.id` was changed to
    /// track the local reference instead of the shared content digest — produced two rows with the
    /// same SwiftUI identity and made the Images list crash ("the ID ... occurs multiple times").
    @Test func retagOnPushProducesDistinctIdsSharingOneDigest() async throws {
        let mock = MockContainerService()
        let source = try #require(mock.images.first { $0.fullName == "local/web:1.4" })

        try await mock.pushImage(reference: source.fullName, destination: "ghcr.io/user/web:1.4")

        let pushed = try #require(mock.images.first { $0.fullName == "ghcr.io/user/web:1.4" })
        #expect(pushed.id != source.id)
        #expect(pushed.digest == source.digest)
        // Both rows must still be present and distinguishable — that's the actual regression this
        // guards: a shared digest must never collapse the two into one list identity.
        #expect(mock.images.filter { $0.digest == source.digest }.count == 2)
    }

    /// Pushing back onto the *same* name (no retag) must not duplicate the row.
    @Test func pushWithoutRetagDoesNotDuplicate() async throws {
        let mock = MockContainerService()
        let before = mock.images.count
        try await mock.pushImage(reference: "local/web:1.4", destination: "local/web:1.4")
        #expect(mock.images.count == before)
    }

    /// Retagging onto an existing destination name replaces that entry rather than appending a
    /// second row sharing its id — a name always points at exactly one piece of content.
    @Test func retagOntoExistingDestinationReplacesNotAppends() async throws {
        let mock = MockContainerService()
        let before = mock.images.count
        try await mock.pushImage(reference: "local/api:2.1", destination: "local/web:1.4")
        #expect(mock.images.count == before)
        let replaced = try #require(mock.images.first { $0.fullName == "local/web:1.4" })
        #expect(replaced.digest == mock.images.first { $0.fullName == "local/api:2.1" }?.digest)
    }
}

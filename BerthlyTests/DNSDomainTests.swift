// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Berthly

/// Local DNS domain management (`container system dns`): the list is parsed from `/etc/resolver`
/// filenames, and every mutation costs the user an admin-password prompt — so the pre-flight
/// validation (catch typos *before* the prompt) and the exact elevated command line are the
/// pieces that earn tests.
struct DNSDomainTests {

    // MARK: - Filename → domain parsing

    @Test func parsesOnlyContainerizationPrefixedResolverFiles() {
        let domains = LiveContainerService.dnsDomains(fromResolverFilenames: [
            "containerization.test",
            "containerization.dev.internal",
            "corp-vpn",           // someone else's resolver file
            "openvpn.split",      // no containerization prefix
        ])
        #expect(domains == ["dev.internal", "test"])  // ours only, sorted
    }

    @Test func ignoresABarePrefixFileWithNoDomain() {
        // A file named exactly "containerization." would otherwise yield an empty domain row.
        let domains = LiveContainerService.dnsDomains(fromResolverFilenames: ["containerization."])
        #expect(domains.isEmpty)
    }

    @Test func emptyResolverDirectoryYieldsNoDomains() {
        #expect(LiveContainerService.dnsDomains(fromResolverFilenames: []).isEmpty)
    }

    // MARK: - Domain validation (pre-flight, before the admin prompt)

    @Test func acceptsTypicalDomains() {
        #expect(LiveContainerService.validateDNSDomainName("test") == nil)
        #expect(LiveContainerService.validateDNSDomainName("dev.internal") == nil)
        #expect(LiveContainerService.validateDNSDomainName("my-app.local2") == nil)
        #expect(LiveContainerService.validateDNSDomainName("  test  ") == nil)  // trimmed
    }

    @Test func rejectsEmptyAndWhitespaceOnly() {
        #expect(LiveContainerService.validateDNSDomainName("") != nil)
        #expect(LiveContainerService.validateDNSDomainName("   ") != nil)
    }

    @Test func rejectsStrayDots() {
        #expect(LiveContainerService.validateDNSDomainName(".test") != nil)
        #expect(LiveContainerService.validateDNSDomainName("test.") != nil)
        #expect(LiveContainerService.validateDNSDomainName("a..b") != nil)
    }

    @Test func rejectsIllegalCharactersAndHyphenPlacement() {
        #expect(LiveContainerService.validateDNSDomainName("has space") != nil)
        #expect(LiveContainerService.validateDNSDomainName("under_score") != nil)
        #expect(LiveContainerService.validateDNSDomainName("-leading") != nil)
        #expect(LiveContainerService.validateDNSDomainName("trailing-") != nil)
        #expect(LiveContainerService.validateDNSDomainName("mid-dle") == nil)
    }

    @Test func rejectsOverlongNamesAndLabels() {
        let longLabel = String(repeating: "a", count: 64)
        #expect(LiveContainerService.validateDNSDomainName(longLabel) != nil)
        #expect(LiveContainerService.validateDNSDomainName(String(repeating: "a", count: 63)) == nil)

        let longName = Array(repeating: String(repeating: "a", count: 63), count: 5).joined(separator: ".")
        #expect(longName.count > 253)
        #expect(LiveContainerService.validateDNSDomainName(longName) != nil)
    }

    // MARK: - Elevated command construction

    @Test func buildsQuotedCreateAndDeleteCommands() {
        #expect(LiveContainerService.dnsCreateShellCommand(domain: "test")
                == "container system dns create 'test'")
        #expect(LiveContainerService.dnsDeleteShellCommand(domain: "dev.internal")
                == "container system dns delete 'dev.internal'")
    }

    // MARK: - Mock service behavior (what previews/UI tests run against)

    @MainActor
    @Test func mockCreateAppendsSortedAndRejectsDuplicates() async throws {
        let mock = MockContainerService()
        await mock.fetchDNSDomains()
        #expect(mock.dnsDomains == ["test"])

        try await mock.createDNSDomain("alpha")
        #expect(mock.dnsDomains == ["alpha", "test"])

        await #expect(throws: (any Error).self) {
            try await mock.createDNSDomain("alpha")
        }
        await #expect(throws: (any Error).self) {
            try await mock.createDNSDomain("bad name")
        }
    }

    @MainActor
    @Test func mockDeleteRemovesTheDomain() async throws {
        let mock = MockContainerService()
        await mock.fetchDNSDomains()
        try await mock.deleteDNSDomain("test")
        #expect(mock.dnsDomains == [])
    }
}

// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Berthly

struct CopyArgumentsTests {

    @Test func intoContainerKeepsHostAsSource() {
        let (source, destination) = LiveContainerService.copyArguments(
            direction: .intoContainer, hostPath: "/Users/me/report.pdf", containerPath: "/app/docs")
        #expect(source == "/Users/me/report.pdf")
        #expect(destination == "/app/docs")
    }

    @Test func outOfContainerSwapsSourceAndDestination() {
        let (source, destination) = LiveContainerService.copyArguments(
            direction: .outOfContainer, hostPath: "/Users/me/Downloads/app.log", containerPath: "/var/log/app.log")
        // The container path is the source when pulling *out*; getting this backwards is the bug
        // this test exists to catch.
        #expect(source == "/var/log/app.log")
        #expect(destination == "/Users/me/Downloads/app.log")
    }
}

struct ResolvedHostDestinationTests {

    @Test func appendsContainerSourceBasenameToFolder() {
        let dest = LiveContainerService.resolvedHostDestination(
            folder: "/Users/me/Downloads", containerSource: "/var/log/app.log")
        #expect(dest == "/Users/me/Downloads/app.log")
    }

    @Test func usesLastComponentForDirectorySources() {
        // Copying a folder out: the target is folder/<dirname>, not folder/ itself.
        let dest = LiveContainerService.resolvedHostDestination(
            folder: "/Users/me/Desktop", containerSource: "/etc/nginx")
        #expect(dest == "/Users/me/Desktop/nginx")
    }

    @Test func trailingSlashOnSourceStillYieldsName() {
        let dest = LiveContainerService.resolvedHostDestination(
            folder: "/tmp", containerSource: "/var/data/")
        #expect(dest == "/tmp/data")
    }
}

@MainActor
struct CopyFilesServiceTests {

    @Test func mockRecordsCopyInvocation() async throws {
        let service = MockContainerService()
        try await service.copyFiles(
            direction: .outOfContainer, containerID: "abc123",
            hostPath: "/Users/me/out.txt", containerPath: "/tmp/out.txt")

        let last = try #require(service.lastCopy)
        #expect(last.direction == .outOfContainer)
        #expect(last.containerID == "abc123")
        #expect(last.hostPath == "/Users/me/out.txt")
        #expect(last.containerPath == "/tmp/out.txt")
    }
}

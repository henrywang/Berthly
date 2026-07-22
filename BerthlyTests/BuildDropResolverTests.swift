// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Berthly

struct BuildDropResolverTests {

    /// A fresh temp directory per test, torn down after — real files/symlinks on disk, since this
    /// layer does actual filesystem work (§3.3 steps 2–5).
    private func withTempDir(_ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildDropResolverTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test func validDropResolvesContextAndDockerfilePath() throws {
        try withTempDir { dir in
            let dockerfile = dir.appendingPathComponent("Dockerfile")
            try "FROM scratch".write(to: dockerfile, atomically: true, encoding: .utf8)

            let result = BuildDropResolver.resolve(candidates: [.url(dockerfile)])

            switch result {
            case .success(let resolution):
                #expect(resolution.contextPath == dockerfile.deletingLastPathComponent().path(percentEncoded: false))
                #expect(resolution.dockerfilePath == dockerfile.path(percentEncoded: false))
            case .failure(let rejection):
                Issue.record("expected success, got \(rejection)")
            }
        }
    }

    @Test func directoryNamedDockerfileIsUnsupported() throws {
        try withTempDir { dir in
            let fakeDockerfile = dir.appendingPathComponent("Dockerfile")
            try FileManager.default.createDirectory(at: fakeDockerfile, withIntermediateDirectories: true)

            let result = BuildDropResolver.resolve(candidates: [.url(fakeDockerfile)])

            #expect(result == .failure(.unsupportedFile))
        }
    }

    @Test func nonMatchingNameIsUnsupportedRegardlessOfContent() throws {
        try withTempDir { dir in
            let readme = dir.appendingPathComponent("README.md")
            try "FROM scratch".write(to: readme, atomically: true, encoding: .utf8)

            let result = BuildDropResolver.resolve(candidates: [.url(readme)])

            #expect(result == .failure(.unsupportedFile))
        }
    }

    @Test func symlinkNamedDockerfilePointingAtOtherFileIsAccepted() throws {
        try withTempDir { dir in
            let target = dir.appendingPathComponent("README.md")
            try "not really a Dockerfile".write(to: target, atomically: true, encoding: .utf8)
            let link = dir.appendingPathComponent("Dockerfile")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            let result = BuildDropResolver.resolve(candidates: [.url(link)])

            switch result {
            case .success(let resolution):
                #expect(resolution.dockerfilePath == target.resolvingSymlinksInPath().path(percentEncoded: false))
                #expect(resolution.contextPath == dir.resolvingSymlinksInPath().path(percentEncoded: false))
            case .failure(let rejection):
                Issue.record("expected success, got \(rejection)")
            }
        }
    }

    @Test func symlinkWithNonMatchingNamePointingAtDockerfileIsRejected() throws {
        try withTempDir { dir in
            let target = dir.appendingPathComponent("Dockerfile")
            try "FROM scratch".write(to: target, atomically: true, encoding: .utf8)
            let link = dir.appendingPathComponent("build-file")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            let result = BuildDropResolver.resolve(candidates: [.url(link)])

            #expect(result == .failure(.unsupportedFile))
        }
    }

    @Test func brokenSymlinkNamedDockerfileIsUnreadable() throws {
        try withTempDir { dir in
            let missingTarget = dir.appendingPathComponent("does-not-exist")
            let link = dir.appendingPathComponent("Dockerfile")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missingTarget)

            let result = BuildDropResolver.resolve(candidates: [.url(link)])

            #expect(result == .failure(.unreadableFile))
        }
    }

    @Test func firstValidCandidateInOrderWins() throws {
        try withTempDir { dir in
            let readme = dir.appendingPathComponent("README.md")
            try "irrelevant".write(to: readme, atomically: true, encoding: .utf8)
            let first = dir.appendingPathComponent("Dockerfile")
            try "FROM scratch AS first".write(to: first, atomically: true, encoding: .utf8)
            let secondDir = dir.appendingPathComponent("second")
            try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
            let second = secondDir.appendingPathComponent("Containerfile")
            try "FROM scratch AS second".write(to: second, atomically: true, encoding: .utf8)

            let result = BuildDropResolver.resolve(candidates: [.url(readme), .url(first), .url(second)])

            switch result {
            case .success(let resolution):
                #expect(resolution.dockerfilePath == first.path(percentEncoded: false))
            case .failure(let rejection):
                Issue.record("expected success, got \(rejection)")
            }
        }
    }

    @Test func unreadableCandidateFollowedByValidOneStillResolves() throws {
        try withTempDir { dir in
            let dockerfile = dir.appendingPathComponent("Dockerfile")
            try "FROM scratch".write(to: dockerfile, atomically: true, encoding: .utf8)

            let result = BuildDropResolver.resolve(candidates: [.unreadable, .url(dockerfile)])

            switch result {
            case .success(let resolution):
                #expect(resolution.dockerfilePath == dockerfile.path(percentEncoded: false))
            case .failure(let rejection):
                Issue.record("expected success, got \(rejection)")
            }
        }
    }

    @Test func allUnreadableCandidatesYieldsUnreadableFile() {
        let result = BuildDropResolver.resolve(candidates: [.unreadable, .unreadable])
        #expect(result == .failure(.unreadableFile))
    }

    @Test func unreadablePlusUnsupportedYieldsUnsupportedFile() throws {
        try withTempDir { dir in
            let readme = dir.appendingPathComponent("README.md")
            try "irrelevant".write(to: readme, atomically: true, encoding: .utf8)

            let result = BuildDropResolver.resolve(candidates: [.unreadable, .url(readme)])

            #expect(result == .failure(.unsupportedFile))
        }
    }
}

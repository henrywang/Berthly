// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Berthly

struct LocalFileHardeningTests {

    @Test func persistedApplicationDataIsOwnerOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try LiveContainerService.writePrivateData(Data("{}".utf8), to: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == "{}")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func cidFileIsOwnerOnlyAndNeverOverwrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("container.cid")

        try LiveContainerService.writeCIDFile("first-id", to: url.path)
        #expect(try String(contentsOf: url, encoding: .utf8) == "first-id")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(throws: (any Error).self) {
            try LiveContainerService.writeCIDFile("second-id", to: url.path)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "first-id")
    }
}

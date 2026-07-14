// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Berthly

/// Only the pure start-gate is unit-tested. Constructing `UpdaterService` itself spawns a real
/// `SPUStandardUpdaterController`, which reads/writes Sparkle keys in the host app's user
/// defaults — side effects that don't belong in a unit test (same rationale as scoping
/// memory-leak tests to the mock service).
struct UpdaterServiceTests {
    @Test func startsUpdaterInNormalLaunchEnvironment() {
        #expect(UpdaterService.shouldStartUpdater(environment: [:]))
        #expect(UpdaterService.shouldStartUpdater(environment: ["PATH": "/usr/bin"]))
    }

    @Test func doesNotStartUpdaterInMockModeUITests() {
        #expect(!UpdaterService.shouldStartUpdater(environment: ["UITEST_USE_MOCK_SERVICE": "1"]))
    }

    @Test func doesNotStartUpdaterInsideTestHost() {
        // XCTest marks the hosting app's environment with these; any one alone must gate.
        #expect(!UpdaterService.shouldStartUpdater(
            environment: ["XCTestConfigurationFilePath": "/tmp/config.xctestconfiguration"]
        ))
        #expect(!UpdaterService.shouldStartUpdater(
            environment: ["XCTestBundlePath": "/tmp/BerthlyTests.xctest"]
        ))
        #expect(!UpdaterService.shouldStartUpdater(
            environment: ["XCTestSessionIdentifier": "ABC-123"]
        ))
    }

    /// The gate this suite relies on for its own determinism: the process running these tests
    /// must itself be recognized as a test host, or the app under test would have started a live
    /// updater before any test ran.
    @Test func recognizesThisTestRunAsTestHost() {
        #expect(!UpdaterService.shouldStartUpdater(environment: ProcessInfo.processInfo.environment))
    }
}

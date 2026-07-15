// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Berthly

// MARK: - DaemonState.afterFailedPing

/// The poll loop classifies every failed health-check ping through this one pure function, so the
/// "installed vs stopped vs error" decision stays testable without a live daemon or filesystem.
struct DaemonStateAfterFailedPingTests {

    @Test func connectionFailureWithCLIInstalledMeansStopped() {
        let state = DaemonState.afterFailedPing(
            isConnectionFailure: true, cliInstalled: true, errorMessage: "connection refused")
        #expect(state == .installedButStopped)
    }

    @Test func connectionFailureWithoutCLIMeansNotInstalled() {
        let state = DaemonState.afterFailedPing(
            isConnectionFailure: true, cliInstalled: false, errorMessage: "connection refused")
        #expect(state == .notInstalled)
    }

    @Test func nonConnectionFailureIsAnErrorEvenIfCLIMissing() {
        // A real API error must never be masked as "not installed" just because the binary check
        // also happened to fail — the message is what the user needs to see.
        let state = DaemonState.afterFailedPing(
            isConnectionFailure: false, cliInstalled: false, errorMessage: "decoding failed")
        #expect(state == .error("decoding failed"))
    }

    @Test func nonConnectionFailureCarriesTheMessage() {
        let state = DaemonState.afterFailedPing(
            isConnectionFailure: false, cliInstalled: true, errorMessage: "timeout after 5s")
        #expect(state == .error("timeout after 5s"))
    }
}

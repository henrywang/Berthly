// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` (see PLAN/UPGRADE.md): Berthly
/// self-updates from GitHub Releases via the appcast in `SUFeedURL`. The controller owns the
/// whole update UI (check dialog, download, "Install and Relaunch"); this class only adapts it
/// to SwiftUI — observable `canCheckForUpdates` for the menu item, and stored mirrors of the
/// two automatic-update preferences so Settings toggles get observation-driven updates
/// (Sparkle's own properties are plain ObjC accessors the `@Observable` macro can't track).
@Observable
final class UpdaterService {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    /// False while an update session is already in flight (or the updater never started, as in
    /// UI tests) — drives the "Check for Updates…" menu item's enabled state.
    private(set) var canCheckForUpdates = false

    /// Mirrors `SPUUpdater.automaticallyChecksForUpdates` (persisted by Sparkle in user
    /// defaults). Seeded in init, so external changes made while Settings is open won't reflect
    /// back — acceptable, since these toggles are the only surface that writes them.
    var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    /// Mirrors `SPUUpdater.automaticallyDownloadsUpdates` ("download and install in the
    /// background" as opposed to just notifying).
    var automaticallyDownloadsUpdates: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    init(startingUpdater: Bool = true) {
        let controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        // KVO rather than a Combine publisher: Sparkle fires this on the main thread, and the
        // observation handle keeps no reference cycle (self holds it, closure holds self weak).
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { [weak self] updater, change in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = change.newValue ?? updater.canCheckForUpdates
            }
        }
    }

    /// User-initiated check — shows Sparkle's progress/result UI, including "no update found"
    /// and error alerts (scheduled background checks stay silent on failure).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Whether to start the updater for this process. Tests must never trigger update checks:
    /// mock-mode UI tests set `UITEST_USE_MOCK_SERVICE`, and unit tests run inside the app as
    /// test host, which XCTest marks with `XCTestConfigurationFilePath`/`XCTestSessionIdentifier`.
    /// Pure and `nonisolated` so it's testable without constructing an updater.
    nonisolated static func shouldStartUpdater(environment: [String: String]) -> Bool {
        if environment["UITEST_USE_MOCK_SERVICE"] != nil { return false }
        if environment["XCTestConfigurationFilePath"] != nil { return false }
        if environment["XCTestBundlePath"] != nil { return false }
        if environment["XCTestSessionIdentifier"] != nil { return false }
        return true
    }
}

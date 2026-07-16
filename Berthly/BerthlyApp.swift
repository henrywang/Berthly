// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

@main
struct BerthlyApp: App {
    /// UI-test launches disable animations app-wide: animations are the #1 source of the
    /// suite's timing races (coordinate clicks landing on mid-transition controls, measure
    /// loops re-entering before a sheet settles — see CLAUDE.md's CI-flake notes). Piggybacks
    /// on `UITEST_USE_MOCK_SERVICE` so every existing mock-mode test gets it without launch
    /// changes; `UITEST_DISABLE_ANIMATIONS` lets the real-daemon E2E suite opt in separately.
    static let disableAnimations: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["UITEST_USE_MOCK_SERVICE"] != nil || env["UITEST_DISABLE_ANIMATIONS"] != nil
    }()

    init() {
        StatusButtonImageDedupe.install()
        if Self.disableAnimations {
            // SwiftUI transactions are handled per-scene below; these AppKit-level defaults
            // cover what transactions can't reach — window/sheet present-dismiss slides and
            // window resize easing, the exact animations the coordinate-click races hit.
            UserDefaults.standard.set(false, forKey: "NSAutomaticWindowAnimationsEnabled")
            UserDefaults.standard.set(0.001, forKey: "NSWindowResizeTime")
        }
    }

    @State private var service: ContainerServiceBase = Self.makeService()
    @State private var menuBarBridge = MenuBarBridge()
    @State private var buildJobManager = BuildJobManager()
    /// Sparkle self-updater (PLAN/UPGRADE.md). Not started under tests, so nothing can hit the
    /// update feed or pop update UI mid-test.
    @State private var updaterService = UpdaterService(
        startingUpdater: UpdaterService.shouldStartUpdater(environment: ProcessInfo.processInfo.environment)
    )
    /// Mirrors the General settings toggle — `MenuBarExtra(isInserted:)` inserts/removes the
    /// status item live as it changes.
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    /// UI tests set `UITEST_USE_MOCK_SERVICE` to get deterministic state instead of a real
    /// daemon connection, optionally seeded via `UITEST_INITIAL_DAEMON_STATE`.
    private static func makeService() -> ContainerServiceBase {
        let env = ProcessInfo.processInfo.environment
        guard env["UITEST_USE_MOCK_SERVICE"] != nil else {
            return LiveContainerService()
        }
        let mock = MockContainerService()
        switch env["UITEST_INITIAL_DAEMON_STATE"] {
        case "installedButStopped": mock.daemonState = .installedButStopped
        case "notInstalled":        mock.daemonState = .notInstalled
        case "checking":            mock.daemonState = .checking
        case "versionMismatch":
            mock.daemonState = .versionMismatch(installed: "1.0.0", required: ContainerCompatibility.requiredVersion)
        default: break
        }
        return mock
    }

    var body: some Scene {
        WindowGroup("Berthly", id: "main") {
            MainWindowView()
                .environment(service)
                .environment(menuBarBridge)
                .environment(buildJobManager)
                .disableAnimationsInUITests()
        }
        .defaultSize(width: 1200, height: 780)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            UpdaterCommands(updater: updaterService)
            ContainerCommands(service: service, bridge: menuBarBridge)
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarContentShell()
                .environment(service)
                .environment(menuBarBridge)
                .disableAnimationsInUITests()
        } label: {
            // Must stay render-stable: any label change makes SwiftUI call
            // NSStatusBarButton.setImage, which invalidates the status window's constraints —
            // and when that lands mid display cycle (e.g. during the detail-pane slide
            // animation in the main window), AppKit's feedback-loop guard throws
            // "window has been marked as needing another Update Constraints in Window pass,
            // but it has already had more ... than there are views" and crashes. Daemon
            // connection state is shown inside MenuBarView instead (dimming the icon via
            // `service.isConnected` here is what used to crash).
            Image("MenuBarIcon")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(updaterService)
        }
    }
}

private extension View {
    /// Strips animation from every transaction in this subtree when the app was launched by UI
    /// tests (`BerthlyApp.disableAnimations`) — sheets' *content*, the detail-pane slide,
    /// refresh spinners. A no-op in normal launches. Window-level AppKit animations are
    /// disabled separately in `BerthlyApp.init` (transactions don't reach those).
    func disableAnimationsInUITests() -> some View {
        transaction { t in
            if BerthlyApp.disableAnimations {
                t.animation = nil
                t.disablesAnimations = true
            }
        }
    }
}

/// Mounts `MenuBarView` only while the status-bar panel is on screen.
///
/// With `.menuBarExtraStyle(.window)`, *any* invalidation of the MenuBarExtra scene — the
/// content included, not just the label — makes SwiftUI re-apply the status button via
/// `NSStatusBarButton.setImage`, which invalidates the status window's constraints. When the
/// service's polling ticks land while another window is mid layout animation, AppKit's
/// feedback-loop guard throws ("window has been marked as needing another Update Constraints
/// in Window pass, but it has already had more ... than there are views"). MenuBarView reads
/// live service state, so it must not be part of the scene while the panel is closed; this
/// shell contributes no observable reads of its own, leaving the closed-panel scene fully
/// inert. (The label must stay static for the same reason — see `BerthlyApp`.)
private struct MenuBarContentShell: View {
    @State private var isPanelOpen = false

    var body: some View {
        Group {
            if isPanelOpen {
                MenuBarView()
            } else {
                // Roughly MenuBarView's footprint so the panel doesn't visibly resize on open.
                Color.clear.frame(width: 300, height: 120)
            }
        }
        .onAppear { isPanelOpen = true }
        .onDisappear { isPanelOpen = false }
    }
}

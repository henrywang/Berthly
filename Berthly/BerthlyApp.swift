// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

@main
struct BerthlyApp: App {
    @State private var service: ContainerServiceBase = Self.makeService()

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
        default: break
        }
        return mock
    }

    var body: some Scene {
        WindowGroup("Berthly") {
            MainWindowView()
                .environment(service)
        }
        .defaultSize(width: 1200, height: 780)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            // TODO: M4 — MenuBarView()
            Text("Berthly")
                .padding()
        } label: {
            Image(systemName: "shippingbox.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

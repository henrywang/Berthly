// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

@main
struct BerthlyApp: App {
    @State private var service = LiveContainerService()

    var body: some Scene {
        WindowGroup("Berthly") {
            MainWindowView()
                .environment(service as ContainerServiceBase)
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

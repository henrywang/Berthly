// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppKit
import UserNotifications

/// Posts a macOS user notification when a background build finishes and the user isn't
/// looking at the app — the Dock bounce alone is a single, easy-to-miss signal, and it
/// doesn't fire at all when Berthly is still the active app with its window closed (the
/// exact state clicking the window's red button leaves you in).
@MainActor
final class BuildNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = BuildNotifier()

    /// UI tests must never trip the system notification-permission dialog — it would hang
    /// mock-mode runs behind a prompt XCUITest can't reliably dismiss.
    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["UITEST_USE_MOCK_SERVICE"] == nil
    }

    private var authorizationRequested = false

    /// Called when a build starts, not at app launch: the permission prompt then appears in
    /// context ("you just started something that may finish while you're away") and the
    /// grant is settled by the time the build finishes.
    func prepare() {
        guard Self.isEnabled, !authorizationRequested else { return }
        authorizationRequested = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func postBuildFinished(_ job: BuildJob) {
        guard Self.isEnabled else { return }
        // If the user is actively looking at the app with the main window open, the toolbar
        // indicator already tells the story — a banner on top of it is noise. `mainWindow`
        // is nil once the red button has closed the window, even while Berthly stays the
        // active app, which is the case the Dock bounce misses.
        if NSApp.isActive && NSApp.mainWindow != nil { return }

        let text = buildFinishedNotificationText(
            reference: job.reference, status: job.status, duration: job.duration
        )
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
        )
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Clicking the banner brings the result into view: activate the app and reopen the
    /// main window through the same delegate path a Dock-icon click takes (SwiftUI's app
    /// delegate restores the `WindowGroup` window from it).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }
    }

    /// Without this, macOS suppresses banners while the app is frontmost — but "frontmost
    /// with no window open" is precisely a state we post in, so opt in explicitly. (The
    /// watching-the-app case never reaches delivery; `postBuildFinished` skips it.)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Pure text builder, separated for testability.
nonisolated func buildFinishedNotificationText(
    reference: String,
    status: BuildJob.Status,
    duration: TimeInterval
) -> (title: String, body: String) {
    switch status {
    case .succeeded:
        return ("Image Built", "\(reference) built in \(formatBuildDuration(duration)).")
    case .failed(let message):
        return ("Build Failed", "\(reference): \(message)")
    case .building:
        // Never posted — builds only notify on completion.
        return ("Building", reference)
    }
}

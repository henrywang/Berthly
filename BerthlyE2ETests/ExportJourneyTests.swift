// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

/// Export Filesystem coverage against a real daemon — previously untested at any layer beyond
/// unit (mock exportContainer) and mock UI (menu enablement only). Covers both paths:
/// stopped and running (`ComputeListView.canExportFilesystem` gates it on daemon 1.2.1, added in
/// #107 per apple/container#1630). The running half once skipped below 1.2.1, but its version
/// probe read `apiserver.version`, which current CLIs print as `server.version`, so it skipped on
/// every daemon (#212). Berthly's 1.6.1 floor makes that gate moot, so the half is unconditional.
///
/// `ComputeListView.exportFilesystem()` calls `NSSavePanel.runModal()` directly — no sheet, no
/// existing test seam, same shape as Save/Load before `UITEST_SAVE_DESTINATION` — so this adds
/// `UITEST_EXPORT_DESTINATION_DIR`, a directory (not a single path) since one launch here
/// exports two different containers, each landing at its own default filename.
///
/// The oracle is the archive's actual contents, not just its existence: a marker file written
/// into the container via `exec` before export, then confirmed present via `tar -tf` on the
/// produced archive — a truncated or empty archive from a mid-export failure would still leave
/// a file on disk, but wouldn't contain the marker.
final class ExportJourneyTests: BerthlyE2ETestCase {
    private static let fixtureImage = "alpine:latest"

    @MainActor
    func testExportFilesystemStoppedAndRunning() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)

        let exportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.resourcePrefix)-export-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exportDir) }

        let app = XCUIApplication.berthlyE2E()
        app.launchEnvironment["UITEST_EXPORT_DESTINATION_DIR"] = exportDir.path
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        // ── Stopped container. ──
        let stoppedMarker = "export-marker-\(UUID().uuidString.prefix(8))"
        let runStopped = try ContainerCLI.run(
            ["run", "-d", "--name", containerName, Self.fixtureImage, "sleep", "300"], timeout: 60
        )
        XCTAssertEqual(runStopped.status, 0, "fixture container should start:\n\(runStopped.output)")
        let writeStopped = try ContainerCLI.exec(containerName, ["sh", "-c", "echo hi > /\(stoppedMarker).txt"])
        XCTAssertEqual(writeStopped.status, 0, "writing the marker file should succeed:\n\(writeStopped.output)")
        let stop = try ContainerCLI.run(["stop", containerName], timeout: 30)
        XCTAssertEqual(stop.status, 0, "stopping the fixture container should succeed:\n\(stop.output)")

        let stoppedArchive = try exportViaUI(app: app, containerName: containerName, exportDir: exportDir)
        try assertArchiveContains(stoppedArchive, entry: "\(stoppedMarker).txt")

        // ── Running container. ──

        let runningName = "\(containerName)-running"
        let runningMarker = "export-marker-\(UUID().uuidString.prefix(8))"
        let runRunning = try ContainerCLI.run(
            ["run", "-d", "--name", runningName, Self.fixtureImage, "sleep", "300"], timeout: 60
        )
        XCTAssertEqual(runRunning.status, 0, "second fixture container should start:\n\(runRunning.output)")
        let writeRunning = try ContainerCLI.exec(runningName, ["sh", "-c", "echo hi > /\(runningMarker).txt"])
        XCTAssertEqual(writeRunning.status, 0, "writing the running marker file should succeed:\n\(writeRunning.output)")

        let runningArchive = try exportViaUI(app: app, containerName: runningName, exportDir: exportDir)
        try assertArchiveContains(runningArchive, entry: "\(runningMarker).txt")
    }

    // MARK: - Helpers

    /// Right-clicks the container's row, exports through the context menu (destination already
    /// resolved via `UITEST_EXPORT_DESTINATION_DIR`, so no save panel appears), and waits for
    /// the archive to land on disk. There's no "Done" element for a bare context-menu action
    /// (unlike Save/Load's sheet) — the row's own in-flight spinner has no accessibility hook —
    /// so the file's stabilized size is the completion signal: unchanged across two samples a
    /// second apart, ruling out catching it mid-write.
    private func exportViaUI(app: XCUIApplication, containerName: String, exportDir: URL) throws -> URL {
        let row = app.staticTexts["computeRow-\(containerName)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "\(containerName) should appear in the sidebar")
        row.rightClick()
        let exportItem = app.menuItems["Export Filesystem…"]
        XCTAssertTrue(exportItem.waitForExistence(timeout: 5), "Export Filesystem… should be in the context menu")
        XCTAssertTrue(exportItem.isEnabled, "Export Filesystem… should be enabled for \(containerName)")
        exportItem.click()

        let archive = exportDir.appendingPathComponent("\(containerName)-rootfs.tar")

        let deadline = Date(timeIntervalSinceNow: 60)
        var lastSize: UInt64?
        while Date() < deadline {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: archive.path),
               let size = attrs[.size] as? UInt64, size > 0 {
                if size == lastSize { return archive }
                lastSize = size
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("export archive never appeared or never stabilized at \(archive.path)")
        return archive
    }

    /// `tar -tf` lists entries without extracting — enough to prove the archive is well-formed
    /// and genuinely contains the marker written into the container, not just that some file
    /// landed on disk.
    private func assertArchiveContains(_ archive: URL, entry: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tf", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        // Lossy decode on purpose, matching ContainerCLI.run: tar output with a stray
        // non-UTF-8 byte should still surface the rest, not become nil.
        // swiftlint:disable:next optional_data_string_conversion
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "tar should read the archive as valid:\n\(output)")
        XCTAssertTrue(output.contains(entry), "archive should contain \(entry):\n\(output)")
    }
}

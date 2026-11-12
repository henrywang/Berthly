// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

/// apple/container#2405, fixed in 1.7.1 by #2414 (`BuildFSSync`, which Berthly links in-process)
/// plus builder shim 0.13.3: a step that needs the whole context (here a tmpfs-mount `RUN`) made
/// BuildKit send an empty `followpaths`, which served nothing, so a multi-source `COPY` failed
/// with `"/b.txt": not found` — only the first source reached the builder.
final class BuildContextJourneyTests: BerthlyE2ETestCase {
    private static let fixtureImage = "alpine:latest"

    @MainActor
    func testBuildMultiSourceCopyWithTmpfsMountStep() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.resourcePrefix)-ctx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dockerfile = """
        FROM alpine:latest
        COPY a.txt b.txt /out/
        RUN --mount=type=tmpfs,dst=/scratch ls -l /out
        """
        try dockerfile.write(to: dir.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        try "one\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let tag = "\(Self.resourcePrefix)/img-\(UUID().uuidString.prefix(8).lowercased()):1"

        let app = XCUIApplication.berthlyE2E()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        XCTAssertTrue(app.openViaPalette("Build Image"))
        let tagField = app.windows.textFields["buildTagField"]
        XCTAssertTrue(tagField.waitForExistence(timeout: 5), "Build sheet should appear")
        tagField.click(); tagField.typeText(tag)
        let ctxField = app.windows.textFields["buildContextField"]
        ctxField.click(); ctxField.typeText(dir.path)

        app.buttons["buildSubmitButton"].click()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 300),
                      "build should succeed; sheet:\n\(app.windows.firstMatch.debugDescription)")
        done.click()

        let out = try ContainerCLI.run(
            ["run", "--rm", "--name", containerName, tag, "cat", "/out/a.txt", "/out/b.txt"],
            timeout: 120)
        XCTAssertTrue(out.output.contains("one") && out.output.contains("two"),
                      "both COPY sources should be in the image:\n\(out.output)")
        // image (berthly-e2e/…) swept by prefix in tearDown.
    }
}

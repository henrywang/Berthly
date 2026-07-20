// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

/// Split into its own file to keep `BerthlyE2ETests.swift` under the `file_length` ratchet —
/// this is still logically part of `RegistryJourneyTests` (an `extension`, not a new class), so
/// it shares that class's registry fixtures/helpers directly. `fixtureImage`/`registryImage`/
/// `waitForRegistryReady` are `internal` there rather than `private` specifically so this
/// extension can reach them from a separate file — Swift's `private` is file-scoped, not
/// type-scoped.
extension RegistryJourneyTests {
    /// The recreate feature's one real-daemon journey. Unit/mock tests can't prove: a real
    /// registry HEAD comparison, real indirect-index digest unwrapping, a real pull replacing
    /// the local tag, recreate preserving configuration/run state and volume data while
    /// discarding the writable layer, the `.localImageNewer` vs `.remoteUpdateAvailable`
    /// distinction via "Pull Latest", a recreate that provably needs zero network, and an
    /// `--rm`/autoRemove container surviving the post-stop `notFound`-confirmed-absence fallback.
    ///
    /// Build/push/retag for v1/v2/v3 are CLI-driven fixture setup — Build/Push/generic-Pull are
    /// already proven end to end by the two tests above, so re-driving those sheets three times
    /// each here would be pure duplication. The UI is exercised only for what's new: one initial
    /// Pull (insecure toggle ON, to exercise the insecure-host memory's write path for real),
    /// Check for Updates, Recreate, and Pull Latest (which should need NO manual toggle click —
    /// the host is already remembered as insecure from the first pull, so this doubles as a
    /// behavioral proof that the prefill wiring actually works).
    ///
    /// The core trick (verified empirically against this exact daemon before writing this test):
    /// any push through this ONE daemon updates the local store's entry for that reference too,
    /// so local and remote can never naturally disagree. Publish vN to the registry, then
    /// **locally** retag a preserved alias back onto the canonical name (confirmed: retagging
    /// overwrites an existing local name rather than erroring) — a real, no-network operation —
    /// so the registry keeps vN while the local store (and anything already pinned to the old
    /// digest) stays at vN-1.
    @MainActor
    func testRecreateWithLatestImageThroughLocalRegistry() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)
        try ContainerCLI.ensureImage(Self.registryImage)

        let port = 18583
        let watchtowerRegistryName = "\(Self.resourcePrefix)-watchtower-registry"
        let canonical = "localhost:\(port)/berthly-e2e/watchtower:latest"

        // ── 1. Local registry — fixture infra via CLI, its own port to avoid any collision with
        // the two tests above. ──
        let registryRun = try ContainerCLI.run(
            ["run", "-d", "--name", watchtowerRegistryName, "-p", "\(port):5000", Self.registryImage],
            timeout: 60
        )
        XCTAssertEqual(registryRun.status, 0, "starting the local registry failed:\n\(registryRun.output)")
        try waitForRegistryReady(port: port)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.resourcePrefix)-watchtower-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // ── 2. Publish v1 (CLI fixture setup). ──
        try buildTagPush(marker: "v1", workDir: workDir, as: canonical)

        // ── 3. The one UI touch that isn't pure setup: pull v1 through Berthly with the
        // insecure toggle on, for real. ──
        let app = XCUIApplication.berthlyE2E()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        // Daemon-ready gate: unlike the round-trip tests above (which do a slow Build first,
        // incidentally giving the app time to connect), this is the very first UI action here —
        // the palette's "Pull Image" entry can silently no-op if invoked before the daemon
        // connection settles. Same enabled-state wait openRunSheet uses.
        let runButton = app.buttons["runToolbarButton"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: runButton)
        waitForExpectations(timeout: 30)

        XCTAssertTrue(app.openViaPalette("Pull Image"))
        let pullField = app.windows.textFields["pullImageField"]
        XCTAssertTrue(pullField.waitForExistence(timeout: 5), "Pull sheet should appear")
        pullField.click(); pullField.typeText(canonical)
        expandAdvancedSection(app, revealing: "allowInsecureRegistryToggle")
        app.checkBoxes["allowInsecureRegistryToggle"].click()
        app.buttons["pullSubmitButton"].click()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 60), "the initial pull should succeed")
        dismissDoneSheet(app)

        // ── 4. Run two containers from the pulled reference: "main" (named volume + a marker
        // written straight into its writable layer) and "-ar" (Remove when stopped). ──
        let mainName = containerName
        let autoRemoveName = "\(containerName)-ar"

        openRunSheet(app)
        typeField(app, canonical, into: "runImageField")
        typeField(app, mainName, into: "runNameField")
        typeField(app, "sleep 600", into: "runCommandField")
        app.buttons["runCategory-Storage"].click()
        app.buttons["runVolumeAddButton"].click()
        typeField(app, "\(volumeName):/data", into: "runVolumeField")
        app.buttons["runSubmitButton"].click()
        XCTAssertTrue(app.buttons["Show Container"].waitForExistence(timeout: 60), "main container should boot")
        app.buttons["Show Container"].click()

        openRunSheet(app)
        typeField(app, canonical, into: "runImageField")
        typeField(app, autoRemoveName, into: "runNameField")
        typeField(app, "sleep 600", into: "runCommandField")
        app.checkBoxes["runRemoveWhenStoppedToggle"].click()
        app.buttons["runSubmitButton"].click()
        XCTAssertTrue(app.buttons["Show Container"].waitForExistence(timeout: 60), "auto-remove container should boot")
        app.buttons["Show Container"].click()

        // Two markers: one inside the volume mount (must survive recreate), one in the
        // container's own writable layer outside any mount (must NOT survive recreate) —
        // the exact distinction the confirm sheet's own warning text makes.
        XCTAssertEqual(try ContainerCLI.exec(mainName, ["sh", "-c", "echo volume-data > /data/marker"]).status, 0)
        XCTAssertEqual(try ContainerCLI.exec(mainName, ["sh", "-c", "echo layer-data > /root/marker"]).status, 0)

        // ── 5. Publish v2 to the registry while the local store (and both containers, still
        // pinned at run time) stays at v1. ──
        try republishKeepingLocalPinned(marker: "v2", workDir: workDir, canonical: canonical)

        // ── 6. Detect + recreate the remote-update path. ──
        app.staticTexts["Images"].click()
        let checkButton = app.buttons["checkImageUpdatesButton"]
        XCTAssertTrue(checkButton.waitForExistence(timeout: 10))
        checkButton.click()
        XCTAssertTrue(checkButton.waitForNonExistence(timeout: 5), "check should show a spinner while running")
        XCTAssertTrue(checkButton.waitForExistence(timeout: 30), "check should complete")

        let imageBadge = app.descendants(matching: .any)["imageUpdateBadge-\(canonical)"]
        XCTAssertTrue(imageBadge.waitForExistence(timeout: 5), "image row should show an update badge for v2")

        app.staticTexts["Compute"].click()
        let mainRow = app.staticTexts["computeRow-\(mainName)"]
        XCTAssertTrue(mainRow.waitForExistence(timeout: 10))
        let mainBadge = app.descendants(matching: .any)["containerUpdateBadge-\(mainName)"]
        XCTAssertTrue(mainBadge.waitForExistence(timeout: 5), "main container row should show an update badge")

        openRecreateSheet(app, on: mainRow)
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 240),
                      "recreate should succeed with a real HTTP pull; sheet:\n\(app.windows.firstMatch.debugDescription)")
        dismissDoneSheet(app)

        let mainJSON = try ContainerCLI.inspectJSON(mainName)
        XCTAssertEqual(ContainerCLI.value(at: "status.state", in: mainJSON) as? String, "running")
        let imageMarker = try ContainerCLI.exec(mainName, ["cat", "/berthly-e2e-marker"])
        XCTAssertTrue(imageMarker.output.contains("v2"), "image marker should read v2 after recreate")
        let volumeMarker = try ContainerCLI.exec(mainName, ["cat", "/data/marker"])
        XCTAssertTrue(volumeMarker.output.contains("volume-data"), "the volume marker should survive recreate")
        let layerMarker = try ContainerCLI.exec(mainName, ["cat", "/root/marker"])
        XCTAssertNotEqual(layerMarker.status, 0, "the writable-layer marker should be discarded by recreate")

        XCTAssertTrue(mainBadge.waitForNonExistence(timeout: 5), "container badge should clear")
        XCTAssertTrue(imageBadge.waitForNonExistence(timeout: 5), "image badge should clear")

        // ── 7. Recreate the auto-remove container too — it's now .localImageNewer (local moved
        // to v2 via the pull above; it's still pinned to v1) — exercises BOTH the no-pull path
        // and the post-stop notFound-confirmed-absence fallback in one action. ──
        let autoRemoveRow = app.staticTexts["computeRow-\(autoRemoveName)"]
        XCTAssertTrue(autoRemoveRow.waitForExistence(timeout: 10))
        openRecreateSheet(app, on: autoRemoveRow)
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 60),
                      "the auto-remove container should survive recreate despite self-deleting on stop")
        dismissDoneSheet(app)
        let autoRemoveJSON = try ContainerCLI.inspectJSON(autoRemoveName)
        XCTAssertEqual(ContainerCLI.value(at: "status.state", in: autoRemoveJSON) as? String, "running")
        // Not asserting autoRemove is still enabled: the product explicitly can't preserve it
        // (ContainerSnapshot never carries it) — the confirm sheet's copy says so.

        // ── 8. v3 + Pull Latest — the .localImageNewer path reached via the Images page's own
        // button instead of an implicit side effect. ──
        try republishKeepingLocalPinned(marker: "v3", workDir: workDir, canonical: canonical)

        app.staticTexts["Images"].click()
        checkButton.click()
        XCTAssertTrue(checkButton.waitForNonExistence(timeout: 5))
        XCTAssertTrue(checkButton.waitForExistence(timeout: 30))
        XCTAssertTrue(imageBadge.waitForExistence(timeout: 5), "image badge should reappear for v3")

        app.staticTexts[canonical].rightClick()
        let pullLatest = app.menuItems["Pull Latest"]
        XCTAssertTrue(pullLatest.waitForExistence(timeout: 5))
        pullLatest.click()
        // No manual toggle click here: the host was already remembered as insecure from step 3,
        // so PullImageSheet's initiallyInsecure prefill should have it checked already — this is
        // as much a functional proof of that prefill as it is journey setup.
        app.buttons["pullSubmitButton"].click()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 60), "Pull Latest should succeed")
        dismissDoneSheet(app)

        XCTAssertTrue(imageBadge.waitForNonExistence(timeout: 5), "image badge should clear after Pull Latest")
        app.staticTexts["Compute"].click()
        XCTAssertTrue(mainBadge.waitForExistence(timeout: 5),
                      "container badge should REMAIN — still pinned to v2 while local is now v3")

        // ── 9. Stop the registry entirely, then recreate again — a definitive, non-racy proof
        // that .localImageNewer needs zero network (a "no PULL log line ever appeared" string
        // match would be flaky by comparison — this can't pass by accident). ──
        _ = try ContainerCLI.run(["stop", watchtowerRegistryName], timeout: 30)
        openRecreateSheet(app, on: mainRow)
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 30),
                      "recreate must succeed with the registry unreachable — proves .localImageNewer needs no network")
        dismissDoneSheet(app)

        XCTAssertTrue(mainBadge.waitForNonExistence(timeout: 5))
        let finalMarker = try ContainerCLI.exec(mainName, ["cat", "/berthly-e2e-marker"])
        XCTAssertTrue(finalMarker.output.contains("v3"), "final recreate should be pinned to v3")

        // watchtower registry (already stopped above), both compute containers, and every
        // berthly-e2e/… image swept by prefix in tearDown.
    }

    /// Right-clicks `row`, opens "Recreate with Latest Image…" (label query — no identifier
    /// survives the SwiftUI→NSMenu bridge), and submits. Leaves the caller to wait for whatever
    /// this particular recreate should produce (a real pull can take much longer than a no-pull
    /// no-network one).
    @MainActor
    private func openRecreateSheet(_ app: XCUIApplication, on row: XCUIElement) {
        row.rightClick()
        let item = app.menuItems["Recreate with Latest Image…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        app.buttons["recreateSubmitButton"].click()
    }

    /// Dismisses a sheet's "Done" button by clicking it — matching the round-trip tests above
    /// (`buildDone.click()`, the push/pull "Done" clicks), not the mock-mode UI test convention
    /// of a Return keypress: a real-daemon E2E launch has no `UITEST_DISABLE_ANIMATIONS` and (for
    /// the pull sheets specifically) a just-typed text field can still hold first responder, so
    /// Return isn't guaranteed to route to the button here the way it does in mock mode — verified
    /// empirically (Return alone left the sheet up past a 10s wait; a direct click doesn't).
    /// Waits for the sheet to be fully gone before returning, since the next action in this
    /// journey is often another coordinate-sensitive gesture (a right-click).
    @MainActor
    private func dismissDoneSheet(_ app: XCUIApplication) {
        let done = app.buttons["Done"]
        done.click()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10), "sheet should fully dismiss")
    }

    /// Builds a tiny marker image and pushes it to `destination` — CLI fixture setup, not the
    /// feature under test (Build/Push are already proven end to end by the two tests above).
    @discardableResult
    private func buildTagPush(marker: String, workDir: URL, as destination: String) throws -> ContainerCLI.Result {
        let dockerfile = """
        FROM alpine:latest
        RUN echo \(marker) > /berthly-e2e-marker
        """
        try dockerfile.write(to: workDir.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        let localTag = "\(Self.resourcePrefix)/watchtower-src-\(UUID().uuidString.prefix(8).lowercased()):1"
        let build = try ContainerCLI.run(["build", "-t", localTag, workDir.path], timeout: 120)
        XCTAssertEqual(build.status, 0, "build (\(marker)) failed:\n\(build.output)")
        let tag = try ContainerCLI.run(["image", "tag", localTag, destination], timeout: 30)
        XCTAssertEqual(tag.status, 0, "tag (\(marker)) failed:\n\(tag.output)")
        let push = try ContainerCLI.run(["image", "push", "--scheme", "http", destination], timeout: 60)
        XCTAssertEqual(push.status, 0, "push (\(marker)) failed:\n\(push.output)")
        return push
    }

    /// Publishes a new version to the registry while leaving the local store (and anything
    /// already pinned to the old digest, e.g. a running container) exactly where it was — see
    /// the journey's own doc comment for why a plain push can't do this on a single daemon.
    private func republishKeepingLocalPinned(marker: String, workDir: URL, canonical: String) throws {
        let alias = "\(Self.resourcePrefix)/watchtower-preserved-\(UUID().uuidString.prefix(8).lowercased()):1"
        let preserve = try ContainerCLI.run(["image", "tag", canonical, alias], timeout: 30)
        XCTAssertEqual(preserve.status, 0, "preserving the local alias failed:\n\(preserve.output)")
        try buildTagPush(marker: marker, workDir: workDir, as: canonical)
        let restore = try ContainerCLI.run(["image", "tag", alias, canonical], timeout: 30)
        XCTAssertEqual(restore.status, 0, "restoring the local canonical tag failed:\n\(restore.output)")
    }
}

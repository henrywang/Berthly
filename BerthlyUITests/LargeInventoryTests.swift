// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

final class LargeInventoryTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication.terminateRunningBerthly()
    }

    @MainActor
    func testLargeInventorySupportsNavigationAndLifecycleWorkflows() throws {
        let app = launchLargeInventory()
        let firstContainer = app.staticTexts["computeRow-container-000"]
        XCTAssertTrue(firstContainer.waitForExistence(timeout: 10))
        firstContainer.click()
        assertTitle(app.staticTexts["containerDetailTitle"], equals: "container-000")

        setComputeFilter("machine-018", in: app)
        let machine = app.staticTexts["machineRow-machine-018"]
        XCTAssertTrue(machine.waitForExistence(timeout: 5))
        machine.click()
        assertTitle(app.staticTexts["machineDetailTitle"], equals: "machine-018")
        clearComputeFilter(in: app)

        firstContainer.click()
        XCTAssertTrue(app.staticTexts["containerDetailTitle"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["containerDetailTitle"].waitForNonExistence(timeout: 5))
        let computeList = app.descendants(matching: .any)["computeList"]
        XCTAssertTrue(computeList.waitForExistence(timeout: 5))
        let computeOutline = computeList.descendants(matching: .outline).firstMatch
        XCTAssertTrue(computeOutline.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            computeOutline.scroll(byDeltaX: 0, deltaY: -10_000)
        }
        // container-099 is the last *container* row, seven stopped-machine rows above the actual
        // bottom edge — landing a scroll-to-max click there avoids the boundary row (machine-018,
        // dead last in the list), where the same click reproducibly raced a stale/degenerate frame.
        let tailContainer = app.staticTexts["computeRow-container-099"]
        let tailIsHittable = NSPredicate(format: "hittable == true")
        expectation(for: tailIsHittable, evaluatedWith: tailContainer)
        waitForExpectations(timeout: 5)
        tailContainer.click()
        assertTitle(app.staticTexts["containerDetailTitle"], equals: "container-099")

        setComputeFilter("container-000", in: app)
        XCTAssertTrue(firstContainer.waitForExistence(timeout: 5))
        firstContainer.click()
        clearComputeFilter(in: app)
        let stopButton = app.buttons["containerStopButton"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))
        stopButton.click()
        let startButton = app.buttons["containerStartButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        startButton.click()
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))

        setComputeFilter("container-097", in: app)
        let deleteRow = app.staticTexts["computeRow-container-097"]
        XCTAssertTrue(deleteRow.waitForExistence(timeout: 5))
        deleteRow.rightClick()
        let deleteMenuItem = app.menuItems["Delete…"]
        XCTAssertTrue(deleteMenuItem.waitForExistence(timeout: 5))
        deleteMenuItem.click()
        let confirmDelete = app.buttons["containerDeleteConfirmButton"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.click()
        XCTAssertTrue(deleteRow.waitForNonExistence(timeout: 5))
        clearComputeFilter(in: app)

        selectSidebar("sidebarImages", in: app)
        XCTAssertTrue(app.staticTexts["containerDetailTitle"].waitForNonExistence(timeout: 5))
        let image = app.staticTexts["imageRow-local/fixture-image-000:v1"]
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        image.click()
        XCTAssertTrue(app.staticTexts["imageDetailTitle"].waitForExistence(timeout: 5))

        selectSidebar("sidebarVolumes", in: app)
        XCTAssertTrue(app.staticTexts["imageDetailTitle"].waitForNonExistence(timeout: 5))
        let volume = app.staticTexts["volumeRow-volume-000"]
        XCTAssertTrue(volume.waitForExistence(timeout: 5))
        volume.click()
        XCTAssertTrue(app.staticTexts["volumeDetailTitle"].waitForExistence(timeout: 5))

        selectSidebar("sidebarNetworks", in: app)
        XCTAssertTrue(app.staticTexts["volumeDetailTitle"].waitForNonExistence(timeout: 5))
        let network = app.staticTexts["networkRow-network-000"]
        XCTAssertTrue(network.waitForExistence(timeout: 5))
        network.click()
        XCTAssertTrue(app.staticTexts["networkDetailTitle"].waitForExistence(timeout: 5))

        selectSidebar("sidebarCompute", in: app)
        XCTAssertTrue(app.staticTexts["networkDetailTitle"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(firstContainer.waitForExistence(timeout: 5))
    }

    @MainActor
    func testLargeInventorySectionAndDetailPerformance() throws {
        let app = launchLargeInventory()
        let container = app.staticTexts["computeRow-container-000"]
        XCTAssertTrue(container.waitForExistence(timeout: 10))

        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(metrics: [XCTMemoryMetric(), XCTCPUMetric()], options: options) {
            container.click()
            XCTAssertTrue(app.staticTexts["containerDetailTitle"].waitForExistence(timeout: 5))

            selectSidebar("sidebarImages", in: app)
            let image = app.staticTexts["imageRow-local/fixture-image-000:v1"]
            XCTAssertTrue(image.waitForExistence(timeout: 5))
            image.click()
            XCTAssertTrue(app.staticTexts["imageDetailTitle"].waitForExistence(timeout: 5))

            selectSidebar("sidebarVolumes", in: app)
            let volume = app.staticTexts["volumeRow-volume-000"]
            XCTAssertTrue(volume.waitForExistence(timeout: 5))
            volume.click()
            XCTAssertTrue(app.staticTexts["volumeDetailTitle"].waitForExistence(timeout: 5))

            selectSidebar("sidebarNetworks", in: app)
            let network = app.staticTexts["networkRow-network-000"]
            XCTAssertTrue(network.waitForExistence(timeout: 5))
            network.click()
            XCTAssertTrue(app.staticTexts["networkDetailTitle"].waitForExistence(timeout: 5))

            selectSidebar("sidebarCompute", in: app)
            XCTAssertTrue(app.staticTexts["networkDetailTitle"].waitForNonExistence(timeout: 5))
            XCTAssertTrue(container.waitForExistence(timeout: 5))
        }
    }

    @MainActor
    private func launchLargeInventory() -> XCUIApplication {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launchEnvironment["UITEST_MOCK_DATASET"] = "large"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func selectSidebar(_ identifier: String, in app: XCUIApplication) {
        let destination = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        destination.click()
    }

    @MainActor
    private func setComputeFilter(_ text: String, in app: XCUIApplication) {
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        app.typeKey("a", modifierFlags: .command)
        search.typeText(text)
    }

    @MainActor
    private func clearComputeFilter(in app: XCUIApplication) {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["computeRunningSummary"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertTitle(_ title: XCUIElement, equals expected: String) {
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let displayedText = title.label.isEmpty ? title.value as? String : title.label
        XCTAssertEqual(displayedText, expected)
    }
}

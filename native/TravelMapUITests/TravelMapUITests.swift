import XCTest

final class TravelMapUITests: XCTestCase {
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"] + extra
        app.launch()
        return app
    }

    func testBrowseGroupPagePhotosAndReopenDetail() {
        let app = launch()
        XCTAssertTrue(app.buttons["spot-library"].waitForExistence(timeout: 15))
        app.buttons["spot-library"].tap()
        let row = app.buttons["spot-row-sample-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.buttons["expand-photo"].waitForExistence(timeout: 10))
        app.buttons["expand-photo"].tap()
        XCTAssertTrue(app.buttons["next-photo"].waitForExistence(timeout: 10))
        app.buttons["next-photo"].tap()
        XCTAssertTrue(app.staticTexts["2 / 3"].waitForExistence(timeout: 5))
        app.buttons["previous-photo"].tap()
        XCTAssertTrue(app.staticTexts["1 / 3"].exists)
        app.buttons["close-viewer"].tap()
        app.buttons["close-detail"].tap()
        app.buttons["spot-library"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["expand-photo"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "spot-detail"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLocalModeAndPrivacyInformationWithLargeText() {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["information"].waitForExistence(timeout: 15))
        app.buttons["information"].tap()
        XCTAssertTrue(app.navigationBars["Travel Mapについて"].waitForExistence(timeout: 5))
        app.buttons["close-info"].tap()
        let control = app.segmentedControls["map-scope"]
        control.buttons["端末の記録"].tap()
        XCTAssertTrue(app.buttons["capture"].isHittable)
        app.buttons["spot-library"].tap()
        XCTAssertTrue(app.navigationBars["端末の記録"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "large-type-journal"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLandscapeDarkModeMapControls() {
        let app = launch(extra: ["-AppleInterfaceStyle", "Dark"])
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["capture"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["capture"].isHittable)
        XCTAssertTrue(app.buttons["information"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "landscape-dark"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

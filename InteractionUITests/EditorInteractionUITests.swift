import XCTest
import UIKit

@MainActor
final class EditorInteractionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(tool: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["JOTTRE_INTERACTION_TEST_TOOL"] = tool
        app.launch()
        return app
    }

    private func info(_ probe: XCUIElement) throws -> [String: Any] {
        let text = try XCTUnwrap(probe.value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func point(_ app: XCUIApplication, info: [String: Any], x: Double, y: Double) throws -> XCUICoordinate {
        let rect = try XCTUnwrap(info["rect"] as? [Double])
        return app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: rect[0] + rect[2] * x, dy: rect[1] + rect[3] * y)
        )
    }

    func testFirstTouchAfterScrollingDoesNotShowTextMenu() throws {
        let app = launch(tool: "pen")
        let first = app.staticTexts["editor.page.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let pen = app.buttons["Pen"]
        XCTAssertTrue(pen.waitForExistence(timeout: 5))
        if try info(first)["tool"] as? String != "pen" { pen.tap() }
        XCTAssertEqual(try info(first)["tool"] as? String, "pen")
        let geometry = try info(first)
        try point(app, info: geometry, x: 0.6, y: 0.65)
            .press(forDuration: 0.01, thenDragTo: point(app, info: geometry, x: 0.6, y: 0.2))
        let second = app.staticTexts["editor.page.1"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        let next = try info(second)
        let touch = try point(app, info: next, x: 0.45, y: 0.15)
        XCTAssertTrue(app.frame.insetBy(dx: 20, dy: 160).contains(touch.screenPoint),
            "The test must touch the newly visible page, not an offscreen stale coordinate")
        touch.tap()
        touch.press(forDuration: 1.2)
        XCTAssertFalse(app.menuItems["Select All"].exists)
        XCTAssertFalse(app.buttons["Select All"].exists)
        XCTAssertFalse(app.buttons["Insert Space"].exists)
        XCTAssertFalse(app.staticTexts["Select All"].exists)
        XCTAssertFalse(app.staticTexts["Insert Space"].exists)
    }

    func testColdLaunchAfterEditingReturnsToLibrary() {
        let app = launch(tool: "pen")
        XCTAssertTrue(app.staticTexts["editor.page.0"].waitForExistence(timeout: 15))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "JOTTRE_INTERACTION_TEST_TOOL")
        app.launch()
        XCTAssertTrue(app.buttons["zotero.sort"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["editor.page.0"].exists)
    }

    func testColdLaunchShowsLibraryAndRetainsSorting() {
        let app = launch()
        let sort = app.buttons["zotero.sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 15))
        sort.tap()
        app.buttons["zotero.sort.dateAdded"].tap()
        let expected = sort.value as? String
        app.terminate()
        app.launch()
        XCTAssertTrue(sort.waitForExistence(timeout: 15))
        XCTAssertEqual(sort.value as? String, expected)
        XCTAssertFalse(app.staticTexts["editor.page.0"].exists)
        sort.tap()
        app.buttons["zotero.sort.dateAdded"].tap()
        XCTAssertNotEqual(sort.value as? String, expected)
        let reversed = sort.value as? String
        app.terminate()
        app.launch()
        XCTAssertTrue(sort.waitForExistence(timeout: 15))
        XCTAssertEqual(sort.value as? String, reversed)
    }
}

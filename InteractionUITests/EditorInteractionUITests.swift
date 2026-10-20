import XCTest
import UIKit
@preconcurrency import PencilKit

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

    func testFirstTouchAfterScrollingDoesNotShowTextMenu() async throws {
        let app = launch(tool: "pen")
        let first = app.staticTexts["editor.page.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let pen = app.buttons["Pen"]
        XCTAssertTrue(pen.waitForExistence(timeout: 5))
        if try info(first)["tool"] as? String != "pen" {
            pen.tap()
            var selectedTool = try info(first)["tool"] as? String
            for _ in 0..<20 where selectedTool != "pen" {
                try await Task.sleep(for: .milliseconds(100))
                selectedTool = try info(first)["tool"] as? String
            }
        }
        XCTAssertEqual(try info(first)["tool"] as? String, "pen")
        // The fixture contains selectable PDF text at the top-left. Hold there
        // long enough to exercise PDFKit's text-selection edit menu path.
        let text = try point(app, info: info(first), x: 0.12, y: 0.07)
        text.press(forDuration: 1.2)
        XCTAssertFalse(app.menuItems["Select All"].exists)
        XCTAssertFalse(app.buttons["Insert Space"].exists)

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

    func testFingerPinchStillZoomsWithNativeMenuSuppression() async throws {
        let app = launch(tool: "pen")
        let page = app.staticTexts["editor.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        let before = try XCTUnwrap(try info(page)["scaleFactor"] as? Double)

        page.pinch(withScale: 1.5, velocity: 1)

        var after = try info(page)
        for _ in 0..<20 where (after["scaleFactor"] as? Double ?? 0) <= before * 1.1 {
            try await Task.sleep(for: .milliseconds(100))
            after = try info(page)
        }
        XCTAssertGreaterThan(try XCTUnwrap(after["scaleFactor"] as? Double), before * 1.1)
    }

    func testBlankNoteKeepsPencilKitDrawingAndSuppressesRepeatedFingerEditMenus() async throws {
        let app = launch(tool: "blank-pen")
        let page = app.staticTexts["editor.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        let pen = app.buttons["Pen"]
        XCTAssertTrue(pen.waitForExistence(timeout: 5))
        if try info(page)["tool"] as? String != "pen" {
            pen.tap()
        }

        var state = try info(page)
        XCTAssertEqual(state["blankNoteFixture"] as? Bool, true,
            "This regression must use a note whose persisted pdfData is nil")
        XCTAssertGreaterThan(state["strokes"] as? Int ?? 0, 0,
            "The blank note fixture starts with PencilKit ink already written")
        XCTAssertEqual(state["drawingPolicy"] as? UInt, PKCanvasViewDrawingPolicy.pencilOnly.rawValue)
        XCTAssertEqual(state["input"] as? Bool, true)
        XCTAssertEqual(state["drawingGesture"] as? Bool, true)

        // This fixture has a nil source PDF plus a previously written PKDrawing.
        // Tap several blank ruled-paper locations as the finger side of the
        // reported Apple Pencil + finger regression.
        for (index, position) in [(0.18, 0.27), (0.82, 0.36), (0.25, 0.72), (0.7, 0.81)].enumerated() {
            state = try info(page)
            try point(app, info: state, x: position.0, y: position.1).tap()
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertFalse(app.menuItems["Select All"].exists, "Unexpected Select All menu after finger tap \(index + 1)")
            XCTAssertFalse(app.buttons["Insert Space"].exists, "Unexpected Insert Space menu after finger tap \(index + 1)")
        }

        // Exercise the longer stationary touch that can trigger UIKit edit
        // menus on devices where the menu appears after a tap/hold sequence.
        state = try info(page)
        try point(app, info: state, x: 0.48, y: 0.5).press(forDuration: 1.0)
        XCTAssertFalse(app.menuItems["Select All"].exists)
        XCTAssertFalse(app.buttons["Insert Space"].exists)

        state = try info(page)
        XCTAssertEqual(state["strokes"] as? Int, 1,
            "Finger navigation must not modify or erase the existing PencilKit drawing")
        XCTAssertEqual(state["canvasEditMenuInteractions"] as? [String], [],
            "Native UIEditMenuInteraction should be absent from the canvas during ordinary ink input")
        XCTAssertEqual(state["pdfEditMenuInteractions"] as? [String], [],
            "PDFKit's edit menu interaction should also be absent while editing with the pen")
        XCTAssertEqual(state["drawingGesture"] as? Bool, true)
    }

    func testEraserModeAlsoSuppressesIncidentalFingerMenu() throws {
        let app = launch(tool: "pen")
        let page = app.staticTexts["editor.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        let eraser = app.buttons["Eraser"]
        XCTAssertTrue(eraser.waitForExistence(timeout: 10))
        eraser.tap()

        let geometry = try info(page)
        XCTAssertEqual(geometry["tool"] as? String, "eraser")
        try point(app, info: geometry, x: 0.12, y: 0.07).press(forDuration: 1.2)
        XCTAssertFalse(app.menuItems["Select All"].exists)
        XCTAssertFalse(app.buttons["Insert Space"].exists)
    }

    func testFingerDoubleTapZoomsAroundTapAndReturnsToFit() async throws {
        let app = launch(tool: "pen")
        let page = app.staticTexts["editor.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))

        let initial = try info(page)
        let initialScale = try XCTUnwrap(initial["scaleFactor"] as? Double)
        let initialPageRect = try XCTUnwrap(initial["rect"] as? [Double])
        let anchorX = initialPageRect[0] + initialPageRect[2] * 0.32
        let anchorY = initialPageRect[1] + initialPageRect[3] * 0.38
        let zoomTap = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: anchorX, dy: anchorY))
        zoomTap.doubleTap()

        var zoomed = try info(page)
        for _ in 0..<20 where (zoomed["scaleFactor"] as? Double ?? 0) <= initialScale * 1.1 {
            try await Task.sleep(for: .milliseconds(100))
            zoomed = try info(page)
        }
        let zoomedScale = try XCTUnwrap(zoomed["scaleFactor"] as? Double)
        XCTAssertGreaterThan(zoomedScale, initialScale * 1.1)
        let pageRect = try XCTUnwrap(zoomed["rect"] as? [Double])
        let canvasRect = try XCTUnwrap(zoomed["canvasRect"] as? [Double])
        XCTAssertEqual(anchorX,
            pageRect[0] + pageRect[2] * 0.32, accuracy: 8,
            "The tapped PDF point should remain near its original screen position")
        XCTAssertEqual(anchorY,
            pageRect[1] + pageRect[3] * 0.38, accuracy: 8,
            "The tapped PDF point should remain near its original screen position")
        for index in 0..<4 {
            XCTAssertEqual(canvasRect[index], pageRect[index], accuracy: 2,
                "PDF page and PencilKit canvas must remain registered after zoom")
        }

        zoomTap.doubleTap()
        var restored = try info(page)
        for _ in 0..<20 where (restored["scaleFactor"] as? Double ?? .greatestFiniteMagnitude) >= zoomedScale * 0.9 {
            try await Task.sleep(for: .milliseconds(100))
            restored = try info(page)
        }
        let restoredScale = try XCTUnwrap(restored["scaleFactor"] as? Double)
        XCTAssertEqual(restoredScale, initialScale, accuracy: 0.05)
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

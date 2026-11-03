import XCTest
import UIKit
@preconcurrency import PencilKit

@MainActor
final class EditorInteractionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(tool: String? = nil, rotatedCrop: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["JOTTRE_INTERACTION_TEST_TOOL"] = tool
        app.launchEnvironment["JOTTRE_INTERACTION_TEST_ROTATED_CROP"] = rotatedCrop ? "1" : "0"
        app.launch()
        return app
    }

    private func info(_ probe: XCUIElement) throws -> [String: Any] {
        let text = try XCTUnwrap(probe.value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func endpointDrift(
        in state: [String: Any],
        touchKey: String,
        strokeKey: String
    ) throws -> Double {
        let touch = try XCTUnwrap(state[touchKey] as? [Double])
        let stroke = try XCTUnwrap(state[strokeKey] as? [Double])
        XCTAssertEqual(touch.count, 2)
        XCTAssertEqual(stroke.count, 2)
        return hypot(touch[0] - stroke[0], touch[1] - stroke[1])
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

    func testSimulatorFingerInkRegistersIndependentPencilKitUndoAndRedoActions() async throws {
        let app = launch(tool: "scribble-undo")
        let page = app.staticTexts["editor.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))

        var state = try info(page)
        XCTAssertEqual(state["strokes"] as? Int, 0, "The fixture must start with an empty page drawing")
        XCTAssertEqual(state["drawingPolicy"] as? UInt, PKCanvasViewDrawingPolicy.anyInput.rawValue,
            "Only the DEBUG Simulator Scribble fixture accepts direct finger ink")
        XCTAssertEqual(state["currentPageIndex"] as? Int, 0)
        XCTAssertNotEqual(state["undoManagerIdentity"] as? String, "nil")

        let gestures: [(String, Double, Double, Double, Double)] = [
            ("A", 0.18, 0.28, 0.42, 0.28),
            ("B", 0.22, 0.50, 0.78, 0.50),
            ("C", 0.56, 0.72, 0.82, 0.72),
        ]
        var identities: [[UInt32]] = []
        for (name, startX, startY, endX, endY) in gestures {
            state = try info(page)
            let start = try point(app, info: state, x: startX, y: startY)
            let end = try point(app, info: state, x: endX, y: endY)
            start.press(forDuration: 0.01, thenDragTo: end)
            state = try await waitForDrawing(page, count: identities.count + 1)
            let seeds = try XCTUnwrap(state["strokeSeeds"] as? [UInt32])
            identities.append(seeds)
            XCTAssertEqual(seeds.count, identities.count, "One finger drag should create exactly one PKStroke for \(name)")
            XCTAssertEqual(state["groupingLevel"] as? Int, 0, "The completed PencilKit tool group must close after \(name)")
            XCTAssertEqual(state["groupsByEvent"] as? Bool, true,
                "This Simulator-only comparison deliberately leaves PencilKit in control of native event grouping")
            XCTAssertEqual(state["currentPageIndex"] as? Int, 0)
            XCTAssertEqual(state["isUndoing"] as? Bool, false)
            XCTAssertEqual(state["isRedoing"] as? Bool, false)
            XCTContext.runActivity(named: "Touch stroke \(name): \(String(describing: seeds))") { activity in
                activity.add(XCTAttachment(string: String(describing: state)))
            }
        }

        let a = try XCTUnwrap(identities[0].first)
        let b = try XCTUnwrap(identities[1].last)
        let c = try XCTUnwrap(identities[2].last)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(b, c)
        XCTAssertEqual(try info(page)["canUndo"] as? Bool, true)

        let undo = app.buttons["editor.test.undo"]
        let redo = app.buttons["editor.test.redo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(redo.exists)
        for expected in [[a, b], [a], []] as [[UInt32]] {
            undo.tap()
            state = try await waitForSeeds(page, expected)
            XCTAssertEqual(state["canRedo"] as? Bool, true)
            XCTAssertEqual(state["isUndoing"] as? Bool, false)
            XCTContext.runActivity(named: "PencilKit touch Undo: \(expected)") { activity in
                activity.add(XCTAttachment(string: String(describing: state)))
            }
        }
        for expected in [[a], [a, b], [a, b, c]] as [[UInt32]] {
            redo.tap()
            state = try await waitForSeeds(page, expected)
            XCTAssertEqual(state["canUndo"] as? Bool, true)
            XCTAssertEqual(state["isRedoing"] as? Bool, false)
            XCTContext.runActivity(named: "PencilKit touch Redo: \(expected)") { activity in
                activity.add(XCTAttachment(string: String(describing: state)))
            }
        }

        // XCTest's public coordinate API emits one straight drag per touch.
        // This crossing control is intentionally not called a Scribble: it
        // confirms the recognizer does not mistake a straight line for one.
        state = try info(page)
        try point(app, info: state, x: 0.18, y: 0.50)
            .press(forDuration: 0.01, thenDragTo: point(app, info: state, x: 0.82, y: 0.50))
        state = try await waitForDrawing(page, count: 4)
        XCTAssertEqual(state["scribbleRecognitionCount"] as? Int, 0)
        XCTAssertTrue((state["strokeSeeds"] as? [UInt32] ?? []).contains(b),
            "A straight finger drag across B must not erase it as a Scribble")
        undo.tap()
        state = try await waitForSeeds(page, [a, b, c])
        XCTAssertEqual(state["scribbleEraseApplicationCount"] as? Int, 0)

        let managerIdentity = try XCTUnwrap(state["undoManagerIdentity"] as? String)
        XCTAssertNotEqual(managerIdentity, "nil")
        XCTAssertEqual(state["groupingLevel"] as? Int, 0)
        XCTAssertEqual(state["scribbleRecognitionCount"] as? Int, 0,
            "Linear XCUITest drags are touch input but do not synthesize the multi-reversal Scribble path")
    }

    func testDetachedProgrammaticDrawingReplacementConsumesNativeUndoWithoutChangingDrawing() async throws {
        let app = launch(tool: "scribble-undo")
        let page = app.staticTexts["editor.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))

        var identities: [[UInt32]] = []
        for (name, startX, startY, endX, endY) in [
            ("A", 0.18, 0.28, 0.42, 0.28),
            ("B", 0.22, 0.50, 0.78, 0.50),
            ("C", 0.56, 0.72, 0.82, 0.72),
        ] {
            let state = try info(page)
            try point(app, info: state, x: startX, y: startY)
                .press(forDuration: 0.01, thenDragTo: point(app, info: state, x: endX, y: endY))
            let drawnState = try await waitForDrawing(page, count: identities.count + 1)
            identities.append(try XCTUnwrap(drawnState["strokeSeeds"] as? [UInt32]))
            XCTAssertEqual(identities.last?.count, identities.count, "Actual PencilKit input must create stroke \(name)")
        }
        let a = try XCTUnwrap(identities[0].first)
        let b = try XCTUnwrap(identities[1].last)
        let c = try XCTUnwrap(identities[2].last)

        let removeMiddle = app.buttons["editor.test.removeMiddleDetached"]
        XCTAssertTrue(removeMiddle.waitForExistence(timeout: 5))
        removeMiddle.tap()
        var state = try await waitForSeeds(page, [a, c])
        assertDrawingsSynchronized(state)
        XCTAssertTrue(try info(page)["canUndo"] as? Bool == true)

        let undo = app.buttons["editor.test.undo"]
        let managerBefore = try XCTUnwrap(state["undoManagerIdentity"] as? String)
        undo.tap()
        state = try await waitForSeeds(page, [a, c])
        assertDrawingsSynchronized(state)
        XCTAssertEqual(state["canRedo"] as? Bool, false,
            "The PKDrawing setter consumed the native Undo but did not produce a Drawing change")
        XCTAssertEqual(state["undoManagerIdentity"] as? String, managerBefore)
        XCTAssertEqual(state["canUndo"] as? Bool, true)
        print("[DrawingSyncExperiment] Detached replacement after Undo: seeds=\(state["strokeSeeds"] ?? []), coordinator=\(state["committedStrokeSeeds"] ?? []), model=\(state["viewModelStrokeSeeds"] ?? []), canUndo=\(state["canUndo"] ?? "nil"), canRedo=\(state["canRedo"] ?? "nil"), manager=\(state["undoManagerIdentity"] ?? "nil")")
        XCTContext.runActivity(named: "Detached PKDrawing replacement outcome") { activity in
            activity.add(XCTAttachment(string: String(describing: state)))
        }
    }

    func testCanvasOnlyProgrammaticDrawingReplacementIsolatesUndoMutation() async throws {
        let app = launch(tool: "scribble-undo")
        let page = app.staticTexts["editor.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        var identities: [[UInt32]] = []
        for (startX, startY, endX, endY) in [
            (0.18, 0.28, 0.42, 0.28),
            (0.22, 0.50, 0.78, 0.50),
            (0.56, 0.72, 0.82, 0.72),
        ] {
            let state = try info(page)
            try point(app, info: state, x: startX, y: startY)
                .press(forDuration: 0.01, thenDragTo: point(app, info: state, x: endX, y: endY))
            let drawnState = try await waitForDrawing(page, count: identities.count + 1)
            identities.append(try XCTUnwrap(drawnState["strokeSeeds"] as? [UInt32]))
        }
        let a = try XCTUnwrap(identities[0].first)
        let b = try XCTUnwrap(identities[1].last)
        let c = try XCTUnwrap(identities[2].last)
        let remove = app.buttons["editor.test.removeMiddleCanvasOnly"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        var state = try info(page)
        XCTAssertEqual(state["strokeSeeds"] as? [UInt32], [a, c])
        XCTAssertEqual(state["committedStrokeSeeds"] as? [UInt32], [a, b, c],
            "With the delegate deliberately suppressed, only PKCanvasView should change")
        XCTAssertEqual(state["viewModelStrokeSeeds"] as? [UInt32], [a, b, c])
        let managerBefore = try XCTUnwrap(state["undoManagerIdentity"] as? String)

        app.buttons["editor.test.undo"].tap()
        try await Task.sleep(for: .milliseconds(250))
        state = try info(page)
        let managerAfter = try XCTUnwrap(state["undoManagerIdentity"] as? String)
        XCTAssertEqual(managerAfter, managerBefore)
        XCTContext.runActivity(named: "Drawing-only replacement: native Undo outcome") { activity in
            activity.add(XCTAttachment(string: String(describing: state)))
        }
        let canvasSeedsAfterUndo = state["strokeSeeds"] as? [UInt32] ?? []
        let coordinatorSeedsAfterUndo = state["committedStrokeSeeds"] as? [UInt32] ?? []
        let modelSeedsAfterUndo = state["viewModelStrokeSeeds"] as? [UInt32] ?? []
        let canUndoAfterUndo = state["canUndo"] as? Bool ?? false
        let canRedoAfterUndo = state["canRedo"] as? Bool ?? false
        print("[DrawingSyncExperiment] Canvas-only D2 after Undo: \(canvasSeedsAfterUndo); coordinator=\(coordinatorSeedsAfterUndo); model=\(modelSeedsAfterUndo); canUndo=\(canUndoAfterUndo); canRedo=\(canRedoAfterUndo)")
    }

    func testCustomUndoRegistrationWithoutDrawingReplacementPreservesNativeStrokeUndo() async throws {
        let app = launch(tool: "scribble-undo")
        let page = app.staticTexts["editor.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        var identities: [[UInt32]] = []
        for (startX, startY, endX, endY) in [
            (0.18, 0.28, 0.42, 0.28),
            (0.22, 0.50, 0.78, 0.50),
            (0.56, 0.72, 0.82, 0.72),
        ] {
            let state = try info(page)
            try point(app, info: state, x: startX, y: startY)
                .press(forDuration: 0.01, thenDragTo: point(app, info: state, x: endX, y: endY))
            let drawnState = try await waitForDrawing(page, count: identities.count + 1)
            identities.append(try XCTUnwrap(drawnState["strokeSeeds"] as? [UInt32]))
        }
        let a = try XCTUnwrap(identities[0].first)
        let b = try XCTUnwrap(identities[1].last)
        let c = try XCTUnwrap(identities[2].last)
        let beforeRegistration = try info(page)
        let seedsBeforeRegistration = try XCTUnwrap(beforeRegistration["strokeSeeds"] as? [UInt32])
        let registerNoop = app.buttons["editor.test.registerNoopUndo"]
        XCTAssertTrue(registerNoop.waitForExistence(timeout: 5))
        registerNoop.tap()

        let undo = app.buttons["editor.test.undo"]
        undo.tap()
        var state = try await waitForSeeds(page, [a, b, c])
        XCTAssertEqual(state["customNoDrawingUndoCount"] as? Int, 3,
            "Three explicit groups registered in one event are coalesced by UndoManager's event grouping")
        XCTAssertEqual(state["strokeSeeds"] as? [UInt32], seedsBeforeRegistration)
        assertDrawingsSynchronized(state)

        undo.tap()
        state = try await waitForSeeds(page, [a, b])
        assertDrawingsSynchronized(state)
        undo.tap()
        state = try await waitForSeeds(page, [a])
        assertDrawingsSynchronized(state)
        undo.tap()
        state = try await waitForSeeds(page, [])
        assertDrawingsSynchronized(state)

        let redo = app.buttons["editor.test.redo"]
        for expected in [[a], [a, b], [a, b, c]] as [[UInt32]] {
            redo.tap()
            state = try await waitForSeeds(page, expected)
            assertDrawingsSynchronized(state)
        }
        redo.tap()
        state = try await waitForSeeds(page, [a, b, c])
        XCTAssertEqual(state["customNoDrawingUndoCount"] as? Int, 6,
            "The custom event-group transaction should Redo once after native stroke Redos")
        assertDrawingsSynchronized(state)
    }

    private func assertDrawingsSynchronized(
        _ state: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let canvas = state["strokeSeeds"] as? [UInt32]
        XCTAssertEqual(state["committedStrokeSeeds"] as? [UInt32], canvas, "Canvas/Coordinator mismatch", file: file, line: line)
        XCTAssertEqual(state["viewModelStrokeSeeds"] as? [UInt32], canvas, "Canvas/ViewModel mismatch", file: file, line: line)
    }

    private func waitForDrawing(_ page: XCUIElement, count: Int) async throws -> [String: Any] {
        var state = try info(page)
        for _ in 0..<40 where (state["strokes"] as? Int ?? -1) != count {
            try await Task.sleep(for: .milliseconds(100))
            state = try info(page)
        }
        let trace = state["undoTrace"] as? [String] ?? []
        XCTAssertEqual(state["strokes"] as? Int, count, "Drawing wait failed for \(count); state=\(state); undoTrace=\(trace)")
        return state
    }

    private func waitForSeeds(_ page: XCUIElement, _ expected: [UInt32]) async throws -> [String: Any] {
        var state = try info(page)
        for _ in 0..<40 where (state["strokeSeeds"] as? [UInt32]) != expected
            || state["isUndoing"] as? Bool == true
            || state["isRedoing"] as? Bool == true
            || state["groupingLevel"] as? Int != 0 {
            try await Task.sleep(for: .milliseconds(100))
            state = try info(page)
        }
        let trace = state["undoTrace"] as? [String] ?? []
        let undoState = state["lastFixtureUndoState"] as? String ?? "none"
        let undoCount = state["fixtureUndoActionCount"] as? Int ?? -1
        let manager = state["undoManagerIdentity"] as? String ?? "nil"
        XCTAssertEqual(
            state["strokeSeeds"] as? [UInt32],
            expected,
            "Undo trace: \(trace); fixtureUndo=\(undoState); undoCount=\(undoCount); manager=\(manager)"
        )
        return state
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

    func testMemoryFootprintAcrossHighZoomWithThreePageFourHundredSixteenStrokeFixture() async throws {
        let app = launch(tool: "zoom-memory")
        let page = app.staticTexts["editor.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        let zoomButton = app.buttons["editor.test.zoomFactor"]
        XCTAssertTrue(zoomButton.waitForExistence(timeout: 5))

        var state = try info(page)
        XCTAssertEqual(state["pdfPageCount"] as? Int, 3)
        XCTAssertEqual((state["committedStrokeSeeds"] as? [UInt32])?.count, 416)
        let baselineBytes = try XCTUnwrap(state["physicalFootprintBytes"] as? UInt64)
        print("[ZoomMemory] baseline footprint=\(baselineBytes) bytes (\(Double(baselineBytes) / 1_048_576) MiB) canvases=\(state["activeCanvasCount"] ?? "?") overlays=\(state["activeOverlayCount"] ?? "?")")

        let factors = [1.0, 2, 4, 8, 16, 32, 64]
        for factor in factors {
            var reachedTarget = false
            for attempt in 0..<5 where !reachedTarget {
                zoomButton.tap()
                state = try info(page)
                for _ in 0..<20 {
                    let ratio = try XCTUnwrap(state["scaleFactor"] as? Double)
                        / (try XCTUnwrap(state["fitScaleFactor"] as? Double))
                    if abs(ratio - factor) < max(0.05, factor * 0.01) {
                        reachedTarget = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    state = try info(page)
                }
                if !reachedTarget, attempt < 4 { try await Task.sleep(for: .milliseconds(200)) }
            }
            state = try info(page)
            let ratio = try XCTUnwrap(state["scaleFactor"] as? Double)
                / (try XCTUnwrap(state["fitScaleFactor"] as? Double))
            XCTAssertEqual(ratio, factor, accuracy: max(0.05, factor * 0.01))
            try await Task.sleep(for: .seconds(1))
            state = try info(page)
            let footprint = try XCTUnwrap(state["physicalFootprintBytes"] as? UInt64)
            let contentSize = try XCTUnwrap(state["contentSize"] as? [Double])
            let canvasBounds = try XCTUnwrap(state["canvasBounds"] as? [Double])
            print("[ZoomMemory] zoom=\(factor)x footprint=\(footprint) bytes (\(Double(footprint) / 1_048_576) MiB) canvasZoom=\(state["canvasZoom"] ?? "?") contentSize=\(contentSize) canvasBounds=\(canvasBounds) canvases=\(state["activeCanvasCount"] ?? "?") overlays=\(state["activeOverlayCount"] ?? "?")")

            if factor == 64 {
                let rectValues = try XCTUnwrap(state["rect"] as? [Double])
                let rect = CGRect(x: rectValues[0], y: rectValues[1], width: rectValues[2], height: rectValues[3])
                let visibleRect = rect.intersection(app.frame)
                let start = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: visibleRect.midX - 40, dy: visibleRect.midY))
                let end = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: visibleRect.midX + 40, dy: visibleRect.midY))
                let localStrokeCount = try XCTUnwrap(state["strokes"] as? Int)
                start.press(forDuration: 0.01, thenDragTo: end)
                state = try await waitForDrawing(page, count: localStrokeCount + 1)
                try await Task.sleep(for: .seconds(5))
                state = try info(page)
                let postInkBytes = try XCTUnwrap(state["physicalFootprintBytes"] as? UInt64)
                print("[ZoomMemory] after 64x ink + 5s footprint=\(postInkBytes) bytes (\(Double(postInkBytes) / 1_048_576) MiB) strokes=\(state["strokes"] ?? "?")")
                for sample in 1...11 {
                    try await Task.sleep(for: .seconds(5))
                    state = try info(page)
                    let sampleBytes = try XCTUnwrap(state["physicalFootprintBytes"] as? UInt64)
                    print("[ZoomMemory] 64x ink hold=\((sample + 1) * 5)s footprint=\(sampleBytes) bytes (\(Double(sampleBytes) / 1_048_576) MiB)")
                }
            }
        }

        zoomButton.tap() // 64x -> 1x
        try await Task.sleep(for: .seconds(2))
        state = try info(page)
        let reducedBytes = try XCTUnwrap(state["physicalFootprintBytes"] as? UInt64)
        print("[ZoomMemory] after zoom-out footprint=\(reducedBytes) bytes (\(Double(reducedBytes) / 1_048_576) MiB)")
    }

    func testSimulatorTouchInkStaysRegisteredFromOneToSixtyFourTimesZoom() async throws {
        let app = launch(tool: "scribble-undo")
        let page = app.staticTexts["editor.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        let zoomButton = app.buttons["editor.test.zoomFactor"]
        XCTAssertTrue(zoomButton.waitForExistence(timeout: 5))

        let factors = [1.0, 2, 4, 8, 16, 32, 64]
        var expectedStrokeCount = 0
        for (factorIndex, factor) in factors.enumerated() {
            zoomButton.tap()
            var state = try info(page)
            for _ in 0..<40 {
                let ratio = try XCTUnwrap(state["scaleFactor"] as? Double)
                    / (try XCTUnwrap(state["fitScaleFactor"] as? Double))
                let drawingSize = try XCTUnwrap(state["drawingSize"] as? [Double])
                let canvasZoom = try XCTUnwrap(state["canvasZoom"] as? Double)
                let canvasScale = try XCTUnwrap(state["canvasRect"] as? [Double])[2] / drawingSize[0]
                if abs(ratio - factor) < max(0.05, factor * 0.01), abs(canvasZoom - canvasScale) < 0.01 { break }
                try await Task.sleep(for: .milliseconds(100))
                state = try info(page)
            }
            state = try info(page)
            let settledRatio = try XCTUnwrap(state["scaleFactor"] as? Double)
                / (try XCTUnwrap(state["fitScaleFactor"] as? Double))
            XCTAssertEqual(settledRatio, factor, accuracy: max(0.05, factor * 0.01),
                "Fixture did not reach the requested zoom factor \(factor)x")

            let pageValues = try XCTUnwrap(state["rect"] as? [Double])
            let drawingSize = try XCTUnwrap(state["drawingSize"] as? [Double])
            let settledCanvasRect = try XCTUnwrap(state["canvasRect"] as? [Double])
            XCTContext.runActivity(named: "Pre-input geometry at \(factor)x") { activity in
                activity.add(XCTAttachment(string: String(describing: state)))
            }
            let viewportTransform = try XCTUnwrap(state["viewportHostTransform"] as? [Double])
            let effectiveScale = try XCTUnwrap(state["canvasZoom"] as? Double)
                * viewportTransform[0]
                * (try XCTUnwrap(state["measuredDisplayScale"] as? Double))
            XCTAssertEqual(effectiveScale, settledCanvasRect[2] / drawingSize[0], accuracy: 0.01,
                "Canvas and residual viewport scaling must compose to the PDF page scale at \(factor)x")
            let pageRect = CGRect(x: pageValues[0], y: pageValues[1], width: pageValues[2], height: pageValues[3])
            let visibleRect = pageRect.intersection(app.frame)
            XCTAssertFalse(visibleRect.isNull || visibleRect.isEmpty, "No visible page at \(factor)x: \(pageRect)")
            let startScreen: CGPoint
            let endScreen: CGPoint
            switch factorIndex % 3 {
            case 0:
                startScreen = CGPoint(x: visibleRect.minX + 100, y: visibleRect.minY + 300)
                endScreen = CGPoint(x: visibleRect.minX + 220, y: visibleRect.minY + 300)
            case 1:
                startScreen = CGPoint(x: visibleRect.midX - 80, y: visibleRect.midY)
                endScreen = CGPoint(x: visibleRect.midX + 80, y: visibleRect.midY)
            default:
                let lowerPageY = visibleRect.minY + visibleRect.height * 0.72
                startScreen = CGPoint(x: visibleRect.maxX - 300, y: lowerPageY)
                endScreen = CGPoint(x: visibleRect.maxX - 180, y: lowerPageY)
            }
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: startScreen.x, dy: startScreen.y))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: endScreen.x, dy: endScreen.y))
            start.press(forDuration: 0.01, thenDragTo: end)
            expectedStrokeCount += 1
            state = try await waitForDrawing(page, count: expectedStrokeCount)

            let startError = try endpointDrift(
                in: state, touchKey: "touchStartWindow", strokeKey: "lastStrokeStartWindow"
            )
            let endError = try endpointDrift(
                in: state, touchKey: "touchEndWindow", strokeKey: "lastStrokeEndWindow"
            )
            let reportedStartErrorPixels = try XCTUnwrap(state["lastStrokeStartErrorPixels"] as? Double)
            let screenScale = try XCTUnwrap(state["screenScale"] as? Double)
            XCTAssertEqual(reportedStartErrorPixels, startError * screenScale, accuracy: 0.1,
                "Fixture and controller must compare the same touch-to-stroke endpoints")
            print("[ZoomCoordinate] requested=\(factor)x touchToStrokeStart=\(startError)pt touchToStrokeEnd=\(endError)pt")
            XCTContext.runActivity(named: "Actual finger ink at \(factor)x") { activity in
                activity.add(XCTAttachment(string: "state=\(state)\nstartErrorPixels=\(startError)\nendErrorPixels=\(endError)"))
            }
            XCTAssertLessThan(startError, 12, "Touch-to-stroke start drifted by \(startError) screen points at \(factor)x")
            XCTAssertLessThan(endError, 12, "Touch-to-stroke end drifted by \(endError) screen points at \(factor)x")
            let canvasRect = try XCTUnwrap(state["canvasRect"] as? [Double])
            for index in 0..<4 {
                XCTAssertEqual(canvasRect[index], pageValues[index], accuracy: 2)
            }
        }

        // At the 32x stress point, compare the three independent UIScrollView
        // state variants: automatic contentSize, natural contentOffset, and both.
        for _ in 0..<5 { zoomButton.tap() } // 64x -> 1x -> 2x -> 4x -> 8x -> 16x
        zoomButton.tap() // 32x
        var state = try info(page)
        for _ in 0..<40 {
            let ratio = try XCTUnwrap(state["scaleFactor"] as? Double)
                / (try XCTUnwrap(state["fitScaleFactor"] as? Double))
            if abs(ratio - 32) < 0.32 { break }
            try await Task.sleep(for: .milliseconds(100))
            state = try info(page)
        }
        let settledRatio = try XCTUnwrap(state["scaleFactor"] as? Double)
            / (try XCTUnwrap(state["fitScaleFactor"] as? Double))
        XCTAssertEqual(settledRatio, 32, accuracy: 0.32)
        let geometryButton = app.buttons["editor.test.geometryExperiment"]
        XCTAssertTrue(geometryButton.waitForExistence(timeout: 5))
        for expectedMode in 1...3 {
            geometryButton.tap()
            state = try info(page)
            XCTAssertEqual(state["geometryExperimentMode"] as? Int, expectedMode)
            let pageValues = try XCTUnwrap(state["rect"] as? [Double])
            let pageRect = CGRect(x: pageValues[0], y: pageValues[1], width: pageValues[2], height: pageValues[3])
            let visibleRect = pageRect.intersection(app.frame)
            let startScreen = CGPoint(x: visibleRect.midX - 24, y: visibleRect.midY)
            let endScreen = CGPoint(x: visibleRect.midX + 24, y: visibleRect.midY)
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: startScreen.x, dy: startScreen.y))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: endScreen.x, dy: endScreen.y))
            start.press(forDuration: 0.01, thenDragTo: end)
            expectedStrokeCount += 1
            state = try await waitForDrawing(page, count: expectedStrokeCount)
            let startError = try endpointDrift(
                in: state, touchKey: "touchStartWindow", strokeKey: "lastStrokeStartWindow"
            )
            let endError = try endpointDrift(
                in: state, touchKey: "touchEndWindow", strokeKey: "lastStrokeEndWindow"
            )
            print("[ZoomCoordinate] geometryMode=\(expectedMode) requested=32x touchToStrokeStart=\(startError)pt touchToStrokeEnd=\(endError)pt")
            XCTContext.runActivity(named: "32x geometry experiment \(expectedMode)") { activity in
                activity.add(XCTAttachment(string: "state=\(state)\nstartErrorPixels=\(startError)\nendErrorPixels=\(endError)"))
            }
            XCTAssertLessThan(startError, 12, "Geometry experiment \(expectedMode) start drifted by \(startError) points")
            XCTAssertLessThan(endError, 12, "Geometry experiment \(expectedMode) end drifted by \(endError) points")
        }
    }

    func testRotatedPageWithNonzeroCropOriginKeepsHighZoomTouchCoordinatesRegistered() async throws {
        let app = launch(tool: "scribble-undo", rotatedCrop: true)
        let page = app.staticTexts["editor.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        let zoomButton = app.buttons["editor.test.zoomFactor"]
        XCTAssertTrue(zoomButton.waitForExistence(timeout: 5))
        for _ in 0..<6 { zoomButton.tap() } // 1x -> 32x

        var state = try info(page)
        for _ in 0..<40 {
            let ratio = try XCTUnwrap(state["scaleFactor"] as? Double)
                / (try XCTUnwrap(state["fitScaleFactor"] as? Double))
            if abs(ratio - 32) < 0.32 { break }
            try await Task.sleep(for: .milliseconds(100))
            state = try info(page)
        }
        state = try info(page)
        let settledRatio = try XCTUnwrap(state["scaleFactor"] as? Double)
            / (try XCTUnwrap(state["fitScaleFactor"] as? Double))
        XCTAssertEqual(settledRatio, 32, accuracy: 0.32,
            "Rotated crop fixture did not reach 32x")
        XCTAssertEqual(state["pageRotation"] as? Int, 90)
        let crop = try XCTUnwrap(state["cropBox"] as? [Double])
        XCTAssertEqual(crop[0], 40, accuracy: 0.01)
        XCTAssertEqual(crop[1], 60, accuracy: 0.01)

        let pageValues = try XCTUnwrap(state["rect"] as? [Double])
        let pageRect = CGRect(x: pageValues[0], y: pageValues[1], width: pageValues[2], height: pageValues[3])
        let visibleRect = pageRect.intersection(app.frame)
        XCTAssertFalse(visibleRect.isNull || visibleRect.isEmpty)
        let startScreen = CGPoint(x: visibleRect.midX - 24, y: visibleRect.midY)
        let endScreen = CGPoint(x: visibleRect.midX + 24, y: visibleRect.midY)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: startScreen.x, dy: startScreen.y))
            .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: endScreen.x, dy: endScreen.y)))
        state = try await waitForDrawing(page, count: 1)
        let startError = try endpointDrift(
            in: state, touchKey: "touchStartWindow", strokeKey: "lastStrokeStartWindow"
        )
        let endError = try endpointDrift(
            in: state, touchKey: "touchEndWindow", strokeKey: "lastStrokeEndWindow"
        )
        print("[ZoomCoordinate] rotatedCrop=90deg requested=32x touchToStrokeStart=\(startError)pt touchToStrokeEnd=\(endError)pt")
        XCTContext.runActivity(named: "Rotated crop geometry at 32x") { activity in
            activity.add(XCTAttachment(string: "state=\(state)\nstartError=\(startError)\nendError=\(endError)"))
        }
        XCTAssertLessThan(startError, 12, "Rotated crop start drifted by \(startError); state=\(state)")
        XCTAssertLessThan(endError, 12, "Rotated crop end drifted by \(endError); state=\(state)")
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

    func testFingerDoubleTapAlternatesPageFitAndKeepsPDFLayoutAligned() async throws {
        let app = launch(tool: "pen")
        let page = app.staticTexts["editor.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))

        let initial = try info(page)
        let initialPageRect = try XCTUnwrap(initial["rect"] as? [Double])
        let initialViewport = try XCTUnwrap(initial["viewportRect"] as? [Double])
        let startsAtWidthFit = abs(initialPageRect[2] - initialViewport[2]) <= 8
            || abs(initialPageRect[2] - initialViewport[2] * 0.97) <= 8
        let startsAtHeightFit = abs(initialPageRect[3] - initialViewport[3]) <= 8
        XCTAssertTrue(startsAtWidthFit || startsAtHeightFit,
            "PDFKit should begin at one of the page-fit scales")
        let firstTapFitsHeight = startsAtWidthFit
        let anchorX = initialPageRect[0] + initialPageRect[2] * 0.32
        let anchorY = initialPageRect[1] + initialPageRect[3] * 0.38
        let zoomTap = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: anchorX, dy: anchorY))
        zoomTap.doubleTap()

        var zoomed = try info(page)
        for _ in 0..<30 {
            guard let rect = zoomed["rect"] as? [Double] else { break }
            let fittedDimension = firstTapFitsHeight ? rect[3] : rect[2]
            let viewportDimension = firstTapFitsHeight ? initialViewport[3] : initialViewport[2]
            if abs(fittedDimension - viewportDimension) <= 8 { break }
            try await Task.sleep(for: .milliseconds(100))
            zoomed = try info(page)
        }
        let pageRect = try XCTUnwrap(zoomed["rect"] as? [Double])
        let viewportRect = try XCTUnwrap(zoomed["viewportRect"] as? [Double])
        let canvasRect = try XCTUnwrap(zoomed["canvasRect"] as? [Double])
        if firstTapFitsHeight {
            XCTAssertEqual(pageRect[3], viewportRect[3], accuracy: 8,
                "A tap from width-fit should select height-fit")
            XCTAssertEqual(anchorX, pageRect[0] + pageRect[2] * 0.32, accuracy: 10,
                "The zoom should keep the tapped point anchored on the scrollable axis")
        } else {
            XCTAssertEqual(pageRect[2], viewportRect[2] * 0.97, accuracy: 8,
                "A tap from height-fit should select width-fit with a small horizontal gutter")
            XCTAssertEqual(anchorY, pageRect[1] + pageRect[3] * 0.38, accuracy: 10,
                "The zoom should keep the tapped point anchored on the scrollable axis")
        }
        for index in 0..<4 {
            XCTAssertEqual(canvasRect[index], pageRect[index], accuracy: 2,
                "PDF page and PencilKit canvas must remain registered after zoom")
        }

        let secondTap = try point(app, info: zoomed, x: 0.75, y: 0.45)
        secondTap.doubleTap()
        var fitted = try info(page)
        for _ in 0..<30 {
            guard let rect = fitted["rect"] as? [Double] else { break }
            let fittedDimension = firstTapFitsHeight ? rect[2] : rect[3]
            let viewportDimension = firstTapFitsHeight ? viewportRect[2] * 0.97 : viewportRect[3]
            if abs(fittedDimension - viewportDimension) <= 8 { break }
            try await Task.sleep(for: .milliseconds(100))
            fitted = try info(page)
        }
        let fittedRect = try XCTUnwrap(fitted["rect"] as? [Double])
        let fittedViewport = try XCTUnwrap(fitted["viewportRect"] as? [Double])
        let fittedCanvas = try XCTUnwrap(fitted["canvasRect"] as? [Double])
        if firstTapFitsHeight {
            XCTAssertEqual(fittedRect[2], fittedViewport[2] * 0.97, accuracy: 8,
                "The next double tap should return to width-fit")
        } else {
            XCTAssertEqual(fittedRect[3], fittedViewport[3], accuracy: 8,
                "The next double tap should return to height-fit")
        }
        XCTAssertEqual(fittedRect[0] + fittedRect[2] / 2,
            fittedViewport[0] + fittedViewport[2] / 2, accuracy: 8,
            "PDFKit should center a page narrower than the viewport")
        for index in 0..<4 {
            XCTAssertEqual(fittedCanvas[index], fittedRect[index], accuracy: 2)
        }
    }

    func testRulerStateSurvivesPageSwitchAndZoomNavigation() async throws {
        let app = launch(tool: "pen")
        let first = app.staticTexts["editor.page.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let rulerButton = app.buttons["Ruler"]
        XCTAssertTrue(rulerButton.waitForExistence(timeout: 10))
        rulerButton.tap()

        var state = try info(first)
        for _ in 0..<20 where state["canvasRulerActive"] as? Bool != true {
            try await Task.sleep(for: .milliseconds(100))
            state = try info(first)
        }
        XCTAssertEqual(state["pickerRulerActive"] as? Bool, true)
        XCTAssertEqual(state["canvasRulerActive"] as? Bool, true,
            "The active page canvas must retain the Picker's ruler state")
        let rulerScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        rulerScreenshot.name = "Ruler active on page 1"
        rulerScreenshot.lifetime = .keepAlways
        add(rulerScreenshot)

        let nextPageButton = app.buttons["editor.test.nextPage"]
        XCTAssertTrue(nextPageButton.waitForExistence(timeout: 5))
        nextPageButton.tap()
        let second = app.staticTexts["editor.page.1"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        state = try info(second)
        for _ in 0..<20 where state["currentPageIndex"] as? Int != 1 {
            try await Task.sleep(for: .milliseconds(100))
            state = try info(second)
        }
        XCTAssertEqual(state["currentPageIndex"] as? Int, 1,
            "The test must check the selected page rather than a prefetched overlay")
        XCTAssertEqual(state["pickerRulerActive"] as? Bool, true)
        XCTAssertEqual(state["canvasRulerActive"] as? Bool, true,
            "The newly active page must inherit the active ruler")
        let nextPageRulerScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        nextPageRulerScreenshot.name = "Ruler remains visible after page change"
        nextPageRulerScreenshot.lifetime = .keepAlways
        add(nextPageRulerScreenshot)

        try point(app, info: state, x: 0.5, y: 0.5).doubleTap()
        try await Task.sleep(for: .milliseconds(450))
        state = try info(second)
        XCTAssertEqual(state["pickerRulerActive"] as? Bool, true)
        XCTAssertEqual(state["canvasRulerActive"] as? Bool, true,
            "Zoom and overlay geometry updates must not deactivate the ruler")

        rulerButton.tap()
        state = try info(second)
        for _ in 0..<20 where state["canvasRulerActive"] as? Bool != false {
            try await Task.sleep(for: .milliseconds(100))
            state = try info(second)
        }
        XCTAssertEqual(state["pickerRulerActive"] as? Bool, false)
        XCTAssertEqual(state["canvasRulerActive"] as? Bool, false)
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

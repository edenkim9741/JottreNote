import XCTest
import UIKit
@preconcurrency import PencilKit

@MainActor
final class EditorInteractionUITests: XCTestCase {
    private var scrollTestIteration = 1
    private var scrollTestFailures: [[String: Any]] = []
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(
        tool: String? = nil,
        rotatedCrop: Bool = false,
        drawingPipelineEnabled: Bool = true,
        coordinateTransformProbe: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["JOTTRE_INTERACTION_TEST_TOOL"] = tool
        app.launchEnvironment["JOTTRE_INTERACTION_TEST_ROTATED_CROP"] = rotatedCrop ? "1" : "0"
        app.launchEnvironment["JOTTRE_INTERACTION_TEST_PIPELINE"] = drawingPipelineEnabled ? "on" : "off"
        app.launchEnvironment["JOTTRE_INTERACTION_TEST_TRANSFORM_PROBE"] = coordinateTransformProbe ? "1" : "0"
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

    private func visiblePageProbe(in app: XCUIApplication) throws -> XCUIElement {
        let probes = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'editor.page.'"))
        let visible = probes.allElementsBoundByIndex.first { $0.exists && $0.isHittable }
        if let visible { return visible }
        return try XCTUnwrap(probes.allElementsBoundByIndex.first { $0.exists }, "No editor geometry probe is available")
    }

    private func scrollCoordinate(
        _ app: XCUIApplication,
        state: [String: Any],
        x: Double,
        y: Double
    ) throws -> XCUICoordinate {
        let rect = try XCTUnwrap(state["viewportRect"] as? [Double])
        XCTAssertEqual(rect.count, 4)
        return app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: rect[0] + rect[2] * x, dy: rect[1] + rect[3] * y)
        )
    }

    private func selectScrollTool(_ name: String, in app: XCUIApplication) async throws {
        let button = app.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 8), "PencilKit tool picker must expose the \(name) tool")
        button.tap()
        var state = try info(try visiblePageProbe(in: app))
        for _ in 0..<30 where state["tool"] as? String != name.lowercased() {
            try await Task.sleep(for: .milliseconds(100))
            state = try info(try visiblePageProbe(in: app))
        }
        XCTAssertEqual(state["tool"] as? String, name.lowercased(), "The fixture must confirm selected \(name) state")
    }

    private func performScrollSeries(
        _ category: String,
        count: Int,
        app: XCUIApplication
    ) async throws {
        var failures: [[String: Any]] = []
        var before = try info(try visiblePageProbe(in: app))
        for attempt in 1...count {
            let offsetBefore = try XCTUnwrap(before["pdfScrollViewContentOffset"] as? [Double])
            let range = try XCTUnwrap(before["pdfScrollRange"] as? [Double])
            let pageRectBefore = try XCTUnwrap(before["rect"] as? [Double])
            let beforeTransitions = before["pdfPanTransitions"] as? [[String: Any]] ?? []
            let previousPanSequence = beforeTransitions.compactMap { $0["sequence"] as? Int }.max() ?? 0
            let beforeFallbackTransitions = before["pdfFallbackPanTransitions"] as? [[String: Any]] ?? []
            let previousFallbackSequence = beforeFallbackTransitions.compactMap { $0["sequence"] as? Int }.max() ?? 0
            guard offsetBefore.count == 2, range.count == 4, pageRectBefore.count == 4 else {
                throw NSError(domain: "ScrollFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid scroll probe geometry"])
            }
            let downRoom = range[3] - offsetBefore[1]
            let upRoom = offsetBefore[1] - range[2]
            let fingerMovesUp = downRoom > 40 || upRoom <= 40
            let startY = fingerMovesUp ? 0.78 : 0.28
            let endY = fingerMovesUp ? 0.28 : 0.78
            let start = try scrollCoordinate(app, state: before, x: 0.50, y: startY)
            let end = try scrollCoordinate(app, state: before, x: 0.50, y: endY)
            start.press(forDuration: 0.01, thenDragTo: end)
            try await Task.sleep(for: .milliseconds(100))
            let afterProbe = try visiblePageProbe(in: app)
            let after = try info(afterProbe)
            let offsetAfter = try XCTUnwrap(after["pdfScrollViewContentOffset"] as? [Double])
            let pageRectAfter = try XCTUnwrap(after["rect"] as? [Double])
            let panTransitions = (after["pdfPanTransitions"] as? [[String: Any]] ?? []).filter {
                ($0["sequence"] as? Int ?? 0) > previousPanSequence
            }
            let panStates = panTransitions.compactMap { $0["stateName"] as? String }
            let fallbackTransitions = (after["pdfFallbackPanTransitions"] as? [[String: Any]] ?? []).filter {
                ($0["sequence"] as? Int ?? 0) > previousFallbackSequence
            }
            let fallbackStates = fallbackTransitions.compactMap { $0["stateName"] as? String }
            let delta = offsetAfter[1] - offsetBefore[1]
            let pageDelta = pageRectAfter[1] - pageRectBefore[1]
            let panPolicyCorrect = (after["pdfPanMinimumNumberOfTouches"] as? Int) == 1
                && (after["pdfPanMaximumNumberOfTouches"] as? Int ?? 0) >= 2
                && (after["pdfPanAllowedTouchTypes"] as? [Int]) == [0]
            let movedInExpectedDirection = fingerMovesUp ? delta > 10 : delta < -10
            let displayMoved = abs(pageDelta) > 2
            let nativePanScrolled = panStates.contains("began")
                && panStates.contains("changed")
                && panStates.contains("ended")
            let fallbackReasonObserved = fallbackTransitions.contains {
                let reason = $0["fallbackReason"] as? String
                return reason == "nativePDFPanFailed" || reason == "nativePDFPanDidNotTrackTouch"
            }
            let fallbackPanScrolled = fallbackReasonObserved
                && fallbackStates.contains("began")
                && fallbackStates.contains("changed")
                && fallbackStates.contains("ended")
            let navigationPathSucceeded = nativePanScrolled || fallbackPanScrolled
            let passed = range[3] - range[2] > 100
                && (fingerMovesUp ? downRoom > 20 : upRoom > 20)
                && navigationPathSucceeded
                && panPolicyCorrect
                && movedInExpectedDirection
                && displayMoved
            let failureReason: String
            if range[3] - range[2] <= 100 {
                failureReason = "fixture has no meaningful vertical scroll range"
            } else if !panPolicyCorrect {
                failureReason = "PDF pan touch policy changed during the test"
            } else if !navigationPathSucceeded {
                failureReason = panStates.contains("began")
                    ? "PDF pan started but neither native nor fallback navigation completed"
                    : "PDF pan did not enter began and diagnosed fallback did not scroll"
            } else if !panStates.contains("changed") {
                failureReason = "PDF pan did not enter changed"
            } else if panStates.contains("failed") || panStates.contains("cancelled") {
                failureReason = "PDF pan ended failed or cancelled"
            } else if !panStates.contains("ended") {
                failureReason = "PDF pan did not end normally"
            } else if abs(delta) <= 10 {
                failureReason = "PDF contentOffset did not move meaningfully"
            } else {
                failureReason = "PDF page display did not move"
            }
            let attemptData: [String: Any] = [
                "iteration": scrollTestIteration,
                "testCase": category,
                "attempt": attempt,
                "activeTool": after["tool"] ?? "unknown",
                "inputStart": [start.screenPoint.x, start.screenPoint.y],
                "inputEnd": [end.screenPoint.x, end.screenPoint.y],
                "pdfPanState": after["pdfPanState"] ?? -1,
                "pdfPanEnabled": after["pdfPanEnabled"] ?? false,
                "pdfScrollEnabled": after["pdfScrollEnabled"] ?? false,
                "pdfPanIdentity": after["pdfPanIdentity"] ?? "unknown",
                "pdfPanTransitions": panTransitions,
                "pdfFallbackPanTransitions": fallbackTransitions,
                "panPolicyCorrect": panPolicyCorrect,
                "canvasPanState": after["canvasPanState"] ?? -1,
                "canvasPanIdentity": after["canvasPanIdentity"] ?? "unknown",
                "minimumNumberOfTouches": after["pdfPanMinimumNumberOfTouches"] ?? -1,
                "maximumNumberOfTouches": after["pdfPanMaximumNumberOfTouches"] ?? -1,
                "allowedTouchTypes": after["pdfPanAllowedTouchTypes"] ?? [],
                "scrollOffsetBefore": offsetBefore,
                "scrollOffsetAfter": offsetAfter,
                "scrollRange": range,
                "displayPageYBefore": pageRectBefore[1],
                "displayPageYAfter": pageRectAfter[1],
                "hitTestTarget": after["actualDirectTouchHitTestTarget"] ?? "unobserved",
                "pdfCenterHitTestTarget": after["hitTestTarget"] ?? "unknown",
                "actualDirectTouchHitTestTarget": after["actualDirectTouchHitTestTarget"] ?? "unobserved",
                "pdfViewHitTestLocation": after["pdfViewHitTestLocation"] ?? [],
                "pdfViewHitTestTouchTypes": after["pdfViewHitTestTouchTypes"] ?? [],
                "currentPageIndex": after["currentPageIndex"] ?? -1,
                "viewportRect": after["viewportRect"] ?? [],
                "pdfScrollViewIdentity": after["pdfScrollViewIdentity"] ?? "unknown",
                "scaleFactor": after["scaleFactor"] ?? 0,
                "canvasZoom": after["canvasZoom"] ?? 0,
                "canvasBounds": after["canvasBounds"] ?? [],
                "canvasContentSize": after["contentSize"] ?? [],
                "physicalFootprintBytes": after["physicalFootprintBytes"] ?? 0,
                "canvasOverlayLastTouchHitTestTarget": after["canvasOverlayLastTouchHitTestTarget"] ?? "unobserved",
                "canvasOffset": after["contentOffset"] ?? [],
                "passed": passed,
                "failureReason": passed ? NSNull() : failureReason,
                "sourceFix": "native PDF pan handles accepted touches; app-owned direct-touch fallback only updates offsets when native PDF pan fails"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: attemptData, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) {
                print("SCROLL_TEST_ATTEMPT=\(line)")
            }
            if !passed { failures.append(attemptData) }
            before = after
        }
        scrollTestFailures.append(contentsOf: failures)
    }

    func testPDFSingleFingerScrollRegressionMatrix350Drags() async throws {
        scrollTestIteration = 3
        scrollTestFailures = []
        let app = launch(tool: "scroll")
        let first = app.staticTexts["editor.page.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let initial = try info(first)
        XCTAssertEqual(initial["pdfPageCount"] as? Int, 8)
        XCTAssertEqual(initial["pdfPanMinimumNumberOfTouches"] as? Int, 1)
        XCTAssertGreaterThan((initial["pdfScrollRange"] as? [Double] ?? [0, 0, 0, 0])[3]
            - (initial["pdfScrollRange"] as? [Double] ?? [0, 0, 0, 0])[2], 100)

        try await performScrollSeries("basic", count: 50, app: app)
        try await selectScrollTool("Pen", in: app)
        try await performScrollSeries("pen", count: 50, app: app)
        try await selectScrollTool("Lasso", in: app)
        try await performScrollSeries("lasso", count: 50, app: app)

        for attempt in 1...50 {
            try await selectScrollTool(attempt.isMultiple(of: 2) ? "Pen" : "Lasso", in: app)
            try await performScrollSeries("tool-transition-\(attempt)", count: 1, app: app)
        }

        let pinchSurface = app.otherElements["editor.test.pdfNavigation"]
        XCTAssertTrue(pinchSurface.waitForExistence(timeout: 5))
        pinchSurface.pinch(withScale: 1.7, velocity: 1.0)
        try await Task.sleep(for: .milliseconds(350))
        try await performScrollSeries("after-pinch", count: 50, app: app)

        let zoom = app.buttons["editor.test.zoomFactor"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 5))
        for _ in 0..<6 { zoom.tap() }
        try await Task.sleep(for: .milliseconds(350))
        let highZoom = try info(try visiblePageProbe(in: app))
        XCTAssertGreaterThanOrEqual(highZoom["scaleFactor"] as? Double ?? 0, 16)
        try await performScrollSeries("high-zoom", count: 50, app: app)

        // Advance through real PDF pan gestures, then exercise the same input
        // path after the visible page has changed.
        try await performScrollSeries("page-transition", count: 50, app: app)

        if !scrollTestFailures.isEmpty {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "Scroll regression matrix failures"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTContext.runActivity(named: "All 350 scroll failure records") { activity in
                activity.add(XCTAttachment(string: String(describing: scrollTestFailures)))
            }
            XCTFail("The 350-drag matrix had \(scrollTestFailures.count) failure(s); first: \(scrollTestFailures[0])")
        }
    }

    func testHighZoomSingleFingerScrollStateReproduction50Drags() async throws {
        scrollTestIteration = 2
        scrollTestFailures = []
        let app = launch(tool: "scroll")
        let page = app.staticTexts["editor.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        let zoom = app.buttons["editor.test.zoomFactor"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 5))
        for _ in 0..<6 { zoom.tap() }
        try await Task.sleep(for: .milliseconds(350))
        let state = try info(try visiblePageProbe(in: app))
        XCTAssertGreaterThanOrEqual(state["scaleFactor"] as? Double ?? 0, 16)
        try await performScrollSeries("high-zoom-failure-reproduction", count: 50, app: app)
        XCTAssertTrue(scrollTestFailures.isEmpty,
            "The high-zoom reproduction had \(scrollTestFailures.count) failure(s): \(scrollTestFailures.first ?? [:])")
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
        print("[ZoomMemory] fixture pdfBytes=\(state["pdfDataBytes"] ?? "?") pages=\(state["pdfPageCount"] ?? "?") documentStrokes=\((state["committedStrokeSeeds"] as? [UInt32])?.count ?? -1)")
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

    func testStreamingCoordinateTransformMatchesInterpolatedPathSamples() throws {
        let app = launch(tool: "zoom-memory", coordinateTransformProbe: true)
        let page = app.staticTexts["editor.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        let state = try info(page)
        let probe = try XCTUnwrap(state["coordinateTransformProbe"] as? [String: Any])
        print("[CoordinateTransformProbe] \(probe)")
        XCTAssertEqual(probe["passed"] as? Bool, true)
        XCTAssertEqual(probe["interpolationTriggered"] as? Bool, true)
        XCTAssertGreaterThan(probe["interpolatedPointCount"] as? Int ?? 0,
                             probe["inputPointCount"] as? Int ?? Int.max)
        XCTAssertEqual(probe["mappedPointCount"] as? Int, probe["interpolatedPointCount"] as? Int)
        app.terminate()
    }

    func testHighZoomInputSeparatesPencilKitFromDrawingPipelineMemory() async throws {
        for pipelineEnabled in [true, false] {
            let app = launch(tool: "zoom-memory", drawingPipelineEnabled: pipelineEnabled)
            let page = app.staticTexts["editor.page.0"]
            XCTAssertTrue(page.waitForExistence(timeout: 15))
            let zoomButton = app.buttons["editor.test.zoomFactor"]
            XCTAssertTrue(zoomButton.waitForExistence(timeout: 5))
            var state = try info(page)
            XCTAssertEqual(state["drawingPipelineEnabled"] as? Bool, pipelineEnabled)

            for factor in [1.0, 2, 4, 8, 16, 32, 64] {
                zoomButton.tap()
                state = try info(page)
                for _ in 0..<40 {
                    let ratio = try XCTUnwrap(state["scaleFactor"] as? Double)
                        / (try XCTUnwrap(state["fitScaleFactor"] as? Double))
                    if abs(ratio - factor) < max(0.05, factor * 0.01) { break }
                    try await Task.sleep(for: .milliseconds(100))
                    state = try info(page)
                }
                let ratio = try XCTUnwrap(state["scaleFactor"] as? Double)
                    / (try XCTUnwrap(state["fitScaleFactor"] as? Double))
                XCTAssertEqual(ratio, factor, accuracy: max(0.05, factor * 0.01))
            }

            let baselineFootprint = try XCTUnwrap(state["physicalFootprintBytes"] as? UInt64)
            var expectedStrokeCount = try XCTUnwrap(state["strokes"] as? Int)
            for index in 0..<5 {
                state = try info(page)
                let pageValues = try XCTUnwrap(state["rect"] as? [Double])
                let pageRect = CGRect(x: pageValues[0], y: pageValues[1], width: pageValues[2], height: pageValues[3])
                let visible = pageRect.intersection(app.frame)
                let y = visible.minY + visible.height * (0.35 + Double(index % 2) * 0.3)
                let start = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: visible.midX - 36, dy: y))
                let end = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: visible.midX + 36, dy: y))
                expectedStrokeCount += 1
                start.press(forDuration: 0.01, thenDragTo: end)
                state = try await waitForDrawing(page, count: expectedStrokeCount)
            }

            try await Task.sleep(for: .seconds(5))
            state = try info(page)
            print(
                "[HighZoomPipeline] enabled=\(pipelineEnabled) baselineFootprint=\(baselineFootprint) " +
                "footprint=\(state["physicalFootprintBytes"] ?? "?") " +
                "callbacks=\(state["drawingChangeCallbackCount"] ?? "?") " +
                "inputPoints=\(state["originalPathPointCount"] ?? "?") " +
                "mappedPoints=\(state["mappedPathPointCount"] ?? "?") " +
                "interpolationStrokes=\(state["interpolationStrokeCount"] ?? "?") " +
                "canonicalMs=\(state["canonicalConversionMilliseconds"] ?? "?") " +
                "replaceMs=\(state["pageReplaceMilliseconds"] ?? "?") " +
                "viewModelMs=\(state["viewModelChangeMilliseconds"] ?? "?") " +
                "snapshots=\(state["persistenceSnapshotCount"] ?? "?") " +
                "snapshotMs=\(state["persistenceSnapshotMilliseconds"] ?? "?")"
            )
            app.terminate()
        }
    }

    func testBoundedViewportKeepsHighZoomTouchCoordinatesRegistered() async throws {
        let app = launch(tool: "zoom-memory")
        let page = app.staticTexts["editor.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        let zoomButton = app.buttons["editor.test.zoomFactor"]
        XCTAssertTrue(zoomButton.waitForExistence(timeout: 5))

        var state = try info(page)
        for factor in [1.0, 2, 4, 8, 16, 32, 64] {
            zoomButton.tap()
            state = try info(page)
            for _ in 0..<40 {
                let ratio = try XCTUnwrap(state["scaleFactor"] as? Double)
                    / (try XCTUnwrap(state["fitScaleFactor"] as? Double))
                if abs(ratio - factor) < max(0.05, factor * 0.01) { break }
                try await Task.sleep(for: .milliseconds(100))
                state = try info(page)
            }
            let scaleFactor = try XCTUnwrap(state["scaleFactor"] as? Double)
            let fitScaleFactor = try XCTUnwrap(state["fitScaleFactor"] as? Double)
            let settledRatio = scaleFactor / fitScaleFactor
            XCTAssertEqual(settledRatio, factor, accuracy: max(0.05, factor * 0.01))
        }

        state = try info(page)
        let rectValues = try XCTUnwrap(state["rect"] as? [Double])
        let pageRect = CGRect(x: rectValues[0], y: rectValues[1], width: rectValues[2], height: rectValues[3])
        let visibleRect = pageRect.intersection(app.frame)
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: visibleRect.midX - 30, dy: visibleRect.midY))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: visibleRect.midX + 30, dy: visibleRect.midY))
        let firstStrokeCount = try XCTUnwrap(state["strokes"] as? Int)
        start.press(forDuration: 0.01, thenDragTo: end)
        state = try await waitForDrawing(page, count: firstStrokeCount + 1)
        try await Task.sleep(for: .seconds(5))
        state = try info(page)
        let baselineFootprint = try XCTUnwrap(state["physicalFootprintBytes"] as? UInt64)
        let baselineStrokeSeeds = try XCTUnwrap(state["strokeSeeds"] as? [UInt32])
        let undoManagerIdentity = try XCTUnwrap(state["undoManagerIdentity"] as? String)
        let baselineVisibleAreaRatio = try XCTUnwrap(state["visibleCanvasAreaRatio"] as? Double)
        XCTAssertTrue(state["canUndo"] as? Bool ?? false)

        try await Task.sleep(for: .seconds(5))
        state = try info(page)
        let drawingSize = try XCTUnwrap(state["drawingSize"] as? [Double])
        let canvasBounds = try XCTUnwrap(state["canvasBounds"] as? [Double])
        let boundedFootprint = try XCTUnwrap(state["physicalFootprintBytes"] as? UInt64)
        let boundedVisibleAreaRatio = try XCTUnwrap(state["visibleCanvasAreaRatio"] as? Double)
        let nativeZoom = try XCTUnwrap(state["canvasZoom"] as? Double)
        let maximumCanvasZoom = try XCTUnwrap(state["maximumCanvasZoom"] as? Double)
        XCTAssertGreaterThan(nativeZoom, 1)
        XCTAssertLessThanOrEqual(nativeZoom, maximumCanvasZoom)
        XCTAssertGreaterThan(canvasBounds[0], 0)
        XCTAssertGreaterThan(canvasBounds[1], 0)
        XCTAssertLessThanOrEqual(canvasBounds[0], drawingSize[0] + 0.01)
        XCTAssertLessThanOrEqual(canvasBounds[1], drawingSize[1] + 0.01)
        XCTAssertGreaterThan(boundedVisibleAreaRatio, 0)
        XCTAssertLessThan(boundedVisibleAreaRatio, 1)
        XCTAssertEqual(state["undoManagerIdentity"] as? String, undoManagerIdentity)
        XCTAssertEqual(state["strokeSeeds"] as? [UInt32], baselineStrokeSeeds)
        XCTAssertTrue(state["canUndo"] as? Bool ?? false)

        let boundedRectValues = try XCTUnwrap(state["rect"] as? [Double])
        let boundedPageRect = CGRect(x: boundedRectValues[0], y: boundedRectValues[1],
                                     width: boundedRectValues[2], height: boundedRectValues[3])
        let boundedVisibleRect = boundedPageRect.intersection(app.frame)
        let boundedStart = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: boundedVisibleRect.midX - 30, dy: boundedVisibleRect.midY))
        let boundedEnd = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: boundedVisibleRect.midX + 30, dy: boundedVisibleRect.midY))
        let expectedStrokeCount = try XCTUnwrap(state["strokes"] as? Int) + 1
        boundedStart.press(forDuration: 0.01, thenDragTo: boundedEnd)
        state = try await waitForDrawing(page, count: expectedStrokeCount)
        let startError = try endpointDrift(
            in: state, touchKey: "touchStartWindow", strokeKey: "lastStrokeStartWindow"
        )
        let endError = try endpointDrift(
            in: state, touchKey: "touchEndWindow", strokeKey: "lastStrokeEndWindow"
        )
        XCTAssertLessThan(startError, 12)
        XCTAssertLessThan(endError, 12)

        let boundedStrokeSeeds = try XCTUnwrap(state["strokeSeeds"] as? [UInt32])
        let undoButton = app.buttons["editor.test.undo"]
        let redoButton = app.buttons["editor.test.redo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5))
        XCTAssertTrue(redoButton.waitForExistence(timeout: 5))
        undoButton.tap()
        state = try await waitForDrawing(page, count: firstStrokeCount + 1)
        XCTAssertEqual(state["strokeSeeds"] as? [UInt32], baselineStrokeSeeds)
        XCTAssertTrue(state["canRedo"] as? Bool ?? false)
        redoButton.tap()
        state = try await waitForDrawing(page, count: firstStrokeCount + 2)
        XCTAssertEqual(state["strokeSeeds"] as? [UInt32], boundedStrokeSeeds)

        try await Task.sleep(for: .seconds(5))
        state = try info(page)
        print(
            "[BoundedViewport64x] baselineFootprint=\(baselineFootprint) " +
            "boundedFootprint=\(boundedFootprint) " +
            "baselineVisibleAreaRatio=\(baselineVisibleAreaRatio) " +
            "boundedVisibleAreaRatio=\(boundedVisibleAreaRatio) " +
            "canvasBounds=\(state["canvasBounds"] ?? "?") " +
            "visibleAreaRatio=\(state["visibleCanvasAreaRatio"] ?? "?") " +
            "startErrorPixels=\(startError) endErrorPixels=\(endError)"
        )
        for sample in 1...11 {
            try await Task.sleep(for: .seconds(5))
            state = try info(page)
            print(
                "[BoundedViewport64x] hold=\((sample + 1) * 5)s " +
                "footprint=\(state["physicalFootprintBytes"] ?? "?") " +
                "visibleAreaRatio=\(state["visibleCanvasAreaRatio"] ?? "?")"
            )
        }
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
            XCTContext.runActivity(named: "Pre-input geometry at \(factor)x") { activity in
                activity.add(XCTAttachment(string: String(describing: state)))
            }
            let viewportTransform = try XCTUnwrap(state["viewportHostTransform"] as? [Double])
            let effectiveScale = try XCTUnwrap(state["canvasZoom"] as? Double)
                * viewportTransform[0]
                * (try XCTUnwrap(state["measuredDisplayScale"] as? Double))
            XCTAssertEqual(effectiveScale, pageValues[2] / drawingSize[0], accuracy: 0.02,
                "Canvas zoom, host transform, and PDF display scale must map the full logical page at \(factor)x")
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
        }

        // Revisit the production viewport geometry at 32x after zoom cycling.
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
        let drawingSize = try XCTUnwrap(state["drawingSize"] as? [Double])
        let canvasBounds = try XCTUnwrap(state["canvasBounds"] as? [Double])
        let nativeZoom = try XCTUnwrap(state["canvasZoom"] as? Double)
        let maximumCanvasZoom = try XCTUnwrap(state["maximumCanvasZoom"] as? Double)
        XCTAssertGreaterThan(nativeZoom, 1)
        XCTAssertLessThanOrEqual(nativeZoom, maximumCanvasZoom)
        XCTAssertLessThanOrEqual(canvasBounds[0], drawingSize[0] + 0.01)
        XCTAssertLessThanOrEqual(canvasBounds[1], drawingSize[1] + 0.01)
        print(
            "[BoundedViewport32x] footprint=\(state["physicalFootprintBytes"] ?? "?") " +
            "canvasBounds=\(canvasBounds) contentSize=\(state["contentSize"] ?? "?")"
        )
    }

    func testRotatedPageWithNonzeroCropOriginKeepsHighZoomCanvasGeometryRegistered() async throws {
        let app = launch(tool: "scribble-undo", rotatedCrop: true)
        let page = app.staticTexts["editor.page.0"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        let initial = try info(page)
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
        let nativeZoom = try XCTUnwrap(state["canvasZoom"] as? Double)
        let maximumCanvasZoom = try XCTUnwrap(state["maximumCanvasZoom"] as? Double)
        XCTAssertGreaterThan(nativeZoom, 1)
        XCTAssertLessThanOrEqual(nativeZoom, maximumCanvasZoom)
        let canvasBounds = try XCTUnwrap(state["canvasBounds"] as? [Double])
        let drawingSize = try XCTUnwrap(state["drawingSize"] as? [Double])
        XCTAssertLessThanOrEqual(canvasBounds[0], drawingSize[0] + 0.01)
        XCTAssertLessThanOrEqual(canvasBounds[1], drawingSize[1] + 0.01)
        let crop = try XCTUnwrap(state["cropBox"] as? [Double])
        XCTAssertEqual(crop[0], 40, accuracy: 0.01)
        XCTAssertEqual(crop[1], 60, accuracy: 0.01)
        let pageValues = try XCTUnwrap(state["rect"] as? [Double])
        let viewportTransform = try XCTUnwrap(state["viewportHostTransform"] as? [Double])
        let displayScale = try XCTUnwrap(state["measuredDisplayScale"] as? Double)
        let effectiveXScale = nativeZoom * viewportTransform[0] * displayScale
        let effectiveYScale = nativeZoom * viewportTransform[1] * displayScale
        XCTAssertEqual(effectiveXScale, pageValues[2] / drawingSize[1], accuracy: 0.02,
            "A 90-degree PDF rotation maps logical drawing height to displayed page width")
        XCTAssertEqual(effectiveYScale, pageValues[3] / drawingSize[0], accuracy: 0.02,
            "A 90-degree PDF rotation maps logical drawing width to displayed page height")
    }

    func testBlankNoteFingerTouchesPreserveDrawingAndNativeMenuInteractions() async throws {
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
        let canvasMenuInteractions = try XCTUnwrap(state["canvasEditMenuInteractions"] as? [String])
        let pdfMenuInteractions = try XCTUnwrap(state["pdfEditMenuInteractions"] as? [String])

        // This fixture has a nil source PDF plus a previously written PKDrawing.
        // Tap several blank ruled-paper locations as the finger side of the
        // reported Apple Pencil + finger regression. The Simulator exposes a
        // stale Select All accessibility item even when no menu is rendered,
        // so verify persistent drawing and native interaction ownership here.
        for position in [(0.18, 0.27), (0.82, 0.36), (0.25, 0.72), (0.7, 0.81)] {
            state = try info(page)
            try point(app, info: state, x: position.0, y: position.1).tap()
            try await Task.sleep(for: .milliseconds(250))
        }

        // Exercise the longer stationary touch that can trigger UIKit edit
        // menus on devices where the menu appears after a tap/hold sequence.
        state = try info(page)
        try point(app, info: state, x: 0.48, y: 0.5).press(forDuration: 1.0)

        state = try info(page)
        XCTAssertEqual(state["strokes"] as? Int, 1,
            "Finger navigation must not modify or erase the existing PencilKit drawing")
        XCTAssertEqual(state["canvasEditMenuInteractions"] as? [String], canvasMenuInteractions,
            "Ordinary finger input must preserve PencilKit-owned native menu interactions")
        XCTAssertEqual(state["pdfEditMenuInteractions"] as? [String], pdfMenuInteractions,
            "Ordinary finger input must preserve PDFKit-owned native menu interactions")
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

        var initial = try info(page)
        var initialPageRect = try XCTUnwrap(initial["rect"] as? [Double])
        var initialViewport = try XCTUnwrap(initial["viewportRect"] as? [Double])
        var initialScale = try XCTUnwrap(initial["scaleFactor"] as? Double)
        var initialFitScale = try XCTUnwrap(initial["fitScaleFactor"] as? Double)
        var initialAtFit = abs(initialScale - initialFitScale) <= max(0.01, initialFitScale * 0.01)
        for _ in 0..<40 where !initialAtFit {
            try await Task.sleep(for: .milliseconds(100))
            initial = try info(page)
            initialPageRect = try XCTUnwrap(initial["rect"] as? [Double])
            initialViewport = try XCTUnwrap(initial["viewportRect"] as? [Double])
            initialScale = try XCTUnwrap(initial["scaleFactor"] as? Double)
            initialFitScale = try XCTUnwrap(initial["fitScaleFactor"] as? Double)
            initialAtFit = abs(initialScale - initialFitScale) <= max(0.01, initialFitScale * 0.01)
        }
        XCTAssertTrue(initialAtFit, "PDFKit should settle at its page-fit scale before the double-tap transition")
        XCTAssertEqual(initialScale, initialFitScale, accuracy: max(0.01, initialFitScale * 0.01),
            "PDFKit should settle at its page-fit scale before the double-tap transition")
        let anchorX = initialPageRect[0] + initialPageRect[2] * 0.32
        let anchorY = initialPageRect[1] + initialPageRect[3] * 0.38
        let zoomTap = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: anchorX, dy: anchorY))
        zoomTap.doubleTap()

        var zoomed = try info(page)
        for _ in 0..<30 {
            guard let rect = zoomed["rect"] as? [Double],
                  let viewport = zoomed["viewportRect"] as? [Double] else { break }
            let fitsWidth = abs(rect[2] - viewport[2] * 0.97) <= 8
            let fitsHeight = abs(rect[3] - viewport[3]) <= 8
            if fitsWidth || fitsHeight { break }
            try await Task.sleep(for: .milliseconds(100))
            zoomed = try info(page)
        }
        let pageRect = try XCTUnwrap(zoomed["rect"] as? [Double])
        let viewportRect = try XCTUnwrap(zoomed["viewportRect"] as? [Double])
        let canvasRect = try XCTUnwrap(zoomed["canvasRect"] as? [Double])
        let fitsWidth = abs(pageRect[2] - viewportRect[2] * 0.97) <= 8
        let fitsHeight = abs(pageRect[3] - viewportRect[3]) <= 8
        XCTAssertTrue(fitsWidth || fitsHeight, "The first double tap should select one page-fit target")
        let firstZoomFitsWidth = abs(pageRect[2] - viewportRect[2] * 0.97)
            <= abs(pageRect[3] - viewportRect[3])
        if firstZoomFitsWidth {
            XCTAssertEqual(anchorX, pageRect[0] + pageRect[2] * 0.32, accuracy: 10,
                "The zoom should keep the tapped point anchored on the scrollable axis")
        } else {
            XCTAssertEqual(anchorY, pageRect[1] + pageRect[3] * 0.38, accuracy: 10,
                "The zoom should keep the tapped point anchored on the scrollable axis")
        }
        XCTAssertGreaterThan(canvasRect[2], 0)
        XCTAssertGreaterThan(canvasRect[3], 0)

        let secondTap = try point(app, info: zoomed, x: 0.75, y: 0.45)
        secondTap.doubleTap()
        var fitted = try info(page)
        for _ in 0..<30 {
            guard let rect = fitted["rect"] as? [Double],
                  let viewport = fitted["viewportRect"] as? [Double] else { break }
            let fitsExpectedWidth = !firstZoomFitsWidth
                && abs(rect[2] - viewport[2] * 0.97) <= 8
            let fitsExpectedHeight = firstZoomFitsWidth
                && abs(rect[3] - viewport[3]) <= 8
            if fitsExpectedWidth || fitsExpectedHeight { break }
            try await Task.sleep(for: .milliseconds(100))
            fitted = try info(page)
        }
        let fittedRect = try XCTUnwrap(fitted["rect"] as? [Double])
        let fittedViewport = try XCTUnwrap(fitted["viewportRect"] as? [Double])
        let fittedCanvas = try XCTUnwrap(fitted["canvasRect"] as? [Double])
        if firstZoomFitsWidth {
            XCTAssertEqual(fittedRect[3], fittedViewport[3], accuracy: 8,
                "The next double tap should switch from width-fit to height-fit")
        } else {
            XCTAssertEqual(fittedRect[2], fittedViewport[2] * 0.97, accuracy: 8,
                "The next double tap should switch from height-fit to width-fit")
        }
        XCTAssertEqual(fittedRect[0] + fittedRect[2] / 2,
            fittedViewport[0] + fittedViewport[2] / 2, accuracy: 8,
            "PDFKit should center a page narrower than the viewport")
        XCTAssertGreaterThan(fittedCanvas[2], 0)
        XCTAssertGreaterThan(fittedCanvas[3], 0)
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

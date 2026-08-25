/*
 Jottre: Minimalistic jotting for iPhone, iPad and Mac.
 Copyright (C) 2021-2026 Anton Lorani

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

@preconcurrency import PencilKit
import UIKit
import XCTest

@testable import Jottre

final class CanvasTouchRoutingTests: XCTestCase {

    func testNonLassoDirectTouchIsBlockedFromPencilKitMenu() {
        XCTAssertTrue(
            CanvasEditMenuSuppressionPolicy.blocksDirectTouch(
                isEditingEnabled: true,
                isLassoTool: false,
                routesDirectTouchesToDocumentScroll: true
            )
        )
    }

    func testLassoDirectTouchRemainsNative() {
        XCTAssertFalse(
            CanvasEditMenuSuppressionPolicy.blocksDirectTouch(
                isEditingEnabled: true,
                isLassoTool: true,
                routesDirectTouchesToDocumentScroll: true
            )
        )
    }

    func testViewOnlyDirectTouchDoesNotNeedMenuBlocker() {
        XCTAssertFalse(
            CanvasEditMenuSuppressionPolicy.blocksDirectTouch(
                isEditingEnabled: false,
                isLassoTool: false,
                routesDirectTouchesToDocumentScroll: true
            )
        )
    }

    func testFingerDrawingDirectTouchDoesNotUseMenuBlocker() {
        XCTAssertFalse(
            CanvasEditMenuSuppressionPolicy.blocksDirectTouch(
                isEditingEnabled: true,
                isLassoTool: false,
                routesDirectTouchesToDocumentScroll: false
            )
        )
    }

    @MainActor
    func testPencilOnlyEditingRoutesOneFingerToDocumentPan() {
        let configuration = CanvasTouchRouting.configuration(
            isEditingEnabled: true,
            drawingPolicy: .pencilOnly,
            isToolPickerVisible: true,
            prefersPencilOnlyDrawing: false
        )

        XCTAssertFalse(configuration.isFingerDrawingEnabled)
        XCTAssertEqual(configuration.documentPanMinimumNumberOfTouches, 1)
        XCTAssertTrue(configuration.routesDirectTouchesToDocumentScroll)
    }

    @MainActor
    func testAnyInputEditingReservesOneFingerForDrawing() {
        let configuration = CanvasTouchRouting.configuration(
            isEditingEnabled: true,
            drawingPolicy: .anyInput,
            isToolPickerVisible: false,
            prefersPencilOnlyDrawing: true
        )

        XCTAssertTrue(configuration.isFingerDrawingEnabled)
        XCTAssertEqual(configuration.documentPanMinimumNumberOfTouches, 2)
        XCTAssertFalse(configuration.routesDirectTouchesToDocumentScroll)
    }

    @MainActor
    func testDefaultPolicyFollowsVisibleToolPickerPreference() {
        let anyInput = CanvasTouchRouting.configuration(
            isEditingEnabled: true,
            drawingPolicy: .default,
            isToolPickerVisible: true,
            prefersPencilOnlyDrawing: false
        )
        let pencilOnly = CanvasTouchRouting.configuration(
            isEditingEnabled: true,
            drawingPolicy: .default,
            isToolPickerVisible: true,
            prefersPencilOnlyDrawing: true
        )

        XCTAssertTrue(anyInput.isFingerDrawingEnabled)
        XCTAssertFalse(pencilOnly.isFingerDrawingEnabled)
    }

    @MainActor
    func testDefaultPolicyIsPencilOnlyWithoutVisibleToolPicker() {
        let configuration = CanvasTouchRouting.configuration(
            isEditingEnabled: true,
            drawingPolicy: .default,
            isToolPickerVisible: false,
            prefersPencilOnlyDrawing: false
        )

        XCTAssertFalse(configuration.isFingerDrawingEnabled)
        XCTAssertEqual(configuration.documentPanMinimumNumberOfTouches, 1)
    }

    @MainActor
    func testViewOnlyModeAlwaysRoutesOneFingerToDocumentPan() {
        let configuration = CanvasTouchRouting.configuration(
            isEditingEnabled: false,
            drawingPolicy: .anyInput,
            isToolPickerVisible: true,
            prefersPencilOnlyDrawing: false
        )

        XCTAssertFalse(configuration.isFingerDrawingEnabled)
        XCTAssertEqual(configuration.documentPanMinimumNumberOfTouches, 1)
    }

    @MainActor
    func testApplyingPencilOnlyRoutingDoesNotRewritePencilKitTouchTypes() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("Direct-touch and Apple Pencil routing is unavailable on Mac Catalyst")
        #else
        let foregroundCanvas = PKCanvasView()
        let highlighterCanvas = PKCanvasView()
        let documentScrollView = UIScrollView()
        documentScrollView.maximumZoomScale = 8
        let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pencilTouch = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        foregroundCanvas.tool = PKLassoTool()

        // PencilKit owns this recognizer and may reconfigure it while lasso is active.
        foregroundCanvas.drawingGestureRecognizer.allowedTouchTypes = [directTouch, pencilTouch]
        let configuration = CanvasTouchRouting.Configuration(isFingerDrawingEnabled: false)

        CanvasTouchRouting.apply(
            configuration,
            to: [foregroundCanvas, highlighterCanvas],
            documentScrollView: documentScrollView
        )

        XCTAssertEqual(documentScrollView.panGestureRecognizer.allowedTouchTypes, [directTouch])
        XCTAssertEqual(documentScrollView.panGestureRecognizer.minimumNumberOfTouches, 1)
        XCTAssertEqual(documentScrollView.panGestureRecognizer.maximumNumberOfTouches, 2)
        XCTAssertEqual(documentScrollView.pinchGestureRecognizer?.allowedTouchTypes, [directTouch])
        XCTAssertEqual(documentScrollView.pinchGestureRecognizer?.isEnabled, true)
        XCTAssertFalse(foregroundCanvas.isScrollEnabled)
        XCTAssertFalse(foregroundCanvas.panGestureRecognizer.isEnabled)
        XCTAssertFalse(highlighterCanvas.isScrollEnabled)
        XCTAssertEqual(
            foregroundCanvas.drawingGestureRecognizer.allowedTouchTypes,
            [directTouch, pencilTouch]
        )
        XCTAssertTrue(highlighterCanvas.drawingGestureRecognizer.allowedTouchTypes.isEmpty)
        #endif
    }

    @MainActor
    func testApplyingAnyInputRoutingPreservesFingerLassoAndTwoFingerNavigation() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("Direct-touch and Apple Pencil routing is unavailable on Mac Catalyst")
        #else
        let canvasView = PKCanvasView()
        let documentScrollView = UIScrollView()
        let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pencilTouch = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        canvasView.tool = PKLassoTool()
        let configuration = CanvasTouchRouting.Configuration(isFingerDrawingEnabled: true)

        CanvasTouchRouting.apply(
            configuration,
            to: [canvasView],
            documentScrollView: documentScrollView
        )

        XCTAssertEqual(documentScrollView.panGestureRecognizer.allowedTouchTypes, [directTouch])
        XCTAssertEqual(documentScrollView.panGestureRecognizer.minimumNumberOfTouches, 2)
        XCTAssertEqual(documentScrollView.panGestureRecognizer.maximumNumberOfTouches, 2)
        XCTAssertFalse(canvasView.isScrollEnabled)
        XCTAssertFalse(canvasView.panGestureRecognizer.isEnabled)
        XCTAssertEqual(
            canvasView.drawingGestureRecognizer.allowedTouchTypes,
            [directTouch, pencilTouch]
        )
        #endif
    }
}

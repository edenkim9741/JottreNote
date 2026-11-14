@preconcurrency import PencilKit
import UIKit
import XCTest

@testable import Jottre

final class CanvasTouchRoutingTests: XCTestCase {
    @MainActor
    func testAllPencilKitToolsUseNativePencilOnlyInput() {
        XCTAssertEqual(CanvasTouchRouting.drawingPolicy(for: PKLassoTool()), .pencilOnly)
        XCTAssertEqual(CanvasTouchRouting.drawingPolicy(for: PKInkingTool(.pen)), .pencilOnly)
        XCTAssertEqual(CanvasTouchRouting.drawingPolicy(for: PKEraserTool(.bitmap)), .pencilOnly)
    }

    @MainActor
    func testNativeEditMenuSuppressionTargetsInkAndEraserButPreservesLassoAndRuler() {
        XCTAssertTrue(CanvasTouchRouting.suppressesStandardEditActions(isEditing: true, tool: PKInkingTool(.pen)))
        XCTAssertTrue(CanvasTouchRouting.suppressesStandardEditActions(isEditing: true, tool: PKEraserTool(.bitmap)))
        XCTAssertFalse(CanvasTouchRouting.suppressesStandardEditActions(isEditing: true, tool: PKLassoTool()))
        XCTAssertFalse(CanvasTouchRouting.suppressesStandardEditActions(isEditing: false, tool: PKInkingTool(.pen)))

        XCTAssertFalse(CanvasTouchRouting.shouldSuppressNativeEditMenuInteractions(isEditing: true, tool: PKLassoTool()))
        XCTAssertFalse(CanvasTouchRouting.shouldSuppressNativeEditMenuInteractions(isEditing: true, tool: PKInkingTool(.pen)))
        XCTAssertFalse(CanvasTouchRouting.shouldSuppressNativeEditMenuInteractions(isEditing: true, tool: PKEraserTool(.bitmap)))
        XCTAssertFalse(CanvasTouchRouting.shouldSuppressNativeEditMenuInteractions(isEditing: false, tool: PKInkingTool(.pen)))
    }

    @MainActor
    func testNativeEditMenuInteractionsAreNeverDetachedByRoutingUpdates() {
        let pdfView = JotPDFView()
        let canvas = JotCanvasView()
        let overlay = JotPDFPageCanvasOverlay(canvas: canvas, pageSize: CGSize(width: 100, height: 140))
        let editMenu = UIEditMenuInteraction(delegate: nil)
        canvas.addInteraction(editMenu)
        let coordinator = JotEditorGestureCoordinator(pdfView: pdfView)

        let tools: [any PKTool] = [PKInkingTool(.pen), PKEraserTool(.bitmap), PKLassoTool()]
        for tool in tools {
            coordinator.update(
                isEditing: true,
                tool: tool,
                rulerActive: false,
                activePageIndex: 0,
                overlays: [0: overlay]
            )
            XCTAssertTrue(canvas.interactions.contains { $0 === editMenu })
        }
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
    }

    @MainActor
    func testRulerStateIsScopedToActivePageWithoutDisablingMenuOrCanvasInputPolicies() {
        let pdfView = JotPDFView()
        let coordinator = JotEditorGestureCoordinator(pdfView: pdfView)
        let firstCanvas = JotCanvasView()
        let secondCanvas = JotCanvasView()
        let firstOverlay = JotPDFPageCanvasOverlay(canvas: firstCanvas, pageSize: CGSize(width: 100, height: 140))
        let secondOverlay = JotPDFPageCanvasOverlay(canvas: secondCanvas, pageSize: CGSize(width: 100, height: 140))

        coordinator.update(
            isEditing: true,
            tool: PKInkingTool(.pen),
            pickerVisible: true,
            rulerActive: true,
            activePageIndex: 1,
            overlays: [0: firstOverlay, 1: secondOverlay]
        )

        XCTAssertFalse(firstCanvas.isRulerActive)
        XCTAssertTrue(secondCanvas.isRulerActive)
        XCTAssertTrue(secondCanvas.isUserInteractionEnabled)
        XCTAssertTrue(secondCanvas.drawingGestureRecognizer.isEnabled)
        XCTAssertTrue(secondCanvas.suppressesStandardEditActions)

        coordinator.update(
            isEditing: true,
            tool: PKInkingTool(.pen),
            pickerVisible: true,
            rulerActive: true,
            activePageIndex: 0,
            overlays: [0: firstOverlay, 1: secondOverlay]
        )

        XCTAssertTrue(firstCanvas.isRulerActive)
        XCTAssertFalse(secondCanvas.isRulerActive)

        coordinator.update(
            isEditing: true,
            tool: PKInkingTool(.pen),
            pickerVisible: true,
            rulerActive: false,
            activePageIndex: 0,
            overlays: [0: firstOverlay, 1: secondOverlay]
        )
        XCTAssertFalse(firstCanvas.isRulerActive)
        XCTAssertFalse(secondCanvas.isRulerActive)
        XCTAssertTrue(firstCanvas.isUserInteractionEnabled)
        XCTAssertTrue(firstCanvas.drawingGestureRecognizer.isEnabled)
    }

    @MainActor
    func testRulerStateSurvivesPageOverlayGeometryUpdates() {
        let canvas = JotCanvasView()
        let overlay = JotPDFPageCanvasOverlay(canvas: canvas, pageSize: CGSize(width: 210, height: 297))
        canvas.isRulerActive = true

        overlay.configure(displayScale: 1.5)
        overlay.layoutIfNeeded()
        overlay.configure(displayScale: 2.25)
        overlay.layoutIfNeeded()

        XCTAssertTrue(canvas.isRulerActive)
        XCTAssertTrue(canvas.isUserInteractionEnabled)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
    }

    @MainActor
    func testPDFPanAcceptsFingerOnlyDuringEditingAndRestoresOriginalTypes() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("Touch-type routing is unavailable on Mac Catalyst")
        #else
        let pan = UIPanGestureRecognizer()
        pan.minimumNumberOfTouches = 1
        let originalTypes = pan.allowedTouchTypes
        let originalMinimum = pan.minimumNumberOfTouches
        let originalMaximum = pan.maximumNumberOfTouches

        CanvasTouchRouting.apply(to: [pan], pencilInputHasPriority: true)

        XCTAssertEqual(pan.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)])
        XCTAssertEqual(pan.minimumNumberOfTouches, originalMinimum)
        XCTAssertEqual(pan.maximumNumberOfTouches, originalMaximum)

        CanvasTouchRouting.apply(to: [pan], pencilInputHasPriority: false)
        XCTAssertEqual(pan.allowedTouchTypes, originalTypes)
        XCTAssertEqual(pan.minimumNumberOfTouches, originalMinimum)
        XCTAssertEqual(pan.maximumNumberOfTouches, originalMaximum)
        #endif
    }

    @MainActor
    func testResponderActionsAreUnavailableFromEditorViewsWhileEditing() {
        let selectAll = #selector(UIResponderStandardEditActions.selectAll(_:))
        let canvas = JotCanvasView()
        let pdf = JotPDFView()
        canvas.suppressesStandardEditActions = true
        pdf.suppressesStandardEditActions = true

        XCTAssertFalse(canvas.canPerformAction(selectAll, withSender: nil))
        XCTAssertFalse(pdf.canPerformAction(selectAll, withSender: nil))

        canvas.suppressesStandardEditActions = false
        pdf.suppressesStandardEditActions = false
        XCTAssertEqual(canvas.suppressesStandardEditActions, false)
        XCTAssertEqual(pdf.suppressesStandardEditActions, false)
    }
}

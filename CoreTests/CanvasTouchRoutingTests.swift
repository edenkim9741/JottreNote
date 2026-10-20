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
    func testDirectTouchesPassThroughOverlayUnlessRulerNeedsFingerInteraction() {
        XCTAssertTrue(CanvasTouchRouting.shouldPassDirectTouchesThroughOverlay(rulerActive: false))
        XCTAssertFalse(CanvasTouchRouting.shouldPassDirectTouchesThroughOverlay(rulerActive: true))
    }

    @MainActor
    func testNativeEditMenuSuppressionTargetsInkAndEraserButPreservesLassoAndRuler() {
        XCTAssertTrue(CanvasTouchRouting.suppressesStandardEditActions(isEditing: true, tool: PKInkingTool(.pen)))
        XCTAssertTrue(CanvasTouchRouting.suppressesStandardEditActions(isEditing: true, tool: PKEraserTool(.bitmap)))
        XCTAssertFalse(CanvasTouchRouting.suppressesStandardEditActions(isEditing: true, tool: PKLassoTool()))
        XCTAssertFalse(CanvasTouchRouting.suppressesStandardEditActions(isEditing: false, tool: PKInkingTool(.pen)))

        XCTAssertTrue(CanvasTouchRouting.shouldSuppressNativeEditMenuInteractions(isEditing: true, tool: PKInkingTool(.pen)))
        XCTAssertTrue(CanvasTouchRouting.shouldSuppressNativeEditMenuInteractions(isEditing: true, tool: PKEraserTool(.bitmap)))
        XCTAssertFalse(CanvasTouchRouting.shouldSuppressNativeEditMenuInteractions(isEditing: true, tool: PKLassoTool()))
        XCTAssertFalse(CanvasTouchRouting.shouldSuppressNativeEditMenuInteractions(isEditing: false, tool: PKInkingTool(.pen)))
    }

    @MainActor
    func testNativeEditMenuInteractionIsRemovedOnlyForInkToolsAndRestoredForLasso() {
        let canvas = JotCanvasView()
        let editMenu = UIEditMenuInteraction(delegate: nil)
        canvas.addInteraction(editMenu)
        let controller = JotEditMenuInteractionController()

        controller.apply(suppressed: true, in: canvas)

        XCTAssertFalse(canvas.interactions.contains { $0 === editMenu })
        XCTAssertGreaterThanOrEqual(controller.detachedCount, 1)
        XCTAssertTrue(canvas.isUserInteractionEnabled)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)

        controller.apply(suppressed: false, in: canvas)

        XCTAssertTrue(canvas.interactions.contains { $0 === editMenu })
        XCTAssertEqual(controller.detachedCount, 0)
        XCTAssertTrue(canvas.isUserInteractionEnabled)
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
        XCTAssertFalse(CanvasTouchRouting.shouldPassDirectTouchesThroughOverlay(rulerActive: secondCanvas.isRulerActive))

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
    func testPencilOnlyAndViewingModesKeepOneFingerPDFNavigation() {
        let editing = CanvasTouchRouting.configuration(
            isEditingEnabled: true,
            drawingPolicy: CanvasTouchRouting.drawingPolicy(for: PKLassoTool()),
            isToolPickerVisible: true,
            prefersPencilOnlyDrawing: false
        )
        let viewing = CanvasTouchRouting.configuration(
            isEditingEnabled: false,
            drawingPolicy: .anyInput,
            isToolPickerVisible: true,
            prefersPencilOnlyDrawing: false
        )

        XCTAssertFalse(editing.isFingerDrawingEnabled)
        XCTAssertEqual(editing.documentPanMinimumNumberOfTouches, 1)
        XCTAssertEqual(viewing.documentPanMinimumNumberOfTouches, 1)
    }

    @MainActor
    func testAnyInputAndDefaultPoliciesSetDocumentPanTouchCount() {
        let anyInput = CanvasTouchRouting.configuration(
            isEditingEnabled: true,
            drawingPolicy: .anyInput,
            isToolPickerVisible: false,
            prefersPencilOnlyDrawing: true
        )
        let systemDefault = CanvasTouchRouting.configuration(
            isEditingEnabled: true,
            drawingPolicy: .default,
            isToolPickerVisible: true,
            prefersPencilOnlyDrawing: false
        )

        XCTAssertEqual(anyInput.documentPanMinimumNumberOfTouches, 2)
        XCTAssertEqual(systemDefault.documentPanMinimumNumberOfTouches, 2)
    }

    @MainActor
    func testPDFPanAcceptsFingerOnlyDuringEditingAndRestoresOriginalTypes() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("Touch-type routing is unavailable on Mac Catalyst")
        #else
        let pan = UIPanGestureRecognizer()
        pan.minimumNumberOfTouches = 1
        let originalTypes = pan.allowedTouchTypes
        let input = CanvasTouchRouting.Configuration(isFingerDrawingEnabled: false)

        CanvasTouchRouting.apply(input, to: [pan], pencilInputHasPriority: true)

        XCTAssertEqual(pan.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)])
        XCTAssertEqual(pan.minimumNumberOfTouches, 1)

        CanvasTouchRouting.apply(input, to: [pan], pencilInputHasPriority: false)
        XCTAssertEqual(pan.allowedTouchTypes, originalTypes)
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

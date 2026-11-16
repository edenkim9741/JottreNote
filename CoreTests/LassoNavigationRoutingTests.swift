import PDFKit
@preconcurrency import PencilKit
import UIKit
import XCTest

@testable import Jottre

@MainActor
final class LassoNavigationRoutingTests: XCTestCase {
    func testLassoSelectionGesturesCannotPreventFingerNavigation() throws {
        let pdf = JotPDFView()
        let canvas = JotCanvasView()
        let overlay = JotPDFPageCanvasOverlay(
            canvas: canvas, pageSize: CGSize(width: 600, height: 800)
        )
        pdf.addSubview(overlay)
        let coordinator = JotEditorGestureCoordinator(pdfView: pdf)
        coordinator.update(isEditing: true, tool: PKLassoTool(), rulerActive: false,
                           activePageIndex: 0, overlays: [0: overlay])
        let fallback = try XCTUnwrap(coordinator.fingerNavigationFallbackPan)

        // Native selection recognizers can appear after configuration, when
        // the user selects/moves ink. Discover them through their view ancestry.
        let selectionView = UIView()
        canvas.addSubview(selectionView)
        let selectionPan = UIPanGestureRecognizer()
        selectionView.addGestureRecognizer(selectionPan)
        XCTAssertTrue(coordinator.gestureRecognizer(fallback, shouldRecognizeSimultaneouslyWith: selectionPan))
        XCTAssertTrue(coordinator.gestureRecognizer(selectionPan, shouldRecognizeSimultaneouslyWith: fallback))
        XCTAssertEqual(fallback.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)])
        XCTAssertEqual(fallback.maximumNumberOfTouches, 1)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)

        let unrelated = UIPanGestureRecognizer()
        pdf.addGestureRecognizer(unrelated)
        XCTAssertFalse(coordinator.gestureRecognizer(fallback, shouldRecognizeSimultaneouslyWith: unrelated))

        canvas.isRulerActive = true
        XCTAssertFalse(coordinator.gestureRecognizer(fallback, shouldRecognizeSimultaneouslyWith: selectionPan))
        canvas.isRulerActive = false
        canvas.drawingPolicy = .anyInput
        XCTAssertFalse(coordinator.gestureRecognizer(fallback, shouldRecognizeSimultaneouslyWith: selectionPan))
    }

    func testFallbackCoexistsWithNativePDFPanAndPinch() throws {
        let pdf = JotPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let data = UIGraphicsPDFRenderer(bounds: pdf.bounds).pdfData { context in context.beginPage() }
        pdf.document = try XCTUnwrap(PDFDocument(data: data))
        pdf.layoutIfNeeded()
        let coordinator = JotEditorGestureCoordinator(pdfView: pdf)
        coordinator.update(isEditing: true, tool: PKLassoTool(), rulerActive: false,
                           activePageIndex: nil, overlays: [:])
        let fallback = try XCTUnwrap(coordinator.fingerNavigationFallbackPan)
        let scroll = try XCTUnwrap(coordinator.pdfNavigationScrollViews().first)
        let pinch = try XCTUnwrap(scroll.pinchGestureRecognizer)

        XCTAssertTrue(coordinator.gestureRecognizer(fallback, shouldRecognizeSimultaneouslyWith: scroll.panGestureRecognizer))
        XCTAssertTrue(coordinator.gestureRecognizer(fallback, shouldRecognizeSimultaneouslyWith: pinch))
        XCTAssertTrue(coordinator.gestureRecognizer(pinch, shouldRecognizeSimultaneouslyWith: fallback))
        XCTAssertTrue(pinch.isEnabled)
    }

    func testLeavingEditingRemovesFallbackFromItsActualHost() throws {
        let pdf = JotPDFView()
        let host = UIView()
        host.addSubview(pdf)
        let coordinator = JotEditorGestureCoordinator(pdfView: pdf, fingerNavigationGestureHost: host)
        coordinator.update(isEditing: true, tool: PKLassoTool(), rulerActive: false,
                           activePageIndex: nil, overlays: [:])
        let fallback = try XCTUnwrap(coordinator.fingerNavigationFallbackPan)
        XCTAssertTrue(fallback.view === host)

        coordinator.update(isEditing: false, tool: PKLassoTool(), rulerActive: false,
                           activePageIndex: nil, overlays: [:])
        XCTAssertNil(coordinator.fingerNavigationFallbackPan)
        XCTAssertNil(fallback.view)
        XCTAssertFalse(host.gestureRecognizers?.contains(fallback) ?? false)
    }
}

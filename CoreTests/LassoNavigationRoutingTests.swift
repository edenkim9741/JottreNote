import PDFKit
@preconcurrency import PencilKit
import UIKit
import XCTest

@testable import Jottre

@MainActor
final class LassoNavigationRoutingTests: XCTestCase {
    private final class NativeDeceleratingScrollView: UIScrollView {
        override var isDecelerating: Bool { true }
    }

    private final class FingerTouch: UITouch {
        override var type: UITouch.TouchType { .direct }
        override func location(in view: UIView?) -> CGPoint { CGPoint(x: 10, y: 10) }
    }

    func testInertiaContinuesInReleaseDirectionWithDecreasingSpeed() {
        var motion = JotScrollDeceleration(offset: CGPoint(x: 500, y: 500),
                                          velocity: CGPoint(x: -200, y: 1_000), rate: 0.998)
        let range = CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
        motion.advance(by: 1.0 / 60, within: range)
        let first = motion.offset
        XCTAssertLessThan(first.x, 500)
        XCTAssertGreaterThan(first.y, 500)
        XCTAssertGreaterThan(motion.velocity.y, 0)
        XCTAssertLessThan(motion.velocity.y, 1_000)
        motion.advance(by: 1.0 / 60, within: range)
        XCTAssertGreaterThan(motion.offset.y, first.y)
        XCTAssertLessThan(motion.offset.y - first.y, first.y - 500)
    }

    func testInertiaIsIndependentOfRefreshRate() {
        func simulate(frames: Int) -> JotScrollDeceleration {
            var motion = JotScrollDeceleration(offset: .zero, velocity: CGPoint(x: 200, y: 1_000), rate: 0.998)
            for _ in 0..<frames {
                motion.advance(by: 1.0 / Double(frames), within: CGRect(x: 0, y: 0, width: 10_000, height: 10_000))
            }
            return motion
        }
        let at60 = simulate(frames: 60)
        let at120 = simulate(frames: 120)
        XCTAssertEqual(at60.offset.y, at120.offset.y, accuracy: 0.0001)
        XCTAssertEqual(at60.velocity.y, at120.velocity.y, accuracy: 0.0001)
        XCTAssertEqual(at60.offset.x, at120.offset.x, accuracy: 0.0001)
    }

    func testInertiaStopsAtInsetsAndKeepsScrollingTheOtherAxis() {
        var motion = JotScrollDeceleration(offset: CGPoint(x: 1, y: 100),
                                          velocity: CGPoint(x: -1_000, y: 1_000), rate: 0.998)
        let range = CGRect(x: -20, y: -40, width: 520, height: 1_040)
        motion.advance(by: 0.1, within: range)
        XCTAssertEqual(motion.offset.x, -20)
        XCTAssertEqual(motion.velocity.x, 0)
        XCTAssertGreaterThan(motion.offset.y, 100)
        XCTAssertGreaterThan(motion.velocity.y, 0)
        motion.advance(by: 10, within: CGRect(x: -20, y: -40, width: 520, height: 240))
        XCTAssertEqual(motion.offset.y, 200)
        XCTAssertFalse(motion.isMoving)
    }

    func testInertiaUsesScrollViewsDecelerationRateAndSettles() {
        var normal = JotScrollDeceleration(offset: .zero, velocity: CGPoint(x: 0, y: 1_000), rate: 0.998)
        var fast = JotScrollDeceleration(offset: .zero, velocity: CGPoint(x: 0, y: 1_000), rate: 0.99)
        let range = CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
        normal.advance(by: 1, within: range)
        fast.advance(by: 1, within: range)
        XCTAssertGreaterThan(normal.offset.y, fast.offset.y)
        normal.advance(by: 5, within: range)
        XCTAssertFalse(normal.isMoving)
    }

    func testEditingExitAndExplicitInterruptionStopInertia() {
        let pdf = JotPDFView()
        let coordinator = JotEditorGestureCoordinator(pdfView: pdf)
        let scroll = UIScrollView()
        coordinator.update(isEditing: true, tool: PKLassoTool(), rulerActive: false,
                           activePageIndex: nil, overlays: [:])
        coordinator.startFallbackDeceleration(velocity: CGPoint(x: 0, y: 1_000), in: scroll)
        XCTAssertNotNil(coordinator.fallbackDeceleration)
        XCTAssertEqual(coordinator.fallbackDeceleration?.rate, scroll.decelerationRate.rawValue)
        coordinator.stopFingerNavigationDeceleration()
        XCTAssertNil(coordinator.fallbackDeceleration)
        coordinator.startFallbackDeceleration(velocity: CGPoint(x: 0, y: 1_000), in: scroll)
        coordinator.update(isEditing: false, tool: PKLassoTool(), rulerActive: false,
                           activePageIndex: nil, overlays: [:])
        XCTAssertNil(coordinator.fallbackDeceleration)
        coordinator.startFallbackDeceleration(velocity: CGPoint(x: 0, y: 1_000), in: scroll)
        XCTAssertNil(coordinator.fallbackDeceleration)
    }

    func testNewFingerTouchStopsInertiaBeforeNextPanBegins() throws {
        let pdf = JotPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let coordinator = JotEditorGestureCoordinator(pdfView: pdf)
        let scroll = UIScrollView()
        coordinator.update(isEditing: true, tool: PKLassoTool(), rulerActive: false,
                           activePageIndex: nil, overlays: [:])
        let fallback = try XCTUnwrap(coordinator.fingerNavigationFallbackPan)
        coordinator.startFallbackDeceleration(velocity: CGPoint(x: 0, y: 1_000), in: scroll)
        XCTAssertNotNil(coordinator.fallbackDeceleration)
        XCTAssertTrue(coordinator.gestureRecognizer(fallback, shouldReceive: FingerTouch()))
        XCTAssertNil(coordinator.fallbackDeceleration)
    }

    func testNativeDecelerationAndStationaryReleaseDoNotStartFallbackInertia() {
        let pdf = JotPDFView()
        let coordinator = JotEditorGestureCoordinator(pdfView: pdf)
        coordinator.update(isEditing: true, tool: PKLassoTool(), rulerActive: false,
                           activePageIndex: nil, overlays: [:])
        coordinator.startFallbackDeceleration(velocity: CGPoint(x: 0, y: 1_000), in: NativeDeceleratingScrollView())
        XCTAssertNil(coordinator.fallbackDeceleration)
        coordinator.startFallbackDeceleration(velocity: .zero, in: UIScrollView())
        XCTAssertNil(coordinator.fallbackDeceleration)
    }

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

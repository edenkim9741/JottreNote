import PDFKit
@preconcurrency import PencilKit
import UIKit
import XCTest

@testable import Jottre

@MainActor
final class EditorTransitionAndSortingTests: XCTestCase {
    private func overlay() -> JotPDFPageCanvasOverlay {
        JotPDFPageCanvasOverlay(canvas: JotCanvasView(), pageSize: CGSize(width: 600, height: 800))
    }

    func testPageOverlayIsConfiguredBeforeBeingReturnedToPDFKit() throws {
        let pdf = JotPDFView()
        let coordinator = JotEditorGestureCoordinator(pdfView: pdf)
        let page = overlay()
        let canvas = try XCTUnwrap(page.canvas as? JotCanvasView)

        coordinator.update(
            isEditing: true,
            tool: PKInkingTool(.pen),
            pickerVisible: true,
            rulerActive: false,
            activePageIndex: 0,
            overlays: [0: page]
        )

        XCTAssertTrue(pdf.isInMarkupMode)
        XCTAssertTrue(canvas.suppressesStandardEditActions)
        XCTAssertEqual(canvas.drawingPolicy, .pencilOnly)
        XCTAssertTrue(canvas.isDrawingEnabled)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertFalse(canvas.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)), withSender: nil))
        coordinator.update(
            isEditing: true,
            tool: PKEraserTool(.bitmap),
            pickerVisible: true,
            rulerActive: false,
            activePageIndex: 0,
            overlays: [0: page]
        )
        XCTAssertTrue(CanvasTouchRouting.shouldSuppressNativeEditMenuInteractions(isEditing: true, tool: PKEraserTool(.bitmap)))
        XCTAssertTrue(canvas.suppressesStandardEditActions)
        XCTAssertFalse(canvas.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)), withSender: nil))
    }

    func testRulerStateSurvivesTransientMissingCurrentPage() {
        let pdf = JotPDFView()
        let coordinator = JotEditorGestureCoordinator(pdfView: pdf)
        let page = overlay()
        let canvas = page.canvas

        coordinator.update(
            isEditing: true,
            tool: PKInkingTool(.pen),
            pickerVisible: true,
            rulerActive: true,
            activePageIndex: 0,
            overlays: [0: page]
        )
        XCTAssertTrue(canvas.isRulerActive)

        coordinator.update(
            isEditing: true,
            tool: PKInkingTool(.pen),
            pickerVisible: true,
            rulerActive: true,
            activePageIndex: nil,
            overlays: [0: page]
        )
        XCTAssertTrue(canvas.isRulerActive)

        coordinator.update(
            isEditing: true,
            tool: PKInkingTool(.pen),
            pickerVisible: true,
            rulerActive: false,
            activePageIndex: 0,
            overlays: [0: page]
        )
        XCTAssertFalse(canvas.isRulerActive)
    }

    func testDoubleTapZoomInstallsOneFingerOnlyRecognizerAndSuppressesPDFKitDuplicate() throws {
        let pdf = JotPDFView()
        let pdfKitDoubleTap = UITapGestureRecognizer()
        pdfKitDoubleTap.numberOfTapsRequired = 2
        pdfKitDoubleTap.numberOfTouchesRequired = 1
        pdf.addGestureRecognizer(pdfKitDoubleTap)
        let coordinator = JotCanvasZoomCoordinator {}

        coordinator.observeDoubleTapZoom(in: pdf)
        let installed = try XCTUnwrap(coordinator.doubleTapRecognizer)
        coordinator.observeDoubleTapZoom(in: pdf)

        XCTAssertFalse(pdfKitDoubleTap.isEnabled)
        XCTAssertTrue(JotCanvasZoomCoordinator.acceptsDoubleTapTouch(.direct))
        XCTAssertFalse(JotCanvasZoomCoordinator.acceptsDoubleTapTouch(.pencil))
        XCTAssertTrue(installed.delegate === coordinator)
        XCTAssertFalse(installed.cancelsTouchesInView)
        let enabledDoubleTaps = pdf.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.numberOfTapsRequired == 2 && $0.isEnabled } ?? []
        XCTAssertEqual(enabledDoubleTaps.count, 1)
        XCTAssertTrue(enabledDoubleTaps.first === installed,
            "Repeated editor synchronization must not install another active double-tap recognizer")
        coordinator.stopObservingDoubleTapZoom()
        XCTAssertTrue(pdfKitDoubleTap.isEnabled, "PDFKit's original recognizer state is restored on editor exit")
        XCTAssertFalse(pdf.gestureRecognizers?.contains(installed) ?? true)
    }

    func testDoubleTapRecognizerRemainsSingleAcrossPDFDocumentReplacement() throws {
        let pdf = JotPDFView()
        let coordinator = JotCanvasZoomCoordinator {}
        coordinator.observeDoubleTapZoom(in: pdf)
        let installed = try XCTUnwrap(coordinator.doubleTapRecognizer)
        pdf.document = try XCTUnwrap(PDFDocument(data: makePDF(pageCount: 1)))
        coordinator.observeDoubleTapZoom(in: pdf)
        pdf.document = try XCTUnwrap(PDFDocument(data: makePDF(pageCount: 4)))
        coordinator.observeDoubleTapZoom(in: pdf)

        XCTAssertTrue(coordinator.doubleTapRecognizer === installed)
        XCTAssertEqual(installed.numberOfTouchesRequired, 1)
        XCTAssertTrue(doubleTapRecognizers(in: pdf).allSatisfy { $0 === installed || !$0.isEnabled })
    }

    func testDoubleTapFitTargetIsSelectedFromCurrentScale() {
        let portrait = JotCanvasZoomCoordinator.PageFitScales(shortSide: 1.4, longSide: 0.8)

        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 0.5, scales: portrait), 0.8)
        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 0.8, scales: portrait), 1.4)
        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 1.1, scales: portrait), 1.4)
        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 1.4, scales: portrait), 0.8)
        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 2.0, scales: portrait), 1.4)
    }

    func testTwoFingerUndoGestureIsScopedToAnEditablePDFAndDoesNotCancelNavigation() throws {
        let pdf = JotPDFView()
        pdf.document = try XCTUnwrap(PDFDocument(data: makePDF(pageCount: 1)))
        let coordinator = JotEditorGestureCoordinator(pdfView: pdf)
        coordinator.installUndoDoubleTapGesture(target: self, action: #selector(handleUndoGesture(_:)))
        coordinator.installUndoDoubleTapGesture(target: self, action: #selector(handleUndoGesture(_:)))
        let recognizer = try XCTUnwrap(coordinator.undoDoubleTapRecognizer)

        XCTAssertEqual(recognizer.numberOfTouchesRequired, 2)
        XCTAssertEqual(recognizer.numberOfTapsRequired, 2)
        XCTAssertFalse(recognizer.cancelsTouchesInView)
        XCTAssertFalse(recognizer.delaysTouchesBegan)
        XCTAssertFalse(recognizer.delaysTouchesEnded)
        XCTAssertTrue(recognizer.delegate === coordinator)
        XCTAssertTrue(recognizer.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.direct.rawValue)))
        XCTAssertEqual(
            pdf.gestureRecognizers?.filter { $0 === recognizer }.count,
            1,
            "Repeated editor synchronization must not register duplicate Undo recognizers"
        )
        XCTAssertFalse(recognizer.isEnabled, "Undo is inactive until PDF editing is enabled")

        coordinator.update(
            isEditing: true,
            tool: PKInkingTool(.pen),
            pickerVisible: true,
            rulerActive: false,
            activePageIndex: 0,
            overlays: [:]
        )

        XCTAssertTrue(recognizer.isEnabled)
        XCTAssertTrue(JotEditorGestureCoordinator.acceptsUndoDoubleTapTouch(.direct))
        XCTAssertFalse(JotEditorGestureCoordinator.acceptsUndoDoubleTapTouch(.pencil))
        XCTAssertTrue(coordinator.gestureRecognizer(
            recognizer,
            shouldRecognizeSimultaneouslyWith: UIPanGestureRecognizer()
        ))

        coordinator.update(
            isEditing: false,
            tool: PKInkingTool(.pen),
            pickerVisible: false,
            rulerActive: false,
            activePageIndex: nil,
            overlays: [:]
        )
        XCTAssertFalse(recognizer.isEnabled)
        coordinator.removeUndoDoubleTapGesture()
        XCTAssertNil(coordinator.undoDoubleTapRecognizer)
        XCTAssertFalse(pdf.gestureRecognizers?.contains(recognizer) ?? true)
    }

    @objc private func handleUndoGesture(_ recognizer: UITapGestureRecognizer) {}

    private func makePDF(pageCount: Int) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).pdfData { context in
            for _ in 0..<pageCount { context.beginPage() }
        }
    }

    private func doubleTapRecognizers(in view: UIView) -> [UITapGestureRecognizer] {
        let local = (view.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.numberOfTapsRequired == 2 && $0.numberOfTouchesRequired == 1 }
        return local + view.subviews.flatMap(doubleTapRecognizers(in:))
    }

    func testNativeLassoKeepsPencilInputAndPDFFingerNavigation() throws {
        let pdf = JotPDFView()
        let scroll = UIScrollView()
        pdf.addSubview(scroll)
        let page = overlay()
        scroll.addSubview(page)
        let canvas = try XCTUnwrap(page.canvas as? JotCanvasView)
        let coordinator = JotEditorGestureCoordinator(pdfView: pdf)

        coordinator.update(
            isEditing: true,
            tool: PKLassoTool(),
            pickerVisible: true,
            rulerActive: false,
            activePageIndex: 0,
            overlays: [0: page]
        )

        XCTAssertEqual(canvas.drawingPolicy, .pencilOnly)
        XCTAssertFalse(canvas.suppressesStandardEditActions)
        XCTAssertFalse(pdf.suppressesStandardEditActions)
        XCTAssertFalse(CanvasTouchRouting.shouldSuppressNativeEditMenuInteractions(isEditing: true, tool: PKLassoTool()))
        XCTAssertFalse(canvas.isScrollEnabled)
        XCTAssertEqual(scroll.panGestureRecognizer.minimumNumberOfTouches, 1)
        XCTAssertFalse(coordinator.pdfNavigationScrollViews().contains { $0 === canvas })
    }

    func testCanvasEditMenuInteractionTracksInkAndLassoToolsWithoutDisablingDrawing() throws {
        let pdf = JotPDFView()
        let page = overlay()
        pdf.addSubview(page)
        let canvas = try XCTUnwrap(page.canvas as? JotCanvasView)
        let editMenu = UIEditMenuInteraction(delegate: nil)
        canvas.addInteraction(editMenu)
        let pdfKitMenu = try XCTUnwrap(pdf.interactions.compactMap { $0 as? UIEditMenuInteraction }.first)
        let coordinator = JotEditorGestureCoordinator(pdfView: pdf)

        coordinator.update(isEditing: true, tool: PKInkingTool(.pen), pickerVisible: true,
            rulerActive: false, activePageIndex: 0, overlays: [0: page])
        XCTAssertFalse(canvas.interactions.contains { $0 === editMenu })
        XCTAssertFalse(pdf.interactions.contains { $0 === pdfKitMenu })
        XCTAssertTrue(canvas.isUserInteractionEnabled)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)

        coordinator.update(isEditing: true, tool: PKLassoTool(), pickerVisible: true,
            rulerActive: false, activePageIndex: 0, overlays: [0: page])
        XCTAssertTrue(canvas.interactions.contains { $0 === editMenu },
            "PencilKit's native edit menu is restored for lasso selection and copy/paste")
        XCTAssertTrue(pdf.interactions.contains { $0 === pdfKitMenu })

        coordinator.update(isEditing: false, tool: PKInkingTool(.pen), pickerVisible: false,
            rulerActive: false, activePageIndex: nil, overlays: [0: page])
        XCTAssertTrue(canvas.interactions.contains { $0 === editMenu })
        XCTAssertTrue(pdf.interactions.contains { $0 === pdfKitMenu })
    }

    func testRulerFingerInteractionRemainsEnabledWithInkMenuSuppression() {
        let pdf = JotPDFView()
        let page = overlay()
        let canvas = page.canvas as! JotCanvasView
        let coordinator = JotEditorGestureCoordinator(pdfView: pdf)
        coordinator.update(
            isEditing: true,
            tool: PKInkingTool(.pen),
            pickerVisible: true,
            rulerActive: true,
            activePageIndex: 0,
            overlays: [0: page]
        )

        XCTAssertTrue(page.canvas.isRulerActive)
        XCTAssertTrue(CanvasTouchRouting.shouldSuppressNativeEditMenuInteractions(isEditing: true, tool: PKInkingTool(.pen)))
        XCTAssertTrue(canvas.suppressesStandardEditActions)
    }

    func testEditorExitRestoresPDFSelectionAndPanInput() {
        let pdf = JotPDFView()
        let scroll = UIScrollView()
        let longPress = UILongPressGestureRecognizer()
        pdf.addSubview(scroll)
        pdf.addGestureRecognizer(longPress)
        let originalTouchTypes = scroll.panGestureRecognizer.allowedTouchTypes
        let coordinator = JotEditorGestureCoordinator(pdfView: pdf)

        coordinator.update(isEditing: true, tool: PKInkingTool(.pen), pickerVisible: true,
            rulerActive: false, activePageIndex: nil, overlays: [:])
        XCTAssertTrue(pdf.isInMarkupMode)
        XCTAssertTrue(pdf.suppressesStandardEditActions)
        XCTAssertTrue(CanvasTouchRouting.shouldSuppressNativeEditMenuInteractions(isEditing: true, tool: PKInkingTool(.pen)))
        XCTAssertTrue(longPress.isEnabled, "PDFKit recognizers are left under PDFKit's control")

        coordinator.update(isEditing: false, tool: PKInkingTool(.pen), pickerVisible: false,
            rulerActive: false, activePageIndex: nil, overlays: [:])
        XCTAssertFalse(pdf.isInMarkupMode)
        XCTAssertFalse(pdf.suppressesStandardEditActions)
        XCTAssertFalse(CanvasTouchRouting.shouldSuppressNativeEditMenuInteractions(isEditing: false, tool: PKInkingTool(.pen)))
        XCTAssertEqual(scroll.panGestureRecognizer.allowedTouchTypes, originalTouchTypes)
    }

    func testSortingCriterionAndDirectionSurviveFreshDefaultsInstances() throws {
        let name = "Jottre.SortingTests." + UUID().uuidString
        let first = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { first.removePersistentDomain(forName: name) }
        for order in ZoteroAttachmentSortOrder.allCases {
            for reversed in [false, true] {
                let expected = ZoteroLibrarySorting(order: order, isReversed: reversed)
                expected.save(to: DefaultsService(userDefaults: first))
                let reopened = try XCTUnwrap(UserDefaults(suiteName: name))
                XCTAssertEqual(ZoteroLibrarySorting(defaults: DefaultsService(userDefaults: reopened)), expected)
            }
        }
    }

    func testRepeatedCriterionReversesAndNewCriterionResetsDirection() {
        let state = ZoteroLibrarySorting(order: .dateAdded)
        XCTAssertEqual(state.selecting(.dateAdded), ZoteroLibrarySorting(order: .dateAdded, isReversed: true))
        XCTAssertEqual(state.selecting(.dateAdded).selecting(.dateAdded), state)
        XCTAssertEqual(state.selecting(.title), ZoteroLibrarySorting())
    }

    func testInvalidStoredSortingUsesSafeDefaults() throws {
        let name = "Jottre.SortingTests." + UUID().uuidString
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { userDefaults.removePersistentDomain(forName: name) }
        userDefaults.set("{\"order\":\"removedOption\",\"isReversed\":true}", forKey: "zotero.library.sorting")
        XCTAssertEqual(
            ZoteroLibrarySorting(defaults: DefaultsService(userDefaults: userDefaults)),
            ZoteroLibrarySorting()
        )
    }

    func testColdLaunchStartsAtLibraryAndExplicitFileOpenIsPreserved() {
        XCTAssertNil(SceneLaunchPolicy.documentURL(explicitActivityURL: nil, fileURLs: []))
        let file = URL(fileURLWithPath: "/tmp/explicit.jot")
        XCTAssertEqual(SceneLaunchPolicy.documentURL(explicitActivityURL: nil, fileURLs: [file]), file)
        XCTAssertNil(
            SceneLaunchPolicy.documentURL(explicitActivityURL: "https://invalid.local/old-document", fileURLs: [])
        )
    }
}

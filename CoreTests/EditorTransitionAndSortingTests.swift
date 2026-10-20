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
        XCTAssertTrue(coordinator.incidentalEditMenuBlocker.isEnabled)
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

    func testDoubleTapScalePolicyTogglesBetweenFitAndCappedTwoTimesFit() {
        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 1, fit: 1, minimum: 0.5, maximum: 5), 2)
        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 2, fit: 1, minimum: 0.5, maximum: 5), 1)
        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 1, fit: 1, minimum: 0.5, maximum: 1.5), 1.5)
        XCTAssertEqual(JotCanvasZoomCoordinator.targetScale(current: 1.5, fit: 1, minimum: 0.5, maximum: 1.5), 1)
        XCTAssertNil(JotCanvasZoomCoordinator.targetScale(current: .nan, fit: 1, minimum: 0, maximum: 5))
        XCTAssertNil(JotCanvasZoomCoordinator.targetScale(current: 1, fit: 1, minimum: 2, maximum: 1))
    }

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
        XCTAssertFalse(coordinator.incidentalEditMenuBlocker.isEnabled)
        XCTAssertFalse(canvas.isScrollEnabled)
        XCTAssertEqual(scroll.panGestureRecognizer.minimumNumberOfTouches, 1)
        XCTAssertFalse(coordinator.pdfNavigationScrollViews().contains { $0 === canvas })
    }

    func testRulerFingerInteractionIsExcludedFromIncidentalMenuBlocker() {
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
        XCTAssertFalse(coordinator.incidentalEditMenuBlocker.isEnabled)
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
        XCTAssertTrue(coordinator.incidentalEditMenuBlocker.isEnabled)
        XCTAssertTrue(longPress.isEnabled, "PDFKit recognizers are left under PDFKit's control")

        coordinator.update(isEditing: false, tool: PKInkingTool(.pen), pickerVisible: false,
            rulerActive: false, activePageIndex: nil, overlays: [:])
        XCTAssertFalse(pdf.isInMarkupMode)
        XCTAssertFalse(pdf.suppressesStandardEditActions)
        XCTAssertFalse(coordinator.incidentalEditMenuBlocker.isEnabled)
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

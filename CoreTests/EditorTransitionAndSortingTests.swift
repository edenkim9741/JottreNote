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

    func testDoubleTapZoomObserverLeavesPDFKitRecognizerConfigurationUntouched() {
        let pdf = JotPDFView()
        let doubleTap = UITapGestureRecognizer()
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        doubleTap.cancelsTouchesInView = true
        pdf.addGestureRecognizer(doubleTap)
        let originalEnabled = doubleTap.isEnabled
        let originalTouchTypes = doubleTap.allowedTouchTypes
        let originalCancelsTouches = doubleTap.cancelsTouchesInView
        let coordinator = JotCanvasZoomCoordinator {}

        coordinator.observeDoubleTapZoom(in: pdf)

        XCTAssertEqual(doubleTap.isEnabled, originalEnabled)
        XCTAssertEqual(doubleTap.allowedTouchTypes, originalTouchTypes)
        XCTAssertEqual(doubleTap.cancelsTouchesInView, originalCancelsTouches)
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
        XCTAssertTrue(canvas.suppressesStandardEditActions)
        XCTAssertFalse(canvas.isScrollEnabled)
        XCTAssertEqual(scroll.panGestureRecognizer.minimumNumberOfTouches, 1)
        XCTAssertFalse(coordinator.pdfNavigationScrollViews().contains { $0 === canvas })
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
        XCTAssertTrue(longPress.isEnabled, "PDFKit recognizers are left under PDFKit's control")

        coordinator.update(isEditing: false, tool: PKInkingTool(.pen), pickerVisible: false,
            rulerActive: false, activePageIndex: nil, overlays: [:])
        XCTAssertFalse(pdf.isInMarkupMode)
        XCTAssertFalse(pdf.suppressesStandardEditActions)
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

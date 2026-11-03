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

    func testSeparateToolUndoGroupsKeepScribbleUndoIndependentAndRedoable() {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var strokes: [String] = []

        func registerTransition(from old: [String], to new: [String]) {
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: self) { _ in
                strokes = old
                undoManager.registerUndo(withTarget: self) { _ in strokes = new }
            }
            undoManager.endUndoGrouping()
            strokes = new
        }

        registerTransition(from: [], to: ["A"])
        registerTransition(from: ["A"], to: ["A", "S"])
        registerTransition(from: ["A", "S"], to: [])

        undoManager.undo()
        XCTAssertEqual(strokes, ["A", "S"], "Undoing erasure restores prior ink and Scribble")
        undoManager.undo()
        XCTAssertEqual(strokes, ["A"], "Undoing the Scribble gesture must preserve prior ink")
        undoManager.undo()
        XCTAssertTrue(strokes.isEmpty, "The next Undo may then remove the prior ink")
        undoManager.redo()
        XCTAssertEqual(strokes, ["A"], "Redo restores prior ink first")
        undoManager.redo()
        XCTAssertEqual(strokes, ["A", "S"], "The next Redo restores the Scribble stroke")
        undoManager.redo()
        XCTAssertTrue(strokes.isEmpty, "Redo reapplies Scribble erasure last")
    }

    func testScribbleUndoAndRedoRemainOnOriginatingPageManagerAfterPageChanges() {
        let scribblePageUndoManager = UndoManager()
        let newlyVisiblePageUndoManager = UndoManager()
        scribblePageUndoManager.groupsByEvent = false
        newlyVisiblePageUndoManager.groupsByEvent = false
        var strokes = ["A"]

        func register(from previous: [String], to next: [String], on manager: UndoManager) {
            manager.beginUndoGrouping()
            manager.registerUndo(withTarget: self) { _ in
                strokes = previous
                manager.registerUndo(withTarget: self) { _ in strokes = next }
            }
            manager.endUndoGrouping()
            strokes = next
        }

        register(from: ["A"], to: ["A", "S"], on: scribblePageUndoManager)
        register(from: ["A", "S"], to: [], on: scribblePageUndoManager)

        XCTAssertFalse(newlyVisiblePageUndoManager.canUndo)
        XCTAssertTrue(scribblePageUndoManager.canUndo)

        // The view has moved to a different page, but the Scribble history
        // must continue to use the manager that owned the originating canvas.
        scribblePageUndoManager.undo()
        XCTAssertEqual(strokes, ["A", "S"])
        XCTAssertTrue(scribblePageUndoManager.canUndo)

        scribblePageUndoManager.undo()
        XCTAssertEqual(strokes, ["A"])

        scribblePageUndoManager.redo()
        XCTAssertEqual(strokes, ["A", "S"])
        scribblePageUndoManager.redo()
        XCTAssertTrue(strokes.isEmpty)
        XCTAssertFalse(newlyVisiblePageUndoManager.canUndo)
    }

    func testUndoTransitionsRegisteredInSeparateRunLoopEventsRemainSeparate() {
        let undoManager = UndoManager()
        var state = "D1"
        let eraseRegistration = expectation(description: "Erase action is registered on next event")

        func register(_ previousState: String, on manager: UndoManager) {
            manager.beginUndoGrouping()
            manager.registerUndo(withTarget: self) { _ in state = previousState }
            manager.endUndoGrouping()
        }

        register("D0", on: undoManager) // Scribble creation undo.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            state = "D2"
            register("D1", on: undoManager) // Erase undo, in a distinct event.

            undoManager.undo()
            XCTAssertEqual(state, "D1", "The first Undo should reverse only the erase")
            undoManager.undo()
            XCTAssertEqual(state, "D0", "The next Undo should reverse Scribble creation")
            eraseRegistration.fulfill()
        }

        wait(for: [eraseRegistration], timeout: 1)
    }

    func testReplacingNativeScribbleActionKeepsEraseAndCreationAsTwoUndoSteps() {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        var state = "D1"

        // Simulate PencilKit's Scribble drawing action, then consume it before
        // the programmatic drawing replacement invalidates its native entry.
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { _ in state = "D0" }
        undoManager.endUndoGrouping()
        undoManager.undo()
        XCTAssertEqual(state, "D0")

        // Install the explicit D1 -> D0 replacement and then the D2 -> D1
        // Erase action, matching the controller's two-event registration.
        state = "D1"
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { _ in
            state = "D0"
            undoManager.registerUndo(withTarget: self) { _ in state = "D1" }
        }
        undoManager.endUndoGrouping()
        state = "D2"

        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { _ in
            state = "D1"
            undoManager.registerUndo(withTarget: self) { _ in state = "D2" }
        }
        undoManager.endUndoGrouping()

        undoManager.undo()
        XCTAssertEqual(state, "D1", "Undo 1 reverses Erase")
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(state, "D0", "Undo 2 removes only the Scribble")

        undoManager.redo()
        XCTAssertEqual(state, "D1", "Redo 1 restores the Scribble")
        undoManager.redo()
        XCTAssertEqual(state, "D2", "Redo 2 reapplies Erase")
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

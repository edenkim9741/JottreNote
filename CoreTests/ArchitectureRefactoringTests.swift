import PDFKit
@preconcurrency import PencilKit
import UIKit
import XCTest

@testable import Jottre

@MainActor
final class ArchitectureRefactoringTests: XCTestCase {
    private func overlay(size: CGSize = CGSize(width: 80, height: 100)) -> JotPDFPageCanvasOverlay {
        JotPDFPageCanvasOverlay(canvas: JotCanvasView(), pageSize: size)
    }

    func testGeometryRejectsInvalidPageAndScale() {
        for invalid: CGFloat in [0, -1, .nan, .infinity] {
            XCTAssertNil(
                JotCanvasRenderGeometry(
                    pageSize: CGSize(width: invalid, height: 100),
                    drawingSize: CGSize(width: 1200, height: 1500),
                    displayScale: 3,
                    screenScale: 2
                )
            )
            XCTAssertNil(
                JotCanvasRenderGeometry(
                    pageSize: CGSize(width: 80, height: 100),
                    drawingSize: CGSize(width: 1200, height: 1500),
                    displayScale: invalid,
                    screenScale: 2
                )
            )
        }
    }

    func testGeometryKeepsScreenDensitySeparateFromSmallPageZoom() throws {
        let geometry = try XCTUnwrap(
            JotCanvasRenderGeometry(
                pageSize: CGSize(width: 80, height: 100),
                drawingSize: CGSize(width: 1200, height: 1500),
                displayScale: 12,
                screenScale: 3
            )
        )
        XCTAssertEqual(geometry.viewportSize, CGSize(width: 960, height: 1200))
        XCTAssertEqual(geometry.canvasZoom, 0.8, accuracy: 0.0001)
        XCTAssertEqual(geometry.screenScale, 3)
        XCTAssertEqual(geometry.inversePageScale.a, 1 / 12, accuracy: 0.0001)
    }

    func testDisplayRatioUsesMeasuredPageVectorsAndPDFScaleAsFallback() {
        XCTAssertEqual(
            JotCanvasRenderGeometry.displayRatio(
                pageSize: CGSize(width: 100, height: 200),
                displayedWidthVector: CGVector(dx: 300, dy: 0),
                displayedHeightVector: CGVector(dx: 0, dy: 800),
                pdfViewScaleFactor: 2
            ),
            4,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            JotCanvasRenderGeometry.displayRatio(
                pageSize: CGSize(width: 100, height: 200),
                displayedWidthVector: .zero,
                displayedHeightVector: .zero,
                pdfViewScaleFactor: 2
            ),
            2,
            accuracy: 0.0001
        )
    }

    func testLandscapeGeometryUsesSameNormalizedMapping() throws {
        let geometry = try XCTUnwrap(
            JotCanvasRenderGeometry(
                pageSize: CGSize(width: 1600, height: 1200),
                drawingSize: CGSize(width: 1200, height: 900),
                displayScale: 3,
                screenScale: 2
            )
        )
        XCTAssertEqual(geometry.canvasZoom, 4)
        XCTAssertEqual(geometry.viewportSize, CGSize(width: 4800, height: 3600))
    }

    func testDeferredZoomKeepsInkAndPDFRegisteredDuringOuterTransform() {
        let overlay = overlay()
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        host.addSubview(overlay)
        overlay.configure(displayScale: 2)
        let normalizedPoint = CGPoint(x: 600, y: 750)
        let canvasPoint = CGPoint(
            x: normalizedPoint.x * overlay.canvas.zoomScale,
            y: normalizedPoint.y * overlay.canvas.zoomScale
        )
        // PDFKit animates its outer page while the inner canvas refresh waits.
        for scale: CGFloat in [2, 3, 6, 12] {
            overlay.transform = CGAffineTransform(scaleX: scale, y: scale)
            let ink = overlay.canvas.convert(canvasPoint, to: host)
            let pdf = overlay.convert(CGPoint(x: 40, y: 50), to: host)
            XCTAssertEqual(ink.x, pdf.x, accuracy: 0.001)
            XCTAssertEqual(ink.y, pdf.y, accuracy: 0.001)
        }
    }

    func testZoomNotificationsCoalesceWithoutFramePolling() async throws {
        var refreshes = 0
        let coordinator = JotCanvasZoomCoordinator { refreshes += 1 }
        for _ in 0..<30 { coordinator.scaleChanged() }
        XCTAssertEqual(refreshes, 0)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(refreshes, 1)
    }

    func testPendingZoomRefreshDoesNotRetainCoordinator() async throws {
        var refreshes = 0
        weak var released: JotCanvasZoomCoordinator?
        autoreleasepool {
            let coordinator = JotCanvasZoomCoordinator { refreshes += 1 }
            released = coordinator
            coordinator.scaleChanged()
        }
        XCTAssertNil(released)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(refreshes, 0)
    }

    func testOffscreenOverlayAndCanvasAreReleased() {
        let store = JotPageOverlayStore()
        let page = PDFPage()
        weak var releasedOverlay: JotPDFPageCanvasOverlay?
        weak var releasedCanvas: PKCanvasView?
        autoreleasepool {
            let overlay = overlay()
            releasedOverlay = overlay
            releasedCanvas = overlay.canvas
            store.register(overlay, page: page, index: 3)
            XCTAssertTrue(store.remove(overlay, page: page))
        }
        XCTAssertTrue(store.canvases.isEmpty)
        XCTAssertNil(releasedOverlay)
        XCTAssertNil(releasedCanvas)
    }

    func testPDFKitRetainedOverlayCanRebindWithoutDuplicateRegistration() {
        let store = JotPageOverlayStore()
        let page = PDFPage()
        let overlay = overlay()
        store.register(overlay, page: page, index: 3)
        XCTAssertTrue(store.remove(overlay, page: page))
        XCTAssertTrue(store.overlay(for: page) === overlay)
        store.register(overlay, page: page, index: 3)
        XCTAssertEqual(store.indices.count, 1)
        XCTAssertEqual(store.canvases.count, 1)
    }

    func testStaleEndCallbackCannotRemoveNewDocumentOverlay() {
        let store = JotPageOverlayStore()
        let oldPage = PDFPage()
        let newPage = PDFPage()
        let oldOverlay = overlay()
        let newOverlay = overlay()
        store.register(oldOverlay, page: oldPage, index: 0)
        store.reset()
        store.register(newOverlay, page: newPage, index: 0)
        XCTAssertFalse(store.remove(oldOverlay, page: oldPage))
        XCTAssertTrue(store.overlays[0] === newOverlay)
    }

    func testSingleInputStateConfiguresNewPagesAndScopesRuler() throws {
        let pdf = JotPDFView()
        let coordinator = JotEditorGestureCoordinator(pdfView: pdf)
        let first = overlay()
        let second = overlay()
        let canvas = try XCTUnwrap(second.canvas as? JotCanvasView)
        coordinator.update(
            isEditing: true,
            tool: PKInkingTool(.pen),
            pickerVisible: true,
            rulerActive: true,
            activePageIndex: 1,
            overlays: [0: first, 1: second]
        )
        XCTAssertFalse(first.canvas.isRulerActive)
        XCTAssertTrue(second.canvas.isRulerActive)
        XCTAssertEqual(canvas.drawingPolicy, .pencilOnly)
        XCTAssertFalse(canvas.canPerformAction(NSSelectorFromString("selectAll:"), withSender: nil))
        coordinator.update(
            isEditing: true,
            tool: PKLassoTool(),
            pickerVisible: true,
            rulerActive: true,
            activePageIndex: 0,
            overlays: [0: first, 1: second]
        )
        XCTAssertEqual(canvas.drawingPolicy, .pencilOnly)
        XCTAssertFalse(canvas.suppressesStandardEditActions)
        XCTAssertFalse(coordinator.incidentalEditMenuBlocker.isEnabled)
        XCTAssertTrue(first.canvas.isRulerActive)
        XCTAssertFalse(second.canvas.isRulerActive)
    }

    func testReadingRestoresPDFModeAndPanTouchTypes() {
        let pdf = JotPDFView()
        let scroll = UIScrollView()
        let longPress = UILongPressGestureRecognizer()
        pdf.addSubview(scroll)
        pdf.addGestureRecognizer(longPress)
        let original = scroll.panGestureRecognizer.allowedTouchTypes
        let coordinator = JotEditorGestureCoordinator(pdfView: pdf)
        coordinator.update(
            isEditing: true,
            tool: PKInkingTool(.pen),
            pickerVisible: true,
            rulerActive: false,
            activePageIndex: nil,
            overlays: [:]
        )
        XCTAssertTrue(longPress.isEnabled)
        coordinator.update(
            isEditing: false,
            tool: PKInkingTool(.pen),
            pickerVisible: false,
            rulerActive: false,
            activePageIndex: nil,
            overlays: [:]
        )
        XCTAssertTrue(longPress.isEnabled)
        XCTAssertEqual(scroll.panGestureRecognizer.allowedTouchTypes, original)
        XCTAssertFalse(pdf.suppressesStandardEditActions)
    }

    func testTemporaryWorkspaceCleansUpAfterSuccessAndFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try TemporaryFileWorkspace.withDirectory(in: root) { url in
            try Data([1, 2, 3]).write(to: url.appendingPathComponent("payload"))
            return url
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertThrowsError(try TemporaryFileWorkspace.withDirectory(in: root) { _ in throw TestFailure.expected })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testTemporaryPruningPreservesRealConflictCopiesAndActiveWorkspaces() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expired = root.appendingPathComponent("operation_" + UUID().uuidString)
        let real = root.appendingPathComponent("document (iPad Conflict Copy).pdf")
        try FileManager.default.createDirectory(at: expired, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: expired.path)
        try Data([1]).write(to: real)
        try TemporaryFileWorkspace.withDirectory(in: root) { active in
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: active.path)
            try TemporaryFileWorkspace.withDirectory(in: root) { _ in
                XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
            }
        }
    }

    func testAsyncResourceTransactionsSerializeSameKey() async throws {
        let key = UUID().uuidString
        let probe = ConcurrencyProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await AsyncResourceAccessCoordinator.shared.withAccess(to: key) {
                        await probe.begin()
                        try await Task.sleep(for: .milliseconds(2))
                        await probe.end()
                    }
                }
            }
            try await group.waitForAll()
        }
        let maximum = await probe.maximum
        XCTAssertEqual(maximum, 1)
    }

    func testAsyncResourceErrorReleasesLock() async throws {
        let key = UUID().uuidString
        do {
            try await AsyncResourceAccessCoordinator.shared.withAccess(to: key) { throw TestFailure.expected }
            XCTFail("Expected failure")
        } catch TestFailure.expected {}
        let result = try await AsyncResourceAccessCoordinator.shared.withAccess(to: key) { 42 }
        XCTAssertEqual(result, 42)
    }

    func testCancelledQueuedResourceOperationDoesNotBlockNextWriter() async throws {
        let key = UUID().uuidString
        let (entered, continuation) = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await AsyncResourceAccessCoordinator.shared.withAccess(to: key) {
                continuation.yield()
                continuation.finish()
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        for await _ in entered { break }
        let cancelled = Task {
            try await AsyncResourceAccessCoordinator.shared.withAccess(to: key) { 7 }
        }
        cancelled.cancel()
        try await holder.value
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled operation should not run")
        } catch is CancellationError {}
        let result = try await AsyncResourceAccessCoordinator.shared.withAccess(to: key) { 42 }
        XCTAssertEqual(result, 42)
    }

    func testIndependentResourcesAreNotGloballySerialized() async throws {
        let probe = ConcurrencyProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                let key = UUID().uuidString
                group.addTask {
                    try await AsyncResourceAccessCoordinator.shared.withAccess(to: key) {
                        await probe.begin()
                        try await Task.sleep(for: .milliseconds(30))
                        await probe.end()
                    }
                }
            }
            try await group.waitForAll()
        }
        let maximum = await probe.maximum
        XCTAssertEqual(maximum, 2)
    }

    func testPageReplacementKeepsOtherInkAndIgnoresDuplicateCallbacks() {
        func stroke(_ x: CGFloat) -> PKStroke {
            let points = [CGPoint(x: x, y: 10), CGPoint(x: x + 20, y: 30)].enumerated().map { index, point in
                PKStrokePoint(
                    location: point,
                    timeOffset: Double(index) * 0.1,
                    size: CGSize(width: 2, height: 2),
                    opacity: 1,
                    force: 1,
                    azimuth: 0,
                    altitude: .pi / 2
                )
            }
            return PKStroke(
                ink: PKInk(.pen, color: .black),
                path: PKStrokePath(controlPoints: points, creationDate: .distantPast)
            )
        }
        let first = stroke(10)
        let other = stroke(60)
        let state = JotEditorDrawingState()
        state.load(drawing: PKDrawing(strokes: [first, other]), strokePageIndices: [0, 14])
        let edited = PKDrawing(strokes: [stroke(30)])
        XCTAssertTrue(state.replacePage(edited, at: 0))
        XCTAssertFalse(state.replacePage(edited, at: 0))
        XCTAssertEqual(state.committedDrawing.strokes.count, 2)
        let index = state.committedStrokePageIndices.firstIndex(of: 14)!
        XCTAssertEqual(state.committedDrawing.strokes[index].randomSeed, other.randomSeed)
        XCTAssertTrue(state.replacePage(PKDrawing(), at: 0))
        XCTAssertEqual(state.committedStrokePageIndices, [14])
    }

    func testSeparateCacheInstancesPreserveConcurrentMetadataChanges() async throws {
        let userID = "refactor-test-" + UUID().uuidString
        let store = ZoteroCacheStore()
        var snapshot = ZoteroCacheSnapshot.empty(userID: userID)
        for index in 0..<16 {
            let key = String(format: "%08d", index)
            snapshot.attachments[key] = ZoteroAttachment(
                key: key,
                parentItemKey: nil,
                contentType: "application/pdf",
                filename: key + ".pdf",
                localCachePath: nil,
                syncStatus: .cloudOnly,
                version: 1,
                md5: nil,
                modificationTimeMilliseconds: nil
            )
        }
        try store.save(snapshot)
        let keys = Array(snapshot.attachments.keys)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask { _ = try ZoteroCacheStore().markDirty(key: key, userID: userID) }
            }
            try await group.waitForAll()
        }
        XCTAssertTrue(store.load(userID: userID).attachments.values.allSatisfy { $0.syncStatus == .dirty })
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZoteroLibraryCache")
        try? FileManager.default.removeItem(
            at: root.appendingPathComponent(userID.filter { $0.isLetter || $0.isNumber } + ".json")
        )
    }
}

private enum TestFailure: Error { case expected }
private actor ConcurrencyProbe {
    private var active = 0
    private(set) var maximum = 0
    func begin() {
        active += 1
        maximum = max(maximum, active)
    }
    func end() { active -= 1 }
}

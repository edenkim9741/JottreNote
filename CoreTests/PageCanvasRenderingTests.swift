import PDFKit
@preconcurrency import PencilKit
import UIKit
import XCTest
@testable import Jottre

@MainActor
final class PageCanvasRenderingTests: XCTestCase {
    private let pageSize = CGSize(width: 80, height: 100)

    func testPDFReplacementRestoresSavedPageAndClampsWhenPageCountShrinks() {
        XCTAssertEqual(
            JotPDFPageRestorationPolicy.targetIndex(pendingIndex: 8, currentIndex: 2, pageCount: 12),
            8
        )
        XCTAssertEqual(
            JotPDFPageRestorationPolicy.targetIndex(pendingIndex: 8, currentIndex: 2, pageCount: 4),
            3
        )
        XCTAssertEqual(
            JotPDFPageRestorationPolicy.targetIndex(pendingIndex: nil, currentIndex: 2, pageCount: 4),
            2
        )
        XCTAssertNil(JotPDFPageRestorationPolicy.targetIndex(pendingIndex: 2, currentIndex: nil, pageCount: 0))
    }

    private func drawing(coordinateScale: CGFloat = 1) -> PKDrawing {
        let points = [CGPoint(x: 12, y: 75), CGPoint(x: 36, y: 22), CGPoint(x: 68, y: 66)]
            .enumerated().map { index, point in
                PKStrokePoint(location: CGPoint(x: point.x * coordinateScale, y: point.y * coordinateScale), timeOffset: Double(index) * 0.1,
                              size: CGSize(width: 6 * coordinateScale, height: 6 * coordinateScale), opacity: 1,
                              force: 1, azimuth: 0, altitude: .pi / 2)
            }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
                                          path: PKStrokePath(controlPoints: points, creationDate: .distantPast))])
    }

    func testSmallPageUsesPencilKitZoomWithoutDoubleScalingOrChangingInk() {
        let canvas = PKCanvasView()
        let overlay = JotPDFPageCanvasOverlay(canvas: canvas, pageSize: pageSize)
        let pageHost = UIView(frame: CGRect(origin: .zero, size: pageSize))
        pageHost.addSubview(overlay)
        canvas.drawing = drawing(coordinateScale: 15)
        let original = canvas.drawing.dataRepresentation()
        for scale: CGFloat in [1, 3, 6, 12, 0.5, 3] {
            // Simulate PDFKit applying the page zoom while the overlay updates
            // PencilKit's inner zoom in that same scale transaction.
            overlay.transform = CGAffineTransform(scaleX: scale, y: scale)
            overlay.configure(displayScale: scale)
            overlay.layoutIfNeeded()
            XCTAssertEqual(canvas.zoomScale, scale / 15, accuracy: 0.001)
            XCTAssertEqual(canvas.bounds.width, pageSize.width * scale, accuracy: 0.001)
            XCTAssertEqual(canvas.convert(canvas.bounds, to: overlay).width, pageSize.width, accuracy: 0.001)
            XCTAssertEqual(canvas.transform, .identity)
            XCTAssertEqual(canvas.contentOffset, .zero)
            let canvasPinches = gestureRecognizers(in: canvas).compactMap { $0 as? UIPinchGestureRecognizer }
            XCTAssertFalse(canvasPinches.isEmpty, "The native canvas zoom range should install its pinch recognizer")
            XCTAssertTrue(canvasPinches.allSatisfy { !$0.isEnabled }, "Only PDFView may receive document pinch zoom")
            XCTAssertEqual(canvas.drawing.dataRepresentation(), original)
            // Native PencilKit zoom maps drawing points into its viewport;
            // the inverse view transform maps them back into PDF page space.
            let inkPoint = CGPoint(x: 36, y: 22)
            let viewPoint = CGPoint(x: inkPoint.x * 15 * canvas.zoomScale, y: inkPoint.y * 15 * canvas.zoomScale)
            let pagePoint = canvas.convert(viewPoint, to: overlay)
            XCTAssertEqual(pagePoint.x, inkPoint.x, accuracy: 0.01)
            XCTAssertEqual(pagePoint.y, inkPoint.y, accuracy: 0.01)
            let renderedInkPoint = canvas.convert(viewPoint, to: pageHost)
            let renderedPagePoint = overlay.convert(inkPoint, to: pageHost)
            XCTAssertEqual(renderedInkPoint.x, renderedPagePoint.x, accuracy: 0.01)
            XCTAssertEqual(renderedInkPoint.y, renderedPagePoint.y, accuracy: 0.01)
        }
    }

    func testZoomedPageDrawingStillRoundTripsThroughDocumentCoordinates() {
        let canvas = PKCanvasView()
        let overlay = JotPDFPageCanvasOverlay(canvas: canvas, pageSize: pageSize)
        let local = drawing(coordinateScale: 15)
        canvas.drawing = local
        overlay.configure(displayScale: 9)
        let normalized = CGSize(width: 1_200, height: 1_500)
        let global = JotPageCanvasCoordinateAdapter.documentDrawing(
            from: canvas.drawing, pageIndex: 2, overlaySize: overlay.drawingSize,
            normalizedPageSize: normalized, pageSpacing: 20
        )
        let restored = JotPageCanvasCoordinateAdapter.localDrawing(
            from: global, pageIndices: [2], pageIndex: 2, overlaySize: overlay.drawingSize,
            normalizedPageSize: normalized, pageSpacing: 20
        )
        XCTAssertEqual(restored.strokes.count, local.strokes.count)
        let a = restored.strokes[0]
        let b = local.strokes[0]
        for index in 0..<a.path.count {
            let lhs = a.path[index].location.applying(a.transform)
            let rhs = b.path[index].location.applying(b.transform)
            XCTAssertEqual(lhs.x, rhs.x, accuracy: 0.001)
            XCTAssertEqual(lhs.y, rhs.y, accuracy: 0.001)
        }
    }

    func testStoredSmallPageScalingIsMovedIntoVectorPointsAndMask() throws {
        var stroke = drawing().strokes[0]
        stroke.randomSeed = 42
        stroke.mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 80, height: 50))
        stroke.transform = CGAffineTransform(scaleX: 15, y: 15)
        let restored = JotPageCanvasCoordinateAdapter.localDrawing(
            from: PKDrawing(strokes: [stroke]), pageIndices: [0], pageIndex: 0,
            overlaySize: CGSize(width: 1_200, height: 1_500),
            normalizedPageSize: CGSize(width: 1_200, height: 1_500), pageSpacing: 20
        )
        let result = try XCTUnwrap(restored.strokes.first)
        XCTAssertEqual(result.transform, .identity)
        XCTAssertEqual(result.randomSeed, stroke.randomSeed)
        XCTAssertEqual(result.path.creationDate, stroke.path.creationDate)
        XCTAssertGreaterThan(result.path.count, stroke.path.count)
        XCTAssertEqual(result.path[0].location.x, stroke.path[0].location.x * 15, accuracy: 0.001)
        XCTAssertEqual(result.path[0].size.width, stroke.path[0].size.width * 15, accuracy: 0.001)
        XCTAssertEqual(result.mask?.bounds, CGRect(x: 0, y: 0, width: 1_200, height: 750))
    }

    func testToolWidthsAndLassoRemainInPageCoordinatesAfterNormalization() throws {
        let overlay = JotPDFPageCanvasOverlay(canvas: PKCanvasView(), pageSize: pageSize)
        overlay.configure(displayScale: 6)
        let pen = try XCTUnwrap(overlay.toolInDrawingCoordinates(PKInkingTool(.pen, color: .black, width: 1)) as? PKInkingTool)
        XCTAssertEqual(pen.width * overlay.canvas.zoomScale, 1 * 6, accuracy: 0.001)
        let eraser = try XCTUnwrap(overlay.toolInDrawingCoordinates(PKEraserTool(.bitmap, width: 4)) as? PKEraserTool)
        // PencilKit bounds eraser widths internally. Its bitmap mode and
        // effective width must survive renderer zoom changes without a reset.
        overlay.canvas.tool = eraser
        overlay.configure(displayScale: 3)
        let zoomedEraser = try XCTUnwrap(overlay.canvas.tool as? PKEraserTool)
        XCTAssertEqual(zoomedEraser.eraserType, eraser.eraserType)
        XCTAssertEqual(zoomedEraser.width, eraser.width)
        let widePen = try XCTUnwrap(overlay.toolInDrawingCoordinates(PKInkingTool(.pen, color: .black, width: 3)) as? PKInkingTool)
        XCTAssertTrue(widePen.inkType.validWidthRange.contains(widePen.width))
        XCTAssertTrue(overlay.toolInDrawingCoordinates(PKLassoTool()) is PKLassoTool)
    }

    func testActualPDFKitOverlayTracksSmallPageAtFitAndThreeTimesZoom() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let pdfView = PDFView(frame: controller.view.bounds)
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.displayMode = .singlePageContinuous
        controller.view.addSubview(pdfView)
        let provider = RenderingOverlayProvider()
        pdfView.pageOverlayViewProvider = provider
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize)).pdfData { context in
            context.beginPage()
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: pageSize))
        }
        pdfView.document = try XCTUnwrap(PDFDocument(data: data))
        pdfView.autoScales = true
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let pdfPinches = gestureRecognizers(in: pdfView).compactMap { $0 as? UIPinchGestureRecognizer }
        XCTAssertTrue(pdfPinches.contains(where: \.isEnabled), "PDFView must retain the active document pinch recognizer")
        let fit = pdfView.scaleFactor
        pdfView.maxScaleFactor = fit * 4
        pdfView.autoScales = false
        for factor: CGFloat in [1, 3, 1] {
            pdfView.scaleFactor = fit * factor
            try await Task.sleep(for: .milliseconds(200))
            let overlay = try XCTUnwrap(provider.overlay)
            overlay.configure(in: pdfView, pdfScaleFactor: pdfView.scaleFactor)
            overlay.layoutIfNeeded()
            let pageRect = overlay.convert(overlay.bounds, to: pdfView)
            let canvasRect = overlay.canvas.convert(overlay.canvas.bounds, to: pdfView)
            XCTAssertEqual(canvasRect.minX, pageRect.minX, accuracy: 0.01)
            XCTAssertEqual(canvasRect.minY, pageRect.minY, accuracy: 0.01)
            XCTAssertEqual(canvasRect.width, pageRect.width, accuracy: 0.01)
            XCTAssertEqual(canvasRect.height, pageRect.height, accuracy: 0.01)
            XCTAssertEqual(overlay.canvas.zoomScale, pageRect.width / overlay.drawingSize.width, accuracy: 0.001)
        }
    }

    func testCaptureSmallPageRenderingBeforeAndAfterNativeZoom() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 768)
        let controller = UIViewController()
        controller.view.backgroundColor = .white
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let scale: CGFloat = 6
        let oldCanvas = PKCanvasView(frame: CGRect(origin: .zero, size: pageSize))
        oldCanvas.backgroundColor = .clear
        oldCanvas.isOpaque = false
        oldCanvas.isScrollEnabled = false
        oldCanvas.drawing = drawing()
        // Reproduce the old architecture: a high outer contentScaleFactor
        // with PencilKit's internal zoom left at 1, then PDFKit-style scaling.
        let oldPage = UIView(frame: CGRect(origin: .zero, size: pageSize))
        oldPage.addSubview(oldCanvas)
        oldPage.transform = CGAffineTransform(scaleX: scale, y: scale)
        oldPage.center = CGPoint(x: 250, y: 380)
        controller.view.addSubview(oldPage)
        oldCanvas.contentScaleFactor = scene.screen.scale * scale
        oldCanvas.layer.contentsScale = oldCanvas.contentScaleFactor
        let canvas = PKCanvasView()
        let overlay = JotPDFPageCanvasOverlay(canvas: canvas, pageSize: pageSize)
        overlay.transform = CGAffineTransform(scaleX: scale, y: scale)
        overlay.center = CGPoint(x: 760, y: 380)
        controller.view.addSubview(overlay)
        var cachedStroke = oldCanvas.drawing.strokes[0]
        cachedStroke.transform = CGAffineTransform(scaleX: 15, y: 15)
        canvas.drawing = JotPageCanvasCoordinateAdapter.localDrawing(
            from: PKDrawing(strokes: [cachedStroke]), pageIndices: [0], pageIndex: 0,
            overlaySize: overlay.drawingSize, normalizedPageSize: overlay.drawingSize, pageSpacing: 0
        )
        overlay.configure(displayScale: scale)
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(1))
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let screenshot = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Small page ink: outer scaling (left), native PencilKit zoom (right)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("small-page-ink-comparison.png")
        try screenshot.pngData()?.write(to: output)
        print("[InkRenderingTest] screenshot: \(output.path)")
        let oldEdges = try edgePixelRatio(in: screenshot, rect: CGRect(x: 10, y: 80, width: 480, height: 600))
        let newEdges = try edgePixelRatio(in: screenshot, rect: CGRect(x: 520, y: 80, width: 480, height: 600))
        print("[InkRenderingTest] edge pixels / dark ink pixels: old=\(oldEdges), new=\(newEdges)")
        XCTAssertGreaterThan(oldEdges, newEdges * 3,
                             "Native canvas zoom must reduce the broad blurry edge bands; a blank canvas cannot pass")
        XCTAssertEqual(oldCanvas.zoomScale, 1)
        XCTAssertEqual(canvas.zoomScale, scale / 15, accuracy: 0.001)
    }

    private func edgePixelRatio(in image: UIImage, rect: CGRect) throws -> Double {
        let source = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(source.width) / image.size.width
        let crop = try XCTUnwrap(source.cropping(to: CGRect(
            x: rect.minX * scale, y: rect.minY * scale,
            width: rect.width * scale, height: rect.height * scale
        )))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        var dark = 0
        var edge = 0
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let value = bytes[offset]
                if value < 128 { dark += 1 }
                if value > 8 && value < 247 { edge += 1 }
            }
        }
        XCTAssertGreaterThan(dark, 1_000, "The captured canvas must actually contain ink")
        return Double(edge) / Double(max(dark, 1))
    }

    private func gestureRecognizers(in view: UIView) -> [UIGestureRecognizer] {
        (view.gestureRecognizers ?? []) + view.subviews.flatMap(gestureRecognizers(in:))
    }
}

@MainActor
private final class RenderingOverlayProvider: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    var overlay: JotPDFPageCanvasOverlay?
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let result = JotPDFPageCanvasOverlay(canvas: PKCanvasView(), pageSize: page.bounds(for: .cropBox).size)
        overlay = result
        return result
    }
    func pdfView(_ view: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        guard let result = overlayView as? JotPDFPageCanvasOverlay else { return }
        result.prepareForPage(size: result.bounds.size, drawingWidth: 1_200)
        result.configure(in: view, pdfScaleFactor: view.scaleFactor)
    }
}

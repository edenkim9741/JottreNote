@preconcurrency import PencilKit
import PDFKit
import UIKit

enum JotPDFPageRestorationPolicy {
    static func targetIndex(pendingIndex: Int?, currentIndex: Int?, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        return min(max(0, pendingIndex ?? currentIndex ?? 0), pageCount - 1)
    }
}

#if DEBUG
enum JotCanvasGeometryExperimentMode: Int, CaseIterable {
    case normal
    case noManualContentSize
    case noOffsetReset
    case neither

    var setsContentSize: Bool { self != .noManualContentSize && self != .neither }
    var resetsContentOffset: Bool { self != .noOffsetReset && self != .neither }
}
#endif

/// PDFKit transforms this page container. PencilKit owns as much of the zoom as
/// its scroll view supports. If that zoom range is reached, the viewport host
/// supplies only the remaining scale while preserving the page-space geometry.
@MainActor
final class JotPDFPageCanvasOverlay: UIView {
    let canvas: PKCanvasView
    private let viewportHost = UIView()
    private(set) var drawingSize: CGSize
    private(set) var displayScale: CGFloat = 1
    private(set) var diagnosticsPageIndex: Int?
    private(set) var diagnosticsPageRotation = 0
    private(set) var diagnosticsCropBox = CGRect.zero
    private var appliedGeometry: JotCanvasRenderGeometry?
    private var lastMemorySampleZoomBucket: Int?
#if DEBUG
    static var geometryExperimentMode: JotCanvasGeometryExperimentMode = .normal
    private var appliedExperimentMode: JotCanvasGeometryExperimentMode = .normal
#endif
    private weak var scaleReferenceView: UIView?
    private(set) var pdfViewScaleFactor: CGFloat = 1
    private(set) var fitScaleFactor: CGFloat = 1
    var viewportHostTransform: CGAffineTransform { viewportHost.transform }

    init(canvas: PKCanvasView, pageSize: CGSize, drawingWidth: CGFloat = 1_200) {
        self.canvas = canvas
        self.drawingSize = CGSize(width: drawingWidth, height: drawingWidth * pageSize.height / pageSize.width)
        super.init(frame: CGRect(origin: .zero, size: pageSize))
        backgroundColor = .clear
        clipsToBounds = true
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.clipsToBounds = true
        canvas.isScrollEnabled = false
        canvas.bounces = false
        canvas.bouncesZoom = false
        canvas.minimumZoomScale = 0.01
        canvas.maximumZoomScale = 64
        canvas.contentInset = .zero
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.automaticallyAdjustsScrollIndicatorInsets = false
        viewportHost.backgroundColor = .clear
        viewportHost.clipsToBounds = true
        addSubview(viewportHost)
        viewportHost.addSubview(canvas)
        updateCanvasGeometry()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if CanvasTouchRouting.shouldPassDirectTouchesThroughOverlay(rulerActive: canvas.isRulerActive),
            event?.allTouches?.contains(where: { $0.type == .direct }) == true
        {
            // `.pencilOnly` controls drawing, not UIKit hit testing. Let direct
            // touches reach PDFKit's page recognizers; Pencil input still hits
            // the page-local PKCanvasView. Keep the overlay hit-testable while
            // the PencilKit ruler is active so fingers can manipulate it.
            return false
        }
        return super.point(inside: point, with: event)
    }

    func prepareForPage(size: CGSize, drawingWidth: CGFloat) {
        guard size.width > 0, size.height > 0, drawingWidth > 0 else { return }
        drawingSize = CGSize(width: drawingWidth, height: drawingWidth * size.height / size.width)
        updateCanvasGeometry()
    }

    func setDiagnosticsPage(_ page: PDFPage, index: Int) {
        let pageChanged = diagnosticsPageIndex != index
            || diagnosticsPageRotation != page.rotation
            || diagnosticsCropBox != page.bounds(for: .cropBox)
        diagnosticsPageIndex = index
        diagnosticsPageRotation = page.rotation
        diagnosticsCropBox = page.bounds(for: .cropBox)
        if pageChanged { lastMemorySampleZoomBucket = nil }
    }

    func configure(displayScale: CGFloat) {
        guard displayScale.isFinite, displayScale > 0 else { return }
        scaleReferenceView = nil
        guard abs(self.displayScale - displayScale) > 0.001 else { return }
        self.displayScale = displayScale
        updateCanvasGeometry()
    }

    func configure(in coordinateView: UIView, pdfScaleFactor: CGFloat) {
        scaleReferenceView = coordinateView
        pdfViewScaleFactor = pdfScaleFactor
        if let pdfView = coordinateView as? PDFView,
           pdfView.scaleFactorForSizeToFit.isFinite,
           pdfView.scaleFactorForSizeToFit > 0 {
            fitScaleFactor = pdfView.scaleFactorForSizeToFit
        }
        let measured = measuredDisplayScale()
        if measured.isFinite, measured > 0 { displayScale = measured }
        updateCanvasGeometry()
    }

    private func measuredDisplayScale() -> CGFloat {
        guard let coordinateView = scaleReferenceView, bounds.width > 0, bounds.height > 0 else {
            return displayScale
        }
        let origin = convert(bounds.origin, to: coordinateView)
        let horizontal = convert(CGPoint(x: bounds.maxX, y: bounds.minY), to: coordinateView)
        let vertical = convert(CGPoint(x: bounds.minX, y: bounds.maxY), to: coordinateView)
        return JotCanvasRenderGeometry.displayRatio(
            pageSize: bounds.size,
            displayedWidthVector: CGVector(dx: horizontal.x - origin.x, dy: horizontal.y - origin.y),
            displayedHeightVector: CGVector(dx: vertical.x - origin.x, dy: vertical.y - origin.y),
            pdfViewScaleFactor: pdfViewScaleFactor
        )
    }

    /// Preserve picker widths in PDF page points when the renderer uses the
    /// larger, normalized drawing coordinate space.
    func toolInDrawingCoordinates(_ tool: any PKTool) -> any PKTool {
        guard bounds.width > 0 else { return tool }
        let scale = drawingSize.width / bounds.width
        if var ink = tool as? PKInkingTool {
            let supportedWidths = ink.inkType.validWidthRange
            ink.width = min(max(ink.width * scale, supportedWidths.lowerBound), supportedWidths.upperBound)
            return ink
        }
        if var eraser = tool as? PKEraserTool {
            eraser.width *= scale
            return eraser
        }
        return tool
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateCanvasGeometry()
    }

    private func updateCanvasGeometry() {
        guard let geometry = JotCanvasRenderGeometry(
            pageSize: bounds.size,
            drawingSize: drawingSize,
            displayScale: measuredDisplayScale(),
            screenScale: window?.screen.nativeScale ?? traitCollection.displayScale
        ) else { return }
        let requestedZoom = geometry.canvasZoom
        let nativeZoom = min(requestedZoom, max(canvas.maximumZoomScale, canvas.minimumZoomScale))
        let viewportSize = CGSize(
            width: drawingSize.width * nativeZoom,
            height: drawingSize.height * nativeZoom
        )
        let pageToViewport = CGAffineTransform(
            scaleX: bounds.width / max(viewportSize.width, 1),
            y: bounds.height / max(viewportSize.height, 1)
        )
        let renderScale = geometry.screenScale * max(1, requestedZoom / max(nativeZoom, 0.01))
        let scaledContentSize = viewportSize
#if DEBUG
        let experimentMode = Self.geometryExperimentMode
        let setsContentSize = experimentMode.setsContentSize
        let resetsContentOffset = experimentMode.resetsContentOffset
        let experimentChanged = experimentMode != appliedExperimentMode
#else
        let setsContentSize = true
        let resetsContentOffset = true
#endif
        var geometryAlreadyApplied = geometry == appliedGeometry
#if DEBUG
        geometryAlreadyApplied = geometryAlreadyApplied && !experimentChanged
#endif
        geometryAlreadyApplied = geometryAlreadyApplied
            && canvas.bounds.size == viewportSize
            && abs(canvas.zoomScale - nativeZoom) <= 0.0001
            && (!setsContentSize || canvas.contentSize == scaledContentSize)
            && (!resetsContentOffset || canvas.contentOffset == .zero)
            && viewportHost.bounds.size == viewportSize
            && viewportHost.transform == pageToViewport
            && abs(canvas.contentScaleFactor - renderScale) <= 0.0001
        guard !geometryAlreadyApplied else { return }
        let isNewGeometry = geometry != appliedGeometry
        appliedGeometry = geometry
#if DEBUG
        appliedExperimentMode = experimentMode
#endif
        if abs(canvas.contentScaleFactor - renderScale) > 0.0001 {
            canvas.contentScaleFactor = renderScale
            canvas.layer.contentsScale = renderScale
        }
        let nextBounds = CGRect(origin: .zero, size: viewportSize)
        if viewportHost.bounds != nextBounds { viewportHost.bounds = nextBounds }
        let nextCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        if viewportHost.center != nextCenter { viewportHost.center = nextCenter }
        if viewportHost.transform != pageToViewport { viewportHost.transform = pageToViewport }
        // Keep the PKCanvasView itself untransformed. Its frame and bounds
        // must both describe the real display viewport used by its tiler.
        if canvas.frame != nextBounds { canvas.frame = nextBounds }
        if canvas.minimumZoomScale != min(0.01, nativeZoom) { canvas.minimumZoomScale = min(0.01, nativeZoom) }
        // Establish the target content extent before applying the zoom. PKCanvasView
        // may recalculate its own zoom state when its content size changes.
        if setsContentSize, canvas.contentSize != scaledContentSize { canvas.contentSize = scaledContentSize }
        if abs(canvas.zoomScale - nativeZoom) > 0.0001 {
            canvas.setZoomScale(nativeZoom, animated: false)
        }
        if resetsContentOffset, canvas.contentOffset != .zero { canvas.contentOffset = .zero }
        recordGeometryMilestoneIfNeeded(
            requestedZoom: requestedZoom,
            nativeZoom: nativeZoom,
            renderScale: renderScale,
            viewportTransform: pageToViewport
        )
        #if DEBUG
        if isNewGeometry {
            let details: [String: Any] = [
                "requestedCanvasZoom": requestedZoom,
                "nativeCanvasZoom": nativeZoom,
                "nativeZoomMaximum": canvas.maximumZoomScale,
                "pdfScaleFactor": pdfViewScaleFactor,
                "measuredDisplayScale": measuredDisplayScale(),
                "canvasBounds": [canvas.bounds.width, canvas.bounds.height],
                "contentSize": [canvas.contentSize.width, canvas.contentSize.height],
                "contentOffset": [canvas.contentOffset.x, canvas.contentOffset.y],
                "viewportTransform": [pageToViewport.a, pageToViewport.d],
                "overlayBounds": [bounds.width, bounds.height]
            ]
            JottreDiagnostics.shared.record("zoom.geometryUpdated", details: details)
            if abs(requestedZoom - nativeZoom) > 0.0001 {
                JottreDiagnostics.shared.record("zoom.geometryMismatch", details: details)
            }
        }
        #endif
        // Setting a UIScrollView zoom range can lazily create or re-enable its
        // pinch recognizer. Disable it after all native zoom configuration so
        // PDFView remains the only owner of the user's document pinch gesture.
        disableCanvasPinchGestures(in: canvas)
    }

    private func recordGeometryMilestoneIfNeeded(
        requestedZoom: CGFloat,
        nativeZoom: CGFloat,
        renderScale: CGFloat,
        viewportTransform: CGAffineTransform
    ) {
        let bucket = Int(floor(log2(max(displayScale, 0.01))))
        guard bucket != lastMemorySampleZoomBucket else { return }
        lastMemorySampleZoomBucket = bucket
        let details: [String: Any] = [
            "pageIndex": diagnosticsPageIndex as Any? ?? NSNull(),
            "pageRotation": diagnosticsPageRotation,
            "cropBox": [diagnosticsCropBox.minX, diagnosticsCropBox.minY,
                        diagnosticsCropBox.width, diagnosticsCropBox.height],
            "pageDimensions": [bounds.width, bounds.height],
            "pdfScaleFactor": pdfViewScaleFactor,
            "fitScaleFactor": fitScaleFactor,
            "relativeZoom": pdfViewScaleFactor / max(fitScaleFactor, 0.01),
            "measuredDisplayScale": displayScale,
            "screenScale": window?.screen.nativeScale ?? traitCollection.displayScale,
            "requestedCanvasZoom": requestedZoom,
            "canvasZoomScale": canvas.zoomScale,
            "nativeZoomMaximum": canvas.maximumZoomScale,
            "renderScale": renderScale,
            "canvasContentScaleFactor": canvas.contentScaleFactor,
            "contentSize": [canvas.contentSize.width, canvas.contentSize.height],
            "canvasBounds": [canvas.bounds.width, canvas.bounds.height],
            "contentOffset": [canvas.contentOffset.x, canvas.contentOffset.y],
            "viewportTransform": [viewportTransform.a, viewportTransform.d],
            "strokeCount": canvas.drawing.strokes.count,
            "zoomBucket": bucket
        ]
        JottreDiagnostics.shared.updateCanvasMemoryContext(details)
        JottreDiagnostics.shared.record("canvas.geometryUpdated", details: details)
        JottreDiagnostics.shared.sampleMemoryNow(for: "canvas.memorySample", details: details)
    }

    private func disableCanvasPinchGestures(in view: UIView) {
        for recognizer in view.gestureRecognizers ?? [] where recognizer is UIPinchGestureRecognizer {
            recognizer.isEnabled = false
        }
        for child in view.subviews {
            disableCanvasPinchGestures(in: child)
        }
    }
}

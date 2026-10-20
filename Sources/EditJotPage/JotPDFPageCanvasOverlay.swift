@preconcurrency import PencilKit
import UIKit

enum JotPDFPageRestorationPolicy {
    static func targetIndex(pendingIndex: Int?, currentIndex: Int?, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        return min(max(0, pendingIndex ?? currentIndex ?? 0), pageCount - 1)
    }
}

/// PDFKit transforms this page container. PencilKit owns the zoom inside it,
/// so its stroke renderer sees the actual magnification instead of presenting
/// a magnified canvas texture. The inverse viewport transform cancels PDFKit's
/// outer magnification without changing the drawing's page coordinates.
@MainActor
final class JotPDFPageCanvasOverlay: UIView {
    let canvas: PKCanvasView
    private let viewportHost = UIView()
    private(set) var drawingSize: CGSize
    private(set) var displayScale: CGFloat = 1
    private var appliedGeometry: JotCanvasRenderGeometry?
    private weak var scaleReferenceView: UIView?
    private var pdfViewScaleFactor: CGFloat = 1

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
        guard
            let geometry = JotCanvasRenderGeometry(
                pageSize: bounds.size,
                drawingSize: drawingSize,
                displayScale: measuredDisplayScale(),
                screenScale: window?.screen.nativeScale ?? traitCollection.displayScale
            ),
            geometry != appliedGeometry
        else { return }
        appliedGeometry = geometry
        let viewportSize = geometry.viewportSize
        let nativeZoom = geometry.canvasZoom
        if canvas.contentScaleFactor != geometry.screenScale {
            canvas.contentScaleFactor = geometry.screenScale
            canvas.layer.contentsScale = geometry.screenScale
        }
        let nextBounds = CGRect(origin: .zero, size: viewportSize)
        if viewportHost.bounds != nextBounds { viewportHost.bounds = nextBounds }
        let nextCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        if viewportHost.center != nextCenter { viewportHost.center = nextCenter }
        let inverseScale = geometry.inversePageScale
        if viewportHost.transform != inverseScale { viewportHost.transform = inverseScale }
        // Keep the PKCanvasView itself untransformed. Its frame and bounds
        // must both describe the real display viewport used by its tiler.
        if canvas.frame != nextBounds { canvas.frame = nextBounds }
        if canvas.minimumZoomScale != min(0.01, nativeZoom) { canvas.minimumZoomScale = min(0.01, nativeZoom) }
        if canvas.maximumZoomScale != max(8, nativeZoom) { canvas.maximumZoomScale = max(8, nativeZoom) }
        if abs(canvas.zoomScale - nativeZoom) > 0.0001 {
            canvas.setZoomScale(nativeZoom, animated: false)
        }
        // PencilKit updates contentSize itself when its internal zoom changes.
        let scaledContentSize = CGSize(
            width: drawingSize.width * nativeZoom,
            height: drawingSize.height * nativeZoom
        )
        if canvas.contentSize != scaledContentSize { canvas.contentSize = scaledContentSize }
        if canvas.contentOffset != .zero { canvas.contentOffset = .zero }
        // Setting a UIScrollView zoom range can lazily create or re-enable its
        // pinch recognizer. Disable it after all native zoom configuration so
        // PDFView remains the only owner of the user's document pinch gesture.
        disableCanvasPinchGestures(in: canvas)
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

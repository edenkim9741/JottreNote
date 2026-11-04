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
    case optimized
    case manualContentSizeOnly
    case manualContentOffsetOnly
    case manualContentSizeAndOffset
    case boundedViewport

    var setsContentSize: Bool {
        self == .manualContentSizeOnly || self == .manualContentSizeAndOffset
    }

    var resetsContentOffset: Bool {
        self == .manualContentOffsetOnly || self == .manualContentSizeAndOffset
    }
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
#if DEBUG
    private(set) var diagnosticsActiveCanvasCount = 0
    private(set) var diagnosticsActiveOverlayCount = 0
#endif
    private var appliedGeometry: JotCanvasRenderGeometry?
    private var lastMemorySampleZoomBucket: Int?
#if DEBUG
    static var geometryExperimentMode: JotCanvasGeometryExperimentMode = .optimized
    private var appliedExperimentMode: JotCanvasGeometryExperimentMode = .optimized
    private var isPencilHoverActive = false
    private var hoverBaselineGeometry: [String: Any]?
    private var hoverLayoutCount = 0
    private var hoverGeometryUpdateCount = 0
    private var hoverGeometryReapplyCount = 0
    private var hoverZoomSetCount = 0
    private var hoverContentSizeSetCount = 0
    private var hoverContentOffsetSetCount = 0
    private var hoverContentScaleSetCount = 0
    private var hoverMoveCount = 0
    private var hoverSessionID = UUID()
#endif
    private weak var scaleReferenceView: UIView?
    private(set) var pdfViewScaleFactor: CGFloat = 1
    private(set) var fitScaleFactor: CGFloat = 1
    var viewportHostTransform: CGAffineTransform { viewportHost.transform }
    var viewportHostBounds: CGRect { viewportHost.bounds }

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
#if DEBUG
        let hoverRecognizer = UIHoverGestureRecognizer(target: self, action: #selector(handlePencilHover(_:)))
        hoverRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hoverRecognizer.cancelsTouchesInView = false
        hoverRecognizer.delaysTouchesBegan = false
        hoverRecognizer.delaysTouchesEnded = false
        addGestureRecognizer(hoverRecognizer)
#endif
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

#if DEBUG
    func setDiagnosticsActiveCounts(canvases: Int, overlays: Int) {
        diagnosticsActiveCanvasCount = max(0, canvases)
        diagnosticsActiveOverlayCount = max(0, overlays)
    }
#endif

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
#if DEBUG
        if isPencilHoverActive { hoverLayoutCount += 1 }
#endif
        updateCanvasGeometry()
    }

    private func updateCanvasGeometry() {
#if DEBUG
        if isPencilHoverActive { hoverGeometryUpdateCount += 1 }
#endif
        guard let geometry = JotCanvasRenderGeometry(
            pageSize: bounds.size,
            drawingSize: drawingSize,
            displayScale: measuredDisplayScale(),
            screenScale: window?.screen.nativeScale ?? traitCollection.displayScale
        ) else { return }
        let requestedZoom = geometry.canvasZoom
        let useBoundedViewport: Bool
#if DEBUG
        // Compare a logical-page-sized canvas while preserving the same
        // Drawing-to-page transform and effective render scale.
        useBoundedViewport = Self.geometryExperimentMode == .boundedViewport
#else
        useBoundedViewport = false
#endif
        let nativeZoom = useBoundedViewport
            ? 1
            : min(requestedZoom, max(canvas.maximumZoomScale, canvas.minimumZoomScale))
        let viewportSize = useBoundedViewport
            ? drawingSize
            : CGSize(
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
        let setsContentSize = !useBoundedViewport && experimentMode.setsContentSize
        let resetsContentOffset = !useBoundedViewport && experimentMode.resetsContentOffset
        let experimentChanged = experimentMode != appliedExperimentMode
#else
        let setsContentSize = false
        let resetsContentOffset = false
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
#if DEBUG
        if isPencilHoverActive { hoverGeometryReapplyCount += 1 }
#endif
        let isNewGeometry = geometry != appliedGeometry
        appliedGeometry = geometry
#if DEBUG
        appliedExperimentMode = experimentMode
#endif
        if abs(canvas.contentScaleFactor - renderScale) > 0.0001 {
#if DEBUG
            if isPencilHoverActive { hoverContentScaleSetCount += 1 }
#endif
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
        if setsContentSize, canvas.contentSize != scaledContentSize {
#if DEBUG
            if isPencilHoverActive { hoverContentSizeSetCount += 1 }
#endif
            canvas.contentSize = scaledContentSize
        }
        if abs(canvas.zoomScale - nativeZoom) > 0.0001 {
#if DEBUG
            if isPencilHoverActive { hoverZoomSetCount += 1 }
#endif
            canvas.setZoomScale(nativeZoom, animated: false)
        }
        if resetsContentOffset, canvas.contentOffset != .zero {
#if DEBUG
            if isPencilHoverActive { hoverContentOffsetSetCount += 1 }
#endif
            canvas.contentOffset = .zero
        }
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

#if DEBUG
    @objc private func handlePencilHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began:
            isPencilHoverActive = true
            hoverSessionID = UUID()
            hoverLayoutCount = 0
            hoverGeometryUpdateCount = 0
            hoverGeometryReapplyCount = 0
            hoverZoomSetCount = 0
            hoverContentSizeSetCount = 0
            hoverContentOffsetSetCount = 0
            hoverContentScaleSetCount = 0
            hoverMoveCount = 0
            hoverBaselineGeometry = hoverGeometrySnapshot()
            var details = hoverBaselineGeometry ?? [:]
            details["hoverSessionID"] = hoverSessionID.uuidString
            details["recognizer"] = String(describing: type(of: recognizer))
            details["observationPhase"] = "UIHoverGestureRecognizer.began"
            details["preEventGuarantee"] = false
            JottreDiagnostics.shared.record("pencil.hover.entered", details: details)
            JottreDiagnostics.shared.record("canvas.geometry.atHoverBegin", details: details)
            JottreDiagnostics.shared.sampleMemoryNow(for: "canvas.memorySample", details: details)
        case .changed:
            hoverMoveCount += 1
            if hoverMoveCount == 1 {
                JottreDiagnostics.shared.record("pencil.hover.moved", details: [
                    "hoverSessionID": hoverSessionID.uuidString,
                    "pageIndex": diagnosticsPageIndex as Any? ?? NSNull()
                ])
            }
        case .ended, .cancelled, .failed:
            let session = hoverSessionID
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.finishPencilHover(sessionID: session, recognizerState: recognizer.state.rawValue)
            }
        default:
            break
        }
    }

    private func finishPencilHover(sessionID: UUID, recognizerState: Int) {
        guard isPencilHoverActive, sessionID == hoverSessionID else { return }
        isPencilHoverActive = false
        let before = hoverBaselineGeometry ?? [:]
        var after = hoverGeometrySnapshot()
        after["hoverSessionID"] = sessionID.uuidString
        after["recognizerState"] = recognizerState
        after["observationPhase"] = "after UIHoverGestureRecognizer terminal state and next main-actor yield"
        after["hoverMoveCount"] = hoverMoveCount
        after["layoutTriggeredCount"] = hoverLayoutCount
        after["geometryUpdateCount"] = hoverGeometryUpdateCount
        after["geometryReappliedCount"] = hoverGeometryReapplyCount
        after["zoomSetCount"] = hoverZoomSetCount
        after["contentSizeSetCount"] = hoverContentSizeSetCount
        after["contentOffsetSetCount"] = hoverContentOffsetSetCount
        after["contentScaleSetCount"] = hoverContentScaleSetCount

        let geometryKeys = [
            "pdfScaleFactor", "measuredDisplayScale", "requestedCanvasZoom", "canvasZoomScale",
            "canvasMinimumZoom", "canvasMaximumZoom", "canvasBounds", "canvasFrame", "canvasTransform",
            "canvasContentSize", "canvasContentOffset", "canvasContentInset", "canvasAdjustedContentInset",
            "canvasContentScaleFactor", "canvasLayerContentsScale", "overlayBounds", "overlayFrame",
            "overlayTransform", "viewportHostBounds", "viewportHostFrame", "viewportHostTransform"
        ]
        let inkKeys = [
            "strokeCount", "pointCount", "drawingBounds", "firstStrokeSeed", "lastStrokeSeed",
            "strokeStructureFingerprint"
        ]
        let undoKeys = ["undoManagerIdentity", "canUndo", "canRedo"]
        let changedGeometryKeys = changedKeys(geometryKeys, before: before, after: after)
        let changedInkKeys = changedKeys(inkKeys, before: before, after: after)
        let changedUndoKeys = changedKeys(undoKeys, before: before, after: after)
        let beforeScaleErrorX = abs((before["drawingToOverlayScaleErrorX"] as? CGFloat) ?? 0)
        let beforeScaleErrorY = abs((before["drawingToOverlayScaleErrorY"] as? CGFloat) ?? 0)
        let afterScaleErrorX = abs((after["drawingToOverlayScaleErrorX"] as? CGFloat) ?? 0)
        let afterScaleErrorY = abs((after["drawingToOverlayScaleErrorY"] as? CGFloat) ?? 0)
        let scaleMappingChanged = abs(afterScaleErrorX - beforeScaleErrorX) > 0.0001
            || abs(afterScaleErrorY - beforeScaleErrorY) > 0.0001
            || afterScaleErrorX > 0.001
            || afterScaleErrorY > 0.001
        after["changedGeometryKeys"] = changedGeometryKeys
        after["changedInkKeys"] = changedInkKeys
        after["changedUndoKeys"] = changedUndoKeys
        JottreDiagnostics.shared.record("pencil.hover.exited", details: after)
        JottreDiagnostics.shared.record("canvas.geometry.afterHover", details: after)
        if !changedGeometryKeys.isEmpty {
            JottreDiagnostics.shared.record("canvas.zoomStateChanged", details: [
                "hoverSessionID": sessionID.uuidString,
                "changedGeometryKeys": changedGeometryKeys
            ])
        }
        if changedGeometryKeys.contains("canvasContentOffset") {
            JottreDiagnostics.shared.record("canvas.contentOffsetChanged", details: [
                "hoverSessionID": sessionID.uuidString,
                "before": before["canvasContentOffset"] ?? NSNull(),
                "after": after["canvasContentOffset"] ?? NSNull()
            ])
        }
        if hoverLayoutCount > 0 {
            JottreDiagnostics.shared.record("canvas.layoutTriggered", details: [
                "hoverSessionID": sessionID.uuidString,
                "count": hoverLayoutCount
            ])
        }
        if hoverGeometryReapplyCount > 0 {
            JottreDiagnostics.shared.record("canvas.geometryReapplied", details: [
                "hoverSessionID": sessionID.uuidString,
                "count": hoverGeometryReapplyCount,
                "zoomSetCount": hoverZoomSetCount,
                "contentOffsetSetCount": hoverContentOffsetSetCount
            ])
        }
        JottreDiagnostics.shared.record("canvas.inkAlignmentCheck", details: [
            "hoverSessionID": sessionID.uuidString,
            "coordinateModelOnly": true,
            "beforeDrawingToOverlayScaleError": [beforeScaleErrorX, beforeScaleErrorY],
            "afterDrawingToOverlayScaleError": [afterScaleErrorX, afterScaleErrorY],
            "drawingDataChanged": !changedInkKeys.isEmpty
        ])
        if scaleMappingChanged {
            JottreDiagnostics.shared.record("canvas.inkAlignmentChanged", details: [
                "hoverSessionID": sessionID.uuidString,
                "coordinateModelOnly": true,
                "changedGeometryKeys": changedGeometryKeys,
                "beforeDrawingToOverlayScaleError": [beforeScaleErrorX, beforeScaleErrorY],
                "afterDrawingToOverlayScaleError": [afterScaleErrorX, afterScaleErrorY]
            ])
        }
        if !changedInkKeys.isEmpty {
            JottreDiagnostics.shared.record("canvas.drawingStateChangedDuringHover", details: [
                "hoverSessionID": sessionID.uuidString,
                "changedInkKeys": changedInkKeys
            ])
        }
        JottreDiagnostics.shared.sampleMemoryNow(for: "canvas.memorySample", details: after)
        hoverBaselineGeometry = nil
    }

    private func hoverGeometrySnapshot() -> [String: Any] {
        let drawing = canvas.drawing
        let pointCount = drawing.strokes.reduce(0) { $0 + $1.path.count }
        var strokeStructureFingerprint: UInt64 = 14_695_981_039_346_656_037
        func mix(_ value: UInt64) {
            strokeStructureFingerprint = (strokeStructureFingerprint ^ value) &* 1_099_511_628_211
        }
        for stroke in drawing.strokes {
            mix(UInt64(stroke.randomSeed))
            mix(UInt64(stroke.path.count))
            mix(Double(stroke.transform.a).bitPattern)
            mix(Double(stroke.transform.b).bitPattern)
            mix(Double(stroke.transform.c).bitPattern)
            mix(Double(stroke.transform.d).bitPattern)
            mix(Double(stroke.transform.tx).bitPattern)
            mix(Double(stroke.transform.ty).bitPattern)
            mix(Double(stroke.renderBounds.minX).bitPattern)
            mix(Double(stroke.renderBounds.minY).bitPattern)
            mix(Double(stroke.renderBounds.width).bitPattern)
            mix(Double(stroke.renderBounds.height).bitPattern)
            if let first = stroke.path.first {
                mix(Double(first.location.x).bitPattern)
                mix(Double(first.location.y).bitPattern)
            }
            if let last = stroke.path.last {
                mix(Double(last.location.x).bitPattern)
                mix(Double(last.location.y).bitPattern)
            }
        }
        let canvasTransform = canvas.transform
        let overlayTransform = transform
        let hostTransform = viewportHost.transform
        let requestedZoom = drawingSize.width > 0
            ? bounds.width * displayScale / drawingSize.width
            : 0
        let expectedDrawingToOverlayScaleX = drawingSize.width > 0 ? bounds.width / drawingSize.width : 0
        let expectedDrawingToOverlayScaleY = drawingSize.height > 0 ? bounds.height / drawingSize.height : 0
        let composedDrawingToOverlayScaleX = canvas.zoomScale * hostTransform.a
        let composedDrawingToOverlayScaleY = canvas.zoomScale * hostTransform.d
        let visiblePageRect: CGRect
        if let scaleReferenceView {
            let pageInReference = convert(bounds, to: scaleReferenceView)
            let visibleInReference = pageInReference.intersection(scaleReferenceView.bounds)
            visiblePageRect = visibleInReference.isNull || visibleInReference.isEmpty
                ? .zero
                : convert(visibleInReference, from: scaleReferenceView).intersection(bounds)
        } else {
            visiblePageRect = bounds
        }
        let convertedVisibleCanvasRect = canvas.convert(visiblePageRect, from: self).intersection(canvas.bounds)
        let visibleRectComponents = [
            convertedVisibleCanvasRect.minX, convertedVisibleCanvasRect.minY,
            convertedVisibleCanvasRect.width, convertedVisibleCanvasRect.height
        ]
        let visibleCanvasRect = visibleRectComponents.allSatisfy(\.isFinite)
            && !convertedVisibleCanvasRect.isNull
            ? convertedVisibleCanvasRect
            : .zero
        let canvasArea = max(canvas.bounds.width * canvas.bounds.height, 1)
        let rawVisibleCanvasAreaRatio = max(0, visibleCanvasRect.width * visibleCanvasRect.height) / canvasArea
        let visibleCanvasAreaRatio = rawVisibleCanvasAreaRatio.isFinite ? rawVisibleCanvasAreaRatio : 0
        var pdfPageCornerPoints: [[CGFloat]] = []
        if let pdfView = scaleReferenceView as? PDFView,
           let pageIndex = diagnosticsPageIndex,
           let page = pdfView.document?.page(at: pageIndex) {
            let overlayPoints = [
                CGPoint.zero,
                CGPoint(x: bounds.maxX, y: 0),
                CGPoint(x: 0, y: bounds.maxY),
                CGPoint(x: bounds.maxX, y: bounds.maxY)
            ]
            pdfPageCornerPoints = overlayPoints.map { overlayPoint in
                let pdfViewPoint = convert(overlayPoint, to: pdfView)
                let pagePoint = pdfView.convert(pdfViewPoint, to: page)
                return [pagePoint.x, pagePoint.y]
            }
        }
        return [
            "pageIndex": diagnosticsPageIndex as Any? ?? NSNull(),
            "pageRotation": diagnosticsPageRotation,
            "cropBox": [diagnosticsCropBox.minX, diagnosticsCropBox.minY,
                        diagnosticsCropBox.width, diagnosticsCropBox.height],
            "pdfScaleFactor": pdfViewScaleFactor,
            "fitScaleFactor": fitScaleFactor,
            "relativeZoom": pdfViewScaleFactor / max(fitScaleFactor, 0.01),
            "measuredDisplayScale": displayScale,
            "requestedCanvasZoom": requestedZoom,
            "expectedDrawingToOverlayScale": [expectedDrawingToOverlayScaleX, expectedDrawingToOverlayScaleY],
            "composedDrawingToOverlayScale": [composedDrawingToOverlayScaleX, composedDrawingToOverlayScaleY],
            "drawingToOverlayScaleErrorX": composedDrawingToOverlayScaleX - expectedDrawingToOverlayScaleX,
            "drawingToOverlayScaleErrorY": composedDrawingToOverlayScaleY - expectedDrawingToOverlayScaleY,
            "canvasZoomScale": canvas.zoomScale,
            "canvasMinimumZoom": canvas.minimumZoomScale,
            "canvasMaximumZoom": canvas.maximumZoomScale,
            "canvasBounds": [canvas.bounds.width, canvas.bounds.height],
            "canvasFrame": [canvas.frame.minX, canvas.frame.minY, canvas.frame.width, canvas.frame.height],
            "canvasTransform": [canvasTransform.a, canvasTransform.b, canvasTransform.c,
                                canvasTransform.d, canvasTransform.tx, canvasTransform.ty],
            "canvasContentSize": [canvas.contentSize.width, canvas.contentSize.height],
            "canvasContentOffset": [canvas.contentOffset.x, canvas.contentOffset.y],
            "canvasContentInset": [canvas.contentInset.top, canvas.contentInset.left,
                                   canvas.contentInset.bottom, canvas.contentInset.right],
            "canvasAdjustedContentInset": [canvas.adjustedContentInset.top, canvas.adjustedContentInset.left,
                                           canvas.adjustedContentInset.bottom, canvas.adjustedContentInset.right],
            "canvasContentScaleFactor": canvas.contentScaleFactor,
            "canvasLayerContentsScale": canvas.layer.contentsScale,
            "overlayBounds": [bounds.width, bounds.height],
            "overlayFrame": [frame.minX, frame.minY, frame.width, frame.height],
            "overlayTransform": [overlayTransform.a, overlayTransform.b, overlayTransform.c,
                                 overlayTransform.d, overlayTransform.tx, overlayTransform.ty],
            "viewportHostBounds": [viewportHost.bounds.width, viewportHost.bounds.height],
            "viewportHostFrame": [viewportHost.frame.minX, viewportHost.frame.minY,
                                  viewportHost.frame.width, viewportHost.frame.height],
            "viewportHostTransform": [hostTransform.a, hostTransform.b, hostTransform.c,
                                      hostTransform.d, hostTransform.tx, hostTransform.ty],
            "visibleCanvasRect": [visibleCanvasRect.minX, visibleCanvasRect.minY,
                                  visibleCanvasRect.width, visibleCanvasRect.height],
            "visibleCanvasAreaRatio": visibleCanvasAreaRatio,
            "pdfPageCornerPoints": pdfPageCornerPoints,
            "strokeCount": drawing.strokes.count,
            "pointCount": pointCount,
            "drawingBounds": [drawing.bounds.minX, drawing.bounds.minY,
                              drawing.bounds.width, drawing.bounds.height],
            "strokeStructureFingerprint": strokeStructureFingerprint,
            "firstStrokeSeed": drawing.strokes.first?.randomSeed as Any? ?? NSNull(),
            "lastStrokeSeed": drawing.strokes.last?.randomSeed as Any? ?? NSNull(),
            "undoManagerIdentity": canvas.undoManager.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
            "canUndo": canvas.undoManager?.canUndo ?? false,
            "canRedo": canvas.undoManager?.canRedo ?? false,
            "activeCanvasCount": diagnosticsActiveCanvasCount,
            "activeOverlayCount": diagnosticsActiveOverlayCount,
            "physicalFootprintBytes": JottreDiagnostics.currentFootprintBytesForTesting() ?? 0
        ]
    }

    private func changedKeys(_ keys: [String], before: [String: Any], after: [String: Any]) -> [String] {
        keys.filter { key in
            String(reflecting: before[key]) != String(reflecting: after[key])
        }
    }
#endif

    private func recordGeometryMilestoneIfNeeded(
        requestedZoom: CGFloat,
        nativeZoom: CGFloat,
        renderScale: CGFloat,
        viewportTransform: CGAffineTransform
    ) {
        let bucket = Int(floor(log2(max(displayScale, 0.01))))
        guard bucket != lastMemorySampleZoomBucket else { return }
        lastMemorySampleZoomBucket = bucket
        let visiblePageRect: CGRect
        if let scaleReferenceView {
            let pageRectInReference = convert(bounds, to: scaleReferenceView)
            let visibleRectInReference = pageRectInReference.intersection(scaleReferenceView.bounds)
            visiblePageRect = visibleRectInReference.isNull || visibleRectInReference.isEmpty
                ? .zero
                : convert(visibleRectInReference, from: scaleReferenceView).intersection(bounds)
        } else {
            visiblePageRect = bounds
        }
        let convertedVisibleCanvasRect = canvas.convert(visiblePageRect, from: self).intersection(canvas.bounds)
        let visibleRectComponents = [
            convertedVisibleCanvasRect.minX, convertedVisibleCanvasRect.minY,
            convertedVisibleCanvasRect.width, convertedVisibleCanvasRect.height
        ]
        let visibleCanvasRect = visibleRectComponents.allSatisfy(\.isFinite)
            && !convertedVisibleCanvasRect.isNull
            ? convertedVisibleCanvasRect
            : .zero
        let canvasArea = max(canvas.bounds.width * canvas.bounds.height, 1)
        let rawVisibleCanvasAreaRatio = max(0, visibleCanvasRect.width * visibleCanvasRect.height) / canvasArea
        let visibleCanvasAreaRatio = rawVisibleCanvasAreaRatio.isFinite ? rawVisibleCanvasAreaRatio : 0
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
            "canvasFrame": [canvas.frame.minX, canvas.frame.minY, canvas.frame.width, canvas.frame.height],
            "viewportHostBounds": [viewportHost.bounds.width, viewportHost.bounds.height],
            "contentOffset": [canvas.contentOffset.x, canvas.contentOffset.y],
            "viewportTransform": [viewportTransform.a, viewportTransform.d],
            "visibleCanvasRect": [visibleCanvasRect.minX, visibleCanvasRect.minY,
                                  visibleCanvasRect.width, visibleCanvasRect.height],
            "visibleCanvasAreaRatio": visibleCanvasAreaRatio,
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

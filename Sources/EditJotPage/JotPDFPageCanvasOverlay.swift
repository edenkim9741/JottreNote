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
@MainActor
enum JotCanvasGeometryDiagnosticSequence {
    private static var value: UInt64 = 0

    static func next() -> UInt64 {
        value &+= 1
        return value
    }
}
#endif

/// PDFKit owns document zoom. The canvas retains the complete page drawing as
/// scrollable content while its frame covers only the currently visible page
/// viewport. PencilKit's native zoom keeps that viewport sharp at display scale.
@MainActor
final class JotPDFPageCanvasOverlay: UIView {
    // The native zoom is bounded independently from PDFKit's scale. The
    // canvas frame below covers only the visible page viewport, never the full
    // page multiplied by this value.
    private static let maximumNativeCanvasZoom: CGFloat = 64
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
    private var appliedDrawingContentSize: CGSize?
    private var lastMemorySampleZoomBucket: Int?
#if DEBUG
    private var canvasGeometryObservations: [NSKeyValueObservation] = []
    private var pdfGeometryObservations: [NSKeyValueObservation] = []
    private weak var observedPDFScrollView: UIScrollView?
    private var isPDFZoomDiagnosticActive = false
    private var geometryObservationEventCount = 0
    private var didLogObservationLimit = false
    private var didLogFirstHoverGeometryChange = false
    private var didLogUnchangedGeometryDuringHover = false
    private var lastLoggedCoordinateError: Double?
    private var didLogInvalidDrawingBounds = false
    private var lastLassoDrawingState: (boundsState: String, strokeCount: Int)?
    private var lastHoverPoint: CGPoint?
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
        canvas.maximumZoomScale = Self.maximumNativeCanvasZoom
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

    func beginGeometryDiagnosticTracking() {
        installGeometryDiagnosticObservations()
        recordGeometryDiagnostic("pdf.pageDisplayed", includeCoordinateProbes: true)
    }

    func endGeometryDiagnosticTracking() {
        canvasGeometryObservations.forEach { $0.invalidate() }
        pdfGeometryObservations.forEach { $0.invalidate() }
        canvasGeometryObservations.removeAll(keepingCapacity: false)
        pdfGeometryObservations.removeAll(keepingCapacity: false)
        observedPDFScrollView = nil
        isPDFZoomDiagnosticActive = false
    }

    func recordPDFGeometryDiagnostic(_ eventName: String) {
        if eventName == "pdf.zoom.started" {
            isPDFZoomDiagnosticActive = true
            geometryObservationEventCount = 0
            didLogObservationLimit = false
        }
        recordGeometryDiagnostic(
            eventName,
            includeCoordinateProbes: eventName == "pdf.zoom.completed" || eventName == "pdf.geometry.stable"
        )
        if eventName == "pdf.geometry.stable" { isPDFZoomDiagnosticActive = false }
    }

    func recordGeometryDiagnostic(
        _ eventName: String,
        includeCoordinateProbes: Bool = false,
        extra: [String: Any] = [:]
    ) {
        var details = geometryDiagnosticSnapshot(includeCoordinateProbes: includeCoordinateProbes)
        details.merge(extra) { _, new in new }
        details["eventName"] = eventName
        details["timestamp"] = Date().timeIntervalSince1970
        details["sequence"] = JotCanvasGeometryDiagnosticSequence.next()
        JottreDiagnostics.shared.record(eventName, details: details)
        let boundsState = details["canvasDrawingBoundsState"] as? String ?? "unknown"
        let strokeCount = details["drawingStrokeCount"] as? Int ?? 0
        if strokeCount > 0, boundsState != "finite" {
            if !didLogInvalidDrawingBounds {
                didLogInvalidDrawingBounds = true
                JottreDiagnostics.shared.record("canvas.drawingBounds.invalid", details: [
                    "sourceEvent": eventName,
                    "boundsState": boundsState,
                    "strokeCount": strokeCount,
                    "canvasDrawingBounds": details["canvasDrawingBounds"] ?? NSNull()
                ])
            }
        } else {
            didLogInvalidDrawingBounds = false
        }
        guard includeCoordinateProbes,
              let probes = details["coordinateProbes"] as? [[String: Any]] else { return }
        let maximumError = probes.compactMap { $0["errorDistance"] as? Double }
            .filter(\.isFinite).max() ?? 0
        if maximumError > 0.5,
           lastLoggedCoordinateError.map({ abs($0 - maximumError) > 0.1 }) ?? true
        {
            lastLoggedCoordinateError = maximumError
            recordGeometryDiagnostic("inkAlignmentErrorDetected", extra: [
                "maximumCoordinateModelError": maximumError,
                "errorThresholdPDFViewPoints": 0.5,
                "comparedEvent": eventName
            ])
        }
    }

    func recordLassoDrawingStateIfChanged() {
        let drawing = canvas.drawing
        let sample = (Self.drawingBoundsState(drawing.bounds), drawing.strokes.count)
        guard lastLassoDrawingState?.boundsState != sample.0
                || lastLassoDrawingState?.strokeCount != sample.1 else { return }
        lastLassoDrawingState = sample
        recordGeometryDiagnostic("lasso.drawingStateChanged", extra: [
            "canvasDrawingBounds": Self.diagnosticDrawingBounds(drawing.bounds),
            "canvasDrawingBoundsState": sample.0,
            "drawingStrokeCount": sample.1
        ])
    }

    private func installGeometryDiagnosticObservations() {
        guard canvasGeometryObservations.isEmpty else { return }
        observeGeometry(on: canvas, prefix: "canvas", into: &canvasGeometryObservations)
        observeGeometry(on: viewportHost, prefix: "viewportHost", into: &canvasGeometryObservations)
        observeGeometry(on: self, prefix: "overlay", into: &canvasGeometryObservations)
        installPDFScrollViewObservationsIfNeeded()
    }

    private func installPDFScrollViewObservationsIfNeeded() {
        guard let pdfView = scaleReferenceView as? PDFView,
              let documentView = pdfView.documentView else { return }
        var ancestor = documentView.superview
        var scrollView: UIScrollView?
        while let view = ancestor {
            if let candidate = view as? UIScrollView {
                scrollView = candidate
                break
            }
            ancestor = view.superview
        }
        guard let scrollView, observedPDFScrollView !== scrollView else { return }
        pdfGeometryObservations.forEach { $0.invalidate() }
        pdfGeometryObservations.removeAll(keepingCapacity: true)
        observedPDFScrollView = scrollView
        observeGeometry(on: scrollView, prefix: "pdfScroll", into: &pdfGeometryObservations)
    }

    private func observeGeometry(
        on view: UIView,
        prefix: String,
        into observations: inout [NSKeyValueObservation]
    ) {
        if let scrollView = view as? UIScrollView {
            observations.append(scrollView.observe(\.contentOffset, options: [.old, .new]) { [weak self] _, change in
                guard let old = change.oldValue, let new = change.newValue, old != new else { return }
                MainActor.assumeIsolated {
                    self?.recordObservedGeometryChange("\(prefix).offsetChanged", property: "contentOffset",
                        old: [Double(old.x), Double(old.y)], new: [Double(new.x), Double(new.y)])
                }
            })
            observations.append(scrollView.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
                guard let old = change.oldValue, let new = change.newValue, old != new else { return }
                MainActor.assumeIsolated {
                    self?.recordObservedGeometryChange("\(prefix).contentSizeChanged", property: "contentSize",
                        old: [Double(old.width), Double(old.height)], new: [Double(new.width), Double(new.height)])
                }
            })
            observations.append(scrollView.observe(\.zoomScale, options: [.old, .new]) { [weak self] _, change in
                guard let old = change.oldValue, let new = change.newValue, old != new else { return }
                MainActor.assumeIsolated {
                    self?.recordObservedGeometryChange("\(prefix).zoomChanged", property: "zoomScale",
                        old: [Double(old)], new: [Double(new)])
                }
            })
        }
        observations.append(view.observe(\.bounds, options: [.old, .new]) { [weak self] _, change in
            guard let old = change.oldValue, let new = change.newValue, old != new else { return }
            MainActor.assumeIsolated {
                self?.recordObservedGeometryChange("\(prefix).boundsChanged", property: "bounds",
                    old: Self.rectComponents(old), new: Self.rectComponents(new))
            }
        })
        observations.append(view.observe(\.frame, options: [.old, .new]) { [weak self] _, change in
            guard let old = change.oldValue, let new = change.newValue, old != new else { return }
            MainActor.assumeIsolated {
                self?.recordObservedGeometryChange("\(prefix).frameChanged", property: "frame",
                    old: Self.rectComponents(old), new: Self.rectComponents(new))
            }
        })
        observations.append(view.observe(\.transform, options: [.old, .new]) { [weak self] _, change in
            guard let old = change.oldValue, let new = change.newValue, old != new else { return }
            MainActor.assumeIsolated {
                self?.recordObservedGeometryChange("\(prefix).transformChanged", property: "transform",
                    old: Self.transformComponents(old), new: Self.transformComponents(new))
            }
        })
    }

    private func recordObservedGeometryChange(
        _ eventName: String,
        property: String,
        old: [Double],
        new: [Double]
    ) {
        guard isPencilHoverActive || isPDFZoomDiagnosticActive else { return }
        guard geometryObservationEventCount < 128 else {
            if !didLogObservationLimit {
                didLogObservationLimit = true
                recordGeometryDiagnostic("geometry.observationLimitReached", extra: ["limit": 128])
            }
            return
        }
        geometryObservationEventCount += 1
        recordGeometryDiagnostic(eventName, extra: ["property": property, "oldValue": old, "newValue": new])
        guard isPencilHoverActive else { return }
        if !didLogFirstHoverGeometryChange {
            didLogFirstHoverGeometryChange = true
            recordGeometryDiagnostic("hover.geometryChanged.first", includeCoordinateProbes: true, extra: [
                "sourceEvent": eventName, "property": property, "oldValue": old, "newValue": new
            ])
        }
        recordGeometryDiagnostic("hover.geometryChanged", extra: [
            "sourceEvent": eventName, "property": property, "oldValue": old, "newValue": new
        ])
    }

    private static func rectComponents(_ rect: CGRect) -> [Double] {
        [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
    }

    private static func transformComponents(_ transform: CGAffineTransform) -> [Double] {
        [Double(transform.a), Double(transform.b), Double(transform.c), Double(transform.d),
         Double(transform.tx), Double(transform.ty)]
    }

    private static func drawingBoundsState(_ bounds: CGRect) -> String {
        if bounds.isNull { return "null" }
        if bounds.isInfinite { return "infinite" }
        let components = [bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height,
                          bounds.maxX, bounds.maxY]
        guard components.allSatisfy(\.isFinite) else { return "nonFinite" }
        return bounds.isEmpty ? "empty" : "finite"
    }

    private static func diagnosticDrawingBounds(_ bounds: CGRect) -> Any {
        let state = drawingBoundsState(bounds)
        guard state == "finite" || state == "empty" else { return NSNull() }
        return rectComponents(bounds)
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
        // Keep the full PKDrawing in logical page coordinates. Size the actual
        // canvas to the visible portion of the page, expressed in PencilKit's
        // zoomed content coordinates. This keeps its drawable viewport near
        // the device viewport instead of scaling the whole page into a huge
        // layer at high PDF zoom.
        let requestedZoom = geometry.canvasZoom
        guard let nativeZoom = geometry.effectiveCanvasZoom(maximumZoomScale: canvas.maximumZoomScale) else { return }
        let visiblePageRect = visibleOverlayRect()
        guard !visiblePageRect.isNull, !visiblePageRect.isEmpty else { return }
        let viewportSize = geometry.viewportSize(for: visiblePageRect, nativeZoom: nativeZoom)
        guard viewportSize.width.isFinite, viewportSize.height.isFinite,
              viewportSize.width > 0, viewportSize.height > 0 else { return }
        let contentOffset = geometry.contentOffset(for: visiblePageRect, nativeZoom: nativeZoom)
        let pageToViewport = geometry.viewportHostTransform(nativeZoom: nativeZoom)
        let hostCenter = CGPoint(x: visiblePageRect.midX, y: visiblePageRect.midY)
        let geometryAlreadyApplied = appliedGeometry != nil
            && appliedDrawingContentSize == drawingSize
            && canvas.bounds.size == viewportSize
            && canvas.frame == CGRect(origin: .zero, size: viewportSize)
            && abs(canvas.zoomScale - nativeZoom) <= 0.0001
            && abs(canvas.contentOffset.x - contentOffset.x) <= 0.05
            && abs(canvas.contentOffset.y - contentOffset.y) <= 0.05
            && viewportHost.bounds.size == viewportSize
            && viewportHost.center == hostCenter
            && viewportHost.transform == pageToViewport
        if geometryAlreadyApplied {
#if DEBUG
            if isPencilHoverActive, !didLogUnchangedGeometryDuringHover {
                didLogUnchangedGeometryDuringHover = true
                recordGeometryDiagnostic("geometry.skippedUnchanged")
            }
#endif
            return
        }
#if DEBUG
        if isPencilHoverActive { hoverGeometryReapplyCount += 1 }
        recordGeometryDiagnostic("geometry.beforeApply")
#endif
        appliedGeometry = geometry
        if appliedDrawingContentSize != drawingSize {
#if DEBUG
            let oldContentSize = canvas.contentSize
#endif
            canvas.contentSize = drawingSize
            appliedDrawingContentSize = drawingSize
#if DEBUG
            recordGeometryDiagnostic("canvas.contentSizeChanged", extra: [
                "source": "updateCanvasGeometry",
                "oldValue": [Double(oldContentSize.width), Double(oldContentSize.height)],
                "newValue": [Double(canvas.contentSize.width), Double(canvas.contentSize.height)]
            ])
#endif
        }
        let nextBounds = CGRect(origin: .zero, size: viewportSize)
        if viewportHost.bounds != nextBounds { viewportHost.bounds = nextBounds }
        if viewportHost.center != hostCenter { viewportHost.center = hostCenter }
        if viewportHost.transform != pageToViewport {
#if DEBUG
            let oldTransform = viewportHost.transform
#endif
            viewportHost.transform = pageToViewport
#if DEBUG
            recordGeometryDiagnostic("viewport.transformChanged", extra: [
                "source": "updateCanvasGeometry",
                "oldValue": Self.transformComponents(oldTransform),
                "newValue": Self.transformComponents(viewportHost.transform)
            ])
#endif
        }
        if canvas.frame != nextBounds { canvas.frame = nextBounds }
        let minimumZoom = min(0.01, nativeZoom)
        if canvas.minimumZoomScale != minimumZoom { canvas.minimumZoomScale = minimumZoom }
        if abs(canvas.zoomScale - nativeZoom) > 0.0001 {
#if DEBUG
            let oldZoom = canvas.zoomScale
            if isPencilHoverActive { hoverZoomSetCount += 1 }
#endif
            canvas.setZoomScale(nativeZoom, animated: false)
#if DEBUG
            recordGeometryDiagnostic("canvas.zoomChanged", extra: [
                "source": "updateCanvasGeometry", "oldValue": oldZoom, "newValue": canvas.zoomScale
            ])
#endif
        }
        if abs(canvas.contentOffset.x - contentOffset.x) > 0.05
            || abs(canvas.contentOffset.y - contentOffset.y) > 0.05
        {
#if DEBUG
            let oldOffset = canvas.contentOffset
#endif
            canvas.setContentOffset(contentOffset, animated: false)
#if DEBUG
            recordGeometryDiagnostic("canvas.offsetChanged", extra: [
                "source": "updateCanvasGeometry",
                "oldValue": [Double(oldOffset.x), Double(oldOffset.y)],
                "newValue": [Double(canvas.contentOffset.x), Double(canvas.contentOffset.y)]
            ])
#endif
        }
        recordGeometryMilestoneIfNeeded(
            requestedZoom: geometry.canvasZoom,
            nativeZoom: nativeZoom,
            renderScale: geometry.screenScale,
            viewportTransform: pageToViewport
        )
        #if DEBUG
        if appliedGeometry == geometry {
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
        }
        recordGeometryDiagnostic("geometry.afterApply", includeCoordinateProbes: true)
        #endif
        // PDFView remains the only owner of the user's document pinch gesture.
        disableCanvasPinchGestures(in: canvas)
    }

    private func visibleOverlayRect() -> CGRect {
        guard let scaleReferenceView, bounds.width > 0, bounds.height > 0 else { return bounds }
        let pageInReference = convert(bounds, to: scaleReferenceView)
        let visibleInReference = pageInReference.intersection(scaleReferenceView.bounds)
        guard !visibleInReference.isNull, !visibleInReference.isEmpty else { return .zero }
        let visible = convert(visibleInReference, from: scaleReferenceView).intersection(bounds)
        return visible.isNull || visible.isEmpty ? .zero : visible
    }

#if DEBUG
    @objc private func handlePencilHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began:
            isPencilHoverActive = true
            lastHoverPoint = recognizer.location(in: self)
            didLogFirstHoverGeometryChange = false
            didLogUnchangedGeometryDuringHover = false
            lastLoggedCoordinateError = nil
            geometryObservationEventCount = 0
            didLogObservationLimit = false
            hoverSessionID = UUID()
            hoverLayoutCount = 0
            hoverGeometryUpdateCount = 0
            hoverGeometryReapplyCount = 0
            hoverZoomSetCount = 0
            hoverContentSizeSetCount = 0
            hoverContentOffsetSetCount = 0
            hoverContentScaleSetCount = 0
            hoverMoveCount = 0
            var baseline = hoverGeometrySnapshot()
            baseline["coordinateProbes"] = coordinateAlignmentProbes()
            baseline["coordinateProbeRenderingNote"] = "coordinate model only; does not measure PencilKit rendered pixels"
            hoverBaselineGeometry = baseline
            var details = hoverBaselineGeometry ?? [:]
            details["hoverSessionID"] = hoverSessionID.uuidString
            details["recognizer"] = String(describing: type(of: recognizer))
            details["observationPhase"] = "UIHoverGestureRecognizer.began"
            details["preEventGuarantee"] = false
            details["eventName"] = "hover.entered"
            details["timestamp"] = Date().timeIntervalSince1970
            details["sequence"] = JotCanvasGeometryDiagnosticSequence.next()
            details["coordinateProbes"] = coordinateAlignmentProbes()
            JottreDiagnostics.shared.record("pencil.hover.entered", details: details)
            JottreDiagnostics.shared.record("canvas.geometry.atHoverBegin", details: details)
            JottreDiagnostics.shared.sampleMemoryNow(for: "canvas.memorySample", details: details)
        case .changed:
            lastHoverPoint = recognizer.location(in: self)
            hoverMoveCount += 1
            if hoverMoveCount == 1 {
                var details = geometryDiagnosticSnapshot(includeCoordinateProbes: false)
                details["sequence"] = JotCanvasGeometryDiagnosticSequence.next()
                details["timestamp"] = Date().timeIntervalSince1970
                details["eventName"] = "hover.moved.first"
                details["hoverSessionID"] = hoverSessionID.uuidString
                details["pageIndex"] = diagnosticsPageIndex as Any? ?? NSNull()
                JottreDiagnostics.shared.record("pencil.hover.moved", details: details.merging([
                    "hoverSessionID": hoverSessionID.uuidString,
                    "pageIndex": diagnosticsPageIndex as Any? ?? NSNull()
                ]) { _, new in new })
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
        after["eventName"] = "hover.exited"
        after["timestamp"] = Date().timeIntervalSince1970
        after["sequence"] = JotCanvasGeometryDiagnosticSequence.next()
        after["coordinateProbes"] = coordinateAlignmentProbes()
        let beforeCoordinateError = maximumCoordinateError(before["coordinateProbes"])
        let afterCoordinateError = maximumCoordinateError(after["coordinateProbes"])
        after["maximumCoordinateErrorBeforeHover"] = beforeCoordinateError as Any? ?? NSNull()
        after["maximumCoordinateErrorAfterHover"] = afterCoordinateError as Any? ?? NSNull()
        after["hoverMoveCount"] = hoverMoveCount
        after["layoutTriggeredCount"] = hoverLayoutCount
        after["geometryUpdateCount"] = hoverGeometryUpdateCount
        after["geometryReappliedCount"] = hoverGeometryReapplyCount
        after["zoomSetCount"] = hoverZoomSetCount
        after["contentSizeSetCount"] = hoverContentSizeSetCount
        after["contentOffsetSetCount"] = hoverContentOffsetSetCount
        after["contentScaleSetCount"] = hoverContentScaleSetCount

        let geometryKeys = [
            "pageRotation", "cropBox",
            "pdfScaleFactor", "measuredDisplayScale", "requestedCanvasZoom", "canvasZoomScale",
            "canvasMinimumZoom", "canvasMaximumZoom", "canvasBounds", "canvasFrame", "canvasTransform",
            "canvasContentSize", "canvasContentOffset", "canvasContentInset", "canvasAdjustedContentInset",
            "canvasContentScaleFactor", "canvasLayerContentsScale", "canvasLayerAffineTransform",
            "overlayBounds", "overlayFrame", "overlayTransform", "pdfViewBounds", "pdfScrollViewIdentity",
            "pdfScrollViewContentOffset", "pdfScrollViewContentSize", "pdfScrollViewBounds",
            "viewportHostBounds", "viewportHostFrame", "viewportHostTransform", "overlayIdentity",
            "canvasIdentity", "viewportHostIdentity", "pageIdentity"
        ]
        let inkKeys = [
            "strokeCount", "pointCount", "drawingBounds", "firstStrokeSeed", "lastStrokeSeed",
            "strokeStructureFingerprint", "drawingContentIdentity"
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
        after["candidateFailureClass"] = candidateFailureClass(
            geometryKeys: changedGeometryKeys,
            inkKeys: changedInkKeys
        )
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
        var details: [String: Any] = [
            "pageIndex": diagnosticsPageIndex as Any? ?? NSNull(),
            "pageRotation": diagnosticsPageRotation,
            "cropBox": [diagnosticsCropBox.minX, diagnosticsCropBox.minY,
                        diagnosticsCropBox.width, diagnosticsCropBox.height],
            "pdfScaleFactor": (scaleReferenceView as? PDFView)?.scaleFactor ?? pdfViewScaleFactor,
            "configuredPDFScaleFactor": pdfViewScaleFactor,
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
            "canvasLayerAffineTransform": Self.transformComponents(canvas.layer.affineTransform()),
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
            "overlayIdentity": String(describing: ObjectIdentifier(self)),
            "canvasIdentity": String(describing: ObjectIdentifier(canvas)),
            "viewportHostIdentity": String(describing: ObjectIdentifier(viewportHost)),
            "pageIdentity": pageIdentity,
            "pdfViewBounds": (scaleReferenceView.map { Self.rectComponents($0.bounds) } ?? []),
            "pdfScrollViewIdentity": pdfDocumentScrollView().map { String(describing: ObjectIdentifier($0)) } ?? "nil",
            "pdfScrollViewContentOffset": pdfDocumentScrollView().map { [Double($0.contentOffset.x), Double($0.contentOffset.y)] } ?? [],
            "pdfScrollViewContentSize": pdfDocumentScrollView().map { [Double($0.contentSize.width), Double($0.contentSize.height)] } ?? [],
            "pdfScrollViewBounds": pdfDocumentScrollView().map { Self.rectComponents($0.bounds) } ?? [],
            "pdfScrollViewAdjustedContentInset": pdfDocumentScrollView().map {
                let inset = $0.adjustedContentInset
                return [Double(inset.top), Double(inset.left), Double(inset.bottom), Double(inset.right)]
            } ?? [],
            "strokeCount": drawing.strokes.count,
            "pointCount": pointCount,
            "drawingBounds": Self.diagnosticDrawingBounds(drawing.bounds),
            "drawingBoundsState": Self.drawingBoundsState(drawing.bounds),
            "strokeStructureFingerprint": strokeStructureFingerprint,
            "drawingContentIdentity": strokeStructureFingerprint,
            "drawingContentIdentityCoverage": "stroke seeds, path counts, transforms, render bounds, first and last path points; not a full byte-for-byte drawing hash",
            "firstStrokeSeed": drawing.strokes.first?.randomSeed as Any? ?? NSNull(),
            "lastStrokeSeed": drawing.strokes.last?.randomSeed as Any? ?? NSNull(),
            "undoManagerIdentity": canvas.undoManager.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
            "canUndo": canvas.undoManager?.canUndo ?? false,
            "canRedo": canvas.undoManager?.canRedo ?? false,
            "activeCanvasCount": diagnosticsActiveCanvasCount,
            "activeOverlayCount": diagnosticsActiveOverlayCount,
            "physicalFootprintBytes": JottreDiagnostics.currentFootprintBytesForTesting() ?? 0
        ]
        details["canvasDrawingBounds"] = Self.diagnosticDrawingBounds(drawing.bounds)
        details["canvasDrawingBoundsState"] = Self.drawingBoundsState(drawing.bounds)
        return details
    }

    private func changedKeys(_ keys: [String], before: [String: Any], after: [String: Any]) -> [String] {
        keys.filter { key in
            String(reflecting: before[key]) != String(reflecting: after[key])
        }
    }

    private func geometryDiagnosticSnapshot(includeCoordinateProbes: Bool) -> [String: Any] {
        let drawing = canvas.drawing
        let pdfScrollView = pdfDocumentScrollView()
        let canvasLayerTransform = canvas.layer.affineTransform()
        var details: [String: Any] = [
            "pageIndex": diagnosticsPageIndex as Any? ?? NSNull(),
            "pageRotation": diagnosticsPageRotation,
            "pdfCropBox": Self.rectComponents(diagnosticsCropBox),
            "pdfViewScaleFactor": pdfViewScaleFactor,
            "pdfScaleFactor": (scaleReferenceView as? PDFView)?.scaleFactor ?? pdfViewScaleFactor,
            "fitScaleFactor": fitScaleFactor,
            "pdfViewBounds": scaleReferenceView.map { Self.rectComponents($0.bounds) } ?? [],
            "pdfScrollViewIdentity": pdfScrollView.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
            "pdfScrollViewContentOffset": pdfScrollView.map { [Double($0.contentOffset.x), Double($0.contentOffset.y)] } ?? [],
            "pdfScrollViewContentSize": pdfScrollView.map { [Double($0.contentSize.width), Double($0.contentSize.height)] } ?? [],
            "pdfScrollViewBounds": pdfScrollView.map { Self.rectComponents($0.bounds) } ?? [],
            "pdfScrollViewAdjustedContentInset": pdfScrollView.map {
                let inset = $0.adjustedContentInset
                return [Double(inset.top), Double(inset.left), Double(inset.bottom), Double(inset.right)]
            } ?? [],
            "canvasFrame": Self.rectComponents(canvas.frame),
            "canvasBounds": Self.rectComponents(canvas.bounds),
            "canvasViewTransform": Self.transformComponents(canvas.transform),
            "canvasZoomScale": canvas.zoomScale,
            "canvasMinimumZoomScale": canvas.minimumZoomScale,
            "canvasMaximumZoomScale": canvas.maximumZoomScale,
            "canvasContentOffset": [Double(canvas.contentOffset.x), Double(canvas.contentOffset.y)],
            "canvasContentSize": [Double(canvas.contentSize.width), Double(canvas.contentSize.height)],
            "canvasAdjustedContentInset": {
                let inset = canvas.adjustedContentInset
                return [Double(inset.top), Double(inset.left), Double(inset.bottom), Double(inset.right)]
            }(),
            "canvasContentInset": {
                let inset = canvas.contentInset
                return [Double(inset.top), Double(inset.left), Double(inset.bottom), Double(inset.right)]
            }(),
            "canvasContentScaleFactor": canvas.contentScaleFactor,
            "canvasLayerContentsScale": canvas.layer.contentsScale,
            "canvasLayerAffineTransform": Self.transformComponents(canvasLayerTransform),
            "viewportHostFrame": Self.rectComponents(viewportHost.frame),
            "viewportHostBounds": Self.rectComponents(viewportHost.bounds),
            "viewportHostTransform": Self.transformComponents(viewportHost.transform),
            "overlayFrame": Self.rectComponents(frame),
            "overlayBounds": Self.rectComponents(bounds),
            "overlayTransform": Self.transformComponents(transform),
            "canvasDrawingBounds": Self.diagnosticDrawingBounds(drawing.bounds),
            "canvasDrawingBoundsState": Self.drawingBoundsState(drawing.bounds),
            "drawingStrokeCount": drawing.strokes.count,
            "overlayIdentity": String(describing: ObjectIdentifier(self)),
            "canvasIdentity": String(describing: ObjectIdentifier(canvas)),
            "viewportHostIdentity": String(describing: ObjectIdentifier(viewportHost)),
            "pageIdentity": pageIdentity
        ]
        if isPencilHoverActive, let lastHoverPoint {
            details["hoverPointOverlay"] = [Double(lastHoverPoint.x), Double(lastHoverPoint.y)]
            if let pdfView = scaleReferenceView {
                let pdfPoint = convert(lastHoverPoint, to: pdfView)
                details["hoverPointPDFView"] = [Double(pdfPoint.x), Double(pdfPoint.y)]
            }
        }
        if includeCoordinateProbes {
            details["coordinateProbes"] = coordinateAlignmentProbes()
            details["coordinateProbeRenderingNote"] = "coordinate model only; does not measure PencilKit rendered pixels"
        }
        return details
    }

    private var pageIdentity: String {
        guard let pdfView = scaleReferenceView as? PDFView,
              let pageIndex = diagnosticsPageIndex,
              let page = pdfView.document?.page(at: pageIndex) else { return "nil" }
        return String(describing: ObjectIdentifier(page))
    }

    private func pdfDocumentScrollView() -> UIScrollView? {
        guard let pdfView = scaleReferenceView as? PDFView,
              let documentView = pdfView.documentView else { return nil }
        var ancestor = documentView.superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView { return scrollView }
            ancestor = view.superview
        }
        return nil
    }

    private func coordinateAlignmentProbes() -> [[String: Any]] {
        guard let pdfView = scaleReferenceView as? PDFView,
              let pageIndex = diagnosticsPageIndex,
              let page = pdfView.document?.page(at: pageIndex),
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0,
              drawingSize.width.isFinite, drawingSize.height.isFinite,
              drawingSize.width > 0, drawingSize.height > 0,
              canvas.zoomScale.isFinite, canvas.zoomScale > 0 else { return [] }
        let visible = visibleOverlayRect()
        guard !visible.isNull, !visible.isEmpty else { return [] }
        let points: [(String, CGPoint, CGPoint?)] = [
            ("visibleCenter", CGPoint(x: visible.midX, y: visible.midY), nil),
            ("visibleTopLeft", CGPoint(x: visible.minX, y: visible.minY), nil),
            ("visibleTopRight", CGPoint(x: visible.maxX, y: visible.minY), nil),
            ("visibleBottomLeft", CGPoint(x: visible.minX, y: visible.maxY), nil),
            ("visibleBottomRight", CGPoint(x: visible.maxX, y: visible.maxY), nil)
        ]
        var probes = points.compactMap { name, point, drawingPoint in
            coordinateAlignmentProbe(name: name, overlayPoint: point, drawingPoint: drawingPoint, page: page, pdfView: pdfView)
        }
        let drawingVisibleRect = CGRect(
            x: visible.minX * drawingSize.width / bounds.width,
            y: visible.minY * drawingSize.height / bounds.height,
            width: visible.width * drawingSize.width / bounds.width,
            height: visible.height * drawingSize.height / bounds.height
        )
        if let strokePoint = firstVisibleStrokePoint(in: canvas.drawing, visibleDrawingRect: drawingVisibleRect) {
            let overlayPoint = CGPoint(
                x: strokePoint.x * bounds.width / drawingSize.width,
                y: strokePoint.y * bounds.height / drawingSize.height
            )
            if let probe = coordinateAlignmentProbe(
                name: "existingStrokePoint",
                overlayPoint: overlayPoint,
                drawingPoint: strokePoint,
                page: page,
                pdfView: pdfView
            ) {
                probes.append(probe)
            }
        }
        return probes
    }

    private func coordinateAlignmentProbe(
        name: String,
        overlayPoint: CGPoint,
        drawingPoint suppliedDrawingPoint: CGPoint?,
        page: PDFPage,
        pdfView: PDFView
    ) -> [String: Any]? {
        let drawingPoint = suppliedDrawingPoint ?? CGPoint(
            x: overlayPoint.x * drawingSize.width / bounds.width,
            y: overlayPoint.y * drawingSize.height / bounds.height
        )
        guard [overlayPoint.x, overlayPoint.y, drawingPoint.x, drawingPoint.y].allSatisfy(\.isFinite) else { return nil }
        let expectedPDFViewPoint = convert(overlayPoint, to: pdfView)
        let pdfPagePoint = pdfView.convert(expectedPDFViewPoint, to: page)
        // UIScrollView's bounds origin already contains its content offset.
        // Pass the zoomed content point to UIView.convert so UIKit applies that
        // origin once; passing a pre-offset viewport point here subtracts it twice.
        let canvasContentPoint = CGPoint(
            x: drawingPoint.x * canvas.zoomScale,
            y: drawingPoint.y * canvas.zoomScale
        )
        let canvasViewportPoint = canvas.convert(canvasContentPoint, to: viewportHost)
        let canvasViewportPointFromOffset = CGPoint(
            x: canvasContentPoint.x - canvas.contentOffset.x,
            y: canvasContentPoint.y - canvas.contentOffset.y
        )
        let actualPointInPDFView = canvas.convert(canvasContentPoint, to: pdfView)
        let dx = actualPointInPDFView.x - expectedPDFViewPoint.x
        let dy = actualPointInPDFView.y - expectedPDFViewPoint.y
        return [
            "name": name,
            "pdfPagePoint": [pdfPagePoint.x, pdfPagePoint.y],
            "pdfViewExpectedPoint": [expectedPDFViewPoint.x, expectedPDFViewPoint.y],
            "drawingPoint": [drawingPoint.x, drawingPoint.y],
            "canvasContentPoint": [canvasContentPoint.x, canvasContentPoint.y],
            "canvasContentOffset": [canvas.contentOffset.x, canvas.contentOffset.y],
            "canvasViewportPoint": [canvasViewportPoint.x, canvasViewportPoint.y],
            "canvasViewportPointFromOffset": [canvasViewportPointFromOffset.x, canvasViewportPointFromOffset.y],
            "actualPointInPDFView": [actualPointInPDFView.x, actualPointInPDFView.y],
            "canvasPointConvertedToPDFView": [actualPointInPDFView.x, actualPointInPDFView.y],
            "deltaX": dx,
            "deltaY": dy,
            "errorDistance": hypot(dx, dy)
        ]
    }

    private func firstVisibleStrokePoint(in drawing: PKDrawing, visibleDrawingRect: CGRect) -> CGPoint? {
        for stroke in drawing.strokes {
            for point in [stroke.path.first, stroke.path.last].compactMap({ $0 }) {
                let location = point.location.applying(stroke.transform)
                if visibleDrawingRect.contains(location) { return location }
            }
        }
        return nil
    }

    private func maximumCoordinateError(_ value: Any?) -> Double? {
        guard let probes = value as? [[String: Any]] else { return nil }
        return probes.compactMap { $0["errorDistance"] as? Double }
            .filter(\.isFinite).max()
    }

    private func candidateFailureClass(geometryKeys: [String], inkKeys: [String]) -> String {
        if geometryKeys.contains(where: { ["overlayIdentity", "canvasIdentity", "viewportHostIdentity", "pageIdentity"].contains($0) }) {
            return "C_candidate_page_or_render_view_replaced"
        }
        if geometryKeys.contains(where: { $0 == "canvasContentOffset" || $0 == "canvasContentSize" }) {
            return "A_candidate_canvas_scroll_state_changed"
        }
        if geometryKeys.contains("canvasZoomScale") {
            return "B_candidate_native_zoom_changed"
        }
        if geometryKeys.contains(where: {
            $0.hasPrefix("viewportHost") || $0 == "overlayFrame" || $0 == "pdfScaleFactor"
                || $0.hasPrefix("pdfScrollView")
        }) {
            return "C_candidate_pdf_or_parent_geometry_changed"
        }
        if geometryKeys.isEmpty && inkKeys.isEmpty {
            return "D_candidate_geometry_and_sampled_drawing_unchanged_rendered_pixels_not_measured"
        }
        if geometryKeys.isEmpty && !inkKeys.isEmpty {
            return "E_candidate_drawing_state_changed"
        }
        return "unclassified_geometry_change"
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

import PDFKit
@preconcurrency import PencilKit
import UIKit

/// Applies PencilKit's native input policy to visible page overlays and keeps
/// direct-touch navigation on PDFKit's own scroll views.
@MainActor
final class JotEditorGestureCoordinator: NSObject, UIGestureRecognizerDelegate {
    private unowned let pdfView: JotPDFView
    private var isEditingEnabled = false
    private var selectedTool: any PKTool = PKInkingTool(.pen)
    private var isRulerActive = false
    private var activePageIndex: Int?
    private weak var activeCanvas: JotCanvasView?
    private(set) var undoDoubleTapRecognizer: UITapGestureRecognizer?
    private let observedPDFPans = NSHashTable<UIPanGestureRecognizer>.weakObjects()
#if DEBUG
    private let observedCanvasPans = NSHashTable<UIPanGestureRecognizer>.weakObjects()
#endif
    private let routedPDFPans = NSHashTable<UIPanGestureRecognizer>.weakObjects()
    private var isPDFScrollRoutingPending = false
#if DEBUG
    private var pdfPanStartOffsets: [ObjectIdentifier: CGPoint] = [:]
    private var pdfPanStartCanvasOffsets: [ObjectIdentifier: CGPoint] = [:]
    private var pdfPanSuccessLogged = Set<ObjectIdentifier>()
    private var lastLoggedPDFPanStates: [ObjectIdentifier: Int] = [:]
    private var lastLoggedCanvasPanStates: [ObjectIdentifier: Int] = [:]
#endif

    init(pdfView: JotPDFView) {
        self.pdfView = pdfView
        super.init()
    }

    func installUndoDoubleTapGesture(target: Any, action: Selector) {
        guard undoDoubleTapRecognizer == nil else { return }
        let recognizer = UITapGestureRecognizer(target: target, action: action)
        recognizer.numberOfTouchesRequired = 2
        recognizer.numberOfTapsRequired = 2
        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        pdfView.addGestureRecognizer(recognizer)
        undoDoubleTapRecognizer = recognizer
        updateUndoDoubleTapAvailability()
    }

    func removeUndoDoubleTapGesture() {
        if let undoDoubleTapRecognizer {
            pdfView.removeGestureRecognizer(undoDoubleTapRecognizer)
        }
        undoDoubleTapRecognizer = nil
    }

    func update(
        isEditing: Bool,
        tool: any PKTool,
        rulerActive: Bool,
        activePageIndex: Int?,
        overlays: [Int: JotPDFPageCanvasOverlay]
    ) {
        let editingStateChanged = isEditingEnabled != isEditing
        isEditingEnabled = isEditing
        selectedTool = tool
        if isEditing {
            isRulerActive = rulerActive
            if let activePageIndex { self.activePageIndex = activePageIndex }
        } else {
            isRulerActive = false
            self.activePageIndex = nil
        }
        updateUndoDoubleTapAvailability()
        if pdfView.isInMarkupMode != isEditing {
            pdfView.isInMarkupMode = isEditing
        }
        let suppressesEditActions = CanvasTouchRouting.suppressesStandardEditActions(
            isEditing: isEditing,
            tool: tool
        )
        pdfView.suppressesStandardEditActions = suppressesEditActions
        for (index, overlay) in overlays {
            guard let canvas = overlay.canvas as? JotCanvasView else { continue }
            configure(canvas, overlay: overlay, pageIndex: index)
        }
        activeCanvas = activePageIndex.flatMap { overlays[$0]?.canvas as? JotCanvasView }
        if editingStateChanged {
            applyPDFScrollRouting()
        } else {
            refreshPDFScrollRoutingIfNavigationViewChanged()
        }
    }

    private func applyPDFScrollRouting() {
        let pans = pdfNavigationScrollViews().map(\.panGestureRecognizer)
        let currentIdentities = Set(pans.map(ObjectIdentifier.init))
        let stalePans = routedPDFPans.allObjects.filter { !currentIdentities.contains(ObjectIdentifier($0)) }
        let allPans = pans + stalePans
        observePDFPanGestures(allPans)
        guard !allPans.contains(where: Self.isGestureActive) else {
            isPDFScrollRoutingPending = true
            return
        }
        isPDFScrollRoutingPending = false
#if DEBUG
        let oldStates = allPans.map { ($0, scrollPolicyState(for: $0)) }
#endif
        CanvasTouchRouting.apply(to: pans, pencilInputHasPriority: isEditingEnabled)
        CanvasTouchRouting.apply(to: stalePans, pencilInputHasPriority: false)
        stalePans.forEach { routedPDFPans.remove($0) }
        pans.forEach { routedPDFPans.add($0) }
#if DEBUG
        for (pan, oldState) in oldStates {
            let newState = scrollPolicyState(for: pan)
            guard !NSDictionary(dictionary: oldState).isEqual(to: newState) else { continue }
            recordScrollDiagnostic("gesture.scrollPolicyChanged", pan: pan, extra: [
                "oldPolicy": oldState,
                "newPolicy": newState
            ])
        }
#endif
    }

    private func observePDFPanGestures(_ pans: [UIPanGestureRecognizer]) {
        for pan in pans where !observedPDFPans.contains(pan) {
            observedPDFPans.add(pan)
            pan.addTarget(self, action: #selector(pdfPanStateChanged(_:)))
#if DEBUG
            lastLoggedPDFPanStates[ObjectIdentifier(pan)] = pan.state.rawValue
#endif
        }
    }

    private static func isGestureActive(_ pan: UIPanGestureRecognizer) -> Bool {
        pan.state == .began || pan.state == .changed
    }

#if DEBUG
    private func observeCanvasPan(_ canvas: JotCanvasView) {
        let pan = canvas.panGestureRecognizer
        guard !observedCanvasPans.contains(pan) else { return }
        observedCanvasPans.add(pan)
        pan.addTarget(self, action: #selector(canvasPanStateChanged(_:)))
        lastLoggedCanvasPanStates[ObjectIdentifier(pan)] = pan.state.rawValue
    }
#endif

    @objc private func pdfPanStateChanged(_ pan: UIPanGestureRecognizer) {
#if DEBUG
        guard let scrollView = pan.view as? UIScrollView else { return }
        let key = ObjectIdentifier(pan)
        let previousState = lastLoggedPDFPanStates[key]
        let didChangeState = previousState != pan.state.rawValue
        if didChangeState { lastLoggedPDFPanStates[key] = pan.state.rawValue }
        if didChangeState, pan.state == .began {
            recordScrollDiagnostic("pdf.scrollAttempted", pan: pan, extra: [
                "previousPanState": Self.stateName(previousState),
                "currentPanState": Self.stateName(pan.state.rawValue)
            ])
        } else if didChangeState, pan.state == .changed {
            recordScrollDiagnostic("gesture.pdfPanStateChanged", pan: pan, extra: [
                "previousPanState": Self.stateName(previousState),
                "currentPanState": Self.stateName(pan.state.rawValue)
            ])
        }
        switch pan.state {
        case .began:
            pdfPanStartOffsets[key] = scrollView.contentOffset
            pdfPanStartCanvasOffsets[key] = activeCanvas?.contentOffset
            pdfPanSuccessLogged.remove(key)
        case .changed:
            guard !pdfPanSuccessLogged.contains(key),
                  let start = pdfPanStartOffsets[key],
                  hypot(scrollView.contentOffset.x - start.x, scrollView.contentOffset.y - start.y) > 0.5
            else { return }
            pdfPanSuccessLogged.insert(key)
            recordScrollDiagnostic("pdf.scrollSucceeded", pan: pan, extra: ["observedDuring": "changed"])
        case .ended, .cancelled, .failed:
            if !pdfPanSuccessLogged.contains(key),
               let start = pdfPanStartOffsets[key],
               hypot(scrollView.contentOffset.x - start.x, scrollView.contentOffset.y - start.y) > 0.5
            {
                pdfPanSuccessLogged.insert(key)
                recordScrollDiagnostic("pdf.scrollSucceeded", pan: pan, extra: ["observedDuring": "terminal"])
            }
            let terminalEvent: String
            switch pan.state {
            case .cancelled: terminalEvent = "pdf.scrollPanCancelled"
            case .failed: terminalEvent = "pdf.scrollPanFailed"
            default: terminalEvent = "pdf.scrollPanEnded"
            }
            recordScrollDiagnostic(terminalEvent, pan: pan, extra: [
                "previousPanState": Self.stateName(previousState),
                "currentPanState": Self.stateName(pan.state.rawValue),
                "startContentOffset": pdfPanStartOffsets[key].map { [Double($0.x), Double($0.y)] } ?? [],
                "finalContentOffset": [Double(scrollView.contentOffset.x), Double(scrollView.contentOffset.y)],
                "offsetChanged": pdfPanSuccessLogged.contains(key),
                "startCanvasContentOffset": pdfPanStartCanvasOffsets[key].map { [Double($0.x), Double($0.y)] } ?? [],
                "finalCanvasContentOffset": activeCanvas.map { [Double($0.contentOffset.x), Double($0.contentOffset.y)] } ?? [],
                "canvasOffsetChanged": pdfPanStartCanvasOffsets[key].map {
                    guard let activeCanvas else { return false }
                    return hypot(activeCanvas.contentOffset.x - $0.x, activeCanvas.contentOffset.y - $0.y) > 0.05
                } ?? false
            ])
            pdfPanStartOffsets.removeValue(forKey: key)
            pdfPanStartCanvasOffsets.removeValue(forKey: key)
            pdfPanSuccessLogged.remove(key)
        default:
            break
        }
#endif
        if !Self.isGestureActive(pan), isPDFScrollRoutingPending {
            isPDFScrollRoutingPending = false
            applyPDFScrollRouting()
        }
    }

#if DEBUG
    @objc private func canvasPanStateChanged(_ pan: UIPanGestureRecognizer) {
        let key = ObjectIdentifier(pan)
        let previousState = lastLoggedCanvasPanStates[key]
        guard previousState != pan.state.rawValue else { return }
        lastLoggedCanvasPanStates[key] = pan.state.rawValue
        let canvas = pan.view as? JotCanvasView
        let pdfPan = pdfNavigationScrollViews().first?.panGestureRecognizer
        JottreDiagnostics.shared.record("gesture.canvasPanStateChanged", details: [
            "eventSequence": JotCanvasGeometryDiagnosticSequence.next(),
            "eventTimestamp": Date().timeIntervalSince1970,
            "canvasPanIdentity": String(describing: ObjectIdentifier(pan)),
            "previousPanState": Self.stateName(previousState),
            "currentPanState": Self.stateName(pan.state.rawValue),
            "canvasPanEnabled": pan.isEnabled,
            "canvasPanAllowedTouchTypes": pan.allowedTouchTypes.map(\.intValue),
            "canvasPanMinimumTouches": pan.minimumNumberOfTouches,
            "canvasPanMaximumTouches": pan.maximumNumberOfTouches,
            "canvasScrollEnabled": canvas?.isScrollEnabled ?? false,
            "activeTool": canvas.map { $0.tool is PKLassoTool ? "lasso" : $0.tool is PKEraserTool ? "eraser" : "ink" } ?? "none",
            "pdfPanIdentity": pdfPan.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
            "pdfPanState": pdfPan.map { Self.stateName($0.state.rawValue) } ?? "unknown",
            "pdfScrollEnabled": (pdfPan?.view as? UIScrollView)?.isScrollEnabled ?? false,
            "pdfContentOffset": (pdfPan?.view as? UIScrollView).map { [Double($0.contentOffset.x), Double($0.contentOffset.y)] } ?? []
        ])
    }
#endif

#if DEBUG
    private func scrollPolicyState(for pan: UIPanGestureRecognizer) -> [String: Any] {
        [
            "enabled": pan.isEnabled,
            "minimumTouches": pan.minimumNumberOfTouches,
            "maximumTouches": pan.maximumNumberOfTouches,
            "allowedTouchTypes": pan.allowedTouchTypes.map(\.intValue)
        ]
    }

    private static func stateName(_ rawValue: Int?) -> String {
        guard let rawValue, let state = UIGestureRecognizer.State(rawValue: rawValue) else { return "unknown" }
        switch state {
        case .possible: return "possible"
        case .began: return "began"
        case .changed: return "changed"
        case .ended: return "ended"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        @unknown default: return "unknown(\(rawValue))"
        }
    }

    private func recordScrollDiagnostic(
        _ event: String,
        pan: UIPanGestureRecognizer,
        extra: [String: Any] = [:]
    ) {
        let scrollView = pan.view as? UIScrollView
        let canvasHost = activeCanvas?.superview
        let inset = scrollView?.adjustedContentInset ?? .zero
        let minimumPDFOffset = CGPoint(x: -inset.left, y: -inset.top)
        let maximumPDFOffset = CGPoint(
            x: max(minimumPDFOffset.x, (scrollView?.contentSize.width ?? 0) - (scrollView?.bounds.width ?? 0) + inset.right),
            y: max(minimumPDFOffset.y, (scrollView?.contentSize.height ?? 0) - (scrollView?.bounds.height ?? 0) + inset.bottom)
        )
        var details: [String: Any] = [
            "eventSequence": JotCanvasGeometryDiagnosticSequence.next(),
            "eventTimestamp": Date().timeIntervalSince1970,
            "activeTool": selectedTool is PKLassoTool ? "lasso" : selectedTool is PKEraserTool ? "eraser" : "ink",
            "isEditing": isEditingEnabled,
            "activePageIndex": activePageIndex as Any? ?? NSNull(),
            "pdfViewInteractionEnabled": pdfView.isUserInteractionEnabled,
            "pdfScrollViewIdentity": scrollView.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
            "pdfScrollEnabled": scrollView?.isScrollEnabled ?? false,
            "pdfPanIdentity": String(describing: ObjectIdentifier(pan)),
            "pdfPanEnabled": pan.isEnabled,
            "pdfPanState": pan.state.rawValue,
            "pdfPanStateName": Self.stateName(pan.state.rawValue),
            "pdfPinchIdentity": scrollView?.pinchGestureRecognizer.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
            "pdfPinchState": scrollView?.pinchGestureRecognizer.map { Self.stateName($0.state.rawValue) } ?? "unknown",
            "numberOfTouches": pan.numberOfTouches,
            "minimumTouches": pan.minimumNumberOfTouches,
            "maximumTouches": pan.maximumNumberOfTouches,
            "allowedTouchTypes": pan.allowedTouchTypes.map(\.intValue),
            "pdfContentOffset": scrollView.map { [Double($0.contentOffset.x), Double($0.contentOffset.y)] } ?? [],
            "pdfMinimumContentOffset": [Double(minimumPDFOffset.x), Double(minimumPDFOffset.y)],
            "pdfMaximumContentOffset": [Double(maximumPDFOffset.x), Double(maximumPDFOffset.y)],
            "canvasInteractionEnabled": activeCanvas?.isUserInteractionEnabled ?? false,
            "canvasScrollEnabled": activeCanvas?.isScrollEnabled ?? false,
            "canvasPanEnabled": activeCanvas?.panGestureRecognizer.isEnabled ?? false,
            "canvasPanState": activeCanvas?.panGestureRecognizer.state.rawValue ?? -1,
            "canvasPanStateName": activeCanvas.map { Self.stateName($0.panGestureRecognizer.state.rawValue) } ?? "unknown",
            "canvasPanIdentity": activeCanvas.map { String(describing: ObjectIdentifier($0.panGestureRecognizer)) } ?? "nil",
            "canvasZoomScale": activeCanvas?.zoomScale ?? 0,
            "canvasBounds": activeCanvas.map { [Double($0.bounds.width), Double($0.bounds.height)] } ?? [],
            "canvasContentSize": activeCanvas.map { [Double($0.contentSize.width), Double($0.contentSize.height)] } ?? [],
            "canvasContentOffset": activeCanvas.map { [Double($0.contentOffset.x), Double($0.contentOffset.y)] } ?? [],
            "viewportHostIdentity": canvasHost.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
            "viewportHostBounds": canvasHost.map { [Double($0.bounds.width), Double($0.bounds.height)] } ?? [],
            "viewportHostTransform": canvasHost.map { [Double($0.transform.a), Double($0.transform.b), Double($0.transform.c), Double($0.transform.d)] } ?? [],
            "canvasTool": activeCanvas.map { $0.tool is PKLassoTool ? "lasso" : $0.tool is PKEraserTool ? "eraser" : "ink" } ?? "none",
            "canvasPencilKitToolSequenceActive": activeCanvas?.diagnosticToolSequenceActive ?? false
        ]
        details.merge(extra) { _, new in new }
        JottreDiagnostics.shared.record(event, details: details)
    }
#endif

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === undoDoubleTapRecognizer
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === undoDoubleTapRecognizer else { return true }
        return Self.acceptsUndoDoubleTapTouch(touch.type)
            && isEditingEnabled
            && pdfView.document != nil
    }

    static func acceptsUndoDoubleTapTouch(_ touchType: UITouch.TouchType) -> Bool {
        touchType == .direct
    }

    private func updateUndoDoubleTapAvailability() {
        undoDoubleTapRecognizer?.isEnabled = isEditingEnabled && pdfView.document != nil
    }

    func configure(_ canvas: JotCanvasView, overlay: JotPDFPageCanvasOverlay, pageIndex: Int?) {
#if DEBUG
        observeCanvasPan(canvas)
#endif
        let nextTool = overlay.toolInDrawingCoordinates(selectedTool)
        if !toolsMatch(canvas.tool, nextTool) { canvas.tool = nextTool }

        let policy = CanvasTouchRouting.drawingPolicy(for: selectedTool)
        if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
        if canvas.isUserInteractionEnabled != isEditingEnabled {
            canvas.isUserInteractionEnabled = isEditingEnabled
        }
        if canvas.isDrawingEnabled != isEditingEnabled { canvas.isDrawingEnabled = isEditingEnabled }
        if canvas.isScrollEnabled { canvas.isScrollEnabled = false }
        if let pinch = canvas.pinchGestureRecognizer, pinch.isEnabled { pinch.isEnabled = false }
        canvas.suppressesStandardEditActions = CanvasTouchRouting.suppressesStandardEditActions(
            isEditing: isEditingEnabled,
            tool: selectedTool
        )
        let shouldActivateRuler = isEditingEnabled && isRulerActive && pageIndex == activePageIndex
        if canvas.isRulerActive != shouldActivateRuler {
            canvas.isRulerActive = shouldActivateRuler
        }
    }

    func detach(_ canvas: JotCanvasView) {
        canvas.isUserInteractionEnabled = false
        canvas.delegate = nil
    }

    /// PDFKit's public documentView is the content whose pan/zoom navigation
    /// policy we own. Restrict routing to its nearest scroll ancestor; scanning
    /// every PDFView descendant also changes unrelated private/internal scrolls.
    func pdfNavigationScrollViews() -> [UIScrollView] {
        guard let documentView = pdfView.documentView else { return [] }
        var ancestor = documentView.superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView { return [scrollView] }
            ancestor = view.superview
        }
        return []
    }

    func refreshPDFScrollRoutingIfNavigationViewChanged() {
        let current = Set(pdfNavigationScrollViews().map { ObjectIdentifier($0.panGestureRecognizer) })
        let routed = Set(routedPDFPans.allObjects.map(ObjectIdentifier.init))
        guard current != routed else { return }
        applyPDFScrollRouting()
    }

    private func toolsMatch(_ lhs: any PKTool, _ rhs: any PKTool) -> Bool {
        if let left = lhs as? PKInkingTool, let right = rhs as? PKInkingTool {
            return left.inkType == right.inkType && left.color.isEqual(right.color) && left.width == right.width
        }
        if let left = lhs as? PKEraserTool, let right = rhs as? PKEraserTool {
            return left.eraserType == right.eraserType && left.width == right.width
        }
        return lhs is PKLassoTool && rhs is PKLassoTool
    }
}

final class JotPDFView: PDFView {
    var suppressesStandardEditActions = false

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard !suppressesStandardEditActions else { return false }
        return super.canPerformAction(action, withSender: sender)
    }
}

final class JotCanvasView: PKCanvasView {
#if DEBUG
    private(set) var diagnosticTouchStartInWindow: CGPoint?
    private(set) var diagnosticTouchEndInWindow: CGPoint?
    private(set) var diagnosticTouchStartType: String?
    private(set) var diagnosticTouchEndType: String?
    private(set) var diagnosticStrokeCountAtTouchStart = 0
    private(set) var diagnosticToolSequenceActive = false

    func setDiagnosticToolSequenceActive(_ isActive: Bool) {
        diagnosticToolSequenceActive = isActive
    }

    func resetDiagnosticTouches() {
        diagnosticTouchStartInWindow = nil
        diagnosticTouchEndInWindow = nil
        diagnosticTouchStartType = nil
        diagnosticTouchEndType = nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first, let window {
            diagnosticTouchStartInWindow = touch.location(in: window)
            diagnosticTouchEndInWindow = diagnosticTouchStartInWindow
            diagnosticTouchStartType = String(describing: touch.type)
            diagnosticTouchEndType = diagnosticTouchStartType
            diagnosticStrokeCountAtTouchStart = drawing.strokes.count
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first, let window {
            diagnosticTouchEndInWindow = touch.location(in: window)
            diagnosticTouchEndType = String(describing: touch.type)
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first, let window {
            diagnosticTouchEndInWindow = touch.location(in: window)
            diagnosticTouchEndType = String(describing: touch.type)
        }
        super.touchesEnded(touches, with: event)
    }
#endif

    var firstResponderInHierarchy: UIResponder? {
        func firstResponder(in view: UIView) -> UIResponder? {
            if view.isFirstResponder { return view }
            for child in view.subviews {
                if let responder = firstResponder(in: child) { return responder }
            }
            return nil
        }
        return firstResponder(in: self)
    }

    var suppressesStandardEditActions = false

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard !suppressesStandardEditActions else { return false }
        return super.canPerformAction(action, withSender: sender)
    }
}

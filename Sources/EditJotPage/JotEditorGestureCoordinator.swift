import PDFKit
@preconcurrency import PencilKit
import UIKit

/// Applies PencilKit's native input policy to visible page overlays and keeps
/// direct-touch navigation on PDFKit's own scroll views.
@MainActor
final class JotEditorGestureCoordinator: NSObject, UIGestureRecognizerDelegate {
    private unowned let pdfView: JotPDFView
    private weak var fingerNavigationGestureHost: UIView?
    private let updateVisibleRegionAfterFallbackPan: @MainActor () -> Void
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
    private(set) var fingerNavigationFallbackPan: UIPanGestureRecognizer?
    private var fallbackPanStartOffset: CGPoint?
#if DEBUG
    private var pdfPanStartOffsets: [ObjectIdentifier: CGPoint] = [:]
    private var pdfPanSuccessLogged = Set<ObjectIdentifier>()
    private var lastLoggedPDFPanStates: [ObjectIdentifier: Int] = [:]
    private var lastLoggedCanvasPanStates: [ObjectIdentifier: Int] = [:]
#endif

    init(
        pdfView: JotPDFView,
        fingerNavigationGestureHost: UIView? = nil,
        updateVisibleRegionAfterFallbackPan: @escaping @MainActor () -> Void = {}
    ) {
        self.pdfView = pdfView
        self.fingerNavigationGestureHost = fingerNavigationGestureHost
        self.updateVisibleRegionAfterFallbackPan = updateVisibleRegionAfterFallbackPan
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

    private func updateFingerNavigationFallback(isEnabled: Bool) {
        let gestureHost = pdfView.window ?? fingerNavigationGestureHost ?? pdfView
        if isEnabled, fingerNavigationFallbackPan == nil {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(fingerNavigationFallbackChanged(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pan.minimumNumberOfTouches = 1
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = true
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            pan.delegate = self
            gestureHost.addGestureRecognizer(pan)
            fingerNavigationFallbackPan = pan
        } else if isEnabled,
                  let pan = fingerNavigationFallbackPan,
                  pan.view !== gestureHost,
                  pan.state != .began, pan.state != .changed, pan.numberOfTouches == 0 {
            pan.view?.removeGestureRecognizer(pan)
            gestureHost.addGestureRecognizer(pan)
        } else if !isEnabled,
                  let pan = fingerNavigationFallbackPan,
                  pan.state != .began, pan.state != .changed, pan.numberOfTouches == 0 {
            pdfView.removeGestureRecognizer(pan)
            fingerNavigationFallbackPan = nil
            fallbackPanStartOffset = nil
        }
    }

    @objc private func fingerNavigationFallbackChanged(_ pan: UIPanGestureRecognizer) {
        guard isEditingEnabled,
              let scrollView = pdfNavigationScrollViews().first else { return }
        let pdfPan = scrollView.panGestureRecognizer

        switch pan.state {
        case .began:
            fallbackPanStartOffset = scrollView.contentOffset
#if DEBUG
            pdfView.recordFingerNavigationFallbackDiagnostic(state: pan.state, scrollView: scrollView, fallbackPan: pan)
#endif
        case .changed, .ended:
            // PDFKit remains the only scroll owner whenever its public pan
            // tracks and recognizes this touch. A PDF pan that remains
            // possible with no active touches never received the gesture; this
            // handles the diagnosed PencilKit hit-test conflict without
            // competing with an active PDFKit pan.
            let fallbackReason: String?
            if pdfPan.state == .failed {
                fallbackReason = "nativePDFPanFailed"
            } else if pdfPan.state == .possible && pdfPan.numberOfTouches == 0 {
                fallbackReason = "nativePDFPanDidNotTrackTouch"
            } else {
                fallbackReason = nil
            }
            guard let fallbackReason,
                  let startOffset = fallbackPanStartOffset else { return }
#if DEBUG
            pdfView.recordFingerNavigationFallbackDiagnostic(
                state: pan.state,
                scrollView: scrollView,
                fallbackPan: pan,
                fallbackReason: fallbackReason
            )
#endif
            let translation = pan.translation(in: scrollView)
            let inset = scrollView.adjustedContentInset
            let minimumOffset = CGPoint(x: -inset.left, y: -inset.top)
            let maximumOffset = CGPoint(
                x: max(minimumOffset.x, scrollView.contentSize.width - scrollView.bounds.width + inset.right),
                y: max(minimumOffset.y, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
            )
            let desiredOffset = CGPoint(
                x: min(max(startOffset.x - translation.x, minimumOffset.x), maximumOffset.x),
                y: min(max(startOffset.y - translation.y, minimumOffset.y), maximumOffset.y)
            )
            if abs(desiredOffset.x - scrollView.contentOffset.x) > 0.5
                || abs(desiredOffset.y - scrollView.contentOffset.y) > 0.5 {
                scrollView.setContentOffset(desiredOffset, animated: false)
                updateVisibleRegionAfterFallbackPan()
                pdfView.layoutIfNeeded()
            }
        case .cancelled, .failed:
            fallbackPanStartOffset = nil
        case .possible:
            break
        @unknown default:
            break
        }
        if pan.state == .ended {
            fallbackPanStartOffset = nil
        }
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
        updateFingerNavigationFallback(isEnabled: isEditing)
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
        pan.state == .began || pan.state == .changed || (pan.state == .possible && pan.numberOfTouches > 0)
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
                "offsetChanged": pdfPanSuccessLogged.contains(key)
            ])
            pdfPanStartOffsets.removeValue(forKey: key)
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
            "canvasTool": activeCanvas.map { $0.tool is PKLassoTool ? "lasso" : $0.tool is PKEraserTool ? "eraser" : "ink" } ?? "none"
        ]
        details.merge(extra) { _, new in new }
        JottreDiagnostics.shared.record(event, details: details)
    }
#endif

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === fingerNavigationFallbackPan,
           pdfNavigationScrollViews().first?.panGestureRecognizer === otherGestureRecognizer {
            return true
        }
        return gestureRecognizer === undoDoubleTapRecognizer
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === fingerNavigationFallbackPan {
#if DEBUG && targetEnvironment(simulator)
            if EditorInteractionFixture.tool == "scribble-undo" { return false }
#endif
            let location = touch.location(in: pdfView)
            return isEditingEnabled && touch.type == .direct && pdfView.bounds.contains(location)
        }
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
#if DEBUG
    private(set) var diagnosticsLastDirectTouchHitTestTarget = "unobserved"
    private(set) var diagnosticsLastHitTestLocation: [Double] = []
    private(set) var diagnosticsLastHitTestTouchTypes: [Int] = []
    private(set) var diagnosticsFingerFallbackPanTransitions: [[String: Any]] = []
    private var diagnosticsFingerFallbackPanSequence = 0

    func recordFingerNavigationFallbackDiagnostic(
        state: UIGestureRecognizer.State,
        scrollView: UIScrollView,
        fallbackPan: UIPanGestureRecognizer,
        fallbackReason: String? = nil
    ) {
        diagnosticsFingerFallbackPanSequence += 1
        let stateName: String
        switch state {
        case .began: stateName = "began"
        case .changed: stateName = "changed"
        case .ended: stateName = "ended"
        case .cancelled: stateName = "cancelled"
        case .failed: stateName = "failed"
        case .possible: stateName = "possible"
        @unknown default: stateName = "unknown"
        }
        let transition: [String: Any] = [
            "sequence": diagnosticsFingerFallbackPanSequence,
            "stateName": stateName,
            "fallbackPanIdentity": String(describing: ObjectIdentifier(fallbackPan)),
            "pdfPanIdentity": String(describing: ObjectIdentifier(scrollView.panGestureRecognizer)),
            "pdfPanState": scrollView.panGestureRecognizer.state.rawValue,
            "pdfPanTouchCount": scrollView.panGestureRecognizer.numberOfTouches,
            "contentOffset": [Double(scrollView.contentOffset.x), Double(scrollView.contentOffset.y)],
            "fallbackReason": fallbackReason ?? "notEvaluatedAtStart",
            "timestamp": Date().timeIntervalSince1970
        ]
        diagnosticsFingerFallbackPanTransitions.append(transition)
        if diagnosticsFingerFallbackPanTransitions.count > 32 {
            diagnosticsFingerFallbackPanTransitions.removeFirst(
                diagnosticsFingerFallbackPanTransitions.count - 32
            )
        }
        JottreDiagnostics.shared.record("gesture.pdfFallbackPanStateChanged", details: transition)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        guard let event else { return target }
        diagnosticsLastDirectTouchHitTestTarget = target.map { String(describing: type(of: $0)) } ?? "nil"
        diagnosticsLastHitTestLocation = [Double(point.x), Double(point.y)]
        diagnosticsLastHitTestTouchTypes = event.allTouches?.map { $0.type.rawValue } ?? []
        let beganDirectTouch = event.allTouches?.first { $0.phase == .began && $0.type == .direct }
        JottreDiagnostics.shared.record("pdfView.hitTest", details: [
            "eventIdentity": String(describing: ObjectIdentifier(event)),
            "touchTypes": diagnosticsLastHitTestTouchTypes,
            "touchIdentity": beganDirectTouch.map { String(describing: ObjectIdentifier($0)) } ?? "unavailable",
            "locationInPDFView": [Double(point.x), Double(point.y)],
            "targetClass": diagnosticsLastDirectTouchHitTestTarget,
            "targetIdentity": target.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
        ])
        return target
    }
#endif

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

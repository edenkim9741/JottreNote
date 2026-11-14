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
    private var isToolPickerVisible = false
    private var isRulerActive = false
    private var activePageIndex: Int?
    private weak var activeCanvas: JotCanvasView?
    private let editMenuInteractions = JotEditMenuInteractionController()
    private(set) var undoDoubleTapRecognizer: UITapGestureRecognizer?
#if DEBUG
    private let observedPDFPans = NSHashTable<UIPanGestureRecognizer>.weakObjects()
    private var pdfPanStartOffsets: [ObjectIdentifier: CGPoint] = [:]
    private var pdfPanSuccessLogged = Set<ObjectIdentifier>()
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
        pickerVisible: Bool,
        rulerActive: Bool,
        activePageIndex: Int?,
        overlays: [Int: JotPDFPageCanvasOverlay]
    ) {
        isEditingEnabled = isEditing
        selectedTool = tool
        isToolPickerVisible = pickerVisible
        if isEditing {
            isRulerActive = rulerActive
            if let activePageIndex { self.activePageIndex = activePageIndex }
        } else {
            isRulerActive = false
            self.activePageIndex = nil
        }
        updateUndoDoubleTapAvailability()
        pdfView.isInMarkupMode = isEditing
        let suppressesEditActions = CanvasTouchRouting.suppressesStandardEditActions(
            isEditing: isEditing,
            tool: tool
        )
        pdfView.suppressesStandardEditActions = suppressesEditActions
        let suppressesNativeEditMenus = CanvasTouchRouting.shouldSuppressNativeEditMenuInteractions(
            isEditing: isEditing,
            tool: tool
        )
        editMenuInteractions.apply(suppressed: suppressesNativeEditMenus, in: pdfView)

        for (index, overlay) in overlays {
            guard let canvas = overlay.canvas as? JotCanvasView else { continue }
            configure(canvas, overlay: overlay, pageIndex: index)
        }
        activeCanvas = activePageIndex.flatMap { overlays[$0]?.canvas as? JotCanvasView }
        applyPDFScrollRouting()
    }

    /// Reapply the current, touch-type-specific PDF navigation policy after
    /// PencilKit ends a native tool interaction. This does not enable/disable
    /// recognizers and does not change PencilKit's own scroll state.
    func refreshPDFScrollRoutingAfterCanvasContact() {
        guard isEditingEnabled else { return }
        applyPDFScrollRouting()
    }

    private func applyPDFScrollRouting() {
        let pans = pdfNavigationScrollViews().map(\.panGestureRecognizer)
#if DEBUG
        observePDFPanGestures(pans)
        let oldStates = pans.map { ($0, scrollPolicyState(for: $0)) }
#endif
        let input = CanvasTouchRouting.configuration(
            isEditingEnabled: isEditingEnabled,
            drawingPolicy: CanvasTouchRouting.drawingPolicy(for: selectedTool),
            isToolPickerVisible: isToolPickerVisible,
            prefersPencilOnlyDrawing: UIPencilInteraction.prefersPencilOnlyDrawing
        )
        CanvasTouchRouting.apply(input, to: pans, pencilInputHasPriority: isEditingEnabled)
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

#if DEBUG
    private func observePDFPanGestures(_ pans: [UIPanGestureRecognizer]) {
        for pan in pans where !observedPDFPans.contains(pan) {
            observedPDFPans.add(pan)
            pan.addTarget(self, action: #selector(pdfPanStateChanged(_:)))
        }
    }

    @objc private func pdfPanStateChanged(_ pan: UIPanGestureRecognizer) {
        guard let scrollView = pan.view as? UIScrollView else { return }
        let key = ObjectIdentifier(pan)
        switch pan.state {
        case .began:
            pdfPanStartOffsets[key] = scrollView.contentOffset
            pdfPanSuccessLogged.remove(key)
            recordScrollDiagnostic("pdf.scrollAttempted", pan: pan)
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
            recordScrollDiagnostic("pdf.scrollPanEnded", pan: pan, extra: [
                "startContentOffset": pdfPanStartOffsets[key].map { [Double($0.x), Double($0.y)] } ?? [],
                "finalContentOffset": [Double(scrollView.contentOffset.x), Double(scrollView.contentOffset.y)],
                "offsetChanged": pdfPanSuccessLogged.contains(key)
            ])
            pdfPanStartOffsets.removeValue(forKey: key)
            pdfPanSuccessLogged.remove(key)
        default:
            break
        }
    }

    private func scrollPolicyState(for pan: UIPanGestureRecognizer) -> [String: Any] {
        [
            "enabled": pan.isEnabled,
            "minimumTouches": pan.minimumNumberOfTouches,
            "maximumTouches": pan.maximumNumberOfTouches,
            "allowedTouchTypes": pan.allowedTouchTypes.map(\.intValue)
        ]
    }

    private func recordScrollDiagnostic(
        _ event: String,
        pan: UIPanGestureRecognizer,
        extra: [String: Any] = [:]
    ) {
        let scrollView = pan.view as? UIScrollView
        var details: [String: Any] = [
            "eventSequence": JotCanvasGeometryDiagnosticSequence.next(),
            "eventTimestamp": Date().timeIntervalSince1970,
            "activeTool": selectedTool is PKLassoTool ? "lasso" : selectedTool is PKEraserTool ? "eraser" : "ink",
            "isEditing": isEditingEnabled,
            "activePageIndex": activePageIndex as Any? ?? NSNull(),
            "pdfViewInteractionEnabled": pdfView.isUserInteractionEnabled,
            "pdfScrollEnabled": scrollView?.isScrollEnabled ?? false,
            "pdfPanEnabled": pan.isEnabled,
            "pdfPanState": pan.state.rawValue,
            "numberOfTouches": pan.numberOfTouches,
            "minimumTouches": pan.minimumNumberOfTouches,
            "maximumTouches": pan.maximumNumberOfTouches,
            "allowedTouchTypes": pan.allowedTouchTypes.map(\.intValue),
            "pdfContentOffset": scrollView.map { [Double($0.contentOffset.x), Double($0.contentOffset.y)] } ?? [],
            "canvasInteractionEnabled": activeCanvas?.isUserInteractionEnabled ?? false,
            "canvasScrollEnabled": activeCanvas?.isScrollEnabled ?? false,
            "canvasPanEnabled": activeCanvas?.panGestureRecognizer.isEnabled ?? false,
            "canvasPanState": activeCanvas?.panGestureRecognizer.state.rawValue ?? -1,
            "canvasContentOffset": activeCanvas.map { [Double($0.contentOffset.x), Double($0.contentOffset.y)] } ?? [],
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
        editMenuInteractions.apply(
            suppressed: CanvasTouchRouting.shouldSuppressNativeEditMenuInteractions(
                isEditing: isEditingEnabled,
                tool: selectedTool
            ),
            in: overlay
        )
        let shouldActivateRuler = isEditingEnabled && isRulerActive && pageIndex == activePageIndex
        if canvas.isRulerActive != shouldActivateRuler {
            canvas.isRulerActive = shouldActivateRuler
        }
    }

    func detach(_ canvas: JotCanvasView) {
        editMenuInteractions.restore(in: canvas)
        canvas.isUserInteractionEnabled = false
        canvas.delegate = nil
    }

    func pdfNavigationScrollViews() -> [UIScrollView] {
        var scrollViews: [UIScrollView] = []
        if let documentView = pdfView.documentView {
            var ancestor = documentView.superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView { scrollViews.append(scrollView) }
                ancestor = view.superview
            }
        }
        collectPDFScrollViews(in: pdfView, into: &scrollViews)
        var seen = Set<ObjectIdentifier>()
        return scrollViews.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func collectPDFScrollViews(in view: UIView, into result: inout [UIScrollView]) {
        guard !(view is PKCanvasView), !(view is JotPDFPageCanvasOverlay) else { return }
        for child in view.subviews {
            guard !(child is PKCanvasView), !(child is JotPDFPageCanvasOverlay) else { continue }
            if let scrollView = child as? UIScrollView, scrollView.isScrollEnabled {
                result.append(scrollView)
            }
            collectPDFScrollViews(in: child, into: &result)
        }
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

/// PDFKit and PencilKit retain their native recognizers and touch routing.
/// Standard responder actions remain suppressed for ordinary ink tools.
/// Keeps PDFKit/PencilKit's native edit-menu interactions intact, but removes
/// only those interactions while pen or eraser input is active. The same
/// interaction objects are restored for lasso and when editing ends.
@MainActor
final class JotEditMenuInteractionController {
    private final class DetachedInteraction {
        weak var owner: UIView?
        let interaction: UIEditMenuInteraction

        init(owner: UIView, interaction: UIEditMenuInteraction) {
            self.owner = owner
            self.interaction = interaction
        }
    }

    private var detached: [ObjectIdentifier: DetachedInteraction] = [:]
    #if DEBUG
    private var diagnosed = Set<ObjectIdentifier>()
    #endif

    var detachedCount: Int { detached.count }

    func apply(suppressed: Bool, in root: UIView) {
        detached = detached.filter { $0.value.owner != nil }
        if suppressed {
            visit(root) { owner in
                for interaction in owner.interactions.compactMap({ $0 as? UIEditMenuInteraction }) {
                    let key = ObjectIdentifier(interaction)
                    diagnose(interaction, owner: owner)
                    guard detached[key] == nil else {
                        owner.removeInteraction(interaction)
                        continue
                    }
                    detached[key] = DetachedInteraction(owner: owner, interaction: interaction)
                    owner.removeInteraction(interaction)
                }
            }
        } else {
            restore(in: root)
        }
    }

    func restore(in root: UIView) {
        let keys = detached.compactMap { entry -> ObjectIdentifier? in
            let (key, record) = entry
            guard let owner = record.owner,
                owner === root || owner.isDescendant(of: root)
            else { return nil }
            return key
        }
        for key in keys {
            guard let record = detached.removeValue(forKey: key), let owner = record.owner else { continue }
            if !owner.interactions.contains(where: { $0 === record.interaction }) {
                owner.addInteraction(record.interaction)
            }
        }
    }

    private func visit(_ view: UIView, body: (UIView) -> Void) {
        body(view)
        for child in view.subviews { visit(child, body: body) }
    }

    private func diagnose(_ interaction: UIEditMenuInteraction, owner: UIView) {
        #if DEBUG
        let key = ObjectIdentifier(interaction)
        guard diagnosed.insert(key).inserted else { return }
        var hierarchy: [String] = []
        var current: UIView? = owner
        while let view = current {
            hierarchy.append(String(describing: type(of: view)))
            current = view.superview
        }
        let responder = owner.window.flatMap(firstResponder(in:)).map { String(describing: type(of: $0)) } ?? "none"
        print("[EditMenuDiagnostic] UIEditMenuInteraction owner=\(type(of: owner)) path=\(hierarchy.joined(separator: " <- ")) delegate=\(interaction.delegate.map { String(describing: type(of: $0)) } ?? "system") firstResponder=\(responder)")
        #endif
    }

    private func firstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let responder = firstResponder(in: child) { return responder }
        }
        return nil
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

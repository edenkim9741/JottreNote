import PDFKit
@preconcurrency import PencilKit
import UIKit

/// Applies PencilKit's native input policy to visible page overlays and keeps
/// direct-touch navigation on PDFKit's own scroll views.
@MainActor
final class JotEditorGestureCoordinator: NSObject {
    private unowned let pdfView: JotPDFView
    private var isEditingEnabled = false
    private var selectedTool: any PKTool = PKInkingTool(.pen)
    private var isRulerActive = false
    private var activePageIndex: Int?
    private let editMenuInteractions = JotEditMenuInteractionController()

    init(pdfView: JotPDFView) {
        self.pdfView = pdfView
        super.init()
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
        if isEditing {
            isRulerActive = rulerActive
            if let activePageIndex { self.activePageIndex = activePageIndex }
        } else {
            isRulerActive = false
            self.activePageIndex = nil
        }
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

        let input = CanvasTouchRouting.configuration(
            isEditingEnabled: isEditing,
            drawingPolicy: CanvasTouchRouting.drawingPolicy(for: tool),
            isToolPickerVisible: pickerVisible,
            prefersPencilOnlyDrawing: UIPencilInteraction.prefersPencilOnlyDrawing
        )
        CanvasTouchRouting.apply(
            input,
            to: pdfNavigationScrollViews().map(\.panGestureRecognizer),
            pencilInputHasPriority: isEditing
        )
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

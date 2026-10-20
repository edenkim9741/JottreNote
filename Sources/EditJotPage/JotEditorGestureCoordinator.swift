import PDFKit
@preconcurrency import PencilKit
import UIKit

/// Applies PencilKit's native input policy to visible page overlays and keeps
/// direct-touch navigation on PDFKit's own scroll views.
@MainActor
final class JotEditorGestureCoordinator {
    private unowned let pdfView: JotPDFView
    private var isEditingEnabled = false
    private var selectedTool: any PKTool = PKInkingTool(.pen)
    private var isRulerActive = false
    private var activePageIndex: Int?

    init(pdfView: JotPDFView) {
        self.pdfView = pdfView
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
        pdfView.suppressesStandardEditActions = isEditing

        for (index, overlay) in overlays {
            guard let canvas = overlay.canvas as? JotCanvasView else { continue }
            configure(canvas, overlay: overlay)
            canvas.isRulerActive = isEditingEnabled && self.isRulerActive && index == self.activePageIndex
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

    func configure(_ canvas: JotCanvasView, overlay: JotPDFPageCanvasOverlay, pageIndex: Int? = nil) {
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
        canvas.suppressesStandardEditActions = isEditingEnabled
        canvas.isRulerActive = isEditingEnabled && isRulerActive && pageIndex == activePageIndex
    }

    func detach(_ canvas: JotCanvasView) {
        canvas.isRulerActive = false
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

/// PDFKit and PencilKit remain responsible for their own native recognizers.
/// The editor only suppresses responder actions while a page is being edited.
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

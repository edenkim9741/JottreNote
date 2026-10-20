@preconcurrency import PencilKit
import UIKit

/// Observes the native page drawing gesture without replacing its delegate or
/// input handling. Only an explicitly held, completed stroke can be snapped.
@MainActor
final class JotPageShapeCoordinator: NSObject {
    var isEnabled = true {
        didSet { if !isEnabled { cancel() } }
    }
    private weak var canvas: PKCanvasView?
    private var detector: EndpointHoldDetector?
    private var initialStrokeCount = 0
    private var strokeEnded = false
    private var holdTask: Task<Void, Never>?
    private var isReplacing = false

    deinit { holdTask?.cancel() }

    func attach(_ canvas: PKCanvasView) {
        canvas.drawingGestureRecognizer.removeTarget(self, action: #selector(drawingGestureChanged))
        canvas.drawingGestureRecognizer.addTarget(self, action: #selector(drawingGestureChanged))
    }

    func detach(_ canvas: PKCanvasView) {
        canvas.drawingGestureRecognizer.removeTarget(self, action: #selector(drawingGestureChanged))
        if self.canvas === canvas { cancel() }
    }

    @objc private func drawingGestureChanged(_ gesture: UIGestureRecognizer) {
        var ancestor = gesture.view
        while ancestor != nil, !(ancestor is PKCanvasView) { ancestor = ancestor?.superview }
        guard let canvas = ancestor as? PKCanvasView else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        let point = gesture.location(in: canvas)
        switch gesture.state {
        case .began:
            cancel()
            guard isEnabled, let tool = canvas.tool as? PKInkingTool, tool.inkType != .marker else { return }
            self.canvas = canvas
            initialStrokeCount = canvas.drawing.strokes.count
            var next = EndpointHoldDetector(configuration: .init(holdDuration: 0.42, movementTolerance: 5))
            next.begin(at: point, timestamp: timestamp)
            detector = next
            scheduleHold()
        case .changed:
            guard var next = detector else { return }
            let reset = next.move(to: point, timestamp: timestamp)
            detector = next
            if reset { scheduleHold() }
        case .ended:
            guard var next = detector else { return }
            let shouldSnap = next.end(at: timestamp)
            detector = next
            strokeEnded = true
            holdTask?.cancel()
            if shouldSnap { drawingDidChange(canvas) } else { cancel() }
        case .cancelled, .failed: cancel()
        default: break
        }
    }

    private func scheduleHold() {
        holdTask?.cancel()
        guard let deadline = detector?.deadline, let generation = detector?.generation else { return }
        holdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            guard !Task.isCancelled, let self, var next = detector else { return }
            if next.update(at: ProcessInfo.processInfo.systemUptime, generation: generation) {
                detector = next
                UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
            }
        }
    }

    func drawingDidChange(_ canvas: PKCanvasView) {
        guard !isReplacing, self.canvas === canvas, strokeEnded,
            detector?.shouldSnapAfterStrokeCommit == true
        else { return }
        let strokes = canvas.drawing.strokes
        guard strokes.count == initialStrokeCount + 1 else { return }
        guard let stroke = strokes.last, let snapped = PencilStrokeShapeSnapper.snap(stroke) else {
            cancel()
            return
        }
        let previous = canvas.drawing
        var updated = strokes
        updated[updated.count - 1] = snapped.stroke
        cancel()
        isReplacing = true
        canvas.undoManager?.registerUndo(withTarget: canvas) { target in target.drawing = previous }
        canvas.drawing = PKDrawing(strokes: updated)
        isReplacing = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.85)
    }

    private func cancel() {
        holdTask?.cancel()
        holdTask = nil
        detector = nil
        canvas = nil
        strokeEnded = false
    }
}

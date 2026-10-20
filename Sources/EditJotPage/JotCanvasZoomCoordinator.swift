@preconcurrency import PencilKit
import UIKit

/// Uses PDFKit's scale notifications for pinch, double tap and programmatic
/// zoom. The PDF page transform carries ink during the gesture; native canvas
/// tiles are refreshed once the display scale settles, never by frame polling.
@MainActor
final class JotCanvasZoomCoordinator: NSObject {
    private let refresh: @MainActor () -> Void
    private var settleTask: Task<Void, Never>?
    private var doubleTapSettleTask: Task<Void, Never>?
    private let pinches = NSHashTable<UIPinchGestureRecognizer>.weakObjects()
    private let doubleTaps = NSHashTable<UITapGestureRecognizer>.weakObjects()

    init(refresh: @escaping @MainActor () -> Void) { self.refresh = refresh }
    deinit {
        settleTask?.cancel()
        doubleTapSettleTask?.cancel()
    }

    func observe(_ scrollViews: [UIScrollView]) {
        for scrollView in scrollViews {
            guard let pinch = scrollView.pinchGestureRecognizer, !pinches.contains(pinch) else { continue }
            pinches.add(pinch)
            pinch.addTarget(self, action: #selector(pinchChanged))
        }
    }

    func observeDoubleTapZoom(in view: UIView) {
        collectDoubleTapRecognizers(in: view)
    }

    func scaleChanged() {
        guard doubleTapSettleTask == nil else { return }
        guard !pinches.allObjects.contains(where: { $0.state == .began || $0.state == .changed }) else { return }
        schedule(delay: .milliseconds(80))
    }

    @objc private func pinchChanged(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began, .changed:
            settleTask?.cancel()
            doubleTapSettleTask?.cancel()
            doubleTapSettleTask = nil
        case .ended, .cancelled, .failed: schedule(delay: .zero)
        default: break
        }
    }

    private func collectDoubleTapRecognizers(in view: UIView) {
        guard !(view is JotPDFPageCanvasOverlay), !(view is PKCanvasView) else { return }
        for recognizer in view.gestureRecognizers ?? [] {
            guard let tap = recognizer as? UITapGestureRecognizer,
                tap.numberOfTapsRequired == 2,
                !doubleTaps.contains(tap)
            else { continue }
            doubleTaps.add(tap)
            // Observe PDFKit's recognizer without changing its configuration;
            // PDFKit owns the recognition and zoom action.
            tap.addTarget(self, action: #selector(doubleTapRecognized))
        }
        for child in view.subviews { collectDoubleTapRecognizers(in: child) }
    }

    @objc private func doubleTapRecognized(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .recognized else { return }
        // PDFKit animates the page transform after recognizing the tap. Refresh
        // the native PencilKit renderer after that transform has settled.
        settleTask?.cancel()
        doubleTapSettleTask?.cancel()
        doubleTapSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            refresh()
            doubleTapSettleTask = nil
        }
    }

    private func schedule(delay: Duration) {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            refresh()
            settleTask = nil
        }
    }
}

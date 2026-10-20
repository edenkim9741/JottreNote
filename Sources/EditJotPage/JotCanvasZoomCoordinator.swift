@preconcurrency import PencilKit
import PDFKit
import UIKit

/// Owns finger double-tap zoom and observes document zoom changes. The PDF page
/// transform carries ink during zoom; PencilKit tiles refresh after it settles.
@MainActor
final class JotCanvasZoomCoordinator: NSObject, UIGestureRecognizerDelegate {
    private let refresh: @MainActor () -> Void
    private var settleTask: Task<Void, Never>?
    private let pinches = NSHashTable<UIPinchGestureRecognizer>.weakObjects()
    private let nativeDoubleTapStates = NSMapTable<UITapGestureRecognizer, NSNumber>.weakToStrongObjects()
    private weak var doubleTapHost: PDFView?
    private(set) var doubleTapRecognizer: UITapGestureRecognizer?

    init(refresh: @escaping @MainActor () -> Void) { self.refresh = refresh }
    deinit {
        settleTask?.cancel()
    }

    func observe(_ scrollViews: [UIScrollView]) {
        for scrollView in scrollViews {
            guard let pinch = scrollView.pinchGestureRecognizer, !pinches.contains(pinch) else { continue }
            pinches.add(pinch)
            pinch.addTarget(self, action: #selector(pinchChanged))
        }
    }

    func observeDoubleTapZoom(in pdfView: PDFView, isEnabled: Bool = true) {
        if doubleTapHost !== pdfView {
            stopObservingDoubleTapZoom()
            doubleTapHost = pdfView
        }

        suppressNativeDoubleTapRecognizers(in: pdfView)
        if doubleTapRecognizer == nil {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            recognizer.numberOfTapsRequired = 2
            recognizer.numberOfTouchesRequired = 1
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            pdfView.addGestureRecognizer(recognizer)
            doubleTapRecognizer = recognizer
        }
        doubleTapRecognizer?.isEnabled = isEnabled
    }

    func stopObservingDoubleTapZoom() {
        if let host = doubleTapHost, let doubleTapRecognizer {
            host.removeGestureRecognizer(doubleTapRecognizer)
        }
        let states = nativeDoubleTapStates
        let keys = states.keyEnumerator().allObjects.compactMap { $0 as? UITapGestureRecognizer }
        for recognizer in keys {
            recognizer.isEnabled = states.object(forKey: recognizer)?.boolValue ?? recognizer.isEnabled
        }
        states.removeAllObjects()
        doubleTapRecognizer = nil
        doubleTapHost = nil
    }

    func scaleChanged() {
        guard !pinches.allObjects.contains(where: { $0.state == .began || $0.state == .changed }) else { return }
        schedule(delay: .milliseconds(80))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // The custom recognizer observes the tap while PDFKit's page/scroll
        // recognizers still handle their own navigation and selection work.
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === doubleTapRecognizer else { return true }
        return Self.acceptsDoubleTapTouch(touch.type)
    }

    static func acceptsDoubleTapTouch(_ touchType: UITouch.TouchType) -> Bool {
        touchType == .direct
    }

    static func targetScale(current: CGFloat, fit: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat? {
        guard current.isFinite, current > 0,
              fit.isFinite, fit > 0,
              minimum.isFinite, minimum >= 0,
              maximum.isFinite, maximum > 0,
              maximum >= minimum else { return nil }

        let fitScale = min(max(fit, minimum), maximum)
        let isZoomedIn = current > fitScale * 1.05
        let proposed = isZoomedIn ? fitScale : fitScale * 2
        return min(max(proposed, minimum), maximum)
    }

    @objc private func pinchChanged(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began, .changed:
            settleTask?.cancel()
        case .ended, .cancelled, .failed: schedule(delay: .zero)
        default: break
        }
    }

    private func suppressNativeDoubleTapRecognizers(in view: UIView) {
        guard !(view is JotPDFPageCanvasOverlay), !(view is PKCanvasView) else { return }
        for recognizer in view.gestureRecognizers ?? [] {
            guard let tap = recognizer as? UITapGestureRecognizer,
                tap.numberOfTapsRequired == 2,
                tap.numberOfTouchesRequired == 1,
                tap !== doubleTapRecognizer
            else { continue }
            if nativeDoubleTapStates.object(forKey: tap) == nil {
                nativeDoubleTapStates.setObject(NSNumber(value: tap.isEnabled), forKey: tap)
            }
            tap.isEnabled = false
        }
        for child in view.subviews { suppressNativeDoubleTapRecognizers(in: child) }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .recognized,
              let pdfView = doubleTapHost,
              pdfView.page(for: recognizer.location(in: pdfView), nearest: true) != nil else { return }

        let tapInPDFView = recognizer.location(in: pdfView)
        let scrollView = documentScrollView(in: pdfView)
        let minimum = pdfView.minScaleFactor
        let maximum = pdfView.maxScaleFactor
        guard let target = Self.targetScale(
            current: pdfView.scaleFactor,
            fit: pdfView.scaleFactorForSizeToFit,
            minimum: minimum,
            maximum: maximum
        ), abs(target - pdfView.scaleFactor) > 0.001 else { return }

        let isReturningToFit = target <= min(max(pdfView.scaleFactorForSizeToFit, minimum), maximum) * 1.001
        pdfView.autoScales = false
        settleTask?.cancel()
        let oldScale = pdfView.scaleFactor
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            if isReturningToFit {
                // PDFKit's autoscale path recenters the page at its fit scale.
                pdfView.autoScales = true
            } else {
                pdfView.autoScales = false
                pdfView.scaleFactor = target
                if let scrollView {
                    // PDFKit applies scaleFactor around the viewport center. Shift
                    // its document scroll offset by the difference between that
                    // center anchor and the user's tap, in post-zoom coordinates.
                    let ratio = target / oldScale
                    let delta = CGPoint(
                        x: (tapInPDFView.x - pdfView.bounds.midX) * (ratio - 1),
                        y: (tapInPDFView.y - pdfView.bounds.midY) * (ratio - 1)
                    )
                    scrollView.setContentOffset(
                        CGPoint(x: scrollView.contentOffset.x + delta.x, y: scrollView.contentOffset.y + delta.y),
                        animated: false
                    )
                }
            }
        } completion: { [weak self] _ in
            self?.schedule(delay: .milliseconds(40))
        }
    }

    private func documentScrollView(in pdfView: PDFView) -> UIScrollView? {
        guard let documentView = pdfView.documentView else { return nil }
        var ancestor = documentView.superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView { return scrollView }
            ancestor = view.superview
        }
        return nil
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

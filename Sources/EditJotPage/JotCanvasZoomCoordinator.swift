@preconcurrency import PencilKit
import PDFKit
import UIKit

/// Owns finger double-tap zoom and observes document zoom changes. The PDF page
/// transform carries ink during zoom; PencilKit tiles refresh after it settles.
@MainActor
final class JotCanvasZoomCoordinator: NSObject, UIGestureRecognizerDelegate {
    enum PageFitMode: Equatable {
        case shortSide
        case longSide

        var next: Self { self == .shortSide ? .longSide : .shortSide }
    }

    struct PageFitScales: Equatable {
        let shortSide: CGFloat
        let longSide: CGFloat

        func scale(for mode: PageFitMode) -> CGFloat {
            mode == .shortSide ? shortSide : longSide
        }
    }

    struct ScaleRange: Equatable {
        let minimum: CGFloat
        let maximum: CGFloat
    }

    private let refresh: @MainActor () -> Void
    private var settleTask: Task<Void, Never>?
    private let pinches = NSHashTable<UIPinchGestureRecognizer>.weakObjects()
    private let nativeDoubleTapStates = NSMapTable<UITapGestureRecognizer, NSNumber>.weakToStrongObjects()
    private weak var doubleTapHost: PDFView?
    private(set) var doubleTapRecognizer: UITapGestureRecognizer?
    private weak var fitCycleDocument: PDFDocument?
    private weak var fitCyclePage: PDFPage?
    private var fitCycleViewportSize: CGSize?
    private var nextFitMode: PageFitMode = .shortSide

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

    static func pageFitScales(pageSize: CGSize, viewportSize: CGSize) -> PageFitScales? {
        guard pageSize.width.isFinite, pageSize.width > 0,
              pageSize.height.isFinite, pageSize.height > 0,
              viewportSize.width.isFinite, viewportSize.width > 0,
              viewportSize.height.isFinite, viewportSize.height > 0 else { return nil }

        // Fit each actual page axis to the corresponding viewport axis. A
        // landscape page's short axis is its height; a portrait page's short
        // axis is its width. The caller supplies rotation-adjusted dimensions.
        let isPortrait = pageSize.height >= pageSize.width
        let short = isPortrait
            ? viewportSize.width / pageSize.width
            : viewportSize.height / pageSize.height
        let long = isPortrait
            ? viewportSize.height / pageSize.height
            : viewportSize.width / pageSize.width
        guard short.isFinite, short > 0, long.isFinite, long > 0 else { return nil }
        return PageFitScales(shortSide: short, longSide: long)
    }

    static func expandedScaleRange(
        minimum: CGFloat,
        maximum: CGFloat,
        toInclude scales: PageFitScales
    ) -> ScaleRange? {
        guard minimum.isFinite, minimum >= 0,
              maximum.isFinite, maximum > 0, maximum >= minimum,
              scales.shortSide.isFinite, scales.shortSide > 0,
              scales.longSide.isFinite, scales.longSide > 0 else { return nil }
        return ScaleRange(
            minimum: min(minimum, min(scales.shortSide, scales.longSide)),
            maximum: max(maximum, max(scales.shortSide, scales.longSide))
        )
    }

    static func nextFitMode(afterPinchAt current: CGFloat, scales: PageFitScales) -> PageFitMode {
        guard current.isFinite, current > 0 else { return .shortSide }
        let shortDistance = abs(log(current / scales.shortSide))
        let longDistance = abs(log(current / scales.longSide))
        let nearestMode: PageFitMode = shortDistance <= longDistance ? .shortSide : .longSide
        return nearestMode.next
    }

    @objc private func pinchChanged(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began, .changed:
            settleTask?.cancel()
        case .ended:
            prepareNextFitAfterPinch()
            schedule(delay: .zero)
        case .cancelled, .failed:
            schedule(delay: .zero)
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
              let page = pdfView.page(for: recognizer.location(in: pdfView), nearest: true),
              let viewport = displayViewport(in: pdfView),
              let pageScales = scales(for: page, viewport: viewport.size) else { return }

        resetFitCycleIfNeeded(document: pdfView.document, page: page, viewportSize: viewport.size)

        let tapInPDFView = recognizer.location(in: pdfView)
        let scrollView = documentScrollView(in: pdfView)
        let target = pageScales.scale(for: nextFitMode)
        nextFitMode = nextFitMode.next
        guard let scaleRange = Self.expandedScaleRange(
            minimum: pdfView.minScaleFactor,
            maximum: pdfView.maxScaleFactor,
            toInclude: pageScales
        ) else { return }
        guard abs(target - pdfView.scaleFactor) > 0.001 else { return }

        // PDFKit clamps scaleFactor to this range. Expand it before applying
        // either page-fit target so mixed-size and rotated pages remain valid.
        pdfView.autoScales = false
        pdfView.minScaleFactor = scaleRange.minimum
        pdfView.maxScaleFactor = scaleRange.maximum
        settleTask?.cancel()
        let oldScale = pdfView.scaleFactor
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            pdfView.autoScales = false
            pdfView.scaleFactor = target
            if let scrollView {
                // PDFKit applies scaleFactor around the viewport center. Shift
                // its document scroll offset to keep the tapped PDF location
                // anchored even when safe areas or split view offset the center.
                let ratio = target / oldScale
                let delta = CGPoint(
                    x: (tapInPDFView.x - viewport.midX) * (ratio - 1),
                    y: (tapInPDFView.y - viewport.midY) * (ratio - 1)
                )
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x + delta.x, y: scrollView.contentOffset.y + delta.y),
                    animated: false
                )
            }
        } completion: { [weak self] _ in
            self?.schedule(delay: .milliseconds(40))
        }
    }

    private func prepareNextFitAfterPinch() {
        guard let pdfView = doubleTapHost,
              let page = pdfView.currentPage,
              let viewport = displayViewport(in: pdfView),
              let pageScales = scales(for: page, viewport: viewport.size) else { return }
        resetFitCycleIfNeeded(document: pdfView.document, page: page, viewportSize: viewport.size)
        nextFitMode = Self.nextFitMode(afterPinchAt: pdfView.scaleFactor, scales: pageScales)
    }

    private func resetFitCycleIfNeeded(document: PDFDocument?, page: PDFPage, viewportSize: CGSize) {
        let viewportChanged = fitCycleViewportSize.map {
            abs($0.width - viewportSize.width) > 0.5 || abs($0.height - viewportSize.height) > 0.5
        } ?? true
        guard fitCycleDocument !== document || fitCyclePage !== page || viewportChanged else { return }
        fitCycleDocument = document
        fitCyclePage = page
        fitCycleViewportSize = viewportSize
        nextFitMode = .shortSide
    }

    private func displayViewport(in pdfView: PDFView) -> CGRect? {
        let viewport = pdfView.bounds.inset(by: pdfView.safeAreaInsets)
        guard viewport.width.isFinite, viewport.width > 0,
              viewport.height.isFinite, viewport.height > 0 else { return nil }
        return viewport
    }

    private func scales(for page: PDFPage, viewport: CGSize) -> PageFitScales? {
        let cropBounds = page.bounds(for: .cropBox)
        let displayedSize = PDFAnnotationConverter.displaySize(for: cropBounds, rotation: page.rotation)
        return Self.pageFitScales(pageSize: displayedSize, viewportSize: viewport)
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

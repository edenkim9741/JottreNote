@preconcurrency import PencilKit
import PDFKit
import UIKit

/// Owns finger double-tap zoom and observes document zoom changes. The PDF page
/// transform carries ink during zoom; PencilKit tiles refresh after it settles.
@MainActor
final class JotCanvasZoomCoordinator: NSObject, UIGestureRecognizerDelegate {
    struct PageFitScales: Equatable {
        let shortSide: CGFloat
        let longSide: CGFloat
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

    private static let minimumPinchMaximumScale: CGFloat = 16
    private static let pinchMaximumScalePerFit: CGFloat = 4
    private static let preferredPinchMaximumScale: CGFloat = 64
    private static let fitScaleTolerance: CGFloat = 0.005

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

    static func pageFitViewport(_ viewport: CGRect) -> CGRect? {
        guard viewport.origin.x.isFinite, viewport.origin.y.isFinite,
              viewport.width.isFinite, viewport.width > 0,
              viewport.height.isFinite, viewport.height > 0 else { return nil }

        // Preserve a small horizontal gutter so PDFKit rounding and tile
        // layout do not turn a width-fit into horizontal scrolling. Keep the
        // full vertical viewport so a height-fit fills the available height.
        let horizontalInset = viewport.width * 0.015
        let fittedViewport = viewport.insetBy(dx: horizontalInset, dy: 0)
        guard fittedViewport.width > 0, fittedViewport.height > 0 else { return nil }
        return fittedViewport
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

    static func targetScale(current: CGFloat, scales: PageFitScales) -> CGFloat {
        let lower = min(scales.shortSide, scales.longSide)
        let upper = max(scales.shortSide, scales.longSide)
        guard current.isFinite, current > 0 else { return lower }

        if approximatelyEqual(current, upper) { return lower }
        if approximatelyEqual(current, lower) { return upper }
        return current < lower ? lower : upper
    }

    private static func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) <= max(0.001, max(abs(lhs), abs(rhs)) * fitScaleTolerance)
    }

    @objc private func pinchChanged(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began, .changed:
            settleTask?.cancel()
        case .ended:
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

        let tapInPDFView = recognizer.location(in: pdfView)
        let scrollView = documentScrollView(in: pdfView)
        let target = Self.targetScale(current: pdfView.scaleFactor, scales: pageScales)
        let tapInPage = pdfView.convert(tapInPDFView, to: page)
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
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            pdfView.autoScales = false
            pdfView.scaleFactor = target
        } completion: { [weak self] _ in
            // PDFKit updates documentView/contentSize/insets after scaleFactor
            // changes. Anchor against the final page transform, never the
            // stale scroll geometry from the animation block.
            pdfView.setNeedsLayout()
            pdfView.layoutIfNeeded()
            pdfView.documentView?.setNeedsLayout()
            pdfView.documentView?.layoutIfNeeded()
            scrollView?.setNeedsLayout()
            scrollView?.layoutIfNeeded()
            if let scrollView {
                self?.alignPageAfterZoom(
                    page: page,
                    pagePoint: tapInPage,
                    tapPoint: tapInPDFView,
                    viewport: viewport,
                    pdfView: pdfView,
                    scrollView: scrollView
                )
            }
            self?.schedule(delay: .milliseconds(40))
        }
    }

    private func alignPageAfterZoom(
        page: PDFPage,
        pagePoint: CGPoint,
        tapPoint: CGPoint,
        viewport: CGRect,
        pdfView: PDFView,
        scrollView: UIScrollView
    ) {
        let pageRect = pdfView.convert(page.bounds(for: .cropBox), from: page)
        let pointInPDFView = pdfView.convert(pagePoint, from: page)
        let pointInScrollView = pdfView.convert(pointInPDFView, to: scrollView)

        // PDFKit centers axes whose content is smaller than the viewport. Keep
        // that native policy; only adjust axes that actually scroll.
        let visibleScrollRect = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
        let scrollsHorizontally = pageRect.width > viewport.width + 0.5
            && scrollView.contentSize.width > visibleScrollRect.width + 0.5
        let scrollsVertically = pageRect.height > viewport.height + 0.5
            && scrollView.contentSize.height > visibleScrollRect.height + 0.5
        guard scrollsHorizontally || scrollsVertically else { return }

        let targetInPDFView = CGPoint(
            x: scrollsHorizontally ? tapPoint.x : pageRect.midX,
            y: scrollsVertically ? tapPoint.y : pageRect.midY
        )
        let targetInScrollView = pdfView.convert(targetInPDFView, to: scrollView)
        let delta = CGPoint(
            x: scrollsHorizontally ? pointInScrollView.x - targetInScrollView.x : 0,
            y: scrollsVertically ? pointInScrollView.y - targetInScrollView.y : 0
        )
        let inset = scrollView.adjustedContentInset
        let minimumOffset = CGPoint(x: -inset.left, y: -inset.top)
        let maximumOffset = CGPoint(
            x: max(minimumOffset.x, scrollView.contentSize.width - scrollView.bounds.width + inset.right),
            y: max(minimumOffset.y, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        )
        let desiredOffset = CGPoint(
            x: min(max(scrollView.contentOffset.x + delta.x, minimumOffset.x), maximumOffset.x),
            y: min(max(scrollView.contentOffset.y + delta.y, minimumOffset.y), maximumOffset.y)
        )
        if abs(desiredOffset.x - scrollView.contentOffset.x) > 0.5
            || abs(desiredOffset.y - scrollView.contentOffset.y) > 0.5
        {
            scrollView.setContentOffset(desiredOffset, animated: false)
            pdfView.layoutIfNeeded()
            scrollView.layoutIfNeeded()
        }
    }

    private func displayViewport(in pdfView: PDFView) -> CGRect? {
        let visibleRect = pdfView.bounds.inset(by: pdfView.safeAreaInsets)
        return Self.pageFitViewport(visibleRect)
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

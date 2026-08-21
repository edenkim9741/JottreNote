import QuartzCore
import UIKit

/// Displays the pages behind `PKCanvasView` without rasterizing an entire PDF.
/// Only visible logical pages own views, and PDF pages use `CATiledLayer` so a
/// scalable source is redrawn at the current zoom resolution.
final class JotBackgroundView: UIView {

    nonisolated static let pageSpacing: CGFloat = 32
    nonisolated static let ruledLineSpacing: CGFloat = 32

    private enum Content {
        case ruled(pageCount: Int)
        case pdf(document: PDFRenderDocument, insertedPageSlots: [Int])

        var pageCount: Int {
            switch self {
            case let .ruled(pageCount):
                return pageCount
            case let .pdf(document, slots):
                return document.pageCount + slots.count
            }
        }
    }

    private var content: Content = .ruled(pageCount: 1)
    private var currentPageSize = CGSize(width: 1200, height: 1600)
    private var scrollOffset = CGPoint.zero
    private var zoomScale = CGFloat(1)
    private var viewportSize = CGSize.zero
    private var visiblePageViews: [Int: PageView] = [:]
    private var lastVisiblePageRange: ClosedRange<Int>?

    func configureRuled(
        pageCount: Int,
        pageSize: CGSize,
        scrollOffset: CGPoint,
        zoomScale: CGFloat
    ) {
        content = .ruled(pageCount: max(1, pageCount))
        configureCommon(pageSize: pageSize, scrollOffset: scrollOffset, zoomScale: zoomScale)
    }

    func configurePDF(
        document: PDFRenderDocument,
        pageSize: CGSize,
        insertedPageSlots: [Int],
        scrollOffset: CGPoint,
        zoomScale: CGFloat
    ) {
        let maximumSlot = document.pageCount + insertedPageSlots.count
        let slots = Array(Set(insertedPageSlots.filter { $0 >= 0 && $0 < maximumSlot })).sorted()
        content = .pdf(document: document, insertedPageSlots: slots)
        configureCommon(pageSize: pageSize, scrollOffset: scrollOffset, zoomScale: zoomScale)
    }

    func sync(scrollOffset: CGPoint, zoomScale: CGFloat, viewportSize: CGSize) {
        guard self.scrollOffset != scrollOffset
                || self.zoomScale != zoomScale
                || self.viewportSize != viewportSize else {
            return
        }
        self.scrollOffset = scrollOffset
        self.zoomScale = zoomScale
        self.viewportSize = viewportSize
        layoutVisiblePages()
    }

    /// Kept for small thumbnails and other non-editor callers. Editor pages do not
    /// use this bitmap path.
    static func makeRuledPageImage(
        pageSize: CGSize,
        traitCollection: UITraitCollection,
        scale: CGFloat
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat(for: traitCollection)
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: pageSize, format: format).image { rendererContext in
            drawRuledPage(
                in: CGRect(origin: .zero, size: pageSize),
                context: rendererContext.cgContext,
                isDark: traitCollection.userInterfaceStyle == .dark
            )
        }
    }

    private func configureCommon(pageSize: CGSize, scrollOffset: CGPoint, zoomScale: CGFloat) {
        currentPageSize = pageSize
        self.scrollOffset = scrollOffset
        self.zoomScale = zoomScale
        // Page spacing and the free canvas below the final page should expose
        // the editor's surrounding margin color, including true black in dark mode.
        backgroundColor = .clear
        visiblePageViews.values.forEach { $0.removeFromSuperview() }
        visiblePageViews.removeAll()
        lastVisiblePageRange = nil
        layoutVisiblePages()
    }

    private func layoutVisiblePages() {
        guard
            zoomScale.isFinite,
            zoomScale > 0,
            currentPageSize.width.isFinite,
            currentPageSize.height.isFinite,
            currentPageSize.width > 0,
            currentPageSize.height > 0
        else { return }

        guard let visibleRange = visiblePageRange() else {
            visiblePageViews.values.forEach { $0.removeFromSuperview() }
            visiblePageViews.removeAll()
            lastVisiblePageRange = nil
            return
        }
        guard visibleRange != lastVisiblePageRange else { return }
        lastVisiblePageRange = visibleRange

        let staleIndices = visiblePageViews.keys.filter { !visibleRange.contains($0) }
        for index in staleIndices {
            visiblePageViews.removeValue(forKey: index)?.removeFromSuperview()
        }

        for index in visibleRange {
            let pageView = visiblePageViews[index] ?? makePageView(at: index)
            visiblePageViews[index] = pageView
            let pageFrame = CGRect(
                x: 0,
                y: CGFloat(index) * (currentPageSize.height + Self.pageSpacing),
                width: currentPageSize.width,
                height: currentPageSize.height
            )
            if pageView.frame != pageFrame {
                pageView.frame = pageFrame
            }
        }
    }

    private func makePageView(at logicalIndex: Int) -> PageView {
        let pageView: PageView
        switch content {
        case .ruled:
            pageView = PageView(content: .ruled(adaptsToAppearance: true))

        case let .pdf(document, insertedPageSlots):
            if insertedPageSlots.contains(logicalIndex) {
                pageView = PageView(content: .ruled(adaptsToAppearance: false))
            } else {
                let precedingInsertions = insertedPageSlots.partitioningIndex { $0 >= logicalIndex }
                let pdfIndex = logicalIndex - precedingInsertions
                if pdfIndex >= 0, pdfIndex < document.pageCount {
                    pageView = PageView(content: .pdf(document, pageIndex: pdfIndex))
                } else {
                    pageView = PageView(content: .blank)
                }
            }
        }
        addSubview(pageView)
        return pageView
    }

    private func visiblePageRange() -> ClosedRange<Int>? {
        let totalPages = content.pageCount
        guard totalPages > 0 else { return nil }
        let stride = currentPageSize.height + Self.pageSpacing
        guard stride.isFinite, stride > 0 else { return nil }

        // Retain one page above and below the viewport so fast scrolling does not
        // expose an empty background while the next PDF tile starts rendering.
        let visibleTop = max(0, scrollOffset.y) / zoomScale
        let visibleBottom = max(0, scrollOffset.y + viewportSize.height) / zoomScale
        let first = Int(floor(visibleTop / stride)) - 1
        let last = Int(floor(visibleBottom / stride)) + 1
        let lower = max(0, first)
        let upper = min(totalPages - 1, last)
        guard upper >= lower else { return nil }
        return lower...upper
    }

    private static func drawRuledPage(in rect: CGRect, context: CGContext, isDark: Bool) {
        if isDark {
            context.setFillColor(gray: 0, alpha: 1)
        } else {
            context.setFillColor(red: 0.99, green: 0.97, blue: 0.90, alpha: 1)
        }
        context.fill(rect)
        context.setStrokeColor(gray: isDark ? 0.45 : 0.62, alpha: 0.55)
        context.setLineWidth(0.5)
        var lineY = rect.minY + ruledLineSpacing
        while lineY < rect.maxY {
            context.move(to: CGPoint(x: rect.minX, y: lineY))
            context.addLine(to: CGPoint(x: rect.maxX, y: lineY))
            context.strokePath()
            lineY += ruledLineSpacing
        }
    }
}

private extension Array where Element == Int {

    /// Index of the first element matching `predicate` in an already sorted array.
    func partitioningIndex(where predicate: (Int) -> Bool) -> Int {
        var lower = 0
        var upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if predicate(self[middle]) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }
}

private final class PageView: UIView {

    enum Content {
        case pdf(PDFRenderDocument, pageIndex: Int)
        case ruled(adaptsToAppearance: Bool)
        case blank
    }

    private let pageContent: Content

    override class var layerClass: AnyClass { PageTiledLayer.self }

    init(content: Content) {
        pageContent = content
        super.init(frame: .zero)
        isOpaque = true
        contentMode = .redraw
        if case let .ruled(adaptsToAppearance) = content, adaptsToAppearance {
            overrideUserInterfaceStyle = .unspecified
        } else {
            overrideUserInterfaceStyle = .light
        }
        if let tiledLayer = layer as? PageTiledLayer {
            tiledLayer.tileSize = CGSize(width: 768, height: 768)
            tiledLayer.levelsOfDetail = 1
            tiledLayer.levelsOfDetailBias = 4
            tiledLayer.contentsScale = UITraitCollection.current.displayScale
            tiledLayer.needsDisplayOnBoundsChange = true
        }
        updatePageContent()
        layer.borderWidth = 0.5
        layer.borderColor = UIColor(white: 0.55, alpha: 0.5).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePageContent()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        updatePageContent()
    }

    private func updatePageContent() {
        guard let tiledLayer = layer as? PageTiledLayer else { return }
        switch pageContent {
        case let .pdf(document, pageIndex):
            tiledLayer.pageContent = .pdf(document, pageIndex: pageIndex)
        case let .ruled(adaptsToAppearance):
            tiledLayer.pageContent = .ruled(
                isDark: adaptsToAppearance && traitCollection.userInterfaceStyle == .dark
            )
        case .blank:
            tiledLayer.pageContent = .blank
        }
        tiledLayer.setNeedsDisplay()
    }

}

/// `CATiledLayer` invokes `draw(in:)` on background threads. Keeping that work
/// in a layer subclass prevents Core Animation from calling the main-actor
/// isolated `UIView.draw(_:)` implementation on the wrong queue.
private final class PageTiledLayer: CATiledLayer {

    enum Content {
        case pdf(PDFRenderDocument, pageIndex: Int)
        case ruled(isDark: Bool)
        case blank
    }

    var pageContent: Content = .blank

    override class func fadeDuration() -> CFTimeInterval { 0 }

    override init() {
        super.init()
    }

    override init(layer: Any) {
        if let source = layer as? PageTiledLayer {
            pageContent = source.pageContent
        }
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(in context: CGContext) {
        let drawingBounds = bounds
        switch pageContent {
        case let .pdf(document, pageIndex):
            document.drawPage(at: pageIndex, in: drawingBounds, context: context)
        case let .ruled(isDark):
            drawRuled(in: drawingBounds, context: context, isDark: isDark)
        case .blank:
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(drawingBounds)
        }
    }

    private func drawRuled(in rect: CGRect, context: CGContext, isDark: Bool) {
        if isDark {
            context.setFillColor(gray: 0, alpha: 1)
        } else {
            context.setFillColor(red: 0.99, green: 0.97, blue: 0.90, alpha: 1)
        }
        context.fill(rect)
        context.setStrokeColor(gray: isDark ? 0.45 : 0.62, alpha: 0.55)
        context.setLineWidth(0.5)
        let visibleBounds = context.boundingBoxOfClipPath.intersection(rect)
        guard !visibleBounds.isNull else { return }
        let spacing = JotBackgroundView.ruledLineSpacing
        let firstLine = max(1, Int(floor((visibleBounds.minY - rect.minY) / spacing)))
        var lineY = rect.minY + CGFloat(firstLine) * spacing
        while lineY <= visibleBounds.maxY, lineY < rect.maxY {
            context.move(to: CGPoint(x: rect.minX, y: lineY))
            context.addLine(to: CGPoint(x: rect.maxX, y: lineY))
            lineY += spacing
        }
        context.strokePath()
    }
}

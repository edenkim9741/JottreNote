import QuartzCore
import UIKit

/// Keeps interaction-time rendering predictable. PDF pages are displayed from
/// whole-page bitmaps, so scrolling and pinching only transform existing layer
/// contents instead of waiting for a checkerboard of CATiledLayer jobs.
enum PageRasterizationPolicy {

    static let prefetchedPageCount = 3

    static func baselineScale(pageSize: CGSize) -> CGFloat {
        clampedScale(1, pageSize: pageSize)
    }

    static func settledScale(
        zoomScale: CGFloat,
        displayScale: CGFloat,
        pageSize: CGSize
    ) -> CGFloat {
        let requiredScale = max(1, zoomScale * displayScale)
        let tier: CGFloat
        if requiredScale <= 1 {
            tier = 1
        } else if requiredScale <= 1.5 {
            tier = 1.5
        } else {
            tier = 2
        }
        return clampedScale(tier, pageSize: pageSize)
    }

    static func pageRange(
        pageCount: Int,
        pageHeight: CGFloat,
        pageSpacing: CGFloat,
        scrollOffsetY: CGFloat,
        viewportHeight: CGFloat,
        zoomScale: CGFloat,
        overscan: Int
    ) -> ClosedRange<Int>? {
        guard
            pageCount > 0,
            pageHeight.isFinite,
            pageHeight > 0,
            pageSpacing.isFinite,
            viewportHeight.isFinite,
            viewportHeight >= 0,
            zoomScale.isFinite,
            zoomScale > 0
        else { return nil }

        let stride = pageHeight + pageSpacing
        guard stride.isFinite, stride > 0 else { return nil }
        let visibleTop = max(0, scrollOffsetY) / zoomScale
        let visibleBottom = max(0, scrollOffsetY + viewportHeight) / zoomScale
        let lower = max(0, Int(floor(visibleTop / stride)) - max(0, overscan))
        let upper = min(
            pageCount - 1,
            Int(floor(visibleBottom / stride)) + max(0, overscan)
        )
        guard upper >= lower else { return nil }
        return lower...upper
    }

    private static func clampedScale(_ scale: CGFloat, pageSize: CGSize) -> CGFloat {
        let longestEdge = max(pageSize.width, pageSize.height)
        guard longestEdge.isFinite, longestEdge > 0 else { return 1 }
        let maximumPixelDimension = CGFloat(4096)
        let dimensionLimitedScale = maximumPixelDimension / longestEdge
        return max(0.25, min(scale, dimensionLimitedScale))
    }
}

/// Displays paper and PDF content as one background plane below both ink
/// canvases. Ruled paper uses vector layers; PDF pages use an asynchronous,
/// cost-bounded full-page bitmap cache.
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

        var documentIdentifier: ObjectIdentifier? {
            guard case let .pdf(document, _) = self else { return nil }
            return ObjectIdentifier(document)
        }

        func pdfPageIndex(for logicalIndex: Int) -> Int? {
            guard case let .pdf(document, insertedPageSlots) = self,
                !insertedPageSlots.contains(logicalIndex)
            else { return nil }
            let precedingInsertions = insertedPageSlots.partitioningIndex { $0 >= logicalIndex }
            let pageIndex = logicalIndex - precedingInsertions
            guard pageIndex >= 0, pageIndex < document.pageCount else { return nil }
            return pageIndex
        }
    }

    private struct RasterKey: Hashable {
        let pageIndex: Int
        let scaleUnit: Int

        init(pageIndex: Int, scale: CGFloat) {
            self.pageIndex = pageIndex
            scaleUnit = Int((scale * 1_000).rounded())
        }

        var scale: CGFloat { CGFloat(scaleUnit) / 1_000 }
        var cacheKey: NSString { "\(pageIndex):\(scaleUnit)" as NSString }
    }

    private struct RasterRequestState: Equatable {
        let visibleRange: ClosedRange<Int>
        let retainedRange: ClosedRange<Int>
        let targetPrefetchRange: ClosedRange<Int>?
        let targetScaleUnit: Int
    }

    private struct RasterOperation {
        let renderTask: Task<SendablePageRaster?, Never>
        let completionTask: Task<Void, Never>

        func cancel() {
            renderTask.cancel()
            completionTask.cancel()
        }
    }

    private var content: Content = .ruled(pageCount: 1)
    private var currentPageSize = CGSize(width: 1200, height: 1600)
    private var scrollOffset = CGPoint.zero
    private var zoomScale = CGFloat(1)
    private var viewportSize = CGSize.zero
    private var isZoomInteractionActive = false
    private var settledRasterScale = CGFloat(1)
    private var visiblePageViews: [Int: BackgroundPageView] = [:]
    private var lastRetainedPageRange: ClosedRange<Int>?
    private var lastRasterRequestState: RasterRequestState?
    private var targetPrefetchRange: ClosedRange<Int>?
    private var renderGeneration = UUID()
    private var rasterOperations: [RasterKey: RasterOperation] = [:]
    private let rasterCache = NSCache<NSString, CachedPageRaster>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        rasterCache.countLimit = 32
        #if targetEnvironment(macCatalyst)
        rasterCache.totalCostLimit = 512 * 1_024 * 1_024
        #else
        rasterCache.totalCostLimit =
            UIDevice.current.userInterfaceIdiom == .phone
            ? 128 * 1_024 * 1_024
            : 256 * 1_024 * 1_024
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        for operation in rasterOperations.values {
            operation.cancel()
        }
    }

    func configureRuled(
        pageCount: Int,
        pageSize: CGSize,
        scrollOffset: CGPoint,
        zoomScale: CGFloat
    ) {
        let invalidatesRasterCache = content.documentIdentifier != nil || currentPageSize != pageSize
        content = .ruled(pageCount: max(1, pageCount))
        configureCommon(
            pageSize: pageSize,
            scrollOffset: scrollOffset,
            zoomScale: zoomScale,
            invalidatesRasterCache: invalidatesRasterCache
        )
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
        let nextDocumentIdentifier = ObjectIdentifier(document)
        let invalidatesRasterCache =
            content.documentIdentifier != nextDocumentIdentifier || currentPageSize != pageSize
        content = .pdf(document: document, insertedPageSlots: slots)
        configureCommon(
            pageSize: pageSize,
            scrollOffset: scrollOffset,
            zoomScale: zoomScale,
            invalidatesRasterCache: invalidatesRasterCache
        )
    }

    func sync(scrollOffset: CGPoint, zoomScale: CGFloat, viewportSize: CGSize) {
        guard
            self.scrollOffset != scrollOffset
                || self.zoomScale != zoomScale
                || self.viewportSize != viewportSize
        else { return }
        self.scrollOffset = scrollOffset
        self.zoomScale = zoomScale
        self.viewportSize = viewportSize
        layoutRetainedPages()
    }

    func setZoomInteractionActive(_ isActive: Bool) {
        guard isZoomInteractionActive != isActive else { return }
        isZoomInteractionActive = isActive
        if !isActive {
            settledRasterScale = preferredRasterScale()
            lastRasterRequestState = nil
            layoutRetainedPages()
        }
    }

    func prefetch(toward targetScrollOffset: CGPoint) {
        targetPrefetchRange = PageRasterizationPolicy.pageRange(
            pageCount: content.pageCount,
            pageHeight: currentPageSize.height,
            pageSpacing: Self.pageSpacing,
            scrollOffsetY: targetScrollOffset.y,
            viewportHeight: viewportSize.height,
            zoomScale: zoomScale,
            overscan: 1
        )
        lastRasterRequestState = nil
        layoutRetainedPages()
    }

    func finishScrollPrefetch() {
        guard targetPrefetchRange != nil else { return }
        targetPrefetchRange = nil
        lastRasterRequestState = nil
        layoutRetainedPages()
    }

    /// Kept for thumbnails and other non-editor callers.
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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard !isZoomInteractionActive else { return }
        let nextScale = preferredRasterScale()
        guard nextScale != settledRasterScale else { return }
        settledRasterScale = nextScale
        lastRasterRequestState = nil
        layoutRetainedPages()
    }

    private func configureCommon(
        pageSize: CGSize,
        scrollOffset: CGPoint,
        zoomScale: CGFloat,
        invalidatesRasterCache: Bool
    ) {
        currentPageSize = pageSize
        self.scrollOffset = scrollOffset
        self.zoomScale = zoomScale
        backgroundColor = .clear
        settledRasterScale = preferredRasterScale()

        if invalidatesRasterCache {
            resetRasterCache()
        } else if case .ruled = content {
            cancelAllRasterOperations()
        }
        for pageView in visiblePageViews.values {
            pageView.removeFromSuperview()
        }
        visiblePageViews.removeAll()
        lastRetainedPageRange = nil
        lastRasterRequestState = nil
        targetPrefetchRange = nil
        layoutRetainedPages()
    }

    private func layoutRetainedPages() {
        guard
            currentPageSize.width.isFinite,
            currentPageSize.height.isFinite,
            currentPageSize.width > 0,
            currentPageSize.height > 0,
            let visibleRange = pageRange(overscan: 0),
            let retainedRange = pageRange(overscan: PageRasterizationPolicy.prefetchedPageCount)
        else {
            removeAllPageViews()
            return
        }

        if retainedRange != lastRetainedPageRange {
            lastRetainedPageRange = retainedRange
            let staleIndices = visiblePageViews.keys.filter { !retainedRange.contains($0) }
            for index in staleIndices {
                visiblePageViews.removeValue(forKey: index)?.removeFromSuperview()
            }

            for index in retainedRange where visiblePageViews[index] == nil {
                let pageView = makePageView(at: index)
                pageView.frame = pageFrame(at: index)
                visiblePageViews[index] = pageView
                addSubview(pageView)
            }
        }

        if !isZoomInteractionActive {
            settledRasterScale = preferredRasterScale()
        }

        let requestState = RasterRequestState(
            visibleRange: visibleRange,
            retainedRange: retainedRange,
            targetPrefetchRange: targetPrefetchRange,
            targetScaleUnit: Int((settledRasterScale * 1_000).rounded())
        )
        guard requestState != lastRasterRequestState else { return }
        lastRasterRequestState = requestState
        updateRasterRequests(visibleRange: visibleRange, retainedRange: retainedRange)
    }

    private func makePageView(at logicalIndex: Int) -> BackgroundPageView {
        switch content {
        case .ruled:
            return BackgroundPageView(content: .ruled(adaptsToAppearance: true))
        case let .pdf(_, insertedPageSlots):
            if insertedPageSlots.contains(logicalIndex) {
                return BackgroundPageView(content: .ruled(adaptsToAppearance: false))
            }
            if let pageIndex = content.pdfPageIndex(for: logicalIndex) {
                return BackgroundPageView(content: .pdf(pageIndex: pageIndex))
            }
            return BackgroundPageView(content: .blankPaper)
        }
    }

    private func updateRasterRequests(
        visibleRange: ClosedRange<Int>,
        retainedRange: ClosedRange<Int>
    ) {
        guard case let .pdf(document, _) = content else {
            cancelAllRasterOperations()
            return
        }

        let baselineScale = PageRasterizationPolicy.baselineScale(pageSize: currentPageSize)
        let targetScale = settledRasterScale

        let visibleIndices = prioritizedIndices(in: visibleRange, around: visibleRange)
        let retainedIndices = prioritizedIndices(in: retainedRange, around: visibleRange)
            .filter { !visibleRange.contains($0) }
        let targetIndices =
            targetPrefetchRange.map {
                prioritizedIndices(in: $0, around: $0)
            } ?? []
        var desiredKeys = Set<RasterKey>()

        // Visible pages receive a quick baseline and the settled zoom tier.
        for logicalIndex in visibleIndices {
            guard let pageView = visiblePageViews[logicalIndex],
                let pageIndex = pageView.pdfPageIndex
            else { continue }
            let baselineKey = RasterKey(pageIndex: pageIndex, scale: baselineScale)
            let targetKey = RasterKey(pageIndex: pageIndex, scale: targetScale)
            desiredKeys.insert(baselineKey)
            desiredKeys.insert(targetKey)
            applyCachedRaster(for: targetKey, to: pageView)
            applyCachedRaster(for: baselineKey, to: pageView)
            if targetKey != baselineKey, pageView.displayedRasterScale == 0 {
                requestRaster(for: baselineKey, document: document, priority: .userInitiated)
            }
            requestRaster(
                for: targetKey == baselineKey ? baselineKey : targetKey,
                document: document,
                priority: .userInitiated
            )
        }

        // Adjacent pages keep a 1x bitmap warm. Fast scrolling therefore lands
        // on a complete page rather than a set of independently arriving tiles.
        for logicalIndex in retainedIndices {
            guard let pageView = visiblePageViews[logicalIndex],
                let pageIndex = pageView.pdfPageIndex
            else { continue }
            let key = RasterKey(pageIndex: pageIndex, scale: baselineScale)
            desiredKeys.insert(key)
            applyCachedRaster(for: key, to: pageView)
            requestRaster(for: key, document: document, priority: .utility)
        }

        // A fast flick can jump beyond the normal retained window. Begin those
        // destination pages before deceleration reaches them.
        for logicalIndex in targetIndices {
            guard let pageIndex = content.pdfPageIndex(for: logicalIndex) else { continue }
            let key = RasterKey(pageIndex: pageIndex, scale: baselineScale)
            desiredKeys.insert(key)
            requestRaster(for: key, document: document, priority: .userInitiated)
        }

        let staleKeys = rasterOperations.keys.filter { !desiredKeys.contains($0) }
        for key in staleKeys {
            rasterOperations.removeValue(forKey: key)?.cancel()
        }
    }

    private func requestRaster(
        for key: RasterKey,
        document: PDFRenderDocument,
        priority: TaskPriority
    ) {
        guard rasterCache.object(forKey: key.cacheKey) == nil,
            rasterOperations[key] == nil
        else { return }

        let pageSize = currentPageSize
        let generation = renderGeneration
        let renderTask = Task.detached(priority: priority) { () -> SendablePageRaster? in
            guard !Task.isCancelled else { return nil }
            return PDFPageBitmapRenderer.render(
                document: document,
                pageIndex: key.pageIndex,
                pageSize: pageSize,
                scale: key.scale
            )
        }
        let completionTask = Task { @MainActor [weak self] in
            let raster = await renderTask.value
            guard let self else { return }
            rasterOperations[key] = nil
            guard
                !Task.isCancelled,
                generation == renderGeneration,
                let raster
            else { return }
            let cachedRaster = CachedPageRaster(image: raster.image, scale: key.scale)
            rasterCache.setObject(cachedRaster, forKey: key.cacheKey, cost: raster.cost)
            for pageView in visiblePageViews.values where pageView.pdfPageIndex == key.pageIndex {
                pageView.setRasterImage(raster.image, scale: key.scale)
            }
        }
        rasterOperations[key] = RasterOperation(
            renderTask: renderTask,
            completionTask: completionTask
        )
    }

    private func applyCachedRaster(for key: RasterKey, to pageView: BackgroundPageView) {
        guard let cached = rasterCache.object(forKey: key.cacheKey) else { return }
        pageView.setRasterImage(cached.image, scale: cached.scale)
    }

    private func preferredRasterScale() -> CGFloat {
        PageRasterizationPolicy.settledScale(
            zoomScale: zoomScale,
            displayScale: max(1, traitCollection.displayScale),
            pageSize: currentPageSize
        )
    }

    private func pageRange(overscan: Int) -> ClosedRange<Int>? {
        PageRasterizationPolicy.pageRange(
            pageCount: content.pageCount,
            pageHeight: currentPageSize.height,
            pageSpacing: Self.pageSpacing,
            scrollOffsetY: scrollOffset.y,
            viewportHeight: viewportSize.height,
            zoomScale: zoomScale,
            overscan: overscan
        )
    }

    private func prioritizedIndices(
        in range: ClosedRange<Int>,
        around visibleRange: ClosedRange<Int>
    ) -> [Int] {
        let visibleCenter = CGFloat(visibleRange.lowerBound + visibleRange.upperBound) / 2
        return Array(range).sorted {
            abs(CGFloat($0) - visibleCenter) < abs(CGFloat($1) - visibleCenter)
        }
    }

    private func pageFrame(at index: Int) -> CGRect {
        CGRect(
            x: 0,
            y: CGFloat(index) * (currentPageSize.height + Self.pageSpacing),
            width: currentPageSize.width,
            height: currentPageSize.height
        )
    }

    private func resetRasterCache() {
        renderGeneration = UUID()
        cancelAllRasterOperations()
        rasterCache.removeAllObjects()
    }

    private func cancelAllRasterOperations() {
        for operation in rasterOperations.values {
            operation.cancel()
        }
        rasterOperations.removeAll()
    }

    private func removeAllPageViews() {
        for pageView in visiblePageViews.values {
            pageView.removeFromSuperview()
        }
        visiblePageViews.removeAll()
        lastRetainedPageRange = nil
        lastRasterRequestState = nil
        targetPrefetchRange = nil
        cancelAllRasterOperations()
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
            lineY += ruledLineSpacing
        }
        context.strokePath()
    }
}

extension Array where Element == Int {

    /// Index of the first element matching `predicate` in an already sorted array.
    fileprivate func partitioningIndex(where predicate: (Int) -> Bool) -> Int {
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

private final class BackgroundPageView: UIView {

    enum Content {
        case pdf(pageIndex: Int)
        case ruled(adaptsToAppearance: Bool)
        case blankPaper
    }

    let pdfPageIndex: Int?
    private let pageContent: Content
    private let ruledLinesLayer = CAShapeLayer()
    private(set) var displayedRasterScale = CGFloat.zero

    init(content: Content) {
        pageContent = content
        if case let .pdf(pageIndex) = content {
            pdfPageIndex = pageIndex
        } else {
            pdfPageIndex = nil
        }
        super.init(frame: .zero)
        isOpaque = true
        layer.drawsAsynchronously = true
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = .linear
        layer.borderWidth = 0.5
        layer.borderColor = UIColor(white: 0.55, alpha: 0.5).cgColor

        if case let .ruled(adaptsToAppearance) = content, adaptsToAppearance {
            overrideUserInterfaceStyle = .unspecified
        } else {
            overrideUserInterfaceStyle = .light
        }
        if case .ruled = content {
            ruledLinesLayer.fillColor = nil
            ruledLinesLayer.lineWidth = 0.5
            layer.addSublayer(ruledLinesLayer)
        }
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard case .ruled = pageContent else { return }
        ruledLinesLayer.frame = bounds
        let path = CGMutablePath()
        var lineY = JotBackgroundView.ruledLineSpacing
        while lineY < bounds.height {
            path.move(to: CGPoint(x: bounds.minX, y: lineY))
            path.addLine(to: CGPoint(x: bounds.maxX, y: lineY))
            lineY += JotBackgroundView.ruledLineSpacing
        }
        ruledLinesLayer.path = path
        ruledLinesLayer.contentsScale = traitCollection.displayScale
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        updateAppearance()
    }

    func setRasterImage(_ image: CGImage, scale: CGFloat) {
        guard pdfPageIndex != nil,
            displayedRasterScale == 0 || scale >= displayedRasterScale
        else { return }
        displayedRasterScale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        layer.contentsScale = scale
        CATransaction.commit()
    }

    private func updateAppearance() {
        switch pageContent {
        case let .ruled(adaptsToAppearance):
            let isDark = adaptsToAppearance && traitCollection.userInterfaceStyle == .dark
            layer.backgroundColor =
                isDark
                ? UIColor.black.cgColor
                : UIColor(red: 0.99, green: 0.97, blue: 0.90, alpha: 1).cgColor
            ruledLinesLayer.strokeColor =
                UIColor(
                    white: isDark ? 0.45 : 0.62,
                    alpha: 0.55
                ).cgColor
        case .pdf, .blankPaper:
            layer.backgroundColor = UIColor.white.cgColor
        }
    }
}

private final class CachedPageRaster {
    let image: CGImage
    let scale: CGFloat

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }
}

private struct SendablePageRaster: @unchecked Sendable {
    let image: CGImage
    let cost: Int
}

private enum PDFPageBitmapRenderer {

    nonisolated static func render(
        document: PDFRenderDocument,
        pageIndex: Int,
        pageSize: CGSize,
        scale: CGFloat
    ) -> SendablePageRaster? {
        guard !Task.isCancelled,
            pageSize.width.isFinite,
            pageSize.height.isFinite,
            pageSize.width > 0,
            pageSize.height > 0,
            scale.isFinite,
            scale > 0
        else { return nil }

        return autoreleasepool {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = scale
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: pageSize, format: format).image {
                rendererContext in
                document.drawPage(
                    at: pageIndex,
                    in: CGRect(origin: .zero, size: pageSize),
                    context: rendererContext.cgContext,
                    fillsBackground: true
                )
            }
            guard !Task.isCancelled, let cgImage = image.cgImage else { return nil }
            let cost = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
            return SendablePageRaster(
                image: cgImage,
                cost: cost.overflow ? Int.max : cost.partialValue
            )
        }
    }
}

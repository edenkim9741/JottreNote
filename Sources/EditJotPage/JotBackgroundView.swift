import QuartzCore
import UIKit

/// Keeps interaction-time rendering predictable. PDF pages are displayed from
/// whole-page bitmaps, so scrolling and pinching only transform existing layer
/// contents instead of waiting for a checkerboard of CATiledLayer jobs.
///
/// The whole-page bitmap alone cannot stay sharp while zooming: its resolution
/// is bounded so a long document remains affordable. Zoomed-in reading is
/// therefore served by a second, viewport-sized bitmap re-rendered straight
/// from `CGPDFPage` at the device resolution the current zoom actually needs.
/// Because only the visible slice is rasterized, its cost stays roughly
/// constant instead of growing with the zoom.
///
/// Ruled paper needs none of this. Its lines are a `CAShapeLayer`, so following
/// the zoom with `contentsScale` keeps them genuinely vector-drawn.
enum PageRasterizationPolicy {

    static let prefetchedPageCount = 3

    /// Pixel budget for one detail bitmap. The detail covers only the visible
    /// slice of a page, so this bound is viewport-shaped rather than
    /// zoom-shaped.
    static let maximumDetailPixels = CGFloat(8_000_000)

    /// Highest backing-store density PencilKit is asked to use. Reached at the
    /// editor's maximum zoom on a 2x display.
    static let maximumInkContentScale = CGFloat(16)

    /// Keeps small scroll adjustments inside the bitmap that is already on
    /// screen instead of re-rendering on every frame.
    private static let detailMargin = CGFloat(0.08)

    private static let maximumPixelDimension = CGFloat(4_096)
    private static let maximumDetailPixelDimension = CGFloat(8_192)

    /// A vector re-render of one page region, expressed in page coordinates.
    struct DetailRequest: Equatable, Sendable {
        let sourceRect: CGRect
        let scale: CGFloat
    }

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

    /// Describes the vector re-render needed to keep `visiblePageRect` sharp, or
    /// `nil` when the whole-page bitmap at `baseScale` already resolves every
    /// device pixel.
    static func detailRequest(
        visiblePageRect: CGRect,
        pageSize: CGSize,
        zoomScale: CGFloat,
        displayScale: CGFloat,
        baseScale: CGFloat
    ) -> DetailRequest? {
        guard
            pageSize.width.isFinite,
            pageSize.height.isFinite,
            pageSize.width > 0,
            pageSize.height > 0,
            zoomScale.isFinite,
            zoomScale > 0,
            displayScale.isFinite,
            displayScale > 0,
            baseScale.isFinite
        else { return nil }

        let pageBounds = CGRect(origin: .zero, size: pageSize)
        let visibleRect = visiblePageRect.standardized.intersection(pageBounds)
        guard
            !visibleRect.isNull,
            visibleRect.width > 0,
            visibleRect.height > 0
        else { return nil }

        // Whole integer steps keep the number of distinct re-renders small
        // while still tracking the zoom upwards.
        let requiredScale = max(1, (zoomScale * displayScale).rounded(.up))
        guard requiredScale > baseScale + 0.001 else { return nil }

        let sourceRect =
            visibleRect
            .insetBy(
                dx: -visibleRect.width * detailMargin,
                dy: -visibleRect.height * detailMargin
            )
            .intersection(pageBounds)
            .integral
            .intersection(pageBounds)
        guard
            !sourceRect.isNull,
            sourceRect.width > 0,
            sourceRect.height > 0
        else { return nil }

        let scale = clampedDetailScale(requiredScale, sourceSize: sourceRect.size)
        guard scale > baseScale + 0.001 else { return nil }
        return DetailRequest(sourceRect: sourceRect, scale: scale)
    }

    /// Backing-store density for the PencilKit canvases. PencilKit keeps ink as
    /// vector strokes, so raising this makes it re-tessellate the strokes at the
    /// zoomed resolution instead of magnifying a 1x rasterization.
    static func inkContentScale(zoomScale: CGFloat, displayScale: CGFloat) -> CGFloat {
        let baseScale = max(1, displayScale.isFinite ? displayScale : 1)
        guard zoomScale.isFinite, zoomScale > 0 else { return baseScale }
        let requiredScale = (zoomScale * baseScale).rounded(.up)
        return min(max(baseScale, requiredScale), maximumInkContentScale)
    }

    /// Document-space breathing room around the PencilKit viewport.
    ///
    /// The allocation is measured in document points, so a fixed overscan grows
    /// the backing store quadratically once `inkContentScale` follows the zoom.
    /// Trading buffer for density keeps the zoomed-in canvas both sharp and
    /// bounded, and matters less at high zoom where a screenful of document is
    /// small anyway.
    static func inkViewportOverscan(zoomScale: CGFloat) -> CGFloat {
        guard zoomScale.isFinite, zoomScale > 0 else { return 1 }
        if zoomScale <= 1.01 { return 1 }
        if zoomScale <= 2 { return 0.5 }
        if zoomScale <= 4 { return 0.25 }
        return 0.15
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
        let dimensionLimitedScale = maximumPixelDimension / longestEdge
        return max(0.25, min(scale, dimensionLimitedScale))
    }

    /// A detail bitmap is bounded by total pixels rather than by page size: it
    /// always covers roughly one viewport, so the same budget holds at any zoom.
    private static func clampedDetailScale(_ scale: CGFloat, sourceSize: CGSize) -> CGFloat {
        let longestEdge = max(sourceSize.width, sourceSize.height)
        let area = sourceSize.width * sourceSize.height
        guard longestEdge.isFinite, longestEdge > 0, area.isFinite, area > 0 else { return 1 }
        let dimensionLimitedScale = maximumDetailPixelDimension / longestEdge
        let areaLimitedScale = (maximumDetailPixels / area).squareRoot()
        return max(1, min(scale, min(dimensionLimitedScale, areaLimitedScale)))
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

    private struct DetailOperation {
        let request: PageRasterizationPolicy.DetailRequest
        let renderTask: Task<SendablePageDetail?, Never>
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
    private var detailOperations: [Int: DetailOperation] = [:]
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
        for operation in detailOperations.values {
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
                pageView.refreshRuledLineResolution(documentZoomScale: zoomScale)
                visiblePageViews[index] = pageView
                addSubview(pageView)
            }
        }

        if !isZoomInteractionActive {
            settledRasterScale = preferredRasterScale()
        }

        // Detail bitmaps track the viewport continuously, including during a
        // pinch, because they are what keeps a zoomed page sharp.
        updateDetailRequests(visibleRange: visibleRange)

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

    /// Re-renders the visible slice of each on-screen PDF page straight from
    /// `CGPDFPage` whenever the whole-page bitmap can no longer resolve every
    /// device pixel. Pages that scroll away drop their detail, so the extra
    /// memory is proportional to the viewport rather than to the document.
    ///
    /// Ruled paper needs no bitmap at all: its lines are a `CAShapeLayer`, so
    /// raising `contentsScale` is enough to keep them vector-sharp.
    private func updateDetailRequests(visibleRange: ClosedRange<Int>) {
        for pageView in visiblePageViews.values {
            pageView.refreshRuledLineResolution(documentZoomScale: zoomScale)
        }

        for (logicalIndex, operation) in detailOperations
        where !visibleRange.contains(logicalIndex) {
            operation.cancel()
            detailOperations.removeValue(forKey: logicalIndex)
        }
        for (logicalIndex, pageView) in visiblePageViews
        where !visibleRange.contains(logicalIndex) {
            pageView.clearDetail()
        }

        guard case let .pdf(document, _) = content else {
            cancelAllDetailOperations()
            return
        }

        let displayScale = max(1, traitCollection.displayScale)
        for logicalIndex in visibleRange {
            guard let pageView = visiblePageViews[logicalIndex],
                let pageIndex = pageView.pdfPageIndex
            else { continue }
            let pageFrame = self.pageFrame(at: logicalIndex)
            let visiblePageRect = CGRect(
                x: scrollOffset.x / zoomScale - pageFrame.minX,
                y: scrollOffset.y / zoomScale - pageFrame.minY,
                width: viewportSize.width / zoomScale,
                height: viewportSize.height / zoomScale
            )
            guard
                let request = PageRasterizationPolicy.detailRequest(
                    visiblePageRect: visiblePageRect,
                    pageSize: currentPageSize,
                    zoomScale: zoomScale,
                    displayScale: displayScale,
                    baseScale: pageView.displayedRasterScale
                )
            else {
                detailOperations.removeValue(forKey: logicalIndex)?.cancel()
                pageView.clearDetail()
                continue
            }
            requestDetail(
                request,
                for: logicalIndex,
                pageIndex: pageIndex,
                pageView: pageView,
                document: document
            )
        }
    }

    private func requestDetail(
        _ request: PageRasterizationPolicy.DetailRequest,
        for logicalIndex: Int,
        pageIndex: Int,
        pageView: BackgroundPageView,
        document: PDFRenderDocument
    ) {
        guard !pageView.satisfiesDetail(request) else {
            detailOperations.removeValue(forKey: logicalIndex)?.cancel()
            return
        }
        if let operation = detailOperations[logicalIndex] {
            guard operation.request != request else { return }
            operation.cancel()
        }

        let pageSize = currentPageSize
        let generation = renderGeneration
        let renderTask = Task.detached(priority: .userInitiated) { () -> SendablePageDetail? in
            guard !Task.isCancelled else { return nil }
            return PDFPageDetailRenderer.render(
                document: document,
                pageIndex: pageIndex,
                pageSize: pageSize,
                sourceRect: request.sourceRect,
                scale: request.scale
            )
        }
        let completionTask = Task { @MainActor [weak self] in
            let detail = await renderTask.value
            guard let self else { return }
            if detailOperations[logicalIndex]?.request == request {
                detailOperations.removeValue(forKey: logicalIndex)
            }
            guard
                !Task.isCancelled,
                generation == renderGeneration,
                let detail,
                let pageView = visiblePageViews[logicalIndex],
                pageView.pdfPageIndex == pageIndex
            else { return }
            pageView.setDetailImage(
                detail.image,
                sourceRect: request.sourceRect,
                scale: request.scale
            )
        }
        detailOperations[logicalIndex] = DetailOperation(
            request: request,
            renderTask: renderTask,
            completionTask: completionTask
        )
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
        cancelAllDetailOperations()
    }

    private func cancelAllDetailOperations() {
        for operation in detailOperations.values {
            operation.cancel()
        }
        detailOperations.removeAll()
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
    /// Sharp re-render of the visible slice, drawn above the whole-page bitmap.
    private let detailLayer = CALayer()
    private var detailSourceRect = CGRect.null
    private var detailScale = CGFloat.zero
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

        detailLayer.contentsGravity = .resize
        // The detail is rendered at or above the density the current zoom needs,
        // so it is displayed at 1:1 or very slightly reduced. Linear filtering
        // resolves that residual fraction without reintroducing stair-stepping.
        detailLayer.minificationFilter = .linear
        detailLayer.magnificationFilter = .linear
        detailLayer.isHidden = true
        detailLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(detailLayer)

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
        ruledLinesLayer.contentsScale = ruledLineContentsScale
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

    /// True when the currently displayed detail already covers `request` at an
    /// equal or higher resolution, so no re-render is needed.
    func satisfiesDetail(_ request: PageRasterizationPolicy.DetailRequest) -> Bool {
        guard !detailLayer.isHidden, !detailSourceRect.isNull else { return false }
        return detailScale >= request.scale - 0.001
            && detailSourceRect.contains(request.sourceRect)
    }

    func setDetailImage(_ image: CGImage, sourceRect: CGRect, scale: CGFloat) {
        detailSourceRect = sourceRect
        detailScale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        detailLayer.frame = sourceRect
        detailLayer.contents = image
        detailLayer.contentsScale = scale
        detailLayer.isHidden = false
        CATransaction.commit()
    }

    func clearDetail() {
        guard !detailLayer.isHidden || detailLayer.contents != nil else { return }
        detailSourceRect = .null
        detailScale = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        detailLayer.isHidden = true
        detailLayer.contents = nil
        CATransaction.commit()
    }

    /// Ruled paper draws its lines as a vector `CAShapeLayer`, which Core
    /// Animation still rasterizes at `contentsScale`. Without accounting for the
    /// document zoom, those hairlines alias exactly like a bitmap would.
    private var ruledLineContentsScale: CGFloat {
        PageRasterizationPolicy.inkContentScale(
            zoomScale: documentZoomScale,
            displayScale: max(1, traitCollection.displayScale)
        )
    }

    /// Zoom applied by the document scroll view, pushed down by the owning
    /// background view. Kept as stored state so `layoutSubviews` does not have
    /// to reach back up the view hierarchy.
    private var documentZoomScale = CGFloat(1)

    func refreshRuledLineResolution(documentZoomScale: CGFloat) {
        if documentZoomScale.isFinite, documentZoomScale > 0 {
            self.documentZoomScale = documentZoomScale
        }
        guard case .ruled = pageContent else { return }
        let scale = ruledLineContentsScale
        guard abs(ruledLinesLayer.contentsScale - scale) > 0.001 else { return }
        ruledLinesLayer.contentsScale = scale
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

private struct SendablePageDetail: @unchecked Sendable {
    let image: CGImage
}

/// Draws one region of a PDF page at an arbitrary resolution by scaling the
/// Core Graphics context around the vector page. Nothing is resampled from an
/// existing bitmap, so the result is as sharp as the zoom requires.
private enum PDFPageDetailRenderer {

    nonisolated static func render(
        document: PDFRenderDocument,
        pageIndex: Int,
        pageSize: CGSize,
        sourceRect: CGRect,
        scale: CGFloat
    ) -> SendablePageDetail? {
        guard !Task.isCancelled,
            pageSize.width.isFinite,
            pageSize.height.isFinite,
            pageSize.width > 0,
            pageSize.height > 0,
            sourceRect.width.isFinite,
            sourceRect.height.isFinite,
            sourceRect.width > 0,
            sourceRect.height > 0,
            scale.isFinite,
            scale > 0
        else { return nil }

        return autoreleasepool {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = scale
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: sourceRect.size, format: format).image {
                rendererContext in
                let context = rendererContext.cgContext
                // Move the requested region to the context origin, then hand the
                // full page rect to the vector renderer. Core Graphics clips and
                // rasterizes at `format.scale`, which is the whole point.
                context.translateBy(x: -sourceRect.minX, y: -sourceRect.minY)
                document.drawPage(
                    at: pageIndex,
                    in: CGRect(origin: .zero, size: pageSize),
                    context: context,
                    fillsBackground: true
                )
            }
            guard !Task.isCancelled, let cgImage = image.cgImage else { return nil }
            return SendablePageDetail(image: cgImage)
        }
    }
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

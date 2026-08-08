import UIKit

// Renders the canvas background — either ruled lines (default) or PDF page images.
// Placed behind PKCanvasView; kept full-screen and redraws on each scroll/zoom tick.
final class JotBackgroundView: UIView {

    enum Content {
        case ruled(pageSize: CGSize, extraPages: Int)
        case pdf(pages: [UIImage], pageSize: CGSize, extraPages: Int)
    }

    private static let pageSpacing: CGFloat = 24
    private static let ruledLineSpacing: CGFloat = 32

    private var content: Content = .ruled(pageSize: CGSize(width: 1200, height: 1600), extraPages: 0)
    private var scrollOffset: CGPoint = .zero
    private var zoomScale: CGFloat = 1
    private var pageImageViews: [UIImageView] = []
    private var usingImageViewsForPDF = false

    func configure(content: Content, scrollOffset: CGPoint, zoomScale: CGFloat) {
        self.content = content
        self.scrollOffset = scrollOffset
        self.zoomScale = zoomScale
        switch content {
        case .ruled:
            removePageImageViewsIfNeeded()
            usingImageViewsForPDF = false
            setNeedsDisplay()
        case let .pdf(pages, pageSize, _):
            ensurePageImageViews(match: pages)
            usingImageViewsForPDF = true
            layoutPageImageViews(pages: pages, pageSize: pageSize)
        }
    }

    func sync(scrollOffset: CGPoint, zoomScale: CGFloat) {
        self.scrollOffset = scrollOffset
        self.zoomScale = zoomScale
        if usingImageViewsForPDF {
            switch content {
            case let .pdf(pages, pageSize, _):
                layoutPageImageViews(pages: pages, pageSize: pageSize)
            default:
                break
            }
        } else {
            setNeedsDisplay()
        }
    }

    private func ensurePageImageViews(match pages: [UIImage]) {
        if pageImageViews.count < pages.count {
            for _ in pageImageViews.count..<pages.count {
                let iv = UIImageView()
                iv.contentMode = .scaleAspectFit
                iv.clipsToBounds = true
                addSubview(iv)
                pageImageViews.append(iv)
            }
        } else if pageImageViews.count > pages.count {
            for _ in pages.count..<pageImageViews.count {
                let iv = pageImageViews.removeLast()
                iv.removeFromSuperview()
            }
        }
    }

    private func removePageImageViewsIfNeeded() {
        guard !pageImageViews.isEmpty else { return }
        for iv in pageImageViews { iv.removeFromSuperview() }
        pageImageViews.removeAll()
    }

    private func layoutPageImageViews(pages: [UIImage], pageSize: CGSize) {
        let pageHeightPts = pageSize.height * zoomScale
        let spacingPts = Self.pageSpacing * zoomScale
        let totalPages = pages.count

        guard let visibleRange = visiblePageRange(totalPages: totalPages, pageHeightPts: pageHeightPts, spacingPts: spacingPts) else {
            for iv in pageImageViews { iv.isHidden = true }
            return
        }

        for index in 0..<pageImageViews.count {
            let iv = pageImageViews[index]
            if visibleRange.contains(index) {
                iv.isHidden = false
                let pageOriginY = CGFloat(index) * (pageHeightPts + spacingPts) - scrollOffset.y
                let pageRect = CGRect(x: 0, y: pageOriginY, width: bounds.width, height: pageHeightPts)
                iv.frame = pageRect
                if iv.image !== pages[index] {
                    iv.image = pages[index]
                }
                iv.layer.borderColor = UIColor.separator.withAlphaComponent(0.3).cgColor
                iv.layer.borderWidth = 0.5
            } else {
                iv.isHidden = true
            }
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        switch content {
        case let .ruled(pageSize, extraPages):
            drawRuled(context: context, pageSize: pageSize, extraPages: extraPages)
        case let .pdf(pages, pageSize, extraPages):
            drawPDF(context: context, pages: pages, pageSize: pageSize, extraPages: extraPages)
        }
    }

    // MARK: - Private

    private func visiblePageRange(totalPages: Int, pageHeightPts: CGFloat, spacingPts: CGFloat) -> ClosedRange<Int>? {
        guard totalPages > 0 else { return nil }
        let stride = pageHeightPts + spacingPts
        guard stride > 0 else { return nil }

        let minIndex = Int(floor((scrollOffset.y - pageHeightPts) / stride))
        let maxIndex = Int(floor((scrollOffset.y + bounds.height) / stride))

        let clampedMin = max(0, minIndex)
        let clampedMax = min(totalPages - 1, maxIndex)
        guard clampedMax >= clampedMin else { return nil }
        return clampedMin...clampedMax
    }

    private func drawRuled(context: CGContext, pageSize: CGSize, extraPages: Int) {
        let totalPages = 1 + extraPages
        let pageHeightPts = pageSize.height * zoomScale
        let spacingPts = Self.pageSpacing * zoomScale

        guard let visibleRange = visiblePageRange(
            totalPages: totalPages,
            pageHeightPts: pageHeightPts,
            spacingPts: spacingPts
        ) else { return }

        for page in visibleRange {
            let pageOriginY = CGFloat(page) * (pageHeightPts + spacingPts) - scrollOffset.y

            let pageRect = CGRect(x: 0, y: pageOriginY, width: bounds.width, height: pageHeightPts)

            UIColor.systemBackground.setFill()
            context.fill(pageRect)

            let lineColor = UIColor.separator.withAlphaComponent(0.6)
            lineColor.setStroke()
            context.setLineWidth(0.5)

            let lineSpacingPts = Self.ruledLineSpacing * zoomScale
            var lineY = pageOriginY + lineSpacingPts
            while lineY < pageOriginY + pageHeightPts {
                if lineY >= 0, lineY <= bounds.height {
                    context.move(to: CGPoint(x: 0, y: lineY))
                    context.addLine(to: CGPoint(x: bounds.width, y: lineY))
                    context.strokePath()
                }
                lineY += lineSpacingPts
            }

            drawPageBorder(context: context, rect: pageRect)
        }
    }

    private func drawPDF(context: CGContext, pages: [UIImage], pageSize: CGSize, extraPages: Int) {
        let pageHeightPts = pageSize.height * zoomScale
        let spacingPts = Self.pageSpacing * zoomScale

        let totalPages = pages.count + extraPages
        guard let visibleRange = visiblePageRange(
            totalPages: totalPages,
            pageHeightPts: pageHeightPts,
            spacingPts: spacingPts
        ) else { return }

        for pageIndex in visibleRange {
            if pageIndex < pages.count {
                let page = pages[pageIndex]
                let pageOriginY = CGFloat(pageIndex) * (pageHeightPts + spacingPts) - scrollOffset.y
                let pageRect = CGRect(x: 0, y: pageOriginY, width: bounds.width, height: pageHeightPts)

                UIColor.white.setFill()
                context.fill(pageRect)
                page.draw(in: pageRect)
                drawPageBorder(context: context, rect: pageRect)
            } else {
                drawBlankRuledPage(
                    context: context,
                    pageIndex: pageIndex,
                    pageSize: pageSize,
                    pageHeightPts: pageHeightPts,
                    spacingPts: spacingPts
                )
            }
        }
    }

    private func drawBlankRuledPage(
        context: CGContext,
        pageIndex: Int,
        pageSize: CGSize,
        pageHeightPts: CGFloat,
        spacingPts: CGFloat
    ) {
        let pageOriginY = CGFloat(pageIndex) * (pageHeightPts + spacingPts) - scrollOffset.y
        let pageRect = CGRect(x: 0, y: pageOriginY, width: bounds.width, height: pageHeightPts)
        guard pageRect.maxY >= 0, pageRect.minY <= bounds.height else { return }

        UIColor.systemBackground.setFill()
        context.fill(pageRect)

        UIColor.separator.withAlphaComponent(0.6).setStroke()
        context.setLineWidth(0.5)

        let lineSpacingPts = Self.ruledLineSpacing * zoomScale
        var lineY = pageOriginY + lineSpacingPts
        while lineY < pageOriginY + pageHeightPts {
            if lineY >= 0, lineY <= bounds.height {
                context.move(to: CGPoint(x: 0, y: lineY))
                context.addLine(to: CGPoint(x: bounds.width, y: lineY))
                context.strokePath()
            }
            lineY += lineSpacingPts
        }

        drawPageBorder(context: context, rect: pageRect)
    }

    private func drawPageBorder(context: CGContext, rect: CGRect) {
        UIColor.separator.withAlphaComponent(0.3).setStroke()
        context.setLineWidth(0.5)
        context.stroke(rect)
    }
}

import UIKit

/// PDFKit owns document zoom. This geometry separates requested native
/// PencilKit zoom from the normalized Drawing-to-page mapping and sizes only
/// the visible PencilKit viewport.
struct JotCanvasRenderGeometry: Equatable {
    let viewportSize: CGSize
    let canvasZoom: CGFloat
    let inversePageScale: CGAffineTransform
    let screenScale: CGFloat
    let drawingToPageScaleX: CGFloat
    let drawingToPageScaleY: CGFloat

    @MainActor
    static func displayRatio(
        pageSize: CGSize,
        displayedWidthVector: CGVector,
        displayedHeightVector: CGVector,
        pdfViewScaleFactor: CGFloat
    ) -> CGFloat {
        let pageWidth = max(pageSize.width, 1)
        let pageHeight = max(pageSize.height, 1)
        let ratio = max(
            hypot(displayedWidthVector.dx, displayedWidthVector.dy) / pageWidth,
            hypot(displayedHeightVector.dx, displayedHeightVector.dy) / pageHeight
        )
        return ratio.isFinite && ratio > 0 ? ratio : max(pdfViewScaleFactor, 0.01)
    }

    init?(pageSize: CGSize, drawingSize: CGSize, displayScale: CGFloat, screenScale: CGFloat) {
        guard
            [
                pageSize.width, pageSize.height, drawingSize.width, drawingSize.height,
                displayScale, screenScale,
            ].allSatisfy({ $0.isFinite && $0 > 0 })
        else { return nil }
        viewportSize = CGSize(width: pageSize.width * displayScale, height: pageSize.height * displayScale)
        canvasZoom = viewportSize.width / drawingSize.width
        guard viewportSize.width.isFinite, viewportSize.height.isFinite, canvasZoom.isFinite else { return nil }
        inversePageScale = CGAffineTransform(scaleX: 1 / displayScale, y: 1 / displayScale)
        self.screenScale = screenScale
        drawingToPageScaleX = drawingSize.width / pageSize.width
        drawingToPageScaleY = drawingSize.height / pageSize.height
    }

    func effectiveCanvasZoom(maximumZoomScale: CGFloat) -> CGFloat? {
        guard maximumZoomScale.isFinite, maximumZoomScale > 0 else { return nil }
        return min(canvasZoom, maximumZoomScale)
    }

    func viewportSize(for visiblePageRect: CGRect, nativeZoom: CGFloat) -> CGSize {
        CGSize(
            width: visiblePageRect.width * drawingToPageScaleX * nativeZoom,
            height: visiblePageRect.height * drawingToPageScaleY * nativeZoom
        )
    }

    func contentOffset(for visiblePageRect: CGRect, nativeZoom: CGFloat) -> CGPoint {
        CGPoint(
            x: visiblePageRect.minX * drawingToPageScaleX * nativeZoom,
            y: visiblePageRect.minY * drawingToPageScaleY * nativeZoom
        )
    }

    func viewportHostTransform(nativeZoom: CGFloat) -> CGAffineTransform {
        CGAffineTransform(
            scaleX: 1 / (drawingToPageScaleX * nativeZoom),
            y: 1 / (drawingToPageScaleY * nativeZoom)
        )
    }
}

enum JotPageLayout {
    static let defaultSize = CGSize(width: 1_200, height: 1_600)
    static let pageSpacing: CGFloat = 32
    static let ruledLineSpacing: CGFloat = 32
}

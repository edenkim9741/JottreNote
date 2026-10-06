@preconcurrency import PencilKit
import CoreGraphics

enum JotPageCanvasCoordinateAdapter {

    static func localDrawing(
        from drawing: PKDrawing,
        pageIndices: [Int],
        pageIndex: Int,
        overlaySize: CGSize,
        normalizedPageSize: CGSize,
        pageSpacing: CGFloat
    ) -> PKDrawing {
        guard overlaySize.width > 0, overlaySize.height > 0,
              normalizedPageSize.width > 0, normalizedPageSize.height > 0 else { return PKDrawing() }
        let sx = overlaySize.width / normalizedPageSize.width
        let sy = overlaySize.height / normalizedPageSize.height
        let pageStride = normalizedPageSize.height + pageSpacing
        let top = CGFloat(pageIndex) * pageStride
        let transform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: -top * sy)
        return PKDrawing(strokes: drawing.strokes.enumerated().compactMap { index, stroke in
            let owner = pageIndices.indices.contains(index) ? pageIndices[index] : 0
            guard owner == pageIndex else { return nil }
            return PKStroke(
                ink: stroke.ink,
                path: stroke.path,
                transform: stroke.transform.concatenating(transform),
                mask: stroke.mask
            )
        })
    }

    static func documentDrawing(
        from localDrawing: PKDrawing,
        pageIndex: Int,
        overlaySize: CGSize,
        normalizedPageSize: CGSize,
        pageSpacing: CGFloat
    ) -> PKDrawing {
        guard overlaySize.width > 0, overlaySize.height > 0,
              normalizedPageSize.width > 0, normalizedPageSize.height > 0 else { return PKDrawing() }
        let sx = normalizedPageSize.width / overlaySize.width
        let sy = normalizedPageSize.height / overlaySize.height
        let pageStride = normalizedPageSize.height + pageSpacing
        let top = CGFloat(pageIndex) * pageStride
        let transform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: top)
        return PKDrawing(strokes: localDrawing.strokes.map { stroke in
            PKStroke(
                ink: stroke.ink,
                path: stroke.path,
                transform: stroke.transform.concatenating(transform),
                mask: stroke.mask
            )
        })
    }
}

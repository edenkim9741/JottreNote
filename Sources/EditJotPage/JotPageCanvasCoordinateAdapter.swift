@preconcurrency import PencilKit
import CoreGraphics
import UIKit

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
            return mappedStroke(stroke, using: transform)
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
            mappedStroke(stroke, using: transform)
        })
    }

    private static func mappedStroke(_ stroke: PKStroke, using pageTransform: CGAffineTransform) -> PKStroke {
        let transform = stroke.transform.concatenating(pageTransform)
        let sx = hypot(transform.a, transform.b)
        let sy = hypot(transform.c, transform.d)
        var result = stroke
        // Translation/rotation do not magnify PencilKit's rendered texture.
        // Preserve the path and brush state on this usual save/load path.
        if abs(sx - 1) < 0.00001, abs(sy - 1) < 0.00001,
           abs(transform.a * transform.c + transform.b * transform.d) < 0.00001 {
            result.transform = transform
            return result
        }
        // PKStroke.transform acts AFTER stroke rendering. Move scaling into
        // its vector control points instead, including point widths and masks.
        // This also restores drawings saved from old small-page canvases.
        // Preserve the interpolated curve when restoring a sparse path from
        // small PDF coordinates. Scaling only its original control points can
        // change PencilKit's smoothing at the larger coordinate density.
        let storedScale = max(hypot(stroke.transform.a, stroke.transform.b),
                              hypot(stroke.transform.c, stroke.transform.d))
        let sourcePoints = max(sx, sy) > 1.00001 && storedScale > 1.00001 && stroke.path.count > 1
            ? Array(stroke.path.interpolatedPoints(by: .distance(0.5)))
            : Array(stroke.path)
        let points = sourcePoints.map { point -> PKStrokePoint in
            let location = point.location.applying(transform)
            let size = CGSize(width: point.size.width * sx, height: point.size.height * sy)
            let direction = atan2(
                sin(point.azimuth) * transform.d + cos(point.azimuth) * transform.b,
                cos(point.azimuth) * transform.a + sin(point.azimuth) * transform.c
            )
            let azimuth = (direction + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
            if #available(iOS 27.0, *) {
                return PKStrokePoint(location: location, timeOffset: point.timeOffset, size: size,
                                     opacity: point.opacity, force: point.force, azimuth: azimuth,
                                     altitude: point.altitude, secondaryScale: point.secondaryScale,
                                     threshold: point.threshold, lateralJitter: point.lateralJitter)
            } else if #available(iOS 26.0, *) {
                return PKStrokePoint(location: location, timeOffset: point.timeOffset, size: size,
                                     opacity: point.opacity, force: point.force, azimuth: azimuth,
                                     altitude: point.altitude, secondaryScale: point.secondaryScale,
                                     threshold: point.threshold)
            }
            return PKStrokePoint(location: location, timeOffset: point.timeOffset, size: size,
                                 opacity: point.opacity, force: point.force, azimuth: azimuth,
                                 altitude: point.altitude, secondaryScale: point.secondaryScale)
        }
        result.path = PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate)
        result.transform = .identity
        if let mask = stroke.mask?.copy() as? UIBezierPath {
            mask.apply(transform)
            result.mask = mask
        }
        return result
    }
}

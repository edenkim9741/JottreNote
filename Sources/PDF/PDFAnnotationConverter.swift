import PDFKit
@preconcurrency import PencilKit
import UIKit

/// Converts the editor's top-left-origin canvas coordinates into PDF page
/// coordinates. The converter deliberately uses the page crop box rather than
/// the media box because PDFKit places annotations in page user space.
enum PDFAnnotationConverter {

    static let marker = "JottrenoteStroke"

    static func annotations(
        drawing: PKDrawing,
        strokePageIndices: [Int],
        canvasPageSize: CGSize,
        page: PDFPage,
        pageIndex: Int
    ) -> [PDFAnnotation] {
        guard canvasPageSize.width > 0, canvasPageSize.height > 0 else { return [] }
        let pageBounds = page.bounds(for: .cropBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return [] }

        let pageDisplaySize = displaySize(for: pageBounds, rotation: page.rotation)
        let scaleX = pageDisplaySize.width / canvasPageSize.width
        let scaleY = pageDisplaySize.height / canvasPageSize.height
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { return [] }

        return drawing.strokes.enumerated().compactMap { index, stroke -> PDFAnnotation? in
            let resolvedPageIndex = index < strokePageIndices.count
                ? strokePageIndices[index]
                : Int(floor(stroke.renderBounds.midY / canvasPageSize.height))
            guard resolvedPageIndex == pageIndex else { return nil }

            let path = UIBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let points = stroke.path.map { point in
                let location = point.location.applying(stroke.transform)
                return pdfPoint(
                    fromCanvasPoint: CGPoint(
                        x: location.x * scaleX,
                        y: (location.y - CGFloat(pageIndex) * canvasPageSize.height) * scaleY
                    ),
                    pageBounds: pageBounds,
                    rotation: page.rotation,
                    displaySize: pageDisplaySize
                )
            }

            guard let firstPoint = points.first else { return nil }
            path.move(to: firstPoint)
            if points.count > 1 {
                for index in 0..<(points.count - 1) {
                    let currentPoint = points[index]
                    let nextPoint = points[index + 1]
                    let midpoint = CGPoint(
                        x: (currentPoint.x + nextPoint.x) / 2,
                        y: (currentPoint.y + nextPoint.y) / 2
                    )
                    path.addQuadCurve(to: midpoint, controlPoint: currentPoint)
                }
                path.addQuadCurve(
                    to: points[points.count - 1],
                    controlPoint: points[points.count - 2]
                )
            }

            guard !path.isEmpty else { return nil }
            let lineWidth = max(0.1, (stroke.path.first?.size.width ?? 1) * scaleX)
            let padding = max(1, lineWidth * 1.5)
            let annotationBounds = path.bounds.insetBy(dx: -padding, dy: -padding)
            var localTransform = CGAffineTransform(
                translationX: -annotationBounds.minX,
                y: -annotationBounds.minY
            )
            guard let localCGPath = path.cgPath.copy(using: &localTransform) else { return nil }
            let localPath = UIBezierPath(cgPath: localCGPath)
            localPath.lineCapStyle = .round
            localPath.lineJoinStyle = .round
            var red = CGFloat.zero
            var green = CGFloat.zero
            var blue = CGFloat.zero
            var alpha = CGFloat.zero
            let hasRGBColor = stroke.ink.color.getRed(
                &red,
                green: &green,
                blue: &blue,
                alpha: &alpha
            )
            let annotation = PDFAnnotation(
                bounds: annotationBounds,
                forType: .ink,
                withProperties: nil
            )
            annotation.add(localPath)
            annotation.color = hasRGBColor
                ? UIColor(red: red, green: green, blue: blue, alpha: alpha)
                : .black
            annotation.contents = marker
            annotation.shouldDisplay = true
            annotation.shouldPrint = true
            let border = PDFBorder()
            border.lineWidth = lineWidth
            annotation.border = border
            return annotation
        }
    }

    static func displaySize(for pageBounds: CGRect, rotation: Int) -> CGSize {
        let normalizedRotation = ((rotation % 360) + 360) % 360
        if normalizedRotation == 90 || normalizedRotation == 270 {
            return CGSize(width: pageBounds.height, height: pageBounds.width)
        }
        return pageBounds.size
    }

    static func pdfPoint(
        fromCanvasPoint point: CGPoint,
        pageBounds: CGRect,
        rotation: Int,
        displaySize: CGSize
    ) -> CGPoint {
        let x = point.x
        let y = displaySize.height - point.y
        let normalizedRotation = ((rotation % 360) + 360) % 360

        switch normalizedRotation {
        case 90:
            return CGPoint(
                x: pageBounds.maxX - y,
                y: pageBounds.minY + x
            )
        case 180:
            return CGPoint(
                x: pageBounds.maxX - x,
                y: pageBounds.minY + y
            )
        case 270:
            return CGPoint(
                x: pageBounds.minX + y,
                y: pageBounds.maxY - x
            )
        default:
            return CGPoint(
                x: pageBounds.minX + x,
                y: pageBounds.minY + y
            )
        }
    }
}

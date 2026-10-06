import Foundation
import UIKit
@preconcurrency import PencilKit

enum JotHybridPDFBuilder {

    static func buildHybridPDF(jot: Jot, dirtyPageIndices: Set<Int>? = nil) throws -> Data {
        let drawing = try PKDrawing(data: jot.drawing)
        let basePDF = try jot.pdfData.map(HybridPDFManager.pdfData(in:)) ?? makeRuledPDF(
            pageSize: CGSize(width: jot.width, height: jot.width * (4.0 / 3.0)),
            pageCount: max(1, jot.extraPages + 1)
        )
        let aspectRatio = JotPDFMetadata(pdfData: basePDF)?.pageAspectRatio ?? (4.0 / 3.0)
        let canvasPageSize = CGSize(width: jot.width, height: jot.width * aspectRatio)
        let embeddedJot = Jot(
            version: jot.version,
            drawing: drawing.dataRepresentation(),
            width: jot.width,
            pdfData: nil,
            extraPages: jot.extraPages,
            pdfInsertedPageSlots: jot.pdfInsertedPageSlots,
            strokePageIndices: jot.strokePageIndices,
            trashedPages: jot.trashedPages,
            zoteroItemKey: jot.zoteroItemKey,
            zoteroFileName: jot.zoteroFileName
        )
        let jotData = try encodedJotData(embeddedJot)
        return try HybridPDFManager.saveWithPDFKitAnnotations(
            pdfData: basePDF,
            jotData: jotData,
            drawing: drawing,
            strokePageIndices: jot.strokePageIndices,
            canvasPageSize: canvasPageSize,
            dirtyPageIndices: dirtyPageIndices
        )
    }

    static func encodedJotData(_ jot: Jot) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(jot)
    }

    static func makeRuledPDF(pageSize: CGSize, pageCount: Int) throws -> Data {
        let pageBounds = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        return renderer.pdfData { rendererContext in
            for _ in 0..<pageCount {
                rendererContext.beginPage()
                let context = rendererContext.cgContext
                context.setFillColor(red: 0.99, green: 0.97, blue: 0.90, alpha: 1)
                context.fill(pageBounds)
                context.setStrokeColor(gray: 0.62, alpha: 0.55)
                context.setLineWidth(0.5)
                var lineY = pageBounds.minY + 32
                while lineY < pageBounds.maxY {
                    context.move(to: CGPoint(x: pageBounds.minX, y: lineY))
                    context.addLine(to: CGPoint(x: pageBounds.maxX, y: lineY))
                    context.strokePath()
                    lineY += 32
                }
            }
        }
    }
}

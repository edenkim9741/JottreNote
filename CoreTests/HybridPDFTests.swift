import PDFKit
@preconcurrency import PencilKit
import UIKit
import XCTest
@testable import Jottre

final class HybridPDFTests: XCTestCase {

    func testEmbeddedJotRoundTrip() throws {
        let pdf = try makePDF(pageSize: CGSize(width: 240, height: 320), rotation: 0)
        let jotData = Data("binary-jot-payload".utf8)

        let hybrid = try HybridPDFManager.embedJotPreservingSourcePDF(
            pdfData: pdf,
            jotData: jotData
        )

        XCTAssertEqual(HybridPDFManager.embeddedJotData(in: hybrid), jotData)
        XCTAssertEqual(HybridPDFManager.pdfData(in: hybrid), pdf)
        XCTAssertEqual(hybrid.prefix(pdf.count), pdf)
    }

    func testTrailerPayloadUsesBigEndianLengthAndHandlesEOFBytesInPayload() throws {
        let pdf = try makePDF(pageSize: CGSize(width: 240, height: 320), rotation: 0)
        let jotData = Data([0, 1, 2, 0x25, 0x25, 0x45, 0x4F, 0x46, 0x0A, 0xFF])
        let hybrid = try HybridPDFManager.embedJotPreservingSourcePDF(
            pdfData: pdf,
            jotData: jotData
        )
        let startMarker = Data("\n%%JOTTRENOTE_PAYLOAD_START%%\n".utf8)
        let lengthStart = pdf.count + startMarker.count
        let encodedLength = hybrid[lengthStart..<(lengthStart + 4)]

        XCTAssertEqual(Array(encodedLength), [0, 0, 0, UInt8(jotData.count)])
        XCTAssertEqual(HybridPDFManager.embeddedJotData(in: hybrid), jotData)
        XCTAssertEqual(HybridPDFManager.pdfData(in: hybrid), pdf)
        XCTAssertEqual(PDFDocument(data: hybrid)?.pageCount, 1)
    }

    func testRepeatedSaveExtractsMostRecentlyEmbeddedJotAndPreservesPages() throws {
        let pdf = try makePDF(pageSize: CGSize(width: 240, height: 320), rotation: 0)
        let firstPayload = Data("first-save".utf8)
        let secondPayload = Data("second-save".utf8)
        let latestPayload = Data("latest-save".utf8)
        let firstSave = try HybridPDFManager.embedJotPreservingSourcePDF(
            pdfData: pdf,
            jotData: firstPayload
        )
        let secondSave = try HybridPDFManager.embedJotPreservingSourcePDF(
            pdfData: firstSave,
            jotData: secondPayload
        )
        let thirdSave = try HybridPDFManager.embedJotPreservingSourcePDF(
            pdfData: secondSave,
            jotData: latestPayload
        )

        let extractedPayload = HybridPDFManager.embeddedJotData(in: thirdSave)
        XCTAssertEqual(
            extractedPayload,
            latestPayload,
            "Extracted payload base64: \(extractedPayload?.base64EncodedString() ?? "nil")"
        )
        XCTAssertEqual(HybridPDFManager.pdfData(in: thirdSave), pdf)
        XCTAssertEqual(thirdSave.count, pdf.count + "\n%%JOTTRENOTE_PAYLOAD_START%%\n".utf8.count + 4 + latestPayload.count + "\n%%JOTTRENOTE_PAYLOAD_END%%\n".utf8.count)
        let savedPage = try XCTUnwrap(PDFDocument(data: thirdSave)?.page(at: 0))
        XCTAssertEqual(PDFDocument(data: thirdSave)?.pageCount, 1)
        XCTAssertEqual(JotPDFMetadata(pdfData: thirdSave)?.pageCount, 1)
        let centerPixel = try pixel(
            in: savedPage.thumbnail(of: CGSize(width: 32, height: 32), for: .mediaBox),
            at: CGPoint(x: 16, y: 16)
        )
        XCTAssertGreaterThan(centerPixel.red, 200, "The original page artwork should survive repeated saves.")
        XCTAssertLessThan(centerPixel.green, 60)
        XCTAssertLessThan(centerPixel.blue, 60)
    }

    @MainActor
    func testSQLDFixtureRetainsRenderedPagesAfterHybridSave() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "SQLD-unlocked-fixture", withExtension: "pdf")
        )
        let sourcePDF = try Data(contentsOf: fixtureURL)
        let pdfLoader = PDFLoadService()
        let source = try pdfLoader.load(data: sourcePDF)
        let pageIndices = [0, source.pageCount / 2, source.pageCount - 1]
        let renderSize = CGSize(width: 224, height: 316)
        let sourceImages = try pageIndices.map { pageIndex in
            try XCTUnwrap(
                pdfLoader.renderPage(
                    from: source,
                    at: pageIndex,
                    targetSize: renderSize,
                    scale: 1
                )
            )
        }
        let drawing = PKDrawing(strokes: [makeStroke()])
        let jotData = try JotHybridPDFBuilder.encodedJotData(Jot(
            drawing: drawing.dataRepresentation(),
            width: 1200,
            pdfData: nil,
            extraPages: 0,
            pdfInsertedPageSlots: [],
            strokePageIndices: [0]
        ))
        let hybridPDF = try HybridPDFManager.embedJotPreservingSourcePDF(
            pdfData: sourcePDF,
            jotData: jotData
        )
        let saved = try pdfLoader.load(data: hybridPDF)
        XCTAssertEqual(saved.pageCount, source.pageCount)
        XCTAssertEqual(JotPDFMetadata(pdfData: hybridPDF)?.pageCount, source.pageCount)
        XCTAssertEqual(try HybridPDFManager.load(data: hybridPDF).drawing.strokes.count, 1)

        let savedImages = try pageIndices.map { pageIndex in
            try XCTUnwrap(
                pdfLoader.renderPage(
                    from: saved,
                    at: pageIndex,
                    targetSize: renderSize,
                    scale: 1
                )
            )
        }
        for (offset, pageIndex) in pageIndices.enumerated() {
            let original = try pixels(in: sourceImages[offset])
            let rewritten = try pixels(in: savedImages[offset])
            let differingPixels = differingPixelCount(original, rewritten)
            let comparedPixels = original.count / 4
            XCTAssertLessThanOrEqual(
                Double(differingPixels) / Double(comparedPixels),
                0.01,
                "Page \(pageIndex + 1) changed across save (\(differingPixels)/\(comparedPixels) pixels)."
            )
        }
    }

    func testEmbeddedJotPayloadRestoresDrawing() throws {
        let pdf = try makePDF(pageSize: CGSize(width: 240, height: 320), rotation: 0)
        let drawing = PKDrawing(strokes: [makeStroke()])
        let jot = Jot(
            drawing: drawing.dataRepresentation(),
            width: 1200,
            pdfData: nil,
            extraPages: 0,
            pdfInsertedPageSlots: [],
            strokePageIndices: [0]
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let jotData = try encoder.encode(jot)

        let hybrid = try HybridPDFManager.embedJotPreservingSourcePDF(
            pdfData: pdf,
            jotData: jotData
        )

        let loaded = try HybridPDFManager.load(data: hybrid)
        XCTAssertGreaterThan(PDFDocument(data: hybrid)?.pageCount ?? 0, 0)
        XCTAssertEqual(PDFDocument(data: hybrid)?.pageCount, PDFDocument(data: pdf)?.pageCount)
        XCTAssertEqual(loaded.jot.drawing, jot.drawing)
        XCTAssertEqual(loaded.drawing.strokes.count, drawing.strokes.count)
        XCTAssertEqual(loaded.drawing.strokes.first?.path.count, drawing.strokes.first?.path.count)
        XCTAssertEqual(loaded.drawing.strokes.first?.renderBounds, drawing.strokes.first?.renderBounds)
    }

    func testSavedJottrenoteInkAppearanceRendersInPDFExport() throws {
        let pdf = try makePDF(pageSize: CGSize(width: 240, height: 320), rotation: 0)
        let drawing = PKDrawing(strokes: [makeStroke()])
        let jotData = try JotHybridPDFBuilder.encodedJotData(Jot(
            drawing: drawing.dataRepresentation(),
            width: 1200,
            pdfData: nil,
            extraPages: 0,
            pdfInsertedPageSlots: [],
            strokePageIndices: [0]
        ))
        let hybrid = try HybridPDFManager.saveWithPDFKitAnnotations(
            pdfData: pdf,
            jotData: jotData,
            drawing: drawing,
            strokePageIndices: [0],
            canvasPageSize: CGSize(width: 1200, height: 1600)
        )
        let text = String(decoding: hybrid, as: UTF8.self)
        let marker = try XCTUnwrap(text.range(of: "JottrenoteStroke"))
        let start = text.index(marker.lowerBound, offsetBy: -300, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(marker.upperBound, offsetBy: 300, limitedBy: text.endIndex)
            ?? text.endIndex
        let annotationWindow = text[start..<end]

        XCTAssertTrue(annotationWindow.contains("/Subtype /Ink"))
        XCTAssertTrue(annotationWindow.contains("/AP"), "The exported annotation needs an appearance stream for viewers to render it.")
        XCTAssertFalse(text.contains("/Subtype /Image"), "The synthetic PDF export should keep the annotation appearance vector-based.")

        let sourcePage = try XCTUnwrap(PDFDocument(data: pdf)?.page(at: 0))
        let exportedPage = try XCTUnwrap(PDFDocument(data: hybrid)?.page(at: 0))
        let renderSize = CGSize(width: 240, height: 320)
        let sourceImage = sourcePage.thumbnail(of: renderSize, for: .mediaBox)
        let exportedImage = exportedPage.thumbnail(of: renderSize, for: .mediaBox)
        let changedPixels = differingPixelCount(
            try pixels(in: sourceImage),
            try pixels(in: exportedImage)
        )
        XCTAssertGreaterThan(changedPixels, 0, "The exported PDF rendering must include the ink appearance.")
    }

    func testCropOffsetAndRotationMapCanvasCornersToPageCoordinates() {
        let bounds = CGRect(x: 40, y: 70, width: 240, height: 320)
        let displaySize = PDFAnnotationConverter.displaySize(for: bounds, rotation: 90)

        XCTAssertEqual(
            PDFAnnotationConverter.pdfPoint(
                fromCanvasPoint: CGPoint(x: 0, y: 0),
                pageBounds: bounds,
                rotation: 90,
                displaySize: displaySize
            ),
            CGPoint(x: 40, y: 70)
        )
        XCTAssertEqual(
            PDFAnnotationConverter.pdfPoint(
                fromCanvasPoint: CGPoint(x: displaySize.width, y: displaySize.height),
                pageBounds: bounds,
                rotation: 90,
                displaySize: displaySize
            ),
            CGPoint(x: 280, y: 390)
        )
    }

    func testRotatedPageReceivesJottrenoteInkAnnotation() throws {
        let pdf = try makePDF(pageSize: CGSize(width: 240, height: 320), rotation: 90)
        let drawing = PKDrawing(strokes: [makeStroke()])
        let jotData = try JotHybridPDFBuilder.encodedJotData(Jot(
            drawing: drawing.dataRepresentation(),
            width: 1200,
            pdfData: nil,
            extraPages: 0,
            pdfInsertedPageSlots: [],
            strokePageIndices: [0]
        ))

        let hybrid = try HybridPDFManager.saveWithPDFKitAnnotations(
            pdfData: pdf,
            jotData: jotData,
            drawing: drawing,
            strokePageIndices: [0],
            canvasPageSize: CGSize(width: 320, height: 240)
        )

        let document = try XCTUnwrap(PDFDocument(data: hybrid))
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.annotations.filter { $0.contents == PDFAnnotationConverter.marker }.count, 1)
    }

    func testCropOffsetPageReceivesJottrenoteInkAnnotation() throws {
        let basePDF = try makePDF(pageSize: CGSize(width: 240, height: 320), rotation: 0)
        let sourceDocument = try XCTUnwrap(PDFDocument(data: basePDF))
        let sourcePage = try XCTUnwrap(sourceDocument.page(at: 0))
        sourcePage.setBounds(CGRect(x: 20, y: 30, width: 200, height: 280), for: .cropBox)
        let croppedPDF = try XCTUnwrap(sourceDocument.dataRepresentation())
        let drawing = PKDrawing(strokes: [makeStroke()])

        let jotData = try JotHybridPDFBuilder.encodedJotData(Jot(
            drawing: drawing.dataRepresentation(),
            width: 1200,
            pdfData: nil,
            extraPages: 0,
            pdfInsertedPageSlots: [],
            strokePageIndices: [0]
        ))
        let hybrid = try HybridPDFManager.saveWithPDFKitAnnotations(
            pdfData: croppedPDF,
            jotData: jotData,
            drawing: drawing,
            strokePageIndices: [0],
            canvasPageSize: CGSize(width: 1200, height: 1600)
        )

        let document = try XCTUnwrap(PDFDocument(data: hybrid))
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.bounds(for: .cropBox), CGRect(x: 20, y: 30, width: 200, height: 280))
        XCTAssertEqual(page.annotations.filter { $0.contents == PDFAnnotationConverter.marker }.count, 1)
    }

    private func makePDF(pageSize: CGSize, rotation: Int) throws -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            context.cgContext.setFillColor(UIColor.red.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: pageSize))
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        document.page(at: 0)?.rotation = rotation
        return try XCTUnwrap(document.dataRepresentation())
    }

    private func pixel(in image: UIImage, at point: CGPoint) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        let bytes = try pixels(in: image)
        let cgImage = try XCTUnwrap(image.cgImage)
        let bytesPerRow = cgImage.width * 4
        let x = min(cgImage.width - 1, max(0, Int(point.x / image.size.width * CGFloat(cgImage.width))))
        let y = min(cgImage.height - 1, max(0, Int(point.y / image.size.height * CGFloat(cgImage.height))))
        let offset = y * bytesPerRow + x * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    private func pixels(in image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let bytesPerRow = cgImage.width * 4
        var rgba = [UInt8](repeating: 0, count: cgImage.height * bytesPerRow)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress,
                width: cgImage.width,
                height: cgImage.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        return rgba
    }

    private func differingPixelCount(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        guard lhs.count == rhs.count else { return max(lhs.count, rhs.count) / 4 }
        return stride(from: 0, to: lhs.count, by: 4).filter { pixelOffset in
            lhs[pixelOffset] != rhs[pixelOffset] ||
                lhs[pixelOffset + 1] != rhs[pixelOffset + 1] ||
                lhs[pixelOffset + 2] != rhs[pixelOffset + 2]
        }.count
    }

    private func makeStroke() -> PKStroke {
        let firstPoint = PKStrokePoint(
            location: CGPoint(x: 40, y: 40),
            timeOffset: 0,
            size: CGSize(width: 4, height: 4),
            opacity: 1,
            force: 1,
            azimuth: 0,
            altitude: .pi / 2
        )
        let secondPoint = PKStrokePoint(
            location: CGPoint(x: 120, y: 100),
            timeOffset: 0.1,
            size: CGSize(width: 4, height: 4),
            opacity: 1,
            force: 1,
            azimuth: 0,
            altitude: .pi / 2
        )
        let thirdPoint = PKStrokePoint(
            location: CGPoint(x: 200, y: 60),
            timeOffset: 0.2,
            size: CGSize(width: 4, height: 4),
            opacity: 1,
            force: 1,
            azimuth: 0,
            altitude: .pi / 2
        )
        let path = PKStrokePath(
            controlPoints: [firstPoint, secondPoint, thirdPoint],
            creationDate: Date()
        )
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }
}

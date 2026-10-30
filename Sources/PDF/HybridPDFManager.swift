import CoreGraphics
import CryptoKit
import Foundation
import PDFKit
@preconcurrency import PencilKit

struct HybridPDFDocument: Sendable {
    let pdfData: Data
    let jotData: Data
    let jot: Jot
    let drawing: PKDrawing
}

enum HybridPDFManager {

    static let payloadStartMarker = Data("\n%%JOTTRENOTE_PAYLOAD_START%%\n".utf8)
    static let payloadEndMarker = Data("\n%%JOTTRENOTE_PAYLOAD_END%%\n".utf8)

    enum Failure: Error {
        case invalidPDF
        case embeddedJotNotFound
        case malformedEmbeddedFile
        case invalidDrawing
        case annotationNotRetained
    }

    static func load(data: Data) throws -> HybridPDFDocument {
        let sourcePDF = try EmbeddedFileStore.pdfData(from: data)
        guard let document = PDFDocument(data: sourcePDF), document.pageCount > 0 else {
            throw Failure.invalidPDF
        }
        let jotData = try EmbeddedFileStore.extract(from: data)
        let jot = try PropertyListDecoder().decode(Jot.self, from: jotData)
        guard let drawing = try? PKDrawing(data: jot.drawing) else {
            throw Failure.invalidDrawing
        }
        return HybridPDFDocument(pdfData: sourcePDF, jotData: jotData, jot: jot, drawing: drawing)
    }

    static func embeddedJotData(in data: Data) -> Data? {
        try? EmbeddedFileStore.extract(from: data)
    }

    static func materializePages(
        pdfData: Data?,
        insertedPageSlots: [Int],
        blankPageCount: Int = 0,
        pageSize: CGSize
    ) throws -> Data {
        guard let pdfData else {
            return try JotHybridPDFBuilder.makeRuledPDF(
                pageSize: pageSize,
                pageCount: max(1, insertedPageSlots.count + max(0, blankPageCount) + 1)
            )
        }
        let cleanPDF = Self.pdfData(in: pdfData)
        guard let source = PDFDocument(data: cleanPDF), source.pageCount > 0 else {
            throw Failure.invalidPDF
        }
        var result = cleanPDF
        for slot in Array(Set(insertedPageSlots)).sorted() {
            let ruledPage = try JotHybridPDFBuilder.makeRuledPDF(pageSize: pageSize, pageCount: 1)
            result = try insertingPage(ruledPage, into: result, at: slot)
        }
        return result
    }

    static func pageData(_ pageIndex: Int, in pdfData: Data) throws -> Data {
        let cleanPDF = Self.pdfData(in: pdfData)
        guard let source = PDFDocument(data: cleanPDF),
              source.pageCount > pageIndex, pageIndex >= 0,
              let page = source.page(at: pageIndex) else {
            throw Failure.invalidPDF
        }
        let singlePage = PDFDocument()
        singlePage.insert(page.copy() as? PDFPage ?? page, at: 0)
        guard let result = singlePage.dataRepresentation() else { throw Failure.invalidPDF }
        return result
    }

    /// Returns the page's displayed MediaBox size, accounting for page rotation.
    /// This is the coordinate size used when creating a matching inserted page.
    static func displayedMediaBoxSize(in pdfData: Data, pageIndex: Int) throws -> CGSize {
        let cleanPDF = Self.pdfData(in: pdfData)
        guard let document = PDFDocument(data: cleanPDF),
              pageIndex >= 0, pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else {
            throw Failure.invalidPDF
        }
        let mediaBox = page.bounds(for: .mediaBox)
        guard mediaBox.width.isFinite, mediaBox.height.isFinite,
              mediaBox.width > 0, mediaBox.height > 0 else {
            throw Failure.invalidPDF
        }
        let rotation = ((page.rotation % 360) + 360) % 360
        if rotation == 90 || rotation == 270 {
            return CGSize(width: mediaBox.height, height: mediaBox.width)
        }
        return mediaBox.size
    }

    static func removingPage(_ pageIndex: Int, from pdfData: Data) throws -> Data {
        let cleanPDF = Self.pdfData(in: pdfData)
        guard let document = PDFDocument(data: cleanPDF),
              document.pageCount > 1,
              pageIndex >= 0, pageIndex < document.pageCount else {
            throw Failure.invalidPDF
        }
        document.removePage(at: pageIndex)
        guard let result = document.dataRepresentation(),
              PDFDocument(data: result)?.pageCount == document.pageCount else {
            throw Failure.invalidPDF
        }
        return result
    }

    static func insertingPage(_ pagePDFData: Data, into pdfData: Data, at index: Int) throws -> Data {
        let cleanPDF = Self.pdfData(in: pdfData)
        guard let document = PDFDocument(data: cleanPDF), document.pageCount > 0,
              let pageDocument = PDFDocument(data: Self.pdfData(in: pagePDFData)),
              let page = pageDocument.page(at: 0) else {
            throw Failure.invalidPDF
        }
        document.insert(page.copy() as? PDFPage ?? page, at: min(max(0, index), document.pageCount))
        guard let result = document.dataRepresentation(),
              PDFDocument(data: result)?.pageCount == document.pageCount else {
            throw Failure.invalidPDF
        }
        return result
    }

    /// Returns the original PDF unchanged when it has no Jottre trailer.
    static func pdfData(in data: Data) -> Data {
        (try? EmbeddedFileStore.pdfData(from: data)) ?? data
    }

    static func embedJotPreservingSourcePDF(pdfData: Data, jotData: Data) throws -> Data {
        let sourcePDF = try EmbeddedFileStore.pdfData(from: pdfData)
        guard let sourceDocument = PDFDocument(data: sourcePDF), sourceDocument.pageCount > 0 else {
            throw Failure.invalidPDF
        }
        let hybrid = try EmbeddedFileStore.replacing(data: jotData, in: sourcePDF)
        // PDFKit may report an incomplete page tree when a Jot trailer follows
        // %%EOF. Validate the PDF portion only, while preserving the complete
        // hybrid bytes for storage.
        let savedPDF = Self.pdfData(in: hybrid)
        guard let savedDocument = PDFDocument(data: savedPDF),
              savedDocument.pageCount == sourceDocument.pageCount,
              let provider = CGDataProvider(data: savedPDF as CFData),
              let coreGraphicsDocument = CGPDFDocument(provider),
              coreGraphicsDocument.numberOfPages == sourceDocument.pageCount else {
            throw Failure.invalidPDF
        }
        return hybrid
    }

    /// Serializes native PDF Ink annotations and appends the Jot payload after %%EOF.
    static func saveWithPDFKitAnnotations(
        pdfData: Data,
        jotData: Data,
        drawing: PKDrawing,
        strokePageIndices: [Int],
        canvasPageSize: CGSize,
        canvasPageSpacing: CGFloat = 0,
        dirtyPageIndices: Set<Int>? = nil
    ) throws -> Data {
        guard canvasPageSize.width.isFinite, canvasPageSize.width > 0,
              canvasPageSize.height.isFinite, canvasPageSize.height > 0,
              canvasPageSpacing.isFinite, canvasPageSpacing >= 0 else {
            throw Failure.invalidDrawing
        }
        let canvasPageStride = canvasPageSize.height + canvasPageSpacing
        guard canvasPageStride.isFinite, canvasPageStride > 0 else { throw Failure.invalidDrawing }
        let cleanPDF = try EmbeddedFileStore.pdfData(from: pdfData)
        let saveStarted = ContinuousClock.now
        JottreDiagnostics.shared.recordPDFSaveStage("started", byteCount: cleanPDF.count)
        JottreDiagnostics.shared.sampleMemoryNow(for: "pdf.save.before")
        guard var document = PDFDocument(data: cleanPDF), document.pageCount > 0 else {
            throw Failure.invalidPDF
        }
        if !document.allowsCommenting {
            guard let writablePDF = makeVectorPDFCopy(of: document),
                  let writableDocument = PDFDocument(data: writablePDF),
                  writableDocument.pageCount == document.pageCount else {
                throw Failure.annotationNotRetained
            }
            document = writableDocument
        }
        let allPageIndices = Set(0..<document.pageCount)
        var pagesToUpdate = dirtyPageIndices.map { $0.intersection(allPageIndices) } ?? allPageIndices
        if dirtyPageIndices != nil {
            var pagesWithDrawing = Set<Int>()
            for (strokeIndex, stroke) in drawing.strokes.enumerated() {
                let pageIndex = strokePageIndices.indices.contains(strokeIndex)
                    ? strokePageIndices[strokeIndex]
                    : Int(floor(stroke.renderBounds.midY / canvasPageStride))
                pagesWithDrawing.insert(pageIndex)
            }
            // Older/base PDFs may not yet contain any Jottre annotations.
            // Seed only those pages once; later saves can update the dirty pages.
            for pageIndex in pagesWithDrawing where allPageIndices.contains(pageIndex) {
                guard let page = document.page(at: pageIndex) else { continue }
                let hasStoredInk = page.annotations.contains { $0.contents == PDFAnnotationConverter.marker }
                if !hasStoredInk { pagesToUpdate.insert(pageIndex) }
            }
        }
        removeJottrenoteAnnotations(from: document, pageIndices: pagesToUpdate)

        var expectedCount = 0
        for pageIndex in 0..<document.pageCount where !pagesToUpdate.contains(pageIndex) {
            expectedCount += document.page(at: pageIndex)?.annotations.filter {
                $0.contents == PDFAnnotationConverter.marker
            }.count ?? 0
        }
        for pageIndex in pagesToUpdate.sorted() {
            guard let page = document.page(at: pageIndex) else { throw Failure.invalidPDF }
            let annotations = PDFAnnotationConverter.annotations(
                drawing: drawing,
                strokePageIndices: strokePageIndices,
                canvasPageSize: canvasPageSize,
                canvasPageSpacing: canvasPageSpacing,
                page: page,
                pageIndex: pageIndex
            )
            expectedCount += annotations.count
            annotations.forEach(page.addAnnotation)
            let attachedCount = page.annotations.filter {
                $0.contents == PDFAnnotationConverter.marker
            }.count
            guard attachedCount >= annotations.count else { throw Failure.annotationNotRetained }
        }

        let serializationStarted = ContinuousClock.now
        guard let serializedPDF = document.dataRepresentation() else { throw Failure.invalidPDF }
        JottreDiagnostics.shared.recordPDFSaveStage(
            "pdfkitSerialized",
            durationMilliseconds: JottreDiagnostics.milliseconds(serializationStarted.duration(to: .now)),
            byteCount: serializedPDF.count
        )
        let normalizationStarted = ContinuousClock.now
        let annotatedPDF = canonicalizeDocumentIdentifier(in: serializedPDF)
        JottreDiagnostics.shared.recordPDFSaveStage(
            "identifierNormalized",
            durationMilliseconds: JottreDiagnostics.milliseconds(normalizationStarted.duration(to: .now)),
            byteCount: annotatedPDF.count
        )
        let embeddingStarted = ContinuousClock.now
        let hybrid = try EmbeddedFileStore.replacing(data: jotData, in: annotatedPDF)
        JottreDiagnostics.shared.recordPDFSaveStage(
            "jotEmbedded",
            durationMilliseconds: JottreDiagnostics.milliseconds(embeddingStarted.duration(to: .now)),
            byteCount: hybrid.count
        )
        guard let savedDocument = PDFDocument(data: HybridPDFManager.pdfData(in: hybrid)),
              savedDocument.pageCount == document.pageCount else {
            throw Failure.invalidPDF
        }
        let savedAnnotationCount = (0..<savedDocument.pageCount).reduce(into: 0) { total, pageIndex in
            total += savedDocument.page(at: pageIndex)?.annotations.filter {
                $0.contents == PDFAnnotationConverter.marker
            }.count ?? 0
        }
        guard savedAnnotationCount == expectedCount else { throw Failure.annotationNotRetained }
        JottreDiagnostics.shared.recordPDFSaveStage(
            "completed",
            durationMilliseconds: JottreDiagnostics.milliseconds(saveStarted.duration(to: .now)),
            byteCount: hybrid.count
        )
        JottreDiagnostics.shared.sampleMemoryNow(for: "pdf.save.after")
        return hybrid
    }

    private static func removeJottrenoteAnnotations(from document: PDFDocument, pageIndices: Set<Int>) {
        for pageIndex in pageIndices {
            guard let page = document.page(at: pageIndex) else { continue }
            page.annotations
                .filter { $0.contents == PDFAnnotationConverter.marker }
                .forEach(page.removeAnnotation)
        }
    }

    /// Rebuilds pages into an unencrypted PDF content stream when the source
    /// explicitly denies annotation changes. Quartz copies the source page
    /// operators directly into a new PDF context; no page or ink bitmap is made.
    private static func makeVectorPDFCopy(of document: PDFDocument) -> Data? {
        guard document.pageCount > 0,
              let firstPage = document.page(at: 0)?.pageRef else { return nil }
        var firstMediaBox = firstPage.getBoxRect(.mediaBox)
        let outputData = NSMutableData()
        guard let consumer = CGDataConsumer(data: outputData),
              let context = CGContext(consumer: consumer, mediaBox: &firstMediaBox, nil) else { return nil }

        for pageIndex in 0..<document.pageCount {
            guard let pageRef = document.page(at: pageIndex)?.pageRef else { continue }
            let mediaBox = pageRef.getBoxRect(.mediaBox)
            var pageInfo: [CFString: Any] = [kCGPDFContextMediaBox: mediaBox]
            pageInfo[kCGPDFContextCropBox] = pageRef.getBoxRect(.cropBox)
            context.beginPDFPage(pageInfo as CFDictionary)
            context.saveGState()
            let transform = pageRef.getDrawingTransform(.mediaBox, rect: mediaBox, rotate: 0, preserveAspectRatio: false)
            context.concatenate(transform)
            context.drawPDFPage(pageRef)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return outputData as Data
    }

    /// PDFKit generates a random trailer /ID each time it serializes an unchanged
    /// document. Normalize that identifier so export and backup produce the same
    /// bytes for the same source PDF and Jot state. Both identifiers remain
    /// content-derived and the replacement preserves the original byte length.
    /// Mutate a single copy-on-write Data buffer instead of materializing multiple
    /// whole-PDF byte arrays during large document saves.
    private static func canonicalizeDocumentIdentifier(in data: Data) -> Data {
        let token = Data("/ID".utf8)
        guard let tokenRange = data.range(of: token, options: .backwards) else { return data }

        func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x00 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
        }
        var cursor = tokenRange.upperBound
        while cursor < data.endIndex, isWhitespace(data[cursor]) { cursor = data.index(after: cursor) }
        guard cursor < data.endIndex, data[cursor] == 0x5B else { return data }
        cursor = data.index(after: cursor)

        func nextHexRange(in bytes: Data, cursor: inout Data.Index) -> Range<Data.Index>? {
            while cursor < bytes.endIndex, isWhitespace(bytes[cursor]) { cursor = bytes.index(after: cursor) }
            guard cursor < bytes.endIndex, bytes[cursor] == 0x3C else { return nil }
            cursor = bytes.index(after: cursor)
            let start = cursor
            while cursor < bytes.endIndex, bytes[cursor] != 0x3E {
                let byte = bytes[cursor]
                let isHex = (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
                guard isHex else { return nil }
                cursor = bytes.index(after: cursor)
            }
            guard cursor < bytes.endIndex else { return nil }
            let range = start..<cursor
            cursor = bytes.index(after: cursor)
            return range
        }

        guard let firstID = nextHexRange(in: data, cursor: &cursor),
              let secondID = nextHexRange(in: data, cursor: &cursor),
              data.distance(from: firstID.lowerBound, to: firstID.upperBound)
                == data.distance(from: secondID.lowerBound, to: secondID.upperBound),
              data.distance(from: firstID.lowerBound, to: firstID.upperBound) >= 32,
              data.distance(from: firstID.lowerBound, to: firstID.upperBound).isMultiple(of: 2) else { return data }

        let idLength = data.distance(from: firstID.lowerBound, to: firstID.upperBound)
        var normalized = data
        for range in [firstID, secondID] {
            var index = range.lowerBound
            while index < range.upperBound {
                normalized[index] = 0x30
                index = normalized.index(after: index)
            }
        }
        let digest = SHA256.hash(data: normalized)
        let hex = Array("0123456789abcdef".utf8)
        var identifier: [UInt8] = []
        identifier.reserveCapacity(idLength)
        for byte in digest.prefix(idLength / 2) {
            identifier.append(hex[Int(byte >> 4)])
            identifier.append(hex[Int(byte & 0x0F)])
        }
        for range in [firstID, secondID] {
            var index = range.lowerBound
            for byte in identifier {
                normalized[index] = byte
                index = normalized.index(after: index)
            }
        }
        return normalized
    }
}

private enum EmbeddedFileStore {

    static func pdfData(from data: Data) throws -> Data {
        try trailerPayload(in: data)?.pdfData ?? data
    }

    static func extract(from data: Data) throws -> Data {
        guard let payload = try trailerPayload(in: data) else {
            throw HybridPDFManager.Failure.embeddedJotNotFound
        }
        return payload.jotData
    }

    static func replacing(data: Data, in pdf: Data) throws -> Data {
        guard data.count <= Int(UInt32.max) else {
            throw HybridPDFManager.Failure.malformedEmbeddedFile
        }
        let sourcePDF = try pdfData(from: pdf)
        var hybrid = sourcePDF
        hybrid.append(HybridPDFManager.payloadStartMarker)
        var bigEndianLength = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &bigEndianLength) { hybrid.append(contentsOf: $0) }
        hybrid.append(data)
        hybrid.append(HybridPDFManager.payloadEndMarker)
        return hybrid
    }

    private static func trailerPayload(in data: Data) throws -> (pdfData: Data, jotData: Data)? {
        let endMarker = HybridPDFManager.payloadEndMarker
        guard data.count >= endMarker.count,
              data.suffix(endMarker.count) == endMarker else { return nil }

        let payloadEnd = data.endIndex - endMarker.count
        guard let startMarker = data.range(
            of: HybridPDFManager.payloadStartMarker,
            options: .backwards,
            in: data.startIndex..<payloadEnd
        ) else {
            throw HybridPDFManager.Failure.malformedEmbeddedFile
        }
        let lengthStart = startMarker.upperBound
        let lengthEnd = lengthStart + MemoryLayout<UInt32>.size
        guard lengthEnd <= payloadEnd else { throw HybridPDFManager.Failure.malformedEmbeddedFile }
        let payloadLength = data[lengthStart..<lengthEnd].reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        let payloadStart = lengthEnd
        guard Int(payloadLength) == payloadEnd - payloadStart else {
            throw HybridPDFManager.Failure.malformedEmbeddedFile
        }
        return (
            Data(data[data.startIndex..<startMarker.lowerBound]),
            Data(data[payloadStart..<payloadEnd])
        )
    }
}

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

    func testInsertedBlankPageUsesMatchingMediaBoxAndRotation() throws {
        let landscape = try makePDF(pageSize: CGSize(width: 640, height: 360), rotation: 0)
        let expectedLandscape = try HybridPDFManager.displayedMediaBoxSize(
            in: landscape,
            pageIndex: 0
        )
        XCTAssertEqual(expectedLandscape, CGSize(width: 640, height: 360))

        let rotated = try makePDF(pageSize: CGSize(width: 640, height: 360), rotation: 90)
        let expectedRotated = try HybridPDFManager.displayedMediaBoxSize(
            in: rotated,
            pageIndex: 0
        )
        XCTAssertEqual(expectedRotated, CGSize(width: 360, height: 640))

        let blank = try JotHybridPDFBuilder.makeRuledPDF(pageSize: expectedRotated, pageCount: 1)
        let inserted = try HybridPDFManager.insertingPage(blank, into: rotated, at: 1)
        XCTAssertEqual(
            try HybridPDFManager.displayedMediaBoxSize(in: inserted, pageIndex: 1),
            expectedRotated
        )
    }

    func testPageOverlayDrawingRoundTripsThroughDocumentCoordinates() throws {
        let normalizedPageSize = CGSize(width: 1200, height: 1600)
        let overlaySize = CGSize(width: 640, height: 360)
        let spacing = JotBackgroundView.pageSpacing
        let sourceStroke = makeStroke()
        let pageIndex = 2
        let documentStroke = PKStroke(
            ink: sourceStroke.ink,
            path: sourceStroke.path,
            transform: sourceStroke.transform.translatedBy(
                x: 0,
                y: CGFloat(pageIndex) * (normalizedPageSize.height + spacing)
            ),
            mask: sourceStroke.mask
        )
        let documentDrawing = PKDrawing(strokes: [documentStroke])

        let pageDrawing = JotPageCanvasCoordinateAdapter.localDrawing(
            from: documentDrawing,
            pageIndices: [pageIndex],
            pageIndex: pageIndex,
            overlaySize: overlaySize,
            normalizedPageSize: normalizedPageSize,
            pageSpacing: spacing
        )
        let roundTripped = JotPageCanvasCoordinateAdapter.documentDrawing(
            from: pageDrawing,
            pageIndex: pageIndex,
            overlaySize: overlaySize,
            normalizedPageSize: normalizedPageSize,
            pageSpacing: spacing
        )

        XCTAssertEqual(pageDrawing.strokes.count, 1)
        XCTAssertEqual(roundTripped.strokes.count, 1)
        let expected = try XCTUnwrap(documentDrawing.strokes.first).renderBounds
        let actual = try XCTUnwrap(roundTripped.strokes.first).renderBounds
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.01)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.01)
        XCTAssertEqual(actual.maxX, expected.maxX, accuracy: 0.01)
        XCTAssertEqual(actual.maxY, expected.maxY, accuracy: 0.01)
    }

    @MainActor
    func testPDFTestFixtureRetainsRenderedPagesAfterHybridSave() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "pdf-test", withExtension: "pdf")
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

    func testPageRemovalAndRestorePreserveVectorPageAndTrashPayload() throws {
        let source = try makeTwoPagePDF()
        let inserted = try HybridPDFManager.materializePages(
            pdfData: source,
            insertedPageSlots: [1],
            pageSize: CGSize(width: 240, height: 320)
        )
        let insertedDocument = try XCTUnwrap(PDFDocument(data: inserted))
        XCTAssertEqual(insertedDocument.pageCount, 3)

        let pageToTrash = try HybridPDFManager.pageData(1, in: inserted)
        let trashedDrawing = PKDrawing(strokes: [makeStroke()])
        let trashedPage = TrashedPage(
            originalIndex: 1,
            pdfPageData: pageToTrash,
            drawingData: trashedDrawing.dataRepresentation()
        )
        let encoded = try JotHybridPDFBuilder.encodedJotData(Jot(
            drawing: PKDrawing().dataRepresentation(),
            width: 1200,
            trashedPages: [trashedPage]
        ))
        let restoredTrash = try PropertyListDecoder().decode(Jot.self, from: encoded).trashedPages
        XCTAssertEqual(restoredTrash, [trashedPage])

        let reduced = try HybridPDFManager.removingPage(1, from: inserted)
        let reducedDocument = try XCTUnwrap(PDFDocument(data: reduced))
        XCTAssertEqual(reducedDocument.pageCount, 2)
        let remainingFirstPixel = try pixel(
            in: try XCTUnwrap(reducedDocument.page(at: 0))
                .thumbnail(of: CGSize(width: 32, height: 32), for: .mediaBox),
            at: CGPoint(x: 16, y: 16)
        )
        let remainingSecondPixel = try pixel(
            in: try XCTUnwrap(reducedDocument.page(at: 1))
                .thumbnail(of: CGSize(width: 32, height: 32), for: .mediaBox),
            at: CGPoint(x: 16, y: 16)
        )
        XCTAssertGreaterThan(remainingFirstPixel.red, remainingFirstPixel.blue)
        XCTAssertGreaterThan(remainingSecondPixel.blue, remainingSecondPixel.red)

        let saved = try JotHybridPDFBuilder.buildHybridPDF(jot: Jot(
            drawing: PKDrawing().dataRepresentation(),
            width: 1200,
            pdfData: reduced,
            trashedPages: restoredTrash
        ))
        let savedPDF = try XCTUnwrap(PDFDocument(data: HybridPDFManager.pdfData(in: saved)))
        XCTAssertEqual(savedPDF.pageCount, 2)
        let uploadedFirstPixel = try pixel(
            in: try XCTUnwrap(savedPDF.page(at: 0))
                .thumbnail(of: CGSize(width: 32, height: 32), for: .mediaBox),
            at: CGPoint(x: 16, y: 16)
        )
        let uploadedSecondPixel = try pixel(
            in: try XCTUnwrap(savedPDF.page(at: 1))
                .thumbnail(of: CGSize(width: 32, height: 32), for: .mediaBox),
            at: CGPoint(x: 16, y: 16)
        )
        XCTAssertGreaterThan(uploadedFirstPixel.red, uploadedFirstPixel.blue)
        XCTAssertGreaterThan(uploadedSecondPixel.blue, uploadedSecondPixel.red)

        let restored = try HybridPDFManager.insertingPage(
            restoredTrash[0].pdfPageData,
            into: reduced,
            at: restoredTrash[0].originalIndex
        )
        let restoredDocument = try XCTUnwrap(PDFDocument(data: restored))
        XCTAssertEqual(restoredDocument.pageCount, 3)
        XCTAssertEqual(
            try pixels(in: try XCTUnwrap(insertedDocument.page(at: 1))
                .thumbnail(of: CGSize(width: 80, height: 100), for: .mediaBox)),
            try pixels(in: try XCTUnwrap(restoredDocument.page(at: 1))
                .thumbnail(of: CGSize(width: 80, height: 100), for: .mediaBox))
        )
        XCTAssertEqual(try PKDrawing(data: restoredTrash[0].drawingData).strokes.count, 1)
    }

    func testDeletingPageFromBlankNotePersistsRemainingPagesAndTrash() throws {
        let pageSize = CGSize(width: 1200, height: 1600)
        let fullBlankNote = try HybridPDFManager.materializePages(
            pdfData: nil,
            insertedPageSlots: [],
            blankPageCount: 3,
            pageSize: pageSize
        )
        XCTAssertEqual(PDFDocument(data: fullBlankNote)?.pageCount, 4)

        let deletedPage = try HybridPDFManager.pageData(2, in: fullBlankNote)
        let remainingPages = try HybridPDFManager.removingPage(2, from: fullBlankNote)
        let jot = Jot(
            drawing: PKDrawing().dataRepresentation(),
            width: pageSize.width,
            trashedPages: [TrashedPage(
                originalIndex: 2,
                pdfPageData: deletedPage,
                drawingData: PKDrawing().dataRepresentation()
            )]
        )
        let jotData = try JotHybridPDFBuilder.encodedJotData(jot)
        let saved = try HybridPDFManager.embedJotPreservingSourcePDF(
            pdfData: remainingPages,
            jotData: jotData
        )
        let restored = try HybridPDFManager.load(data: saved)

        XCTAssertEqual(PDFDocument(data: restored.pdfData)?.pageCount, 3)
        XCTAssertEqual(PDFDocument(data: HybridPDFManager.pdfData(in: saved))?.pageCount, 3)
        XCTAssertEqual(restored.jot.trashedPages.count, 1)
        XCTAssertEqual(restored.jot.trashedPages.first?.originalIndex, 2)
    }

    func testZoteroArchiveAfterPageDeletionKeepsRemainingPagesAndRestoresJotSidecar() throws {
        let source = try makeTwoPagePDF()
        let expanded = try HybridPDFManager.materializePages(
            pdfData: source,
            insertedPageSlots: [1],
            pageSize: CGSize(width: 240, height: 320)
        )
        let deletedPage = try HybridPDFManager.pageData(0, in: expanded)
        let remaining = try HybridPDFManager.removingPage(0, from: expanded)
        let jot = Jot(
            drawing: PKDrawing().dataRepresentation(),
            width: 1200,
            trashedPages: [TrashedPage(
                originalIndex: 0,
                pdfPageData: deletedPage,
                drawingData: PKDrawing().dataRepresentation()
            )]
        )
        let hybrid = try JotHybridPDFBuilder.buildHybridPDF(jot: Jot(
            drawing: jot.drawing,
            width: jot.width,
            pdfData: remaining,
            trashedPages: jot.trashedPages
        ))
        let archive = try ZoteroSyncService.archiveForTesting(documentID: "ABCD2345", data: hybrid)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let files = try ZoteroSyncService.extractArchiveForTesting(archive, to: directory)
        let pdfURL = try XCTUnwrap(files.first { $0.pathExtension.lowercased() == "pdf" })
        let desktopPDF = try Data(contentsOf: pdfURL)
        XCTAssertNil(HybridPDFManager.embeddedJotData(in: desktopPDF))
        XCTAssertEqual(PDFDocument(data: desktopPDF)?.pageCount, 2)
        let desktopDocument = try XCTUnwrap(PDFDocument(data: desktopPDF))
        let firstPixel = try pixel(
            in: try XCTUnwrap(desktopDocument.page(at: 0))
                .thumbnail(of: CGSize(width: 32, height: 32), for: .mediaBox),
            at: CGPoint(x: 16, y: 16)
        )
        let secondPixel = try pixel(
            in: try XCTUnwrap(desktopDocument.page(at: 1))
                .thumbnail(of: CGSize(width: 32, height: 32), for: .mediaBox),
            at: CGPoint(x: 16, y: 16)
        )
        XCTAssertGreaterThan(firstPixel.red, firstPixel.blue)
        XCTAssertGreaterThan(secondPixel.blue, secondPixel.red)

        let restored = try ZoteroSyncService.restoreHybridPDFForTesting(
            fromPDFAt: pdfURL,
            extractedFiles: files
        )
        let loaded = try HybridPDFManager.load(data: restored)
        XCTAssertEqual(PDFDocument(data: loaded.pdfData)?.pageCount, 2)
        XCTAssertEqual(loaded.jot.trashedPages, jot.trashedPages)
    }

    func testZoteroZipPDFRetainsVectorInkAnnotationsAndAllPages() throws {
        let sourcePDF = try makeTwoPagePDF()
        let firstStroke = makeStroke()
        let secondStroke = PKStroke(
            ink: firstStroke.ink,
            path: firstStroke.path,
            transform: CGAffineTransform(translationX: 0, y: 1600),
            mask: firstStroke.mask
        )
        let drawing = PKDrawing(strokes: [firstStroke, secondStroke])
        let jot = Jot(
            drawing: drawing.dataRepresentation(),
            width: 1200,
            pdfData: sourcePDF,
            strokePageIndices: [0, 1]
        )

        // Exercise the exact builder and ZIP split used by Zotero uploads, then
        // open only the PDF member as a desktop reader would.
        let hybridPDF = try JotHybridPDFBuilder.buildHybridPDF(jot: jot)
        let archive = try ZoteroSyncService.archiveForTesting(
            documentID: "ABCD2345",
            data: hybridPDF
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let files = try ZoteroSyncService.extractArchiveForTesting(archive, to: directory)
        let pdfURL = try XCTUnwrap(files.first { $0.pathExtension.lowercased() == "pdf" })
        XCTAssertTrue(files.contains { $0.lastPathComponent == "ABCD2345.pdf.jot" })
        let zipPDFData = try Data(contentsOf: pdfURL)
        XCTAssertNil(HybridPDFManager.embeddedJotData(in: zipPDFData), "The Zotero PDF member must be a clean, directly openable PDF.")

        let exportedPDF = try XCTUnwrap(PDFDocument(data: zipPDFData))
        let originalPDF = try XCTUnwrap(PDFDocument(data: sourcePDF))
        XCTAssertEqual(exportedPDF.pageCount, 2, "The standalone ZIP PDF must preserve the full page tree.")

        let exportedText = String(decoding: zipPDFData, as: UTF8.self)
        XCTAssertEqual(exportedText.components(separatedBy: PDFAnnotationConverter.marker).count - 1, 2)
        XCTAssertTrue(exportedText.contains("/Subtype /Ink"), "The ZIP PDF must serialize native vector Ink annotations.")

        for pageIndex in 0..<2 {
            let exportedPage = try XCTUnwrap(exportedPDF.page(at: pageIndex))
            let sourcePage = try XCTUnwrap(originalPDF.page(at: pageIndex))
            let inkAnnotations = exportedPage.annotations.filter {
                $0.type == "Ink" &&
                    $0.contents == PDFAnnotationConverter.marker
            }
            XCTAssertEqual(inkAnnotations.count, 1, "Page \(pageIndex) must retain its vector handwriting annotation.")

            let renderSize = CGSize(width: 240, height: 320)
            let sourceImage = sourcePage.thumbnail(of: renderSize, for: .mediaBox)
            let exportedImage = exportedPage.thumbnail(of: renderSize, for: .mediaBox)
            XCTAssertGreaterThan(
                differingPixelCount(try pixels(in: sourceImage), try pixels(in: exportedImage)),
                0,
                "Opening the standalone ZIP PDF must render the handwriting on page \(pageIndex)."
            )
        }
    }

    func testStaleUploadCompletionCannotOverwriteNewerEditedPDF() throws {
        let userID = "test-\(UUID().uuidString)"
        let keyAlphabet = Set("23456789ABCDEFGHIJKLMNPQRSTUVWXYZ")
        let attachmentKey = String(UUID().uuidString.uppercased().filter { keyAlphabet.contains($0) }.prefix(8))
        let store = ZoteroCacheStore()
        let originalPDF = Data("initial hybrid PDF".utf8)
        let editedPDF = Data("newer edited hybrid PDF".utf8)
        let item = ZoteroItem(
            key: "PARENT23",
            title: "Race Test",
            creators: [],
            year: nil,
            parentItemKey: nil,
            collectionKeys: [],
            itemType: "document",
            dateAdded: Date(),
            dateModified: Date(),
            version: 1,
            isTrashed: false
        )
        let attachment = ZoteroAttachment(
            key: attachmentKey,
            parentItemKey: item.key,
            contentType: "application/pdf",
            filename: "Race Test.pdf",
            localCachePath: nil,
            syncStatus: .dirty,
            version: 1,
            md5: nil,
            modificationTimeMilliseconds: nil
        )
        let localURL = try store.registerCreatedDocument(
            item: item,
            attachment: attachment,
            hybridPDF: originalPDF,
            libraryVersion: 1,
            userID: userID
        )
        _ = try store.saveEditedPDF(key: attachmentKey, data: editedPDF, userID: userID)

        let snapshot = try store.markSynced(key: attachmentKey, data: originalPDF, userID: userID)

        XCTAssertEqual(try Data(contentsOf: localURL), editedPDF)
        XCTAssertEqual(snapshot.attachments[attachmentKey]?.syncStatus, .dirty)
    }

    func testOfflineDraftSynchronizesAfterConnectivityReturns() async throws {
        let userID = "1234"
        let store = ZoteroCacheStore()
        let temporaryParentKey = "temp_\(UUID().uuidString)"
        let temporaryAttachmentKey = "temp_\(UUID().uuidString)"
        let emptyJot = Jot.makeEmpty()
        let item = ZoteroItem(
            key: temporaryParentKey,
            title: "Offline lecture notes",
            creators: ["Ada Lovelace"],
            year: nil,
            parentItemKey: nil,
            collectionKeys: [],
            itemType: "document",
            dateAdded: Date(),
            dateModified: Date(),
            version: 0,
            isTrashed: false,
            isPendingSync: true
        )
        let attachment = ZoteroAttachment(
            key: temporaryAttachmentKey,
            parentItemKey: temporaryParentKey,
            contentType: "application/pdf",
            filename: "Offline lecture notes.pdf",
            localCachePath: nil,
            syncStatus: .dirty,
            version: 0,
            md5: nil,
            modificationTimeMilliseconds: nil,
            isPendingSync: true
        )
        let hybrid = try JotHybridPDFBuilder.buildHybridPDF(jot: Jot(
            drawing: emptyJot.drawing,
            width: Jot.defaultWidth,
            zoteroItemKey: temporaryAttachmentKey,
            zoteroFileName: attachment.filename
        ))
        let localURL = try store.registerOfflineDraft(
            item: item,
            attachment: attachment,
            hybridPDF: hybrid,
            userID: userID
        )
        let engine = ZoteroSyncEngine(cacheStore: store)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZoteroCreationURLProtocol.self]
        let client = ZoteroAPIClient(
            apiKey: "write-key",
            userID: userID,
            session: URLSession(configuration: configuration)
        )

        ZoteroCreationURLProtocol.configure { _, _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await engine.synchronize(apiClient: client, userID: userID)
            XCTFail("The simulated offline request should fail.")
        } catch {
            XCTAssertTrue(error is URLError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertTrue(store.load(userID: userID).attachments[temporaryAttachmentKey]?.isPendingSync == true)

        ZoteroCreationURLProtocol.configure { request, _ in
            if request.httpMethod == "POST" {
                let submitted = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: try Self.requestBody(from: request)
                ) as? [[String: Any]])
                let successful = Dictionary(uniqueKeysWithValues: submitted.enumerated().compactMap { index, item in
                    (item["key"] as? String).map { (String(index), $0) }
                })
                return (200, try JSONSerialization.data(withJSONObject: ["successful": successful]))
            }
            let body: Data
            if request.url?.path.hasSuffix("/deleted") == true {
                body = try JSONSerialization.data(withJSONObject: ["collections": [], "items": []])
            } else {
                body = Data("{}".utf8)
            }
            return (200, body)
        }
        let synced = try await engine.synchronize(
            apiClient: client,
            userID: userID,
            uploadAttachment: { key in
                guard let path = store.load(userID: userID).attachments[key]?.localCachePath,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                    return "Promoted PDF is missing."
                }
                do {
                    _ = try store.markSynced(key: key, data: data, userID: userID)
                    return nil
                } catch { return error.localizedDescription }
            }
        )
        defer { ZoteroCreationURLProtocol.configure(nil) }

        XCTAssertNil(synced.attachments[temporaryAttachmentKey])
        let canonicalKey = try XCTUnwrap(synced.keyAliases[temporaryAttachmentKey])
        XCTAssertEqual(canonicalKey.count, 8)
        XCTAssertEqual(synced.attachments[canonicalKey]?.isPendingSync, false)
        XCTAssertEqual(synced.attachments[canonicalKey]?.syncStatus, .downloaded)
        let promotedData = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(synced.attachments[canonicalKey]?.localCachePath)))
        let beforePromotion = try HybridPDFManager.load(data: hybrid)
        let afterPromotion = try HybridPDFManager.load(data: promotedData)
        XCTAssertEqual(afterPromotion.pdfData, beforePromotion.pdfData)
        XCTAssertEqual(afterPromotion.jot.drawing, beforePromotion.jot.drawing)
        XCTAssertEqual(afterPromotion.jot.zoteroItemKey, canonicalKey)
    }

    func testDirtyAttachmentConflictPreservesLocalCopyAndDownloadsRemoteVersion() throws {
        let userID = "conflict-\(UUID().uuidString)"
        let key = "ABCD2345"
        let parentKey = "PARENT23"
        let localPDF = Data("local hybrid handwriting".utf8)
        let remotePDF = Data("remote updated PDF".utf8)
        let store = ZoteroCacheStore()
        let item = ZoteroItem(
            key: parentKey,
            title: "Conflict notes",
            creators: [],
            year: nil,
            parentItemKey: nil,
            collectionKeys: [],
            itemType: "document",
            dateAdded: Date(),
            dateModified: Date(),
            version: 1,
            isTrashed: false
        )
        let attachment = ZoteroAttachment(
            key: key,
            parentItemKey: parentKey,
            contentType: "application/pdf",
            filename: "Conflict notes.pdf",
            localCachePath: nil,
            syncStatus: .dirty,
            version: 1,
            md5: nil,
            modificationTimeMilliseconds: nil
        )
        let localURL = try store.registerCreatedDocument(
            item: item,
            attachment: attachment,
            hybridPDF: localPDF,
            libraryVersion: 10,
            userID: userID
        )
        var cached = store.load(userID: userID)
        cached.attachments[key]?.remoteMD5 = "old-remote-md5"
        cached.attachments[key]?.remoteMD5IsPDF = true
        try store.save(cached)
        let updatedRemoteAttachment = ZoteroAttachment(
            key: key,
            parentItemKey: parentKey,
            contentType: "application/pdf",
            filename: "Conflict notes.pdf",
            localCachePath: nil,
            syncStatus: .cloudOnly,
            version: 2,
            md5: "new-remote-md5",
            modificationTimeMilliseconds: nil
        )
        let delta = ZoteroLibraryDelta(
            sinceVersion: 10,
            libraryVersion: 11,
            collections: [],
            items: [item],
            attachments: [updatedRemoteAttachment],
            deletedCollectionKeys: [],
            deletedItemKeys: []
        )

        let changed = try store.apply(delta, userID: userID)
        let localConflict = try XCTUnwrap(changed.attachments.values.first(where: \.isLocalOnly))
        XCTAssertEqual(localConflict.filename, "Conflict notes (iPad Conflict Copy).pdf")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(localConflict.localCachePath))), localPDF)
        XCTAssertEqual(changed.attachments[key]?.syncStatus, .cloudOnly)
        XCTAssertNil(changed.attachments[key]?.localCachePath)
        XCTAssertTrue(changed.pendingRemoteDownloads.contains(key))

        try store.installRemoteVersion(key: key, data: remotePDF, userID: userID)
        let refreshed = store.load(userID: userID)
        XCTAssertEqual(refreshed.attachments[key]?.syncStatus, .downloaded)
        XCTAssertEqual(try Data(contentsOf: localURL), remotePDF)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(refreshed.attachments[localConflict.key]?.localCachePath))), localPDF)
    }

    func testDirtyAttachmentIgnoresVersionAndClockDriftWhenMD5IsUnchanged() throws {
        XCTAssertFalse(ZoteroSyncEngine.timestampSuggestsRemoteChange(
            serverMilliseconds: 1_015_000,
            lastSyncedMilliseconds: 1_000_000
        ))
        XCTAssertTrue(ZoteroSyncEngine.timestampSuggestsRemoteChange(
            serverMilliseconds: 1_015_001,
            lastSyncedMilliseconds: 1_000_000
        ))
        let userID = "clock-drift-\(UUID().uuidString)"
        let parent = ZoteroItem(
            key: "PARENT23", title: "Clock Drift", creators: [], year: nil,
            parentItemKey: nil, collectionKeys: [], itemType: "document",
            dateAdded: Date(), dateModified: Date(), version: 1, isTrashed: false
        )
        let attachment = ZoteroAttachment(
            key: "ABCD2345", parentItemKey: parent.key, contentType: "application/pdf",
            filename: "Clock Drift.pdf", localCachePath: nil, syncStatus: .dirty,
            version: 1, md5: nil, modificationTimeMilliseconds: 1_000_000
        )
        let store = ZoteroCacheStore()
        _ = try store.registerCreatedDocument(
            item: parent, attachment: attachment, hybridPDF: Data("local edit".utf8),
            libraryVersion: 10, userID: userID
        )
        var baseline = store.load(userID: userID)
        baseline.attachments[attachment.key]?.remoteMD5 = "same-server-pdf-hash"
        baseline.attachments[attachment.key]?.remoteMD5IsPDF = true
        baseline.attachments[attachment.key]?.modificationTimeMilliseconds = 1_000_000
        try store.save(baseline)

        let sameContent = ZoteroAttachment(
            key: attachment.key, parentItemKey: parent.key, contentType: "application/pdf",
            filename: attachment.filename, localCachePath: nil, syncStatus: .cloudOnly,
            version: 99, md5: "same-server-pdf-hash", modificationTimeMilliseconds: 1_300_000
        )
        let firstDelta = ZoteroLibraryDelta(
            sinceVersion: 10, libraryVersion: 11, collections: [], items: [parent],
            attachments: [sameContent], deletedCollectionKeys: [], deletedItemKeys: []
        )
        let afterClockDrift = try store.apply(firstDelta, userID: userID)
        XCTAssertEqual(afterClockDrift.attachments[attachment.key]?.syncStatus, .dirty)
        XCTAssertFalse(afterClockDrift.attachments[attachment.key]?.isConflict ?? true)
        XCTAssertFalse(afterClockDrift.attachments.values.contains(where: \.isLocalOnly))
        XCTAssertFalse(afterClockDrift.pendingRemoteDownloads.contains(attachment.key))

        let missingHash = ZoteroAttachment(
            key: attachment.key, parentItemKey: parent.key, contentType: "application/pdf",
            filename: attachment.filename, localCachePath: nil, syncStatus: .cloudOnly,
            version: 100, md5: nil, modificationTimeMilliseconds: 1_600_000
        )
        let secondDelta = ZoteroLibraryDelta(
            sinceVersion: 11, libraryVersion: 12, collections: [], items: [parent],
            attachments: [missingHash], deletedCollectionKeys: [], deletedItemKeys: []
        )
        let afterMissingHash = try store.apply(secondDelta, userID: userID)
        XCTAssertEqual(afterMissingHash.attachments[attachment.key]?.syncStatus, .dirty)
        XCTAssertFalse(afterMissingHash.attachments[attachment.key]?.isConflict ?? true)

        var legacyCache = afterMissingHash
        legacyCache.attachments[attachment.key]?.remoteMD5 = "legacy-hybrid-checksum"
        legacyCache.attachments[attachment.key]?.remoteMD5IsPDF = false
        try store.save(legacyCache)
        let rebaselineAttachment = ZoteroAttachment(
            key: attachment.key, parentItemKey: parent.key, contentType: "application/pdf",
            filename: attachment.filename, localCachePath: nil, syncStatus: .cloudOnly,
            version: 101, md5: "same-server-pdf-hash", modificationTimeMilliseconds: 1_900_000
        )
        let rebaselineDelta = ZoteroLibraryDelta(
            sinceVersion: 12, libraryVersion: 13, collections: [], items: [parent],
            attachments: [rebaselineAttachment], deletedCollectionKeys: [], deletedItemKeys: []
        )
        let afterRebaseline = try store.apply(rebaselineDelta, userID: userID)
        XCTAssertEqual(afterRebaseline.attachments[attachment.key]?.syncStatus, .dirty)
        XCTAssertEqual(afterRebaseline.attachments[attachment.key]?.remoteMD5, "same-server-pdf-hash")
        XCTAssertTrue(afterRebaseline.attachments[attachment.key]?.remoteMD5IsPDF == true)
        XCTAssertFalse(afterRebaseline.attachments.values.contains(where: \.isLocalOnly))
    }

    func testConflictResolutionKeepLocalServerAndBoth() throws {
        func seededStore(_ suffix: String) throws -> (ZoteroCacheStore, String, String, Data, Data) {
            let userID = "conflict-resolution-\(suffix)-\(UUID().uuidString)"
            let originalKey = "ABCD2345"
            let conflictKey = "local_\(UUID().uuidString)"
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let originalData = Data("server-version-\(suffix)".utf8)
            let localData = Data("ipad-handwritten-version-\(suffix)".utf8)
            let originalURL = folder.appendingPathComponent("original.pdf")
            let conflictURL = folder.appendingPathComponent("conflict.pdf")
            try originalData.write(to: originalURL)
            try localData.write(to: conflictURL)
            let item = ZoteroItem(
                key: conflictKey,
                title: "Notes (iPad Conflict Copy)",
                creators: ["Ada Lovelace"],
                year: "2026",
                parentItemKey: nil,
                collectionKeys: [],
                itemType: "document",
                dateAdded: Date(),
                dateModified: Date(),
                version: 1,
                isTrashed: false,
                isConflict: true
            )
            let original = ZoteroAttachment(
                key: originalKey,
                parentItemKey: "PAREN234",
                contentType: "application/pdf",
                filename: "Notes.pdf",
                localCachePath: originalURL.path,
                syncStatus: .downloaded,
                version: 2,
                md5: ZoteroSyncService.md5Hex(originalData),
                modificationTimeMilliseconds: nil
            )
            let conflict = ZoteroAttachment(
                key: conflictKey,
                parentItemKey: conflictKey,
                contentType: "application/pdf",
                filename: "Notes (iPad Conflict Copy).pdf",
                localCachePath: conflictURL.path,
                syncStatus: .dirty,
                version: 0,
                md5: ZoteroSyncService.md5Hex(localData),
                modificationTimeMilliseconds: nil,
                isLocalOnly: true,
                isConflict: true,
                conflictLocalPath: conflictURL.path,
                conflictCreatedAt: Date(),
                conflictOriginalKey: originalKey
            )
            var snapshot = ZoteroCacheSnapshot.empty(userID: userID)
            snapshot.items[conflictKey] = item
            snapshot.attachments[originalKey] = original
            snapshot.attachments[conflictKey] = conflict
            let store = ZoteroCacheStore()
            try store.save(snapshot)
            return (store, userID, conflictKey, originalData, localData)
        }

        let (localStore, localUserID, localConflictKey, _, localData) = try seededStore("local")
        let localResolved = try localStore.resolveConflictKeepingLocal(key: localConflictKey, userID: localUserID)
        let localAttachment = try XCTUnwrap(localResolved.attachments["ABCD2345"])
        XCTAssertFalse(localAttachment.isConflict)
        XCTAssertEqual(localAttachment.syncStatus, .dirty)
        XCTAssertNil(localResolved.attachments[localConflictKey])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(localAttachment.localCachePath))), localData)

        let (serverStore, serverUserID, serverConflictKey, _, _) = try seededStore("server")
        let serverData = Data("latest-zotero-server".utf8)
        let serverResolved = try serverStore.resolveConflictKeepingServer(
            key: serverConflictKey, serverData: serverData, userID: serverUserID
        )
        let serverAttachment = try XCTUnwrap(serverResolved.attachments["ABCD2345"])
        XCTAssertEqual(serverAttachment.syncStatus, .downloaded)
        XCTAssertFalse(serverAttachment.isConflict)
        XCTAssertNil(serverResolved.attachments[serverConflictKey])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(serverAttachment.localCachePath))), serverData)

        let (bothStore, bothUserID, bothConflictKey, bothServerData, bothLocalData) = try seededStore("both")
        let bothResolved = try bothStore.keepConflictAsNewDocument(
            key: bothConflictKey,
            serverData: bothServerData,
            created: CreatedZoteroDocumentKeys(
                parentItemKey: "NEWITEM2",
                attachmentKey: "NEWFILE2",
                libraryVersion: 12
            ),
            userID: bothUserID
        )
        XCTAssertEqual(bothResolved.attachments["ABCD2345"]?.syncStatus, .downloaded)
        XCTAssertEqual(bothResolved.attachments["NEWFILE2"]?.syncStatus, .dirty)
        XCTAssertNil(bothResolved.attachments[bothConflictKey])
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(bothResolved.attachments["NEWFILE2"]?.localCachePath))),
            bothLocalData
        )
    }

    @MainActor
    func testConflictItemsAreSkippedBySyncDownloadAndUploadQueues() async throws {
        let userID = "conflict-isolation-\(UUID().uuidString)"
        let conflictKey = "local_\(UUID().uuidString)"
        let cache = ZoteroCacheStore()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let localURL = folder.appendingPathComponent("conflict.pdf")
        try Data("local conflict".utf8).write(to: localURL)
        let item = ZoteroItem(
            key: conflictKey, title: "Conflict", creators: [], year: nil, parentItemKey: nil,
            collectionKeys: [], itemType: "document", dateAdded: Date(), dateModified: Date(),
            version: 1, isTrashed: false, isConflict: true
        )
        let attachment = ZoteroAttachment(
            key: conflictKey, parentItemKey: conflictKey, contentType: "application/pdf",
            filename: "Conflict.pdf", localCachePath: localURL.path, syncStatus: .dirty,
            version: 1, md5: "local", modificationTimeMilliseconds: nil,
            isLocalOnly: true, isConflict: true,
            conflictLocalPath: localURL.path, conflictCreatedAt: Date(), conflictOriginalKey: "ABCD2345"
        )
        var snapshot = ZoteroCacheSnapshot.empty(userID: userID)
        snapshot.lastLibraryVersion = 101
        snapshot.items[conflictKey] = item
        snapshot.attachments[conflictKey] = attachment
        snapshot.pendingRemoteDownloads = [conflictKey]
        try cache.save(snapshot)

        ZoteroCreationURLProtocol.configure { request, _ in
            if request.url?.path.hasSuffix("/collections") == true {
                return (304, Data())
            }
            if request.url?.path.hasSuffix("/deleted") == true {
                return (200, try JSONSerialization.data(withJSONObject: ["collections": [], "items": []]))
            }
            return (200, Data("{}".utf8))
        }
        defer { ZoteroCreationURLProtocol.configure(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZoteroCreationURLProtocol.self]
        let client = ZoteroAPIClient(
            apiKey: "write-key", userID: "1234", session: URLSession(configuration: configuration)
        )
        let counter = SyncQueueCounter()
        let progress = ZoteroSyncProgress()
        _ = try await ZoteroSyncEngine(cacheStore: cache, progress: progress).synchronize(
            apiClient: client,
            userID: userID,
            uploadAttachment: { _ in await counter.recordUpload(); return nil },
            downloadAttachment: { _ in await counter.recordDownload(); return Data() }
        )
        let counts = await counter.counts
        XCTAssertEqual(counts.uploads, 0)
        XCTAssertEqual(counts.downloads, 0)
        XCTAssertFalse(progress.isSyncing)
        XCTAssertEqual(progress.syncProgress, 1)
    }

    func testRemoteDeletionKeepsDirtyAttachmentAsLocalConflictCopy() throws {
        let userID = "deleted-conflict-\(UUID().uuidString)"
        let key = "DELE2345"
        let parentKey = "PAREN234"
        let localPDF = Data("unsynced handwritten PDF".utf8)
        let store = ZoteroCacheStore()
        let item = ZoteroItem(
            key: parentKey,
            title: "Deleted remotely",
            creators: [],
            year: nil,
            parentItemKey: nil,
            collectionKeys: [],
            itemType: "document",
            dateAdded: Date(),
            dateModified: Date(),
            version: 1,
            isTrashed: false
        )
        let attachment = ZoteroAttachment(
            key: key,
            parentItemKey: parentKey,
            contentType: "application/pdf",
            filename: "Deleted remotely.pdf",
            localCachePath: nil,
            syncStatus: .dirty,
            version: 1,
            md5: nil,
            modificationTimeMilliseconds: nil
        )
        _ = try store.registerCreatedDocument(
            item: item,
            attachment: attachment,
            hybridPDF: localPDF,
            libraryVersion: 1,
            userID: userID
        )
        let delta = ZoteroLibraryDelta(
            sinceVersion: 1,
            libraryVersion: 2,
            collections: [],
            items: [],
            attachments: [],
            deletedCollectionKeys: [],
            deletedItemKeys: [parentKey, key]
        )

        let afterDeletion = try store.apply(delta, userID: userID)
        XCTAssertNil(afterDeletion.attachments[key])
        let conflict = try XCTUnwrap(afterDeletion.attachments.values.first(where: \.isLocalOnly))
        XCTAssertTrue(conflict.isLocalOnly)
        XCTAssertTrue(conflict.filename.contains("(iPad Conflict Copy)"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(conflict.localCachePath))), localPDF)
        XCTAssertNotNil(afterDeletion.items[conflict.parentItemKey ?? ""])
    }

    func testFullCollectionReconciliationPrunesDeletedAndOrphanedCollections() throws {
        let userID = "collection-prune-\(UUID().uuidString)"
        let store = ZoteroCacheStore()
        let item = ZoteroItem(
            key: "ITEMKEY1", title: "Collection cleanup", creators: [], year: nil,
            parentItemKey: nil,
            collectionKeys: ["KEEPKEY1", "GONEKEY1", "ORPHAN01"],
            itemType: "document", dateAdded: Date(), dateModified: Date(),
            version: 4, isTrashed: false
        )
        let cached = ZoteroCacheSnapshot(
            userID: userID,
            lastLibraryVersion: 42,
            collections: [
                "KEEPKEY1": ZoteroCollection(key: "KEEPKEY1", name: "Keep", parentCollectionKey: nil, version: 3),
                "GONEKEY1": ZoteroCollection(key: "GONEKEY1", name: "Deleted", parentCollectionKey: nil, version: 2),
                "ORPHAN01": ZoteroCollection(key: "ORPHAN01", name: "Orphan", parentCollectionKey: "GONEKEY1", version: 1),
            ],
            items: [item.key: item],
            attachments: [:],
            lastSyncedAt: Date()
        )
        try store.save(cached)

        let reconciled = try store.reconcileCollections(
            [ZoteroCollection(key: "KEEPKEY1", name: "Keep", parentCollectionKey: nil, version: 3)],
            libraryVersion: 42,
            userID: userID
        )

        XCTAssertEqual(Set(reconciled.collections.keys), ["KEEPKEY1"])
        XCTAssertEqual(reconciled.items[item.key]?.collectionKeys, ["KEEPKEY1"])
        XCTAssertNil(reconciled.collections["GONEKEY1"])
        XCTAssertNil(reconciled.collections["ORPHAN01"])
    }

    func testTrashedCollectionsAndTheirDescendantsAreHiddenFromSidebar() throws {
        let fromMeta = try XCTUnwrap(ZoteroAPIClient.collection(from: [
            "key": "TRASHED1",
            "version": 2,
            "data": ["name": "Trashed", "parentCollection": false],
            "meta": ["trashed": 1],
        ]))
        let fromDeletedFlag = try XCTUnwrap(ZoteroAPIClient.collection(from: [
            "key": "DELETED1",
            "version": 3,
            "data": ["name": "Deleted", "parentCollection": false, "deleted": true],
        ]))
        XCTAssertTrue(fromMeta.isTrashed)
        XCTAssertTrue(fromDeletedFlag.isTrashed)

        let collections = [
            "ROOTKEY1": ZoteroCollection(key: "ROOTKEY1", name: "Root", parentCollectionKey: nil, version: 1),
            "CHILD001": ZoteroCollection(key: "CHILD001", name: "Active child", parentCollectionKey: "ROOTKEY1", version: 1),
            "TRASHED1": fromMeta,
            "CHILDTR1": ZoteroCollection(key: "CHILDTR1", name: "Child of trash", parentCollectionKey: "TRASHED1", version: 1),
            "GRANDTR1": ZoteroCollection(key: "GRANDTR1", name: "Grandchild of trash", parentCollectionKey: "CHILDTR1", version: 1),
            "DELETED1": fromDeletedFlag,
        ]
        XCTAssertEqual(
            ZoteroCollection.activeKeys(in: collections),
            ["ROOTKEY1", "CHILD001"]
        )

        let legacy = try JSONDecoder().decode(
            ZoteroCollection.self,
            from: Data(#"{"key":"LEGACY1","name":"Legacy","parentCollectionKey":null,"version":1}"#.utf8)
        )
        XCTAssertFalse(legacy.isTrashed, "Old cache records without the flag remain active.")
    }

    func testCreateNoteBuildsParentAndImportedPDFAttachmentRequests() async throws {
        let recorder = ZoteroRequestRecorder()
        ZoteroCreationURLProtocol.configure { request, _ in
            var capturedRequest = request
            capturedRequest.httpBody = try Self.requestBody(from: request)
            recorder.append(capturedRequest)
            let submitted = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedRequest.httpBody)) as? [[String: Any]])
            let successful = Dictionary(uniqueKeysWithValues: submitted.enumerated().compactMap { index, item in
                (item["key"] as? String).map { (String(index), $0) }
            })
            let body = try JSONSerialization.data(withJSONObject: ["successful": successful])
            return (200, body)
        }
        defer { ZoteroCreationURLProtocol.configure(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZoteroCreationURLProtocol.self]
        let client = ZoteroAPIClient(
            apiKey: "write-key",
            userID: "1234",
            session: URLSession(configuration: configuration)
        )
        let created = try await client.createNoteDocument(
            title: "Lecture Notes",
            filename: "Lecture Notes.pdf",
            collectionKeys: ["COLL2345"],
            firstName: "Ada",
            lastName: "Lovelace",
            fullName: "",
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(created.parentItemKey.count, 8)
        XCTAssertEqual(created.attachmentKey.count, 8)
        XCTAssertNotEqual(created.parentItemKey, created.attachmentKey)
        XCTAssertEqual(created.libraryVersion, 101)
        let requests = recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Zotero-Write-Token") == nil })

        let parentArray = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [[String: Any]])
        XCTAssertEqual(parentArray.count, 2)
        let parent = try XCTUnwrap(parentArray.first)
        XCTAssertEqual(parent["itemType"] as? String, "document")
        XCTAssertEqual(parent["version"] as? Int, 0)
        XCTAssertEqual(parent["title"] as? String, "Lecture Notes")
        XCTAssertEqual(parent["date"] as? String, "1970-01-01")
        XCTAssertEqual(parent["collections"] as? [String], ["COLL2345"])
        let creators = try XCTUnwrap(parent["creators"] as? [[String: String]])
        XCTAssertEqual(creators.first?["creatorType"], "author")
        XCTAssertEqual(creators.first?["firstName"], "Ada")
        XCTAssertEqual(creators.first?["lastName"], "Lovelace")

        let attachment = try XCTUnwrap(parentArray.dropFirst().first)
        XCTAssertEqual(attachment["itemType"] as? String, "attachment")
        XCTAssertEqual(attachment["version"] as? Int, 0)
        XCTAssertEqual(attachment["parentItem"] as? String, created.parentItemKey)
        XCTAssertEqual(attachment["key"] as? String, created.attachmentKey)
        XCTAssertEqual(attachment["linkMode"] as? String, "imported_file")
        XCTAssertEqual(attachment["contentType"] as? String, "application/pdf")
        XCTAssertEqual(attachment["filename"] as? String, "Lecture Notes.pdf")
    }

    func testZoteroTrashAndRestoreUseVersionedPartialUpdates() async throws {
        let recorder = ZoteroRequestRecorder()
        ZoteroCreationURLProtocol.configure { request, _ in
            if request.httpMethod == "GET" {
                return (200, Data(#"{"key":"ABCD2345","version":17,"data":{"itemType":"document","title":"Test"}}"#.utf8))
            }
            var capturedRequest = request
            capturedRequest.httpBody = try Self.requestBody(from: request)
            recorder.append(capturedRequest)
            return (200, Data("{}".utf8))
        }
        defer { ZoteroCreationURLProtocol.configure(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZoteroCreationURLProtocol.self]
        let client = ZoteroAPIClient(
            apiKey: "write-key",
            userID: "1234",
            session: URLSession(configuration: configuration)
        )

        try await client.setItemTrashed(key: "ABCD2345", isTrashed: true)
        try await client.setItemTrashed(key: "ABCD2345", isTrashed: false)

        let writes = recorder.requests.filter { $0.httpMethod == "PATCH" }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0].value(forHTTPHeaderField: "If-Unmodified-Since-Version"), "17")
        XCTAssertEqual(writes[1].value(forHTTPHeaderField: "If-Unmodified-Since-Version"), "17")
        let trashPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBody(from: writes[0])) as? [String: Bool])
        let restorePayload = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.requestBody(from: writes[1])) as? [String: Bool])
        XCTAssertEqual(trashPayload, ["deleted": true])
        XCTAssertEqual(restorePayload, ["deleted": false])
    }

    func testSoftTrashPreservesCachedPDFAndPermanentDeleteRemovesIt() throws {
        let userID = "trash-\(UUID().uuidString)"
        let store = ZoteroCacheStore()
        let parent = ZoteroItem(
            key: "PARENT23", title: "Trash Test", creators: [], year: nil,
            parentItemKey: nil, collectionKeys: ["COLL2345"], itemType: "document",
            dateAdded: Date(), dateModified: Date(), version: 1, isTrashed: false
        )
        let attachment = ZoteroAttachment(
            key: "ABCD2345", parentItemKey: parent.key, contentType: "application/pdf",
            filename: "Trash Test.pdf", localCachePath: nil, syncStatus: .downloaded,
            version: 1, md5: nil, modificationTimeMilliseconds: nil
        )
        let pdfData = Data("cached PDF bytes".utf8)
        let localURL = try store.registerCreatedDocument(
            item: parent, attachment: attachment, hybridPDF: pdfData,
            libraryVersion: 1, userID: userID
        )

        let trashed = try store.markItemsTrashed(keys: [parent.key], userID: userID)
        XCTAssertTrue(trashed.items[parent.key]?.isTrashed == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertEqual(try Data(contentsOf: localURL), pdfData)

        let restored = try store.restoreItems(keys: [parent.key], userID: userID)
        XCTAssertFalse(restored.items[parent.key]?.isTrashed ?? true)
        XCTAssertEqual(restored.items[parent.key]?.collectionKeys, ["COLL2345"])

        _ = try store.permanentlyDeleteItems(keys: [parent.key], userID: userID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertNil(store.load(userID: userID).items[parent.key])
        XCTAssertNil(store.load(userID: userID).attachments[attachment.key])
    }

    func testCreateNoteReportsZoteroHTTPErrorAndServerMessage() async throws {
        ZoteroCreationURLProtocol.configure { _, _ in
            let body = try JSONSerialization.data(withJSONObject: ["message": "Write access is required"])
            return (403, body)
        }
        defer { ZoteroCreationURLProtocol.configure(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZoteroCreationURLProtocol.self]
        let client = ZoteroAPIClient(
            apiKey: "read-only-key",
            userID: "1234",
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await client.createNoteDocument(
                title: "Lecture Notes",
                filename: "Lecture Notes.pdf",
                collectionKeys: [],
                firstName: "",
                lastName: "",
                fullName: ""
            )
            XCTFail("Expected Zotero's HTTP error to be reported")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("parent item and PDF attachment creation failed (HTTP 403)"))
            XCTAssertTrue(error.localizedDescription.contains("Write access is required"))
        }
    }

    func testCreateNoteReportsAttachmentItemValidationFailure() async throws {
        ZoteroCreationURLProtocol.configure { request, _ in
            let payload = try Self.requestBody(from: request)
            let submitted = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [[String: Any]])
            let parentKey = try XCTUnwrap(submitted.first?["key"] as? String)
            let body = try JSONSerialization.data(withJSONObject: [
                "successful": ["0": parentKey],
                "failed": ["1": ["code": 400, "message": "Invalid attachment data"]],
            ])
            return (200, body)
        }
        defer { ZoteroCreationURLProtocol.configure(nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZoteroCreationURLProtocol.self]
        let client = ZoteroAPIClient(
            apiKey: "write-key",
            userID: "1234",
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await client.createNoteDocument(
                title: "Lecture Notes",
                filename: "Lecture Notes.pdf",
                collectionKeys: [],
                firstName: "",
                lastName: "",
                fullName: ""
            )
            XCTFail("Expected Zotero to reject the PDF attachment")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("PDF attachment data (HTTP 400)"))
            XCTAssertTrue(error.localizedDescription.contains("Invalid attachment data"))
        }
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

    private func makeTwoPagePDF() throws -> Data {
        let size = CGSize(width: 240, height: 320)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            context.cgContext.setFillColor(UIColor.red.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            context.beginPage()
            context.cgContext.setFillColor(UIColor.blue.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
        }
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    private static func requestBody(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeContentData) }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
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
            location: CGPoint(x: 40, y: 40), timeOffset: 0,
            size: CGSize(width: 4, height: 4), opacity: 1, force: 1,
            azimuth: 0, altitude: .pi / 2
        )
        let secondPoint = PKStrokePoint(
            location: CGPoint(x: 120, y: 100), timeOffset: 0.1,
            size: CGSize(width: 4, height: 4), opacity: 1, force: 1,
            azimuth: 0, altitude: .pi / 2
        )
        let thirdPoint = PKStrokePoint(
            location: CGPoint(x: 200, y: 60), timeOffset: 0.2,
            size: CGSize(width: 4, height: 4), opacity: 1, force: 1,
            azimuth: 0, altitude: .pi / 2
        )
        let path = PKStrokePath(
            controlPoints: [firstPoint, secondPoint, thirdPoint],
            creationDate: Date()
        )
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }
}

private final class ZoteroRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { storage } }

    func append(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }
}

private actor SyncQueueCounter {
    private(set) var uploads = 0
    private(set) var downloads = 0

    func recordUpload() { uploads += 1 }
    func recordDownload() { downloads += 1 }
    var counts: (uploads: Int, downloads: Int) { (uploads, downloads) }
}

private final class ZoteroCreationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var responder: ((URLRequest, Int) throws -> (Int, Data))?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestCount = 0

    static func configure(_ handler: ((URLRequest, Int) throws -> (Int, Data))?) {
        lock.withLock {
            responder = handler
            requestCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (statusCode, data) = try Self.lock.withLock {
                let index = Self.requestCount
                Self.requestCount += 1
                guard let responder = Self.responder else { throw URLError(.badServerResponse) }
                return try responder(request, index)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "Last-Modified-Version": "101"
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

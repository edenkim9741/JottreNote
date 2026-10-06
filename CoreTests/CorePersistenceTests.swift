/*
 Jottre: Minimalistic jotting for iPhone, iPad and Mac.
 Copyright (C) 2021-2026 Anton Lorani

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

import Foundation
@preconcurrency import PencilKit
import PDFKit
import UIKit
import XCTest
@testable import Jottre

final class CorePersistenceTests: XCTestCase {

    func testJotRejectsUnsupportedOrIncompleteFormatVersions() throws {
        let oldFormatData = try PropertyListSerialization.data(
            fromPropertyList: [
                "version": Jot.currentVersion - 1,
                "drawing": PKDrawing().dataRepresentation(),
                "width": 900.0,
                "extraPages": 0,
                "pdfInsertedPageSlots": [Int](),
                "strokePageIndices": [Int](),
            ],
            format: .binary,
            options: 0
        )
        let missingVersionData = try PropertyListSerialization.data(
            fromPropertyList: ["drawing": PKDrawing().dataRepresentation()],
            format: .binary,
            options: 0
        )
        XCTAssertThrowsError(try PropertyListDecoder().decode(Jot.self, from: oldFormatData))
        XCTAssertThrowsError(try PropertyListDecoder().decode(Jot.self, from: missingVersionData))
    }

    func testJotFileServiceWritesBinaryPlistAndPreservesWidth() throws {
        let fileService = MemoryFileService()
        let service = JotFileService(fileService: fileService)
        let info = JotFile.Info(
            url: URL(fileURLWithPath: "/tmp/width.jot"),
            name: "width",
            modificationDate: nil
        )
        let source = JotFile(
            info: info,
            jot: Jot(drawing: PKDrawing().dataRepresentation(), width: 987)
        )

        try service.write(jotFile: source)

        let data = try XCTUnwrap(fileService.data(at: info.url))
        XCTAssertEqual(data.prefix(8), Data("bplist00".utf8))
        let decoded = try PropertyListDecoder().decode(Jot.self, from: data)
        XCTAssertEqual(decoded.width, 987)
    }

    func testEditorSaveAndReloadPreserveTrashedPageForRestore() async throws {
        let memoryFiles = MemoryFileService()
        let jotFileService = JotFileService(fileService: memoryFiles)
        let info = JotFile.Info(
            url: URL(fileURLWithPath: "/tmp/page-trash-persistence.jot"),
            name: "page-trash-persistence",
            modificationDate: nil
        )
        let repository = EditJotRepository(
            jotFileService: jotFileService,
            jotFileConflictService: JotFileConflictService(
                fileConflictService: FileConflictService(fileManager: .default)
            ),
            fileService: memoryFiles,
            trashService: TrashService()
        )
        let trashedPage = TrashedPage(
            originalIndex: 1,
            pdfPageData: try JotHybridPDFBuilder.makeRuledPDF(
                pageSize: CGSize(width: 1200, height: 1600),
                pageCount: 1
            ),
            drawingData: PKDrawing().dataRepresentation()
        )
        let content = JotContent(
            drawing: PKDrawing(),
            width: 1200,
            pdfData: nil,
            extraPages: 0,
            pdfInsertedPageSlots: [],
            strokePageIndices: [],
            trashedPages: [trashedPage]
        )

        try await repository.writeContent(jotFileInfo: info, content: content)
        let reloaded = try await repository.readContent(jotFileInfo: info, onProgress: { _ in })

        XCTAssertEqual(reloaded.trashedPages, [trashedPage])
    }

    func testEditSaveKeepsOriginalPDFAndRestoresOuterDrawing() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "pdf-test", withExtension: "pdf")
        )
        let sourcePDF = try Data(contentsOf: fixtureURL)
        let memoryFiles = MemoryFileService()
        let jotFileService = JotFileService(fileService: memoryFiles)
        let info = JotFile.Info(
            url: URL(fileURLWithPath: "/tmp/sql-save.jot"),
            name: "sql-save",
            modificationDate: nil
        )
        let original = JotFile(
            info: info,
            jot: Jot(drawing: PKDrawing().dataRepresentation(), pdfData: sourcePDF)
        )
        try jotFileService.write(jotFile: original)

        let repository = EditJotRepository(
            jotFileService: jotFileService,
            jotFileConflictService: JotFileConflictService(
                fileConflictService: FileConflictService(fileManager: .default)
            ),
            fileService: memoryFiles,
            trashService: TrashService()
        )
        let drawing = PKDrawing(strokes: [makePersistenceTestStroke()])
        let content = JotContent(
            drawing: drawing,
            width: 1200,
            pdfData: sourcePDF,
            extraPages: 0,
            pdfInsertedPageSlots: [],
            strokePageIndices: [0]
        )

        try await repository.writeContent(jotFileInfo: info, content: content)

        let savedJot = try jotFileService.readJotFile(jotFileInfo: info).jot
        let savedHybridPDF = try XCTUnwrap(savedJot.pdfData)
        XCTAssertEqual(HybridPDFManager.pdfData(in: savedHybridPDF), sourcePDF)
        XCTAssertEqual(PDFDocument(data: HybridPDFManager.pdfData(in: savedHybridPDF))?.pageCount, 78)
        XCTAssertNotNil(HybridPDFManager.embeddedJotData(in: savedHybridPDF))
        let loaded = try await repository.readContent(jotFileInfo: info, onProgress: { _ in })
        XCTAssertEqual(loaded.drawing.strokes.count, 1)
        XCTAssertEqual(loaded.drawing.strokes.first?.path.count, 3)
        XCTAssertEqual(loaded.pdfData, sourcePDF)
    }

    func testPDFTestDocumentInkSurvivesPDFExport() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "pdf-test", withExtension: "pdf")
        )
        let sourcePDF = try Data(contentsOf: fixtureURL)
        let sourceDocument = try XCTUnwrap(PDFDocument(data: sourcePDF))
        XCTAssertEqual(sourceDocument.pageCount, 1)
        XCTAssertFalse(sourceDocument.allowsCommenting, "The fixture should exercise the restricted-PDF export path.")

        let memoryFiles = MemoryFileService()
        let jotFileService = JotFileService(fileService: memoryFiles)
        let info = JotFile.Info(
            url: URL(fileURLWithPath: "/tmp/pdf-test-export.jot"),
            name: "pdf-test-export",
            modificationDate: nil
        )
        try jotFileService.write(
            jotFile: JotFile(
                info: info,
                jot: Jot(drawing: PKDrawing().dataRepresentation(), pdfData: sourcePDF)
            )
        )
        let editRepository = EditJotRepository(
            jotFileService: jotFileService,
            jotFileConflictService: JotFileConflictService(
                fileConflictService: FileConflictService(fileManager: .default)
            ),
            fileService: memoryFiles,
            trashService: TrashService()
        )
        let drawing = PKDrawing(strokes: [makePDFExportTestStroke()])
        try await editRepository.writeContent(
            jotFileInfo: info,
            content: JotContent(
                drawing: drawing,
                width: 1200,
                pdfData: sourcePDF,
                extraPages: 0,
                pdfInsertedPageSlots: [],
                strokePageIndices: [0]
            )
        )

        let exportRepository = ShareJotRepository(
            jotFileService: jotFileService,
            fileService: memoryFiles
        )
        let outputURL = try await exportRepository.exportJot(jotFileInfo: info, format: .pdf)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let exportedData = try Data(contentsOf: outputURL)
        let exportedDocument = try XCTUnwrap(PDFDocument(data: exportedData))
        XCTAssertEqual(exportedDocument.pageCount, 1)
        let exportedPage = try XCTUnwrap(exportedDocument.page(at: 0))
        XCTAssertEqual(try HybridPDFManager.load(data: exportedData).drawing.strokes.count, 1)
        XCTAssertTrue(exportedPage.annotations.contains { $0.contents == PDFAnnotationConverter.marker })

        let sourcePage = try XCTUnwrap(sourceDocument.page(at: 0))
        let renderSize = CGSize(width: 512, height: 512)
        let sourcePixels = try testPixels(in: sourcePage.thumbnail(of: renderSize, for: .mediaBox))
        let exportedPixels = try testPixels(in: exportedPage.thumbnail(of: renderSize, for: .mediaBox))
        XCTAssertEqual(sourcePixels.count, exportedPixels.count)
        let newlyVisibleMagentaPixels = stride(from: 0, to: sourcePixels.count, by: 4).filter { offset in
            let sourceWasMagenta = sourcePixels[offset] > 160 && sourcePixels[offset + 1] < 120 && sourcePixels[offset + 2] > 160
            let exportIsMagenta = exportedPixels[offset] > 160 && exportedPixels[offset + 1] < 120 && exportedPixels[offset + 2] > 160
            return exportIsMagenta && !sourceWasMagenta
        }.count
        XCTAssertGreaterThan(newlyVisibleMagentaPixels, 10, "Reopened exported PDF should visibly contain the generated ink.")
    }

    @MainActor
    func testBlankNoteInkExportMatchesEditorPage() async throws {
        let memoryFiles = MemoryFileService()
        let jotFileService = JotFileService(fileService: memoryFiles)
        let info = JotFile.Info(
            url: URL(fileURLWithPath: "/tmp/blank-note-export.jot"),
            name: "blank-note-export",
            modificationDate: nil
        )
        try jotFileService.write(jotFile: JotFile(info: info, jot: .makeEmpty()))

        let editRepository = EditJotRepository(
            jotFileService: jotFileService,
            jotFileConflictService: JotFileConflictService(
                fileConflictService: FileConflictService(fileManager: .default)
            ),
            fileService: memoryFiles,
            trashService: TrashService()
        )
        let blankContent = try await editRepository.readContent(jotFileInfo: info, onProgress: { _ in })
        XCTAssertNil(blankContent.pdfData, "A blank note must remain a ruled-paper note after loading.")

        let pageSize = CGSize(width: blankContent.width, height: blankContent.width * (4.0 / 3.0))
        let drawing = PKDrawing(strokes: [makePDFExportTestStroke()])
        try await editRepository.writeContent(
            jotFileInfo: info,
            content: JotContent(
                drawing: drawing,
                width: blankContent.width,
                pdfData: blankContent.pdfData,
                extraPages: blankContent.extraPages,
                pdfInsertedPageSlots: blankContent.pdfInsertedPageSlots,
                strokePageIndices: [0]
            )
        )

        let reopenedContent = try await editRepository.readContent(jotFileInfo: info, onProgress: { _ in })
        XCTAssertNil(reopenedContent.pdfData, "Saving ink must not turn a blank note into a white PDF page.")
        XCTAssertEqual(reopenedContent.drawing.strokes.count, 1)

        let exportRepository = ShareJotRepository(
            jotFileService: jotFileService,
            fileService: memoryFiles
        )
        let outputURL = try await exportRepository.exportJot(jotFileInfo: info, format: .pdf)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let exportedData = try Data(contentsOf: outputURL)
        let backupJot = Jot(
            drawing: reopenedContent.drawing.dataRepresentation(),
            width: reopenedContent.width,
            pdfData: reopenedContent.pdfData,
            extraPages: reopenedContent.extraPages,
            pdfInsertedPageSlots: reopenedContent.pdfInsertedPageSlots,
            strokePageIndices: reopenedContent.strokePageIndices
        )
        let backupData = try JotHybridPDFBuilder.buildHybridPDF(jot: backupJot)
        XCTAssertEqual(backupData, exportedData, "Export and Zotero upload must share byte-identical PDF output.")
        let exportedJot = try PropertyListDecoder().decode(
            Jot.self,
            from: XCTUnwrap(HybridPDFManager.embeddedJotData(in: exportedData))
        )
        let backedUpJot = try PropertyListDecoder().decode(
            Jot.self,
            from: XCTUnwrap(HybridPDFManager.embeddedJotData(in: backupData))
        )
        XCTAssertEqual(exportedJot.drawing, backedUpJot.drawing)
        XCTAssertEqual(exportedJot.width, backedUpJot.width)
        XCTAssertEqual(exportedJot.extraPages, backedUpJot.extraPages)
        XCTAssertEqual(exportedJot.pdfInsertedPageSlots, backedUpJot.pdfInsertedPageSlots)
        XCTAssertEqual(exportedJot.strokePageIndices, backedUpJot.strokePageIndices)
        XCTAssertEqual(exportedJot.zoteroItemKey, backedUpJot.zoteroItemKey)
        XCTAssertEqual(exportedJot.zoteroFileName, backedUpJot.zoteroFileName)
        let backupBasePDF = HybridPDFManager.pdfData(in: backupData)
        let exportBasePDF = HybridPDFManager.pdfData(in: exportedData)
        let pdfDifferences = zip(backupBasePDF, exportBasePDF).enumerated()
            .filter { $0.element.0 != $0.element.1 }
            .prefix(20)
            .map { "\($0.offset):\($0.element.0)/\($0.element.1)" }
        XCTAssertEqual(backupBasePDF, exportBasePDF, "PDF byte differences: \(pdfDifferences)")
        XCTAssertEqual(backupData, exportedData, "PDF export and backup must emit identical bytes.")
        let exported = try XCTUnwrap(PDFDocument(data: exportedData))
        let page = try XCTUnwrap(exported.page(at: 0))
        XCTAssertEqual(exported.pageCount, 1)
        XCTAssertEqual(page.bounds(for: .mediaBox).width, pageSize.width, accuracy: 0.5)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, pageSize.height, accuracy: 0.5)
        let basePDF = HybridPDFManager.pdfData(in: exportedData)
        let basePDFText = String(decoding: basePDF, as: UTF8.self)
        XCTAssertTrue(basePDFText.contains("/Subtype /Ink"))
        XCTAssertFalse(basePDFText.contains("/Subtype /Image"))
        XCTAssertTrue(exportedData.suffix("\n%%JOTTRENOTE_PAYLOAD_END%%\n".utf8.count)
            .elementsEqual("\n%%JOTTRENOTE_PAYLOAD_END%%\n".utf8))
        XCTAssertEqual(try HybridPDFManager.load(data: exportedData).drawing.strokes.count, 1)

        let renderSize = CGSize(width: 480, height: 640)
        let scale = renderSize.width / pageSize.width
        let trait = UITraitCollection(userInterfaceStyle: .light)
        let editorBackground = JotBackgroundView.makeRuledPageImage(
            pageSize: pageSize,
            traitCollection: trait,
            scale: scale
        )
        let editorInk = drawing.image(from: CGRect(origin: .zero, size: pageSize), scale: scale)
        let referenceFormat = UIGraphicsImageRendererFormat()
        referenceFormat.scale = 1
        referenceFormat.opaque = true
        let editorPage = UIGraphicsImageRenderer(size: renderSize, format: referenceFormat).image { context in
            editorBackground.draw(in: CGRect(origin: .zero, size: renderSize))
            editorInk.draw(in: CGRect(origin: .zero, size: renderSize))
        }
        let editorPixels = try testPixels(in: editorPage)
        let exportedImage = page.thumbnail(of: renderSize, for: .mediaBox)
        let exportedPixels = try testPixels(in: exportedImage)
        XCTAssertEqual(editorPixels.count, exportedPixels.count)

        let editorMagenta = Set(stride(from: 0, to: editorPixels.count, by: 4).compactMap { offset -> Int? in
            guard editorPixels[offset] > 160,
                  editorPixels[offset + 1] < 120,
                  editorPixels[offset + 2] > 160 else { return nil }
            return offset / 4
        })
        let exportedMagenta = Set(stride(from: 0, to: exportedPixels.count, by: 4).compactMap { offset -> Int? in
            guard exportedPixels[offset] > 160,
                  exportedPixels[offset + 1] < 120,
                  exportedPixels[offset + 2] > 160 else { return nil }
            return offset / 4
        })
        XCTAssertGreaterThan(exportedMagenta.count, 100, "Export should contain visible ink, not only ruled paper.")
        let matchingInkPixels = editorMagenta.intersection(exportedMagenta).count
        XCTAssertGreaterThan(
            Double(matchingInkPixels) / Double(max(1, editorMagenta.count)),
            0.30,
            "Exported ink should occupy the same page position; small stroke thickness differences are allowed."
        )
    }

    func testLocalFileServiceCreateDoesNotOverwriteAnExistingFile() throws {
        let service = LocalFileService(fileManager: .default)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CorePersistenceTests-\(UUID().uuidString).jot")
        let originalData = Data([1])
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try service.createFile(fileURL: fileURL, data: originalData)

        XCTAssertThrowsError(try service.createFile(fileURL: fileURL, data: Data([2])))
        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
    }

    func testPersistenceWriterSerializesAndCoalescesPendingSnapshots() async throws {
        let repository = RecordingEditJotRepository(writeDelay: .milliseconds(80))
        let writer = EditJotPersistenceWriter(
            jotFileInfo: Self.jotFileInfo,
            repository: repository,
            logger: SilentLogger(),
            debounceDuration: .milliseconds(10)
        )

        let firstSnapshot = snapshot(revision: 1, marker: 1)
        let secondSnapshot = snapshot(revision: 2, marker: 2)
        let thirdSnapshot = snapshot(revision: 3, marker: 3)
        async let firstWrite: Void = writer.saveImmediately(firstSnapshot)
        await repository.state.waitForFirstWriteToStart()
        await writer.schedule(secondSnapshot)
        await writer.schedule(thirdSnapshot)
        try await writer.saveImmediately(thirdSnapshot)
        try await firstWrite

        let result = await repository.state.result()
        XCTAssertEqual(result.completedMarkers, [1, 3])
        XCTAssertEqual(result.maximumConcurrentWrites, 1)
    }

    func testPersistenceWriterDoesNotRequeueAnActiveRevision() async throws {
        let repository = RecordingEditJotRepository(writeDelay: .milliseconds(80))
        let writer = EditJotPersistenceWriter(
            jotFileInfo: Self.jotFileInfo,
            repository: repository,
            logger: SilentLogger(),
            debounceDuration: .milliseconds(10)
        )
        let current = snapshot(revision: 2, marker: 2)
        let stale = snapshot(revision: 1, marker: 1)

        async let firstWrite: Void = writer.saveImmediately(current)
        await repository.state.waitForFirstWriteToStart()
        async let duplicateRequest: Void = writer.saveImmediately(current)
        try await writer.saveImmediately(stale)
        try await duplicateRequest
        try await firstWrite

        let result = await repository.state.result()
        XCTAssertEqual(result.completedMarkers, [2])
        XCTAssertEqual(result.maximumConcurrentWrites, 1)
    }

    func testPersistenceWriterDebouncesToLatestScheduledSnapshot() async {
        let repository = RecordingEditJotRepository(writeDelay: .milliseconds(5))
        let writer = EditJotPersistenceWriter(
            jotFileInfo: Self.jotFileInfo,
            repository: repository,
            logger: SilentLogger(),
            debounceDuration: .milliseconds(15)
        )

        await writer.schedule(snapshot(revision: 1, marker: 1))
        await writer.schedule(snapshot(revision: 2, marker: 2))
        await repository.state.waitForCompletedWrites(1)

        let result = await repository.state.result()
        XCTAssertEqual(result.completedMarkers, [2])
        XCTAssertEqual(result.maximumConcurrentWrites, 1)
    }

    func testDefaultsContinuationRemovalUsesStableToken() {
        let storage = DefaultsContinuationStorage()
        let key = DefaultsKey<Int>("test.subscription")
        let id = UUID()
        let (_, continuation) = AsyncStream<Int?>.makeStream()

        storage.add(continuation, id: id, defaultsKey: key)
        XCTAssertEqual(storage.continuationCount(defaultsKey: key), 1)

        storage.remove(id: id, defaultsKey: key)
        XCTAssertEqual(storage.continuationCount(defaultsKey: key), 0)
        continuation.finish()
    }

    func testDefaultsStreamDeliversUpdatesAndRemovesCanceledSubscriber() async {
        let suiteName = "CorePersistenceTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let service = DefaultsService(userDefaults: userDefaults)
        let key = DefaultsKey<Int>("stream.value")
        let receivedInitialValue = expectation(description: "initial value")
        let receivedUpdate = expectation(description: "updated value")

        let subscriber = Task {
            var isFirst = true
            for await value in service.getValueStream(key) {
                if isFirst {
                    isFirst = false
                    receivedInitialValue.fulfill()
                } else if value == 42 {
                    receivedUpdate.fulfill()
                }
            }
        }
        await fulfillment(of: [receivedInitialValue], timeout: 1)
        XCTAssertEqual(service.activeSubscriberCount(for: key), 1)

        service.set(key, value: 42)
        await fulfillment(of: [receivedUpdate], timeout: 1)
        XCTAssertEqual(service.getValue(key), 42)
        subscriber.cancel()
        await subscriber.value
        XCTAssertEqual(service.activeSubscriberCount(for: key), 0)
    }

    private static let jotFileInfo = JotFile.Info(
        url: URL(fileURLWithPath: "/tmp/writer.jot"),
        name: "writer",
        modificationDate: nil
    )

    private func snapshot(revision: UInt64, marker: Int) -> EditJotPersistenceSnapshot {
        EditJotPersistenceSnapshot(
            revision: revision,
            content: JotContent(
                drawing: PKDrawing(),
                width: Jot.defaultWidth,
                pdfData: nil,
                extraPages: marker,
                pdfInsertedPageSlots: [],
                strokePageIndices: []
            )
        )
    }
}

private func makePersistenceTestStroke() -> PKStroke {
    let points = [
        PKStrokePoint(
            location: CGPoint(x: 40, y: 40), timeOffset: 0, size: CGSize(width: 4, height: 4),
            opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
        ),
        PKStrokePoint(
            location: CGPoint(x: 120, y: 100), timeOffset: 0.1, size: CGSize(width: 4, height: 4),
            opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
        ),
        PKStrokePoint(
            location: CGPoint(x: 200, y: 60), timeOffset: 0.2, size: CGSize(width: 4, height: 4),
            opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
        ),
    ]
    return PKStroke(
        ink: PKInk(.pen, color: .black),
        path: PKStrokePath(controlPoints: points, creationDate: Date())
    )
}

private func makePDFExportTestStroke() -> PKStroke {
    let locations = [
        CGPoint(x: 240, y: 520),
        CGPoint(x: 560, y: 960),
        CGPoint(x: 960, y: 620),
    ]
    let points = locations.enumerated().map { index, location in
        PKStrokePoint(
            location: location,
            timeOffset: TimeInterval(index) * 0.1,
            size: CGSize(width: 24, height: 24),
            opacity: 1,
            force: 1,
            azimuth: 0,
            altitude: .pi / 2
        )
    }
    return PKStroke(
        ink: PKInk(.pen, color: .magenta),
        path: PKStrokePath(controlPoints: points, creationDate: Date())
    )
}

private func testPixels(in image: UIImage) throws -> [UInt8] {
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

private struct SilentLogger: LoggerProtocol {
    func debug(_ message: @autoclosure () -> String) { }
    func info(_ message: @autoclosure () -> String) { }
    func error(_ message: @autoclosure () -> String) { }
}

private final class MemoryFileService: FileServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL: Data] = [:]

    func data(at url: URL) -> Data? {
        lock.withLock { files[url] }
    }

    func isEnabled() -> Bool { true }
    func initializeDocumentsDirectory() async throws { }
    func documentsDirectory() async throws -> URL? { URL(fileURLWithPath: "/tmp") }
    func temporaryDirectory() -> URL { URL(fileURLWithPath: "/tmp") }
    func listContents(directory: URL, properties: [URLResourceKey]) throws -> [URL] { [] }
    func directoryChanges(directory: URL) -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
    func readFile(fileURL: URL) throws -> Data {
        guard let data = data(at: fileURL) else { throw CocoaError(.fileNoSuchFile) }
        return data
    }
    func writeFile(fileURL: URL, data: Data) throws {
        lock.withLock { files[fileURL] = data }
    }
    func createFile(fileURL: URL, data: Data) throws {
        try lock.withLock {
            guard files[fileURL] == nil else { throw CocoaError(.fileWriteFileExists) }
            files[fileURL] = data
        }
    }
    func fileExists(fileURL: URL) -> Bool { data(at: fileURL) != nil }
    func removeFile(fileURL: URL) throws { lock.withLock { _ = files.removeValue(forKey: fileURL) } }
    func moveFile(fileURL: URL, newFileURL: URL) throws { }
    func duplicateFile(fileURL: URL) throws -> URL { fileURL }
    func createDirectory(directoryURL: URL) throws { }
}

private final class RecordingEditJotRepository: EditJotRepositoryProtocol, @unchecked Sendable {

    actor State {
        private var activeWrites = 0
        private var maximumConcurrentWrites = 0
        private var completedMarkers: [Int] = []
        private var firstWriteWaiters: [CheckedContinuation<Void, Never>] = []
        private var completionWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var hasStartedWrite = false

        func startedWrite() {
            activeWrites += 1
            maximumConcurrentWrites = max(maximumConcurrentWrites, activeWrites)
            guard !hasStartedWrite else { return }
            hasStartedWrite = true
            let waiters = firstWriteWaiters
            firstWriteWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func completedWrite(marker: Int) {
            completedMarkers.append(marker)
            activeWrites -= 1
            let ready = completionWaiters.filter { completedMarkers.count >= $0.count }
            completionWaiters.removeAll { completedMarkers.count >= $0.count }
            ready.forEach { $0.continuation.resume() }
        }

        func waitForFirstWriteToStart() async {
            guard !hasStartedWrite else { return }
            await withCheckedContinuation { firstWriteWaiters.append($0) }
        }

        func waitForCompletedWrites(_ count: Int) async {
            guard completedMarkers.count < count else { return }
            await withCheckedContinuation { continuation in
                completionWaiters.append((count, continuation))
            }
        }

        func result() -> (completedMarkers: [Int], maximumConcurrentWrites: Int) {
            (completedMarkers, maximumConcurrentWrites)
        }
    }

    let state = State()
    private let writeDelay: Duration

    init(writeDelay: Duration) {
        self.writeDelay = writeDelay
    }

    func readContent(
        jotFileInfo: JotFile.Info,
        onProgress: @Sendable (Double) -> Void
    ) async throws -> JotContent {
        throw CocoaError(.fileReadUnknown)
    }

    func writeContent(jotFileInfo: JotFile.Info, content: JotContent) async throws {
        await state.startedWrite()
        try await Task.sleep(for: writeDelay)
        await state.completedWrite(marker: content.extraPages)
    }

    func getConflictingVersions(jotFileInfo: JotFile.Info) -> [JotFileVersion]? { nil }
    func duplicate(jotFileInfo: JotFile.Info) throws -> JotFile.Info { jotFileInfo }
    func saveDeletedPageToTrash(
        strokes: [PKStroke],
        pageStartY: CGFloat,
        width: CGFloat,
        pageName: String,
        pageDeletion: TrashService.PageDeletionInfo
    ) async throws { }
}

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

@preconcurrency import PencilKit
import PDFKit
import UIKit

protocol TrashRepositoryProtocol: JotPreviewProviderProtocol {

    func observeTrashedJots() -> AsyncThrowingStream<[TrashJotInfo], Error>

    func restore(info: TrashJotInfo) async throws

    func permanentlyDelete(info: TrashJotInfo) throws

    func emptyTrash() async throws
}

struct TrashRepository: TrashRepositoryProtocol {

    private let fileService: FileServiceProtocol
    private let trashService: TrashService
    private let previewService: JotFilePreviewImageServiceProtocol

    init(
        fileService: FileServiceProtocol,
        trashService: TrashService,
        previewService: JotFilePreviewImageServiceProtocol
    ) {
        self.fileService = fileService
        self.trashService = trashService
        self.previewService = previewService
    }

    func observeTrashedJots() -> AsyncThrowingStream<[TrashJotInfo], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let docsDir = try await fileService.documentsDirectory() else {
                        continuation.finish(); return
                    }
                    let trashDir = trashService.trashDirectory(in: docsDir)
                    if !fileService.fileExists(fileURL: trashDir) {
                        try fileService.createDirectory(directoryURL: trashDir)
                    }
                    for await _ in fileService.directoryChanges(directory: trashDir) {
                        let items = try trashService.listTrashedJots(in: trashDir, fileService: fileService)
                        continuation.yield(items)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func restore(info: TrashJotInfo) async throws {
        if info.sourceJotURL != nil {
            try await restoreDeletedPage(info: info)
        } else {
            try await trashService.restore(info: info, fileService: fileService)
        }
    }

    func permanentlyDelete(info: TrashJotInfo) throws {
        try trashService.permanentlyDelete(info: info, fileService: fileService)
    }

    func emptyTrash() async throws {
        guard let docsDir = try await fileService.documentsDirectory() else { return }
        let trashDir = trashService.trashDirectory(in: docsDir)
        guard fileService.fileExists(fileURL: trashDir) else { return }
        try trashService.emptyTrash(in: trashDir, fileService: fileService)
    }

    func getPreviewImage(
        jotFileInfo: JotFile.Info,
        userInterfaceStyle: UIUserInterfaceStyle,
        displayScale: CGFloat
    ) async -> UIImage? {
        guard let data = try? await previewService.getPreviewImageData(
            jotFileInfo: jotFileInfo,
            userInterfaceStyle: userInterfaceStyle,
            displayScale: displayScale
        ) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - Page restore

private extension TrashRepository {

    func restoreDeletedPage(info: TrashJotInfo) async throws {
        guard let sourceJotURL = info.sourceJotURL,
              let deletedPageIndex = info.deletedPageIndex,
              let pageStride = info.pageStride else {
            try await trashService.restore(info: info, fileService: fileService)
            return
        }
        guard fileService.fileExists(fileURL: sourceJotURL) else {
            try await trashService.restore(info: info, fileService: fileService)
            return
        }

        let decoder = PropertyListDecoder()
        let sourceJot = try decoder.decode(Jot.self, from: try fileService.readFile(fileURL: sourceJotURL))
        let pageJot = try decoder.decode(Jot.self, from: try fileService.readFile(fileURL: info.trashURL))

        let basePages = sourceJot.pdfData.flatMap { PDFDocument(data: $0)?.pageCount } ?? 1
        var currentSlots = sourceJot.pdfInsertedPageSlots
        if sourceJot.pdfData != nil, currentSlots.isEmpty, sourceJot.extraPages > 0 {
            currentSlots = Array(basePages..<(basePages + sourceJot.extraPages))
        }
        let totalPages = sourceJot.pdfData != nil ? basePages + currentSlots.count : 1 + sourceJot.extraPages
        let insertIndex = min(deletedPageIndex, totalPages)

        let (mergedDrawing, newIndices) = try mergedDrawing(
            source: sourceJot, page: pageJot,
            insertIndex: insertIndex, pageStride: pageStride
        )
        let (updatedExtraPages, updatedSlots) = updatedPageMetadata(
            sourceJot: sourceJot, currentSlots: currentSlots, insertIndex: insertIndex
        )
        let updatedJot = Jot(
            version: sourceJot.version,
            drawing: mergedDrawing.dataRepresentation(),
            width: sourceJot.width,
            pdfData: sourceJot.pdfData,
            extraPages: updatedExtraPages,
            pdfInsertedPageSlots: updatedSlots,
            strokePageIndices: newIndices
        )
        try fileService.writeFile(fileURL: sourceJotURL, data: PropertyListEncoder().encode(updatedJot))
        try? fileService.removeFile(fileURL: info.trashURL)
        try? fileService.removeFile(fileURL: info.trashInfoURL)
    }

    func mergedDrawing(
        source sourceJot: Jot,
        page pageJot: Jot,
        insertIndex: Int,
        pageStride: CGFloat
    ) throws -> (PKDrawing, [Int]) {
        let insertionBoundaryY = CGFloat(insertIndex) * pageStride
        let sourceDrawing = try PKDrawing(data: sourceJot.drawing)
        let pageDrawing = try PKDrawing(data: pageJot.drawing)

        var newIndices: [Int] = []
        let shiftedExisting: [PKStroke] = sourceDrawing.strokes.enumerated().map { idx, stroke in
            let origPage = idx < sourceJot.strokePageIndices.count
                ? sourceJot.strokePageIndices[idx]
                : max(0, Int(floor(stroke.renderBounds.midY / pageStride)))
            if stroke.renderBounds.minY >= insertionBoundaryY {
                let shifted = stroke.transform.translatedBy(x: 0, y: pageStride)
                newIndices.append(origPage + 1)
                return PKStroke(ink: stroke.ink, path: stroke.path, transform: shifted, mask: stroke.mask)
            }
            newIndices.append(origPage)
            return stroke
        }
        let restoredStrokes: [PKStroke] = pageDrawing.strokes.map { stroke in
            let shifted = stroke.transform.translatedBy(x: 0, y: insertionBoundaryY)
            return PKStroke(ink: stroke.ink, path: stroke.path, transform: shifted, mask: stroke.mask)
        }
        newIndices.append(contentsOf: Array(repeating: insertIndex, count: restoredStrokes.count))
        return (PKDrawing(strokes: shiftedExisting + restoredStrokes), newIndices)
    }

    func updatedPageMetadata(
        sourceJot: Jot,
        currentSlots: [Int],
        insertIndex: Int
    ) -> (extraPages: Int, slots: [Int]) {
        guard sourceJot.pdfData != nil else {
            return (sourceJot.extraPages + 1, [])
        }
        var slots = currentSlots.map { $0 >= insertIndex ? $0 + 1 : $0 }
        slots.append(insertIndex)
        slots.sort()
        return (slots.count, slots)
    }
}

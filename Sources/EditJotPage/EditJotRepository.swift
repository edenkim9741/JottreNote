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
import Foundation

struct JotContent: Sendable {
    let drawing: PKDrawing
    let width: CGFloat
    let pdfData: Data?
    let extraPages: Int
    let pdfInsertedPageSlots: [Int]
    let strokePageIndices: [Int]
}

protocol EditJotRepositoryProtocol: Sendable {

    func readContent(
        jotFileInfo: JotFile.Info,
        onProgress: @Sendable (Double) -> Void
    ) async throws -> JotContent
    func writeContent(
        jotFileInfo: JotFile.Info,
        drawing: PKDrawing,
        pdfData: Data?,
        extraPages: Int,
        pdfInsertedPageSlots: [Int],
        strokePageIndices: [Int]
    ) async throws
    func getConflictingVersions(jotFileInfo: JotFile.Info) -> [JotFileVersion]?
    func duplicate(jotFileInfo: JotFile.Info) throws -> JotFile.Info
    func saveDeletedPageToTrash(
        strokes: [PKStroke],
        pageStartY: CGFloat,
        width: CGFloat,
        pageName: String,
        pageDeletion: TrashService.PageDeletionInfo
    ) async throws
}

struct EditJotRepository: EditJotRepositoryProtocol {

    private let jotFileService: JotFileServiceProtocol
    private let jotFileConflictService: JotFileConflictServiceProtocol
    private let fileService: FileServiceProtocol
    private let trashService: TrashService

    init(
        jotFileService: JotFileServiceProtocol,
        jotFileConflictService: JotFileConflictServiceProtocol,
        fileService: FileServiceProtocol,
        trashService: TrashService
    ) {
        self.jotFileService = jotFileService
        self.jotFileConflictService = jotFileConflictService
        self.fileService = fileService
        self.trashService = trashService
    }

    func readContent(
        jotFileInfo: JotFile.Info,
        onProgress: @Sendable (Double) -> Void
    ) async throws -> JotContent {
        onProgress(0.1)
        let file = try jotFileService.readJotFile(jotFileInfo: jotFileInfo)
        onProgress(0.5)
        let drawing = try PKDrawing(data: file.jot.drawing)
        onProgress(0.9)
        return JotContent(
            drawing: drawing,
            width: file.jot.width,
            pdfData: file.jot.pdfData,
            extraPages: file.jot.extraPages,
            pdfInsertedPageSlots: file.jot.pdfInsertedPageSlots,
            strokePageIndices: file.jot.strokePageIndices
        )
    }

    func writeContent(
        jotFileInfo: JotFile.Info,
        drawing: PKDrawing,
        pdfData: Data?,
        extraPages: Int,
        pdfInsertedPageSlots: [Int],
        strokePageIndices: [Int]
    ) async throws {
        let empty = Jot.makeEmpty()
        let jotFile = JotFile(
            info: jotFileInfo,
            jot: Jot(
                version: empty.version,
                drawing: drawing.dataRepresentation(),
                width: empty.width,
                pdfData: pdfData,
                extraPages: extraPages,
                pdfInsertedPageSlots: pdfInsertedPageSlots,
                strokePageIndices: strokePageIndices
            )
        )
        try jotFileService.write(jotFile: jotFile)
    }

    func getConflictingVersions(jotFileInfo: JotFile.Info) -> [JotFileVersion]? {
        jotFileConflictService.getConfictingVersions(jotFileInfo: jotFileInfo)
    }

    func duplicate(jotFileInfo: JotFile.Info) throws -> JotFile.Info {
        try jotFileService.duplicate(jotFileInfo: jotFileInfo)
    }

    func saveDeletedPageToTrash(
        strokes: [PKStroke],
        pageStartY: CGFloat,
        width: CGFloat,
        pageName: String,
        pageDeletion: TrashService.PageDeletionInfo
    ) async throws {
        let shiftedStrokes = strokes.map { stroke in
            let shifted = stroke.transform.translatedBy(x: 0, y: -pageStartY)
            return PKStroke(ink: stroke.ink, path: stroke.path, transform: shifted, mask: stroke.mask)
        }
        let drawing = PKDrawing(strokes: shiftedStrokes)
        let empty = Jot.makeEmpty()
        let jot = Jot(version: empty.version, drawing: drawing.dataRepresentation(), width: width)
        let data = try PropertyListEncoder().encode(jot)
        try await trashService.saveJotDataToTrash(
            data: data,
            name: pageName,
            pageDeletion: pageDeletion,
            fileService: fileService
        )
    }
}

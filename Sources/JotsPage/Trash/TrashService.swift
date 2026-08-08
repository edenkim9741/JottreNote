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

struct TrashService: Sendable {

    private struct TrashInfo: Codable {
        let originalPath: String
        let originalName: String
        let deletedDate: Date
        var sourceJotPath: String?
        var deletedPageIndex: Int?
        var pageStride: CGFloat?
    }

    struct PageDeletionInfo: Sendable {
        let sourceJotPath: String
        let deletedPageIndex: Int
        let pageStride: CGFloat
    }

    static let directoryName = ".Trash"
    private static let trashInfoExtension = "trashinfo"

    func trashDirectory(in documentsDirectory: URL) -> URL {
        documentsDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    func moveToTrash(jotFileInfo: JotFile.Info, fileService: FileServiceProtocol) async throws {
        guard let docsDir = try await fileService.documentsDirectory() else { return }
        let trashDir = trashDirectory(in: docsDir)
        if !fileService.fileExists(fileURL: trashDir) {
            try fileService.createDirectory(directoryURL: trashDir)
        }
        let itemID = UUID().uuidString
        let trashJotURL = trashDir.appendingPathComponent("\(itemID).jot")
        let trashInfoURL = trashDir.appendingPathComponent("\(itemID).\(Self.trashInfoExtension)")
        try fileService.moveFile(fileURL: jotFileInfo.url, newFileURL: trashJotURL)
        let meta = TrashInfo(
            originalPath: jotFileInfo.url.path,
            originalName: jotFileInfo.name,
            deletedDate: Date()
        )
        try fileService.writeFile(fileURL: trashInfoURL, data: JSONEncoder().encode(meta))
    }

    func listTrashedJots(in trashDir: URL, fileService: FileServiceProtocol) throws -> [TrashJotInfo] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = try fileService.listContents(directory: trashDir, properties: keys)
        let jotURLs = urls.filter { $0.pathExtension == JotFile.Info.fileExtension }
        let decoder = JSONDecoder()
        let items: [TrashJotInfo] = jotURLs.compactMap { jotURL in
            let stem = jotURL.deletingPathExtension().lastPathComponent
            let infoURL = trashDir.appendingPathComponent("\(stem).\(Self.trashInfoExtension)")
            guard let data = try? fileService.readFile(fileURL: infoURL),
                  let meta = try? decoder.decode(TrashInfo.self, from: data) else { return nil }
            let modDate = (try? jotURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return TrashJotInfo(
                trashURL: jotURL,
                trashInfoURL: infoURL,
                originalURL: URL(fileURLWithPath: meta.originalPath),
                name: meta.originalName,
                deletedDate: meta.deletedDate,
                modificationDate: modDate,
                sourceJotURL: meta.sourceJotPath.map { URL(fileURLWithPath: $0) },
                deletedPageIndex: meta.deletedPageIndex,
                pageStride: meta.pageStride
            )
        }
        return items.sorted { $0.deletedDate > $1.deletedDate }
    }

    func restore(info: TrashJotInfo, fileService: FileServiceProtocol) async throws {
        let parentDir = info.originalURL.deletingLastPathComponent()
        let base: URL
        if fileService.fileExists(fileURL: parentDir) {
            base = info.originalURL
        } else {
            guard let docsDir = try await fileService.documentsDirectory() else { return }
            base = docsDir.appendingPathComponent(info.originalURL.lastPathComponent)
        }
        try fileService.moveFile(fileURL: info.trashURL, newFileURL: uniqueURL(for: base, fileService: fileService))
        try? fileService.removeFile(fileURL: info.trashInfoURL)
    }

    func permanentlyDelete(info: TrashJotInfo, fileService: FileServiceProtocol) throws {
        try fileService.removeFile(fileURL: info.trashURL)
        try? fileService.removeFile(fileURL: info.trashInfoURL)
    }

    func saveJotDataToTrash(
        data: Data,
        name: String,
        pageDeletion: PageDeletionInfo?,
        fileService: FileServiceProtocol
    ) async throws {
        guard let docsDir = try await fileService.documentsDirectory() else { return }
        let trashDir = trashDirectory(in: docsDir)
        if !fileService.fileExists(fileURL: trashDir) {
            try fileService.createDirectory(directoryURL: trashDir)
        }
        let itemID = UUID().uuidString
        let trashJotURL = trashDir.appendingPathComponent("\(itemID).jot")
        let trashInfoURL = trashDir.appendingPathComponent("\(itemID).\(Self.trashInfoExtension)")
        let originalURL = docsDir.appendingPathComponent("\(name).jot")
        var meta = TrashInfo(
            originalPath: originalURL.path,
            originalName: name,
            deletedDate: Date()
        )
        meta.sourceJotPath = pageDeletion?.sourceJotPath
        meta.deletedPageIndex = pageDeletion?.deletedPageIndex
        meta.pageStride = pageDeletion?.pageStride
        try fileService.writeFile(fileURL: trashJotURL, data: data)
        try fileService.writeFile(fileURL: trashInfoURL, data: JSONEncoder().encode(meta))
    }

    func emptyTrash(in trashDir: URL, fileService: FileServiceProtocol) throws {
        let items = try listTrashedJots(in: trashDir, fileService: fileService)
        for item in items {
            try permanentlyDelete(info: item, fileService: fileService)
        }
    }

    private func uniqueURL(for url: URL, fileService: FileServiceProtocol) -> URL {
        guard fileService.fileExists(fileURL: url) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let parent = url.deletingLastPathComponent()
        var count = 2
        var candidate = parent.appendingPathComponent("\(stem) \(count).\(ext)")
        while fileService.fileExists(fileURL: candidate) {
            count += 1
            candidate = parent.appendingPathComponent("\(stem) \(count).\(ext)")
        }
        return candidate
    }
}

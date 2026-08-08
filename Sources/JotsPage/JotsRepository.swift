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
import UIKit

protocol JotsRepositoryProtocol: JotPreviewProviderProtocol {

    func getItems(location: JotsLocation) -> AsyncThrowingStream<[JotsItem], Error>

    func duplicate(jotFileInfo: JotFile.Info) throws -> JotFile.Info

    func createFolder(name: String, location: JotsLocation) async throws

    func renameFolder(folder: FolderBusinessModel, newName: String) throws

    func deleteFolder(folder: FolderBusinessModel) throws

    func deleteJot(jotFileInfo: JotFile.Info) async throws

    func moveJot(jotFileInfo: JotFile.Info, destinationFolder: FolderBusinessModel?) async throws

    func moveFolder(folder: FolderBusinessModel, destinationFolder: FolderBusinessModel?) async throws

    func listFolders() async throws -> [FolderBusinessModel]

    @MainActor
    func supportsMultipleScenes() -> Bool

    @MainActor
    func isIPadOS() -> Bool
}

struct JotsRepository: JotsRepositoryProtocol {

    enum Failure: Error {
        case couldNotResolveDirectory
        case invalidFolderName
    }

    private let fileService: FileServiceProtocol
    private let applicationService: ApplicationServiceProtocol
    private let deviceService: DeviceServiceProtocol
    private let jotFileService: JotFileServiceProtocol
    private let jotFilePreviewImageService: JotFilePreviewImageServiceProtocol
    private let defaultsService: DefaultsServiceProtocol
    private let webDAVBackupService: WebDAVBackupService
    private let trashService: TrashService

    init(
        fileService: FileServiceProtocol,
        applicationService: ApplicationServiceProtocol,
        deviceService: DeviceServiceProtocol,
        jotFileService: JotFileServiceProtocol,
        jotFilePreviewImageService: JotFilePreviewImageServiceProtocol,
        defaultsService: DefaultsServiceProtocol,
        webDAVBackupService: WebDAVBackupService,
        trashService: TrashService
    ) {
        self.fileService = fileService
        self.applicationService = applicationService
        self.deviceService = deviceService
        self.jotFileService = jotFileService
        self.jotFilePreviewImageService = jotFilePreviewImageService
        self.defaultsService = defaultsService
        self.webDAVBackupService = webDAVBackupService
        self.trashService = trashService
    }

    func getItems(location: JotsLocation) -> AsyncThrowingStream<[JotsItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let directory: URL
                    switch location {
                    case .root:
                        guard let dir = try await fileService.documentsDirectory() else {
                            continuation.finish()
                            return
                        }
                        directory = dir
                    case let .directory(directoryLocation):
                        directory = directoryLocation.url
                    }

                    // Emit initial state once before starting observation loops.
                    // Both directoryChanges and getValueStream yield immediately on
                    // subscription — skipping their first events avoids a redundant
                    // double listItems() call and main-thread filesystem I/O.
                    let initialItems = try listItems(directory: directory)
                    continuation.yield(sortItems(initialItems))

                    let dirTask = Task {
                        var isFirst = true
                        for try await _ in fileService.directoryChanges(directory: directory) {
                            if isFirst { isFirst = false; continue }
                            let items = try listItems(directory: directory)
                            continuation.yield(sortItems(items))
                        }
                    }

                    let defaultsTask = Task {
                        var isFirst = true
                        for await _ in defaultsService.getValueStream(DefaultsKey<Int>.init("jots.sortOrder")) {
                            if isFirst { isFirst = false; continue }
                            let items = try listItems(directory: directory)
                            continuation.yield(sortItems(items))
                        }
                    }

                    try await dirTask.value
                    try await defaultsTask.value
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func sortItems(_ items: [JotsItem]) -> [JotsItem] {
        enum SortOrder: Int {
            case modified = 0
            case name = 1
        }

        let sortOrderRaw = defaultsService.getValue(DefaultsKey<Int>.init("jots.sortOrder"))
            ?? SortOrder.modified.rawValue
        let sortOrder = SortOrder(rawValue: sortOrderRaw) ?? .modified

        let folders = items.compactMap { item -> FolderBusinessModel? in
            guard case let .folder(folder) = item else { return nil }
            return folder
        }
        .sorted { lhs, rhs in
            switch sortOrder {
            case .modified:
                return (lhs.modificationDate ?? .distantPast) > (rhs.modificationDate ?? .distantPast)
            case .name:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }

        let jots = items.compactMap { item -> JotFile.Info? in
            guard case let .jot(jotFileInfo) = item else { return nil }
            return jotFileInfo
        }
        .sorted { lhs, rhs in
            switch sortOrder {
            case .modified:
                return (lhs.modificationDate ?? .distantPast) > (rhs.modificationDate ?? .distantPast)
            case .name:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }

        return folders.map(JotsItem.folder) + jots.map(JotsItem.jot)
    }

    private enum ListConstants {
        static let urlResourceKeys: [URLResourceKey] = [
            .contentModificationDateKey,
            .isWritableKey,
            .isReadableKey,
            .isDirectoryKey,
            .isRegularFileKey
        ]
    }

    private func listItems(directory: URL) throws -> [JotsItem] {
        let urls = try fileService.listContents(
            directory: directory,
            properties: ListConstants.urlResourceKeys
        )

        let resourceKeys = Set(ListConstants.urlResourceKeys)
        let urlsWithProperties: [(url: URL, properties: URLResourceValues)] = try urls.map { url in
            (url: url, properties: try url.resourceValues(forKeys: resourceKeys))
        }
        let accessible = urlsWithProperties.filter { _, properties in
            properties.isReadable == true && properties.isWritable == true
        }
        return try accessible.compactMap { url, properties -> JotsItem? in
                if properties.isDirectory == true {
                    let name = url.lastPathComponent
                    guard name != "Inbox", name != TrashService.directoryName else { return nil }
                    return .folder(
                        FolderBusinessModel(
                            url: url,
                            name: url.lastPathComponent,
                            modificationDate: properties.contentModificationDate
                        )
                    )
                }
                guard properties.isRegularFile == true,
                      url.pathExtension == JotFile.Info.fileExtension
                else { return nil }

                return .jot(
                    JotFile.Info(
                        url: url,
                        name: url.deletingPathExtension().lastPathComponent,
                        modificationDate: properties.contentModificationDate
                    )
                )
            }
    }

    func duplicate(jotFileInfo: JotFile.Info) throws -> JotFile.Info {
        try jotFileService.duplicate(jotFileInfo: jotFileInfo)
    }

    func createFolder(name: String, location: JotsLocation) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.invalidFolderName }

        let parentDirectory: URL
        switch location {
        case .root:
            guard let directory = try await fileService.documentsDirectory() else {
                throw Failure.couldNotResolveDirectory
            }
            parentDirectory = directory
        case let .directory(directoryLocation):
            parentDirectory = directoryLocation.url
        }

        let folderURL = parentDirectory.appendingPathComponent(trimmed, isDirectory: true)
        try fileService.createDirectory(directoryURL: folderURL)
    }

    func renameFolder(folder: FolderBusinessModel, newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.invalidFolderName }
        let newURL = folder.url.deletingLastPathComponent().appendingPathComponent(trimmed, isDirectory: true)
        try fileService.moveFile(fileURL: folder.url, newFileURL: newURL)
    }

    func deleteFolder(folder: FolderBusinessModel) throws {
        try fileService.removeFile(fileURL: folder.url)
    }

    func deleteJot(jotFileInfo: JotFile.Info) async throws {
        try await trashService.moveToTrash(jotFileInfo: jotFileInfo, fileService: fileService)
    }

    func moveJot(jotFileInfo: JotFile.Info, destinationFolder: FolderBusinessModel?) async throws {
        let destinationDirectory: URL
        if let destinationFolder {
            destinationDirectory = destinationFolder.url
        } else {
            guard let directory = try await fileService.documentsDirectory() else {
                throw Failure.couldNotResolveDirectory
            }
            destinationDirectory = directory
        }
        let destinationURL = destinationDirectory.appendingPathComponent(jotFileInfo.url.lastPathComponent)
        try fileService.moveFile(fileURL: jotFileInfo.url, newFileURL: destinationURL)
        let movedInfo = JotFile.Info(url: destinationURL, name: jotFileInfo.name, modificationDate: nil)
        webDAVBackupService.moveFiles(from: jotFileInfo, to: movedInfo)
    }

    func moveFolder(folder: FolderBusinessModel, destinationFolder: FolderBusinessModel?) async throws {
        let destinationDirectory: URL
        if let destinationFolder {
            destinationDirectory = destinationFolder.url
        } else {
            guard let directory = try await fileService.documentsDirectory() else {
                throw Failure.couldNotResolveDirectory
            }
            destinationDirectory = directory
        }
        let destinationURL = destinationDirectory.appendingPathComponent(
            folder.url.lastPathComponent, isDirectory: true
        )
        try fileService.moveFile(fileURL: folder.url, newFileURL: destinationURL)
    }

    func listFolders() async throws -> [FolderBusinessModel] {
        guard let root = try await fileService.documentsDirectory() else { return [] }
        return try listFoldersRecursively(directory: root)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func listFoldersRecursively(directory: URL) throws -> [FolderBusinessModel] {
        let urls = try fileService.listContents(
            directory: directory,
            properties: ListConstants.urlResourceKeys
        )
        var folders = [FolderBusinessModel]()
        for url in urls {
            let properties = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard properties.isDirectory == true else { continue }
            folders.append(
                FolderBusinessModel(
                    url: url,
                    name: url.lastPathComponent,
                    modificationDate: properties.contentModificationDate
                )
            )
            folders.append(contentsOf: try listFoldersRecursively(directory: url))
        }
        return folders
    }

    func getPreviewImage(
        jotFileInfo: JotFile.Info,
        userInterfaceStyle: UIUserInterfaceStyle,
        displayScale: CGFloat
    ) async -> UIImage? {
        do {
            let imageData = try await jotFilePreviewImageService.getPreviewImageData(
                jotFileInfo: jotFileInfo,
                userInterfaceStyle: userInterfaceStyle,
                displayScale: displayScale
            )
            return UIImage(data: imageData)
        } catch {
            return nil
        }
    }

    func supportsMultipleScenes() -> Bool {
        applicationService.supportsMultipleScenes()
    }

    func isIPadOS() -> Bool {
        deviceService.isIPadOS()
    }
}

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

protocol JotsRepositoryProtocol: Sendable {

    func getItems(location: JotsLocation) -> AsyncThrowingStream<[JotsItem], Error>

    func shouldShowEnableICloudButton() -> Bool

    func duplicate(jotFileInfo: JotFile.Info) throws -> JotFile.Info

    func createFolder(name: String, location: JotsLocation) async throws

    func renameFolder(folder: FolderBusinessModel, newName: String) throws

    func deleteFolder(folder: FolderBusinessModel) throws

    func deleteJot(jotFileInfo: JotFile.Info) throws

    func moveJot(jotFileInfo: JotFile.Info, destinationFolder: FolderBusinessModel?) async throws

    func listFolders(storage: JotsFolderURL.Storage) async throws -> [FolderBusinessModel]

    func download(jotFileInfo: JotFile.Info) throws

    func getPreviewImage(
        jotFileInfo: JotFile.Info,
        userInterfaceStyle: UIUserInterfaceStyle,
        displayScale: CGFloat
    ) async -> UIImage?

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

    private let localFileService: FileServiceProtocol
    private let ubiquitousFileService: FileServiceProtocol
    private let applicationService: ApplicationServiceProtocol
    private let deviceService: DeviceServiceProtocol
    private let jotFileService: JotFileServiceProtocol
    private let jotFilePreviewImageService: JotFilePreviewImageServiceProtocol

    init(
        localFileService: FileServiceProtocol,
        ubiquitousFileService: FileServiceProtocol,
        applicationService: ApplicationServiceProtocol,
        deviceService: DeviceServiceProtocol,
        jotFileService: JotFileServiceProtocol,
        jotFilePreviewImageService: JotFilePreviewImageServiceProtocol
    ) {
        self.localFileService = localFileService
        self.ubiquitousFileService = ubiquitousFileService
        self.applicationService = applicationService
        self.deviceService = deviceService
        self.jotFileService = jotFileService
        self.jotFilePreviewImageService = jotFilePreviewImageService
    }

    func getItems(location: JotsLocation) -> AsyncThrowingStream<[JotsItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch location {
                    case .root:
                        let ubiquitousDocumentsDirectory = try await ubiquitousFileService.documentsDirectory()
                        let localDocumentsDirectory = try await localFileService.documentsDirectory()

                        let documentsDirectories: [(storage: JotsFolderURL.Storage, directory: URL)] = [
                            (storage: .ubiquitous, directory: ubiquitousDocumentsDirectory),
                            (storage: .local, directory: localDocumentsDirectory),
                        ]
                        .compactMap { storage, directory in
                            guard let directory else {
                                return nil
                            }
                            return (storage: storage, directory: directory)
                        }

                        try await withThrowingTaskGroup(of: Void.self) { group in
                            for (storage, directory) in documentsDirectories {
                                let fileService = fileService(storage: storage)
                                group.addTask {
                                    for try await _ in fileService.directoryChanges(directory: directory) {
                                        let items = try documentsDirectories.flatMap { storage, directory in
                                            try listItems(directory: directory, storage: storage)
                                        }
                                        continuation.yield(sortItems(items))
                                    }
                                }
                            }
                            try await group.waitForAll()
                        }
                    case let .directory(directoryLocation):
                        let fileService = fileService(storage: mapStorage(directoryLocation.storage))
                        for try await _ in fileService.directoryChanges(directory: directoryLocation.url) {
                            let items = try listItems(
                                directory: directoryLocation.url,
                                storage: mapStorage(directoryLocation.storage)
                            )
                            continuation.yield(sortItems(items))
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func sortItems(_ items: [JotsItem]) -> [JotsItem] {
        let folders = items.compactMap { item -> FolderBusinessModel? in
            guard case let .folder(folder) = item else {
                return nil
            }
            return folder
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let jots = items.compactMap { item -> JotFile.Info? in
            guard case let .jot(jotFileInfo) = item else {
                return nil
            }
            return jotFileInfo
        }
        .sorted { a, b in
            (a.modificationDate ?? .distantPast) > (b.modificationDate ?? .distantPast)
        }

        return folders.map(JotsItem.folder) + jots.map(JotsItem.jot)
    }

    private func fileService(storage: JotsFolderURL.Storage) -> FileServiceProtocol {
        switch storage {
        case .local:
            localFileService
        case .ubiquitous:
            ubiquitousFileService
        }
    }

    private func mapStorage(_ storage: JotsLocation.Directory.Storage) -> JotsFolderURL.Storage {
        switch storage {
        case .local:
            .local
        case .ubiquitous:
            .ubiquitous
        }
    }

    private enum ListConstants {
        static func urlResourceKeys(isUbiquitous: Bool) -> [URLResourceKey] {
            var keys: [URLResourceKey] = [
                .contentModificationDateKey,
                .isWritableKey,
                .isReadableKey,
                .isDirectoryKey,
                .isRegularFileKey,
            ]
            if isUbiquitous {
                keys.append(.ubiquitousItemDownloadingStatusKey)
                keys.append(.ubiquitousItemIsDownloadingKey)
            }
            return keys
        }
    }

    private func listItems(
        directory: URL,
        storage: JotsFolderURL.Storage
    ) throws -> [JotsItem] {
        let fileService = fileService(storage: storage)
        let isUbiquitous = storage == .ubiquitous

        let urls = try fileService.listContents(
            directory: directory,
            properties: ListConstants.urlResourceKeys(isUbiquitous: isUbiquitous)
        )

        return try urls
            .map { url in
                let resourceKeys = Set(ListConstants.urlResourceKeys(isUbiquitous: isUbiquitous))
                let values = try url.resourceValues(forKeys: resourceKeys)
                return (url: url, properties: values)
            }
            .filter { _, properties in
                let isReadable = properties.isReadable == true
                let isWritable = properties.isWritable == true
                return isReadable && isWritable
            }
            .compactMap { url, properties -> JotsItem? in
                // 1. 폴더 생성 판정 분리
                if properties.isDirectory == true {
                    let folderModel = FolderBusinessModel(
                        url: url,
                        name: url.lastPathComponent,
                        modificationDate: properties.contentModificationDate,
                        ubiquitousInfo: fileService.ubiquitousInfo(url: url)
                    )
                    let folderItem: JotsItem = .folder(folderModel)
                    return folderItem
                }

                // 2. 일반 노트 파일 검증 분리
                guard properties.isRegularFile == true else { return nil }
                guard url.pathExtension == JotFile.Info.fileExtension else { return nil }

                // 3. 노트 아이템 명시적 생성 및 컴파일 타임아웃 우회
                let ubiquitousInfo = fileService.ubiquitousInfo(url: url)
                let cleanName = url.deletingPathExtension().lastPathComponent
                
                let jotFileInfo = JotFile.Info(
                    url: url,
                    name: cleanName,
                    modificationDate: properties.contentModificationDate,
                    ubiquitousInfo: ubiquitousInfo
                )
                
                let jotItem: JotsItem = .jot(jotFileInfo)
                return jotItem
            }
    }

    func shouldShowEnableICloudButton() -> Bool {
        !ubiquitousFileService.isEnabled()
    }

    func duplicate(jotFileInfo: JotFile.Info) throws -> JotFile.Info {
        try jotFileService.duplicate(jotFileInfo: jotFileInfo)
    }

    func createFolder(name: String, location: JotsLocation) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Failure.invalidFolderName
        }

        let parent: (directory: URL, storage: JotsFolderURL.Storage)
        switch location {
        case .root:
            if let directory = try await ubiquitousFileService.documentsDirectory() {
                parent = (directory: directory, storage: .ubiquitous)
            } else if let directory = try await localFileService.documentsDirectory() {
                parent = (directory: directory, storage: .local)
            } else {
                throw Failure.couldNotResolveDirectory
            }
        case let .directory(directoryLocation):
            parent = (directory: directoryLocation.url, storage: mapStorage(directoryLocation.storage))
        }

        let fileService = fileService(storage: parent.storage)
        let folderURL = parent.directory.appendingPathComponent(trimmed, isDirectory: true)
        try fileService.createDirectory(directoryURL: folderURL)
    }

    func renameFolder(folder: FolderBusinessModel, newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Failure.invalidFolderName
        }
        let storage: JotsFolderURL.Storage = folder.ubiquitousInfo == nil ? .local : .ubiquitous
        let fileService = fileService(storage: storage)
        let newURL = folder.url.deletingLastPathComponent().appendingPathComponent(trimmed, isDirectory: true)
        try fileService.moveFile(fileURL: folder.url, newFileURL: newURL)
    }

    func deleteFolder(folder: FolderBusinessModel) throws {
        let storage: JotsFolderURL.Storage = folder.ubiquitousInfo == nil ? .local : .ubiquitous
        let fileService = fileService(storage: storage)
        try fileService.removeFile(fileURL: folder.url)
    }

    func deleteJot(jotFileInfo: JotFile.Info) throws {
        try jotFileService.remove(jotFileInfo: jotFileInfo)
    }

    func moveJot(jotFileInfo: JotFile.Info, destinationFolder: FolderBusinessModel?) async throws {
        let isUbiquitous = jotFileInfo.ubiquitousInfo != nil
        let storage: JotsFolderURL.Storage = isUbiquitous ? .ubiquitous : .local
        let fileService = fileService(storage: storage)

        let destinationDirectory: URL
        if let destinationFolder {
            destinationDirectory = destinationFolder.url
        } else {
            guard let documentsDirectory = try await fileService.documentsDirectory() else {
                throw Failure.couldNotResolveDirectory
            }
            destinationDirectory = documentsDirectory
        }

        let destinationURL = destinationDirectory.appendingPathComponent(jotFileInfo.url.lastPathComponent)
        try fileService.moveFile(fileURL: jotFileInfo.url, newFileURL: destinationURL)
    }

    func listFolders(storage: JotsFolderURL.Storage) async throws -> [FolderBusinessModel] {
        let fileService = fileService(storage: storage)
        guard let root = try await fileService.documentsDirectory() else {
            return []
        }
        return try listFoldersRecursively(directory: root, storage: storage)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func listFoldersRecursively(
        directory: URL,
        storage: JotsFolderURL.Storage
    ) throws -> [FolderBusinessModel] {
        let fileService = fileService(storage: storage)
        let urls = try fileService.listContents(
            directory: directory,
            properties: ListConstants.urlResourceKeys(isUbiquitous: storage == .ubiquitous)
        )

        var folders = [FolderBusinessModel]()
        for url in urls {
            let properties = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard properties.isDirectory == true else {
                continue
            }
            let folder = FolderBusinessModel(
                url: url,
                name: url.lastPathComponent,
                modificationDate: properties.contentModificationDate,
                ubiquitousInfo: fileService.ubiquitousInfo(url: url)
            )
            folders.append(folder)
            folders.append(contentsOf: try listFoldersRecursively(directory: url, storage: storage))
        }
        return folders
    }

    func download(jotFileInfo: JotFile.Info) throws {
        try ubiquitousFileService.startDownload(fileURL: jotFileInfo.url)
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
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

protocol ExternalFileImportServiceProtocol: Sendable {

    /// Copies a file URL (potentially security-scoped) into the app's temporary directory and returns the copied URL.
    func importFileToTemporaryDirectory(sourceURL: URL) throws -> URL

    /// Reads the file contents using `NSFileCoordinator`.
    func readFileCoordinated(fileURL: URL) throws -> Data

    /// Convenience: imports to temp directory and then reads the contents.
    func importAndReadFile(sourceURL: URL) throws -> (importedURL: URL, data: Data)
}

struct ExternalFileImportService: ExternalFileImportServiceProtocol {

    enum Failure: Error {
        case couldNotCoordinate
        case couldNotCreateDestination
        case couldNotReadImportedFile
    }

    nonisolated(unsafe) private let fileManager: FileManager
    private let temporaryDirectory: URL

    init(
        fileManager: FileManager,
        temporaryDirectory: URL
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    func importFileToTemporaryDirectory(sourceURL: URL) throws -> URL {
        let granted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if granted {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        // Best-effort: if this is an iCloud Drive item, request download before coordination.
        // NSFileCoordinator often triggers downloads itself, but this improves reliability.
        if (try? sourceURL.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
            try? fileManager.startDownloadingUbiquitousItem(at: sourceURL)
        }

        var coordinatorError: NSError?
        var result: Result<URL, Error>?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: sourceURL,
            // `.forUploading` is the most robust option for File Provider / iCloud URLs.
            // It yields a readable URL (potentially a coordinated temporary copy) that we can safely copy.
            options: .forUploading,
            error: &coordinatorError
        ) { secureSourceURL in
            result = Result(catching: {
                let destinationURL = try makeUniqueDestinationURL(for: secureSourceURL)

                let parent = destinationURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parent.path) {
                    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                }

                do {
                    try fileManager.copyItem(at: secureSourceURL, to: destinationURL)
                } catch CocoaError.fileWriteFileExists {
                    // In the unlikely case we still collide, try again.
                    let retryURL = try makeUniqueDestinationURL(for: secureSourceURL)
                    try fileManager.copyItem(at: secureSourceURL, to: retryURL)
                    return retryURL
                }

                return destinationURL
            })
        }

        if let coordinatorError {
            throw coordinatorError
        }

        guard let result else {
            throw Failure.couldNotCoordinate
        }

        return try result.get()
    }

    func readFileCoordinated(fileURL: URL) throws -> Data {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var result: Result<Data, Error>?

        coordinator.coordinate(
            readingItemAt: fileURL,
            options: .withoutChanges,
            error: &coordinatorError
        ) { secureURL in
            result = Result(catching: {
                try Data(contentsOf: secureURL)
            })
        }

        if let coordinatorError {
            throw coordinatorError
        }

        guard let result else {
            throw Failure.couldNotCoordinate
        }

        return try result.get()
    }

    func importAndReadFile(sourceURL: URL) throws -> (importedURL: URL, data: Data) {
        let importedURL = try importFileToTemporaryDirectory(sourceURL: sourceURL)
        let data = try readFileCoordinated(fileURL: importedURL)
        return (importedURL: importedURL, data: data)
    }

    private func makeUniqueDestinationURL(for sourceURL: URL) throws -> URL {
        guard sourceURL.isFileURL else {
            throw Failure.couldNotCreateDestination
        }

        let ext = sourceURL.pathExtension
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let unique = UUID().uuidString

        return
            temporaryDirectory
            .appendingPathComponent("Imported", isDirectory: true)
            .appendingPathComponent("\(baseName)-\(unique)")
            .appendingPathExtension(ext)
    }
}

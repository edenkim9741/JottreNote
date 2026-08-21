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

import UIKit

protocol CreateJotRepositoryProtocol: Sendable {

    func createJot(
        name: String,
        directory: CreateJotCoordinatorFactory.Directory?,
        pdfData: Data?
    ) async throws -> JotFile.Info

    func importJotFile(
        name: String,
        data: Data,
        directory: CreateJotCoordinatorFactory.Directory?
    ) async throws -> JotFile.Info
}

extension CreateJotRepositoryProtocol {

    /// Batch imports keep the source title, adding a numeric suffix only when
    /// a note with that title already exists. The single-note workflow still
    /// reports collisions to the rename UI unchanged.
    func createJotResolvingNameCollision(
        name: String,
        directory: CreateJotCoordinatorFactory.Directory?,
        pdfData: Data
    ) async throws -> JotFile.Info {
        var index = 1

        while true {
            try Task.checkCancellation()
            let candidateName = index == 1 ? name : "\(name) \(index)"

            do {
                return try await createJot(
                    name: candidateName,
                    directory: directory,
                    pdfData: pdfData
                )
            } catch CreateJotRepository.Failure.fileExists {
                index += 1
            }
        }
    }
}

struct CreateJotRepository: CreateJotRepositoryProtocol {

    enum Failure: Error {
        case couldNotCreateFile
        case fileExists
    }

    private let fileService: FileServiceProtocol
    private let jotFileService: JotFileServiceProtocol

    init(
        fileService: FileServiceProtocol,
        jotFileService: JotFileServiceProtocol
    ) {
        self.fileService = fileService
        self.jotFileService = jotFileService
    }

    func createJot(
        name: String,
        directory: CreateJotCoordinatorFactory.Directory?,
        pdfData: Data?
    ) async throws -> JotFile.Info {
        let resolvedDirectory: URL

        if let directory {
            resolvedDirectory = directory.url
        } else if let documentsDirectory = try await fileService.documentsDirectory() {
            resolvedDirectory = documentsDirectory
        } else {
            throw Failure.couldNotCreateFile
        }

        let fileURL =
            resolvedDirectory
            .appendingPathComponent(name, isDirectory: false)
            .appendingPathExtension(JotFile.Info.fileExtension)

        let jot: Jot
        if let pdfData {
            let empty = Jot.makeEmpty()
            jot = Jot(version: empty.version, drawing: empty.drawing, width: empty.width, pdfData: pdfData)
        } else {
            jot = .makeEmpty()
        }
        let jotFile = JotFile(
            info: JotFile.Info(url: fileURL, name: name, modificationDate: nil),
            jot: jot
        )
        do {
            try jotFileService.create(jotFile: jotFile)
        } catch CocoaError.fileWriteFileExists {
            throw Failure.fileExists
        }
        return jotFile.info
    }

    func importJotFile(
        name: String,
        data: Data,
        directory: CreateJotCoordinatorFactory.Directory?
    ) async throws -> JotFile.Info {
        let resolvedDirectory: URL
        if let directory {
            resolvedDirectory = directory.url
        } else if let documentsDirectory = try await fileService.documentsDirectory() {
            resolvedDirectory = documentsDirectory
        } else {
            throw Failure.couldNotCreateFile
        }

        let fileURL = resolvedDirectory
            .appendingPathComponent(name, isDirectory: false)
            .appendingPathExtension(JotFile.Info.fileExtension)

        do {
            try fileService.createFile(fileURL: fileURL, data: data)
        } catch CocoaError.fileWriteFileExists {
            throw Failure.fileExists
        }
        return JotFile.Info(url: fileURL, name: name, modificationDate: nil)
    }
}

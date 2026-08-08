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

struct CreateJotRepository: CreateJotRepositoryProtocol {

    enum Failure: Error {
        case couldNotCreateFile
        case fileExists
    }

    private let localFileService: FileServiceProtocol
    private let ubiquitousFileService: FileServiceProtocol
    private let jotFileService: JotFileServiceProtocol

    init(
        localFileService: FileServiceProtocol,
        ubiquitousFileService: FileServiceProtocol,
        jotFileService: JotFileServiceProtocol
    ) {
        self.localFileService = localFileService
        self.ubiquitousFileService = ubiquitousFileService
        self.jotFileService = jotFileService
    }

    func createJot(
        name: String,
        directory: CreateJotCoordinatorFactory.Directory?,
        pdfData: Data?
    ) async throws -> JotFile.Info {
        let fileService: FileServiceProtocol
        let resolvedDirectory: URL
        let isUbiquitous: Bool

        if let directory {
            switch directory.storage {
            case .local:
                fileService = localFileService
                resolvedDirectory = directory.url
                isUbiquitous = false
            case .ubiquitous:
                fileService = ubiquitousFileService
                resolvedDirectory = directory.url
                isUbiquitous = true
            }
        } else if let ubiquitousDirectory = try await ubiquitousFileService.documentsDirectory() {
            fileService = ubiquitousFileService
            resolvedDirectory = ubiquitousDirectory
            isUbiquitous = true
        } else if let localDirectory = try await localFileService.documentsDirectory() {
            fileService = localFileService
            resolvedDirectory = localDirectory
            isUbiquitous = false
        } else {
            throw Failure.couldNotCreateFile
        }

        let fileURL =
            resolvedDirectory
            .appendingPathComponent(name, isDirectory: false)
            .appendingPathExtension(JotFile.Info.fileExtension)

        guard !fileService.fileExists(fileURL: fileURL) else {
            throw Failure.fileExists
        }

        let jot: Jot
        if let pdfData {
            let empty = Jot.makeEmpty()
            jot = Jot(version: empty.version, drawing: empty.drawing, width: empty.width, pdfData: pdfData)
        } else {
            jot = .makeEmpty()
        }
        let jotFile = JotFile(
            info: JotFile.Info(
                url: fileURL,
                name: name,
                modificationDate: nil,
                ubiquitousInfo: isUbiquitous ? UbiquitousInfo(downloadStatus: .current, isDownloading: false) : nil
            ),
            jot: jot
        )
        try jotFileService.write(jotFile: jotFile)
        return jotFile.info
    }

    func importJotFile(
        name: String,
        data: Data,
        directory: CreateJotCoordinatorFactory.Directory?
    ) async throws -> JotFile.Info {
        throw Failure.couldNotCreateFile
    }
}

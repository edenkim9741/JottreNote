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

protocol JotFileServiceProtocol: Sendable {
    func readJotFile(jotFileInfo: JotFile.Info) throws -> JotFile

    func write(jotFile: JotFile) throws

    func duplicate(jotFileInfo: JotFile.Info) throws -> JotFile.Info

    func rename(jotFileInfo: JotFile.Info, newName: String) throws -> JotFile.Info

    func remove(jotFileInfo: JotFile.Info) throws
}

struct JotFileService: JotFileServiceProtocol {

    enum Failure: Error {
        case couldNotResolveDocumentsDirectory
    }

    private let propertyListDecoder = PropertyListDecoder()
    private let propertyListEncoder = PropertyListEncoder()

    private let fileService: FileServiceProtocol

    init(fileService: FileServiceProtocol) {
        self.fileService = fileService
    }

    func readJotFile(jotFileInfo: JotFile.Info) throws -> JotFile {
        let data = try fileService.readFile(fileURL: jotFileInfo.url)
        let jot = try propertyListDecoder.decode(Jot.self, from: data)
        return JotFile(info: jotFileInfo, jot: jot)
    }

    func write(jotFile: JotFile) throws {
        let data = try propertyListEncoder.encode(jotFile.jot)
        try fileService.writeFile(fileURL: jotFile.info.url, data: data)
    }

    func duplicate(jotFileInfo: JotFile.Info) throws -> JotFile.Info {
        let duplicatedFileURL = try fileService.duplicateFile(fileURL: jotFileInfo.url)
        return JotFile.Info(
            url: duplicatedFileURL,
            name: duplicatedFileURL.deletingPathExtension().lastPathComponent,
            modificationDate: jotFileInfo.modificationDate
        )
    }

    func rename(jotFileInfo: JotFile.Info, newName: String) throws -> JotFile.Info {
        let newFileURL =
            jotFileInfo.url
            .deletingPathExtension()
            .deletingLastPathComponent()
            .appendingPathComponent(newName)
            .appendingPathExtension(jotFileInfo.url.pathExtension)

        try fileService.moveFile(fileURL: jotFileInfo.url, newFileURL: newFileURL)

        return JotFile.Info(
            url: newFileURL,
            name: newName,
            modificationDate: jotFileInfo.modificationDate
        )
    }

    func remove(jotFileInfo: JotFile.Info) throws {
        try fileService.removeFile(fileURL: jotFileInfo.url)
    }
}

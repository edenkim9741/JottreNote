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
    /// Materializes and reads a potentially security-scoped external file.
    /// The returned bytes remain valid after coordinated access ends.
    func readExternalFile(sourceURL: URL) throws -> Data
}

struct ExternalFileImportService: ExternalFileImportServiceProtocol {

    private static let maximumFileSize = 512 * 1024 * 1024

    private let startAccessingSecurityScopedResource: @Sendable (_ url: URL) -> Bool
    private let stopAccessingSecurityScopedResource: @Sendable (_ url: URL) -> Void

    enum Failure: Error {
        case couldNotCoordinate
        case fileTooLarge
    }

    init(
        startAccessingSecurityScopedResource: @Sendable @escaping (_ url: URL) -> Bool = {
            $0.startAccessingSecurityScopedResource()
        },
        stopAccessingSecurityScopedResource: @Sendable @escaping (_ url: URL) -> Void = {
            $0.stopAccessingSecurityScopedResource()
        }
    ) {
        self.startAccessingSecurityScopedResource = startAccessingSecurityScopedResource
        self.stopAccessingSecurityScopedResource = stopAccessingSecurityScopedResource
    }

    func readExternalFile(sourceURL: URL) throws -> Data {
        let granted = startAccessingSecurityScopedResource(sourceURL)
        defer {
            if granted {
                stopAccessingSecurityScopedResource(sourceURL)
            }
        }

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var result: Result<Data, Error>?

        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: .withoutChanges,
            error: &coordinatorError
        ) { secureURL in
            result = Result(catching: {
                let fileSize = try? secureURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard fileSize.map({ $0 <= Self.maximumFileSize }) ?? true else {
                    throw Failure.fileTooLarge
                }
                // File Provider URLs can be temporary. Return owned bytes before
                // the coordination/security scope closes rather than a mapping
                // whose backing file may disappear.
                let data = try Data(contentsOf: secureURL)
                guard data.count <= Self.maximumFileSize else { throw Failure.fileTooLarge }
                return data
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
}

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

import CryptoKit
import UIKit

actor CachedJotFilePreviewImageService: JotFilePreviewImageServiceProtocol {

    private enum Constants {
        static let diskCacheDirectoryName = "JotFilePreviewCache"
        static let memoryCacheSizeLimit = 20 * 1024 * 1024  // 20 MB
        static let diskCacheSizeLimit = 100 * 1024 * 1024  // 100 MB
        static let diskCacheTrimTarget = 80 * 1024 * 1024  // 80 MB
        static let diskSweepInterval = 32
        static let cacheSchemaVersion = 2
    }

    private struct CacheKey: CustomStringConvertible {
        let jotFilePath: String
        let modificationDate: Date?
        let userInterfaceStyle: UIUserInterfaceStyle
        let displayScale: CGFloat

        var description: String {
            [
                jotFilePath.description,
                modificationDate.map(\.timeIntervalSince1970.description),
                userInterfaceStyle.rawValue.description,
                displayScale.description,
            ]
            .compactMap { $0 }
            .joined(separator: "|")
        }
    }

    private let localFileService: FileServiceProtocol
    private let jotFilePreviewImageService: JotFilePreviewImageServiceProtocol
    private let memoryCache: NSCache<NSString, NSData>
    private let temporaryDirectory: URL
    private var inFlightRequests: [String: Task<Data, any Error>] = [:]
    private var requestsSinceDiskSweep = Constants.diskSweepInterval

    init(
        localFileService: FileServiceProtocol,
        jotFilePreviewImageService: JotFilePreviewImageServiceProtocol
    ) {
        self.localFileService = localFileService
        self.jotFilePreviewImageService = jotFilePreviewImageService

        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = Constants.memoryCacheSizeLimit
        self.memoryCache = cache

        temporaryDirectory =
            localFileService
            .temporaryDirectory()
            .appendingPathComponent(Constants.diskCacheDirectoryName, isDirectory: true)

        try? localFileService.createDirectory(directoryURL: temporaryDirectory)
    }

    func getPreviewImageData(
        jotFileInfo: JotFile.Info,
        userInterfaceStyle: UIUserInterfaceStyle,
        displayScale: CGFloat
    ) async throws -> Data {
        try Task.checkCancellation()
        sweepDiskCacheIfNeeded()
        // Without a file revision there is no safe invalidation key. Caching
        // such entries would return a permanently stale preview after edits.
        guard let modificationDate = jotFileInfo.modificationDate else {
            let rendered = try await jotFilePreviewImageService.getPreviewImageData(
                jotFileInfo: jotFileInfo,
                userInterfaceStyle: userInterfaceStyle,
                displayScale: displayScale
            )
            try Task.checkCancellation()
            return rendered
        }

        let cacheKey = makeCacheKey(
            jotFilePath: jotFileInfo.url.path,
            modificationDate: modificationDate,
            userInterfaceStyle: userInterfaceStyle,
            displayScale: displayScale
        )
        let memoryCacheKey = cacheKey as NSString

        if let cached = memoryCache.object(forKey: memoryCacheKey) {
            return cached as Data
        }

        if let request = inFlightRequests[cacheKey] {
            return try await request.value
        }

        let diskCacheFileURL = temporaryDirectory.appendingPathComponent(
            cacheKey,
            isDirectory: false
        )
        let localFileService = localFileService
        let renderer = jotFilePreviewImageService
        let request = Task<Data, any Error> {
            if let cached = try? localFileService.readFile(fileURL: diskCacheFileURL) {
                return cached
            }

            let rendered = try await renderer.getPreviewImageData(
                jotFileInfo: jotFileInfo,
                userInterfaceStyle: userInterfaceStyle,
                displayScale: displayScale
            )
            try? localFileService.writeFile(fileURL: diskCacheFileURL, data: rendered)
            return rendered
        }
        inFlightRequests[cacheKey] = request

        do {
            let previewImageData = try await request.value
            try Task.checkCancellation()
            inFlightRequests.removeValue(forKey: cacheKey)

            memoryCache.setObject(
                previewImageData as NSData,
                forKey: memoryCacheKey,
                cost: previewImageData.count
            )
            return previewImageData
        } catch {
            inFlightRequests.removeValue(forKey: cacheKey)
            throw error
        }
    }

    private func makeCacheKey(
        jotFilePath: String,
        modificationDate: Date,
        userInterfaceStyle: UIUserInterfaceStyle,
        displayScale: CGFloat
    ) -> String {
        let keyDescription = CacheKey(
            jotFilePath: jotFilePath,
            modificationDate: modificationDate,
            userInterfaceStyle: userInterfaceStyle,
            displayScale: displayScale
        ).description
        let versionedKey = "v\(Constants.cacheSchemaVersion)|\(keyDescription)"
        return SHA256.hash(
            data: Data(versionedKey.utf8)
        )
        .map { String(format: "%02x", $0) }
        .joined()
    }

    private func sweepDiskCacheIfNeeded() {
        requestsSinceDiskSweep += 1
        guard requestsSinceDiskSweep >= Constants.diskSweepInterval else { return }
        requestsSinceDiskSweep = 0

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard
            let urls = try? localFileService.listContents(
                directory: temporaryDirectory,
                properties: keys
            )
        else { return }

        let resourceKeys = Set(keys)
        let entries = urls.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                values.isRegularFile == true
            else { return nil }
            return (url, max(0, values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var totalSize = entries.reduce(into: 0) { $0 += $1.size }
        guard totalSize > Constants.diskCacheSizeLimit else { return }

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard totalSize > Constants.diskCacheTrimTarget else { break }
            do {
                try localFileService.removeFile(fileURL: entry.url)
                totalSize -= entry.size
            } catch {
                // Cache eviction is best-effort; a concurrently used file can
                // be retried during the next bounded sweep.
            }
        }
    }
}

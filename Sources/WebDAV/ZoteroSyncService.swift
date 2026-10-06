import CryptoKit
import Compression
import Foundation
import PDFKit

struct ZoteroSyncService: Sendable {

    private let service: WebDAVService
    private let cacheDirectory: URL
    private let rootPath: String
    private let apiClient: ZoteroAPIClient

    init(
        service: WebDAVService,
        cacheDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("JottrenoteZotero", isDirectory: true),
        rootPath: String = "zotero",
        apiClient: ZoteroAPIClient
    ) {
        self.service = service
        self.cacheDirectory = cacheDirectory
        self.rootPath = rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiClient = apiClient
    }

    func download(documentID: String) async throws -> Data {
        guard Self.isValidKey(documentID) else { throw Failure.invalidKey }
        let archiveData = try await service.download(remotePath: zipPath(for: documentID))
        let extractedDirectory = cacheDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: extractedDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: extractedDirectory) }
        let entries = try ZoteroZIPArchive.extract(archiveData, to: extractedDirectory)
        guard let pdfURL = entries.first(where: { $0.pathExtension.lowercased() == "pdf" }) ?? entries.first else {
            throw Failure.pdfNotFound
        }
        return try Self.restoreHybridPDF(fromPDFAt: pdfURL, extractedFiles: entries)
    }

    func deleteRemoteAttachment(documentID: String) async throws {
        guard Self.isValidKey(documentID) else { throw Failure.invalidKey }
        _ = try await service.delete(remotePath: zipPath(for: documentID))
        _ = try await service.delete(remotePath: propPath(for: documentID))
    }

    func upload(
        documentID: String,
        data: Data,
        metadata: ZoteroUploadMetadata
    ) async throws {
        guard Self.isValidKey(documentID) else { throw Failure.invalidKey }
        let package = try await Task.detached(priority: .utility) {
            try Self.makeUploadPackage(documentID: documentID, data: data, metadata: metadata)
        }.value
        let filename = package.filename
        let archiveData = package.archiveData
        let checksum = package.archiveMD5
        let pdfChecksum = package.pdfMD5
        let mtime = package.mtime
        let modificationDate = metadata.modificationDate ?? Date()
        let zipRemotePath = zipPath(for: documentID)
        let zipURL = service.baseURL.appendingPathComponent(zipRemotePath)
        print("[ZoteroUpload] Uploading [\(documentID)].zip (\(archiveData.count) bytes) to \(zipURL)...")
        let zipStatus = try await service.upload(
            data: archiveData,
            remotePath: zipRemotePath,
            metadata: ZoteroUploadMetadata(
                modificationDate: modificationDate,
                md5: checksum,
                modificationTimeMilliseconds: mtime
            )
        )
        print("[ZoteroUpload] HTTP Response: \(zipStatus)")
        let properties = Self.propData(mtime: mtime, md5: pdfChecksum)
        let propRemotePath = propPath(for: documentID)
        let propURL = service.baseURL.appendingPathComponent(propRemotePath)
        print("[ZoteroUpload] Uploading [\(documentID)].prop (\(properties.count) bytes) to \(propURL)...")
        let propStatus = try await service.upload(data: properties, remotePath: propRemotePath)
        print("[ZoteroUpload] [\(documentID)].prop HTTP Response: \(propStatus)")
        try await apiClient.updateWebDAVAttachment(
            key: documentID,
            filename: filename,
            md5: pdfChecksum,
            mtime: mtime
        )
    }

    private struct UploadPackage: Sendable {
        let filename: String
        let archiveData: Data
        let archiveMD5: String
        let pdfMD5: String
        let mtime: Int64
    }

    private static func makeUploadPackage(
        documentID: String,
        data: Data,
        metadata: ZoteroUploadMetadata
    ) throws -> UploadPackage {
        let filename = safePDFFileName(metadata.filename, fallback: "\(documentID).pdf")
        let pdfData = HybridPDFManager.pdfData(in: data)
        let jotPayload = HybridPDFManager.embeddedJotData(in: data)
        guard let pdf = PDFDocument(data: pdfData), pdf.pageCount > 0 else {
            throw Failure.invalidPDF
        }
        var entries = [ZoteroZIPArchive.Entry(path: filename, data: pdfData)]
        if let jotPayload {
            // Keep the file Zotero opens as a standards-compliant PDF. Some
            // PDFKit and desktop readers misread multi-page files when bytes
            // follow %%EOF, so Jottre's edit state travels as a ZIP sidecar.
            entries.append(ZoteroZIPArchive.Entry(path: "\(filename).jot", data: jotPayload))
        }
        print("[ZoteroUpload] Packaging standard PDF: pages=\(pdf.pageCount), bytes=\(pdfData.count), Jot sidecar bytes=\(jotPayload?.count ?? 0)")
        let archiveData = try ZoteroZIPArchive.archive(files: entries)
        let mtime = metadata.modificationTimeMilliseconds
            ?? Int64(((metadata.modificationDate ?? Date()).timeIntervalSince1970 * 1_000).rounded())
        return UploadPackage(
            filename: filename,
            archiveData: archiveData,
            archiveMD5: md5Hex(archiveData),
            pdfMD5: md5Hex(pdfData),
            mtime: mtime
        )
    }

    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func modificationTimeMilliseconds(for date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    static func archiveForTesting(documentID: String, data: Data) throws -> Data {
        try archive(data: data, filename: "\(documentID).pdf")
    }

    static func extractArchiveForTesting(
        _ archive: Data,
        to directory: URL
    ) throws -> [URL] {
        try ZoteroZIPArchive.extract(archive, to: directory)
    }

    static func restoreHybridPDFForTesting(fromPDFAt pdfURL: URL, extractedFiles: [URL]) throws -> Data {
        try restoreHybridPDF(fromPDFAt: pdfURL, extractedFiles: extractedFiles)
    }

    private static func archive(data: Data, filename: String) throws -> Data {
        let pdfData = HybridPDFManager.pdfData(in: data)
        var entries = [ZoteroZIPArchive.Entry(path: filename, data: pdfData)]
        if let jotPayload = HybridPDFManager.embeddedJotData(in: data) {
            entries.append(ZoteroZIPArchive.Entry(path: "\(filename).jot", data: jotPayload))
        }
        return try ZoteroZIPArchive.archive(files: entries)
    }

    private static func restoreHybridPDF(fromPDFAt pdfURL: URL, extractedFiles: [URL]) throws -> Data {
        let pdfData = try Data(contentsOf: pdfURL)
        let sidecarURL = extractedFiles.first {
            $0.lastPathComponent == "\(pdfURL.lastPathComponent).jot"
        }
        guard let sidecarURL else {
            // Existing WebDAV archives contain a hybrid PDF directly.
            return pdfData
        }
        return try HybridPDFManager.embedJotPreservingSourcePDF(
            pdfData: pdfData,
            jotData: Data(contentsOf: sidecarURL)
        )
    }

    private func zipPath(for key: String) -> String { rootPath.isEmpty ? "\(key).zip" : "\(rootPath)/\(key).zip" }
    private func propPath(for key: String) -> String { rootPath.isEmpty ? "\(key).prop" : "\(rootPath)/\(key).prop" }

    static func isValidKey(_ key: String) -> Bool {
        let allowed = Set("23456789ABCDEFGHIJKLMNPQRSTUVWXYZ")
        return key.count == 8 && key.allSatisfy { allowed.contains($0) }
    }

    private static func safePDFFileName(_ requested: String?, fallback: String) -> String {
        let candidate = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        let leaf = (candidate?.isEmpty == false ? candidate! : fallback)
            .replacingOccurrences(of: "\\", with: "/")
            .components(separatedBy: "/").last ?? fallback
        return leaf.isEmpty ? fallback : leaf
    }

    private static func propData(mtime: Int64, md5: String) -> Data {
        Data("<properties version=\"1\"><mtime>\(mtime)</mtime><hash>\(md5)</hash></properties>".utf8)
    }

    enum Failure: Error {
        case pdfNotFound
        case invalidKey
        case invalidPDF
    }
}

struct ZoteroUploadMetadata: Sendable, Hashable {
    var modificationDate: Date? = nil
    var md5: String? = nil
    var modificationTimeMilliseconds: Int64? = nil
    var filename: String? = nil
}

enum ZoteroZIPArchive {

    struct Entry {
        let path: String
        let data: Data
    }

    static func archive(files: [Entry]) throws -> Data {
        var local = Data()
        var central = Data()
        var offset = 0

        for file in files {
            let name = Data(file.path.utf8)
            let crc = crc32(file.data)
            appendUInt32(0x04034b50, to: &local)
            appendUInt16(20, to: &local)
            appendUInt16(0x0800, to: &local)
            appendUInt16(0, to: &local)
            appendUInt16(0, to: &local)
            appendUInt16(0, to: &local)
            appendUInt32(crc, to: &local)
            appendUInt32(UInt32(file.data.count), to: &local)
            appendUInt32(UInt32(file.data.count), to: &local)
            appendUInt16(UInt16(name.count), to: &local)
            appendUInt16(0, to: &local)
            local.append(name)
            local.append(file.data)

            appendUInt32(0x02014b50, to: &central)
            appendUInt16(20, to: &central)
            appendUInt16(20, to: &central)
            appendUInt16(0x0800, to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt32(crc, to: &central)
            appendUInt32(UInt32(file.data.count), to: &central)
            appendUInt32(UInt32(file.data.count), to: &central)
            appendUInt16(UInt16(name.count), to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt32(0, to: &central)
            appendUInt32(UInt32(offset), to: &central)
            central.append(name)

            offset = local.count
        }

        var result = local
        let centralOffset = result.count
        result.append(central)
        appendUInt32(0x06054b50, to: &result)
        appendUInt16(0, to: &result)
        appendUInt16(0, to: &result)
        appendUInt16(UInt16(files.count), to: &result)
        appendUInt16(UInt16(files.count), to: &result)
        appendUInt32(UInt32(central.count), to: &result)
        appendUInt32(UInt32(centralOffset), to: &result)
        appendUInt16(0, to: &result)
        return result
    }

    static func extract(_ archive: Data, to directory: URL) throws -> [URL] {
        var cursor = 0
        var urls: [URL] = []
        while cursor + 30 <= archive.count {
            guard readUInt32(archive, at: cursor) == 0x04034b50 else { break }
            let flags = readUInt16(archive, at: cursor + 6)
            let method = readUInt16(archive, at: cursor + 8)
            let compressedSize = Int(readUInt32(archive, at: cursor + 18))
            let nameLength = Int(readUInt16(archive, at: cursor + 26))
            let extraLength = Int(readUInt16(archive, at: cursor + 28))
            let nameStart = cursor + 30
            let nameEnd = nameStart + nameLength
            guard nameEnd <= archive.count else { throw Failure.invalidArchive }
            guard flags & 0x08 == 0,
                  let name = String(
                    data: archive.subdata(in: nameStart..<nameEnd),
                    encoding: .utf8
                  )
            else { throw Failure.invalidArchive }
            let dataStart = cursor + 30 + nameLength + extraLength
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= archive.count else { throw Failure.invalidArchive }
            let compressed = archive.subdata(in: dataStart..<dataEnd)
            let data: Data
            switch method {
            case 0:
                data = compressed
            case 8:
                data = try inflate(compressed, expectedSize: Int(readUInt32(archive, at: cursor + 22)))
            default:
                throw Failure.unsupportedCompression
            }
            let normalizedName = name.replacingOccurrences(of: "\\", with: "/")
            guard !normalizedName.hasPrefix("/"),
                  !normalizedName.split(separator: "/").contains("..") else {
                throw Failure.invalidArchive
            }
            let outputURL = directory.appendingPathComponent(normalizedName)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outputURL, options: .atomic)
            urls.append(outputURL)
            cursor = dataEnd
        }
        guard !urls.isEmpty else { throw Failure.invalidArchive }
        return urls
    }

    enum Failure: Error {
        case invalidArchive
        case unsupportedCompression
        case decompressionFailed
    }

    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        var output = Data(repeating: 0, count: max(expectedSize, data.count * 4, 64 * 1024))
        let count = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard count > 0 else { throw Failure.decompressionFailed }
        output.count = count
        return output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0)
            }
        }
        return crc ^ 0xffffffff
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8(value >> 8))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        appendUInt16(UInt16(value & 0xffff), to: &data)
        appendUInt16(UInt16(value >> 16), to: &data)
    }

    private static func readUInt16(_ data: Data, at index: Int) -> UInt16 {
        UInt16(data[index]) | UInt16(data[index + 1]) << 8
    }

    private static func readUInt32(_ data: Data, at index: Int) -> UInt32 {
        UInt32(readUInt16(data, at: index)) | UInt32(readUInt16(data, at: index + 2)) << 16
    }
}

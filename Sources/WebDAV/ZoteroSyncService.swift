import Compression
import CryptoKit
import Foundation
import PDFKit

enum ZoteroDownloadSource: String, Sendable {
    case documentOpen
    case librarySync
    case conflictResolution
}

struct ZoteroDownloadContext: Sendable {
    let requestID: String
    let attachmentID: String
    let source: ZoteroDownloadSource
    let relatedAttachmentID: String?
    private let attemptState = ZoteroDownloadAttemptState()

    var attempt: Int { attemptState.value }
    func setAttempt(_ attempt: Int) { attemptState.value = attempt }

    init(source: ZoteroDownloadSource, relatedAttachmentID: String? = nil, requestID: String? = nil) {
        self.requestID = requestID ?? UUID().uuidString
        attachmentID = UUID().uuidString
        self.source = source
        self.relatedAttachmentID = relatedAttachmentID
    }

    var eventDetails: [String: Any] {
        var details: [String: Any] = ["requestID": requestID, "attachmentID": attachmentID, "downloadPath": source.rawValue]
        if let relatedAttachmentID { details["relatedAttachmentID"] = relatedAttachmentID }
        return details
    }
}

private final class ZoteroDownloadAttemptState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 1
    var value: Int {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

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

    func download(
        documentID: String,
        context: ZoteroDownloadContext? = nil,
        expectedRemoteMD5: String? = nil
    ) async throws -> Data {
        try await AsyncResourceAccessCoordinator.shared.withAccess(to: resourceKey(for: documentID)) {
            let context = context ?? ZoteroDownloadContext(source: .documentOpen)
            let startedAt = Date()
            var currentStage = "webDAVRequest"
            var archiveByteCount: Int?
            let webDAVStartedAt = Date()
            Self.recordDownloadEvent("zotero.download.started", context: context, stage: "keyValidation", attempt: context.attempt)
            do {
                guard Self.isValidKey(documentID) else { throw Failure.invalidKey }
                let archiveData = try await service.download(
                    remotePath: zipPath(for: documentID),
                    diagnosticContext: context
                )
                Self.recordDownloadEvent(
                    "zotero.download.archiveReceived",
                    context: context,
                    stage: "archiveReceived",
                    attempt: context.attempt,
                    extra: [
                        "zipBytes": archiveData.count,
                        "downloadDurationMilliseconds": Date().timeIntervalSince(webDAVStartedAt) * 1_000
                    ]
                )
                archiveByteCount = archiveData.count
                let archiveBytes = archiveData.count
                currentStage = "zipExtraction"
                let extractionStartedAt = Date()
                Self.recordDownloadEvent("zotero.download.extractionStarted", context: context, stage: "zipExtraction", attempt: context.attempt)
                let result = try await Task.detached(priority: .utility) {
                    try TemporaryFileWorkspace.withDirectory(in: cacheDirectory) { extractedDirectory in
                        let entries = try ZoteroZIPArchive.extract(archiveData, to: extractedDirectory)
                        Self.recordDownloadEvent(
                            "zotero.download.extractionCompleted",
                            context: context,
                            stage: "zipExtraction",
                            attempt: context.attempt,
                            extra: [
                                "extractedFileCount": entries.count,
                                "extractionDurationMilliseconds": Date().timeIntervalSince(extractionStartedAt) * 1_000
                            ]
                        )
                        let pdfEntries = entries.filter { $0.pathExtension.lowercased() == "pdf" }
                            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                        guard let pdfURL = pdfEntries.first else {
                            Self.recordDownloadEvent(
                                "zotero.download.validationFailed",
                                context: context,
                                stage: "pdfSelection",
                                attempt: context.attempt,
                                extra: ["failureReason": "pdfNotFound"]
                            )
                            throw Failure.pdfNotFound
                        }
                        let standardPDF = try Data(contentsOf: pdfURL)
                        guard let pdf = PDFDocument(data: standardPDF), pdf.pageCount > 0 else {
                            Self.recordDownloadEvent(
                                "zotero.download.validationFailed",
                                context: context,
                                stage: "pdfValidation",
                                attempt: context.attempt,
                                extra: ["failureReason": "invalidPDF", "pdfBytes": standardPDF.count]
                            )
                            throw Failure.invalidPDF
                        }
                        let hybridData: Data
                        do {
                            hybridData = try Self.restoreHybridPDF(fromPDFAt: pdfURL, extractedFiles: entries)
                        } catch {
                            Self.recordDownloadEvent(
                                "zotero.download.validationFailed",
                                context: context,
                                stage: "hybridPDFValidation",
                                attempt: context.attempt,
                                extra: ["errorType": String(reflecting: type(of: error))]
                            )
                            throw error
                        }
                        guard let restoredPDF = PDFDocument(data: HybridPDFManager.pdfData(in: hybridData)), restoredPDF.pageCount > 0 else {
                            Self.recordDownloadEvent(
                                "zotero.download.validationFailed",
                                context: context,
                                stage: "hybridPDFValidation",
                                attempt: context.attempt,
                                extra: ["failureReason": "invalidPDF"]
                            )
                            throw Failure.invalidPDF
                        }
                        // Zotero attachment `md5` describes the original PDF bytes in
                        // the WebDAV ZIP. PDFKit/Hybrid restoration may serialize those
                        // bytes differently, so validate the extracted source bytes.
                        let actualRemoteMD5 = Self.md5Hex(standardPDF)
                        Self.recordDownloadEvent(
                            "zotero.download.metadataValidationStarted",
                            context: context,
                            stage: "remoteMetadataValidation",
                            attempt: context.attempt,
                            extra: [
                                "verificationRepresentation": "extractedOriginalPDFBytes",
                                "expectedMetadataMD5": (expectedRemoteMD5 as Any?) ?? NSNull(),
                                "extractedPDFMD5": actualRemoteMD5,
                                "restoredHybridPDFPayloadMD5": Self.md5Hex(HybridPDFManager.pdfData(in: hybridData)),
                                "zipBytes": archiveBytes,
                                "pdfBytes": standardPDF.count
                            ]
                        )
                        if let expectedRemoteMD5 = expectedRemoteMD5?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                           !expectedRemoteMD5.isEmpty,
                           expectedRemoteMD5 != actualRemoteMD5 {
                            Self.recordDownloadEvent(
                                "zotero.download.metadataValidationFailed",
                                context: context,
                                stage: "remoteMetadataValidation",
                                attempt: context.attempt,
                                extra: [
                                    "failureReason": "downloadedPDFChecksumDoesNotMatchAttachmentMetadata",
                                    "verificationRepresentation": "extractedOriginalPDFBytes",
                                    "expectedMetadataMD5": expectedRemoteMD5,
                                    "extractedPDFMD5": actualRemoteMD5
                                ]
                            )
                            throw Failure.remoteDownloadMetadataMismatch
                        }
                        return hybridData
                    }
                }.value
                Self.recordDownloadEvent(
                    "zotero.download.completed",
                    context: context,
                    stage: "complete",
                    attempt: context.attempt,
                    extra: ["durationMilliseconds": Date().timeIntervalSince(startedAt) * 1_000, "pdfValid": true]
                )
                return result
            } catch {
                if Self.isCancellation(error) { throw error }
                Self.recordDownloadFailure(
                    error,
                    context: context,
                    stageOverride: currentStage,
                    startedAt: startedAt,
                    byteCount: archiveByteCount
                )
                throw error
            }
        }
    }

    private static func recordDownloadEvent(
        _ name: String,
        context: ZoteroDownloadContext,
        stage: String,
        attempt: Int,
        extra: [String: Any] = [:]
    ) {
        var details = context.eventDetails
        details["stage"] = stage
        details["attempt"] = attempt
        details.merge(extra) { _, new in new }
        JottreDiagnostics.shared.record(name, details: details)
    }

    static func recordDownloadFailure(
        _ error: Error,
        context: ZoteroDownloadContext,
        stageOverride: String? = nil,
        startedAt: Date? = nil,
        byteCount: Int? = nil
    ) {
        let nsError = error as NSError
        var stage = stageOverride ?? "webDAVRequest"
        var reason = "downloadFailed"
        if case Failure.invalidKey = error { stage = "keyValidation"; reason = "invalidAttachmentKey" }
        else if case Failure.pdfNotFound = error { stage = "pdfSelection"; reason = "pdfNotFound" }
        else if case Failure.invalidPDF = error { stage = "pdfValidation"; reason = "invalidPDF" }
        else if case Failure.remoteDownloadMetadataMismatch = error {
            stage = "remoteMetadataValidation"
            reason = "downloadedPDFChecksumDoesNotMatchAttachmentMetadata"
        }
        else if error is HybridPDFManager.Failure || (error as? Failure).map({ failure in
            if case .invalidHybridPDF = failure { return true }
            return false
        }) == true {
            stage = "hybridPDFValidation"
            reason = "invalidHybridPDF"
        }
        else if let archiveFailure = error as? ZoteroZIPArchive.Failure {
            stage = "zipExtraction"
            if case .checksumMismatch = archiveFailure { reason = "archiveChecksumMismatch" }
            else if case .unsupportedCompression = archiveFailure { reason = "unsupportedCompression" }
            else if case .decompressionFailed = archiveFailure { reason = "decompressionFailed" }
            else { reason = "invalidArchive" }
        }
        else if case ZoteroCacheStore.Failure.remoteDownloadMetadataMismatch = error {
            stage = "remoteMetadataValidation"
            reason = "downloadedPDFChecksumDoesNotMatchAttachmentMetadata"
        }
        else if case WebDAVService.Failure.unexpectedResponse(let status) = error {
            stage = "webDAVHTTP"
            reason = status == 404 ? "httpNotFound" : status == 401 ? "authenticationFailed" : status == 403 ? "permissionDenied" : (500...599).contains(status) ? "serverError" : "httpFailure"
        } else if let urlError = error as? URLError {
            reason = "urlSession.\(urlError.code.rawValue)"
        }
        var underlyingErrors: [[String: Any]] = []
        var underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        for _ in 0..<3 {
            guard let current = underlying else { break }
            underlyingErrors.append(["errorDomain": current.domain, "errorCode": current.code])
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        var details = context.eventDetails
        details["stage"] = stage
        details["attempt"] = context.attempt
        details["errorType"] = String(reflecting: type(of: error))
        details["errorDomain"] = nsError.domain
        details["errorCode"] = nsError.code
        if let urlError = error as? URLError { details["urlSessionErrorCode"] = urlError.code.rawValue }
        details["failureReason"] = reason
        if !underlyingErrors.isEmpty { details["underlyingErrors"] = underlyingErrors }
        if let startedAt { details["durationMilliseconds"] = Date().timeIntervalSince(startedAt) * 1_000 }
        if case WebDAVService.Failure.unexpectedResponse(let status) = error { details["httpStatus"] = status }
        if let byteCount { details["zipBytes"] = byteCount }
        JottreDiagnostics.shared.record("zotero.download.failed", details: details)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError
    }

    func deleteRemoteAttachment(documentID: String) async throws {
        try await AsyncResourceAccessCoordinator.shared.withAccess(to: resourceKey(for: documentID)) {

            guard Self.isValidKey(documentID) else { throw Failure.invalidKey }
            _ = try await service.delete(remotePath: zipPath(for: documentID))
            _ = try await service.delete(remotePath: propPath(for: documentID))

        }
    }

    func upload(
        documentID: String,
        data: Data,
        metadata: ZoteroUploadMetadata
    ) async throws {
        try await AsyncResourceAccessCoordinator.shared.withAccess(to: resourceKey(for: documentID)) {

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
    }

    private func resourceKey(for key: String) -> String {
        service.baseURL.appendingPathComponent(zipPath(for: key)).absoluteString + "|" + service.username
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
        print(
            "[ZoteroUpload] Packaging standard PDF: pages=\(pdf.pageCount), bytes=\(pdfData.count), Jot sidecar bytes=\(jotPayload?.count ?? 0)"
        )
        let archiveData = try ZoteroZIPArchive.archive(files: entries)
        let mtime =
            metadata.modificationTimeMilliseconds
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
        let hybrid = try HybridPDFManager.embedJotPreservingSourcePDF(
            pdfData: pdfData,
            jotData: Data(contentsOf: sidecarURL)
        )
        _ = try HybridPDFManager.load(data: hybrid)
        return hybrid
    }

    private func zipPath(for key: String) -> String { rootPath.isEmpty ? "\(key).zip" : "\(rootPath)/\(key).zip" }
    private func propPath(for key: String) -> String { rootPath.isEmpty ? "\(key).prop" : "\(rootPath)/\(key).prop" }

    static func isValidKey(_ key: String) -> Bool {
        let allowed = Set("23456789ABCDEFGHIJKLMNPQRSTUVWXYZ")
        return key.count == 8 && key.allSatisfy { allowed.contains($0) }
    }

    private static func safePDFFileName(_ requested: String?, fallback: String) -> String {
        let candidate = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        let leaf =
            (candidate?.isEmpty == false ? candidate! : fallback)
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
        case invalidHybridPDF
        case remoteDownloadMetadataMismatch
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
            appendUInt32(0x0403_4b50, to: &local)
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

            appendUInt32(0x0201_4b50, to: &central)
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
        appendUInt32(0x0605_4b50, to: &result)
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
        guard archive.count >= 22 else { throw Failure.invalidArchive }
        let minimumEndOffset = max(0, archive.count - 65_557)
        var endOffset = archive.count - 22
        while endOffset >= minimumEndOffset, readUInt32(archive, at: endOffset) != 0x0605_4b50 {
            endOffset -= 1
        }
        guard endOffset >= minimumEndOffset else { throw Failure.invalidArchive }
        let diskNumber = readUInt16(archive, at: endOffset + 4)
        let centralDiskNumber = readUInt16(archive, at: endOffset + 6)
        let entriesOnDisk = Int(readUInt16(archive, at: endOffset + 8))
        let expectedEntryCount = Int(readUInt16(archive, at: endOffset + 10))
        let centralSize = Int(readUInt32(archive, at: endOffset + 12))
        let centralOffset = Int(readUInt32(archive, at: endOffset + 16))
        let commentLength = Int(readUInt16(archive, at: endOffset + 20))
        guard diskNumber == 0, centralDiskNumber == 0,
            entriesOnDisk == expectedEntryCount,
            endOffset + 22 + commentLength == archive.count,
            centralOffset + centralSize == endOffset
        else { throw Failure.invalidArchive }

        var cursor = 0
        var urls: [URL] = []
        var localEntryCount = 0
        while cursor + 30 <= archive.count {
            guard readUInt32(archive, at: cursor) == 0x0403_4b50 else { break }
            localEntryCount += 1
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
                !normalizedName.split(separator: "/").contains("..")
            else {
                throw Failure.invalidArchive
            }
            let expectedCRC = readUInt32(archive, at: cursor + 14)
            guard data.count == Int(readUInt32(archive, at: cursor + 22)), crc32(data) == expectedCRC else {
                throw Failure.checksumMismatch
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
        guard !urls.isEmpty, cursor == centralOffset, localEntryCount == expectedEntryCount,
            readUInt32(archive, at: cursor) == 0x0201_4b50
        else { throw Failure.invalidArchive }
        return urls
    }

    enum Failure: Error {
        case invalidArchive
        case unsupportedCompression
        case decompressionFailed
        case checksumMismatch
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
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb8_8320 : 0)
            }
        }
        return crc ^ 0xffff_ffff
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

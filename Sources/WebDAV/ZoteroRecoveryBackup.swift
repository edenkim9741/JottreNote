import Foundation

struct ZoteroRecoveryBackup: Sendable {
    let directoryURL: URL
    let localPDFURL: URL?
    let localJotURL: URL?
    let attachmentMetadataURL: URL

    private struct Manifest: Codable {
        let attachmentKey: String
        let createdAt: Date
        let localPDFBackedUp: Bool
        let localJotBackedUp: Bool
        let attachmentMetadataBackedUp: Bool
    }

    enum Failure: Error {
        case invalidBackupSource
        case copyVerificationFailed
    }

    static func create(
        attachment: ZoteroAttachment,
        localCacheURL: URL?,
        localJotURL: URL,
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> Self {
        let baseURL = rootDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZoteroRecovery", isDirectory: true)
        let attachmentFolder = baseURL.appendingPathComponent(
            String(ZoteroSyncService.md5Hex(Data(attachment.key.utf8)).prefix(16)),
            isDirectory: true
        )
        let directoryURL = attachmentFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var localPDFBackupURL: URL?
        if let localCacheURL, fileManager.fileExists(atPath: localCacheURL.path) {
            let destination = directoryURL.appendingPathComponent("local.pdf")
            try copyAndVerify(localCacheURL, to: destination, fileManager: fileManager)
            localPDFBackupURL = destination
        }

        var localJotBackupURL: URL?
        if fileManager.fileExists(atPath: localJotURL.path) {
            let destination = directoryURL.appendingPathComponent("local.jot")
            try copyAndVerify(localJotURL, to: destination, fileManager: fileManager)
            localJotBackupURL = destination
        }

        let metadataURL = directoryURL.appendingPathComponent("attachment-metadata.json")
        let metadata = try JSONEncoder().encode(attachment)
        try metadata.write(to: metadataURL, options: .atomic)
        guard (try? Data(contentsOf: metadataURL)) == metadata else {
            throw Failure.copyVerificationFailed
        }

        let manifest = Manifest(
            attachmentKey: attachment.key,
            createdAt: Date(),
            localPDFBackedUp: localPDFBackupURL != nil,
            localJotBackedUp: localJotBackupURL != nil,
            attachmentMetadataBackedUp: true
        )
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)

        return Self(
            directoryURL: directoryURL,
            localPDFURL: localPDFBackupURL,
            localJotURL: localJotBackupURL,
            attachmentMetadataURL: metadataURL
        )
    }

    func restoreLocalJot(to destination: URL, fileManager: FileManager = .default) throws {
        guard let localJotURL else {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            return
        }
        let data = try Data(contentsOf: localJotURL)
        try data.write(to: destination, options: .atomic)
        guard fileManager.contentsEqual(atPath: localJotURL.path, andPath: destination.path) else {
            throw Failure.copyVerificationFailed
        }
    }

    private static func copyAndVerify(
        _ source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw Failure.invalidBackupSource
        }
        try fileManager.copyItem(at: source, to: destination)
        guard fileManager.contentsEqual(atPath: source.path, andPath: destination.path) else {
            throw Failure.copyVerificationFailed
        }
    }
}

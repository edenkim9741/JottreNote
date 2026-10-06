import Foundation

/// Uploads the durable local hybrid PDF for a Zotero attachment. The editor
/// calls this from an independent utility task after the repository saves it.
struct ZoteroDocumentSyncService: Sendable {
    private let defaultsService: DefaultsServiceProtocol
    private let cacheStore: ZoteroCacheStore
    private let keychain: KeychainCredentialStore

    init(
        defaultsService: DefaultsServiceProtocol,
        cacheStore: ZoteroCacheStore = ZoteroCacheStore(),
        keychain: KeychainCredentialStore = KeychainCredentialStore()
    ) {
        self.defaultsService = defaultsService
        self.cacheStore = cacheStore
        self.keychain = keychain
    }

    /// Returns a user-visible reason when an upload could not be completed.
    /// A nil result means the attachment is synced or was not dirty.
    func uploadCachedAttachment(key: String?, fallbackModificationDate: Date?) async -> String? {
        guard let key else { return nil }
        let userID = defaultsService.getValue(DefaultsKey<String>.zoteroUserID) ?? ""
        guard !userID.isEmpty else {
            print("[ZoteroUpload] Skipped \(key): Zotero User ID is not configured.")
            return "Zotero User ID is not configured."
        }
        let canonicalKey = cacheStore.canonicalAttachmentKey(key, userID: userID)
        let attachment = cacheStore.load(userID: userID).attachments[canonicalKey]
        if attachment?.isLocalOnly == true || attachment?.isConflict == true { return nil }
        guard attachment?.syncStatus == .dirty else { return nil }
        guard let path = attachment?.localCachePath,
              FileManager.default.fileExists(atPath: path),
              let pdf = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            print("[ZoteroUpload] Skipped \(key): local hybrid PDF cache is missing.")
            return "The local PDF cache is missing for attachment \(key)."
        }
        guard let urlString = defaultsService.getValue(DefaultsKey<String>.webDAVURL),
              let baseURL = URL(string: urlString),
              let apiKey = keychain.value(for: "zotero_api_key") else {
            print("[ZoteroUpload] Skipped \(key): WebDAV or Zotero API credentials are missing.")
            return "WebDAV URL or Zotero API credentials are missing. Check account settings."
        }

        let service = ZoteroSyncService(
            service: WebDAVService(
                baseURL: baseURL,
                username: defaultsService.getValue(DefaultsKey<String>.webDAVUsername) ?? "",
                password: keychain.value(for: "webdav_password") ?? ""
            ),
            apiClient: ZoteroAPIClient(apiKey: apiKey, userID: userID)
        )
        do {
            try await service.upload(
                documentID: canonicalKey,
                data: pdf,
                metadata: ZoteroUploadMetadata(
                    modificationDate: fallbackModificationDate,
                    modificationTimeMilliseconds: attachment?.modificationTimeMilliseconds,
                    filename: attachment?.filename
                )
            )
            _ = try cacheStore.markSynced(key: canonicalKey, data: pdf, userID: userID)
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: canonicalKey)
            return nil
        } catch {
            _ = try? cacheStore.markDirty(key: canonicalKey, userID: userID)
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: canonicalKey)
            print("[ZoteroUpload] Failed for \(key): \(error)")
            return error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let zoteroAttachmentCacheChanged = Notification.Name("ZoteroAttachmentCacheChanged")
}

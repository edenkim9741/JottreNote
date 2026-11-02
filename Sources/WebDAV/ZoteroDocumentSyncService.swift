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
    func uploadCachedAttachment(
        key: String?,
        fallbackModificationDate: Date?,
        allowingActiveEdit: Bool = false,
        expectedRemoteMD5: String? = nil,
        conflictContext: ZoteroDownloadContext? = nil,
        conflictResolution: String? = nil
    ) async -> String? {
        guard let key else { return nil }
        let userID = defaultsService.getValue(DefaultsKey<String>.zoteroUserID) ?? ""
        guard !userID.isEmpty else {
            print("[ZoteroUpload] Skipped \(key): Zotero User ID is not configured.")
            return "Zotero User ID is not configured."
        }
        let canonicalKey = cacheStore.canonicalAttachmentKey(key, userID: userID)
        if !allowingActiveEdit, await ZoteroEditingSessionGate.shared.isEditing(key: canonicalKey) {
            return nil
        }
        do {
            return try await AsyncResourceAccessCoordinator.shared.withAccess(
                to: "zotero-cache-upload:" + userID + ":" + canonicalKey
            ) {
                await uploadCurrentCache(
                    key: canonicalKey,
                    userID: userID,
                    fallbackModificationDate: fallbackModificationDate,
                    expectedRemoteMD5: expectedRemoteMD5,
                    conflictContext: conflictContext,
                    conflictResolution: conflictResolution
                )
            }
        } catch { return error.localizedDescription }
    }

    private func uploadCurrentCache(
        key canonicalKey: String,
        userID: String,
        fallbackModificationDate: Date?,
        expectedRemoteMD5: String?,
        conflictContext: ZoteroDownloadContext?,
        conflictResolution: String?
    ) async -> String? {
        let key = canonicalKey
        let attachment = cacheStore.load(userID: userID).attachments[canonicalKey]
        if attachment?.isLocalOnly == true || attachment?.isConflict == true {
            print("[ZoteroUpload] Skipped \(key): local-only or conflict attachment.")
            return nil
        }
        if attachment?.isPendingSync == true {
            print("[ZoteroUpload] Deferred \(key): attachment metadata is not registered remotely yet.")
            return nil
        }
        guard attachment?.syncStatus == .dirty else { return nil }
        guard let path = attachment?.localCachePath,
            FileManager.default.fileExists(atPath: path),
            let pdf = try? Data(contentsOf: URL(fileURLWithPath: path))
        else {
            print("[ZoteroUpload] Skipped \(key): local hybrid PDF cache is missing.")
            recordConflictUploadEvent(
                "zotero.conflict.uploadDeferred",
                context: conflictContext,
                resolution: conflictResolution,
                details: ["failureReason": "localCacheMissing", "syncStatus": attachment?.syncStatus.rawValue ?? "unknown"]
            )
            return "The local PDF cache is missing for attachment \(key)."
        }
        guard let urlString = defaultsService.getValue(DefaultsKey<String>.webDAVURL),
            let baseURL = URL(string: urlString),
            let apiKey = keychain.value(for: "zotero_api_key")
        else {
            print("[ZoteroUpload] Skipped \(key): WebDAV or Zotero API credentials are missing.")
            recordConflictUploadEvent(
                "zotero.conflict.uploadDeferred",
                context: conflictContext,
                resolution: conflictResolution,
                details: ["failureReason": "credentialsUnavailable", "syncStatus": attachment?.syncStatus.rawValue ?? "unknown"]
            )
            return "WebDAV URL or Zotero API credentials are missing. Check account settings."
        }

        if let expectedRemoteMD5 {
            var observedRemoteMD5: String?
            do {
                let latestRemoteState = try await ZoteroAPIClient(apiKey: apiKey, userID: userID)
                    .fetchAttachmentRemoteState(key: canonicalKey)
                observedRemoteMD5 = latestRemoteState.md5
                guard latestRemoteState.md5?.lowercased() == expectedRemoteMD5.lowercased() else {
                    throw Failure.remoteVersionChanged
                }
            } catch {
                if case Failure.remoteVersionChanged = error {
                    try? cacheStore.queueRemoteVerification(
                        key: canonicalKey,
                        userID: userID,
                        expectedRemoteMD5: observedRemoteMD5
                    )
                }
                _ = try? cacheStore.recordPendingSyncError(
                    key: canonicalKey,
                    message: error.localizedDescription,
                    userID: userID
                )
                recordConflictUploadEvent(
                    "zotero.conflict.uploadDeferred",
                    context: conflictContext,
                    resolution: conflictResolution,
                    details: ["failureReason": "remoteVersionChanged", "syncStatus": attachment?.syncStatus.rawValue ?? "unknown"],
                    error: error
                )
                return error.localizedDescription
            }
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
            print("[ZoteroUpload] Completed remote upload for \(canonicalKey).")
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: canonicalKey)
            recordConflictUploadEvent(
                "zotero.conflict.uploadCompleted",
                context: conflictContext,
                resolution: conflictResolution,
                details: ["syncStatus": cacheStore.load(userID: userID).attachments[canonicalKey]?.syncStatus.rawValue ?? "unknown"]
            )
            return nil
        } catch {
            _ = try? cacheStore.markDirty(key: canonicalKey, userID: userID)
            _ = try? cacheStore.recordPendingSyncError(
                key: canonicalKey,
                message: error.localizedDescription,
                userID: userID
            )
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: canonicalKey)
            print("[ZoteroUpload] Failed for \(key): \(error)")
            recordConflictUploadEvent(
                "zotero.conflict.uploadDeferred",
                context: conflictContext,
                resolution: conflictResolution,
                details: ["failureReason": "remoteUploadFailed", "syncStatus": cacheStore.load(userID: userID).attachments[canonicalKey]?.syncStatus.rawValue ?? "unknown"],
                error: error
            )
            return error.localizedDescription
        }
    }

    private func recordConflictUploadEvent(
        _ name: String,
        context: ZoteroDownloadContext?,
        resolution: String?,
        details extra: [String: Any],
        error: Error? = nil
    ) {
        guard let context else { return }
        var details = context.eventDetails
        details["stage"] = "webDAVUpload"
        if let resolution { details["resolution"] = resolution }
        details.merge(extra) { _, new in new }
        if let error {
            let nsError = error as NSError
            details["errorType"] = String(reflecting: type(of: error))
            details["errorDomain"] = nsError.domain
            details["errorCode"] = nsError.code
            if let urlError = error as? URLError { details["urlSessionErrorCode"] = urlError.code.rawValue }
            if case WebDAVService.Failure.unexpectedResponse(let status) = error { details["httpStatus"] = status }
            if case ZoteroAPIClient.Failure.http(let status) = error { details["httpStatus"] = status }
            if case ZoteroAPIClient.Failure.requestFailed(_, let status, _) = error { details["httpStatus"] = status }
            if case ZoteroAPIClient.Failure.itemCreation(_, let status?, _) = error { details["httpStatus"] = status }
        }
        JottreDiagnostics.shared.record(name, details: details)
    }

    enum Failure: LocalizedError {
        case remoteVersionChanged

        var errorDescription: String? {
            switch self {
            case .remoteVersionChanged:
                return "The remote PDF changed after conflict detection. Review the conflict again before keeping the local version."
            }
        }
    }
}

extension Notification.Name {
    static let zoteroAttachmentCacheChanged = Notification.Name("ZoteroAttachmentCacheChanged")
    static let zoteroEditorDidEnd = Notification.Name("ZoteroEditorDidEnd")
}

/// Prevents library-level remote sync from reading or replacing an attachment
/// while its editor is open. A synchronization already in progress is allowed
/// to finish before a new editor session becomes active.
actor ZoteroEditingSessionGate {
    static let shared = ZoteroEditingSessionGate()

    private var editingSessions: [String: String] = [:]
    private var synchronizationInProgress = false
    private var synchronizationWaiters: [CheckedContinuation<Void, Never>] = []

    func beginEditing(key: String, sessionID: String) async {
        guard !key.isEmpty, !sessionID.isEmpty else { return }
        editingSessions[sessionID] = key
        while synchronizationInProgress {
            await withCheckedContinuation { synchronizationWaiters.append($0) }
        }
    }

    func endEditing(sessionID: String) -> (key: String?, shouldSynchronize: Bool) {
        let key = editingSessions.removeValue(forKey: sessionID)
        return (key, editingSessions.isEmpty)
    }

    func beginSynchronization() -> Bool {
        guard editingSessions.isEmpty, !synchronizationInProgress else { return false }
        synchronizationInProgress = true
        return true
    }

    func endSynchronization() {
        synchronizationInProgress = false
        let waiters = synchronizationWaiters
        synchronizationWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }

    func isEditing(key: String) -> Bool {
        editingSessions.values.contains(key)
    }
}

import Foundation
import Combine

@MainActor
final class ZoteroSyncProgress: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var syncProgress = 0.0
    @Published private(set) var syncStatusMessage = String(localized: "zotero.sync.status.ready")

    func begin() {
        isSyncing = true
        syncProgress = 0
        syncStatusMessage = String(localized: "zotero.sync.status.fetching")
    }

    func update(_ value: Double, message: String) {
        syncProgress = min(1, max(syncProgress, value))
        syncStatusMessage = message
    }

    func finish(succeeded: Bool) {
        if succeeded {
            syncProgress = 1
            syncStatusMessage = String(localized: "zotero.sync.status.complete")
        } else {
            syncStatusMessage = String(localized: "zotero.sync.status.failed")
        }
        isSyncing = false
    }
}

actor ZoteroSyncEngine {
    /// Timestamps are only a hint for deciding that a checksum deserves
    /// verification. They are never sufficient to declare a conflict.
    nonisolated static let timeDriftBufferMilliseconds: Int64 = 15_000

    nonisolated static func timestampSuggestsRemoteChange(
        serverMilliseconds: Int64?,
        lastSyncedMilliseconds: Int64?
    ) -> Bool {
        guard let serverMilliseconds, let lastSyncedMilliseconds else { return false }
        return serverMilliseconds - lastSyncedMilliseconds > timeDriftBufferMilliseconds
    }

    private let cacheStore: ZoteroCacheStore
    private let progress: ZoteroSyncProgress?

    init(cacheStore: ZoteroCacheStore, progress: ZoteroSyncProgress? = nil) {
        self.cacheStore = cacheStore
        self.progress = progress
    }

    func synchronize(
        apiClient: ZoteroAPIClient,
        userID: String,
        uploadAttachment: (@Sendable (String) async -> String?)? = nil,
        downloadAttachment: (@Sendable (String, ZoteroDownloadContext) async throws -> Data)? = nil
    ) async throws -> ZoteroCacheSnapshot {
        await progress?.begin()
        do {
        for attempt in 0..<3 {
            let current = cacheStore.load(userID: userID)
            let savedOldVersion = current.lastLibraryVersion
            do {
                var snapshot = current
                let delta = try await apiClient.fetchDelta(since: savedOldVersion)
                let expectedVersion = delta?.libraryVersion ?? savedOldVersion
                let fullCollections = try await apiClient.fetchAllCollections()
                guard fullCollections.libraryVersion == expectedVersion else {
                    throw ZoteroAPIClient.Failure.libraryChangedDuringSync
                }

                if let delta {
                    await progress?.update(0.3, message: String(localized: "zotero.sync.status.applyingChanges"))
                    snapshot = try cacheStore.apply(delta, userID: userID)
                } else {
                    await progress?.update(0.3, message: String(localized: "zotero.sync.status.noChanges"))
                }
                snapshot = try cacheStore.reconcileCollections(
                    fullCollections.collections,
                    libraryVersion: expectedVersion,
                    userID: userID
                )

                if let downloadAttachment {
                    let keys = snapshot.pendingRemoteDownloads.filter { key in
                        guard let attachment = snapshot.attachments[key] else { return false }
                        return !attachment.isConflict && !attachment.isLocalOnly
                    }
                    for (index, key) in keys.enumerated() {
                        let progressValue = 0.35 + 0.2 * Double(index) / Double(max(1, keys.count))
                        await progress?.update(progressValue, message: String(localized: "zotero.sync.status.downloading"))
                        let conflictRelationID = cacheStore.conflictDiagnosticID(forOriginalKey: key, userID: userID)
                        let isConflictRelatedDownload = conflictRelationID != nil
                            || snapshot.attachments[key]?.syncStatus == .dirty
                        let context = ZoteroDownloadContext(
                            source: .librarySync,
                            relatedAttachmentID: conflictRelationID
                        )
                        let isRecoveryDownload = snapshot.attachments[key]?.syncError != nil
                            || snapshot.attachments[key]?.syncStatus == .cloudOnly && conflictRelationID != nil
                        if isRecoveryDownload {
                            var details = context.eventDetails
                            details["attachmentID"] = String(ZoteroSyncService.md5Hex(Data(key.utf8)).prefix(12))
                            details["stage"] = "downloadStarted"
                            details["previousSyncStatus"] = snapshot.attachments[key]?.syncStatus.rawValue
                            details["pendingQueued"] = true
                            details["dirty"] = snapshot.attachments[key]?.syncStatus == .dirty
                            details["conflictCopyExists"] = conflictRelationID != nil
                            JottreDiagnostics.shared.record("zotero.recovery.downloadStarted", details: details)
                        }
                        if isConflictRelatedDownload {
                            var details = context.eventDetails
                            details["stage"] = "remoteDownload"
                            details["attempt"] = context.attempt
                            JottreDiagnostics.shared.record("zotero.conflict.remoteDownloadStarted", details: details)
                        }
                        var receivedDownload = false
                        var downloadedBytes = 0
                        do {
                            let data = try await downloadAttachment(key, context)
                            receivedDownload = true
                            downloadedBytes = data.count
                            let didInstall: Bool
                            if cacheStore.load(userID: userID).attachments[key]?.syncStatus == .dirty {
                                didInstall = try cacheStore.verifyDirtyRemoteVersion(
                                    key: key,
                                    data: data,
                                    userID: userID,
                                    context: context
                                )
                            } else {
                                didInstall = try cacheStore.installRemoteVersion(key: key, data: data, userID: userID)
                            }
                            if didInstall {
                                var details = context.eventDetails
                                details["stage"] = "localCache"
                                details["attempt"] = context.attempt
                                details["cacheSaved"] = true
                                details["byteCount"] = data.count
                                JottreDiagnostics.shared.record("zotero.download.cacheSaved", details: details)
                                if isRecoveryDownload {
                                    details["stage"] = "cacheInstalled"
                                    details["finalStatus"] = ZoteroAttachmentSyncStatus.downloaded.rawValue
                                    details["localFileValid"] = true
                                    JottreDiagnostics.shared.record("zotero.recovery.cacheInstalled", details: details)
                                    JottreDiagnostics.shared.record("zotero.recovery.downloadSucceeded", details: details)
                                    JottreDiagnostics.shared.record("zotero.recovery.completed", details: details)
                                }
                                if conflictRelationID != nil {
                                    details["stage"] = "remoteInstalled"
                                    JottreDiagnostics.shared.record("zotero.conflict.remoteInstalled", details: details)
                                }
                            }
                        } catch {
                            if isCancellation(error) { throw CancellationError() }
                            if isRecoveryDownload {
                                var details = context.eventDetails
                                details["attachmentID"] = String(ZoteroSyncService.md5Hex(Data(key.utf8)).prefix(12))
                                details["stage"] = "webDAVDownloadOrInstall"
                                details["previousSyncStatus"] = snapshot.attachments[key]?.syncStatus.rawValue
                                details["errorType"] = String(reflecting: type(of: error))
                                details["errorDomain"] = (error as NSError).domain
                                details["errorCode"] = (error as NSError).code
                                details["pendingRetained"] = cacheStore.load(userID: userID).pendingRemoteDownloads.contains(key)
                                JottreDiagnostics.shared.record("zotero.recovery.downloadFailed", details: details)
                            }
                            if isConflictRelatedDownload || cacheStore.conflictDiagnosticID(forOriginalKey: key, userID: userID) != nil {
                                var details = context.eventDetails
                                if details["relatedAttachmentID"] == nil {
                                    details["conflictRelationID"] = cacheStore.conflictDiagnosticID(forOriginalKey: key, userID: userID)
                                }
                                details["stage"] = "remoteDownload"
                                details["errorType"] = String(reflecting: type(of: error))
                                details["errorDomain"] = (error as NSError).domain
                                details["errorCode"] = (error as NSError).code
                                JottreDiagnostics.shared.record("zotero.conflict.remoteDownloadFailed", details: details)
                            }
                            if receivedDownload {
                                ZoteroSyncService.recordDownloadFailure(
                                    error,
                                    context: context,
                                    stageOverride: "localCacheInstall",
                                    byteCount: downloadedBytes
                                )
                            }
                            try? cacheStore.recordPendingSyncError(
                                key: key,
                                message: error.localizedDescription,
                                userID: userID
                            )
                        }
                    }
                }

                let drafts = cacheStore.pendingDrafts(userID: userID)
                    .filter { !$0.item.isConflict && !$0.attachment.isConflict && !$0.attachment.isLocalOnly }
                for (index, draft) in drafts.enumerated() {
                    await progress?.update(
                        0.58 + 0.2 * Double(index) / Double(max(1, drafts.count)),
                        message: String(localized: "zotero.sync.status.creatingItems")
                    )
                    do {
                        if !draft.item.isPendingSync {
                            print("[ZoteroSync] Registering a pending PDF note under existing item \(draft.item.key).")
                            let createdAttachment = try await apiClient.createPDFAttachment(
                                parentItemKey: draft.item.key,
                                filename: draft.attachment.filename,
                                attachmentKey: ZoteroSyncService.isValidKey(draft.attachment.key)
                                    ? draft.attachment.key
                                    : nil
                            )
                            try cacheStore.promotePendingAttachment(
                                temporaryAttachmentKey: draft.attachment.key,
                                createdAttachmentKey: createdAttachment.key,
                                version: createdAttachment.libraryVersion,
                                userID: userID
                            )
                            print("[ZoteroSync] Registered PDF attachment \(createdAttachment.key) under existing parent \(draft.item.key).")
                            continue
                        }

                        let created: CreatedZoteroDocumentKeys
                        if draft.item.metadataFields.isEmpty {
                            let author = draft.item.creators.first ?? ""
                            created = try await apiClient.createNoteDocument(
                                title: draft.item.title,
                                filename: draft.attachment.filename,
                                collectionKeys: draft.item.collectionKeys,
                                firstName: "",
                                lastName: "",
                                fullName: author,
                                date: draft.item.dateAdded ?? Date(),
                                parentItemKey: ZoteroSyncService.isValidKey(draft.item.key) ? draft.item.key : nil,
                                pdfAttachmentKey: ZoteroSyncService.isValidKey(draft.attachment.key)
                                    ? draft.attachment.key
                                    : nil
                            )
                        } else {
                            created = try await apiClient.createItemWithPDFAttachment(
                                title: draft.item.title,
                                filename: draft.attachment.filename,
                                collectionKeys: draft.item.collectionKeys,
                                itemType: draft.item.itemType,
                                metadataFields: draft.item.metadataFields,
                                creators: draft.item.creatorEntries,
                                parentItemKey: ZoteroSyncService.isValidKey(draft.item.key) ? draft.item.key : nil,
                                pdfAttachmentKey: ZoteroSyncService.isValidKey(draft.attachment.key)
                                    ? draft.attachment.key
                                    : nil
                            )
                        }
                        try cacheStore.promoteOfflineDraft(
                            temporaryParentKey: draft.item.key,
                            temporaryAttachmentKey: draft.attachment.key,
                            created: created,
                            version: created.libraryVersion,
                            userID: userID
                        )
                        print("[ZoteroSync] Registered new Zotero item and PDF attachment \(created.attachmentKey).")
                    } catch {
                        try? cacheStore.recordPendingSyncError(
                            key: draft.attachment.key,
                            message: error.localizedDescription,
                            userID: userID
                        )
                    }
                }

                if let uploadAttachment {
                    let uploadSnapshot = cacheStore.load(userID: userID)
                    let pendingRemoteDownloadKeys = Set(uploadSnapshot.pendingRemoteDownloads)
                    let dirtyKeys = uploadSnapshot.attachments.values
                        .filter {
                            $0.syncStatus == .dirty && !$0.isPendingSync
                                && !$0.isLocalOnly && !$0.isConflict
                                && !pendingRemoteDownloadKeys.contains($0.key)
                        }
                        .map(\.key)
                        .sorted()
                    print("[ZoteroSync] Initial and edited PDF upload queue contains \(dirtyKeys.count) attachment(s).")
                    for (index, key) in dirtyKeys.enumerated() {
                        let value = 0.8 + 0.18 * Double(index) / Double(max(1, dirtyKeys.count))
                        await progress?.update(value, message: String(localized: "zotero.sync.status.uploading"))
                        if let error = await uploadWithBackoff(key: key, operation: uploadAttachment) {
                            try? cacheStore.recordPendingSyncError(key: key, message: error, userID: userID)
                        }
                    }
                }
                await progress?.update(0.98, message: String(localized: "zotero.sync.status.finishing"))
                let result = cacheStore.load(userID: userID)
                await progress?.finish(succeeded: true)
                return result
            } catch ZoteroAPIClient.Failure.libraryChangedDuringSync {
                try? await Task.sleep(for: .seconds(1 << attempt))
                continue
            } catch ZoteroCacheStore.Failure.cacheAdvancedDuringSync {
                try? await Task.sleep(for: .seconds(1 << attempt))
                continue
            }
        }
        throw Failure.libraryContinuouslyChanging
        } catch {
            await progress?.finish(succeeded: false)
            throw error
        }
    }

    private func uploadWithBackoff(
        key: String,
        operation: @Sendable (String) async -> String?
    ) async -> String? {
        var lastMessage: String?
        for attempt in 0..<3 {
            if let message = await operation(key) {
                lastMessage = message
                guard attempt < 2, !Task.isCancelled else { return message }
                do { try await Task.sleep(for: .seconds(1 << attempt)) }
                catch { return message }
            } else {
                return nil
            }
        }
        return lastMessage ?? "Upload retry limit reached for attachment \(key)."
    }

    private func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    enum Failure: Error { case libraryContinuouslyChanging }
}

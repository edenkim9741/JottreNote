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
        downloadAttachment: (@Sendable (String) async throws -> Data)? = nil
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
                        do {
                            let data = try await downloadWithBackoff(key: key, operation: downloadAttachment)
                            try cacheStore.installRemoteVersion(key: key, data: data, userID: userID)
                        } catch {
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
                        let author = draft.item.creators.first ?? ""
                        let created = try await apiClient.createNoteDocument(
                            title: draft.item.title,
                            filename: draft.attachment.filename,
                            collectionKeys: draft.item.collectionKeys,
                            firstName: "",
                            lastName: "",
                            fullName: author
                        )
                        try cacheStore.promoteOfflineDraft(
                            temporaryParentKey: draft.item.key,
                            temporaryAttachmentKey: draft.attachment.key,
                            created: created,
                            version: created.libraryVersion,
                            userID: userID
                        )
                        if let uploadAttachment,
                           let error = await uploadWithBackoff(key: created.attachmentKey, operation: uploadAttachment) {
                            try? cacheStore.recordPendingSyncError(
                                key: created.attachmentKey,
                                message: error,
                                userID: userID
                            )
                        }
                    } catch {
                        try? cacheStore.recordPendingSyncError(
                            key: draft.attachment.key,
                            message: error.localizedDescription,
                            userID: userID
                        )
                    }
                }

                if let uploadAttachment {
                    let dirtyKeys = cacheStore.load(userID: userID).attachments.values
                        .filter {
                            $0.syncStatus == .dirty && !$0.isPendingSync
                                && !$0.isLocalOnly && !$0.isConflict
                        }
                        .map(\.key)
                        .sorted()
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

    private func downloadWithBackoff(
        key: String,
        operation: @Sendable (String) async throws -> Data
    ) async throws -> Data {
        var lastError: (any Error)?
        for attempt in 0..<3 {
            do { return try await operation(key) }
            catch {
                lastError = error
                guard attempt < 2, !Task.isCancelled else { throw error }
                try await Task.sleep(for: .seconds(1 << attempt))
            }
        }
        throw lastError ?? ZoteroAPIClient.Failure.libraryChangedDuringSync
    }

    enum Failure: Error { case libraryContinuouslyChanging }
}

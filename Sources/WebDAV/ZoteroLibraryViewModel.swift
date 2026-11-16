import Combine
import Network
import PDFKit
@preconcurrency import PencilKit
import UIKit

@MainActor
final class ZoteroLibraryViewModel: ObservableObject {
    @Published private(set) var snapshot: ZoteroCacheSnapshot {
        didSet {
            groupsByLocation.removeAll()
            collectionsByParent = nil
        }
    }
    @Published var selection: ZoteroLibraryLocation = .myLibrary
    @Published private(set) var isSyncing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var openingAttachmentKey: String?
    @Published private(set) var restoringAttachmentKey: String?
    @Published private(set) var remoteRestoreBackupURLs: [URL]?
    @Published private(set) var sorting: ZoteroLibrarySorting {
        didSet { groupsByLocation.removeAll() }
    }
    private var groupsByLocation: [ZoteroLibraryLocation: [ZoteroAttachmentGroup]] = [:]
    private var collectionsByParent: [String?: [ZoteroCollection]]?
    var sortOrder: ZoteroAttachmentSortOrder { sorting.order }
    @Published private(set) var isSelecting = false
    @Published private(set) var selectedItemKeys = Set<String>()
    private var synchronizationRequestedWhileSyncing = false
    private var lastSynchronizationAttempt: Date?
    private var wasNetworkSatisfied = false
    private var periodicSyncTask: Task<Void, Never>?
    private var remoteRestoreRequestIDs: [String: String] = [:]

    private(set) var userID: String
    private var apiKey: String
    private let cacheStore: ZoteroCacheStore
    private let engine: ZoteroSyncEngine
    private let defaults: DefaultsService
    private let keychain = KeychainCredentialStore()
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "ZoteroLibraryNetworkMonitor")
    private let schemaDefaults = UserDefaults.standard
    var onOpenJot: ((JotFile.Info) -> Void)?

    init(cacheStore: ZoteroCacheStore, engine: ZoteroSyncEngine, defaults: DefaultsService) {
        self.cacheStore = cacheStore
        self.engine = engine
        self.defaults = defaults
        sorting = ZoteroLibrarySorting(defaults: defaults)
        userID = defaults.getValue(.zoteroUserID) ?? ""
        apiKey = keychain.value(for: "zotero_api_key") ?? ""
        snapshot = cacheStore.load(userID: userID)
        lastSynchronizationAttempt = UserDefaults.standard.object(forKey: "zotero.lastSyncAttempt.\(userID)") as? Date
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isSatisfied = path.status == .satisfied
                let reconnected = isSatisfied && !self.wasNetworkSatisfied
                self.wasNetworkSatisfied = isSatisfied
                if reconnected { await self.synchronize(trigger: .networkReconnect) }
            }
        }
        networkMonitor.start(queue: networkQueue)
        if !userID.isEmpty, !apiKey.isEmpty { Task { await synchronize(trigger: .appLaunch) } }
        periodicSyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, UIApplication.shared.applicationState == .active else { continue }
                await self.synchronize(trigger: .periodic)
            }
        }
    }

    deinit {
        networkMonitor.cancel()
        periodicSyncTask?.cancel()
    }

    func synchronize(trigger: ZoteroSyncTrigger = .manual) async {
        guard !userID.isEmpty, !apiKey.isEmpty else { return }
        let now = Date()
        var requestDetails: [String: Any] = ["trigger": trigger.rawValue]
        if let lastSynchronizationAttempt {
            requestDetails["lastAttemptAgeSeconds"] = now.timeIntervalSince(lastSynchronizationAttempt)
        }
        JottreDiagnostics.shared.record("zotero.sync.requested", details: requestDetails)
        guard ZoteroSyncSchedule.shouldRun(trigger, lastAttempt: lastSynchronizationAttempt, now: now) else {
            JottreDiagnostics.shared.record(
                "zotero.sync.skipped",
                details: ["trigger": trigger.rawValue, "reason": "minimumInterval"]
            )
            return
        }
        guard !isSyncing else {
            if trigger == .editorFinished || trigger == .accountChanged || trigger == .requiredWork {
                synchronizationRequestedWhileSyncing = true
            }
            JottreDiagnostics.shared.record(
                "zotero.sync.joined",
                details: ["trigger": trigger.rawValue, "followUpRequired": synchronizationRequestedWhileSyncing]
            )
            return
        }
        isSyncing = true
        let startedAt = Date()
        lastSynchronizationAttempt = now
        UserDefaults.standard.set(now, forKey: "zotero.lastSyncAttempt.\(userID)")
        JottreDiagnostics.shared.record("zotero.sync.started", details: ["trigger": trigger.rawValue])
        defer {
            isSyncing = false
            if synchronizationRequestedWhileSyncing {
                synchronizationRequestedWhileSyncing = false
                Task { @MainActor [weak self] in await self?.synchronize(trigger: .editorFinished) }
            }
        }
        let syncGate = ZoteroEditingSessionGate.shared
        guard await syncGate.beginSynchronization() else {
            JottreDiagnostics.shared.record(
                "zotero.sync.skipped",
                details: ["trigger": trigger.rawValue, "reason": "editingSessionOrGateBusy"]
            )
            refreshCacheState()
            return
        }
        do {
            let syncService = makeSyncService()
            let documentSync = ZoteroDocumentSyncService(defaultsService: defaults, cacheStore: cacheStore)
            let syncUserID = userID
            let syncCacheStore = cacheStore
            let synchronizedSnapshot = try await engine.synchronize(
                apiClient: ZoteroAPIClient(apiKey: apiKey, userID: userID),
                userID: userID,
                uploadAttachment: { key in
                    await documentSync.uploadCachedAttachment(key: key, fallbackModificationDate: nil)
                },
                downloadAttachment: { key, context in
                    let attachment = syncCacheStore.load(userID: syncUserID).attachments[key]
                    let expectedRemoteMD5: String?
                    if attachment?.verificationRemoteMD5WasChecked == true {
                        expectedRemoteMD5 = attachment?.verificationRemoteMD5
                    } else {
                        expectedRemoteMD5 =
                            attachment?.syncStatus == .cloudOnly && attachment?.remoteMD5IsPDF == true
                            ? attachment?.remoteMD5
                            : nil
                    }
                    return try await syncService.download(
                        documentID: key,
                        context: context,
                        expectedRemoteMD5: expectedRemoteMD5
                    )
                },
                deleteRemoteAttachment: { key in
                    try await syncService.deleteRemoteAttachment(documentID: key)
                }
            )
            guard syncUserID == userID else {
                JottreDiagnostics.shared.record(
                    "zotero.sync.skipped",
                    details: ["trigger": trigger.rawValue, "reason": "accountChangedDuringSync"]
                )
                await syncGate.endSynchronization()
                return
            }
            snapshot = synchronizedSnapshot
            if case .collection(let key) = selection, snapshot.collections[key] == nil {
                selection = .myLibrary
            }
            errorMessage = nil
            JottreDiagnostics.shared.record(
                "zotero.sync.completed",
                details: [
                    "trigger": trigger.rawValue, "durationMilliseconds": Date().timeIntervalSince(startedAt) * 1_000,
                ]
            )
        } catch {
            errorMessage = String(localized: "zotero.error.librarySync") + "\n" + error.localizedDescription
            JottreDiagnostics.shared.record(
                "zotero.sync.failed",
                details: [
                    "trigger": trigger.rawValue, "durationMilliseconds": Date().timeIntervalSince(startedAt) * 1_000,
                    "errorDomain": (error as NSError).domain, "errorCode": (error as NSError).code,
                ]
            )
        }
        await syncGate.endSynchronization()
    }

    func reloadAccountAndSynchronize() async {
        userID = defaults.getValue(.zoteroUserID) ?? ""
        apiKey = keychain.value(for: "zotero_api_key") ?? ""
        snapshot = cacheStore.load(userID: userID)
        lastSynchronizationAttempt = nil
        await synchronize(trigger: .accountChanged)
    }

    func refreshCacheState() {
        snapshot = cacheStore.load(userID: userID)
    }

    func originalAttachment(for conflict: ZoteroAttachment) -> ZoteroAttachment? {
        guard let key = cacheStore.conflictOriginalKey(for: conflict.key, userID: userID) else { return nil }
        return snapshot.attachments[key]
    }

    func deleteConflictCopy(_ conflictKey: String) async -> Bool {
        do {
            snapshot = try cacheStore.forceDeleteConflictCopy(key: conflictKey, userID: userID)
            selectedItemKeys.remove(conflictKey)
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: conflictKey)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func toggleSelection(for itemKey: String) {
        if !selectedItemKeys.insert(itemKey).inserted { selectedItemKeys.remove(itemKey) }
    }

    func setSelectionMode(_ enabled: Bool) {
        isSelecting = enabled
        if !enabled { selectedItemKeys.removeAll() }
    }

    func updateMetadata(itemKey: String, title: String, creators: [String], date: String) async {
        do {
            try await ZoteroAPIClient(apiKey: apiKey, userID: userID)
                .updateItemMetadata(key: itemKey, title: title, creators: creators, date: date)
            snapshot = try cacheStore.updateItemMetadata(
                key: itemKey,
                title: title,
                creators: creators,
                date: date,
                userID: userID
            )
        } catch { errorMessage = error.localizedDescription }
    }

    func moveItems(_ keys: Set<String>, to collectionKey: String?) async {
        var latestSnapshot = snapshot
        do {
            let api = ZoteroAPIClient(apiKey: apiKey, userID: userID)
            for key in keys.sorted() {
                try await api.moveItem(key: key, toCollectionKey: collectionKey)
                latestSnapshot = try cacheStore.moveItems(
                    keys: [key],
                    toCollectionKey: collectionKey,
                    userID: userID
                )
                snapshot = latestSnapshot
            }
            selectedItemKeys.subtract(keys)
        } catch {
            snapshot = latestSnapshot
            errorMessage = error.localizedDescription
        }
    }

    func trashItems(_ keys: Set<String>) async {
        do {
            snapshot = try cacheStore.markItemsTrashed(keys: keys, userID: userID)
            selectedItemKeys.subtract(keys)
            Task { await synchronize(trigger: .requiredWork) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreItems(_ keys: Set<String>) async {
        do {
            snapshot = try cacheStore.restoreItems(keys: keys, userID: userID)
            selectedItemKeys.subtract(keys)
            Task { await synchronize(trigger: .requiredWork) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func permanentlyDeleteItems(_ keys: Set<String>) async {
        do {
            snapshot = try cacheStore.queuePermanentDeletion(keys: keys, userID: userID)
            selectedItemKeys.subtract(keys)
            Task { await synchronize(trigger: .requiredWork) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func keepConflictLocal(_ conflictKey: String) async -> Bool {
        guard await ZoteroEditingSessionGate.shared.beginSynchronization() else {
            errorMessage = ZoteroCacheStore.Failure.conflictResolutionInProgress.localizedDescription
            return false
        }
        var context: ZoteroDownloadContext?
        var shouldSynchronizeAfterFailure = false
        var uploadCompleted = false
        do {
            guard let originalKey = cacheStore.conflictOriginalKey(for: conflictKey, userID: userID) else {
                throw ZoteroCacheStore.Failure.conflictNotFound
            }
            let diagnosticID = try cacheStore.ensureConflictDiagnosticID(key: conflictKey, userID: userID)
            let resolutionContext = ZoteroDownloadContext(
                source: .conflictResolution,
                relatedAttachmentID: diagnosticID
            )
            context = resolutionContext
            recordConflictResolutionEvent(
                "zotero.conflict.resolutionStarted",
                context: resolutionContext,
                resolution: "keepLocal"
            )
            let currentOriginal = cacheStore.load(userID: userID).attachments[originalKey]
            guard let expectedRemoteMD5 = currentOriginal?.remoteMD5,
                currentOriginal?.remoteMD5IsPDF == true
            else {
                throw ZoteroDocumentSyncService.Failure.remoteVersionChanged
            }
            let latestRemoteState = try await ZoteroAPIClient(apiKey: apiKey, userID: userID)
                .fetchAttachmentRemoteState(key: originalKey)
            guard latestRemoteState.md5?.lowercased() == expectedRemoteMD5.lowercased() else {
                try cacheStore.queueRemoteVerification(
                    key: originalKey,
                    userID: userID,
                    expectedRemoteMD5: latestRemoteState.md5
                )
                snapshot = cacheStore.load(userID: userID)
                shouldSynchronizeAfterFailure = true
                throw ZoteroDocumentSyncService.Failure.remoteVersionChanged
            }
            snapshot = try cacheStore.resolveConflictKeepingLocal(key: conflictKey, userID: userID)
            let documentSync = ZoteroDocumentSyncService(defaultsService: defaults, cacheStore: cacheStore)
            if let error = await documentSync.uploadCachedAttachment(
                key: originalKey,
                fallbackModificationDate: nil,
                expectedRemoteMD5: expectedRemoteMD5,
                conflictContext: resolutionContext,
                conflictResolution: "keepLocal"
            ) {
                errorMessage = error
            } else {
                uploadCompleted = true
            }
            refreshCacheState()
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: conflictKey)
            recordConflictResolutionEvent(
                "zotero.conflict.resolutionCompleted",
                context: resolutionContext,
                resolution: "keepLocal",
                details: [
                    "localRecoveryCompleted": true,
                    "remoteUploadCompleted": uploadCompleted,
                    "syncStatus": cacheStore.load(userID: userID).attachments[originalKey]?.syncStatus.rawValue
                        ?? "unknown",
                ]
            )
            await ZoteroEditingSessionGate.shared.endSynchronization()
            return true
        } catch {
            if let context {
                recordConflictResolutionEvent(
                    "zotero.conflict.resolutionFailed",
                    context: context,
                    resolution: "keepLocal",
                    error: error
                )
            }
            errorMessage = error.localizedDescription
            await ZoteroEditingSessionGate.shared.endSynchronization()
            if shouldSynchronizeAfterFailure { await synchronize(trigger: .requiredWork) }
            return false
        }
    }

    func keepConflictServer(_ conflictKey: String) async -> Bool {
        guard await ZoteroEditingSessionGate.shared.beginSynchronization() else {
            errorMessage = ZoteroCacheStore.Failure.conflictResolutionInProgress.localizedDescription
            return false
        }
        var context: ZoteroDownloadContext?
        var remoteDownloadStarted = false
        var remoteDownloadCompleted = false
        do {
            guard snapshot.attachments[conflictKey] != nil,
                let originalKey = cacheStore.conflictOriginalKey(for: conflictKey, userID: userID)
            else {
                throw ZoteroCacheStore.Failure.conflictNotFound
            }
            let diagnosticID = try cacheStore.ensureConflictDiagnosticID(key: conflictKey, userID: userID)
            let resolutionContext = ZoteroDownloadContext(
                source: .conflictResolution,
                relatedAttachmentID: diagnosticID
            )
            context = resolutionContext
            recordConflictResolutionEvent(
                "zotero.conflict.resolutionStarted",
                context: resolutionContext,
                resolution: "keepServer"
            )
            recordConflictResolutionEvent(
                "zotero.conflict.remoteDownloadStarted",
                context: resolutionContext,
                resolution: "keepServer"
            )
            remoteDownloadStarted = true
            let (serverData, _) = try await downloadStableConflictVersion(key: originalKey, context: resolutionContext)
            remoteDownloadCompleted = true
            snapshot = try cacheStore.resolveConflictKeepingServer(
                key: conflictKey,
                serverData: serverData,
                userID: userID
            )
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: conflictKey)
            recordConflictResolutionEvent(
                "zotero.conflict.remoteInstalled",
                context: resolutionContext,
                resolution: "keepServer",
                details: ["syncStatus": snapshot.attachments[originalKey]?.syncStatus.rawValue ?? "unknown"]
            )
            recordConflictResolutionEvent(
                "zotero.conflict.resolutionCompleted",
                context: resolutionContext,
                resolution: "keepServer",
                details: ["syncStatus": snapshot.attachments[originalKey]?.syncStatus.rawValue ?? "unknown"]
            )
            await ZoteroEditingSessionGate.shared.endSynchronization()
            return true
        } catch {
            if let context {
                if remoteDownloadStarted && !remoteDownloadCompleted {
                    recordConflictResolutionEvent(
                        "zotero.conflict.remoteDownloadFailed",
                        context: context,
                        resolution: "keepServer",
                        error: error
                    )
                }
                recordConflictResolutionEvent(
                    "zotero.conflict.resolutionFailed",
                    context: context,
                    resolution: "keepServer",
                    error: error
                )
            }
            errorMessage = error.localizedDescription
            await ZoteroEditingSessionGate.shared.endSynchronization()
            return false
        }
    }

    func keepConflictBoth(_ conflictKey: String) async -> Bool {
        guard await ZoteroEditingSessionGate.shared.beginSynchronization() else {
            errorMessage = ZoteroCacheStore.Failure.conflictResolutionInProgress.localizedDescription
            return false
        }
        var context: ZoteroDownloadContext?
        var remoteDownloadStarted = false
        var remoteDownloadCompleted = false
        var uploadCompleted = false
        do {
            guard let conflict = snapshot.attachments[conflictKey],
                let originalKey = conflict.conflictOriginalKey
                    ?? cacheStore.conflictOriginalKey(for: conflictKey, userID: userID),
                let item = snapshot.items[conflictKey]
            else {
                throw ZoteroCacheStore.Failure.conflictNotFound
            }
            let reservation = try cacheStore.reserveKeepBothTargetKeys(key: conflictKey, userID: userID)
            let diagnosticID = try cacheStore.ensureConflictDiagnosticID(key: conflictKey, userID: userID)
            let resolutionContext = ZoteroDownloadContext(
                source: .conflictResolution,
                relatedAttachmentID: diagnosticID
            )
            context = resolutionContext
            recordConflictResolutionEvent(
                "zotero.conflict.resolutionStarted",
                context: resolutionContext,
                resolution: "keepBoth"
            )
            recordConflictResolutionEvent(
                "zotero.conflict.remoteDownloadStarted",
                context: resolutionContext,
                resolution: "keepBoth"
            )
            remoteDownloadStarted = true
            let (serverData, serverState) = try await downloadStableConflictVersion(
                key: originalKey,
                context: resolutionContext
            )
            remoteDownloadCompleted = true
            let created = try await ZoteroAPIClient(apiKey: apiKey, userID: userID).createNoteDocument(
                title: item.title,
                filename: conflict.filename,
                collectionKeys: item.collectionKeys,
                firstName: "",
                lastName: "",
                fullName: item.creators.first ?? "",
                date: item.dateAdded ?? conflict.conflictCreatedAt ?? Date(),
                parentItemKey: reservation.parentItemKey,
                pdfAttachmentKey: reservation.attachmentKey
            )
            let latestServerState = try await ZoteroAPIClient(apiKey: apiKey, userID: userID)
                .fetchAttachmentRemoteState(key: originalKey)
            let originalRemoteStillMatches =
                if let initialMD5 = serverState.md5,
                    let latestMD5 = latestServerState.md5
                {
                    initialMD5.lowercased() == latestMD5.lowercased()
                } else {
                    serverState.md5 == nil && latestServerState.md5 == nil
                        && latestServerState.version == serverState.version
                }
            guard originalRemoteStillMatches else {
                throw ZoteroDocumentSyncService.Failure.remoteVersionChanged
            }
            snapshot = try cacheStore.keepConflictAsNewDocument(
                key: conflictKey,
                serverData: serverData,
                created: created,
                userID: userID
            )
            let documentSync = ZoteroDocumentSyncService(defaultsService: defaults, cacheStore: cacheStore)
            if let error = await documentSync.uploadCachedAttachment(
                key: created.attachmentKey,
                fallbackModificationDate: nil,
                conflictContext: resolutionContext,
                conflictResolution: "keepBoth"
            ) {
                errorMessage = error
            } else {
                uploadCompleted = true
            }
            refreshCacheState()
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: created.attachmentKey)
            recordConflictResolutionEvent(
                "zotero.conflict.resolutionCompleted",
                context: resolutionContext,
                resolution: "keepBoth",
                details: [
                    "localRecoveryCompleted": true,
                    "remoteUploadCompleted": uploadCompleted,
                    "syncStatus": cacheStore.load(userID: userID).attachments[created.attachmentKey]?.syncStatus
                        .rawValue ?? "unknown",
                ]
            )
            await ZoteroEditingSessionGate.shared.endSynchronization()
            return true
        } catch {
            if let context {
                if remoteDownloadStarted && !remoteDownloadCompleted {
                    recordConflictResolutionEvent(
                        "zotero.conflict.remoteDownloadFailed",
                        context: context,
                        resolution: "keepBoth",
                        error: error
                    )
                }
                recordConflictResolutionEvent(
                    "zotero.conflict.resolutionFailed",
                    context: context,
                    resolution: "keepBoth",
                    error: error
                )
            }
            errorMessage = error.localizedDescription
            await ZoteroEditingSessionGate.shared.endSynchronization()
            return false
        }
    }

    private func downloadStableConflictVersion(
        key: String,
        context: ZoteroDownloadContext
    ) async throws -> (Data, ZoteroAttachmentRemoteState) {
        let api = ZoteroAPIClient(apiKey: apiKey, userID: userID)
        let before = try await api.fetchAttachmentRemoteState(key: key)
        let data = try await makeSyncService().download(
            documentID: key,
            context: context,
            expectedRemoteMD5: before.md5
        )
        let after = try await api.fetchAttachmentRemoteState(key: key)
        let pdfMD5 = ZoteroSyncService.md5Hex(HybridPDFManager.pdfData(in: data))
        let responseMatchesLatestMD5 = after.md5?.lowercased() == pdfMD5
        let metadataWasStableWithoutMD5 = before.md5 == nil && after.md5 == nil && before.version == after.version
        guard responseMatchesLatestMD5 || metadataWasStableWithoutMD5 else {
            throw ZoteroDocumentSyncService.Failure.remoteVersionChanged
        }
        return (data, after)
    }

    private func recordConflictResolutionEvent(
        _ name: String,
        context: ZoteroDownloadContext,
        resolution: String,
        details extra: [String: Any] = [:],
        error: Error? = nil
    ) {
        var details = context.eventDetails
        details["stage"] = "resolution"
        details["resolution"] = resolution
        details.merge(extra) { _, new in new }
        if let error {
            let nsError = error as NSError
            details["errorType"] = String(reflecting: type(of: error))
            details["errorDomain"] = nsError.domain
            details["errorCode"] = nsError.code
            if case ZoteroAPIClient.Failure.http(let status) = error { details["httpStatus"] = status }
            if case ZoteroAPIClient.Failure.requestFailed(_, let status, _) = error { details["httpStatus"] = status }
            if case ZoteroAPIClient.Failure.itemCreation(_, let status?, _) = error { details["httpStatus"] = status }
        }
        JottreDiagnostics.shared.record(name, details: details)
    }

    func selectSortOrder(_ order: ZoteroAttachmentSortOrder) {
        sorting = sorting.selecting(order)
        sorting.save(to: defaults)
    }

    func createDocument(title: String, pageSize: CGSize, parentItemKey: String? = nil) async -> String? {
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedTitle.isEmpty else { return String(localized: "zotero.create.titleRequired") }
        var sessionIDForCleanup: String?
        var didOpenEditor = false
        do {
            let filename = Self.safePDFFileName(from: resolvedTitle)
            let now = Date()
            let fullName = defaults.getValue(.zoteroDefaultAuthorFullName) ?? ""
            let firstName = defaults.getValue(.zoteroDefaultAuthorFirstName) ?? ""
            let lastName = defaults.getValue(.zoteroDefaultAuthorLastName) ?? ""
            let existingParent: ZoteroItem?
            if let parentItemKey {
                guard ZoteroSyncService.isValidKey(parentItemKey),
                    let parent = snapshot.items[parentItemKey],
                    parent.parentItemKey == nil,
                    !parent.isPendingSync,
                    !parent.isTrashed,
                    !["attachment", "note", "annotation"].contains(parent.itemType)
                else {
                    return String(localized: "zotero.create.failed")
                }
                existingParent = parent
            } else {
                existingParent = nil
            }
            let temporaryParentKey = existingParent?.key ?? ZoteroAPIClient.generateItemKey()
            var temporaryAttachmentKey = ZoteroAPIClient.generateItemKey()
            while temporaryAttachmentKey == temporaryParentKey {
                temporaryAttachmentKey = ZoteroAPIClient.generateItemKey()
            }
            let sessionID = jotSessionID(for: temporaryAttachmentKey)
            sessionIDForCleanup = sessionID
            if onOpenJot != nil {
                await ZoteroEditingSessionGate.shared.beginEditing(
                    key: temporaryAttachmentKey,
                    sessionID: sessionID
                )
            }
            let item =
                existingParent
                ?? ZoteroItem(
                    key: temporaryParentKey,
                    title: resolvedTitle,
                    creators: Self.authorDisplayNames(
                        first: firstName,
                        last: lastName,
                        full: fullName
                    ),
                    year: Calendar(identifier: .gregorian).component(.year, from: now).description,
                    parentItemKey: nil,
                    collectionKeys: selectedCollectionKeys,
                    itemType: "document",
                    dateAdded: now,
                    dateModified: now,
                    version: snapshot.lastLibraryVersion,
                    isTrashed: false,
                    isPendingSync: true
                )
            let attachment = ZoteroAttachment(
                key: temporaryAttachmentKey,
                parentItemKey: temporaryParentKey,
                contentType: "application/pdf",
                filename: filename,
                localCachePath: nil,
                syncStatus: .dirty,
                version: snapshot.lastLibraryVersion,
                md5: nil,
                modificationTimeMilliseconds: nil,
                isPendingSync: true
            )
            let empty = Jot.makeEmpty()
            let ruledPDF = try JotHybridPDFBuilder.makeRuledPDF(pageSize: pageSize, pageCount: 1)
            let jot = Jot(
                drawing: empty.drawing,
                width: pageSize.width,
                pdfData: ruledPDF,
                zoteroItemKey: temporaryAttachmentKey,
                zoteroFileName: filename
            )
            let hybridPDF = try JotHybridPDFBuilder.buildHybridPDF(jot: jot)
            let fileURL = try localJotURL(for: attachment.localDocumentID)
            let jotWithPDF = Jot(
                drawing: empty.drawing,
                width: pageSize.width,
                pdfData: hybridPDF,
                zoteroItemKey: temporaryAttachmentKey,
                zoteroFileName: filename
            )
            let fileInfo = JotFile.Info(url: fileURL, name: resolvedTitle, modificationDate: now)
            let jotEncoder = PropertyListEncoder()
            jotEncoder.outputFormat = .binary
            let localJotData = try jotEncoder.encode(jotWithPDF)
            guard (try? PropertyListDecoder().decode(Jot.self, from: localJotData)) != nil else {
                throw ZoteroCacheStore.Failure.invalidLocalAttachmentFile
            }
            let cacheURL: URL
            if existingParent == nil {
                cacheURL = try cacheStore.registerOfflineDraft(
                    item: item,
                    attachment: attachment,
                    hybridPDF: hybridPDF,
                    userID: userID,
                    localJotData: localJotData,
                    localJotURL: fileURL
                )
            } else {
                cacheURL = try cacheStore.registerPendingAttachment(
                    parentItem: item,
                    attachment: attachment,
                    hybridPDF: hybridPDF,
                    userID: userID,
                    localJotData: localJotData,
                    localJotURL: fileURL
                )
            }

            snapshot = cacheStore.load(userID: userID)
            selection = selectedCollectionKeys.first.map(ZoteroLibraryLocation.collection) ?? .myLibrary
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: temporaryAttachmentKey)
            if onOpenJot != nil {
                onOpenJot?(fileInfo)
                didOpenEditor = true
            }
            print("[ZoteroDraft] Created local offline draft at \(cacheURL.path), bytes: \(hybridPDF.count)")

            guard !userID.isEmpty, !apiKey.isEmpty else {
                return String(localized: "zotero.create.offlineDraft")
            }
            await synchronize(trigger: .requiredWork)
            let currentKey = cacheStore.canonicalAttachmentKey(temporaryAttachmentKey, userID: userID)
            let currentAttachment = cacheStore.load(userID: userID).attachments[currentKey]
            if currentAttachment?.isPendingSync == true { return String(localized: "zotero.create.offlineDraft") }
            if currentAttachment?.syncStatus == .dirty { return String(localized: "zotero.create.offlineDraft") }
            return nil
        } catch {
            if !didOpenEditor, let sessionIDForCleanup {
                await endEditingSession(sessionID: sessionIDForCleanup, requestSynchronization: true)
            }
            return "\(String(localized: "zotero.create.failed"))\n\(error.localizedDescription)"
        }
    }

    func itemTypes() async -> [ZoteroItemTypeDefinition] {
        let locale = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let cacheKey = "zotero.itemTypeCatalog.v1.\(locale)"
        let dateKey = cacheKey + ".fetchedAt"
        let cached = schemaDefaults.data(forKey: cacheKey)
            .flatMap { try? JSONDecoder().decode([ZoteroItemTypeDefinition].self, from: $0) }
        if let cached,
            let fetchedAt = schemaDefaults.object(forKey: dateKey) as? Date,
            Date().timeIntervalSince(fetchedAt) < 3_600
        {
            return cached
        }
        do {
            let values = try await ZoteroAPIClient(apiKey: apiKey, userID: userID).fetchItemTypes()
            if let data = try? JSONEncoder().encode(values) { schemaDefaults.set(data, forKey: cacheKey) }
            schemaDefaults.set(Date(), forKey: dateKey)
            return values
        } catch {
            return cached ?? []
        }
    }

    func itemTypeSchema(for type: ZoteroItemTypeDefinition) async -> ZoteroItemTypeSchema? {
        let locale = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let cacheKey = "zotero.itemTypeSchema.v1.\(locale).\(type.itemType)"
        let dateKey = cacheKey + ".fetchedAt"
        let cached = schemaDefaults.data(forKey: cacheKey)
            .flatMap { try? JSONDecoder().decode(ZoteroItemTypeSchema.self, from: $0) }
        if let cached,
            let fetchedAt = schemaDefaults.object(forKey: dateKey) as? Date,
            Date().timeIntervalSince(fetchedAt) < 3_600
        {
            return cached
        }
        do {
            let value = try await ZoteroAPIClient(apiKey: apiKey, userID: userID).fetchItemTypeSchema(type)
            if let data = try? JSONEncoder().encode(value) { schemaDefaults.set(data, forKey: cacheKey) }
            schemaDefaults.set(Date(), forKey: dateKey)
            return value
        } catch {
            return cached
        }
    }

    func createImportedPDF(
        data sourcePDF: Data,
        filename originalFilename: String,
        schema: ZoteroItemTypeSchema,
        metadata: [String: String],
        creators: [ZoteroCreator]
    ) async -> String? {
        guard let pdf = PDFDocument(data: sourcePDF), pdf.pageCount > 0 else {
            return String(localized: "zotero.import.invalidPDF")
        }
        let title = metadata["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return String(localized: "zotero.create.titleRequired") }
        let now = Date()
        let fileBase = URL(fileURLWithPath: originalFilename).deletingPathExtension().lastPathComponent
        let filename = Self.safePDFFileName(from: fileBase.isEmpty ? title : fileBase)
        let allowedFields = Set(schema.fields.map(\.field))
        let validMetadata = metadata.filter { allowedFields.contains($0.key) }
        guard
            creators.allSatisfy({ creator in
                creator.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || schema.creatorTypes.contains(where: { $0.creatorType == creator.creatorType })
            })
        else { return String(localized: "zotero.import.invalidCreatorRole") }
        let validCreators = creators.filter {
            !$0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let temporaryParentKey = ZoteroAPIClient.generateItemKey()
        let temporaryAttachmentKey = ZoteroAPIClient.generateItemKey()
        guard temporaryParentKey != temporaryAttachmentKey else {
            return String(localized: "zotero.create.failed")
        }
        let item = ZoteroItem(
            key: temporaryParentKey,
            title: title,
            creators: validCreators.map(\.displayName),
            year: validMetadata["date"].flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil },
            parentItemKey: nil,
            collectionKeys: selectedCollectionKeys,
            itemType: schema.type.itemType,
            dateAdded: now,
            dateModified: now,
            version: snapshot.lastLibraryVersion,
            isTrashed: false,
            isPendingSync: true,
            metadataFields: validMetadata,
            creatorEntries: validCreators
        )
        let attachment = ZoteroAttachment(
            key: temporaryAttachmentKey,
            parentItemKey: temporaryParentKey,
            contentType: "application/pdf",
            filename: filename,
            localCachePath: nil,
            syncStatus: .dirty,
            version: snapshot.lastLibraryVersion,
            md5: nil,
            modificationTimeMilliseconds: nil,
            isPendingSync: true
        )
        do {
            let jot = Jot(
                drawing: Jot.makeEmpty().drawing,
                width: Jot.defaultWidth,
                pdfData: sourcePDF,
                zoteroItemKey: temporaryAttachmentKey,
                zoteroFileName: filename
            )
            let hybridPDF = try JotHybridPDFBuilder.buildHybridPDF(jot: jot)
            _ = try cacheStore.registerOfflineDraft(
                item: item,
                attachment: attachment,
                hybridPDF: hybridPDF,
                userID: userID
            )
            snapshot = cacheStore.load(userID: userID)
            selection = selectedCollectionKeys.first.map(ZoteroLibraryLocation.collection) ?? .myLibrary
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: temporaryAttachmentKey)
            guard !userID.isEmpty, !apiKey.isEmpty else {
                return String(localized: "zotero.create.offlineDraft")
            }
            await synchronize(trigger: .requiredWork)
            return cacheStore.load(userID: userID).attachments[temporaryAttachmentKey]?.isPendingSync == true
                ? String(localized: "zotero.create.offlineDraft")
                : nil
        } catch {
            return "\(String(localized: "zotero.create.failed"))\n\(error.localizedDescription)"
        }
    }

    func addPDFAttachment(
        data sourcePDF: Data,
        filename originalFilename: String,
        to parentItemKey: String
    ) async -> String? {
        guard Int(userID) != nil, !apiKey.isEmpty else {
            return String(localized: "zotero.create.accountRequired")
        }
        guard let pdf = PDFDocument(data: sourcePDF), pdf.pageCount > 0,
            let parent = snapshot.items[parentItemKey], parent.parentItemKey == nil,
            !["attachment", "note", "annotation"].contains(parent.itemType)
        else {
            return String(localized: "zotero.import.invalidPDF")
        }
        let filename = Self.safePDFFileName(from: URL(fileURLWithPath: originalFilename).lastPathComponent)
        do {
            let created = try await ZoteroAPIClient(apiKey: apiKey, userID: userID)
                .createPDFAttachment(parentItemKey: parentItemKey, filename: filename)
            let jot = Jot(
                drawing: Jot.makeEmpty().drawing,
                width: Jot.defaultWidth,
                pdfData: sourcePDF,
                zoteroItemKey: created.key,
                zoteroFileName: filename
            )
            let hybridPDF = try JotHybridPDFBuilder.buildHybridPDF(jot: jot)
            let attachment = ZoteroAttachment(
                key: created.key,
                parentItemKey: parentItemKey,
                contentType: "application/pdf",
                filename: filename,
                localCachePath: nil,
                syncStatus: .dirty,
                version: created.libraryVersion,
                md5: nil,
                modificationTimeMilliseconds: nil
            )
            _ = try cacheStore.registerCreatedDocument(
                item: parent,
                attachment: attachment,
                hybridPDF: hybridPDF,
                libraryVersion: created.libraryVersion,
                userID: userID
            )
            refreshCacheState()
            let documentSync = ZoteroDocumentSyncService(defaultsService: defaults, cacheStore: cacheStore)
            if let error = await documentSync.uploadCachedAttachment(key: created.key, fallbackModificationDate: nil) {
                errorMessage = error
                refreshCacheState()
                return String(localized: "zotero.create.uploadFailed")
            }
            refreshCacheState()
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: created.key)
            return nil
        } catch {
            errorMessage = error.localizedDescription
            refreshCacheState()
            return error.localizedDescription
        }
    }

    private var selectedCollectionKeys: [String] {
        if case let .collection(key) = selection { return [key] }
        return []
    }

    private static func safePDFFileName(from title: String) -> String {
        let safe =
            title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safe.isEmpty ? String(localized: "zotero.create.defaultTitle") : safe
        return base.lowercased().hasSuffix(".pdf") ? base : "\(base).pdf"
    }

    private static func authorDisplayNames(first: String, last: String, full: String) -> [String] {
        let full = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if !full.isEmpty { return [full] }
        let name = [first, last]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? [] : [name]
    }

    func childCollections(of parent: String?) -> [ZoteroCollection] {
        if collectionsByParent == nil {
            let activeKeys = ZoteroCollection.activeKeys(in: snapshot.collections)
            collectionsByParent = Dictionary(
                grouping: snapshot.collections.values.filter { activeKeys.contains($0.key) },
                by: \.parentCollectionKey
            ).mapValues { collections in
                collections.sorted {
                    let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                    return comparison == .orderedSame ? $0.key < $1.key : comparison == .orderedAscending
                }
            }
        }
        return collectionsByParent?[parent] ?? []
    }

    func attachmentGroups(for location: ZoteroLibraryLocation) -> [ZoteroAttachmentGroup] {
        if let cached = groupsByLocation[location] { return cached }
        let attachments = ZoteroLibraryAttachmentProjection.attachments(in: snapshot, location: location)
        let sorted = ZoteroLibraryAttachmentProjection.sorted(attachments, in: snapshot, sorting: sorting)
        let groups = ZoteroLibraryAttachmentProjection.groups(for: sorted, in: snapshot)
        groupsByLocation[location] = groups
        return groups
    }

    func hasUsableLocalFile(for attachment: ZoteroAttachment) -> Bool {
        cacheStore.hasUsableLocalFile(for: attachment)
    }

    func displayStatus(for attachment: ZoteroAttachment) -> ZoteroAttachmentDisplayStatus {
        ZoteroAttachmentDisplayStatus.resolve(
            syncStatus: attachment.syncStatus,
            hasLocalFile: hasUsableLocalFile(for: attachment)
        )
    }

    func shouldOfferRemoteRestore(for attachment: ZoteroAttachment) -> Bool {
        guard attachment.contentType.lowercased() == "application/pdf",
            ZoteroSyncService.isValidKey(attachment.key),
            !attachment.isLocalOnly, !attachment.isConflict,
            !isSelecting, restoringAttachmentKey == nil
        else { return false }
        let hasValidPDF = cacheStore.hasUsableLocalFile(for: attachment)
        let expectsLocalPDF =
            attachment.syncStatus == .downloaded
            || attachment.syncStatus == .dirty
            || attachment.localCachePath != nil
        let localVersionIsMissingOrBroken = expectsLocalPDF && !hasValidPDF
        return attachment.syncError != nil
            || localVersionIsMissingOrBroken
            || snapshot.pendingRemoteDownloads.contains(attachment.key)
            || cacheStore.hasUsableConflictCopy(forOriginalKey: attachment.key, userID: userID)
    }

    func recordRemoteRestoreRequest(for attachment: ZoteroAttachment) {
        let requestID = UUID().uuidString
        remoteRestoreRequestIDs[attachment.key] = requestID
        let details: [String: Any] = [
            "requestID": requestID,
            "attachmentID": String(ZoteroSyncService.md5Hex(Data(attachment.key.utf8)).prefix(12)),
            "previousSyncStatus": attachment.syncStatus.rawValue,
            "dirty": attachment.syncStatus == .dirty || attachment.isPendingSync,
            "jotFileExists": FileManager.default.fileExists(atPath: jotSessionID(for: attachment.key)),
            "conflictCopyExists": cacheStore.hasUsableConflictCopy(forOriginalKey: attachment.key, userID: userID),
        ]
        JottreDiagnostics.shared.record("zotero.forceRestore.requested", details: details)
    }

    /// Explicit user-approved restore. This is intentionally separate from
    /// ordinary open/sync and never uploads the resulting remote version.
    func restoreRemoteVersion(_ selectedAttachment: ZoteroAttachment) async throws -> [URL] {
        guard restoringAttachmentKey == nil else { throw ZoteroCacheStore.Failure.remoteRestoreAlreadyRunning }
        guard !userID.isEmpty, !apiKey.isEmpty else { throw ZoteroCacheStore.Failure.remoteRestoreMissingCredentials }
        guard ZoteroSyncService.isValidKey(selectedAttachment.key) else {
            throw ZoteroSyncService.Failure.invalidKey
        }
        let key = selectedAttachment.key
        guard let attachment = cacheStore.load(userID: userID).attachments[key],
            attachment.contentType.lowercased() == "application/pdf",
            !attachment.isLocalOnly, !attachment.isConflict
        else {
            throw ZoteroCacheStore.Failure.attachmentNotFound
        }
        let gate = ZoteroEditingSessionGate.shared
        restoringAttachmentKey = key
        let waitStartedAt = Date()
        JottreDiagnostics.shared.record(
            "zotero.syncGate.waitStarted",
            details: [
                "operation": "remoteRestore",
                "attachmentID": String(ZoteroSyncService.md5Hex(Data(key.utf8)).prefix(12)),
            ]
        )
        guard await gate.beginSynchronizationWhenAvailable() else {
            restoringAttachmentKey = nil
            throw ZoteroCacheStore.Failure.remoteRestoreBlockedByActiveEditor
        }
        JottreDiagnostics.shared.record(
            "zotero.syncGate.waitCompleted",
            details: [
                "operation": "remoteRestore",
                "attachmentID": String(ZoteroSyncService.md5Hex(Data(key.utf8)).prefix(12)),
                "waitMilliseconds": Date().timeIntervalSince(waitStartedAt) * 1_000,
            ]
        )
        defer {
            Task { @MainActor [weak self] in
                await gate.endSynchronization()
                self?.restoringAttachmentKey = nil
            }
        }

        let context = ZoteroDownloadContext(
            source: .conflictResolution,
            requestID: remoteRestoreRequestIDs.removeValue(forKey: key)
        )
        let anonymousKey = String(ZoteroSyncService.md5Hex(Data(key.utf8)).prefix(12))
        var stage = "backup"
        var backup: ZoteroRemoteRestoreBackupReceipt?
        var downloadedBytes = 0
        var httpStatus: Int?
        var details: [String: Any] = context.eventDetails
        details["attachmentID"] = anonymousKey
        details["previousSyncStatus"] = attachment.syncStatus.rawValue
        details["dirty"] = attachment.syncStatus == .dirty || attachment.isPendingSync
        details["jotFileExists"] = FileManager.default.fileExists(atPath: jotSessionID(for: key))
        details["conflictCopyExists"] = cacheStore.hasUsableConflictCopy(forOriginalKey: key, userID: userID)
        JottreDiagnostics.shared.record("zotero.forceRestore.confirmed", details: details)
        JottreDiagnostics.shared.record("zotero.forceRestore.backupStarted", details: details)
        do {
            let jotURL = URL(fileURLWithPath: jotSessionID(for: key))
            backup = try cacheStore.createRemoteRestoreBackup(
                key: key,
                userID: userID,
                additionalLocalURLs: [jotURL, pdfCacheURL(for: key)]
            )
            remoteRestoreBackupURLs = backup?.backupURLs
            details["backupSucceeded"] = true
            details["backupFileCount"] = backup?.backupURLs.count ?? 0
            details["backupID"] = backup?.directoryURL.lastPathComponent
            JottreDiagnostics.shared.record("zotero.forceRestore.backupCompleted", details: details)

            stage = "remoteMetadata"
            let remoteState = try await ZoteroAPIClient(apiKey: apiKey, userID: userID)
                .fetchAttachmentRemoteState(key: key)
            details["remoteVersion"] = remoteState.version
            details["remoteMD5Available"] = remoteState.md5 != nil

            stage = "webDAVDownload"
            JottreDiagnostics.shared.record("zotero.forceRestore.downloadStarted", details: details)
            let remoteData = try await makeSyncService().download(
                documentID: key,
                context: context,
                expectedRemoteMD5: remoteState.md5
            )
            stage = "remoteMetadataRevalidation"
            let latestRemoteState = try await ZoteroAPIClient(apiKey: apiKey, userID: userID)
                .fetchAttachmentRemoteState(key: key)
            guard latestRemoteState.version == remoteState.version,
                latestRemoteState.md5?.lowercased() == remoteState.md5?.lowercased()
            else {
                throw ZoteroDocumentSyncService.Failure.remoteVersionChanged
            }
            details["downloadVersion"] = remoteState.version
            details["revalidatedVersion"] = latestRemoteState.version
            downloadedBytes = remoteData.count
            let hasEmbeddedJot = HybridPDFManager.embeddedJotData(in: remoteData) != nil
            let unpacked = try? HybridPDFManager.load(data: remoteData)
            guard !hasEmbeddedJot || unpacked != nil else {
                throw ZoteroSyncService.Failure.invalidHybridPDF
            }
            let sourcePDF = unpacked?.pdfData ?? HybridPDFManager.pdfData(in: remoteData)
            guard isValidEditorPDFData(sourcePDF) else { throw ZoteroSyncService.Failure.invalidPDF }
            details["byteCount"] = remoteData.count
            details["pdfValid"] = true
            JottreDiagnostics.shared.record("zotero.forceRestore.validationCompleted", details: details)

            stage = "localInstall"
            let restoredJot = Jot(
                drawing: unpacked?.jot.drawing ?? Jot.makeEmpty().drawing,
                width: unpacked?.jot.width ?? Jot.defaultWidth,
                pdfData: sourcePDF,
                extraPages: unpacked?.jot.extraPages ?? 0,
                pdfInsertedPageSlots: unpacked?.jot.pdfInsertedPageSlots ?? [],
                strokePageIndices: unpacked?.jot.strokePageIndices ?? [],
                trashedPages: unpacked?.jot.trashedPages ?? [],
                zoteroItemKey: key,
                zoteroFileName: attachment.filename
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let jotData = try encoder.encode(restoredJot)
            let installedSnapshot = try cacheStore.installRemoteVersionAfterExplicitRestore(
                key: key,
                data: remoteData,
                jotData: jotData,
                jotURL: jotURL,
                userID: userID,
                cacheMD5: ZoteroSyncService.md5Hex(remoteData),
                remotePDFMD5: remoteState.md5 ?? ZoteroSyncService.md5Hex(sourcePDF),
                remoteVersion: remoteState.version,
                backup: try requireBackup(backup)
            )
            snapshot = installedSnapshot
            details["cacheInstalled"] = true
            details["finalStatus"] = installedSnapshot.attachments[key]?.syncStatus.rawValue
            JottreDiagnostics.shared.record("zotero.forceRestore.cacheInstalled", details: details)
            JottreDiagnostics.shared.record("zotero.forceRestore.completed", details: details)
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: key)
            return try requireBackup(backup).backupURLs
        } catch {
            if case WebDAVService.Failure.unexpectedResponse(let status) = error { httpStatus = status }
            details["stage"] = stage
            if let httpStatus { details["httpStatus"] = httpStatus }
            details["downloadedBytes"] = downloadedBytes
            details["errorType"] = String(reflecting: type(of: error))
            details["errorDomain"] = (error as NSError).domain
            details["errorCode"] = (error as NSError).code
            details["backupSucceeded"] = backup != nil
            if stage == "webDAVDownload" {
                JottreDiagnostics.shared.record("zotero.forceRestore.downloadFailed", details: details)
            }
            JottreDiagnostics.shared.record("zotero.forceRestore.failed", details: details)
            throw error
        }
    }

    private func requireBackup(_ backup: ZoteroRemoteRestoreBackupReceipt?) throws -> ZoteroRemoteRestoreBackupReceipt {
        guard let backup else { throw ZoteroCacheStore.Failure.remoteRestoreBackupFailed }
        return backup
    }

    func title(for attachment: ZoteroAttachment) -> String {
        attachment.parentItemKey.flatMap { snapshot.items[$0]?.title } ?? attachment.filename
    }

    func clearError() { errorMessage = nil }

    func open(_ attachment: ZoteroAttachment) async {
        guard openingAttachmentKey == nil else { return }
        openingAttachmentKey = attachment.key
        defer { openingAttachmentKey = nil }
        let sessionID = jotSessionID(for: attachment.key)
        await ZoteroEditingSessionGate.shared.beginEditing(key: attachment.key, sessionID: sessionID)
        let currentAttachment = cacheStore.load(userID: userID).attachments[attachment.key] ?? attachment
        var downloadContext: ZoteroDownloadContext?
        var sourceDataReady = false
        var remoteCacheInstalled = false
        var jotSaved = false
        var hasLocalFile = false
        var jotRecoveryFileExists = false
        var failureStage = "localCacheRead"
        do {
            var sourceData: Data
            var loadedFromLocalCache: Bool
            hasLocalFile = cacheStore.hasUsableLocalFile(for: currentAttachment)
            let recoveryJotURL = URL(fileURLWithPath: jotSessionID(for: attachment.key))
            jotRecoveryFileExists = FileManager.default.fileExists(atPath: recoveryJotURL.path)
            let recoveryJot = JotFile.Info(url: recoveryJotURL, modificationDate: nil)
                .flatMap {
                    try? JotFileService(fileService: LocalFileService(fileManager: .default)).readJotFile(
                        jotFileInfo: $0
                    ).jot
                }
            let recoverableJotPDF = recoveryJot.flatMap { jot -> Data? in
                if let data = jot.pdfData, isValidEditorPDFData(data) { return data }
                return try? JotHybridPDFBuilder.buildHybridPDF(jot: jot)
            }
            let localCacheDataIsValid =
                currentAttachment.localCachePath
                .flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
                .map { isValidEditorPDFData($0) } ?? false
            let hasConflictCopy = cacheStore.hasUsableConflictCopy(forOriginalKey: attachment.key, userID: userID)
            let currentCachePathExists =
                currentAttachment.localCachePath.map {
                    FileManager.default.fileExists(atPath: $0)
                } ?? false
            if (currentAttachment.isLocalOnly || currentAttachment.isConflict) && !hasLocalFile {
                JottreDiagnostics.shared.record(
                    "zotero.recovery.blockedForLocalChanges",
                    details: [
                        "attachmentID": String(ZoteroSyncService.md5Hex(Data(attachment.key.utf8)).prefix(12)),
                        "previousSyncStatus": currentAttachment.syncStatus.rawValue,
                        "syncErrorPresent": currentAttachment.syncError != nil,
                        "localFileValid": false,
                        "dirty": currentAttachment.syncStatus == .dirty,
                        "conflictCopyExists": hasConflictCopy,
                        "reason": "localOnlyAttachmentHasNoRemoteSource",
                    ]
                )
                throw ZoteroCacheStore.Failure.invalidLocalAttachmentFile
            }
            let canRecoverMissingDirtyCache =
                currentAttachment.syncStatus == .dirty
                && (!currentAttachment.isPendingSync || recoverableJotPDF != nil)
                && (!jotRecoveryFileExists || hasConflictCopy || recoverableJotPDF != nil)
                && (!currentCachePathExists || hasConflictCopy)
            if currentAttachment.syncStatus == .dirty && !hasLocalFile && !canRecoverMissingDirtyCache {
                JottreDiagnostics.shared.record(
                    "zotero.recovery.skippedForLocalChanges",
                    details: [
                        "attachmentID": String(ZoteroSyncService.md5Hex(Data(attachment.key.utf8)).prefix(12)),
                        "previousSyncStatus": currentAttachment.syncStatus.rawValue,
                        "pendingQueued": cacheStore.load(userID: userID).pendingRemoteDownloads.contains(
                            attachment.key
                        ),
                        "localFileValid": false,
                        "dirty": true,
                        "conflictCopyExists": hasConflictCopy,
                        "jotRecoveryFileExists": jotRecoveryFileExists,
                        "reason": "dirtyLocalDataMayExist",
                    ]
                )
                throw ZoteroCacheStore.Failure.invalidLocalAttachmentFile
            }
            if !hasLocalFile || !localCacheDataIsValid, let recoveredPDF = recoverableJotPDF {
                // The local .jot is authoritative when its derived PDF cache
                // is missing. Reopen it without contacting Zotero and rebuild
                // the derived cache locally when storage is available.
                sourceData = recoveredPDF
                loadedFromLocalCache = true
                if let repairedURL = try? cacheStore.saveEditedPDF(
                    key: currentAttachment.key,
                    data: recoveredPDF,
                    userID: userID
                ) {
                    NotificationCenter.default.post(
                        name: .zoteroAttachmentCacheChanged,
                        object: currentAttachment.key
                    )
                    print("[ZoteroRecovery] Rebuilt local PDF cache from Jot at \(repairedURL.path).")
                }
            } else if hasLocalFile, let path = currentAttachment.localCachePath {
                if let localData = try? Data(contentsOf: URL(fileURLWithPath: path)),
                    ZoteroCacheStore.isSupportedAttachmentData(localData),
                    isValidEditorPDFData(localData)
                {
                    sourceData = localData
                    loadedFromLocalCache = true
                } else if currentAttachment.syncStatus == .dirty && !canRecoverMissingDirtyCache {
                    JottreDiagnostics.shared.record(
                        "zotero.recovery.skippedForLocalChanges",
                        details: [
                            "attachmentID": String(ZoteroSyncService.md5Hex(Data(attachment.key.utf8)).prefix(12)),
                            "previousSyncStatus": currentAttachment.syncStatus.rawValue,
                            "localFileValid": false,
                            "dirty": true,
                            "conflictCopyExists": hasConflictCopy,
                            "jotRecoveryFileExists": jotRecoveryFileExists,
                            "reason": "dirtyLocalPDFInvalid; preserveLocalChanges",
                        ]
                    )
                    throw ZoteroCacheStore.Failure.invalidLocalAttachmentFile
                } else {
                    recordRecoveryValidationFailure(for: currentAttachment, reason: "localPDFKitValidationFailed")
                    let context = ZoteroDownloadContext(source: .documentOpen)
                    downloadContext = context
                    failureStage = "localPDFValidation"
                    recordRecoveryStart(for: currentAttachment, context: context)
                    sourceData = try await makeSyncService().download(
                        documentID: attachment.key,
                        context: context,
                        expectedRemoteMD5: expectedRemoteMD5(for: currentAttachment)
                    )
                    loadedFromLocalCache = false
                }
            } else {
                let context = ZoteroDownloadContext(source: .documentOpen)
                downloadContext = context
                recordRecoveryStart(for: currentAttachment, context: context)
                sourceData = try await makeSyncService().download(
                    documentID: attachment.key,
                    context: context,
                    expectedRemoteMD5: expectedRemoteMD5(for: currentAttachment)
                )
                loadedFromLocalCache = false
            }
            if jotRecoveryFileExists,
                loadedFromLocalCache,
                !localJotMatchesBaseline(for: attachment.key, data: sourceData)
            {
                if (currentAttachment.syncStatus == .dirty || currentAttachment.isPendingSync)
                    && !hasConflictCopy
                {
                    JottreDiagnostics.shared.record(
                        "zotero.recovery.blockedForLocalChanges",
                        details: [
                            "attachmentID": String(ZoteroSyncService.md5Hex(Data(attachment.key.utf8)).prefix(12)),
                            "previousSyncStatus": currentAttachment.syncStatus.rawValue,
                            "syncErrorPresent": currentAttachment.syncError != nil,
                            "localFileValid": true,
                            "dirty": true,
                            "conflictCopyExists": false,
                            "reason": "dirtyJotDiffersFromCachedPDF",
                        ]
                    )
                    throw ZoteroCacheStore.Failure.invalidLocalAttachmentFile
                }
                // A Jot may have reached disk before an older version failed
                // to commit its PDF cache. Check the remote baseline before
                // treating a byte mismatch as local ink or overwriting it.
                recordRecoveryValidationFailure(for: currentAttachment, reason: "localJotDiffersFromCacheBaseline")
                let context = ZoteroDownloadContext(source: .documentOpen)
                downloadContext = context
                failureStage = "localJotBaselineFetch"
                recordRecoveryStart(for: currentAttachment, context: context)
                sourceData = try await makeSyncService().download(
                    documentID: attachment.key,
                    context: context,
                    expectedRemoteMD5: expectedRemoteMD5(for: currentAttachment)
                )
                loadedFromLocalCache = false
            }
            sourceDataReady = true
            if let downloadContext {
                var details = downloadContext.eventDetails
                details["stage"] = "remotePDFValidation"
                details["downloadedBytes"] = sourceData.count
                details["valid"] = isValidEditorPDFData(sourceData)
                JottreDiagnostics.shared.record("zotero.recovery.remoteValidationCompleted", details: details)
            }
            if jotRecoveryFileExists,
                !localJotMatchesBaseline(for: attachment.key, data: sourceData),
                !hasConflictCopy
            {
                failureStage = "localJotBaselineValidation"
                JottreDiagnostics.shared.record(
                    "zotero.recovery.blockedForLocalChanges",
                    details: [
                        "attachmentID": String(ZoteroSyncService.md5Hex(Data(attachment.key.utf8)).prefix(12)),
                        "previousSyncStatus": currentAttachment.syncStatus.rawValue,
                        "syncErrorPresent": currentAttachment.syncError != nil,
                        "localFileValid": hasLocalFile,
                        "dirty": currentAttachment.syncStatus == .dirty || currentAttachment.isPendingSync,
                        "conflictCopyExists": false,
                        "reason": "localJotContentDiffersFromValidatedPDFBaseline",
                    ]
                )
                throw ZoteroCacheStore.Failure.invalidLocalAttachmentFile
            }

            failureStage = "hybridPDFValidation"
            let fileURL = try localJotURL(for: attachment.key)
            let hasEmbeddedJot = HybridPDFManager.embeddedJotData(in: sourceData) != nil
            let unpacked = try? HybridPDFManager.load(data: sourceData)
            if hasEmbeddedJot, case nil = unpacked {
                throw ZoteroSyncService.Failure.invalidHybridPDF
            }
            print(
                "[ZoteroLoad] Unpacking hybrid PDF from local cache... Strokes restored: \(unpacked.flatMap { try? PKDrawing(data: $0.jot.drawing).strokes.count } ?? 0)"
            )
            let sourcePDF = unpacked?.pdfData ?? HybridPDFManager.pdfData(in: sourceData)
            guard let validatedPDF = PDFDocument(data: sourcePDF), validatedPDF.pageCount > 0 else {
                throw ZoteroSyncService.Failure.invalidPDF
            }
            let title = title(for: currentAttachment)
            let jot = Jot(
                drawing: unpacked?.jot.drawing ?? Jot.makeEmpty().drawing,
                width: unpacked?.jot.width ?? Jot.defaultWidth,
                pdfData: sourcePDF,
                extraPages: unpacked?.jot.extraPages ?? 0,
                pdfInsertedPageSlots: unpacked?.jot.pdfInsertedPageSlots ?? [],
                strokePageIndices: unpacked?.jot.strokePageIndices ?? [],
                trashedPages: unpacked?.jot.trashedPages ?? [],
                zoteroItemKey: currentAttachment.key,
                zoteroFileName: currentAttachment.filename
            )
            let fileInfo = JotFile.Info(url: fileURL, name: title, modificationDate: nil)
            if !loadedFromLocalCache {
                failureStage = "localCacheSave"
                let previousCacheURL = currentAttachment.localCachePath.map(URL.init(fileURLWithPath:))
                let installedCacheURL = try savePDFCache(data: sourceData, key: currentAttachment.key)
                do {
                    let installedSnapshot = try ZoteroDownloadInstallTransaction.commit(
                        installCache: {
                            try cacheStore.markDownloaded(
                                key: currentAttachment.key,
                                path: installedCacheURL,
                                md5: ZoteroSyncService.md5Hex(sourceData),
                                userID: userID,
                                allowReplacingMissingDirtyAttachment: canRecoverMissingDirtyCache
                            )
                        },
                        persistLocalJot: { installedSnapshot in
                            snapshot = installedSnapshot
                            remoteCacheInstalled = true
                            failureStage = "localJotSave"
                            if let downloadContext {
                                var details = downloadContext.eventDetails
                                details["stage"] = "cacheInstalled"
                                details["previousSyncStatus"] = currentAttachment.syncStatus.rawValue
                                details["finalStatus"] = ZoteroAttachmentSyncStatus.downloaded.rawValue
                                details["localFileValid"] = true
                                JottreDiagnostics.shared.record("zotero.recovery.cacheInstalled", details: details)

                                details["stage"] = "localCache"
                                details["attempt"] = downloadContext.attempt
                                details["cacheSaved"] = true
                                details["byteCount"] = sourceData.count
                                JottreDiagnostics.shared.record("zotero.download.cacheSaved", details: details)
                            }
                            try JotFileService(fileService: LocalFileService(fileManager: .default))
                                .write(jotFile: JotFile(info: fileInfo, jot: jot))
                        }
                    )
                    snapshot = installedSnapshot
                    jotSaved = true
                } catch {
                    let nsError = error as NSError
                    var details: [String: Any] = [
                        "stage": "localJotRecoveryCacheCommit",
                        "attachmentID": String(ZoteroSyncService.md5Hex(Data(currentAttachment.key.utf8)).prefix(12)),
                        "jotPath": fileURL.path,
                        "jotParentExists": FileManager.default.fileExists(
                            atPath: fileURL.deletingLastPathComponent().path
                        ),
                        "jotParentWritable": FileManager.default.isWritableFile(
                            atPath: fileURL.deletingLastPathComponent().path
                        ),
                        "errorDomain": nsError.domain,
                        "errorCode": nsError.code,
                    ]
                    if let cachePath = currentAttachment.localCachePath {
                        let cacheURL = URL(fileURLWithPath: cachePath)
                        details["cachePath"] = cacheURL.path
                        details["cacheExists"] = FileManager.default.fileExists(atPath: cacheURL.path)
                        details["cacheParentExists"] = FileManager.default.fileExists(
                            atPath: cacheURL.deletingLastPathComponent().path
                        )
                    }
                    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                        details["underlyingErrorDomain"] = underlying.domain
                        details["underlyingErrorCode"] = underlying.code
                    }
                    JottreDiagnostics.shared.record("zotero.open.localRecoveryCommitFailed", details: details)
                    if !remoteCacheInstalled {
                        try? FileManager.default.removeItem(at: installedCacheURL)
                    }
                    throw error
                }
                if let previousCacheURL, previousCacheURL != installedCacheURL {
                    try? FileManager.default.removeItem(at: previousCacheURL)
                }
            } else {
                if currentAttachment.syncStatus != .dirty,
                    let cachePath = currentAttachment.localCachePath
                {
                    snapshot = try cacheStore.markDownloaded(
                        key: currentAttachment.key,
                        path: URL(fileURLWithPath: cachePath),
                        md5: ZoteroSyncService.md5Hex(sourceData),
                        userID: userID
                    )
                }
                failureStage = "localJotSave"
                try JotFileService(fileService: LocalFileService(fileManager: .default))
                    .write(jotFile: JotFile(info: fileInfo, jot: jot))
                jotSaved = true
            }
            if let downloadContext {
                var details = downloadContext.eventDetails
                details["stage"] = "localJotSaved"
                details["cacheInstalled"] = remoteCacheInstalled
                details["jotSaved"] = jotSaved
                details["finalStatus"] = snapshot.attachments[currentAttachment.key]?.syncStatus.rawValue
                JottreDiagnostics.shared.record("zotero.recovery.downloadSucceeded", details: details)
                JottreDiagnostics.shared.record("zotero.recovery.completed", details: details)
            }
            if let onOpenJot {
                onOpenJot(fileInfo)
            } else {
                await endEditingSession(sessionID: sessionID, requestSynchronization: true)
            }
        } catch {
            let wasCancelled =
                (error as? URLError)?.code == .cancelled || error is CancellationError || Task.isCancelled
            let wasBlockedForLocalChanges = failureStage == "localJotBaselineValidation"
            if let downloadContext, !wasCancelled, !wasBlockedForLocalChanges {
                var details = downloadContext.eventDetails
                details["stage"] = failureStage
                details["errorType"] = String(reflecting: type(of: error))
                details["errorDomain"] = (error as NSError).domain
                details["errorCode"] = (error as NSError).code
                details["previousSyncStatus"] = currentAttachment.syncStatus.rawValue
                details["attempt"] = downloadContext.attempt
                details["cacheInstalled"] = remoteCacheInstalled
                details["jotSaved"] = jotSaved
                let cacheCommittedJotPending = remoteCacheInstalled && !jotSaved
                if cacheCommittedJotPending {
                    details["partialRecoveryState"] = "cacheCommittedJotPendingRetry"
                    JottreDiagnostics.shared.record("zotero.recovery.partialInstall", details: details)
                }
                if case WebDAVService.Failure.unexpectedResponse(let status) = error {
                    details["httpStatus"] = status
                }
                if !cacheCommittedJotPending {
                    JottreDiagnostics.shared.record("zotero.recovery.downloadFailed", details: details)
                    JottreDiagnostics.shared.record("zotero.recovery.remoteDownloadFailed", details: details)
                }
            }
            if sourceDataReady, let downloadContext, !wasCancelled,
                !wasBlockedForLocalChanges,
                !(remoteCacheInstalled && !jotSaved)
            {
                ZoteroSyncService.recordDownloadFailure(
                    error,
                    context: downloadContext,
                    stageOverride: failureStage
                )
            }
            if !wasCancelled, downloadContext == nil, failureStage == "hybridPDFValidation" {
                try? cacheStore.recordPendingSyncError(
                    key: currentAttachment.key,
                    message: "Could not download or open the PDF.",
                    userID: userID
                )
                snapshot = cacheStore.load(userID: userID)
                JottreDiagnostics.shared.record(
                    "zotero.recovery.localValidationFailed",
                    details: [
                        "attachmentID": String(ZoteroSyncService.md5Hex(Data(currentAttachment.key.utf8)).prefix(12)),
                        "previousSyncStatus": currentAttachment.syncStatus.rawValue,
                        "syncErrorPresent": currentAttachment.syncError != nil,
                        "localFileValid": cacheStore.hasUsableLocalFile(for: currentAttachment),
                        "dirty": currentAttachment.syncStatus == .dirty || currentAttachment.isPendingSync,
                        "conflictCopyExists": cacheStore.hasUsableConflictCopy(
                            forOriginalKey: currentAttachment.key,
                            userID: userID
                        ),
                        "reason": "PDFKitOrHybridJotValidationFailed",
                    ]
                )
            }
            await endEditingSession(sessionID: sessionID, requestSynchronization: !wasCancelled)
            if !wasCancelled {
                if !hasLocalFile && !jotRecoveryFileExists {
                    errorMessage = String(
                        localized: "zotero.open.downloadRequired",
                        defaultValue:
                            "This document is not stored on this device. Connect to the internet and download it before opening."
                    )
                } else {
                    errorMessage = String(localized: "zotero.error.openPDF")
                }
            }
        }
    }

    private func recordRecoveryStart(for attachment: ZoteroAttachment, context: ZoteroDownloadContext) {
        var details = context.eventDetails
        details["attachmentID"] = String(ZoteroSyncService.md5Hex(Data(attachment.key.utf8)).prefix(12))
        details["stage"] = "downloadStarted"
        details["previousSyncStatus"] = attachment.syncStatus.rawValue
        details["pendingQueued"] = cacheStore.load(userID: userID).pendingRemoteDownloads.contains(attachment.key)
        details["localFileValid"] = cacheStore.hasUsableLocalFile(for: attachment)
        details["dirty"] = attachment.syncStatus == .dirty
        details["conflictCopyExists"] = cacheStore.hasUsableConflictCopy(forOriginalKey: attachment.key, userID: userID)
        details["syncErrorPresent"] = attachment.syncError != nil
        JottreDiagnostics.shared.record("zotero.recovery.started", details: details)
        JottreDiagnostics.shared.record("zotero.recovery.remoteDownloadStarted", details: details)
    }

    private func isValidEditorPDFData(_ data: Data) -> Bool {
        let embeddedJot = HybridPDFManager.embeddedJotData(in: data)
        let unpacked = try? HybridPDFManager.load(data: data)
        guard embeddedJot == nil || unpacked != nil else { return false }
        let payload = unpacked?.pdfData ?? HybridPDFManager.pdfData(in: data)
        guard let document = PDFDocument(data: payload) else { return false }
        return document.pageCount > 0
    }

    private func localJotMatchesBaseline(for key: String, data baselineData: Data) -> Bool {
        let jotURL = URL(fileURLWithPath: jotSessionID(for: key))
        guard let info = JotFile.Info(url: jotURL, modificationDate: nil),
            let file = try? JotFileService(fileService: LocalFileService(fileManager: .default))
                .readJotFile(jotFileInfo: info),
            file.jot.pdfData != nil
        else { return false }

        return ZoteroLocalJotBaselineValidator.matches(localJot: file.jot, baselineData: baselineData)
    }

    private func expectedRemoteMD5(for attachment: ZoteroAttachment) -> String? {
        if attachment.verificationRemoteMD5WasChecked {
            return attachment.verificationRemoteMD5
        }
        return attachment.remoteMD5IsPDF ? attachment.remoteMD5 : nil
    }

    private func recordRecoveryValidationFailure(for attachment: ZoteroAttachment, reason: String) {
        JottreDiagnostics.shared.record(
            "zotero.recovery.localValidationFailed",
            details: [
                "attachmentID": String(ZoteroSyncService.md5Hex(Data(attachment.key.utf8)).prefix(12)),
                "previousSyncStatus": attachment.syncStatus.rawValue,
                "syncErrorPresent": attachment.syncError != nil,
                "localFileValid": false,
                "dirty": attachment.syncStatus == .dirty,
                "conflictCopyExists": cacheStore.hasUsableConflictCopy(forOriginalKey: attachment.key, userID: userID),
                "reason": reason,
            ]
        )
    }

    private func jotSessionID(for key: String) -> String {
        (try? localJotURL(for: key).standardizedFileURL.path) ?? ""
    }

    private func endEditingSession(sessionID: String, requestSynchronization: Bool) async {
        let result = await ZoteroEditingSessionGate.shared.endEditing(sessionID: sessionID)
        if result.shouldSynchronize && requestSynchronization {
            NotificationCenter.default.post(name: .zoteroEditorDidEnd, object: result.key)
        }
    }

    private func makeSyncService() -> ZoteroSyncService {
        let url = defaults.getValue(.webDAVURL) ?? ""
        let baseURL = URL(string: url) ?? URL(string: "https://invalid.local/")!
        return ZoteroSyncService(
            service: WebDAVService(
                baseURL: baseURL,
                username: defaults.getValue(.webDAVUsername) ?? "",
                password: keychain.value(for: "webdav_password") ?? ""
            ),
            apiClient: ZoteroAPIClient(apiKey: apiKey, userID: userID)
        )
    }

    private func localJotURL(for key: String) throws -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZoteroJots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let attachment =
            snapshot.attachments[key]
            ?? snapshot.attachments[cacheStore.canonicalAttachmentKey(key, userID: userID)]
        let stableID = attachment?.localDocumentID ?? key
        let stableURL = folder.appendingPathComponent("\(stableID).jot")
        if FileManager.default.fileExists(atPath: stableURL.path) { return stableURL }
        // Temporary-key Jot files from older builds remain openable after
        // cache metadata has acquired its deterministic legacy local ID.
        let legacyURL = folder.appendingPathComponent("\(key).jot")
        if FileManager.default.fileExists(atPath: legacyURL.path) { return legacyURL }
        return stableURL
    }

    private func pdfCacheURL(for key: String) -> URL {
        if let attachment = snapshot.attachments[key]
            ?? snapshot.attachments[cacheStore.canonicalAttachmentKey(key, userID: userID)],
            let path = attachment.localCachePath, !path.isEmpty
        {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZoteroPDFs", isDirectory: true)
            .appendingPathComponent("\(key).pdf")
    }

    private func savePDFCache(data: Data, key: String) throws -> URL {
        let url = pdfCacheURL(for: key).deletingLastPathComponent()
            .appendingPathComponent("\(key).\(UUID().uuidString).pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        guard isValidEditorPDFData(data) else {
            try? FileManager.default.removeItem(at: url)
            throw ZoteroSyncService.Failure.invalidPDF
        }
        return url
    }

}

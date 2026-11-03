import SwiftUI
@preconcurrency import PencilKit
import Network
import PDFKit
import UniformTypeIdentifiers

enum ZoteroLibraryLocation: Hashable {
    case myLibrary
    case collection(String)
    case unfiled
    case trash
}

private enum ZoteroNoteOrientation: String, CaseIterable, Identifiable {
    case portrait
    case landscape

    var id: String { rawValue }

    var title: String {
        String(localized: "zotero.create.orientation.\(rawValue)")
    }

    var pageSize: CGSize {
        switch self {
        case .portrait: CGSize(width: 1200, height: 1600)
        case .landscape: CGSize(width: 1600, height: 1200)
        }
    }
}

struct ZoteroAttachmentGroup: Identifiable {
    let key: String
    let title: String
    let subtitle: String
    let attachments: [ZoteroAttachment]
    var id: String { key }
}

enum ZoteroAttachmentDisplayStatus: Equatable {
    case cloudOnly
    case downloaded
    case pendingSync
    case missingLocalChanges

    static func resolve(syncStatus: ZoteroAttachmentSyncStatus, hasLocalFile: Bool) -> Self {
        switch syncStatus {
        case .cloudOnly, .downloaded:
            return hasLocalFile ? .downloaded : .cloudOnly
        case .dirty:
            return hasLocalFile ? .pendingSync : .missingLocalChanges
        }
    }
}

enum ZoteroSyncTrigger: String {
    case appLaunch, editorFinished, periodic, networkReconnect, manual, accountChanged
}

enum ZoteroSyncSchedule {
    static let minimumAutomaticInterval: TimeInterval = 600

    static func shouldRun(_ trigger: ZoteroSyncTrigger, lastAttempt: Date?, now: Date = Date()) -> Bool {
        switch trigger {
        case .appLaunch, .editorFinished, .manual, .accountChanged: return true
        case .periodic, .networkReconnect:
            guard let lastAttempt else { return true }
            return now.timeIntervalSince(lastAttempt) >= minimumAutomaticInterval
        }
    }
}

enum ZoteroDownloadInstallTransaction {
    /// A committed cache is the durable recovery point. If the atomic Jot
    /// write fails, the next open rebuilds it from the validated cache.
    static func commit<CacheState>(
        installCache: () throws -> CacheState,
        persistLocalJot: (CacheState) throws -> Void
    ) throws -> CacheState {
        let installedState = try installCache()
        try persistLocalJot(installedState)
        return installedState
    }
}

@MainActor
enum ZoteroLocalJotBaselineValidator {
    static func matches(localJot: Jot, baselineData: Data) -> Bool {
        guard localJot.pdfData != nil,
              let localDrawing = try? PKDrawing(data: localJot.drawing) else { return false }
        let baselineJot = (try? HybridPDFManager.load(data: baselineData).jot) ?? Jot.makeEmpty()
        guard let baselineDrawing = try? PKDrawing(data: baselineJot.drawing),
              JotEditorDrawingState.drawingsMatch(localDrawing, baselineDrawing),
              localJot.width == baselineJot.width,
              localJot.extraPages == baselineJot.extraPages,
              localJot.pdfInsertedPageSlots == baselineJot.pdfInsertedPageSlots,
              localJot.strokePageIndices == baselineJot.strokePageIndices,
              localJot.trashedPages == baselineJot.trashedPages else { return false }
        return true
    }
}

enum ZoteroLibraryAttachmentProjection {
    static func attachments(
        in snapshot: ZoteroCacheSnapshot,
        location: ZoteroLibraryLocation
    ) -> [ZoteroAttachment] {
        snapshot.attachments.values.filter { attachment in
            let attachmentItem = snapshot.items[attachment.key]
            let attachmentIsTrashed = attachmentItem?.isTrashed ?? false
            let owner = attachment.parentItemKey.flatMap { snapshot.items[$0] } ?? attachmentItem
            guard let owner else { return location == .myLibrary && !attachmentIsTrashed }

            switch location {
            case .myLibrary:
                return !owner.isTrashed && !attachmentIsTrashed
            case .collection(let key):
                return !owner.isTrashed && !attachmentIsTrashed && owner.collectionKeys.contains(key)
            case .unfiled:
                return !owner.isTrashed && !attachmentIsTrashed
                    && owner.collectionKeys.isEmpty && owner.parentItemKey == nil
            case .trash:
                return owner.isTrashed || attachmentIsTrashed
            }
        }
    }

    static func groups(
        for visibleAttachments: [ZoteroAttachment],
        in snapshot: ZoteroCacheSnapshot
    ) -> [ZoteroAttachmentGroup] {
        var order: [String] = []
        var grouped: [String: [ZoteroAttachment]] = [:]
        for attachment in visibleAttachments {
            let groupKey = attachment.parentItemKey ?? attachment.key
            if grouped[groupKey] == nil { order.append(groupKey) }
            grouped[groupKey, default: []].append(attachment)
        }
        return order.compactMap { key in
            guard let attachments = grouped[key], !attachments.isEmpty else { return nil }
            let parent = snapshot.items[key]
            var details = parent?.creators.prefix(2).joined(separator: ", ") ?? ""
            if let year = parent?.year { details += details.isEmpty ? year : " · \(year)" }
            return ZoteroAttachmentGroup(
                key: key,
                title: parent?.title ?? attachments[0].filename,
                subtitle: details,
                attachments: attachments
            )
        }
    }
}

@MainActor
private final class ZoteroLibraryViewModel: ObservableObject {
    @Published private(set) var snapshot: ZoteroCacheSnapshot
    @Published var selection: ZoteroLibraryLocation = .myLibrary
    @Published private(set) var isSyncing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var openingAttachmentKey: String?
    @Published private(set) var restoringAttachmentKey: String?
    @Published private(set) var remoteRestoreBackupURLs: [URL]?
    @Published private(set) var sorting: ZoteroLibrarySorting
    var sortOrder: ZoteroAttachmentSortOrder { sorting.order }
    var isSortReversed: Bool { sorting.isReversed }
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

    deinit { networkMonitor.cancel(); periodicSyncTask?.cancel() }

    func synchronize(trigger: ZoteroSyncTrigger = .manual) async {
        guard !userID.isEmpty, !apiKey.isEmpty else { return }
        let now = Date()
        var requestDetails: [String: Any] = ["trigger": trigger.rawValue]
        if let lastSynchronizationAttempt {
            requestDetails["lastAttemptAgeSeconds"] = now.timeIntervalSince(lastSynchronizationAttempt)
        }
        JottreDiagnostics.shared.record("zotero.sync.requested", details: requestDetails)
        guard ZoteroSyncSchedule.shouldRun(trigger, lastAttempt: lastSynchronizationAttempt, now: now) else {
            JottreDiagnostics.shared.record("zotero.sync.skipped", details: ["trigger": trigger.rawValue, "reason": "minimumInterval"])
            return
        }
        guard !isSyncing else {
            if trigger == .editorFinished || trigger == .accountChanged { synchronizationRequestedWhileSyncing = true }
            JottreDiagnostics.shared.record("zotero.sync.joined", details: ["trigger": trigger.rawValue, "followUpRequired": synchronizationRequestedWhileSyncing])
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
            JottreDiagnostics.shared.record("zotero.sync.skipped", details: ["trigger": trigger.rawValue, "reason": "editingSessionOrGateBusy"])
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
                        expectedRemoteMD5 = attachment?.syncStatus == .cloudOnly && attachment?.remoteMD5IsPDF == true
                            ? attachment?.remoteMD5
                            : nil
                    }
                    return try await syncService.download(
                        documentID: key,
                        context: context,
                        expectedRemoteMD5: expectedRemoteMD5
                    )
                }
            )
            guard syncUserID == userID else {
                JottreDiagnostics.shared.record("zotero.sync.skipped", details: ["trigger": trigger.rawValue, "reason": "accountChangedDuringSync"])
                await syncGate.endSynchronization()
                return
            }
            snapshot = synchronizedSnapshot
            if case .collection(let key) = selection, snapshot.collections[key] == nil {
                selection = .myLibrary
            }
            errorMessage = nil
            JottreDiagnostics.shared.record("zotero.sync.completed", details: ["trigger": trigger.rawValue, "durationMilliseconds": Date().timeIntervalSince(startedAt) * 1_000])
        } catch {
            errorMessage = String(localized: "zotero.error.librarySync")
            JottreDiagnostics.shared.record("zotero.sync.failed", details: ["trigger": trigger.rawValue, "durationMilliseconds": Date().timeIntervalSince(startedAt) * 1_000, "errorDomain": (error as NSError).domain, "errorCode": (error as NSError).code])
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
                key: itemKey, title: title, creators: creators, date: date, userID: userID
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
                    keys: [key], toCollectionKey: collectionKey, userID: userID
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
        var latestSnapshot = snapshot
        do {
            let api = ZoteroAPIClient(apiKey: apiKey, userID: userID)
            for key in keys.sorted() {
                try await api.setItemTrashed(key: key, isTrashed: true)
                latestSnapshot = try cacheStore.markItemsTrashed(keys: [key], userID: userID)
                snapshot = latestSnapshot
            }
            selectedItemKeys.subtract(keys)
        } catch {
            snapshot = latestSnapshot
            errorMessage = error.localizedDescription
        }
    }

    func restoreItems(_ keys: Set<String>) async {
        var latestSnapshot = snapshot
        do {
            let api = ZoteroAPIClient(apiKey: apiKey, userID: userID)
            for key in keys.sorted() {
                try await api.setItemTrashed(key: key, isTrashed: false)
                latestSnapshot = try cacheStore.restoreItems(keys: [key], userID: userID)
                snapshot = latestSnapshot
            }
            selectedItemKeys.subtract(keys)
        } catch {
            snapshot = latestSnapshot
            errorMessage = error.localizedDescription
        }
    }

    func permanentlyDeleteItems(_ keys: Set<String>) async {
        var latestSnapshot = snapshot
        do {
            let api = ZoteroAPIClient(apiKey: apiKey, userID: userID)
            let syncService = makeSyncService()
            for key in keys.sorted() {
                guard snapshot.items[key]?.isTrashed == true else { continue }
                let childAttachmentKeys = snapshot.attachments.values
                    .filter { $0.parentItemKey == key }
                    .map(\.key)
                    .filter(ZoteroSyncService.isValidKey)
                    .sorted()
                // Zotero's API deletes individual objects; remove PDF children
                // before their parent so no orphaned attachments remain.
                for attachmentKey in childAttachmentKeys {
                    try await api.permanentlyDeleteItem(key: attachmentKey)
                }
                try await api.permanentlyDeleteItem(key: key)

                var cleanupErrors: [String] = []
                let remoteAttachmentKeys = Set(childAttachmentKeys).union(
                    snapshot.attachments[key] == nil ? [] : [key]
                )
                for attachmentKey in remoteAttachmentKeys.sorted() {
                    do { try await syncService.deleteRemoteAttachment(documentID: attachmentKey) }
                    catch { cleanupErrors.append(error.localizedDescription) }
                }
                latestSnapshot = try cacheStore.permanentlyDeleteItems(keys: [key], userID: userID)
                snapshot = latestSnapshot
                if !cleanupErrors.isEmpty {
                    errorMessage = String(localized: "zotero.document.delete.cleanupFailed")
                }
            }
            selectedItemKeys.subtract(keys)
        } catch {
            snapshot = latestSnapshot
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
                  currentOriginal?.remoteMD5IsPDF == true else {
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
                    "syncStatus": cacheStore.load(userID: userID).attachments[originalKey]?.syncStatus.rawValue ?? "unknown"
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
            if shouldSynchronizeAfterFailure { await synchronize() }
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
                  let originalKey = cacheStore.conflictOriginalKey(for: conflictKey, userID: userID) else {
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
                key: conflictKey, serverData: serverData, userID: userID
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
                  let item = snapshot.items[conflictKey] else {
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
            let (serverData, serverState) = try await downloadStableConflictVersion(key: originalKey, context: resolutionContext)
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
            let originalRemoteStillMatches = if let initialMD5 = serverState.md5,
                let latestMD5 = latestServerState.md5 {
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
                    "syncStatus": cacheStore.load(userID: userID).attachments[created.attachmentKey]?.syncStatus.rawValue ?? "unknown"
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
                      !["attachment", "note", "annotation"].contains(parent.itemType) else {
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
            let item = existingParent ?? ZoteroItem(
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
            let cacheURL: URL
            if existingParent == nil {
                cacheURL = try cacheStore.registerOfflineDraft(
                    item: item,
                    attachment: attachment,
                    hybridPDF: hybridPDF,
                    userID: userID
                )
            } else {
                cacheURL = try cacheStore.registerPendingAttachment(
                    parentItem: item,
                    attachment: attachment,
                    hybridPDF: hybridPDF,
                    userID: userID
                )
            }
            let fileURL = try localJotURL(for: temporaryAttachmentKey)
            let jotWithPDF = Jot(
                drawing: empty.drawing,
                width: pageSize.width,
                pdfData: hybridPDF,
                zoteroItemKey: temporaryAttachmentKey,
                zoteroFileName: filename
            )
            let fileInfo = JotFile.Info(url: fileURL, name: resolvedTitle, modificationDate: now)
            try JotFileService(fileService: LocalFileService(fileManager: .default))
                .write(jotFile: JotFile(info: fileInfo, jot: jotWithPDF))

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
            await synchronize()
            let currentKey = cacheStore.canonicalAttachmentKey(temporaryAttachmentKey, userID: userID)
            let currentAttachment = cacheStore.load(userID: userID).attachments[currentKey]
            if currentAttachment?.isPendingSync == true { return String(localized: "zotero.create.offlineDraft") }
            if currentAttachment?.syncStatus == .dirty { return String(localized: "zotero.create.uploadFailed") }
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
           Date().timeIntervalSince(fetchedAt) < 3_600 {
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
           Date().timeIntervalSince(fetchedAt) < 3_600 {
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
        guard creators.allSatisfy({ creator in
            creator.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || schema.creatorTypes.contains(where: { $0.creatorType == creator.creatorType })
        }) else { return String(localized: "zotero.import.invalidCreatorRole") }
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
            await synchronize()
            return cacheStore.load(userID: userID).attachments[temporaryAttachmentKey]?.isPendingSync == true
                ? String(localized: "zotero.create.offlineDraft")
                : nil
        } catch {
            return "\(String(localized: "zotero.create.failed"))\n\(error.localizedDescription)"
        }
    }

    func addPDFAttachment(data sourcePDF: Data, filename originalFilename: String, to parentItemKey: String) async -> String? {
        guard Int(userID) != nil, !apiKey.isEmpty else {
            return String(localized: "zotero.create.accountRequired")
        }
        guard let pdf = PDFDocument(data: sourcePDF), pdf.pageCount > 0,
              let parent = snapshot.items[parentItemKey], parent.parentItemKey == nil,
              !["attachment", "note", "annotation"].contains(parent.itemType) else {
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
        let safe = title
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
        let activeKeys = ZoteroCollection.activeKeys(in: snapshot.collections)
        return snapshot.collections.values
            .filter { activeKeys.contains($0.key) && $0.parentCollectionKey == parent }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func attachments(for location: ZoteroLibraryLocation) -> [ZoteroAttachment] {
        ZoteroLibraryAttachmentProjection.attachments(in: snapshot, location: location)
            .sorted(by: isOrderedBefore)
    }

    func attachmentGroups(for location: ZoteroLibraryLocation) -> [ZoteroAttachmentGroup] {
        ZoteroLibraryAttachmentProjection.groups(for: attachments(for: location), in: snapshot)
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
              !isSelecting, restoringAttachmentKey == nil else { return false }
        let hasValidPDF = cacheStore.hasUsableLocalFile(for: attachment)
        let expectsLocalPDF = attachment.syncStatus == .downloaded
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
            "conflictCopyExists": cacheStore.hasUsableConflictCopy(forOriginalKey: attachment.key, userID: userID)
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
              !attachment.isLocalOnly, !attachment.isConflict else {
            throw ZoteroCacheStore.Failure.attachmentNotFound
        }
        let gate = ZoteroEditingSessionGate.shared
        restoringAttachmentKey = key
        let waitStartedAt = Date()
        JottreDiagnostics.shared.record("zotero.syncGate.waitStarted", details: [
            "operation": "remoteRestore",
            "attachmentID": String(ZoteroSyncService.md5Hex(Data(key.utf8)).prefix(12))
        ])
        guard await gate.beginSynchronizationWhenAvailable() else {
            restoringAttachmentKey = nil
            throw ZoteroCacheStore.Failure.remoteRestoreBlockedByActiveEditor
        }
        JottreDiagnostics.shared.record("zotero.syncGate.waitCompleted", details: [
            "operation": "remoteRestore",
            "attachmentID": String(ZoteroSyncService.md5Hex(Data(key.utf8)).prefix(12)),
            "waitMilliseconds": Date().timeIntervalSince(waitStartedAt) * 1_000
        ])
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
                  latestRemoteState.md5?.lowercased() == remoteState.md5?.lowercased() else {
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

    private func isOrderedBefore(_ lhs: ZoteroAttachment, _ rhs: ZoteroAttachment) -> Bool {
        switch sortOrder {
        case .title:
            return compareTitles(lhs, rhs)
        case .dateAdded:
            return compareDates(dateAdded(for: lhs), dateAdded(for: rhs), lhs: lhs, rhs: rhs)
        case .recentlyModified:
            return compareDates(dateModified(for: lhs), dateModified(for: rhs), lhs: lhs, rhs: rhs)
        }
    }

    private func compareTitles(_ lhs: ZoteroAttachment, _ rhs: ZoteroAttachment) -> Bool {
        let comparison = title(for: lhs).localizedCaseInsensitiveCompare(title(for: rhs))
        let tieBreaker = lhs.key.localizedCaseInsensitiveCompare(rhs.key)
        let finalComparison = comparison == .orderedSame ? tieBreaker : comparison
        return isSortReversed
            ? finalComparison == .orderedDescending
            : finalComparison == .orderedAscending
    }

    private func compareDates(_ lhsDate: Date?, _ rhsDate: Date?, lhs: ZoteroAttachment, rhs: ZoteroAttachment) -> Bool {
        switch (lhsDate, rhsDate) {
        case let (lhsDate?, rhsDate?):
            if lhsDate == rhsDate { return compareTitles(lhs, rhs) }
            return isSortReversed ? lhsDate < rhsDate : lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return compareTitles(lhs, rhs)
        }
    }

    private func dateAdded(for attachment: ZoteroAttachment) -> Date? {
        snapshot.items[attachment.key]?.dateAdded
            ?? attachment.parentItemKey.flatMap { snapshot.items[$0]?.dateAdded }
    }

    private func dateModified(for attachment: ZoteroAttachment) -> Date? {
        snapshot.items[attachment.key]?.dateModified
            ?? attachment.parentItemKey.flatMap { snapshot.items[$0]?.dateModified }
    }

    func title(for attachment: ZoteroAttachment) -> String {
        attachment.parentItemKey.flatMap { snapshot.items[$0]?.title } ?? attachment.filename
    }

    func subtitle(for attachment: ZoteroAttachment) -> String {
        guard let item = attachment.parentItemKey.flatMap({ snapshot.items[$0] }) else {
            return attachment.filename
        }
        var details = item.creators.prefix(2).joined(separator: ", ")
        if let year = item.year { details += details.isEmpty ? year : " · \(year)" }
        if !details.isEmpty { details += " · " }
        return details + attachment.filename
    }

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
        var failureStage = "localCacheRead"
        do {
            var sourceData: Data
            var loadedFromLocalCache: Bool
            let hasLocalFile = cacheStore.hasUsableLocalFile(for: currentAttachment)
            let jotRecoveryFileExists = FileManager.default.fileExists(atPath: jotSessionID(for: attachment.key))
            let hasConflictCopy = cacheStore.hasUsableConflictCopy(forOriginalKey: attachment.key, userID: userID)
            let currentCachePathExists = currentAttachment.localCachePath.map {
                FileManager.default.fileExists(atPath: $0)
            } ?? false
            if (currentAttachment.isLocalOnly || currentAttachment.isConflict) && !hasLocalFile {
                JottreDiagnostics.shared.record("zotero.recovery.blockedForLocalChanges", details: [
                    "attachmentID": String(ZoteroSyncService.md5Hex(Data(attachment.key.utf8)).prefix(12)),
                    "previousSyncStatus": currentAttachment.syncStatus.rawValue,
                    "syncErrorPresent": currentAttachment.syncError != nil,
                    "localFileValid": false,
                    "dirty": currentAttachment.syncStatus == .dirty,
                    "conflictCopyExists": hasConflictCopy,
                    "reason": "localOnlyAttachmentHasNoRemoteSource"
                ])
                throw ZoteroCacheStore.Failure.invalidLocalAttachmentFile
            }
            let canRecoverMissingDirtyCache = currentAttachment.syncStatus == .dirty
                && !currentAttachment.isPendingSync
                && (!jotRecoveryFileExists || hasConflictCopy)
                && (!currentCachePathExists || hasConflictCopy)
            if currentAttachment.syncStatus == .dirty && !hasLocalFile && !canRecoverMissingDirtyCache {
                JottreDiagnostics.shared.record("zotero.recovery.skippedForLocalChanges", details: [
                    "attachmentID": String(ZoteroSyncService.md5Hex(Data(attachment.key.utf8)).prefix(12)),
                    "previousSyncStatus": currentAttachment.syncStatus.rawValue,
                    "pendingQueued": cacheStore.load(userID: userID).pendingRemoteDownloads.contains(attachment.key),
                    "localFileValid": false,
                    "dirty": true,
                    "conflictCopyExists": hasConflictCopy,
                    "jotRecoveryFileExists": jotRecoveryFileExists,
                    "reason": "dirtyLocalDataMayExist"
                ])
                throw ZoteroCacheStore.Failure.invalidLocalAttachmentFile
            }
            if hasLocalFile, let path = currentAttachment.localCachePath {
                if let localData = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   ZoteroCacheStore.isSupportedAttachmentData(localData),
                   isValidEditorPDFData(localData) {
                    sourceData = localData
                    loadedFromLocalCache = true
                } else if currentAttachment.syncStatus == .dirty && !canRecoverMissingDirtyCache {
                    JottreDiagnostics.shared.record("zotero.recovery.skippedForLocalChanges", details: [
                        "attachmentID": String(ZoteroSyncService.md5Hex(Data(attachment.key.utf8)).prefix(12)),
                        "previousSyncStatus": currentAttachment.syncStatus.rawValue,
                        "localFileValid": false,
                        "dirty": true,
                        "conflictCopyExists": hasConflictCopy,
                        "jotRecoveryFileExists": jotRecoveryFileExists,
                        "reason": "dirtyLocalPDFInvalid; preserveLocalChanges"
                    ])
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
               !localJotMatchesBaseline(for: attachment.key, data: sourceData) {
                if (currentAttachment.syncStatus == .dirty || currentAttachment.isPendingSync)
                    && !hasConflictCopy {
                    JottreDiagnostics.shared.record("zotero.recovery.blockedForLocalChanges", details: [
                        "attachmentID": String(ZoteroSyncService.md5Hex(Data(attachment.key.utf8)).prefix(12)),
                        "previousSyncStatus": currentAttachment.syncStatus.rawValue,
                        "syncErrorPresent": currentAttachment.syncError != nil,
                        "localFileValid": true,
                        "dirty": true,
                        "conflictCopyExists": false,
                        "reason": "dirtyJotDiffersFromCachedPDF"
                    ])
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
               !hasConflictCopy {
                failureStage = "localJotBaselineValidation"
                JottreDiagnostics.shared.record("zotero.recovery.blockedForLocalChanges", details: [
                    "attachmentID": String(ZoteroSyncService.md5Hex(Data(attachment.key.utf8)).prefix(12)),
                    "previousSyncStatus": currentAttachment.syncStatus.rawValue,
                    "syncErrorPresent": currentAttachment.syncError != nil,
                    "localFileValid": hasLocalFile,
                    "dirty": currentAttachment.syncStatus == .dirty || currentAttachment.isPendingSync,
                    "conflictCopyExists": false,
                    "reason": "localJotContentDiffersFromValidatedPDFBaseline"
                ])
                throw ZoteroCacheStore.Failure.invalidLocalAttachmentFile
            }

            failureStage = "hybridPDFValidation"
            let fileURL = try localJotURL(for: attachment.key)
            let hasEmbeddedJot = HybridPDFManager.embeddedJotData(in: sourceData) != nil
            let unpacked = try? HybridPDFManager.load(data: sourceData)
            if hasEmbeddedJot, case nil = unpacked {
                throw ZoteroSyncService.Failure.invalidHybridPDF
            }
            print("[ZoteroLoad] Unpacking hybrid PDF from local cache... Strokes restored: \(unpacked.flatMap { try? PKDrawing(data: $0.jot.drawing).strokes.count } ?? 0)")
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
                        "jotParentExists": FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path),
                        "jotParentWritable": FileManager.default.isWritableFile(atPath: fileURL.deletingLastPathComponent().path),
                        "errorDomain": nsError.domain,
                        "errorCode": nsError.code
                    ]
                    if let cachePath = currentAttachment.localCachePath {
                        let cacheURL = URL(fileURLWithPath: cachePath)
                        details["cachePath"] = cacheURL.path
                        details["cacheExists"] = FileManager.default.fileExists(atPath: cacheURL.path)
                        details["cacheParentExists"] = FileManager.default.fileExists(atPath: cacheURL.deletingLastPathComponent().path)
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
                   let cachePath = currentAttachment.localCachePath {
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
            let wasCancelled = (error as? URLError)?.code == .cancelled || error is CancellationError || Task.isCancelled
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
               !(remoteCacheInstalled && !jotSaved) {
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
                JottreDiagnostics.shared.record("zotero.recovery.localValidationFailed", details: [
                    "attachmentID": String(ZoteroSyncService.md5Hex(Data(currentAttachment.key.utf8)).prefix(12)),
                    "previousSyncStatus": currentAttachment.syncStatus.rawValue,
                    "syncErrorPresent": currentAttachment.syncError != nil,
                    "localFileValid": cacheStore.hasUsableLocalFile(for: currentAttachment),
                    "dirty": currentAttachment.syncStatus == .dirty || currentAttachment.isPendingSync,
                    "conflictCopyExists": cacheStore.hasUsableConflictCopy(forOriginalKey: currentAttachment.key, userID: userID),
                    "reason": "PDFKitOrHybridJotValidationFailed"
                ])
            }
            await endEditingSession(sessionID: sessionID, requestSynchronization: !wasCancelled)
            if !wasCancelled {
                errorMessage = String(localized: "zotero.error.openPDF")
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
              file.jot.pdfData != nil else { return false }

        return ZoteroLocalJotBaselineValidator.matches(localJot: file.jot, baselineData: baselineData)
    }

    private func expectedRemoteMD5(for attachment: ZoteroAttachment) -> String? {
        if attachment.verificationRemoteMD5WasChecked {
            return attachment.verificationRemoteMD5
        }
        return attachment.remoteMD5IsPDF ? attachment.remoteMD5 : nil
    }

    private func recordRecoveryValidationFailure(for attachment: ZoteroAttachment, reason: String) {
        JottreDiagnostics.shared.record("zotero.recovery.localValidationFailed", details: [
            "attachmentID": String(ZoteroSyncService.md5Hex(Data(attachment.key.utf8)).prefix(12)),
            "previousSyncStatus": attachment.syncStatus.rawValue,
            "syncErrorPresent": attachment.syncError != nil,
            "localFileValid": false,
            "dirty": attachment.syncStatus == .dirty,
            "conflictCopyExists": cacheStore.hasUsableConflictCopy(forOriginalKey: attachment.key, userID: userID),
            "reason": reason
        ])
    }

    private func jotSessionID(for key: String) -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZoteroJots", isDirectory: true)
            .appendingPathComponent("\(key).jot")
            .standardizedFileURL.path
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
        return folder.appendingPathComponent("\(key).jot")
    }

    private func pdfCacheURL(for key: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
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

struct ZoteroLibraryView: View {
    @StateObject private var model: ZoteroLibraryViewModel
    @ObservedObject private var syncProgress: ZoteroSyncProgress
    @State private var showingSettings = false
    @State private var showingNewDocument = false
    @State private var newNoteParentKey: String?
    @State private var showingPDFImporter = false
    @State private var showingAttachmentImporter = false
    @State private var showingPDFCreation = false
    @State private var pendingAttachmentParentKey: String?
    @State private var importedPDFData: Data?
    @State private var importedPDFName: String?
    @State private var creationNotice: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var expandedAttachmentGroups = Set<String>()
    @State private var editingItem: ZoteroItem?
    @State private var movingItemKeys = Set<String>()
    @State private var showingMovePicker = false
    @State private var pendingTrashKeys = Set<String>()
    @State private var showingTrashConfirmation = false
    @State private var resolvingConflict: ZoteroAttachment?
    @State private var pendingRemoteRestore: ZoteroAttachment?
    @State private var remoteRestoreBackupURLs: [URL]?
    @State private var showingRemoteRestoreBackupShare = false

    init(
        cacheStore: ZoteroCacheStore,
        engine: ZoteroSyncEngine,
        syncProgress: ZoteroSyncProgress,
        defaults: DefaultsService,
        onOpenJot: @escaping (JotFile.Info) -> Void
    ) {
        let viewModel = ZoteroLibraryViewModel(cacheStore: cacheStore, engine: engine, defaults: defaults)
        viewModel.onOpenJot = onOpenJot
        _model = StateObject(wrappedValue: viewModel)
        _syncProgress = ObservedObject(wrappedValue: syncProgress)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List {
                locationButton(
                    String(localized: "zotero.sidebar.myLibrary"),
                    symbol: "books.vertical",
                    location: .myLibrary
                )
                ForEach(model.childCollections(of: nil)) { collection in
                    ZoteroCollectionTreeRow(
                        collection: collection,
                        children: { model.childCollections(of: $0) },
                        onSelect: { model.selection = .collection($0) }
                    )
                }
                locationButton(
                    String(localized: "zotero.sidebar.unfiled"),
                    symbol: "tray",
                    location: .unfiled
                )
                locationButton(
                    String(localized: "zotero.sidebar.trash"),
                    symbol: "trash",
                    location: .trash
                )
            }
            .listStyle(.sidebar)
            .contentMargins(.top, 0, for: .scrollContent)
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom, alignment: .leading, spacing: 0) {
                HStack(spacing: 20) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(String(localized: "zotero.sidebar.accountSettings"))

                    if syncProgress.isSyncing {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(syncProgress.syncStatusMessage).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(Int((syncProgress.syncProgress * 100).rounded()))%")
                                    .monospacedDigit()
                            }
                            .font(.caption)
                            ProgressView(value: syncProgress.syncProgress)
                                .tint(.accentColor)
                        }
                        .frame(maxWidth: 260)
                        .accessibilityElement(children: .combine)
                    } else {
                        Button { Task { await model.synchronize() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel(String(localized: "zotero.sidebar.syncLibrary"))
                    }
                }
                .buttonStyle(.plain)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial)
            }
        } detail: {
            attachmentList
                .toolbar(removing: .sidebarToggle)
        }
        .sheet(isPresented: $showingSettings) {
            ZoteroAccountSettingsView(defaults: DefaultsService(userDefaults: .standard)) {
                Task { await model.reloadAccountAndSynchronize() }
            }
        }
        .sheet(isPresented: $showingNewDocument, onDismiss: {
            newNoteParentKey = nil
        }) {
            ZoteroCreateDocumentSheet { title, pageSize in
                let result = await model.createDocument(
                    title: title,
                    pageSize: pageSize,
                    parentItemKey: newNoteParentKey
                )
                if result == String(localized: "zotero.create.offlineDraft") {
                    creationNotice = result
                    return nil
                }
                return result
            }
        }
        .sheet(isPresented: $showingPDFCreation, onDismiss: {
            importedPDFData = nil
            importedPDFName = nil
        }) {
            if let importedPDFData, let importedPDFName {
                ZoteroPDFItemCreationSheet(
                    filename: importedPDFName,
                    loadTypes: { await model.itemTypes() },
                    loadSchema: { await model.itemTypeSchema(for: $0) },
                    onCreate: { schema, metadata, creators in
                        let result = await model.createImportedPDF(
                            data: importedPDFData,
                            filename: importedPDFName,
                            schema: schema,
                            metadata: metadata,
                            creators: creators
                        )
                        if result == String(localized: "zotero.create.offlineDraft") {
                            creationNotice = result
                            return nil
                        }
                        return result
                    }
                )
            }
        }
        .fileImporter(isPresented: $showingPDFImporter, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                do {
                    let data = try ExternalFileImportService().readExternalFile(
                        sourceURL: url,
                        maximumFileSize: 128 * 1_024 * 1_024
                    )
                    guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
                        creationNotice = String(localized: "zotero.import.invalidPDF")
                        return
                    }
                    importedPDFData = data
                    importedPDFName = url.lastPathComponent
                    showingPDFCreation = true
                } catch ExternalFileImportService.Failure.fileTooLarge {
                    creationNotice = String(localized: "zotero.import.pdfTooLarge")
                } catch {
                    creationNotice = error.localizedDescription
                }
            case .failure(let error):
                showImportErrorUnlessCancelled(error)
            }
        }
        .fileImporter(isPresented: $showingAttachmentImporter, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                guard let parentKey = pendingAttachmentParentKey else { return }
                do {
                    let data = try ExternalFileImportService().readExternalFile(
                        sourceURL: url,
                        maximumFileSize: 128 * 1_024 * 1_024
                    )
                    Task {
                        if let message = await model.addPDFAttachment(
                            data: data,
                            filename: url.lastPathComponent,
                            to: parentKey
                        ) {
                            creationNotice = message
                        }
                    }
                } catch ExternalFileImportService.Failure.fileTooLarge {
                    creationNotice = String(localized: "zotero.import.pdfTooLarge")
                } catch {
                    creationNotice = error.localizedDescription
                }
                pendingAttachmentParentKey = nil
            case .failure(let error):
                pendingAttachmentParentKey = nil
                showImportErrorUnlessCancelled(error)
            }
        }
        .sheet(item: $editingItem) { item in
            ZoteroMetadataEditorSheet(item: item) { title, creators, date in
                await model.updateMetadata(itemKey: item.key, title: title, creators: creators, date: date)
            }
        }
        .sheet(isPresented: $showingMovePicker) {
            ZoteroCollectionPickerSheet(collections: Array(model.snapshot.collections.values)) { collectionKey in
                Task { await model.moveItems(movingItemKeys, to: collectionKey) }
            }
        }
        .sheet(item: $resolvingConflict) { conflict in
            ZoteroConflictResolverView(
                attachment: conflict,
                item: model.snapshot.items[conflict.key],
                original: model.originalAttachment(for: conflict),
                onKeepLocal: { await model.keepConflictLocal(conflict.key) },
                onKeepServer: { await model.keepConflictServer(conflict.key) },
                onKeepBoth: { await model.keepConflictBoth(conflict.key) },
                onDeleteConflictCopy: { await model.deleteConflictCopy(conflict.key) }
            )
        }
        .confirmationDialog(
            String(localized: model.selection == .trash
                ? "zotero.document.deletePermanently.confirmTitle"
                : "zotero.document.trash.confirmTitle"),
            isPresented: $showingTrashConfirmation,
            titleVisibility: .visible
        ) {
            if model.selection == .trash {
                Button(String(localized: "zotero.document.deletePermanently"), role: .destructive) {
                    Task { await model.permanentlyDeleteItems(pendingTrashKeys) }
                }
            } else {
                Button(String(localized: "zotero.document.trash"), role: .destructive) {
                    Task { await model.trashItems(pendingTrashKeys) }
                }
            }
            Button(String(localized: "action.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: model.selection == .trash
                ? "zotero.document.deletePermanently.confirmMessage"
                : "zotero.document.trash.confirmMessage"))
        }
        .confirmationDialog(
            String(localized: "zotero.forceRestore.confirm.title", defaultValue: "원격 버전으로 복구하시겠습니까?"),
            isPresented: Binding(
                get: { pendingRemoteRestore != nil },
                set: { if !$0 { pendingRemoteRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let attachment = pendingRemoteRestore {
                Button(String(localized: "zotero.forceRestore.confirm.action", defaultValue: "원격 버전으로 복구"), role: .destructive) {
                    pendingRemoteRestore = nil
                    Task {
                        do {
                            remoteRestoreBackupURLs = try await model.restoreRemoteVersion(attachment)
                            creationNotice = String(localized: "zotero.forceRestore.success", defaultValue: "원격 PDF를 복구했습니다. 백업은 공유하거나 보관할 수 있습니다.")
                        } catch {
                            remoteRestoreBackupURLs = model.remoteRestoreBackupURLs
                            creationNotice = error.localizedDescription
                        }
                    }
                }
                .disabled(model.restoringAttachmentKey != nil || model.isSyncing)
            }
            Button(String(localized: "action.cancel"), role: .cancel) { pendingRemoteRestore = nil }
        } message: {
            Text(String(localized: "zotero.forceRestore.confirm.message", defaultValue: "서버에 저장된 PDF를 다시 다운로드하여 현재 로컬 버전을 대체합니다. 서버에 동기화되지 않은 필기나 수정 내용은 현재 문서에 표시되지 않을 수 있습니다. 복구 가능한 로컬 데이터는 별도 백업으로 보존합니다."))
        }
        .alert("Zotero", isPresented: Binding(
            get: { creationNotice != nil },
            set: { if !$0 { creationNotice = nil } }
        )) {
            if remoteRestoreBackupURLs != nil {
                Button(String(localized: "zotero.forceRestore.shareBackup", defaultValue: "로컬 백업 공유")) {
                    creationNotice = nil
                    showingRemoteRestoreBackupShare = true
                }
            }
            Button(String(localized: "action.ok"), role: .cancel) { creationNotice = nil }
        } message: {
            Text(creationNotice ?? "")
        }
        .sheet(isPresented: $showingRemoteRestoreBackupShare) {
            if let remoteRestoreBackupURLs {
                ZoteroRestoreBackupShareSheet(items: remoteRestoreBackupURLs)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoteroAttachmentCacheChanged)) { _ in
            model.refreshCacheState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            model.refreshCacheState()
            Task { await model.synchronize(trigger: .periodic) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoteroEditorDidEnd)) { _ in
            Task { await model.synchronize(trigger: .editorFinished) }
        }
    }

    private func locationButton(
        _ title: String,
        symbol: String,
        location: ZoteroLibraryLocation
    ) -> some View {
        Button {
            model.selection = location
        } label: {
            Label(title, systemImage: symbol)
                .foregroundStyle(model.selection == location ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func showImportErrorUnlessCancelled(_ error: Error) {
        let cocoaError = error as NSError
        guard cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSUserCancelledError else { return }
        creationNotice = error.localizedDescription
    }

    private var attachmentList: some View {
        let groups = model.attachmentGroups(for: model.selection)
        return List {
            HStack(spacing: 12) {
                Text(title(for: model.selection))
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Button(model.isSelecting
                    ? String(localized: "zotero.document.selection.done")
                    : String(localized: "zotero.document.selection.select")) {
                    model.setSelectionMode(!model.isSelecting)
                }
                .buttonStyle(.borderless)
                Menu {
                    Button {
                        showingNewDocument = true
                    } label: {
                        Label(String(localized: "zotero.create.newDocument"), systemImage: "doc.badge.plus")
                    }
                    Button {
                        showingPDFImporter = true
                    } label: {
                        Label(String(localized: "zotero.import.createItemFromPDF"), systemImage: "doc.viewfinder")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "zotero.create.newDocument"))
                Menu {
                    ForEach(ZoteroAttachmentSortOrder.allCases) { order in
                        Button {
                            model.selectSortOrder(order)
                        } label: {
                            if model.sortOrder == order {
                                let isAscending = order == .title ? !model.isSortReversed : model.isSortReversed
                                Label(order.title, systemImage: isAscending ? "arrow.up" : "arrow.down")
                            } else {
                                Text(order.title)
                            }
                        }
                        .accessibilityIdentifier("zotero.sort.\(order.rawValue)")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "zotero.sort.menu"))
                .accessibilityIdentifier("zotero.sort")
                .accessibilityValue(Text(model.sorting.accessibilityDescription))
                Button {
                    withAnimation {
                        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: columnVisibility == .detailOnly
                    ? "zotero.sidebar.showSidebar"
                    : "zotero.sidebar.hideSidebar"))
            }
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityAddTraits(.isHeader)

            ForEach(groups) { group in
                DisclosureGroup(isExpanded: expandedBinding(for: group.key)) {
                    ForEach(group.attachments) { attachment in
                        attachmentRow(
                            attachment,
                            title: attachment.filename,
                            subtitle: "",
                            selectionKey: attachmentSelectionKey(attachment, groupKey: group.key)
                        )
                    }
                    if !model.isSelecting,
                       model.selection != .trash,
                       let groupItem = model.snapshot.items[group.key],
                       groupItem.parentItemKey == nil,
                       !["attachment", "note", "annotation"].contains(groupItem.itemType),
                       !groupItem.isTrashed {
                        Menu {
                            Button {
                                pendingAttachmentParentKey = group.key
                                expandedAttachmentGroups.insert(group.key)
                                showingAttachmentImporter = true
                            } label: {
                                Label(String(localized: "zotero.import.addPDF"), systemImage: "doc.badge.plus")
                            }
                            Button {
                                newNoteParentKey = group.key
                                expandedAttachmentGroups.insert(group.key)
                                showingNewDocument = true
                            } label: {
                                Label(String(localized: "zotero.import.addNote"), systemImage: "square.and.pencil")
                            }
                        } label: {
                            Label(String(localized: "zotero.import.addAttachment"), systemImage: "plus")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.borderless)
                    }
                } label: {
                        HStack(spacing: 10) {
                            if model.isSelecting { selectionIndicator(for: group.key) }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.title).font(.headline).lineLimit(2)
                                if !group.subtitle.isEmpty {
                                    Text(group.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer()
                            Text("\(group.attachments.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            if model.selection != .trash || model.snapshot.items[group.key]?.isTrashed == true {
                                documentContextMenu(itemKey: group.key)
                            }
                        }
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isSelecting {
                HStack(spacing: 16) {
                    Text(String.localizedStringWithFormat(
                        String(localized: "zotero.document.selection.count"),
                        model.selectedItemKeys.count
                    ))
                    Spacer()
                    Button {
                        movingItemKeys = model.selectedItemKeys
                        showingMovePicker = true
                    } label: {
                        Label(String(localized: "zotero.document.move"), systemImage: "folder")
                    }
                    .disabled(model.selectedItemKeys.isEmpty)
                    if model.selection == .trash {
                        Button {
                            Task { await model.restoreItems(model.selectedItemKeys) }
                        } label: {
                            Label(String(localized: "zotero.document.restore"), systemImage: "arrow.uturn.backward")
                        }
                        .disabled(model.selectedItemKeys.isEmpty)
                        Button(role: .destructive) {
                            pendingTrashKeys = model.selectedItemKeys
                            showingTrashConfirmation = true
                        } label: {
                            Label(String(localized: "zotero.document.deletePermanently"), systemImage: "trash")
                        }
                        .disabled(model.selectedItemKeys.isEmpty)
                    } else {
                        Button(role: .destructive) {
                            pendingTrashKeys = model.selectedItemKeys
                            showingTrashConfirmation = true
                        } label: {
                            Label(String(localized: "zotero.document.trash"), systemImage: "trash")
                        }
                        .disabled(model.selectedItemKeys.isEmpty)
                    }
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView(
                    String(localized: "zotero.empty.title"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(model.errorMessage ?? (model.isSyncing
                        ? String(localized: "zotero.empty.syncing")
                        : String(localized: "zotero.empty.noPDF")))
                )
            }
        }
        .alert(String(localized: "zotero.error.title"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button(String(localized: "zotero.common.ok"), role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func attachmentRow(
        _ attachment: ZoteroAttachment,
        title: String,
        subtitle: String,
        selectionKey: String
    ) -> some View {
        let displayStatus = model.displayStatus(for: attachment)
        return Button {
            if model.isSelecting {
                model.toggleSelection(for: selectionKey)
            } else if attachment.isConflict {
                resolvingConflict = attachment
            } else {
                Task { await model.open(attachment) }
            }
        } label: {
            HStack(spacing: 12) {
                if model.isSelecting { selectionIndicator(for: selectionKey) }
                Image(systemName: statusSymbol(displayStatus))
                    .foregroundStyle(statusColor(displayStatus))
                    .frame(width: 24)
                    .accessibilityLabel(statusDescription(displayStatus))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).lineLimit(2)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if attachment.isConflict {
                    Label(String(localized: "zotero.conflict.badge"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                if model.openingAttachmentKey == attachment.key || model.restoringAttachmentKey == attachment.key {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            documentContextMenu(itemKey: selectionKey)
            if model.shouldOfferRemoteRestore(for: attachment) {
                Button {
                    model.recordRemoteRestoreRequest(for: attachment)
                    pendingRemoteRestore = attachment
                } label: {
                    Label(
                        String(localized: "zotero.forceRestore.menu", defaultValue: "원격 버전으로 복구"),
                        systemImage: "arrow.clockwise.icloud"
                    )
                }
                .disabled(model.restoringAttachmentKey != nil || model.isSyncing)
            }
        }
    }

    private func attachmentSelectionKey(_ attachment: ZoteroAttachment, groupKey: String) -> String {
        if model.selection == .trash,
           model.snapshot.items[attachment.key]?.isTrashed == true {
            return attachment.key
        }
        return groupKey
    }

    @ViewBuilder
    private func selectionIndicator(for key: String) -> some View {
        Image(systemName: model.selectedItemKeys.contains(key) ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(model.selectedItemKeys.contains(key) ? Color.accentColor : Color.secondary)
            .font(.title3)
            .accessibilityLabel(model.selectedItemKeys.contains(key)
                ? String(localized: "zotero.document.selection.selected")
                : String(localized: "zotero.document.selection.notSelected"))
    }

    @ViewBuilder
    private func documentContextMenu(itemKey: String) -> some View {
        if let item = model.snapshot.items[itemKey], ZoteroSyncService.isValidKey(itemKey) {
            if model.selection == .trash || item.isTrashed {
                Button {
                    Task { await model.restoreItems([itemKey]) }
                } label: {
                    Label(String(localized: "zotero.document.restore"), systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive) {
                    pendingTrashKeys = [itemKey]
                    showingTrashConfirmation = true
                } label: {
                    Label(String(localized: "zotero.document.deletePermanently"), systemImage: "trash")
                }
            } else {
                if item.parentItemKey == nil,
                   !["attachment", "note", "annotation"].contains(item.itemType) {
                    Menu {
                        Button {
                            pendingAttachmentParentKey = itemKey
                            expandedAttachmentGroups.insert(itemKey)
                            showingAttachmentImporter = true
                        } label: {
                            Label(String(localized: "zotero.import.addPDF"), systemImage: "doc.badge.plus")
                        }
                        Button {
                            newNoteParentKey = itemKey
                            expandedAttachmentGroups.insert(itemKey)
                            showingNewDocument = true
                        } label: {
                            Label(String(localized: "zotero.import.addNote"), systemImage: "square.and.pencil")
                        }
                    } label: {
                        Label(String(localized: "zotero.import.addAttachment"), systemImage: "plus")
                    }
                }
                Button {
                    editingItem = item
                } label: {
                    Label(String(localized: "zotero.document.editMetadata"), systemImage: "pencil")
                }
                Button {
                    movingItemKeys = [itemKey]
                    showingMovePicker = true
                } label: {
                    Label(String(localized: "zotero.document.move"), systemImage: "folder")
                }
                Button(role: .destructive) {
                    pendingTrashKeys = [itemKey]
                    showingTrashConfirmation = true
                } label: {
                    Label(String(localized: "zotero.document.trash"), systemImage: "trash")
                }
            }
        }
    }

    private func expandedBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { expandedAttachmentGroups.contains(key) },
            set: { expanded in
                if expanded { expandedAttachmentGroups.insert(key) }
                else { expandedAttachmentGroups.remove(key) }
            }
        )
    }

    private func title(for location: ZoteroLibraryLocation) -> String {
        switch location {
        case .myLibrary: String(localized: "zotero.sidebar.myLibrary")
        case .collection(let key): model.snapshot.collections[key]?.name ?? String(localized: "zotero.sidebar.collectionFallback")
        case .unfiled: String(localized: "zotero.sidebar.unfiled")
        case .trash: String(localized: "zotero.sidebar.trash")
        }
    }

    private func statusDescription(_ status: ZoteroAttachmentDisplayStatus) -> String {
        switch status {
        case .cloudOnly: String(localized: "zotero.status.cloudOnly")
        case .downloaded: String(localized: "zotero.status.downloaded")
        case .pendingSync: String(localized: "zotero.status.pendingSync")
        case .missingLocalChanges: String(localized: "zotero.status.missingLocalChanges")
        }
    }

    private func statusSymbol(_ status: ZoteroAttachmentDisplayStatus) -> String {
        switch status {
        case .cloudOnly: "icloud"
        case .downloaded: "arrow.down.circle.fill"
        case .pendingSync: "arrow.triangle.2.circlepath"
        case .missingLocalChanges: "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ status: ZoteroAttachmentDisplayStatus) -> Color {
        switch status {
        case .pendingSync, .missingLocalChanges: .orange
        case .cloudOnly, .downloaded: .secondary
        }
    }
}

private struct ZoteroCollectionTreeRow: View {
    let collection: ZoteroCollection
    let children: (String) -> [ZoteroCollection]
    let onSelect: (String) -> Void

    private var childCollections: [ZoteroCollection] {
        children(collection.key)
    }

    var body: some View {
        if childCollections.isEmpty {
            Button { onSelect(collection.key) } label: {
                Label(collection.name, systemImage: "folder")
            }
            .buttonStyle(.plain)
        } else {
            DisclosureGroup {
                ForEach(childCollections) { child in
                    ZoteroCollectionTreeRow(
                        collection: child,
                        children: children,
                        onSelect: onSelect
                    )
                }
            } label: {
                Button { onSelect(collection.key) } label: {
                    Label(collection.name, systemImage: "folder")
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ZoteroCreateDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var orientation: ZoteroNoteOrientation = .portrait
    @State private var errorMessage: String?
    @State private var isCreating = false
    let onCreate: @MainActor (String, CGSize) async -> String?

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    TextField(String(localized: "zotero.create.titlePlaceholder"), text: $title)
                        .textInputAutocapitalization(.sentences)
                    if !title.isEmpty {
                        Button {
                            title = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "zotero.create.clearTitle"))
                    }
                }
                Picker(String(localized: "zotero.create.orientation"), selection: $orientation) {
                    ForEach(ZoteroNoteOrientation.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(String(localized: "zotero.create.newDocument"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel")) { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            isCreating = true
                            defer { isCreating = false }
                            if let message = await onCreate(title, orientation.pageSize) {
                                errorMessage = message
                            } else {
                                dismiss()
                            }
                        }
                    } label: {
                        if isCreating { ProgressView() }
                        else { Text(String(localized: "zotero.create.create")) }
                    }
                    .disabled(isCreating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct ZoteroPDFItemCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var types: [ZoteroItemTypeDefinition] = []
    @State private var selectedTypeID = ""
    @State private var schema: ZoteroItemTypeSchema?
    @State private var metadata: [String: String]
    @State private var creators: [CreatorDraft] = []
    @State private var isLoading = true
    @State private var isCreating = false
    @State private var didConfirmItemType = false
    @State private var errorMessage: String?

    let filename: String
    let loadTypes: @MainActor () async -> [ZoteroItemTypeDefinition]
    let loadSchema: @MainActor (ZoteroItemTypeDefinition) async -> ZoteroItemTypeSchema?
    let onCreate: @MainActor (ZoteroItemTypeSchema, [String: String], [ZoteroCreator]) async -> String?

    init(
        filename: String,
        loadTypes: @escaping @MainActor () async -> [ZoteroItemTypeDefinition],
        loadSchema: @escaping @MainActor (ZoteroItemTypeDefinition) async -> ZoteroItemTypeSchema?,
        onCreate: @escaping @MainActor (ZoteroItemTypeSchema, [String: String], [ZoteroCreator]) async -> String?
    ) {
        self.filename = filename
        self.loadTypes = loadTypes
        self.loadSchema = loadSchema
        self.onCreate = onCreate
        let title = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        _metadata = State(initialValue: ["title": title])
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    ProgressView(String(localized: "zotero.import.loadingSchema"))
                } else if types.isEmpty {
                    ContentUnavailableView(
                        String(localized: "zotero.import.schemaUnavailable"),
                        systemImage: "wifi.exclamationmark",
                        description: Text(String(localized: "zotero.import.schemaUnavailableDetail"))
                    )
                } else {
                    Section(String(localized: "zotero.import.itemType")) {
                        Picker(String(localized: "zotero.import.itemType"), selection: $selectedTypeID) {
                            Text(String(localized: "zotero.import.selectItemType")).tag("")
                            ForEach(types) { type in
                                Text(type.localized).tag(type.itemType)
                            }
                        }
                        .onChange(of: selectedTypeID) { _, typeID in
                            Task { await selectType(typeID) }
                        }
                    }

                    if didConfirmItemType, let schema {
                        metadataSection(schema: schema)
                        creatorSection(schema: schema)
                    }
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle(String(localized: "zotero.import.createItemFromPDF"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel")) { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if didConfirmItemType {
                            Task { await createItem() }
                        } else {
                            didConfirmItemType = true
                        }
                    } label: {
                        if isCreating || isLoading { ProgressView() }
                        else {
                            Text(String(localized: didConfirmItemType
                                ? "zotero.create.create"
                                : "zotero.import.continue"))
                        }
                    }
                    .disabled(
                        isCreating || isLoading || schema == nil || selectedTypeID.isEmpty
                            || (didConfirmItemType && (titleValue.isEmpty || !creatorsAreValid))
                    )
                }
            }
        }
        .presentationDetents([.large])
        .task { await loadSchemaCatalog() }
    }

    private var titleValue: String {
        metadata["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var creatorsAreValid: Bool {
        guard let schema else { return false }
        return creators.allSatisfy { draft in
            let hasName = !draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return !hasName || schema.creatorTypes.contains(where: { $0.creatorType == draft.creatorType })
        }
    }

    private func metadataSection(schema: ZoteroItemTypeSchema) -> some View {
        let supported = Set(schema.fields.map(\.field))
        let hiddenFields = metadata.keys.filter { !supported.contains($0) }
        return Group {
            Section(String(localized: "zotero.import.metadata")) {
                if supported.contains("title") {
                    TextField(String(localized: "zotero.document.metadata.title"), text: textBinding(for: "title"))
                        .textInputAutocapitalization(.sentences)
                }
                if supported.contains("date") {
                    TextField(String(localized: "zotero.document.metadata.date"), text: textBinding(for: "date"))
                        .keyboardType(.numbersAndPunctuation)
                }
                ForEach(schema.fields.filter { $0.field != "title" && $0.field != "date" }) { field in
                    TextField(field.localized, text: textBinding(for: field.field))
                }
                if !hiddenFields.isEmpty {
                    Text(String(localized: "zotero.import.fieldsNotSavedForType"))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func creatorSection(schema: ZoteroItemTypeSchema) -> some View {
        Section(String(localized: "zotero.import.creators")) {
            ForEach($creators) { $draft in
                VStack(alignment: .leading, spacing: 10) {
                    Picker(String(localized: "zotero.import.creatorRole"), selection: $draft.creatorType) {
                        ForEach(schema.creatorTypes) { type in
                            Text(type.localized).tag(type.creatorType)
                        }
                        if !schema.creatorTypes.contains(where: { $0.creatorType == draft.creatorType }) {
                            Text(String(localized: "zotero.import.unsupportedCreatorRole")).tag(draft.creatorType)
                        }
                    }
                    Toggle(String(localized: "zotero.import.organizationCreator"), isOn: $draft.isOrganization)
                    if draft.isOrganization {
                        TextField(String(localized: "zotero.import.creatorName"), text: $draft.name)
                    } else {
                        TextField(String(localized: "zotero.import.creatorFirstName"), text: $draft.firstName)
                        TextField(String(localized: "zotero.import.creatorLastName"), text: $draft.lastName)
                    }
                    Button(role: .destructive) {
                        creators.removeAll { $0.id == draft.id }
                    } label: {
                        Label(String(localized: "zotero.import.removeCreator"), systemImage: "minus.circle")
                    }
                    .font(.footnote)
                }
                .padding(.vertical, 4)
            }
            if let firstCreatorType = schema.creatorTypes.first?.creatorType {
                Button {
                    creators.append(CreatorDraft(creatorType: firstCreatorType))
                } label: {
                    Label(String(localized: "zotero.import.addCreator"), systemImage: "plus.circle")
                }
            }
            if !creators.isEmpty && !creatorsAreValid {
                Text(String(localized: "zotero.import.invalidCreatorRole"))
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func textBinding(for field: String) -> Binding<String> {
        Binding(
            get: { metadata[field] ?? "" },
            set: { metadata[field] = $0 }
        )
    }

    private func loadSchemaCatalog() async {
        types = await loadTypes()
        isLoading = false
        guard !types.isEmpty else {
            errorMessage = String(localized: "zotero.import.schemaUnavailableDetail")
            return
        }
    }

    private func selectType(_ typeID: String) async {
        guard let type = types.first(where: { $0.itemType == typeID }) else {
            schema = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        guard let loaded = await loadSchema(type) else {
            schema = nil
            errorMessage = String(localized: "zotero.import.schemaUnavailableDetail")
            return
        }
        schema = loaded
        errorMessage = nil
        if creators.isEmpty, let firstCreatorType = loaded.creatorTypes.first?.creatorType {
            creators = [CreatorDraft(creatorType: firstCreatorType, isOrganization: loaded.creatorUsesSingleName)]
        }
    }

    private func createItem() async {
        guard let schema else { return }
        isCreating = true
        defer { isCreating = false }
        let validFields = Set(schema.fields.map(\.field))
        let payload = metadata.filter { validFields.contains($0.key) }
        let creatorValues = creators.map(\.zoteroCreator)
        if let message = await onCreate(schema, payload, creatorValues) {
            errorMessage = message
        } else {
            dismiss()
        }
    }

    private struct CreatorDraft: Identifiable {
        let id = UUID()
        var creatorType: String
        var firstName = ""
        var lastName = ""
        var name = ""
        var isOrganization = false

        init(creatorType: String, isOrganization: Bool = false) {
            self.creatorType = creatorType
            self.isOrganization = isOrganization
        }

        var displayName: String {
            isOrganization ? name : [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        }

        var zoteroCreator: ZoteroCreator {
            ZoteroCreator(
                creatorType: creatorType,
                firstName: isOrganization ? "" : firstName,
                lastName: isOrganization ? "" : lastName,
                name: isOrganization ? name : ""
            )
        }
    }
}

private struct ZoteroMetadataEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var creators: String
    @State private var date: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    let item: ZoteroItem
    let onSave: @MainActor (String, [String], String) async -> Void

    init(item: ZoteroItem, onSave: @escaping @MainActor (String, [String], String) async -> Void) {
        self.item = item
        self.onSave = onSave
        _title = State(initialValue: item.title)
        _creators = State(initialValue: item.creators.joined(separator: ", "))
        _date = State(initialValue: item.year ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(String(localized: "zotero.document.metadata.title"), text: $title)
                TextField(String(localized: "zotero.document.metadata.creators"), text: $creators)
                TextField(String(localized: "zotero.document.metadata.date"), text: $date)
                    .keyboardType(.numbersAndPunctuation)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle(String(localized: "zotero.document.editMetadata"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action.save")) {
                        Task {
                            isSaving = true
                            await onSave(
                                title.trimmingCharacters(in: .whitespacesAndNewlines),
                                creators.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                                date.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ZoteroCollectionPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let collections: [ZoteroCollection]
    let onSelect: (String?) -> Void

    private var orderedCollections: [ZoteroCollection] {
        collections.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect(nil)
                    dismiss()
                } label: {
                    Label(String(localized: "zotero.document.move.unfiled"), systemImage: "tray")
                }
                ForEach(orderedCollections) { collection in
                    Button {
                        onSelect(collection.key)
                        dismiss()
                    } label: {
                        Label(collection.name, systemImage: "folder")
                    }
                }
            }
            .navigationTitle(String(localized: "zotero.document.move"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private extension ZoteroLibraryViewModel {
    func clearError() { errorMessage = nil }
}

private struct ZoteroRestoreBackupShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

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
    @Published private(set) var sorting: ZoteroLibrarySorting
    var sortOrder: ZoteroAttachmentSortOrder { sorting.order }
    var isSortReversed: Bool { sorting.isReversed }
    @Published private(set) var isSelecting = false
    @Published private(set) var selectedItemKeys = Set<String>()
    private var synchronizationRequestedWhileSyncing = false

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
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in await self?.synchronize() }
        }
        networkMonitor.start(queue: networkQueue)
        if !userID.isEmpty, !apiKey.isEmpty { Task { await synchronize() } }
    }

    deinit { networkMonitor.cancel() }

    func synchronize() async {
        guard !userID.isEmpty, !apiKey.isEmpty else { return }
        guard !isSyncing else {
            synchronizationRequestedWhileSyncing = true
            print("[ZoteroSync] Coalesced a synchronization request while a sync is already running.")
            return
        }
        isSyncing = true
        defer {
            isSyncing = false
            if synchronizationRequestedWhileSyncing {
                synchronizationRequestedWhileSyncing = false
                Task { @MainActor [weak self] in await self?.synchronize() }
            }
        }
        let syncGate = ZoteroEditingSessionGate.shared
        guard await syncGate.beginSynchronization() else {
            refreshCacheState()
            return
        }
        do {
            let syncService = makeSyncService()
            let documentSync = ZoteroDocumentSyncService(defaultsService: defaults, cacheStore: cacheStore)
            let synchronizedSnapshot = try await engine.synchronize(
                apiClient: ZoteroAPIClient(apiKey: apiKey, userID: userID),
                userID: userID,
                uploadAttachment: { key in
                    await documentSync.uploadCachedAttachment(key: key, fallbackModificationDate: nil)
                },
                downloadAttachment: { key, context in
                    try await syncService.download(documentID: key, context: context)
                }
            )
            snapshot = synchronizedSnapshot
            if case .collection(let key) = selection, snapshot.collections[key] == nil {
                selection = .myLibrary
            }
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "zotero.error.librarySync")
        }
        await syncGate.endSynchronization()
    }

    func reloadAccountAndSynchronize() async {
        userID = defaults.getValue(.zoteroUserID) ?? ""
        apiKey = keychain.value(for: "zotero_api_key") ?? ""
        snapshot = cacheStore.load(userID: userID)
        await synchronize()
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
        do {
            guard let originalKey = cacheStore.conflictOriginalKey(for: conflictKey, userID: userID) else {
                throw ZoteroCacheStore.Failure.conflictNotFound
            }
            snapshot = try cacheStore.resolveConflictKeepingLocal(key: conflictKey, userID: userID)
            let documentSync = ZoteroDocumentSyncService(defaultsService: defaults, cacheStore: cacheStore)
            if let error = await documentSync.uploadCachedAttachment(
                key: originalKey,
                fallbackModificationDate: nil
            ) {
                errorMessage = error
            }
            refreshCacheState()
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: conflictKey)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func keepConflictServer(_ conflictKey: String) async -> Bool {
        do {
            guard snapshot.attachments[conflictKey] != nil,
                  let originalKey = cacheStore.conflictOriginalKey(for: conflictKey, userID: userID) else {
                throw ZoteroCacheStore.Failure.conflictNotFound
            }
            let serverData = try await makeSyncService().download(documentID: originalKey)
            snapshot = try cacheStore.resolveConflictKeepingServer(
                key: conflictKey, serverData: serverData, userID: userID
            )
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: conflictKey)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func keepConflictBoth(_ conflictKey: String) async -> Bool {
        do {
            guard let conflict = snapshot.attachments[conflictKey],
                  let originalKey = conflict.conflictOriginalKey
                    ?? cacheStore.conflictOriginalKey(for: conflictKey, userID: userID),
                  let item = snapshot.items[conflictKey] else {
                throw ZoteroCacheStore.Failure.conflictNotFound
            }
            let serverData = try await makeSyncService().download(documentID: originalKey)
            let created = try await ZoteroAPIClient(apiKey: apiKey, userID: userID).createNoteDocument(
                title: item.title,
                filename: conflict.filename,
                collectionKeys: item.collectionKeys,
                firstName: "",
                lastName: "",
                fullName: item.creators.first ?? ""
            )
            snapshot = try cacheStore.keepConflictAsNewDocument(
                key: conflictKey,
                serverData: serverData,
                created: created,
                userID: userID
            )
            let documentSync = ZoteroDocumentSyncService(defaultsService: defaults, cacheStore: cacheStore)
            if let error = await documentSync.uploadCachedAttachment(
                key: created.attachmentKey,
                fallbackModificationDate: nil
            ) {
                errorMessage = error
            }
            refreshCacheState()
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: created.attachmentKey)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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
        var failureStage = "localCacheRead"
        do {
            let sourceData: Data
            let loadedFromLocalCache: Bool
            let hasLocalFile = cacheStore.hasUsableLocalFile(for: currentAttachment)
            if currentAttachment.syncStatus == .dirty && !hasLocalFile {
                throw ZoteroCacheStore.Failure.invalidLocalAttachmentFile
            }
            if hasLocalFile, let path = currentAttachment.localCachePath {
                if let localData = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   ZoteroCacheStore.isSupportedAttachmentData(localData) {
                    sourceData = localData
                    loadedFromLocalCache = true
                } else if currentAttachment.syncStatus == .dirty {
                    throw ZoteroCacheStore.Failure.invalidLocalAttachmentFile
                } else {
                    let context = ZoteroDownloadContext(source: .documentOpen)
                    downloadContext = context
                    sourceData = try await makeSyncService().download(documentID: attachment.key, context: context)
                    loadedFromLocalCache = false
                }
            } else {
                let context = ZoteroDownloadContext(source: .documentOpen)
                downloadContext = context
                sourceData = try await makeSyncService().download(documentID: attachment.key, context: context)
                loadedFromLocalCache = false
            }
            sourceDataReady = true

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
            failureStage = "localJotSave"
            try JotFileService(fileService: LocalFileService(fileManager: .default))
                .write(jotFile: JotFile(info: fileInfo, jot: jot))
            if !loadedFromLocalCache {
                failureStage = "localCacheSave"
                try savePDFCache(data: sourceData, key: currentAttachment.key)
                snapshot = try cacheStore.markDownloaded(
                    key: currentAttachment.key,
                    path: pdfCacheURL(for: currentAttachment.key),
                    md5: ZoteroSyncService.md5Hex(sourceData),
                    userID: userID
                )
                if let downloadContext {
                    var details = downloadContext.eventDetails
                    details["stage"] = "localCache"
                    details["attempt"] = downloadContext.attempt
                    details["cacheSaved"] = true
                    details["byteCount"] = sourceData.count
                    JottreDiagnostics.shared.record("zotero.download.cacheSaved", details: details)
                }
            } else if currentAttachment.syncStatus != .dirty,
                      let cachePath = currentAttachment.localCachePath {
                snapshot = try cacheStore.markDownloaded(
                    key: currentAttachment.key,
                    path: URL(fileURLWithPath: cachePath),
                    md5: ZoteroSyncService.md5Hex(sourceData),
                    userID: userID
                )
            }
            if let onOpenJot {
                onOpenJot(fileInfo)
            } else {
                await endEditingSession(sessionID: sessionID, requestSynchronization: true)
            }
        } catch {
            let wasCancelled = (error as? URLError)?.code == .cancelled || error is CancellationError || Task.isCancelled
            if sourceDataReady, let downloadContext, !wasCancelled {
                ZoteroSyncService.recordDownloadFailure(
                    error,
                    context: downloadContext,
                    stageOverride: failureStage
                )
            }
            await endEditingSession(sessionID: sessionID, requestSynchronization: !wasCancelled)
            if !wasCancelled {
                errorMessage = String(localized: "zotero.error.openPDF")
            }
        }
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

    private func savePDFCache(data: Data, key: String) throws {
        let url = pdfCacheURL(for: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
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
        .alert("Zotero", isPresented: Binding(
            get: { creationNotice != nil },
            set: { if !$0 { creationNotice = nil } }
        )) {
            Button(String(localized: "action.ok"), role: .cancel) { creationNotice = nil }
        } message: {
            Text(creationNotice ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoteroAttachmentCacheChanged)) { _ in
            model.refreshCacheState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            model.refreshCacheState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoteroEditorDidEnd)) { _ in
            Task { await model.synchronize() }
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
                if model.openingAttachmentKey == attachment.key { ProgressView() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { documentContextMenu(itemKey: selectionKey) }
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

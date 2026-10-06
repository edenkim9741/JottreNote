import SwiftUI
@preconcurrency import PencilKit
import Network

private enum ZoteroLibraryLocation: Hashable {
    case myLibrary
    case collection(String)
    case unfiled
    case trash
}

private enum ZoteroAttachmentSortOrder: String, CaseIterable, Identifiable {
    case title
    case dateAdded
    case recentlyModified

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: String(localized: "zotero.sort.title")
        case .dateAdded: String(localized: "zotero.sort.dateAdded")
        case .recentlyModified: String(localized: "zotero.sort.recentlyModified")
        }
    }
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

private struct ZoteroAttachmentGroup: Identifiable {
    let key: String
    let title: String
    let subtitle: String
    let attachments: [ZoteroAttachment]
    var id: String { key }
}

@MainActor
private final class ZoteroLibraryViewModel: ObservableObject {
    @Published private(set) var snapshot: ZoteroCacheSnapshot
    @Published var selection: ZoteroLibraryLocation = .myLibrary
    @Published private(set) var isSyncing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var openingAttachmentKey: String?
    @Published private(set) var sortOrder: ZoteroAttachmentSortOrder = .title
    @Published private(set) var isSortReversed = false
    @Published private(set) var isSelecting = false
    @Published private(set) var selectedItemKeys = Set<String>()

    private(set) var userID: String
    private var apiKey: String
    private let cacheStore: ZoteroCacheStore
    private let engine: ZoteroSyncEngine
    private let defaults: DefaultsService
    private let keychain = KeychainCredentialStore()
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "ZoteroLibraryNetworkMonitor")
    var onOpenJot: ((JotFile.Info) -> Void)?

    init(cacheStore: ZoteroCacheStore, engine: ZoteroSyncEngine, defaults: DefaultsService) {
        self.cacheStore = cacheStore
        self.engine = engine
        self.defaults = defaults
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

    func synchronize() async {
        guard !userID.isEmpty, !apiKey.isEmpty, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let syncService = makeSyncService()
            let documentSync = ZoteroDocumentSyncService(defaultsService: defaults, cacheStore: cacheStore)
            let synchronizedSnapshot = try await engine.synchronize(
                apiClient: ZoteroAPIClient(apiKey: apiKey, userID: userID),
                userID: userID,
                uploadAttachment: { key in
                    await documentSync.uploadCachedAttachment(key: key, fallbackModificationDate: nil)
                },
                downloadAttachment: { key in
                    try await syncService.download(documentID: key)
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
        if sortOrder == order {
            isSortReversed.toggle()
        } else {
            sortOrder = order
            isSortReversed = false
        }
    }

    func createDocument(title: String, pageSize: CGSize) async -> String? {
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedTitle.isEmpty else { return String(localized: "zotero.create.titleRequired") }
        do {
            let filename = Self.safePDFFileName(from: resolvedTitle)
            let now = Date()
            let fullName = defaults.getValue(.zoteroDefaultAuthorFullName) ?? ""
            let firstName = defaults.getValue(.zoteroDefaultAuthorFirstName) ?? ""
            let lastName = defaults.getValue(.zoteroDefaultAuthorLastName) ?? ""
            let temporaryParentKey = "temp_\(UUID().uuidString)"
            let temporaryAttachmentKey = "temp_\(UUID().uuidString)"
            let item = ZoteroItem(
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
            let cacheURL = try cacheStore.registerOfflineDraft(
                item: item,
                attachment: attachment,
                hybridPDF: hybridPDF,
                userID: userID
            )
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
            onOpenJot?(fileInfo)
            print("[ZoteroDraft] Created local offline draft at \(cacheURL.path), bytes: \(hybridPDF.count)")

            guard !userID.isEmpty, !apiKey.isEmpty else {
                return String(localized: "zotero.create.offlineDraft")
            }
            await synchronize()
            let pending = cacheStore.load(userID: userID).attachments[temporaryAttachmentKey]?.isPendingSync == true
            return pending ? String(localized: "zotero.create.offlineDraft") : nil
        } catch {
            return "\(String(localized: "zotero.create.failed"))\n\(error.localizedDescription)"
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
        snapshot.attachments.values.filter { attachment in
            let owner = attachment.parentItemKey.flatMap { snapshot.items[$0] }
                ?? snapshot.items[attachment.key]
            guard let owner else { return location == .myLibrary }
            switch location {
            case .myLibrary:
                return !owner.isTrashed
            case .collection(let key):
                return !owner.isTrashed && owner.collectionKeys.contains(key)
            case .unfiled:
                return !owner.isTrashed && owner.collectionKeys.isEmpty && owner.parentItemKey == nil
            case .trash:
                return owner.isTrashed
            }
        }.sorted(by: isOrderedBefore)
    }

    func attachmentGroups(for location: ZoteroLibraryLocation) -> [ZoteroAttachmentGroup] {
        let visibleAttachments = attachments(for: location)
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
        do {
            let sourceData: Data
            let loadedFromLocalCache: Bool
            if let path = attachment.localCachePath,
               FileManager.default.fileExists(atPath: path) {
                sourceData = try Data(contentsOf: URL(fileURLWithPath: path))
                loadedFromLocalCache = true
            } else {
                sourceData = try await makeSyncService().download(documentID: attachment.key)
                loadedFromLocalCache = false
            }

            let fileURL = try localJotURL(for: attachment.key)
            let unpacked = try? HybridPDFManager.load(data: sourceData)
            print("[ZoteroLoad] Unpacking hybrid PDF from local cache... Strokes restored: \(unpacked.flatMap { try? PKDrawing(data: $0.jot.drawing).strokes.count } ?? 0)")
            let sourcePDF = unpacked?.pdfData ?? HybridPDFManager.pdfData(in: sourceData)
            let title = title(for: attachment)
            let jot = Jot(
                drawing: unpacked?.jot.drawing ?? Jot.makeEmpty().drawing,
                width: unpacked?.jot.width ?? Jot.defaultWidth,
                pdfData: sourcePDF,
                extraPages: unpacked?.jot.extraPages ?? 0,
                pdfInsertedPageSlots: unpacked?.jot.pdfInsertedPageSlots ?? [],
                strokePageIndices: unpacked?.jot.strokePageIndices ?? [],
                trashedPages: unpacked?.jot.trashedPages ?? [],
                zoteroItemKey: attachment.key,
                zoteroFileName: attachment.filename
            )
            let fileInfo = JotFile.Info(url: fileURL, name: title, modificationDate: nil)
            try JotFileService(fileService: LocalFileService(fileManager: .default))
                .write(jotFile: JotFile(info: fileInfo, jot: jot))
            if !loadedFromLocalCache {
                try savePDFCache(data: sourceData, key: attachment.key)
                snapshot = try cacheStore.markDownloaded(
                    key: attachment.key,
                    path: pdfCacheURL(for: attachment.key),
                    md5: ZoteroSyncService.md5Hex(sourceData),
                    userID: userID
                )
            } else if attachment.syncStatus != .dirty,
                      let cachePath = attachment.localCachePath {
                snapshot = try cacheStore.markDownloaded(
                    key: attachment.key,
                    path: URL(fileURLWithPath: cachePath),
                    md5: ZoteroSyncService.md5Hex(sourceData),
                    userID: userID
                )
            }
            onOpenJot?(fileInfo)
        } catch {
            errorMessage = String(localized: "zotero.error.openPDF")
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
        .sheet(isPresented: $showingNewDocument) {
            ZoteroCreateDocumentSheet { title, pageSize in
                let result = await model.createDocument(title: title, pageSize: pageSize)
                if result == String(localized: "zotero.create.offlineDraft") {
                    creationNotice = result
                    return nil
                }
                return result
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
                Button { showingNewDocument = true } label: {
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
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "zotero.sort.menu"))
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
                if group.attachments.count == 1, let attachment = group.attachments.first {
                    attachmentRow(
                        attachment,
                        title: model.title(for: attachment),
                        subtitle: model.subtitle(for: attachment),
                        selectionKey: group.key
                    )
                } else {
                    DisclosureGroup(isExpanded: expandedBinding(for: group.key)) {
                        ForEach(group.attachments) { attachment in
                            attachmentRow(attachment, title: attachment.filename, subtitle: "", selectionKey: group.key)
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
                        .contextMenu { documentContextMenu(itemKey: group.key) }
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
        Button {
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
                Image(systemName: statusSymbol(attachment))
                    .foregroundStyle(statusColor(attachment))
                    .frame(width: 24)
                    .accessibilityLabel(statusDescription(attachment))
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

    private func statusDescription(_ attachment: ZoteroAttachment) -> String {
        switch attachment.syncStatus {
        case .cloudOnly: String(localized: "zotero.status.cloudOnly")
        case .downloaded: String(localized: "zotero.status.downloaded")
        case .dirty: String(localized: "zotero.status.pendingSync")
        }
    }

    private func statusSymbol(_ attachment: ZoteroAttachment) -> String {
        switch attachment.syncStatus {
        case .cloudOnly: "icloud"
        case .downloaded: "arrow.down.circle.fill"
        case .dirty: "arrow.triangle.2.circlepath"
        }
    }

    private func statusColor(_ attachment: ZoteroAttachment) -> Color {
        attachment.syncStatus == .dirty ? .orange : .secondary
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

import Foundation

enum ZoteroAttachmentSyncStatus: String, Codable, Sendable {
    case cloudOnly
    case downloaded
    case dirty
}

struct ZoteroCollection: Codable, Sendable, Hashable, Identifiable {
    let key: String
    let name: String
    let parentCollectionKey: String?
    let version: Int
    var isTrashed: Bool
    var id: String { key }

    private enum CodingKeys: String, CodingKey {
        case key, name, parentCollectionKey, version, isTrashed
    }

    init(
        key: String,
        name: String,
        parentCollectionKey: String?,
        version: Int,
        isTrashed: Bool = false
    ) {
        self.key = key
        self.name = name
        self.parentCollectionKey = parentCollectionKey
        self.version = version
        self.isTrashed = isTrashed
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try values.decode(String.self, forKey: .key),
            name: try values.decode(String.self, forKey: .name),
            parentCollectionKey: try values.decodeIfPresent(String.self, forKey: .parentCollectionKey),
            version: try values.decode(Int.self, forKey: .version),
            isTrashed: try values.decodeIfPresent(Bool.self, forKey: .isTrashed) ?? false
        )
    }

    static func activeKeys(in collections: [String: ZoteroCollection]) -> Set<String> {
        func isActive(_ key: String, ancestors: Set<String> = []) -> Bool {
            guard let collection = collections[key], !collection.isTrashed,
                  !ancestors.contains(key) else { return false }
            guard let parentKey = collection.parentCollectionKey else { return true }
            var nextAncestors = ancestors
            nextAncestors.insert(key)
            return isActive(parentKey, ancestors: nextAncestors)
        }
        return Set(collections.keys.filter { isActive($0) })
    }
}

struct ZoteroItem: Codable, Sendable, Hashable, Identifiable {
    let key: String
    let title: String
    let creators: [String]
    let year: String?
    let parentItemKey: String?
    let collectionKeys: [String]
    let itemType: String
    let dateAdded: Date?
    let dateModified: Date?
    let version: Int
    let isTrashed: Bool
    var isPendingSync: Bool
    var syncError: String?
    var isConflict: Bool
    var id: String { key }

    private enum CodingKeys: String, CodingKey {
        case key, title, creators, year, parentItemKey, collectionKeys, itemType
        case dateAdded, dateModified, version, isTrashed, isPendingSync, syncError, isConflict
    }

    init(
        key: String, title: String, creators: [String], year: String?, parentItemKey: String?,
        collectionKeys: [String], itemType: String, dateAdded: Date?, dateModified: Date?,
        version: Int, isTrashed: Bool, isPendingSync: Bool = false, syncError: String? = nil,
        isConflict: Bool = false
    ) {
        self.key = key
        self.title = title
        self.creators = creators
        self.year = year
        self.parentItemKey = parentItemKey
        self.collectionKeys = collectionKeys
        self.itemType = itemType
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.version = version
        self.isTrashed = isTrashed
        self.isPendingSync = isPendingSync
        self.syncError = syncError
        self.isConflict = isConflict
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let title = try values.decode(String.self, forKey: .title)
        self.init(
            key: try values.decode(String.self, forKey: .key),
            title: title,
            creators: try values.decode([String].self, forKey: .creators),
            year: try values.decodeIfPresent(String.self, forKey: .year),
            parentItemKey: try values.decodeIfPresent(String.self, forKey: .parentItemKey),
            collectionKeys: try values.decode([String].self, forKey: .collectionKeys),
            itemType: try values.decode(String.self, forKey: .itemType),
            dateAdded: try values.decodeIfPresent(Date.self, forKey: .dateAdded),
            dateModified: try values.decodeIfPresent(Date.self, forKey: .dateModified),
            version: try values.decode(Int.self, forKey: .version),
            isTrashed: try values.decode(Bool.self, forKey: .isTrashed),
            isPendingSync: try values.decodeIfPresent(Bool.self, forKey: .isPendingSync) ?? false,
            syncError: try values.decodeIfPresent(String.self, forKey: .syncError),
            isConflict: try values.decodeIfPresent(Bool.self, forKey: .isConflict)
                ?? title.hasSuffix("(iPad Conflict Copy)")
        )
    }
}

struct ZoteroAttachment: Codable, Sendable, Hashable, Identifiable {
    var key: String
    var parentItemKey: String?
    let contentType: String
    var filename: String
    var localCachePath: String?
    var syncStatus: ZoteroAttachmentSyncStatus
    var version: Int
    var md5: String?
    var modificationTimeMilliseconds: Int64?
    var remoteMD5: String?
    var remoteMD5IsPDF: Bool
    var isPendingSync: Bool
    var syncError: String?
    var isLocalOnly: Bool
    var isConflict: Bool
    var conflictLocalPath: String?
    var conflictCreatedAt: Date?
    var conflictOriginalKey: String?
    var id: String { key }

    private enum CodingKeys: String, CodingKey {
        case key, parentItemKey, contentType, filename, localCachePath, syncStatus, version
        case md5, modificationTimeMilliseconds, remoteMD5, remoteMD5IsPDF, isPendingSync, syncError, isLocalOnly
        case isConflict, conflictLocalPath, conflictCreatedAt, conflictOriginalKey
    }

    init(
        key: String, parentItemKey: String?, contentType: String, filename: String,
        localCachePath: String?, syncStatus: ZoteroAttachmentSyncStatus, version: Int,
        md5: String?, modificationTimeMilliseconds: Int64?, remoteMD5: String? = nil,
        remoteMD5IsPDF: Bool = false,
        isPendingSync: Bool = false, syncError: String? = nil, isLocalOnly: Bool = false,
        isConflict: Bool = false, conflictLocalPath: String? = nil,
        conflictCreatedAt: Date? = nil, conflictOriginalKey: String? = nil
    ) {
        self.key = key
        self.parentItemKey = parentItemKey
        self.contentType = contentType
        self.filename = filename
        self.localCachePath = localCachePath
        self.syncStatus = syncStatus
        self.version = version
        self.md5 = md5
        self.modificationTimeMilliseconds = modificationTimeMilliseconds
        self.remoteMD5 = remoteMD5
        self.remoteMD5IsPDF = remoteMD5IsPDF
        self.isPendingSync = isPendingSync
        self.syncError = syncError
        self.isLocalOnly = isLocalOnly
        self.isConflict = isConflict
        self.conflictLocalPath = conflictLocalPath
        self.conflictCreatedAt = conflictCreatedAt
        self.conflictOriginalKey = conflictOriginalKey
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let localCachePath = try values.decodeIfPresent(String.self, forKey: .localCachePath)
        let isLocalOnly = try values.decodeIfPresent(Bool.self, forKey: .isLocalOnly) ?? false
        self.init(
            key: try values.decode(String.self, forKey: .key),
            parentItemKey: try values.decodeIfPresent(String.self, forKey: .parentItemKey),
            contentType: try values.decode(String.self, forKey: .contentType),
            filename: try values.decode(String.self, forKey: .filename),
            localCachePath: localCachePath,
            syncStatus: try values.decode(ZoteroAttachmentSyncStatus.self, forKey: .syncStatus),
            version: try values.decode(Int.self, forKey: .version),
            md5: try values.decodeIfPresent(String.self, forKey: .md5),
            modificationTimeMilliseconds: try values.decodeIfPresent(Int64.self, forKey: .modificationTimeMilliseconds),
            remoteMD5: try values.decodeIfPresent(String.self, forKey: .remoteMD5),
            remoteMD5IsPDF: try values.decodeIfPresent(Bool.self, forKey: .remoteMD5IsPDF) ?? false,
            isPendingSync: try values.decodeIfPresent(Bool.self, forKey: .isPendingSync) ?? false,
            syncError: try values.decodeIfPresent(String.self, forKey: .syncError),
            isLocalOnly: isLocalOnly,
            isConflict: try values.decodeIfPresent(Bool.self, forKey: .isConflict) ?? isLocalOnly,
            conflictLocalPath: try values.decodeIfPresent(String.self, forKey: .conflictLocalPath) ?? (isLocalOnly ? localCachePath : nil),
            conflictCreatedAt: try values.decodeIfPresent(Date.self, forKey: .conflictCreatedAt),
            conflictOriginalKey: try values.decodeIfPresent(String.self, forKey: .conflictOriginalKey)
        )
    }
}

struct ZoteroCacheSnapshot: Codable, Sendable {
    var userID: String
    var lastLibraryVersion: Int
    var collections: [String: ZoteroCollection]
    var items: [String: ZoteroItem]
    var attachments: [String: ZoteroAttachment]
    var lastSyncedAt: Date?
    var keyAliases: [String: String]
    var pendingRemoteDownloads: [String]

    static func empty(userID: String) -> ZoteroCacheSnapshot {
        ZoteroCacheSnapshot(
            userID: userID,
            lastLibraryVersion: 0,
            collections: [:],
            items: [:],
            attachments: [:],
            lastSyncedAt: nil,
            keyAliases: [:],
            pendingRemoteDownloads: []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case userID, lastLibraryVersion, collections, items, attachments, lastSyncedAt
        case keyAliases, pendingRemoteDownloads
    }

    init(
        userID: String, lastLibraryVersion: Int, collections: [String: ZoteroCollection],
        items: [String: ZoteroItem], attachments: [String: ZoteroAttachment], lastSyncedAt: Date?,
        keyAliases: [String: String] = [:], pendingRemoteDownloads: [String] = []
    ) {
        self.userID = userID
        self.lastLibraryVersion = lastLibraryVersion
        self.collections = collections
        self.items = items
        self.attachments = attachments
        self.lastSyncedAt = lastSyncedAt
        self.keyAliases = keyAliases
        self.pendingRemoteDownloads = pendingRemoteDownloads
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            userID: try values.decode(String.self, forKey: .userID),
            lastLibraryVersion: try values.decode(Int.self, forKey: .lastLibraryVersion),
            collections: try values.decode([String: ZoteroCollection].self, forKey: .collections),
            items: try values.decode([String: ZoteroItem].self, forKey: .items),
            attachments: try values.decode([String: ZoteroAttachment].self, forKey: .attachments),
            lastSyncedAt: try values.decodeIfPresent(Date.self, forKey: .lastSyncedAt),
            keyAliases: try values.decodeIfPresent([String: String].self, forKey: .keyAliases) ?? [:],
            pendingRemoteDownloads: try values.decodeIfPresent([String].self, forKey: .pendingRemoteDownloads) ?? []
        )
    }
}

struct ZoteroLibraryDelta: Sendable {
    let sinceVersion: Int
    let libraryVersion: Int
    let collections: [ZoteroCollection]
    let items: [ZoteroItem]
    let attachments: [ZoteroAttachment]
    let deletedCollectionKeys: Set<String>
    let deletedItemKeys: Set<String>
}

struct ZoteroCollectionSnapshot: Sendable {
    let collections: [ZoteroCollection]
    let libraryVersion: Int
}

/// A small per-user JSON cache. All writes replace the complete snapshot
/// atomically so the sidebar never sees a partially applied API delta.
final class ZoteroCacheStore: @unchecked Sendable {

    private let rootDirectory: URL
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        rootDirectory = support.appendingPathComponent("ZoteroLibraryCache", isDirectory: true)
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(userID: String) -> ZoteroCacheSnapshot {
        lock.withLock {
            guard let data = try? Data(contentsOf: url(for: userID)),
                  let snapshot = try? decoder.decode(ZoteroCacheSnapshot.self, from: data),
                  snapshot.userID == userID else {
                return .empty(userID: userID)
            }
            return snapshot
        }
    }

    func save(_ snapshot: ZoteroCacheSnapshot) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(snapshot)
            try data.write(to: url(for: snapshot.userID), options: .atomic)
        }
    }

    func apply(_ delta: ZoteroLibraryDelta, userID: String) throws -> ZoteroCacheSnapshot {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            guard snapshot.lastLibraryVersion == delta.sinceVersion else {
                throw Failure.cacheAdvancedDuringSync
            }
            // A zero-version cursor is the initial/full collection snapshot.
            // Prune stale rows before applying the server's authoritative list.
            var removedCollectionKeys = delta.deletedCollectionKeys
            if delta.sinceVersion == 0 {
                let serverCollectionKeys = Set(delta.collections.map(\.key))
                removedCollectionKeys.formUnion(snapshot.collections.keys.filter { !serverCollectionKeys.contains($0) })
                removedCollectionKeys.formUnion(snapshot.items.values.flatMap(\.collectionKeys).filter {
                    !serverCollectionKeys.contains($0)
                })
                snapshot.collections = snapshot.collections.filter { serverCollectionKeys.contains($0.key) }
            }
            for key in removedCollectionKeys { snapshot.collections.removeValue(forKey: key) }
            if !removedCollectionKeys.isEmpty {
                let affectedItems = snapshot.items.values.compactMap { item -> (String, ZoteroItem)? in
                    guard item.collectionKeys.contains(where: removedCollectionKeys.contains) else { return nil }
                    return (item.key, item)
                }
                for (key, item) in affectedItems {
                    snapshot.items[key] = Self.copy(
                        item,
                        collectionKeys: item.collectionKeys.filter { !removedCollectionKeys.contains($0) }
                    )
                }
            }
            let removedAttachments = snapshot.attachments.values.filter { attachment in
                delta.deletedItemKeys.contains(attachment.key)
                    || attachment.parentItemKey.map(delta.deletedItemKeys.contains) == true
            }
            for attachment in removedAttachments where attachment.syncStatus == .dirty && !attachment.isConflict {
                try preserveConflictCopy(attachment, snapshot: &snapshot)
            }
            for key in delta.deletedItemKeys {
                snapshot.items.removeValue(forKey: key)
                snapshot.attachments.removeValue(forKey: key)
            }
            for collection in delta.collections { snapshot.collections[collection.key] = collection }
            for item in delta.items { snapshot.items[item.key] = item }
            for var attachment in delta.attachments {
                if let local = snapshot.attachments[attachment.key] {
                    let serverMD5 = Self.normalizedMD5(attachment.md5)
                    // Older releases stored the hybrid-cache checksum here,
                    // not Zotero's standalone PDF checksum. Treat those
                    // baselines as unknown for one sync, then re-baseline.
                    let lastSyncedMD5 = local.remoteMD5IsPDF
                        ? Self.normalizedMD5(local.remoteMD5)
                        : nil
                    attachment.remoteMD5 = serverMD5 ?? local.remoteMD5
                    attachment.remoteMD5IsPDF = serverMD5 != nil || local.remoteMD5IsPDF
                    // Item versions and timestamps can change for reasons unrelated
                    // to the PDF bytes. They must never create a handwriting conflict.
                    let remoteChanged = serverMD5 != nil && lastSyncedMD5 != nil
                        && serverMD5 != lastSyncedMD5
                    if local.syncStatus == .dirty, !remoteChanged,
                       (serverMD5 == nil || lastSyncedMD5 == nil),
                       ZoteroSyncEngine.timestampSuggestsRemoteChange(
                        serverMilliseconds: attachment.modificationTimeMilliseconds,
                        lastSyncedMilliseconds: local.modificationTimeMilliseconds
                       ) {
                        print("[ZoteroSync] Timestamp differs by more than 15 seconds for \(attachment.key), but MD5 is unavailable; keeping local edits and skipping conflict classification.")
                    }
                    if local.syncStatus == .dirty && remoteChanged && !local.isConflict {
                        try preserveConflictCopy(local, snapshot: &snapshot)
                        attachment.localCachePath = nil
                        attachment.syncStatus = .cloudOnly
                        attachment.md5 = nil
                        snapshot.pendingRemoteDownloads.append(attachment.key)
                    } else {
                        attachment.localCachePath = local.localCachePath
                        attachment.md5 = local.md5
                        if local.syncStatus == .dirty {
                            attachment.syncStatus = .dirty
                            attachment.isPendingSync = local.isPendingSync
                            attachment.syncError = local.syncError
                        } else if local.syncStatus == .downloaded,
                                  local.remoteMD5 == attachment.remoteMD5,
                                  local.filename == attachment.filename {
                            attachment.syncStatus = .downloaded
                        }
                    }
                } else {
                    attachment.remoteMD5 = attachment.md5
                    attachment.remoteMD5IsPDF = Self.normalizedMD5(attachment.md5) != nil
                }
                snapshot.attachments[attachment.key] = attachment
            }
            for key in delta.deletedItemKeys {
                snapshot.attachments = snapshot.attachments.filter { $0.value.parentItemKey != key }
            }
            snapshot.lastLibraryVersion = delta.libraryVersion
            snapshot.lastSyncedAt = Date()
            try saveUnlocked(snapshot)
            return snapshot
        }
    }

    /// Reconciles the local folder tree against Zotero's complete collection
    /// snapshot. The caller must provide a snapshot from the same library
    /// version already applied to this cache.
    @discardableResult
    func reconcileCollections(
        _ serverCollections: [ZoteroCollection],
        libraryVersion: Int,
        userID: String
    ) throws -> ZoteroCacheSnapshot {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            guard snapshot.lastLibraryVersion == libraryVersion else {
                throw Failure.cacheAdvancedDuringSync
            }

            let serverKeys = Set(serverCollections.map(\.key))
            snapshot.collections = Dictionary(uniqueKeysWithValues: serverCollections.map { collection in
                let parentKey = collection.parentCollectionKey.flatMap { serverKeys.contains($0) ? $0 : nil }
                return (collection.key, ZoteroCollection(
                    key: collection.key,
                    name: collection.name,
                    parentCollectionKey: parentKey,
                    version: collection.version,
                    isTrashed: collection.isTrashed
                ))
            })

            let affectedItems = snapshot.items.values.compactMap { item -> (String, ZoteroItem)? in
                let validKeys = item.collectionKeys.filter { serverKeys.contains($0) }
                guard validKeys.count != item.collectionKeys.count else { return nil }
                return (item.key, Self.copy(item, collectionKeys: validKeys))
            }
            for (key, item) in affectedItems { snapshot.items[key] = item }
            snapshot.lastSyncedAt = Date()
            try saveUnlocked(snapshot)
            return snapshot
        }
    }

    /// Deletes a conflict copy entirely from local storage. Conflict copies
    /// are local-only and must never block cleanup on a remote Zotero request.
    @discardableResult
    func forceDeleteConflictCopy(key: String, userID: String) throws -> ZoteroCacheSnapshot {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            guard let attachment = snapshot.attachments[key], attachment.isConflict || attachment.isLocalOnly else {
                throw Failure.conflictNotFound
            }
            let ownedPaths = Set([attachment.conflictLocalPath, attachment.localCachePath].compactMap { $0 })
            for path in ownedPaths where FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            snapshot.attachments.removeValue(forKey: key)
            if attachment.parentItemKey == nil || attachment.parentItemKey == key {
                snapshot.items.removeValue(forKey: key)
            }
            snapshot.pendingRemoteDownloads.removeAll { $0 == key }
            snapshot.keyAliases = snapshot.keyAliases.filter { $0.key != key && $0.value != key }
            let defaultPDFURL = defaultPDFCacheURL(for: key)
            if FileManager.default.fileExists(atPath: defaultPDFURL.path) {
                try FileManager.default.removeItem(at: defaultPDFURL)
            }
            let jotURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ZoteroJots", isDirectory: true)
                .appendingPathComponent("\(key).jot")
            if FileManager.default.fileExists(atPath: jotURL.path) {
                try FileManager.default.removeItem(at: jotURL)
            }
            try saveUnlocked(snapshot)
            return snapshot
        }
    }

    private static func copy(_ item: ZoteroItem, collectionKeys: [String]) -> ZoteroItem {
        ZoteroItem(
            key: item.key, title: item.title, creators: item.creators, year: item.year,
            parentItemKey: item.parentItemKey, collectionKeys: collectionKeys,
            itemType: item.itemType, dateAdded: item.dateAdded, dateModified: item.dateModified,
            version: item.version, isTrashed: item.isTrashed, isPendingSync: item.isPendingSync,
            syncError: item.syncError, isConflict: item.isConflict
        )
    }

    func updateItemMetadata(
        key: String,
        title: String,
        creators: [String],
        date: String,
        userID: String
    ) throws -> ZoteroCacheSnapshot {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            guard let item = snapshot.items[key] else { throw Failure.itemNotFound }
            snapshot.items[key] = ZoteroItem(
                key: item.key,
                title: title,
                creators: creators,
                year: date.count >= 4 ? String(date.prefix(4)) : item.year,
                parentItemKey: item.parentItemKey,
                collectionKeys: item.collectionKeys,
                itemType: item.itemType,
                dateAdded: item.dateAdded,
                dateModified: Date(),
                version: item.version,
                isTrashed: item.isTrashed,
                isPendingSync: item.isPendingSync,
                syncError: nil
            )
            try saveUnlocked(snapshot)
            return snapshot
        }
    }

    func moveItems(
        keys: Set<String>,
        toCollectionKey collectionKey: String?,
        userID: String
    ) throws -> ZoteroCacheSnapshot {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            let collectionKeys = collectionKey.map { [$0] } ?? []
            for key in keys {
                guard let item = snapshot.items[key] else { continue }
                snapshot.items[key] = ZoteroItem(
                    key: item.key,
                    title: item.title,
                    creators: item.creators,
                    year: item.year,
                    parentItemKey: item.parentItemKey,
                    collectionKeys: collectionKeys,
                    itemType: item.itemType,
                    dateAdded: item.dateAdded,
                    dateModified: Date(),
                    version: item.version,
                    isTrashed: item.isTrashed,
                    isPendingSync: item.isPendingSync,
                    syncError: nil
                )
            }
            try saveUnlocked(snapshot)
            return snapshot
        }
    }

    func markItemsTrashed(keys: Set<String>, userID: String) throws -> ZoteroCacheSnapshot {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            for key in keys {
                guard let item = snapshot.items[key] else { continue }
                snapshot.items[key] = ZoteroItem(
                    key: item.key,
                    title: item.title,
                    creators: item.creators,
                    year: item.year,
                    parentItemKey: item.parentItemKey,
                    collectionKeys: item.collectionKeys,
                    itemType: item.itemType,
                    dateAdded: item.dateAdded,
                    dateModified: Date(),
                    version: item.version,
                    isTrashed: true,
                    isPendingSync: item.isPendingSync,
                    syncError: nil,
                    isConflict: item.isConflict
                )
            }
            try saveUnlocked(snapshot)
            return snapshot
        }
    }

    func restoreItems(keys: Set<String>, userID: String) throws -> ZoteroCacheSnapshot {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            for key in keys {
                guard let item = snapshot.items[key] else { continue }
                snapshot.items[key] = ZoteroItem(
                    key: item.key,
                    title: item.title,
                    creators: item.creators,
                    year: item.year,
                    parentItemKey: item.parentItemKey,
                    collectionKeys: item.collectionKeys,
                    itemType: item.itemType,
                    dateAdded: item.dateAdded,
                    dateModified: Date(),
                    version: item.version,
                    isTrashed: false,
                    isPendingSync: item.isPendingSync,
                    syncError: nil,
                    isConflict: item.isConflict
                )
            }
            try saveUnlocked(snapshot)
            return snapshot
        }
    }

    /// Removes all cached rows and files belonging to a permanently deleted
    /// top-level item. Soft trash intentionally never calls this method.
    func permanentlyDeleteItems(keys: Set<String>, userID: String) throws -> ZoteroCacheSnapshot {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            let attachmentKeys = Set(snapshot.attachments.values.compactMap { attachment -> String? in
                if keys.contains(attachment.key) { return attachment.key }
                if let parent = attachment.parentItemKey, keys.contains(parent) { return attachment.key }
                return nil
            })
            for key in attachmentKeys {
                if let attachment = snapshot.attachments.removeValue(forKey: key) {
                    for path in [attachment.localCachePath, attachment.conflictLocalPath].compactMap({ $0 }) {
                        try? FileManager.default.removeItem(atPath: path)
                    }
                }
                snapshot.pendingRemoteDownloads.removeAll { $0 == key }
                snapshot.keyAliases = snapshot.keyAliases.filter { $0.key != key && $0.value != key }
                try? FileManager.default.removeItem(at: defaultPDFCacheURL(for: key))
                let jotURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("ZoteroJots", isDirectory: true)
                    .appendingPathComponent("\(key).jot")
                try? FileManager.default.removeItem(at: jotURL)
            }
            for key in keys {
                snapshot.items.removeValue(forKey: key)
                snapshot.attachments.removeValue(forKey: key)
            }
            try saveUnlocked(snapshot)
            return snapshot
        }
    }

    func markDownloaded(key: String, path: URL, md5: String, userID: String) throws -> ZoteroCacheSnapshot {
        try updateAttachment(key: key, userID: userID) { attachment in
            attachment.localCachePath = path.path
            attachment.syncStatus = .downloaded
            attachment.md5 = md5
        }
    }

    func markDirty(key: String, userID: String) throws -> ZoteroCacheSnapshot {
        let canonicalKey = canonicalAttachmentKey(key, userID: userID)
        return try updateAttachment(key: canonicalKey, userID: userID) { $0.syncStatus = .dirty }
    }

    /// Persists the editor's finished hybrid PDF before any network work starts.
    /// The cache file and dirty metadata are updated under the same store lock.
    @discardableResult
    func saveEditedPDF(key: String, data: Data, userID: String) throws -> URL {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            let canonicalKey = snapshot.keyAliases[key] ?? key
            guard var attachment = snapshot.attachments[canonicalKey] else { throw Failure.attachmentNotFound }
            let fileURL: URL
            if let path = attachment.localCachePath, !path.isEmpty {
                fileURL = URL(fileURLWithPath: path)
            } else {
                fileURL = defaultPDFCacheURL(for: key)
                attachment.localCachePath = fileURL.path
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            attachment.syncStatus = .dirty
            attachment.md5 = ZoteroSyncService.md5Hex(data)
            attachment.modificationTimeMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
            snapshot.attachments[canonicalKey] = attachment
            try saveUnlocked(snapshot)
            return fileURL
        }
    }

    func markSynced(key: String, data: Data, userID: String) throws -> ZoteroCacheSnapshot {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            let canonicalKey = snapshot.keyAliases[key] ?? key
            guard var attachment = snapshot.attachments[canonicalKey] else { throw Failure.attachmentNotFound }
            let uploadedMD5 = ZoteroSyncService.md5Hex(data)
            if let cachedMD5 = attachment.md5, cachedMD5 != uploadedMD5 {
                // A newer editor save reached the cache while this upload was in flight.
                // Keep that local file dirty; never replace it with the older uploaded bytes.
                attachment.syncStatus = .dirty
                snapshot.attachments[canonicalKey] = attachment
                try saveUnlocked(snapshot)
                return snapshot
            }
            if let path = attachment.localCachePath,
               !FileManager.default.fileExists(atPath: path) {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            attachment.md5 = uploadedMD5
            // Zotero's attachment metadata hashes the standards PDF stored in
            // the ZIP, while `md5` tracks the local hybrid cache bytes.
            let standardPDF = HybridPDFManager.pdfData(in: data)
            attachment.remoteMD5 = ZoteroSyncService.md5Hex(standardPDF)
            attachment.remoteMD5IsPDF = true
            attachment.modificationTimeMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
            attachment.syncStatus = .downloaded
            snapshot.attachments[canonicalKey] = attachment
            try saveUnlocked(snapshot)
            return snapshot
        }
    }

    func registerCreatedDocument(
        item: ZoteroItem,
        attachment: ZoteroAttachment,
        hybridPDF: Data,
        libraryVersion: Int,
        userID: String
    ) throws -> URL {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            let fileURL = defaultPDFCacheURL(for: attachment.key)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try hybridPDF.write(to: fileURL, options: .atomic)

            var localAttachment = attachment
            localAttachment.localCachePath = fileURL.path
            localAttachment.syncStatus = .dirty
            localAttachment.isPendingSync = item.isPendingSync || attachment.isPendingSync
            localAttachment.md5 = ZoteroSyncService.md5Hex(hybridPDF)
            localAttachment.modificationTimeMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
            snapshot.items[item.key] = item
            snapshot.items[attachment.key] = ZoteroItem(
                key: attachment.key,
                title: attachment.filename,
                creators: [],
                year: nil,
                parentItemKey: attachment.parentItemKey,
                collectionKeys: [],
                itemType: "attachment",
                dateAdded: item.dateAdded,
                dateModified: item.dateModified,
                version: attachment.version,
                isTrashed: false
            )
            snapshot.attachments[attachment.key] = localAttachment
            snapshot.lastLibraryVersion = max(snapshot.lastLibraryVersion, libraryVersion)
            snapshot.lastSyncedAt = Date()
            try saveUnlocked(snapshot)
            return fileURL
        }
    }

    func registerOfflineDraft(
        item: ZoteroItem,
        attachment: ZoteroAttachment,
        hybridPDF: Data,
        userID: String
    ) throws -> URL {
        guard item.isPendingSync, attachment.isPendingSync else { throw Failure.invalidPendingDraft }
        return try registerCreatedDocument(
            item: item,
            attachment: attachment,
            hybridPDF: hybridPDF,
            libraryVersion: load(userID: userID).lastLibraryVersion,
            userID: userID
        )
    }

    func pendingDrafts(userID: String) -> [(item: ZoteroItem, attachment: ZoteroAttachment)] {
        let snapshot = load(userID: userID)
        return snapshot.attachments.values
            .filter(\.isPendingSync)
            .compactMap { attachment in
                guard let parentKey = attachment.parentItemKey,
                      let item = snapshot.items[parentKey] else { return nil }
                return (item, attachment)
            }
            .sorted { $0.attachment.key < $1.attachment.key }
    }

    func promoteOfflineDraft(
        temporaryParentKey: String,
        temporaryAttachmentKey: String,
        created: CreatedZoteroDocumentKeys,
        version: Int,
        userID: String
    ) throws {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            guard let oldItem = snapshot.items[temporaryParentKey],
                  var oldAttachment = snapshot.attachments[temporaryAttachmentKey],
                  oldItem.isPendingSync, oldAttachment.isPendingSync else {
                throw Failure.pendingDraftNotFound
            }
            let oldPath = oldAttachment.localCachePath.map(URL.init(fileURLWithPath:))
            let newPath = defaultPDFCacheURL(for: created.attachmentKey)
            if let oldPath, FileManager.default.fileExists(atPath: oldPath.path) {
                try FileManager.default.createDirectory(
                    at: newPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: oldPath, to: newPath)
                if let data = try? Data(contentsOf: newPath),
                   let loaded = try? HybridPDFManager.load(data: data) {
                    var remappedJot = loaded.jot
                    remappedJot.zoteroItemKey = created.attachmentKey
                    remappedJot.zoteroFileName = oldAttachment.filename
                    let jotData = try JotHybridPDFBuilder.encodedJotData(remappedJot)
                    let remapped = try HybridPDFManager.embedJotPreservingSourcePDF(
                        pdfData: loaded.pdfData,
                        jotData: jotData
                    )
                    try remapped.write(to: newPath, options: .atomic)
                    oldAttachment.md5 = ZoteroSyncService.md5Hex(remapped)
                }
            }
            snapshot.items.removeValue(forKey: temporaryParentKey)
            snapshot.items.removeValue(forKey: temporaryAttachmentKey)
            snapshot.attachments.removeValue(forKey: temporaryAttachmentKey)
            snapshot.keyAliases[temporaryAttachmentKey] = created.attachmentKey
            let promotedItem = ZoteroItem(
                key: created.parentItemKey,
                title: oldItem.title,
                creators: oldItem.creators,
                year: oldItem.year,
                parentItemKey: nil,
                collectionKeys: oldItem.collectionKeys,
                itemType: oldItem.itemType,
                dateAdded: oldItem.dateAdded,
                dateModified: Date(),
                version: version,
                isTrashed: false
            )
            oldAttachment.key = created.attachmentKey
            oldAttachment.parentItemKey = created.parentItemKey
            oldAttachment.localCachePath = newPath.path
            oldAttachment.version = version
            oldAttachment.isPendingSync = false
            oldAttachment.syncError = nil
            oldAttachment.remoteMD5 = nil
            snapshot.items[created.parentItemKey] = promotedItem
            snapshot.items[created.attachmentKey] = ZoteroItem(
                key: created.attachmentKey,
                title: oldAttachment.filename,
                creators: [],
                year: nil,
                parentItemKey: created.parentItemKey,
                collectionKeys: [],
                itemType: "attachment",
                dateAdded: oldItem.dateAdded,
                dateModified: Date(),
                version: version,
                isTrashed: false
            )
            snapshot.attachments[created.attachmentKey] = oldAttachment
            snapshot.lastLibraryVersion = max(snapshot.lastLibraryVersion, version)
            try saveUnlocked(snapshot)
            if let oldPath, oldPath.path != newPath.path {
                try? FileManager.default.removeItem(at: oldPath)
            }
        }
    }

    func recordPendingSyncError(key: String, message: String, userID: String) throws {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            guard var attachment = snapshot.attachments[key] else { throw Failure.attachmentNotFound }
            attachment.syncError = message
            snapshot.attachments[key] = attachment
            if let parentKey = attachment.parentItemKey, var item = snapshot.items[parentKey] {
                item.syncError = message
                snapshot.items[parentKey] = item
            }
            try saveUnlocked(snapshot)
        }
    }

    func installRemoteVersion(key: String, data: Data, userID: String) throws {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            guard var attachment = snapshot.attachments[key] else { throw Failure.attachmentNotFound }
            guard !attachment.isConflict && !attachment.isLocalOnly else { return }
            let url = defaultPDFCacheURL(for: key)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            attachment.localCachePath = url.path
            attachment.syncStatus = .downloaded
            attachment.md5 = ZoteroSyncService.md5Hex(data)
            attachment.syncError = nil
            snapshot.attachments[key] = attachment
            snapshot.pendingRemoteDownloads.removeAll { $0 == key }
            try saveUnlocked(snapshot)
        }
    }

    func resolveConflictKeepingLocal(key: String, userID: String) throws -> ZoteroCacheSnapshot {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            guard let conflict = snapshot.attachments[key], conflict.isConflict,
                  let originalKey = originalAttachmentKey(for: conflict, snapshot: snapshot),
                  let sourcePath = conflict.conflictLocalPath ?? conflict.localCachePath,
                  FileManager.default.fileExists(atPath: sourcePath),
                  var original = snapshot.attachments[originalKey] else {
                throw Failure.conflictNotFound
            }
            let destination = original.localCachePath.map(URL.init(fileURLWithPath:))
                ?? defaultPDFCacheURL(for: originalKey)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
            try data.write(to: destination, options: .atomic)
            original.localCachePath = destination.path
            original.syncStatus = .dirty
            original.md5 = ZoteroSyncService.md5Hex(data)
            original.modificationTimeMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
            original.syncError = nil
            original.isConflict = false
            snapshot.attachments[originalKey] = original
            removeConflict(key: key, attachment: conflict, snapshot: &snapshot)
            snapshot.pendingRemoteDownloads.removeAll { $0 == originalKey || $0 == key }
            try saveUnlocked(snapshot)
            return snapshot
        }
    }

    func resolveConflictKeepingServer(key: String, serverData: Data, userID: String) throws -> ZoteroCacheSnapshot {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            guard let conflict = snapshot.attachments[key], conflict.isConflict,
                  let originalKey = originalAttachmentKey(for: conflict, snapshot: snapshot),
                  var original = snapshot.attachments[originalKey] else {
                throw Failure.conflictNotFound
            }
            let destination = original.localCachePath.map(URL.init(fileURLWithPath:))
                ?? defaultPDFCacheURL(for: originalKey)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try serverData.write(to: destination, options: .atomic)
            let localMD5 = ZoteroSyncService.md5Hex(serverData)
            let serverMD5 = ZoteroSyncService.md5Hex(HybridPDFManager.pdfData(in: serverData))
            original.localCachePath = destination.path
            original.syncStatus = .downloaded
            original.md5 = localMD5
            original.remoteMD5 = serverMD5
            original.remoteMD5IsPDF = true
            original.syncError = nil
            original.isConflict = false
            snapshot.attachments[originalKey] = original
            removeConflict(key: key, attachment: conflict, snapshot: &snapshot)
            snapshot.pendingRemoteDownloads.removeAll { $0 == originalKey || $0 == key }
            try saveUnlocked(snapshot)
            return snapshot
        }
    }

    func keepConflictAsNewDocument(
        key: String,
        serverData: Data,
        created: CreatedZoteroDocumentKeys,
        userID: String
    ) throws -> ZoteroCacheSnapshot {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            guard let conflict = snapshot.attachments[key], conflict.isConflict,
                  let sourcePath = conflict.conflictLocalPath ?? conflict.localCachePath,
                  FileManager.default.fileExists(atPath: sourcePath),
                  let conflictItem = snapshot.items[key] else {
                throw Failure.conflictNotFound
            }
            let originalKey = originalAttachmentKey(for: conflict, snapshot: snapshot)
            let original = originalKey.flatMap { snapshot.attachments[$0] }
            let data = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
            let localItem = ZoteroItem(
                key: created.parentItemKey,
                title: conflictItem.title,
                creators: conflictItem.creators,
                year: conflictItem.year,
                parentItemKey: nil,
                collectionKeys: conflictItem.collectionKeys,
                itemType: "document",
                dateAdded: Date(),
                dateModified: Date(),
                version: created.libraryVersion,
                isTrashed: false
            )
            let destination = defaultPDFCacheURL(for: created.attachmentKey)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            let localAttachment = ZoteroAttachment(
                key: created.attachmentKey,
                parentItemKey: created.parentItemKey,
                contentType: "application/pdf",
                filename: conflict.filename,
                localCachePath: destination.path,
                syncStatus: .dirty,
                version: created.libraryVersion,
                md5: ZoteroSyncService.md5Hex(data),
                modificationTimeMilliseconds: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
            )
            if let originalKey, var existing = original {
                let originalPath = existing.localCachePath.map(URL.init(fileURLWithPath:))
                    ?? defaultPDFCacheURL(for: originalKey)
                try FileManager.default.createDirectory(
                    at: originalPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try serverData.write(to: originalPath, options: .atomic)
                existing.localCachePath = originalPath.path
                existing.syncStatus = .downloaded
                existing.md5 = ZoteroSyncService.md5Hex(serverData)
                existing.remoteMD5 = ZoteroSyncService.md5Hex(HybridPDFManager.pdfData(in: serverData))
                existing.remoteMD5IsPDF = true
                existing.syncError = nil
                existing.isConflict = false
                snapshot.attachments[originalKey] = existing
            }
            snapshot.items[created.parentItemKey] = localItem
            snapshot.attachments[created.attachmentKey] = localAttachment
            removeConflict(key: key, attachment: conflict, snapshot: &snapshot)
            snapshot.pendingRemoteDownloads.removeAll { $0 == originalKey || $0 == key }
            snapshot.lastLibraryVersion = max(snapshot.lastLibraryVersion, created.libraryVersion)
            try saveUnlocked(snapshot)
            return snapshot
        }
    }

    private func removeConflict(
        key: String,
        attachment: ZoteroAttachment,
        snapshot: inout ZoteroCacheSnapshot
    ) {
        snapshot.attachments.removeValue(forKey: key)
        snapshot.items.removeValue(forKey: key)
        snapshot.pendingRemoteDownloads.removeAll { $0 == key }
        let path = attachment.conflictLocalPath ?? attachment.localCachePath
        if let path, FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    func conflictOriginalKey(for conflictKey: String, userID: String) -> String? {
        let snapshot = load(userID: userID)
        guard let conflict = snapshot.attachments[conflictKey], conflict.isConflict else { return nil }
        return originalAttachmentKey(for: conflict, snapshot: snapshot)
    }

    private func originalAttachmentKey(
        for conflict: ZoteroAttachment,
        snapshot: ZoteroCacheSnapshot
    ) -> String? {
        if let key = conflict.conflictOriginalKey { return key }
        let suffix = " (iPad Conflict Copy)"
        let conflictBase = URL(fileURLWithPath: conflict.filename).deletingPathExtension().lastPathComponent
        let originalBase = conflictBase.hasSuffix(suffix)
            ? String(conflictBase.dropLast(suffix.count))
            : conflictBase
        return snapshot.attachments.values.first(where: { candidate in
            !candidate.isLocalOnly && !candidate.isConflict
                && URL(fileURLWithPath: candidate.filename).deletingPathExtension().lastPathComponent == originalBase
        })?.key
    }

    func canonicalAttachmentKey(_ key: String, userID: String) -> String {
        load(userID: userID).keyAliases[key] ?? key
    }

    private func preserveConflictCopy(
        _ attachment: ZoteroAttachment,
        snapshot: inout ZoteroCacheSnapshot
    ) throws {
        guard let source = attachment.localCachePath,
              FileManager.default.fileExists(atPath: source) else { return }
        let conflictKey = "local_\(UUID().uuidString)"
        let name = URL(fileURLWithPath: attachment.filename)
        let conflictName = "\(name.deletingPathExtension().lastPathComponent) (iPad Conflict Copy).pdf"
        let destination = defaultPDFCacheURL(for: conflictKey)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: destination)
        let originalItem = attachment.parentItemKey.flatMap { snapshot.items[$0] }
        let localItem = ZoteroItem(
            key: conflictKey,
            title: "\(originalItem?.title ?? name.deletingPathExtension().lastPathComponent) (iPad Conflict Copy)",
            creators: originalItem?.creators ?? [],
            year: originalItem?.year,
            parentItemKey: nil,
            collectionKeys: originalItem?.collectionKeys ?? [],
            itemType: "document",
            dateAdded: Date(),
            dateModified: Date(),
            version: 0,
            isTrashed: false,
            isConflict: true
        )
        let localAttachment = ZoteroAttachment(
            key: conflictKey,
            parentItemKey: conflictKey,
            contentType: "application/pdf",
            filename: conflictName,
            localCachePath: destination.path,
            syncStatus: .dirty,
            version: 0,
            md5: attachment.md5,
            modificationTimeMilliseconds: attachment.modificationTimeMilliseconds,
            isLocalOnly: true,
            isConflict: true,
            conflictLocalPath: destination.path,
            conflictCreatedAt: Date(),
            conflictOriginalKey: attachment.key
        )
        snapshot.items[conflictKey] = localItem
        snapshot.attachments[conflictKey] = localAttachment
    }

    /// Removes local PDF copies and returns their attachment records to cloud-only state.
    /// Unsynced edits are rejected so an offload can never discard the only current copy.
    func offload(keys: Set<String>, userID: String) throws -> ZoteroCacheSnapshot {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            let attachments = keys.compactMap { snapshot.attachments[$0] }
            guard !attachments.contains(where: { $0.syncStatus == .dirty }) else {
                throw Failure.dirtyAttachmentCannotBeOffloaded
            }

            var removedPaths = Set<String>()
            for var attachment in attachments {
                if let path = attachment.localCachePath, !path.isEmpty,
                   removedPaths.insert(path).inserted,
                   FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
                attachment.localCachePath = nil
                attachment.syncStatus = .cloudOnly
                snapshot.attachments[attachment.key] = attachment
            }
            try saveUnlocked(snapshot)
            return snapshot
        }
    }

    private func updateAttachment(
        key: String,
        userID: String,
        update: (inout ZoteroAttachment) -> Void
    ) throws -> ZoteroCacheSnapshot {
        try lock.withLock {
            var snapshot = loadUnlocked(userID: userID)
            guard var attachment = snapshot.attachments[key] else { throw Failure.attachmentNotFound }
            update(&attachment)
            snapshot.attachments[key] = attachment
            try saveUnlocked(snapshot)
            return snapshot
        }
    }

    private func loadUnlocked(userID: String) -> ZoteroCacheSnapshot {
        guard let data = try? Data(contentsOf: url(for: userID)),
              let snapshot = try? decoder.decode(ZoteroCacheSnapshot.self, from: data),
              snapshot.userID == userID else { return .empty(userID: userID) }
        return snapshot
    }

    private func saveUnlocked(_ snapshot: ZoteroCacheSnapshot) throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url(for: snapshot.userID), options: .atomic)
    }

    private func url(for userID: String) -> URL {
        let safeID = userID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return rootDirectory.appendingPathComponent(String(String.UnicodeScalarView(safeID)) + ".json")
    }

    private func defaultPDFCacheURL(for key: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZoteroPDFs", isDirectory: true)
            .appendingPathComponent("\(key).pdf")
    }

    private static func normalizedMD5(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    enum Failure: Error {
        case cacheAdvancedDuringSync, attachmentNotFound, dirtyAttachmentCannotBeOffloaded
        case invalidPendingDraft, pendingDraftNotFound, itemNotFound, conflictNotFound
    }
}

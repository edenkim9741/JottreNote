import Foundation

enum ZoteroLibraryLocation: Hashable {
    case myLibrary
    case collection(String)
    case unfiled
    case trash
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
            let owningKey = attachment.parentItemKey ?? attachment.key
            if snapshot.pendingItemActions[owningKey] == .permanentlyDelete
                || snapshot.pendingItemActions[attachment.key] == .permanentlyDelete
            {
                return false
            }
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

    /// Resolve metadata once per attachment rather than in every sort comparison.
    static func sorted(
        _ attachments: [ZoteroAttachment],
        in snapshot: ZoteroCacheSnapshot,
        sorting: ZoteroLibrarySorting
    ) -> [ZoteroAttachment] {
        let entries = attachments.map { attachment in
            let parent = attachment.parentItemKey.flatMap { snapshot.items[$0] }
            let item = snapshot.items[attachment.key]
            let date: Date?
            switch sorting.order {
            case .title: date = nil
            case .dateAdded: date = item?.dateAdded ?? parent?.dateAdded
            case .recentlyModified: date = item?.dateModified ?? parent?.dateModified
            }
            return (attachment: attachment, title: parent?.title ?? attachment.filename, date: date)
        }
        return entries.sorted { lhs, rhs in
            if sorting.order != .title {
                switch (lhs.date, rhs.date) {
                case let (left?, right?) where left != right:
                    return sorting.isReversed ? left < right : left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            let resolved =
                comparison == .orderedSame
                ? lhs.attachment.key.compare(rhs.attachment.key) : comparison
            return resolved == (sorting.isReversed ? .orderedDescending : .orderedAscending)
        }.map(\.attachment)
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

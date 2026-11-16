import Foundation

/// File metadata is collected on cache changes, never during SwiftUI rendering.
struct ZoteroLocalDocumentInventory {
    struct Document: Identifiable {
        let attachment: ZoteroAttachment
        let title: String
        let byteCount: Int64
        var id: String { attachment.id }
        var isOffloadable: Bool { attachment.syncStatus != .dirty }
    }

    let documents: [Document]
    let totalByteCount: Int64
    let offloadableKeys: Set<String>
    var pendingDocumentCount: Int { documents.count - offloadableKeys.count }

    init(snapshot: ZoteroCacheSnapshot, fileManager: FileManager = .default) {
        documents = snapshot.attachments.values.compactMap { attachment in
            guard let path = attachment.localCachePath,
                let attributes = try? fileManager.attributesOfItem(atPath: path),
                attributes[.type] as? FileAttributeType == .typeRegular
            else { return nil }
            return Document(
                attachment: attachment,
                title: attachment.parentItemKey.flatMap { snapshot.items[$0]?.title } ?? attachment.filename,
                byteCount: max(0, (attributes[.size] as? NSNumber)?.int64Value ?? 0)
            )
        }.sorted {
            let comparison = $0.title.localizedCaseInsensitiveCompare($1.title)
            return comparison == .orderedSame ? $0.attachment.key < $1.attachment.key : comparison == .orderedAscending
        }
        totalByteCount = documents.reduce(0) { $0 + $1.byteCount }
        offloadableKeys = Set(documents.filter(\.isOffloadable).map(\.attachment.key))
    }
}

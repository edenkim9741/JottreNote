import Foundation

enum ZoteroAttachmentSortOrder: String, CaseIterable, Identifiable, Codable, Sendable {
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

/// One stored value keeps criterion and direction consistent across launches.
struct ZoteroLibrarySorting: Codable, Equatable, Sendable {
    var order: ZoteroAttachmentSortOrder = .title
    var isReversed = false
    private static let key = DefaultsKey<String>("zotero.library.sorting")

    init(order: ZoteroAttachmentSortOrder = .title, isReversed: Bool = false) {
        self.order = order
        self.isReversed = isReversed
    }

    init(defaults: any DefaultsServiceProtocol) {
        if let value = defaults.getValue(Self.key), let data = value.data(using: .utf8),
            let saved = try? JSONDecoder().decode(Self.self, from: data)
        {
            self = saved
        } else {
            self.init()
        }
    }

    var accessibilityDescription: String {
        let ascending = order == .title ? !isReversed : isReversed
        let direction =
            ascending ? String(localized: "zotero.sort.ascending") : String(localized: "zotero.sort.descending")
        return order.title + ", " + direction
    }

    func selecting(_ order: ZoteroAttachmentSortOrder) -> Self {
        Self(order: order, isReversed: self.order == order ? !isReversed : false)
    }

    func save(to defaults: any DefaultsServiceProtocol) {
        guard let data = try? JSONEncoder().encode(self), let value = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(Self.key, value: value)
    }
}

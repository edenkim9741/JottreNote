import Foundation

struct JotsFolderURL: URLConvertible {

    static let path = "/jots/folder"

    let path: String = Self.path

    var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "folderURL", value: folderURL.absoluteString),
            URLQueryItem(name: "storage", value: storage.rawValue),
        ]
    }

    enum Storage: String, Sendable {
        case local
        case ubiquitous
    }

    let folderURL: URL
    let storage: Storage

    init(folderURL: URL, storage: Storage) {
        self.folderURL = folderURL
        self.storage = storage
    }

    init?(url: URL) {
        guard url.path.hasPrefix(Self.path) else {
            return nil
        }

        guard
            let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let folderURLValue = urlComponents.queryItems?.first(where: { $0.name == "folderURL" })?.value,
            let storageValue = urlComponents.queryItems?.first(where: { $0.name == "storage" })?.value,
            let storage = Storage(rawValue: storageValue),
            let folderURL = URL(string: folderURLValue)
        else {
            return nil
        }

        self.folderURL = folderURL
        self.storage = storage
    }
}

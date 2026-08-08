import Foundation

struct JotsFolderURL: URLConvertible {

    static let path = "/jots/folder"

    let path: String = Self.path

    var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "folderURL", value: folderURL.absoluteString)]
    }

    let folderURL: URL

    init(folderURL: URL) {
        self.folderURL = folderURL
    }

    init?(url: URL) {
        guard url.path.hasPrefix(Self.path) else {
            return nil
        }

        guard
            let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let folderURLValue = urlComponents.queryItems?.first(where: { $0.name == "folderURL" })?.value,
            let folderURL = URL(string: folderURLValue)
        else {
            return nil
        }

        self.folderURL = folderURL
    }
}

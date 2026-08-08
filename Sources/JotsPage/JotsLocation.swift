import Foundation

enum JotsLocation: Hashable, Sendable {
    case root
    case directory(Directory)

    struct Directory: Hashable, Sendable {
        let url: URL
        let name: String

        init(url: URL, name: String) {
            self.url = url
            self.name = name
        }
    }
}

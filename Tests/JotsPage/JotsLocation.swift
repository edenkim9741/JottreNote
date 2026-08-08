import Foundation

enum JotsLocation: Hashable, Sendable {
    case root
    case directory(Directory)

    struct Directory: Hashable, Sendable {
        enum Storage: Hashable, Sendable {
            case local
            case ubiquitous
        }

        let url: URL
        let storage: Storage
        let name: String

        init(url: URL, storage: Storage, name: String) {
            self.url = url
            self.storage = storage
            self.name = name
        }
    }
}

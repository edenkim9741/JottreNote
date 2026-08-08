import Foundation

enum JotsItem: Hashable, Sendable {
    case folder(FolderBusinessModel)
    case jot(JotFile.Info)

    var sortKey: String {
        switch self {
        case let .folder(folder):
            "0_\(folder.name.lowercased())"
        case let .jot(jotFileInfo):
            "1_\(jotFileInfo.name.lowercased())"
        }
    }
}

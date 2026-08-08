import Foundation

struct FolderBusinessModel: Hashable, Sendable {

    let url: URL
    let name: String
    let modificationDate: Date?
    let ubiquitousInfo: UbiquitousInfo?

    init(
        url: URL,
        name: String,
        modificationDate: Date?,
        ubiquitousInfo: UbiquitousInfo?
    ) {
        self.url = url
        self.name = name
        self.modificationDate = modificationDate
        self.ubiquitousInfo = ubiquitousInfo
    }
}

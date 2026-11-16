import XCTest

@testable import Jottre

final class ZoteroLocalDocumentInventoryTests: XCTestCase {
    func testInventoryMeasuresFilesOnceAndProtectsPendingChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cleanURL = root.appendingPathComponent("clean.pdf")
        let dirtyURL = root.appendingPathComponent("dirty.pdf")
        try Data(repeating: 1, count: 12).write(to: cleanURL)
        try Data(repeating: 2, count: 7).write(to: dirtyURL)
        var snapshot = ZoteroCacheSnapshot.empty(userID: "test")
        snapshot.attachments["clean"] = attachment("clean", path: cleanURL.path)
        snapshot.attachments["dirty"] = attachment("dirty", path: dirtyURL.path, dirty: true)
        snapshot.attachments["missing"] = attachment("missing", path: root.appendingPathComponent("missing.pdf").path)
        snapshot.attachments["directory"] = attachment("directory", path: root.path)
        snapshot.attachments["cloud"] = attachment("cloud", path: nil)

        let inventory = ZoteroLocalDocumentInventory(snapshot: snapshot)
        XCTAssertEqual(inventory.documents.map(\.attachment.key), ["clean", "dirty"])
        XCTAssertEqual(inventory.totalByteCount, 19)
        XCTAssertEqual(inventory.offloadableKeys, ["clean"])
        XCTAssertEqual(inventory.pendingDocumentCount, 1)

        // Rendering uses the measured inventory; only an explicit refresh rereads disk.
        try FileManager.default.removeItem(at: cleanURL)
        XCTAssertEqual(inventory.totalByteCount, 19)
        let refreshed = ZoteroLocalDocumentInventory(snapshot: snapshot)
        XCTAssertEqual(refreshed.totalByteCount, 7)
        XCTAssertTrue(refreshed.offloadableKeys.isEmpty)
    }

    func testInventoryUsesParentTitleAndStableKeyOrderForMatchingTitles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1]).write(to: url)
        var snapshot = ZoteroCacheSnapshot.empty(userID: "test")
        snapshot.items["parent"] = ZoteroItem(
            key: "parent",
            title: "Paper",
            creators: [],
            year: nil,
            parentItemKey: nil,
            collectionKeys: [],
            itemType: "journalArticle",
            dateAdded: nil,
            dateModified: nil,
            version: 1,
            isTrashed: false
        )
        for key in ["B", "A"] {
            var entry = attachment(key, path: url.path)
            entry.parentItemKey = "parent"
            snapshot.attachments[key] = entry
        }
        let inventory = ZoteroLocalDocumentInventory(snapshot: snapshot)
        XCTAssertEqual(inventory.documents.map(\.attachment.key), ["A", "B"])
        XCTAssertEqual(inventory.documents.map(\.title), ["Paper", "Paper"])
    }

    private func attachment(_ key: String, path: String?, dirty: Bool = false) -> ZoteroAttachment {
        ZoteroAttachment(
            key: key,
            parentItemKey: nil,
            contentType: "application/pdf",
            filename: key + ".pdf",
            localCachePath: path,
            syncStatus: dirty ? .dirty : .downloaded,
            version: 1,
            md5: nil,
            modificationTimeMilliseconds: nil
        )
    }
}

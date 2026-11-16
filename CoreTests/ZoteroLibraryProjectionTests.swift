import XCTest

@testable import Jottre

final class ZoteroLibraryProjectionTests: XCTestCase {
    func testCollectionVisibilityExcludesCyclesMissingParentsAndTrashedAncestors() {
        let entries: [(String, String?, Bool)] = [
            ("root", nil, false), ("child", "root", false),
            ("trash", nil, true), ("hidden", "trash", false),
            ("orphan", "missing", false), ("a", "b", false),
            ("b", "a", false), ("cycleChild", "a", false), ("self", "self", false),
        ]
        let collections = Dictionary(
            uniqueKeysWithValues: entries.map { key, parent, trashed in
                (
                    key,
                    ZoteroCollection(key: key, name: key, parentCollectionKey: parent, version: 1, isTrashed: trashed)
                )
            }
        )
        XCTAssertEqual(ZoteroCollection.activeKeys(in: collections), ["root", "child"])
    }

    func testDeepCollectionTreeDoesNotRequireRecursiveAncestorTraversal() {
        let collections = Dictionary(
            uniqueKeysWithValues: (0..<10_000).map { index in
                let key = String(index)
                return (
                    key,
                    ZoteroCollection(
                        key: key,
                        name: key,
                        parentCollectionKey: index == 0 ? nil : String(index - 1),
                        version: 1
                    )
                )
            }
        )
        XCTAssertEqual(ZoteroCollection.activeKeys(in: collections).count, 10_000)
    }

    func testDateSortingUsesAttachmentDateThenParentDateAndKeepsMissingDatesLast() {
        var snapshot = ZoteroCacheSnapshot.empty(userID: "test")
        snapshot.items["parent"] = item("parent", date: 20)
        snapshot.items["old"] = item("old", date: 10)
        let attachments = [
            attachment("missing"), attachment("old", parent: "parent"), attachment("inherited", parent: "parent"),
        ]
        for order in [ZoteroAttachmentSortOrder.dateAdded, .recentlyModified] {
            XCTAssertEqual(sortedKeys(attachments, snapshot, .init(order: order)), ["inherited", "old", "missing"])
            XCTAssertEqual(
                sortedKeys(attachments, snapshot, .init(order: order, isReversed: true)),
                ["old", "inherited", "missing"]
            )
        }
    }

    func testTitleTiesHaveStableOrderAndGroupingPreservesSortedAttachmentOrder() {
        var snapshot = ZoteroCacheSnapshot.empty(userID: "test")
        snapshot.items["parent"] = item("parent", date: 20)
        let attachments = [attachment("B", parent: "parent"), attachment("A", parent: "parent")]
        XCTAssertEqual(sortedKeys(attachments, snapshot, .init()), ["A", "B"])
        XCTAssertEqual(sortedKeys(attachments, snapshot, .init(isReversed: true)), ["B", "A"])
        let sorted = ZoteroLibraryAttachmentProjection.sorted(attachments, in: snapshot, sorting: .init())
        let groups = ZoteroLibraryAttachmentProjection.groups(for: sorted, in: snapshot)
        XCTAssertEqual(groups.map(\.key), ["parent"])
        XCTAssertEqual(groups.first?.attachments.map(\.key), ["A", "B"])
    }

    func testProjectionHonorsTrashAndPendingPermanentDeletion() {
        var snapshot = ZoteroCacheSnapshot.empty(userID: "test")
        snapshot.items["parent"] = item("parent", date: 20, trashed: true)
        snapshot.attachments["A"] = attachment("A", parent: "parent")
        XCTAssertTrue(ZoteroLibraryAttachmentProjection.attachments(in: snapshot, location: .myLibrary).isEmpty)
        XCTAssertEqual(ZoteroLibraryAttachmentProjection.attachments(in: snapshot, location: .trash).map(\.key), ["A"])
        snapshot.pendingItemActions["parent"] = .permanentlyDelete
        XCTAssertTrue(ZoteroLibraryAttachmentProjection.attachments(in: snapshot, location: .trash).isEmpty)
    }

    private func sortedKeys(
        _ attachments: [ZoteroAttachment],
        _ snapshot: ZoteroCacheSnapshot,
        _ sorting: ZoteroLibrarySorting
    ) -> [String] {
        ZoteroLibraryAttachmentProjection.sorted(attachments, in: snapshot, sorting: sorting).map(\.key)
    }

    private func attachment(_ key: String, parent: String? = nil) -> ZoteroAttachment {
        ZoteroAttachment(
            key: key,
            parentItemKey: parent,
            contentType: "application/pdf",
            filename: key + ".pdf",
            localCachePath: nil,
            syncStatus: .cloudOnly,
            version: 1,
            md5: nil,
            modificationTimeMilliseconds: nil
        )
    }

    private func item(_ key: String, date: TimeInterval, trashed: Bool = false) -> ZoteroItem {
        ZoteroItem(
            key: key,
            title: "Same title",
            creators: [],
            year: nil,
            parentItemKey: nil,
            collectionKeys: [],
            itemType: "journalArticle",
            dateAdded: Date(timeIntervalSince1970: date),
            dateModified: Date(timeIntervalSince1970: date),
            version: 1,
            isTrashed: trashed
        )
    }
}

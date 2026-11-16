import Foundation
import XCTest

@testable import Jottre

final class ZoteroLibraryFetchTests: XCTestCase {
    private actor ProgressLog {
        var fractions: [Double] = []
        func append(_ fraction: Double) { fractions.append(fraction) }
    }

    private final class Fixture: @unchecked Sendable {
        let token = UUID().uuidString
        let lock = NSLock()
        private var recordedRequests: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { recordedRequests } }
        let itemCount: Int
        let collectionCount: Int
        let unchanged: Bool
        let truncatesObjects: Bool
        let changesVersion: Bool
        let forbidden: Bool

        init(itemCount: Int = 0, collectionCount: Int = 0, unchanged: Bool = false,
             truncatesObjects: Bool = false, changesVersion: Bool = false, forbidden: Bool = false) {
            self.itemCount = itemCount
            self.collectionCount = collectionCount
            self.unchanged = unchanged
            self.truncatesObjects = truncatesObjects
            self.changesVersion = changesVersion
            self.forbidden = forbidden
        }

        func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
            lock.withLock { recordedRequests.append(request) }
            let url = try XCTUnwrap(request.url)
            let query = Dictionary(uniqueKeysWithValues:
                (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            var status = 200
            var headers = ["Last-Modified-Version": "7"]
            let body: Any
            if forbidden {
                status = 403
                body = [:]
            } else if unchanged {
                status = 304
                body = [:]
            } else if url.path.hasSuffix("/deleted") {
                body = ["collections": [], "items": ["DELETED2"]]
            } else if query["format"] == "versions" {
                if url.path.hasSuffix("/items") {
                    body = Dictionary(uniqueKeysWithValues: (0..<itemCount).map { ("I\($0)", 7) })
                } else {
                    body = [String: Int]()
                }
            } else if let keyList = query["itemKey"] {
                let keys = keyList.split(separator: ",").map(String.init)
                let limit = truncatesObjects ? 25 : Int(query["limit"] ?? "25") ?? 25
                body = keys.prefix(limit).map { key in
                    ["key": key, "version": 7, "data": ["itemType": "book", "title": key]] as [String: Any]
                }
                if changesVersion { headers["Last-Modified-Version"] = "8" }
            } else if url.path.hasSuffix("/collections") {
                let start = Int(query["start"] ?? "0") ?? 0
                let limit = Int(query["limit"] ?? "25") ?? 25
                headers["Total-Results"] = String(collectionCount)
                body = (start..<min(start + limit, collectionCount)).map { index in
                    ["key": "C\(index)", "version": 7, "data": ["name": "Collection \(index)"]] as [String: Any]
                }
            } else {
                throw URLError(.badURL)
            }
            return (try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)),
                    try JSONSerialization.data(withJSONObject: body))
        }
    }

    private final class MockProtocol: URLProtocol, @unchecked Sendable {
        private final class Registry: @unchecked Sendable {
            let lock = NSLock()
            var fixtures: [String: Fixture] = [:]
        }
        private static let registry = Registry()

        static func register(_ fixture: Fixture) {
            registry.lock.withLock { registry.fixtures[fixture.token] = fixture }
        }
        static func remove(_ fixture: Fixture) {
            _ = registry.lock.withLock { registry.fixtures.removeValue(forKey: fixture.token) }
        }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let token = request.value(forHTTPHeaderField: "Zotero-API-Key") ?? ""
                let fixture = try XCTUnwrap(Self.registry.lock.withLock { Self.registry.fixtures[token] })
                let (response, data) = try fixture.response(for: request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }

    private func client(for fixture: Fixture) -> (ZoteroAPIClient, URLSession) {
        MockProtocol.register(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: configuration)
        return (ZoteroAPIClient(apiKey: fixture.token, userID: "123", session: session), session)
    }

    func testUnchangedLibraryStopsAfterConditionalVersionCheck() async throws {
        let fixture = Fixture(unchanged: true)
        let (api, session) = client(for: fixture)
        defer { session.invalidateAndCancel(); MockProtocol.remove(fixture) }
        let delta = try await api.fetchDelta(since: 7)
        XCTAssertNil(delta)
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.requests.first?.value(forHTTPHeaderField: "If-Modified-Since-Version"), "7")
    }

    func testLargeLibraryReportsProgressAndDownloadsEveryBatch() async throws {
        let fixture = Fixture(itemCount: 120)
        let (api, session) = client(for: fixture)
        defer { session.invalidateAndCancel(); MockProtocol.remove(fixture) }
        let log = ProgressLog()
        let delta = try await api.fetchDelta(since: 5) { fraction, _ in await log.append(fraction) }
        XCTAssertEqual(delta?.items.count, 120)
        XCTAssertEqual(delta?.deletedItemKeys, ["DELETED2"])
        let progress = await log.fractions
        XCTAssertEqual(progress.last, 1)
        XCTAssertTrue(progress.contains { $0 > 0.4 && $0 < 1 })
        XCTAssertEqual(progress, progress.sorted())
        let batches = fixture.requests.filter { $0.url?.query?.contains("itemKey=") == true }
        XCTAssertEqual(batches.count, 3)
        XCTAssertTrue(batches.allSatisfy { $0.url?.query?.contains("limit=") == true })
        let deletedRequest = try XCTUnwrap(fixture.requests.first { $0.url?.path.hasSuffix("/deleted") == true })
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(deletedRequest.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "since" }?.value, "5")
    }

    func testTruncatedBatchCannotAdvanceLibraryCursor() async throws {
        let fixture = Fixture(itemCount: 50, truncatesObjects: true)
        try await assertSnapshotRejected(fixture)
    }

    func testChangedLibraryVersionDuringObjectDownloadIsRejected() async throws {
        let fixture = Fixture(itemCount: 50, changesVersion: true)
        try await assertSnapshotRejected(fixture)
    }

    private func assertSnapshotRejected(_ fixture: Fixture) async throws {
        let (api, session) = client(for: fixture)
        defer { session.invalidateAndCancel(); MockProtocol.remove(fixture) }
        do {
            _ = try await api.fetchDelta(since: 5)
            XCTFail("An incomplete or mixed snapshot must never be committed")
        } catch ZoteroAPIClient.Failure.libraryChangedDuringSync {
            // The engine can safely retry without advancing the saved cursor.
        }
    }

    func testCollectionPaginationReportsEachPage() async throws {
        let fixture = Fixture(collectionCount: 205)
        let (api, session) = client(for: fixture)
        defer { session.invalidateAndCancel(); MockProtocol.remove(fixture) }
        let log = ProgressLog()
        let snapshot = try await api.fetchAllCollections { completed, total in
            await log.append(Double(completed) / Double(total ?? 1))
        }
        XCTAssertEqual(snapshot.collections.count, 205)
        XCTAssertEqual(fixture.requests.count, 3)
        let progress = await log.fractions
        XCTAssertEqual(progress, [100.0 / 205, 200.0 / 205, 1])
    }

    func testInvalidAccessFailsWithoutRetryingEveryLibraryRequest() async throws {
        let fixture = Fixture(forbidden: true)
        let (api, session) = client(for: fixture)
        defer { session.invalidateAndCancel(); MockProtocol.remove(fixture) }
        do {
            _ = try await api.fetchDelta(since: 7)
            XCTFail("Access errors must finish the sync with an error")
        } catch ZoteroAPIClient.Failure.http(let status) {
            XCTAssertEqual(status, 403)
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }
}

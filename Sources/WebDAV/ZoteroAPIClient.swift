import Foundation

struct ZoteroAPIClient: Sendable {
    let apiKey: String
    let userID: String
    private let session: URLSession

    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    init(apiKey: String, userID: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.userID = userID
        self.session = session ?? Self.defaultSession
    }

    func resolveUserID() async throws -> String {
        let (data, response) = try await performData(for: request(path: "/keys/\(apiKey)"))
        try Self.validate(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userID = object["userID"] as? Int else { throw Failure.invalidResponse }
        return String(userID)
    }

    /// Fetches the complete collection tree using Zotero's offset pagination.
    /// The version header is checked on each page so callers never reconcile
    /// against a mixed snapshot while the library is changing.
    func fetchAllCollections() async throws -> ZoteroCollectionSnapshot {
        guard Int(userID) != nil else { throw Failure.invalidUserID }
        var collections: [ZoteroCollection] = []
        var start = 0
        var totalResults: Int?
        var snapshotVersion: Int?

        while totalResults.map({ start < $0 }) ?? true {
            let query = [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "start", value: String(start)),
            ]
            let (data, response) = try await performData(
                for: request(path: "/users/\(userID)/collections", query: query)
            )
            try Self.validate(response)
            guard let http = response as? HTTPURLResponse,
                  let version = http.value(forHTTPHeaderField: "Last-Modified-Version").flatMap(Int.init),
                  let page = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw Failure.invalidResponse
            }
            if let snapshotVersion, snapshotVersion != version {
                throw Failure.libraryChangedDuringSync
            }
            snapshotVersion = version
            if let total = http.value(forHTTPHeaderField: "Total-Results").flatMap(Int.init) {
                totalResults = total
            }
            collections.append(contentsOf: page.compactMap(Self.collection(from:)))
            start += page.count

            if page.isEmpty || (totalResults == nil && page.count < 100) { break }
        }
        guard let snapshotVersion else { throw Failure.invalidResponse }
        return ZoteroCollectionSnapshot(collections: collections, libraryVersion: snapshotVersion)
    }

    /// Retrieves Zotero's changed object versions, fetches those objects in
    /// batches, and returns a delta that the cache can apply atomically.
    func fetchDelta(since: Int) async throws -> ZoteroLibraryDelta? {
        guard Int(userID) != nil else { throw Failure.invalidUserID }
        let prefix = "/users/\(userID)"
        // Keep the deletion cursor pinned to the version captured by the
        // caller and ask for tombstones before fetching collection objects.
        let deleted = try await fetchDeleted(path: "\(prefix)/deleted", since: since)
        var responseVersions: [Int] = []

        let collectionVersions = try await fetchVersions(
            path: "\(prefix)/collections",
            since: since,
            conditional: true
        )
        if !collectionVersions.notModified {
            responseVersions.append(collectionVersions.libraryVersion)
        }

        let topItemVersions = try await fetchVersions(
            path: "\(prefix)/items/top",
            since: since,
            conditional: false,
            includeTrashed: true
        )
        responseVersions.append(topItemVersions.libraryVersion)
        let childItemVersions = try await fetchVersions(
            path: "\(prefix)/items",
            since: since,
            conditional: false,
            includeTrashed: true
        )
        responseVersions.append(childItemVersions.libraryVersion)
        guard Set(responseVersions).count == 1, let libraryVersion = responseVersions.first else {
            throw Failure.libraryChangedDuringSync
        }

        let collectionObjects = collectionVersions.notModified ? [] : try await fetchObjects(
            path: "\(prefix)/collections",
            keyParameter: "collectionKey",
            versions: collectionVersions.objects
        ) { object in
            Self.collection(from: object)
        }
        let itemVersionMap = topItemVersions.objects.merging(childItemVersions.objects) { _, latest in latest }
        let itemObjects = try await fetchObjects(
            path: "\(prefix)/items",
            keyParameter: "itemKey",
            versions: itemVersionMap,
            extraQuery: [URLQueryItem(name: "includeTrashed", value: "1")]
        ) { object in
            Self.itemAndAttachment(from: object)
        }

        guard deleted.libraryVersion == libraryVersion else { throw Failure.libraryChangedDuringSync }
        return ZoteroLibraryDelta(
            sinceVersion: since,
            libraryVersion: libraryVersion,
            collections: collectionObjects,
            items: itemObjects.compactMap(\.item),
            attachments: itemObjects.compactMap(\.attachment),
            deletedCollectionKeys: Set(deleted.collections),
            deletedItemKeys: Set(deleted.items)
        )
    }

    func updateWebDAVAttachment(key: String, filename: String, md5: String, mtime: Int64) async throws {
        guard ZoteroSyncService.isValidKey(key) else { throw Failure.invalidKey }
        let getRequest = request(path: "/users/\(userID)/items/\(key)?format=json")
        let (itemData, getResponse) = try await performData(for: getRequest)
        try Self.validate(getResponse)
        guard let item = try JSONSerialization.jsonObject(with: itemData) as? [String: Any],
              let version = item["version"] else { throw Failure.invalidResponse }
        var fields = item["data"] as? [String: Any] ?? [:]
        fields["filename"] = filename
        fields["contentType"] = "application/pdf"
        fields["md5"] = md5
        fields["mtime"] = String(mtime)
        fields["version"] = version

        var putRequest = request(path: "/users/\(userID)/items/\(key)")
        putRequest.httpMethod = "PUT"
        putRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        putRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "key": item["key"] as? String ?? key,
            "version": version,
            "data": fields,
        ])
        let (_, putResponse) = try await performData(for: putRequest)
        try Self.validate(putResponse)
    }

    func updateItemMetadata(
        key: String,
        title: String,
        creators: [String],
        date: String
    ) async throws {
        try await modifyItem(key: key) { data in
            data["title"] = title
            data["creators"] = creators.compactMap { value -> [String: String]? in
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return ["creatorType": "author", "name": name]
            }
            data["date"] = date
        }
    }

    func moveItem(key: String, toCollectionKey collectionKey: String?) async throws {
        try await modifyItem(key: key) { data in
            data["collections"] = collectionKey.map { [$0] } ?? []
        }
    }

    /// Moves an item between the library and Zotero's Trash. In Zotero's API,
    /// the editable field is named `deleted`; PATCH preserves every other field.
    func setItemTrashed(key: String, isTrashed: Bool) async throws {
        guard ZoteroSyncService.isValidKey(key) else { throw Failure.invalidKey }
        let getRequest = request(path: "/users/\(userID)/items/\(key)?format=json")
        let (itemData, getResponse) = try await performData(for: getRequest)
        try Self.validate(getResponse)
        guard let item = try JSONSerialization.jsonObject(with: itemData) as? [String: Any],
              let version = item["version"] else { throw Failure.invalidResponse }
        var patchRequest = request(path: "/users/\(userID)/items/\(key)")
        patchRequest.httpMethod = "PATCH"
        patchRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        patchRequest.setValue(String(describing: version), forHTTPHeaderField: "If-Unmodified-Since-Version")
        patchRequest.httpBody = try JSONSerialization.data(withJSONObject: ["deleted": isTrashed])
        let (_, response) = try await performData(for: patchRequest)
        try Self.validate(response)
    }

    /// Permanently removes an item. This must only be called from the Trash UI.
    func permanentlyDeleteItem(key: String) async throws {
        guard ZoteroSyncService.isValidKey(key) else { throw Failure.invalidKey }
        let getRequest = request(path: "/users/\(userID)/items/\(key)?format=json")
        let (itemData, getResponse) = try await performData(for: getRequest)
        if (getResponse as? HTTPURLResponse)?.statusCode == 404 { return }
        try Self.validate(getResponse)
        guard let item = try JSONSerialization.jsonObject(with: itemData) as? [String: Any],
              let version = item["version"] else { throw Failure.invalidResponse }
        var deleteRequest = request(path: "/users/\(userID)/items/\(key)")
        deleteRequest.httpMethod = "DELETE"
        deleteRequest.setValue(String(describing: version), forHTTPHeaderField: "If-Unmodified-Since-Version")
        let (_, response) = try await performData(for: deleteRequest)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return }
        try Self.validate(response)
    }

    private func modifyItem(
        key: String,
        mutation: (inout [String: Any]) -> Void
    ) async throws {
        guard ZoteroSyncService.isValidKey(key) else { throw Failure.invalidKey }
        let getRequest = request(path: "/users/\(userID)/items/\(key)?format=json")
        let (itemData, getResponse) = try await performData(for: getRequest)
        try Self.validate(getResponse)
        guard let item = try JSONSerialization.jsonObject(with: itemData) as? [String: Any],
              let version = item["version"],
              var fields = item["data"] as? [String: Any] else { throw Failure.invalidResponse }
        mutation(&fields)
        fields["version"] = version
        var putRequest = request(path: "/users/\(userID)/items/\(key)")
        putRequest.httpMethod = "PUT"
        putRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        putRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "key": item["key"] as? String ?? key,
            "version": version,
            "data": fields,
        ])
        let (_, response) = try await performData(for: putRequest)
        try Self.validate(response)
    }

    func createNoteDocument(
        title: String,
        filename: String,
        collectionKeys: [String],
        firstName: String,
        lastName: String,
        fullName: String,
        date: Date = Date()
    ) async throws -> CreatedZoteroDocumentKeys {
        guard Int(userID) != nil else { throw Failure.invalidUserID }
        let parentKey = Self.generateItemKey()
        let attachmentKey = Self.generateItemKey()
        let trimmedFullName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFirstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLastName = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        var creators: [[String: String]] = []
        if !trimmedFullName.isEmpty {
            creators = [["creatorType": "author", "name": trimmedFullName]]
        } else if !trimmedFirstName.isEmpty || !trimmedLastName.isEmpty {
            creators = [[
                "creatorType": "author",
                "firstName": trimmedFirstName,
                "lastName": trimmedLastName,
            ]]
        }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let itemPayload: [String: Any] = [
            "key": parentKey,
            "version": 0,
            "itemType": "document",
            "title": title,
            "creators": creators,
            "date": dateFormatter.string(from: date),
            "collections": collectionKeys,
            "tags": [],
            "relations": [:],
        ]
        let attachmentPayload: [String: Any] = [
            "key": attachmentKey,
            "version": 0,
            "itemType": "attachment",
            "parentItem": parentKey,
            "linkMode": "imported_file",
            "title": title,
            "note": "",
            "tags": [],
            "relations": [:],
            "contentType": "application/pdf",
            "charset": "",
            "filename": filename,
            "md5": NSNull(),
            "mtime": NSNull(),
        ]
        let libraryVersion = try await createItems([
            (stage: "parent item", key: parentKey, payload: itemPayload),
            (stage: "PDF attachment", key: attachmentKey, payload: attachmentPayload),
        ])
        return CreatedZoteroDocumentKeys(
            parentItemKey: parentKey,
            attachmentKey: attachmentKey,
            libraryVersion: libraryVersion
        )
    }

    private func createItems(_ items: [(stage: String, key: String, payload: [String: Any])]) async throws -> Int {
        var urlRequest = request(path: "/users/\(userID)/items")
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: items.map(\.payload))
        let (data, response) = try await performData(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.requestFailed(
                stage: "parent item and PDF attachment",
                status: http.statusCode,
                message: Self.serverMessage(from: data)
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidResponse
        }
        let failed = object["failed"] as? [String: Any] ?? [:]
        for (index, item) in items.enumerated() {
            if let failure = failed[String(index)] as? [String: Any] {
                let code = failure["code"] as? Int
                let message = failure["message"] as? String ?? "Zotero rejected the item data."
                throw Failure.itemCreation(stage: item.stage, status: code, message: message)
            }
        }
        let successful = object["successful"] as? [String: Any] ?? [:]
        for (index, item) in items.enumerated() {
            guard let key = Self.createdKey(from: successful[String(index)]),
                  key == item.key,
                  ZoteroSyncService.isValidKey(key) else {
                throw Failure.invalidResponse
            }
        }
        return http.value(forHTTPHeaderField: "Last-Modified-Version").flatMap(Int.init) ?? 0
    }

    private static func createdKey(from value: Any?) -> String? {
        if let key = value as? String { return key }
        if let object = value as? [String: Any] { return object["key"] as? String }
        return nil
    }

    private static func generateItemKey() -> String {
        let alphabet = Array("23456789ABCDEFGHIJKLMNPQRSTUVWXYZ")
        return String((0..<8).compactMap { _ in alphabet.randomElement() })
    }

    private static func serverMessage(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "error", "error_description"] {
                if let message = object[key] as? String, !message.isEmpty { return message }
            }
        }
        let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let body, !body.isEmpty else { return nil }
        return String(body.prefix(500))
    }

    private struct VersionResponse {
        let objects: [String: Int]
        let libraryVersion: Int
        let notModified: Bool
    }

    private struct DeletedResponse {
        let collections: [String]
        let items: [String]
        let libraryVersion: Int
    }

    private struct ParsedObject {
        let item: ZoteroItem?
        let attachment: ZoteroAttachment?
    }

    private func fetchVersions(
        path: String,
        since: Int,
        conditional: Bool,
        includeTrashed: Bool = false
    ) async throws -> VersionResponse {
        var query = [
            URLQueryItem(name: "since", value: String(since)),
            URLQueryItem(name: "format", value: "versions"),
        ]
        if includeTrashed { query.append(URLQueryItem(name: "includeTrashed", value: "1")) }
        var urlRequest = request(path: path, query: query)
        if conditional, since > 0 {
            urlRequest.setValue(String(since), forHTTPHeaderField: "If-Modified-Since-Version")
        }
        let (data, response) = try await performData(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        if http.statusCode == 304 {
            return VersionResponse(objects: [:], libraryVersion: since, notModified: true)
        }
        try Self.validate(response)
        guard let versionHeader = http.value(forHTTPHeaderField: "Last-Modified-Version"),
              let libraryVersion = Int(versionHeader),
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidResponse
        }
        let objects = raw.reduce(into: [String: Int]()) { result, entry in
            if let version = entry.value as? Int { result[entry.key] = version }
        }
        return VersionResponse(objects: objects, libraryVersion: libraryVersion, notModified: false)
    }

    private func fetchObjects<T>(
        path: String,
        keyParameter: String,
        versions: [String: Int],
        extraQuery: [URLQueryItem] = [],
        transform: ([String: Any]) -> T?
    ) async throws -> [T] {
        var output: [T] = []
        let keys = versions.keys.sorted()
        for batch in keys.chunked(maxCount: 50) {
            var query = [URLQueryItem(name: keyParameter, value: batch.joined(separator: ","))]
            query.append(contentsOf: extraQuery)
            let (data, response) = try await performData(for: request(path: path, query: query))
            try Self.validate(response)
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw Failure.invalidResponse
            }
            output.append(contentsOf: array.compactMap(transform))
        }
        return output
    }

    private func fetchDeleted(path: String, since: Int) async throws -> DeletedResponse {
        let query = [URLQueryItem(name: "since", value: String(since))]
        let (data, response) = try await performData(for: request(path: path, query: query))
        try Self.validate(response)
        guard let http = response as? HTTPURLResponse,
              let version = http.value(forHTTPHeaderField: "Last-Modified-Version").flatMap(Int.init),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidResponse
        }
        return DeletedResponse(
            collections: object["collections"] as? [String] ?? [],
            items: object["items"] as? [String] ?? [],
            libraryVersion: version
        )
    }

    private func request(path: String, query: [URLQueryItem]? = nil) -> URLRequest {
        var components = URLComponents(string: "https://api.zotero.org\(path)")!
        components.queryItems = query
        var result = URLRequest(url: components.url!)
        result.timeoutInterval = 60
        result.setValue(apiKey, forHTTPHeaderField: "Zotero-API-Key")
        result.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
        return result
    }

    private func performData(for request: URLRequest) async throws -> (Data, URLResponse) {
        for attempt in 0..<3 {
            do {
                let result = try await session.data(for: request)
                if let response = result.1 as? HTTPURLResponse,
                   Self.isTransientStatus(response.statusCode), attempt < 2 {
                    try await Task.sleep(for: .seconds(attempt + 1))
                    continue
                }
                return result
            } catch {
                guard attempt < 2, Self.isTransientNetworkError(error) else { throw error }
                try await Task.sleep(for: .seconds(attempt + 1))
            }
        }
        throw Failure.invalidResponse
    }

    private static func isTransientStatus(_ status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    private static func isTransientNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut, .cannotConnectToHost, .networkConnectionLost,
            .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed,
            .resourceUnavailable
        ].contains(urlError.code)
    }

    static func collection(from object: [String: Any]) -> ZoteroCollection? {
        guard let key = object["key"] as? String,
              let version = object["version"] as? Int,
              let data = object["data"] as? [String: Any],
              let name = data["name"] as? String else { return nil }
        let parent = data["parentCollection"] as? String
        let meta = object["meta"] as? [String: Any] ?? [:]
        let isTrashed = [data["trashed"], data["deleted"], object["trashed"], object["deleted"],
                         meta["trashed"], meta["deleted"]]
            .contains(where: Self.truthyFlag)
        return ZoteroCollection(
            key: key,
            name: name,
            parentCollectionKey: parent,
            version: version,
            isTrashed: isTrashed
        )
    }

    private static func truthyFlag(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? String {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return false
    }

    private static func itemAndAttachment(from object: [String: Any]) -> ParsedObject? {
        guard let key = object["key"] as? String,
              let version = object["version"] as? Int,
              let data = object["data"] as? [String: Any],
              let itemType = data["itemType"] as? String else { return nil }
        let creators = (data["creators"] as? [[String: Any]] ?? []).compactMap { creator -> String? in
            let first = creator["firstName"] as? String ?? ""
            let last = creator["lastName"] as? String ?? ""
            let name = creator["name"] as? String ?? ""
            let formatted = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
            return formatted.isEmpty ? (name.isEmpty ? nil : name) : formatted
        }
        let dateText = data["dateModified"] as? String
        let dateAddedText = data["dateAdded"] as? String
        let title = (data["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        let item = ZoteroItem(
            key: key,
            title: title,
            creators: creators,
            year: (data["date"] as? String).flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil },
            parentItemKey: data["parentItem"] as? String,
            collectionKeys: data["collections"] as? [String] ?? [],
            itemType: itemType,
            dateAdded: dateAddedText.flatMap(ISO8601DateFormatter().date(from:)),
            dateModified: dateText.flatMap(ISO8601DateFormatter().date(from:)),
            version: version,
            isTrashed: (data["deleted"] as? Bool) ?? false
        )
        let contentType = data["contentType"] as? String
        let attachment: ZoteroAttachment?
        if itemType == "attachment", contentType?.lowercased() == "application/pdf" {
            attachment = ZoteroAttachment(
                key: key,
                parentItemKey: data["parentItem"] as? String,
                contentType: contentType ?? "application/pdf",
                filename: (data["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(key).pdf",
                localCachePath: nil,
                syncStatus: .cloudOnly,
                version: version,
                md5: data["md5"] as? String,
                modificationTimeMilliseconds: (data["mtime"] as? String).flatMap(Int64.init)
            )
        } else {
            attachment = nil
        }
        return ParsedObject(item: item, attachment: attachment)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
    }

    enum Failure: LocalizedError {
        case invalidResponse
        case invalidUserID
        case http(Int)
        case libraryChangedDuringSync
        case invalidKey
        case requestFailed(stage: String, status: Int, message: String?)
        case itemCreation(stage: String, status: Int?, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Zotero returned an unreadable response."
            case .invalidUserID:
                return "The Zotero User ID must contain only digits."
            case let .http(status):
                return "Zotero API request failed (HTTP \(status))."
            case .libraryChangedDuringSync:
                return "The Zotero library changed while it was syncing."
            case .invalidKey:
                return "The Zotero item key is invalid."
            case let .requestFailed(stage, status, message):
                return "Zotero \(stage) creation failed (HTTP \(status))\(message.map { ": \($0)" } ?? ".")"
            case let .itemCreation(stage, status, message):
                let statusText = status.map { " (HTTP \($0))" } ?? ""
                return "Zotero rejected the \(stage) data\(statusText): \(message)"
            }
        }
    }
}

struct CreatedZoteroDocumentKeys: Sendable, Hashable {
    let parentItemKey: String
    let attachmentKey: String
    let libraryVersion: Int
}

private extension Array {
    func chunked(maxCount: Int) -> [[Element]] {
        guard maxCount > 0 else { return [self] }
        return stride(from: 0, to: count, by: maxCount).map {
            Array(self[$0..<Swift.min($0 + maxCount, count)])
        }
    }
}

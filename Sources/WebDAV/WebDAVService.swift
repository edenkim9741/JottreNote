import Foundation

/// Zotero WebDAV transport. Library discovery comes from Zotero's Web API;
/// this service only transfers attachment archives and their .prop metadata.
struct WebDAVService: Sendable {
    enum Failure: Error {
        case badURL
        case unexpectedResponse(Int)
    }

    let baseURL: URL
    let username: String
    let password: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    func upload(
        data: Data,
        remotePath: String,
        metadata: ZoteroUploadMetadata = ZoteroUploadMetadata()
    ) async throws -> Int {
        let url = baseURL.appendingPathComponent(remotePath)
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let md5 = metadata.md5, let digest = Data(hex: md5)?.base64EncodedString() {
            request.setValue(digest, forHTTPHeaderField: "Content-MD5")
        }
        if let mtime = metadata.modificationTimeMilliseconds {
            request.setValue(String(mtime), forHTTPHeaderField: "X-Zotero-Mtime")
        }
        addAuthHeader(to: &request)
        let (_, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badURL }
        guard [200, 201, 204].contains(http.statusCode) else { throw Failure.unexpectedResponse(http.statusCode) }
        return http.statusCode
    }

    func download(remotePath: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(remotePath))
        request.timeoutInterval = 60
        request.httpMethod = "GET"
        addAuthHeader(to: &request)
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badURL }
        guard (200...299).contains(http.statusCode) else { throw Failure.unexpectedResponse(http.statusCode) }
        return data
    }

    /// Deletes a remote attachment or its .prop file. A missing file is
    /// treated as already cleaned up, which makes retries safe.
    func delete(remotePath: String) async throws -> Int {
        var request = URLRequest(url: baseURL.appendingPathComponent(remotePath))
        request.timeoutInterval = 60
        request.httpMethod = "DELETE"
        addAuthHeader(to: &request)
        let (_, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badURL }
        guard [200, 202, 204, 404].contains(http.statusCode) else {
            throw Failure.unexpectedResponse(http.statusCode)
        }
        return http.statusCode
    }

    private func addAuthHeader(to request: inout URLRequest) {
        let credentials = "\(username):\(password)"
        if let encoded = credentials.data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        for attempt in 0..<3 {
            do {
                let result = try await Self.session.data(for: request)
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
        throw Failure.badURL
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
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        data.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

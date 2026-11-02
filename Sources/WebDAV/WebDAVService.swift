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
    private let session: URLSession

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    init(baseURL: URL, username: String, password: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.session = session ?? Self.session
    }

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

    func download(remotePath: String, diagnosticContext: ZoteroDownloadContext? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(remotePath))
        request.timeoutInterval = 60
        request.httpMethod = "GET"
        addAuthHeader(to: &request)
        let (data, response) = try await send(request, diagnosticContext: diagnosticContext)
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

    private func send(
        _ request: URLRequest,
        diagnosticContext: ZoteroDownloadContext? = nil
    ) async throws -> (Data, URLResponse) {
        for attempt in 0..<3 {
            diagnosticContext?.setAttempt(attempt + 1)
            do {
                let result = try await session.data(for: request)
                if let response = result.1 as? HTTPURLResponse {
                    Self.recordHTTPResponse(response.statusCode, context: diagnosticContext, attempt: attempt + 1)
                    if Self.isTransientStatus(response.statusCode), attempt < 2 {
                        let delay = Self.retryAfter(response) ?? TimeInterval(1 << attempt)
                        Self.recordRetry(context: diagnosticContext, attempt: attempt + 1, delay: delay, reason: "http_\(response.statusCode)")
                        try await Task.sleep(for: .seconds(delay))
                        continue
                    }
                }
                return result
            } catch {
                guard attempt < 2, Self.isTransientNetworkError(error), !Task.isCancelled else { throw error }
                let delay = TimeInterval(1 << attempt)
                Self.recordRetry(context: diagnosticContext, attempt: attempt + 1, delay: delay, reason: "urlSession_\((error as? URLError)?.code.rawValue ?? 0)")
                try await Task.sleep(for: .seconds(delay))
            }
        }
        throw Failure.badURL
    }

    private static func recordHTTPResponse(_ status: Int, context: ZoteroDownloadContext?, attempt: Int) {
        guard let context else { return }
        var details = context.eventDetails
        details["stage"] = "webDAVHTTP"
        details["attempt"] = attempt
        details["httpStatus"] = status
        JottreDiagnostics.shared.record("zotero.download.httpResponse", details: details)
    }

    private static func recordRetry(context: ZoteroDownloadContext?, attempt: Int, delay: TimeInterval, reason: String) {
        guard let context else { return }
        var details = context.eventDetails
        details["stage"] = "webDAVRequest"
        details["attempt"] = attempt
        details["nextAttempt"] = attempt + 1
        details["delaySeconds"] = delay
        details["failureReason"] = reason
        JottreDiagnostics.shared.record("zotero.download.retryScheduled", details: details)
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 { return min(seconds, 60) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return min(max(0, date.timeIntervalSinceNow), 60)
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

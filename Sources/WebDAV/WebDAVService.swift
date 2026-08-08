import Foundation

struct WebDAVService: Sendable {

    enum Failure: Error {
        case badURL
        case unexpectedResponse(Int)
    }

    let baseURL: URL
    let username: String
    let password: String

    func makeDirectory(remotePath: String) async throws {
        let remoteURL = baseURL.appendingPathComponent(remotePath)
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "MKCOL"
        addAuthHeader(to: &request)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return }
        // 201 Created or 405 Method Not Allowed (already exists) are both acceptable
        let status = httpResponse.statusCode
        guard (200...299).contains(status) || status == 405 else {
            throw Failure.unexpectedResponse(status)
        }
    }

    func upload(data: Data, remotePath: String) async throws {
        let remoteURL = baseURL.appendingPathComponent(remotePath)
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        addAuthHeader(to: &request)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw Failure.unexpectedResponse(httpResponse.statusCode)
        }
    }

    func move(fromPath: String, toPath: String) async throws {
        let fromURL = baseURL.appendingPathComponent(fromPath)
        let toURL = baseURL.appendingPathComponent(toPath)
        var request = URLRequest(url: fromURL)
        request.httpMethod = "MOVE"
        request.setValue(toURL.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("T", forHTTPHeaderField: "Overwrite")
        addAuthHeader(to: &request)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 404 else {
            throw Failure.unexpectedResponse(httpResponse.statusCode)
        }
    }

    /// Returns the `Last-Modified` date of the remote resource, or `nil` if it does not exist (404).
    func lastModified(remotePath: String) async -> Date? {
        var request = URLRequest(url: baseURL.appendingPathComponent(remotePath))
        request.httpMethod = "HEAD"
        addAuthHeader(to: &request)

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return httpResponse.value(forHTTPHeaderField: "Last-Modified").flatMap { formatter.date(from: $0) }
    }

    private func addAuthHeader(to request: inout URLRequest) {
        let credentials = "\(username):\(password)"
        if let encoded = credentials.data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }
    }
}

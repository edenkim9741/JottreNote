import Foundation

/// Serializes read/modify/write transactions across repository instances.
/// Independent resources can proceed concurrently; idle locks are discarded.
final class FileAccessCoordinator: @unchecked Sendable {
    static let shared = FileAccessCoordinator()
    private final class Entry {
        let lock = NSRecursiveLock()
        var users = 0
    }
    private let registryLock = NSLock()
    private var entries: [String: Entry] = [:]

    func withAccess<T>(to urls: [URL], _ operation: () throws -> T) rethrows -> T {
        let ordered = Array(Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }))
            .sorted { $0.path < $1.path }
        func acquire(_ index: Int) throws -> T {
            guard index < ordered.count else { return try operation() }
            return try withAccess(to: ordered[index]) { try acquire(index + 1) }
        }
        return try acquire(0)
    }

    func withAccess<T>(to url: URL, _ operation: () throws -> T) rethrows -> T {
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        let entry = registryLock.withLock {
            let entry = entries[key] ?? Entry()
            entry.users += 1
            entries[key] = entry
            return entry
        }
        entry.lock.lock()
        defer {
            entry.lock.unlock()
            registryLock.withLock {
                entry.users -= 1
                if entry.users == 0 { entries.removeValue(forKey: key) }
            }
        }
        return try operation()
    }
}

/// Holds a logical resource across suspension points (ZIP, prop and API writes
/// form one transaction). Cancellation and errors always release the next waiter.
actor AsyncResourceAccessCoordinator {
    static let shared = AsyncResourceAccessCoordinator()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withAccess<T: Sendable>(
        to key: String,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        if waiters[key] == nil {
            waiters[key] = []
        } else {
            await withCheckedContinuation { waiters[key, default: []].append($0) }
        }
        defer {
            if var queue = waiters[key], !queue.isEmpty {
                let next = queue.removeFirst()
                waiters[key] = queue
                next.resume()
            } else {
                waiters.removeValue(forKey: key)
            }
        }
        try Task.checkCancellation()
        return try await operation()
    }
}

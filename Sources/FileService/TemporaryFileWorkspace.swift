import Foundation

/// Only operation directories owned by Jottre are pruned. Real user documents
/// and local conflict copies are never candidates for temporary-file cleanup.
enum TemporaryFileWorkspace {
    private final class ActiveOperations: @unchecked Sendable {
        let lock = NSLock()
        var paths: Set<String> = []
    }
    private static let active = ActiveOperations()
    static func withDirectory<T>(
        in root: URL,
        now: Date = Date(),
        operation: (URL) throws -> T
    ) throws -> T {
        let manager = FileManager.default
        let directory = try FileAccessCoordinator.shared.withAccess(to: root) {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let children = try manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
            )
            for child in children where child.lastPathComponent.hasPrefix("operation_") {
                guard !active.lock.withLock({ active.paths.contains(child.path) }) else { continue }
                let suffix = String(child.lastPathComponent.dropFirst("operation_".count))
                guard UUID(uuidString: suffix) != nil,
                    let attributes = try? child.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                    attributes.isDirectory == true,
                    let modified = attributes.contentModificationDate,
                    now.timeIntervalSince(modified) > 86_400
                else { continue }
                // Workspaces are short-lived synchronous utility operations.
                try? manager.removeItem(at: child)
            }
            let directory = root.appendingPathComponent("operation_" + UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            active.lock.withLock { _ = active.paths.insert(directory.path) }
            return directory
        }
        defer {
            try? manager.removeItem(at: directory)
            active.lock.withLock { _ = active.paths.remove(directory.path) }
        }
        return try operation(directory)
    }
}

import Foundation

@MainActor
final class ZoteroApplicationServices {
    static let shared = ZoteroApplicationServices()

    let defaultsService: DefaultsService
    let cacheStore: ZoteroCacheStore
    let syncProgress: ZoteroSyncProgress
    let syncEngine: ZoteroSyncEngine
    let documentSyncService: ZoteroDocumentSyncService

    private init() {
        let defaults = DefaultsService(userDefaults: .standard)
        let cache = ZoteroCacheStore()
        defaultsService = defaults
        cacheStore = cache
        let progress = ZoteroSyncProgress()
        syncProgress = progress
        syncEngine = ZoteroSyncEngine(cacheStore: cache, progress: progress)
        documentSyncService = ZoteroDocumentSyncService(
            defaultsService: defaults,
            cacheStore: cache
        )
    }
}

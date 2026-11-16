import Foundation
@preconcurrency import PencilKit

enum ZoteroSyncTrigger: String {
    case appLaunch, editorFinished, periodic, networkReconnect, manual, accountChanged, requiredWork
}

enum ZoteroSyncSchedule {
    static let minimumAutomaticInterval: TimeInterval = 600

    static func shouldRun(_ trigger: ZoteroSyncTrigger, lastAttempt: Date?, now: Date = Date()) -> Bool {
        switch trigger {
        case .appLaunch, .editorFinished, .manual, .accountChanged, .requiredWork: return true
        case .periodic, .networkReconnect:
            guard let lastAttempt else { return true }
            return now.timeIntervalSince(lastAttempt) >= minimumAutomaticInterval
        }
    }
}

enum ZoteroDownloadInstallTransaction {
    /// A committed cache is the durable recovery point. If the atomic Jot
    /// write fails, the next open rebuilds it from the validated cache.
    static func commit<CacheState>(
        installCache: () throws -> CacheState,
        persistLocalJot: (CacheState) throws -> Void
    ) throws -> CacheState {
        let installedState = try installCache()
        try persistLocalJot(installedState)
        return installedState
    }
}

@MainActor
enum ZoteroLocalJotBaselineValidator {
    static func matches(localJot: Jot, baselineData: Data) -> Bool {
        guard localJot.pdfData != nil,
            let localDrawing = try? PKDrawing(data: localJot.drawing)
        else { return false }
        let baselineJot = (try? HybridPDFManager.load(data: baselineData).jot) ?? Jot.makeEmpty()
        guard let baselineDrawing = try? PKDrawing(data: baselineJot.drawing),
            JotEditorDrawingState.drawingsMatch(localDrawing, baselineDrawing),
            localJot.width == baselineJot.width,
            localJot.extraPages == baselineJot.extraPages,
            localJot.pdfInsertedPageSlots == baselineJot.pdfInsertedPageSlots,
            localJot.strokePageIndices == baselineJot.strokePageIndices,
            localJot.trashedPages == baselineJot.trashedPages
        else { return false }
        return true
    }
}

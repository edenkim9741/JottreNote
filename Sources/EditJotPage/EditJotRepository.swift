/*
 Jottre: Minimalistic jotting for iPhone, iPad and Mac.
 Copyright (C) 2021-2026 Anton Lorani

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

@preconcurrency import PencilKit
import CoreGraphics
import Foundation
import PDFKit
import UIKit

struct JotPDFMetadata: Sendable {
    let pageCount: Int
    let pageAspectRatio: CGFloat

    init(pageCount: Int, pageAspectRatio: CGFloat) {
        self.pageCount = pageCount
        self.pageAspectRatio = pageAspectRatio
    }

    init?(pdfData: Data) {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let document = CGPDFDocument(provider),
              document.isUnlocked,
              document.numberOfPages > 0,
              let page = document.page(at: 1) else { return nil }
        let bounds = PDFPageRenderer.displayBounds(for: page)
        guard bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0 else { return nil }
        pageCount = document.numberOfPages
        pageAspectRatio = bounds.height / bounds.width
    }
}

struct JotContent: Sendable {
    let drawing: PKDrawing
    let width: CGFloat
    let pdfData: Data?
    let extraPages: Int
    let pdfInsertedPageSlots: [Int]
    let strokePageIndices: [Int]
    let dirtyPageIndices: Set<Int>
    let trashedPages: [TrashedPage]
    let pdfMetadata: JotPDFMetadata?
    let zoteroItemKey: String?
    let zoteroFileName: String?

    init(
        drawing: PKDrawing,
        width: CGFloat,
        pdfData: Data?,
        extraPages: Int,
        pdfInsertedPageSlots: [Int],
        strokePageIndices: [Int],
        dirtyPageIndices: Set<Int> = [],
        trashedPages: [TrashedPage] = [],
        pdfMetadata: JotPDFMetadata? = nil,
        zoteroItemKey: String? = nil,
        zoteroFileName: String? = nil
    ) {
        self.drawing = drawing
        self.width = width
        self.pdfData = pdfData
        self.extraPages = extraPages
        self.pdfInsertedPageSlots = pdfInsertedPageSlots
        self.strokePageIndices = strokePageIndices
        self.dirtyPageIndices = dirtyPageIndices
        self.trashedPages = trashedPages
        self.pdfMetadata = pdfMetadata
        self.zoteroItemKey = zoteroItemKey
        self.zoteroFileName = zoteroFileName
    }
}

protocol EditJotRepositoryProtocol: Sendable {

    func readContent(
        jotFileInfo: JotFile.Info,
        onProgress: @Sendable (Double) -> Void
    ) async throws -> JotContent
    func writeContent(
        jotFileInfo: JotFile.Info,
        content: JotContent
    ) async throws
    func getConflictingVersions(jotFileInfo: JotFile.Info) -> [JotFileVersion]?
    func duplicate(jotFileInfo: JotFile.Info) throws -> JotFile.Info
    func saveDeletedPageToTrash(
        strokes: [PKStroke],
        pageStartY: CGFloat,
        width: CGFloat,
        pageName: String,
        pageDeletion: TrashService.PageDeletionInfo
    ) async throws
}

struct EditJotRepository: EditJotRepositoryProtocol {

    private let jotFileService: JotFileServiceProtocol
    private let jotFileConflictService: JotFileConflictServiceProtocol
    private let fileService: FileServiceProtocol
    private let trashService: TrashService
    private let zoteroCacheStore: ZoteroCacheStore
    private let defaultsService: DefaultsServiceProtocol

    init(
        jotFileService: JotFileServiceProtocol,
        jotFileConflictService: JotFileConflictServiceProtocol,
        fileService: FileServiceProtocol,
        trashService: TrashService,
        zoteroCacheStore: ZoteroCacheStore = ZoteroCacheStore(),
        defaultsService: DefaultsServiceProtocol = DefaultsService(userDefaults: .standard)
    ) {
        self.jotFileService = jotFileService
        self.jotFileConflictService = jotFileConflictService
        self.fileService = fileService
        self.trashService = trashService
        self.zoteroCacheStore = zoteroCacheStore
        self.defaultsService = defaultsService
    }

    func readContent(
        jotFileInfo: JotFile.Info,
        onProgress: @Sendable (Double) -> Void
    ) async throws -> JotContent {
        onProgress(0.1)
        let file = try jotFileService.readJotFile(jotFileInfo: jotFileInfo)
        onProgress(0.5)
        // The outer .jot is the authoritative editor state. Its embedded PDF
        // attachment is an interchange copy and may be stale after PDF-only edits.
        let sourceJot = file.jot
        let drawing = try PKDrawing(data: sourceJot.drawing)
        let storedPDFData = file.jot.pdfData
        let pdfData = storedPDFData.map(HybridPDFManager.pdfData(in:))
        let pageCount = pdfData.flatMap { PDFDocument(data: $0)?.pageCount } ?? 0
        let hasEmbeddedJot = storedPDFData.map { HybridPDFManager.embeddedJotData(in: $0) != nil } ?? false
        print("[Load] PDF Data Size: \(pdfData?.count ?? 0), PageCount: \(pageCount), Embedded Jot Found: \(hasEmbeddedJot), Drawing Strokes: \(drawing.strokes.count)")
        onProgress(0.9)
        return JotContent(
            drawing: drawing,
            width: sourceJot.width,
            pdfData: pdfData,
            extraPages: sourceJot.extraPages,
            pdfInsertedPageSlots: sourceJot.pdfInsertedPageSlots,
            strokePageIndices: sourceJot.strokePageIndices,
            dirtyPageIndices: [],
            trashedPages: sourceJot.trashedPages,
            pdfMetadata: pdfData.flatMap { JotPDFMetadata(pdfData: $0) },
            zoteroItemKey: sourceJot.zoteroItemKey,
            zoteroFileName: sourceJot.zoteroFileName
        )
    }

    func writeContent(
        jotFileInfo: JotFile.Info,
        content: JotContent
    ) async throws {
        let strokes = content.drawing.strokes
        let strokePageIndices = content.strokePageIndices.count == strokes.count
            ? content.strokePageIndices.map { max(0, $0) }
            : []
        let insertedPageSlots = Array(
            Set(content.pdfInsertedPageSlots.lazy.filter { $0 >= 0 })
        ).sorted()
        let jot = Jot(
            version: Jot.currentVersion,
            drawing: content.drawing.dataRepresentation(),
            width: content.width,
            pdfData: content.pdfData,
            extraPages: max(0, content.extraPages),
            pdfInsertedPageSlots: insertedPageSlots,
            strokePageIndices: strokePageIndices,
            trashedPages: content.trashedPages,
            zoteroItemKey: content.zoteroItemKey,
            zoteroFileName: content.zoteroFileName
        )
        let savedPDF: Data?
        if content.pdfData != nil {
            // Commit native Ink annotations into the PDF once. Later saves can
            // replace annotations only on pages marked dirty by the editor.
            savedPDF = try JotHybridPDFBuilder.buildHybridPDF(
                jot: jot,
                dirtyPageIndices: content.dirtyPageIndices
            )
        } else {
            // nil pdfData is the persisted representation of a ruled-paper note.
            // Storing a synthetic white PDF here changes its background to blank
            // when the editor is reopened.
            savedPDF = nil
        }
        print("[Save] Original PDF Size: \(content.pdfData?.count ?? 0), New PDF Size: \(savedPDF?.count ?? 0), Dirty Pages: \(content.dirtyPageIndices.count), Drawing Strokes: \(strokes.count)")
        let jotFile = JotFile(
            info: jotFileInfo,
            jot: Jot(
                version: Jot.currentVersion,
                drawing: content.drawing.dataRepresentation(),
                width: content.width,
                pdfData: savedPDF,
                extraPages: max(0, content.extraPages),
                pdfInsertedPageSlots: insertedPageSlots,
                strokePageIndices: strokePageIndices,
                trashedPages: content.trashedPages,
                zoteroItemKey: content.zoteroItemKey,
                zoteroFileName: content.zoteroFileName
            )
        )
        try jotFileService.write(jotFile: jotFile)

        if let key = content.zoteroItemKey,
           let userID = defaultsService.getValue(DefaultsKey<String>.zoteroUserID),
           !userID.isEmpty {
            let hybridPDF = try savedPDF ?? JotHybridPDFBuilder.buildHybridPDF(
                jot: jotFile.jot,
                dirtyPageIndices: content.dirtyPageIndices
            )
            let cacheURL = try zoteroCacheStore.saveEditedPDF(
                key: key,
                data: hybridPDF,
                userID: userID
            )
            print("[ZoteroSave] Successfully saved hybrid PDF to cache: \(cacheURL.path), bytes: \(hybridPDF.count)")
            NotificationCenter.default.post(name: .zoteroAttachmentCacheChanged, object: key)
        }
    }

    func getConflictingVersions(jotFileInfo: JotFile.Info) -> [JotFileVersion]? {
        jotFileConflictService.getConfictingVersions(jotFileInfo: jotFileInfo)
    }

    func duplicate(jotFileInfo: JotFile.Info) throws -> JotFile.Info {
        try jotFileService.duplicate(jotFileInfo: jotFileInfo)
    }

    func saveDeletedPageToTrash(
        strokes: [PKStroke],
        pageStartY: CGFloat,
        width: CGFloat,
        pageName: String,
        pageDeletion: TrashService.PageDeletionInfo
    ) async throws {
        let shiftedStrokes = strokes.map { stroke in
            let shifted = stroke.transform.translatedBy(x: 0, y: -pageStartY)
            return PKStroke(ink: stroke.ink, path: stroke.path, transform: shifted, mask: stroke.mask)
        }
        let drawing = PKDrawing(strokes: shiftedStrokes)
        let jot = Jot(
            version: Jot.currentVersion,
            drawing: drawing.dataRepresentation(),
            width: width
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(jot)
        try await trashService.saveJotDataToTrash(
            data: data,
            name: pageName,
            pageDeletion: pageDeletion,
            fileService: fileService
        )
    }

}

struct EditJotPersistenceSnapshot: Sendable {
    let revision: UInt64
    let content: JotContent
}

/// Owns all writes for one open document. Normal ink edits are debounced, while
/// structural mutations can request an immediate flush through the same queue.
/// Only one write is active, and a slow disk retains just the newest pending
/// snapshot instead of accumulating full drawings and embedded PDFs in memory.
actor EditJotPersistenceWriter {

    private struct Waiter {
        let revision: UInt64
        let continuation: CheckedContinuation<Result<Void, any Error>, Never>
    }

    private let jotFileInfo: JotFile.Info
    private let repository: EditJotRepositoryProtocol
    private let logger: LoggerProtocol
    private let debounceDuration: Duration

    private var highestAcceptedRevision = UInt64.zero
    private var completedRevision = UInt64.zero
    private var lastResult: Result<Void, any Error> = .success(())
    private var latestSnapshot: EditJotPersistenceSnapshot?
    private var pendingSnapshot: EditJotPersistenceSnapshot?
    private var waiters: [Waiter] = []
    private var debounceTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var activeRevision: UInt64?

    init(
        jotFileInfo: JotFile.Info,
        repository: EditJotRepositoryProtocol,
        logger: LoggerProtocol,
        debounceDuration: Duration = .seconds(2)
    ) {
        self.jotFileInfo = jotFileInfo
        self.repository = repository
        self.logger = logger
        self.debounceDuration = debounceDuration
    }

    func schedule(_ snapshot: EditJotPersistenceSnapshot) {
        guard accept(snapshot) else { return }

        debounceTask?.cancel()
        let revision = snapshot.revision
        let duration = debounceDuration
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.debounceElapsed(for: revision)
        }
    }

    func saveImmediately(_ snapshot: EditJotPersistenceSnapshot) async throws {
        _ = accept(snapshot)
        debounceTask?.cancel()
        debounceTask = nil
        queueLatestSnapshotIfNeeded()
        startDrainIfNeeded()

        let result = await result(for: snapshot.revision)
        try result.get()
    }

    private func accept(_ snapshot: EditJotPersistenceSnapshot) -> Bool {
        guard snapshot.revision > highestAcceptedRevision else { return false }
        highestAcceptedRevision = snapshot.revision
        latestSnapshot = snapshot
        return true
    }

    private func debounceElapsed(for revision: UInt64) {
        guard revision == highestAcceptedRevision else { return }
        debounceTask = nil
        print("[SaveDebounce] Quiet period elapsed; starting save for revision \(revision) on utility worker.")
        queueLatestSnapshotIfNeeded()
        startDrainIfNeeded()
    }

    private func queueLatestSnapshotIfNeeded() {
        guard let latestSnapshot,
              latestSnapshot.revision > completedRevision,
              latestSnapshot.revision != activeRevision,
              latestSnapshot.revision != pendingSnapshot?.revision else { return }
        pendingSnapshot = latestSnapshot
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil, pendingSnapshot != nil else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let snapshot = pendingSnapshot {
            pendingSnapshot = nil
            activeRevision = snapshot.revision

            let result: Result<Void, any Error>
            let saveStartedAt = ContinuousClock.now
            do {
                // PDFKit serialization, PencilKit encoding and cache writes are
                // CPU/disk work. Keep them off the editor's executor even when
                // this writer was scheduled by a MainActor view model.
                try await Task.detached(priority: .utility) { [repository, jotFileInfo, content = snapshot.content] in
                    try await repository.writeContent(jotFileInfo: jotFileInfo, content: content)
                }.value
                let elapsed = saveStartedAt.duration(to: .now)
                print("[SaveDebounce] Save completed for revision \(snapshot.revision) in \(elapsed) on utility worker.")
                result = .success(())
            } catch {
                logger.error("Failed to persist jot: \(error)")
                result = .failure(error)
            }

            completedRevision = snapshot.revision
            activeRevision = nil
            lastResult = result
            if latestSnapshot?.revision == snapshot.revision {
                latestSnapshot = nil
            }
            resumeWaiters(through: snapshot.revision, with: result)
        }

        drainTask = nil
        // A submission can arrive while the repository call is suspended. The
        // loop normally observes it; this guard also covers executor ordering at
        // the final suspension boundary without starting a parallel writer.
        startDrainIfNeeded()
    }

    private func result(for revision: UInt64) async -> Result<Void, any Error> {
        if completedRevision >= revision {
            return lastResult
        }

        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(revision: revision, continuation: continuation))
        }
    }

    private func resumeWaiters(
        through revision: UInt64,
        with result: Result<Void, any Error>
    ) {
        var remaining: [Waiter] = []
        remaining.reserveCapacity(waiters.count)
        for waiter in waiters {
            if waiter.revision <= revision {
                waiter.continuation.resume(returning: result)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    deinit {
        debounceTask?.cancel()
        drainTask?.cancel()
        for waiter in waiters {
            waiter.continuation.resume(returning: .failure(CancellationError()))
        }
    }
}

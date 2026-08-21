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

@MainActor
final class EditJotViewModel {

    private static let maximumPageCount = 10_000

    struct Drawing: Sendable {
        let value: PKDrawing
        let width: CGFloat
        let strokePageIndices: [Int]

        init(value: PKDrawing, width: CGFloat, strokePageIndices: [Int] = []) {
            self.value = value
            self.width = width
            self.strokePageIndices = strokePageIndices
        }
    }

    struct ScribbleEraseEvent: Sendable {
        let beforeDrawing: PKDrawing
        let result: Drawing
    }

    enum Background: Sendable {
        case ruled(extraPages: Int)
        case pdf(data: Data, extraPages: Int, insertedPageSlots: [Int])
    }

    private(set) lazy var menuConfigurations = menuConfigurationFactory.make(
        onShare: { [weak self] (format: ShareFormat, configurePopoverAnchor: PopoverAnchor?) in
            Task { @MainActor [weak self] in
                guard let self, await self.flushPendingChanges() else { return }
                self.coordinator?.showShareJot(
                    jotFileInfo: self.jotFileInfo,
                    format: format,
                    configurePopoverAnchor: configurePopoverAnchor
                )
            }
        },
        onRename: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, await self.prepareForFileMutation() else { return }
                self.coordinator?.showRenameAlert(jotFileInfo: self.jotFileInfo)
            }
        },
        onDuplicate: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, await self.flushPendingChanges() else { return }
                self.didTapDuplicateJot(jotFileInfo: self.jotFileInfo)
            }
        },
        onDelete: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, await self.prepareForFileMutation() else { return }
                self.coordinator?.openDeleteJot(jotFileInfo: self.jotFileInfo)
            }
        },
        onShowInFiles: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, await self.flushPendingChanges() else { return }
                self.coordinator?.showInFiles(jotFileInfo: self.jotFileInfo)
            }
        },
        onAddPage: { [weak self] in Task { @MainActor [weak self] in
            guard let self else { return }
            let index = self.visiblePageProvider?()
            self.addPage(afterPageIndex: index)
        } },
        onDeletePage: { [weak self] in Task { @MainActor [weak self] in self?.promptDeletePage() } }
    )

    // When the UI presents the menu we set this to allow insertion after the
    // currently visible page. The controller should set this before accessing
    // `menuConfigurations`.
    var visiblePageProvider: (() -> Int?)?

    var title: String { jotFileInfo.name }

    let drawing: AsyncStream<Drawing>
    private let drawingContinuation: AsyncStream<Drawing>.Continuation

    let scribbleEraseEvent: AsyncStream<ScribbleEraseEvent>
    private let scribbleEraseContinuation: AsyncStream<ScribbleEraseEvent>.Continuation

    let background: AsyncStream<Background>
    private let backgroundContinuation: AsyncStream<Background>.Continuation

    let isEditing: AsyncStream<Bool?>
    private let isEditingContinuation: AsyncStream<Bool?>.Continuation

    let showsBackButton: AsyncStream<Bool>
    private let showsBackButtonContinuation: AsyncStream<Bool>.Continuation

    let loadingProgress: AsyncStream<Double?>
    private let loadingProgressContinuation: AsyncStream<Double?>.Continuation

    private var loadingTask: Task<Void, Never>?
    private var backupTask: Task<Void, Never>?
    private var persistenceRevision = UInt64.zero
    private var isPersistenceReady = false
    private var isDirty = false
    private let persistenceWriter: EditJotPersistenceWriter

    var currentPdfData: Data?
    var currentExtraPages: Int = 0
    var currentPdfInsertedPageSlots: [Int] = []
    var currentDrawing: PKDrawing = PKDrawing()
    var previousDrawing: PKDrawing = PKDrawing()
    var currentWidth: CGFloat = Jot.defaultWidth
    // Per-stroke page indices aligned with `currentDrawing.strokes`.
    // Each entry records the logical page index the stroke was created on.
    var currentStrokePageIndices: [Int] = []
    private var cachedPDFPageAspectRatio: CGFloat?
    private var cachedPDFPageCount: Int?

    let jotFileInfo: JotFile.Info
    let repository: EditJotRepositoryProtocol
    private weak var coordinator: EditJotCoordinatorProtocol?
    private let menuConfigurationFactory: JotMenuConfigurationFactory
    let webDAVBackupService: WebDAVBackupService
    let logger: LoggerProtocol

    init(
        jotFileInfo: JotFile.Info,
        repository: EditJotRepositoryProtocol,
        coordinator: EditJotCoordinatorProtocol,
        menuConfigurationFactory: JotMenuConfigurationFactory,
        webDAVBackupService: WebDAVBackupService,
        logger: LoggerProtocol
    ) {
        self.jotFileInfo = jotFileInfo
        self.coordinator = coordinator
        self.repository = repository
        self.menuConfigurationFactory = menuConfigurationFactory
        self.webDAVBackupService = webDAVBackupService
        self.logger = logger
        persistenceWriter = EditJotPersistenceWriter(
            jotFileInfo: jotFileInfo,
            repository: repository,
            logger: logger
        )
        (isEditing, isEditingContinuation) = AsyncStream.makeStream(
            of: Bool?.self, bufferingPolicy: .bufferingNewest(1)
        )
        (drawing, drawingContinuation) = AsyncStream.makeStream(
            of: Drawing.self, bufferingPolicy: .bufferingNewest(1)
        )
        (scribbleEraseEvent, scribbleEraseContinuation) = AsyncStream.makeStream(
            of: ScribbleEraseEvent.self, bufferingPolicy: .bufferingNewest(1)
        )
        (background, backgroundContinuation) = AsyncStream.makeStream(
            of: Background.self, bufferingPolicy: .bufferingNewest(1)
        )
        (showsBackButton, showsBackButtonContinuation) = AsyncStream.makeStream(
            of: Bool.self, bufferingPolicy: .bufferingNewest(1)
        )
        (loadingProgress, loadingProgressContinuation) = AsyncStream.makeStream(
            of: Double?.self, bufferingPolicy: .bufferingNewest(1)
        )

        #if targetEnvironment(macCatalyst)
        isEditingContinuation.yield(nil)
        #else
        isEditingContinuation.yield(true)
        #endif

    }

    func didLoad() {
        showsBackButtonContinuation.yield(coordinator?.canGoBack() ?? false)

        if let jotFileVersions = repository.getConflictingVersions(jotFileInfo: jotFileInfo) {
            coordinator?.showJotConflictPage(
                jotFileInfo: jotFileInfo,
                jotFileVersions: jotFileVersions
            ) { [weak self] (result: JotConflictResult) in
                Task { @MainActor in
                    switch result {
                    case .keepAll: self?.coordinator?.goBack()
                    case let .keep(jotFileInfo): self?.coordinator?.openJot(jotFileInfo: jotFileInfo)
                    }
                }
            }
        } else {
            loadingProgressContinuation.yield(0.0)
            loadingTask?.cancel()
            let progressContinuation = loadingProgressContinuation
            loadingTask = Task { [weak self, repository, jotFileInfo, logger] in
                do {
                    let content = try await repository.readContent(
                        jotFileInfo: jotFileInfo,
                        onProgress: { progressContinuation.yield($0) }
                    )
                    try Task.checkCancellation()
                    if let self {
                        applyLoadedContent(content)
                    } else {
                        return
                    }
                    progressContinuation.yield(1.0)
                    do {
                        try await Task.sleep(for: .milliseconds(350))
                    } catch {
                        return
                    }
                    progressContinuation.yield(nil)
                } catch {
                    guard !(error is CancellationError) else { return }
                    progressContinuation.yield(nil)
                    logger.error("Failed to read drawing: \(error)")
                }
            }
        }
    }

    func didTapToggleEditingButton(isEditing: Bool) {
        isEditingContinuation.yield(!isEditing)
    }

    func didChangeDrawing(
        _ drawing: PKDrawing,
        strokePageIndices: [Int]? = nil,
        detectsScribbleErase: Bool = true
    ) {
        guard isPersistenceReady else { return }
        let prev = previousDrawing
        previousDrawing = drawing

        if detectsScribbleErase,
           let result = ScribbleEraseProcessor.process(newDrawing: drawing, previousDrawing: prev) {
            let processed = result.processedDrawing
            previousDrawing = processed
            currentDrawing = processed
            currentStrokePageIndices = strokePageIndices(
                after: result,
                previousDrawing: prev
            )
            scribbleEraseContinuation.yield(ScribbleEraseEvent(
                beforeDrawing: drawing,
                result: Drawing(
                    value: processed,
                    width: currentWidth,
                    strokePageIndices: currentStrokePageIndices
                )
            ))
            schedulePersistence()
            return
        }

        currentDrawing = drawing

        if let strokePageIndices, strokePageIndices.count == drawing.strokes.count {
            currentStrokePageIndices = strokePageIndices.map {
                min(max(0, $0), Self.maximumPageCount - 1)
            }
        } else if drawing.strokes.count != currentStrokePageIndices.count {
            if drawing.strokes.count > currentStrokePageIndices.count {
                for idx in currentStrokePageIndices.count..<drawing.strokes.count {
                    currentStrokePageIndices.append(pageIndex(for: drawing.strokes[idx]))
                }
            } else {
                currentStrokePageIndices = normalizedStrokePageIndices([], for: drawing)
            }
        }

        schedulePersistence()
    }

    func didTapBackButton() {
        Task { @MainActor [weak self] in
            guard let self, await self.flushPendingChanges() else { return }
            if let jotFileVersions = self.repository.getConflictingVersions(
                jotFileInfo: self.jotFileInfo
            ) {
                self.coordinator?.showJotConflictPage(
                    jotFileInfo: self.jotFileInfo,
                    jotFileVersions: jotFileVersions
                ) { [weak self] (_: JotConflictResult) in
                    Task { @MainActor in self?.coordinator?.goBack() }
                }
            } else {
                self.coordinator?.goBack()
            }
        }
    }

    func prepareForUndoRedo(expectedDrawing: PKDrawing) {
        previousDrawing = expectedDrawing
    }

    func didDisappear() {
        // A quick back/background event can arrive before an asynchronous read
        // completes. Never replace an existing note with the VM's empty defaults.
        guard isPersistenceReady else { return }
        let snapshot = makePersistenceSnapshot()
        let shouldFlush = isDirty
        let writer = persistenceWriter
        let backupService = webDAVBackupService
        let jotFileInfo = jotFileInfo
        let logger = logger

        backupTask?.cancel()
        backupTask = Task { [weak self] in
            if shouldFlush {
                do {
                    try await writer.saveImmediately(snapshot)
                    self?.markPersisted(revision: snapshot.revision)
                } catch {
                    logger.error("Failed to flush jot before backup: \(error)")
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await backupService.backup(jotFileInfo: jotFileInfo, content: snapshot.content)
        }
    }

    /// Flushes local state while UIKit grants finite background execution time.
    /// WebDAV remains best-effort and is launched only after the durable local
    /// write has completed.
    func didEnterBackground() async {
        guard await flushPendingChanges(presentsError: false), !Task.isCancelled else { return }
        didDisappear()
    }

    deinit {
        loadingTask?.cancel()
        isEditingContinuation.finish()
        drawingContinuation.finish()
        scribbleEraseContinuation.finish()
        backgroundContinuation.finish()
        showsBackButtonContinuation.finish()
        loadingProgressContinuation.finish()
    }
}

// MARK: - Page Management

extension EditJotViewModel {

    func importPDF(data: Data) {
        guard isPersistenceReady else { return }
        currentPdfData = data
        cacheCurrentPDFMetadata()
        guard cachedPDFPageCount != nil else {
            currentPdfData = nil
            cacheCurrentPDFMetadata()
            coordinator?.showInfoAlert(
                title: L10n.EditJot.PDF.Error.importFailed,
                message: ""
            )
            return
        }

        let basePages = basePageCount()
        currentPdfInsertedPageSlots = currentExtraPages > 0
            ? Array(basePages..<(basePages + currentExtraPages))
            : []
        yieldBackground()

        persistCurrentContent()
    }

    func addPage() { addPage(afterPageIndex: nil) }

    func addPage(afterPageIndex: Int?) {
        guard isPersistenceReady else { return }
        let pageHeight = normalizedPageHeight()
        let pageStride = pageHeight + JotBackgroundView.pageSpacing
        let basePages = basePageCount()
        let totalPages = currentPdfData == nil
            ? 1 + currentExtraPages
            : basePages + currentPdfInsertedPageSlots.count
        guard totalPages < Self.maximumPageCount else { return }

        let insertIndex = insertionIndex(after: afterPageIndex, totalPages: totalPages)
        let mutation = drawingByInsertingPage(at: insertIndex, pageStride: pageStride)
        currentDrawing = mutation.drawing
        previousDrawing = mutation.drawing
        currentStrokePageIndices = mutation.indices

        if mutation.didMoveStrokes {
            drawingContinuation.yield(Drawing(
                value: mutation.drawing,
                width: currentWidth,
                strokePageIndices: mutation.indices
            ))
        }

        if currentPdfData != nil {
            for index in currentPdfInsertedPageSlots.indices
                where currentPdfInsertedPageSlots[index] >= insertIndex {
                currentPdfInsertedPageSlots[index] += 1
            }
            let position = currentPdfInsertedPageSlots.firstIndex { $0 >= insertIndex }
                ?? currentPdfInsertedPageSlots.endIndex
            currentPdfInsertedPageSlots.insert(insertIndex, at: position)
            currentExtraPages = currentPdfInsertedPageSlots.count
        } else {
            currentExtraPages += 1
        }

        yieldBackground()
        persistCurrentContent()
    }

    func promptDeletePage() {
        guard isPersistenceReady else { return }
        guard currentExtraPages > 0 else {
            coordinator?.showInfoAlert(title: L10n.EditJot.PDF.DeletePage.nothingToDelete, message: "")
            return
        }
        coordinator?.showConfirmAlert(
            title: L10n.EditJot.PDF.DeletePage.title,
            message: L10n.EditJot.PDF.DeletePage.message,
            confirmTitle: L10n.Action.delete,
            isDestructive: true
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let visible = self.visiblePageProvider?()
                self.deleteExtraPage(at: visible)
            }
        }
    }

    func deleteLastExtraPage() {
        deleteExtraPage(at: nil)
    }

    /// Remove all ink strokes that were recorded as belonging to the given
    /// logical page. This uses the persisted `currentStrokePageIndices` mapping
    /// so it will remove exactly the ink objects that were created on that
    /// page regardless of their current render position.
    func deleteInkObjects(onPage page: Int) {
        guard isPersistenceReady else { return }
        guard !currentDrawing.strokes.isEmpty else { return }

        var newStrokes: [PKStroke] = []
        var newIndices: [Int] = []
        newStrokes.reserveCapacity(currentDrawing.strokes.count)
        newIndices.reserveCapacity(currentDrawing.strokes.count)
        for (idx, stroke) in currentDrawing.strokes.enumerated() {
            let pageIndex = resolvedPageIndex(for: stroke, at: idx)
            guard pageIndex != page else { continue }
            newStrokes.append(stroke)
            newIndices.append(pageIndex)
        }

        let newDrawing = PKDrawing(strokes: newStrokes)
        currentDrawing = newDrawing
        previousDrawing = newDrawing
        currentStrokePageIndices = newIndices
        drawingContinuation.yield(Drawing(
            value: newDrawing,
            width: currentWidth,
            strokePageIndices: newIndices
        ))
        persistCurrentContent()
    }

    func deleteInkObjectsForVisiblePage() {
        guard let visible = visiblePageProvider?() else { return }
        deleteInkObjects(onPage: visible)
    }

    func deleteExtraPage(at index: Int?) {
        guard isPersistenceReady else { return }
        guard currentExtraPages > 0 else { return }

        let pageHeight = normalizedPageHeight()
        let pageStride = pageHeight + JotBackgroundView.pageSpacing
        let basePages = basePageCount()

        let deleteIndex: Int
        if currentPdfData != nil {
            if currentPdfInsertedPageSlots.isEmpty, currentExtraPages > 0 {
                currentPdfInsertedPageSlots = Array(basePages..<(basePages + currentExtraPages))
            }
            let totalPages = basePages + currentPdfInsertedPageSlots.count
            let preferred: Int = {
                if let idx = index, currentPdfInsertedPageSlots.contains(idx) { return idx }
                return currentPdfInsertedPageSlots.last ?? max(basePages, totalPages - 1)
            }()
            deleteIndex = preferred
            if let pos = currentPdfInsertedPageSlots.firstIndex(of: deleteIndex) {
                currentPdfInsertedPageSlots.remove(at: pos)
            } else {
                _ = currentPdfInsertedPageSlots.popLast()
            }
            currentPdfInsertedPageSlots = currentPdfInsertedPageSlots.map {
                $0 > deleteIndex ? $0 - 1 : $0
            }
            currentExtraPages = currentPdfInsertedPageSlots.count
        } else {
            let totalPages = max(1, basePages + currentExtraPages)
            deleteIndex = index.map { min(max(0, $0), totalPages - 1) } ?? (totalPages - 1)
            currentExtraPages = max(0, currentExtraPages - 1)
        }

        let mutation = drawingByDeletingPage(at: deleteIndex, pageStride: pageStride)
        currentDrawing = mutation.drawing
        previousDrawing = mutation.drawing
        currentStrokePageIndices = mutation.indices
        drawingContinuation.yield(Drawing(
            value: mutation.drawing,
            width: currentWidth,
            strokePageIndices: mutation.indices
        ))
        yieldBackground()
        persistCurrentContent()
        schedulePageTrashSave(
            strokes: mutation.removedStrokes,
            deleteIndex: deleteIndex,
            pageStride: pageStride
        )
    }
}

// MARK: - Private Helpers

private extension EditJotViewModel {

    struct PageDeletionMutation {
        let drawing: PKDrawing
        let indices: [Int]
        let removedStrokes: [PKStroke]
    }

    func applyLoadedContent(_ content: JotContent) {
        currentWidth = content.width.isFinite && content.width > 0
            ? content.width
            : Jot.defaultWidth
        currentPdfData = content.pdfData
        cachedPDFPageAspectRatio = content.pdfMetadata?.pageAspectRatio
        cachedPDFPageCount = content.pdfMetadata.map {
            min($0.pageCount, Self.maximumPageCount)
        }

        if currentPdfData != nil {
            let basePages = basePageCount()
            if content.pdfInsertedPageSlots.isEmpty, content.extraPages > 0 {
                let count = min(
                    content.extraPages,
                    max(0, Self.maximumPageCount - basePages)
                )
                currentPdfInsertedPageSlots = Array(basePages..<(basePages + count))
            } else {
                currentPdfInsertedPageSlots = normalizedPDFInsertedPageSlots(
                    content.pdfInsertedPageSlots,
                    basePageCount: basePages
                )
            }
            currentExtraPages = currentPdfInsertedPageSlots.count
        } else {
            currentPdfInsertedPageSlots = []
            currentExtraPages = min(content.extraPages, Self.maximumPageCount - 1)
        }

        let loadedIndices = normalizedStrokePageIndices(
            content.strokePageIndices,
            for: content.drawing
        )
        var highlighterStrokes: [PKStroke] = []
        var foregroundStrokes: [PKStroke] = []
        var highlighterIndices: [Int] = []
        var foregroundIndices: [Int] = []
        for (stroke, pageIndex) in zip(content.drawing.strokes, loadedIndices) {
            if stroke.ink.inkType == .marker {
                highlighterStrokes.append(stroke)
                highlighterIndices.append(pageIndex)
            } else {
                foregroundStrokes.append(stroke)
                foregroundIndices.append(pageIndex)
            }
        }
        let layeredDrawing = PKDrawing(strokes: highlighterStrokes + foregroundStrokes)
        currentDrawing = layeredDrawing
        previousDrawing = layeredDrawing
        currentStrokePageIndices = highlighterIndices + foregroundIndices
        isDirty = false
        isPersistenceReady = true
        drawingContinuation.yield(Drawing(
            value: layeredDrawing,
            width: currentWidth,
            strokePageIndices: currentStrokePageIndices
        ))
        yieldBackground()
    }

    /// Returns the page height in the same rotation-aware coordinate system used
    /// by `PDFLoadService`, so page operations and the visible PDF stay aligned.
    /// The aspect ratio is cached when `currentPdfData` changes; this method is
    /// called after every newly committed ink stroke and must stay allocation-free.
    func normalizedPageHeight() -> CGFloat {
        let aspectRatio = cachedPDFPageAspectRatio ?? (4.0 / 3.0)
        let width = currentWidth.isFinite && currentWidth > 0 ? currentWidth : Jot.defaultWidth
        let height = width * aspectRatio
        return height.isFinite && height > 0 ? height : width * (4.0 / 3.0)
    }

    /// Page boxes do not depend on PDF painting or transparency masks. Read
    /// their geometry directly once instead of constructing the sanitized,
    /// render-ready document for every PencilKit stroke.
    func cacheCurrentPDFMetadata() {
        guard let data = currentPdfData else {
            cachedPDFPageAspectRatio = nil
            cachedPDFPageCount = nil
            return
        }

        guard let metadata = JotPDFMetadata(pdfData: data) else {
            cachedPDFPageAspectRatio = 4.0 / 3.0
            cachedPDFPageCount = nil
            return
        }
        cachedPDFPageAspectRatio = metadata.pageAspectRatio
        cachedPDFPageCount = min(metadata.pageCount, Self.maximumPageCount)
    }

    func basePageCount() -> Int {
        currentPdfData == nil ? 1 : max(1, cachedPDFPageCount ?? 1)
    }

    func normalizedPDFInsertedPageSlots(
        _ slots: [Int],
        basePageCount: Int
    ) -> [Int] {
        var result = Array(Set(slots.lazy.filter { $0 >= 0 })).sorted()
        result = Array(result.prefix(max(0, Self.maximumPageCount - basePageCount)))

        // A high invalid slot can make another high slot appear valid through
        // the count it contributes. Re-filter until the logical page count is
        // stable; malformed persisted arrays are expected to be very small.
        while true {
            let upperBound = basePageCount + result.count
            let filtered = result.filter { $0 < upperBound }
            guard filtered.count != result.count else { return result }
            result = filtered
        }
    }

    func normalizedStrokePageIndices(
        _ indices: [Int],
        for drawing: PKDrawing
    ) -> [Int] {
        drawing.strokes.enumerated().map { index, stroke in
            guard index < indices.count,
                  indices[index] >= 0,
                  indices[index] < Self.maximumPageCount else {
                return pageIndex(for: stroke)
            }
            return indices[index]
        }
    }

    func strokePageIndices(
        after result: ScribbleEraseProcessor.Result,
        previousDrawing: PKDrawing
    ) -> [Int] {
        let previousIndices = normalizedStrokePageIndices(
            currentStrokePageIndices,
            for: previousDrawing
        )
        var resultIndices: [Int] = []
        resultIndices.reserveCapacity(result.processedDrawing.strokes.count)
        for index in result.retainedPreviousStrokeIndices where index < previousIndices.count {
            resultIndices.append(previousIndices[index])
        }
        resultIndices.append(contentsOf: result.retainedAddedStrokes.map(pageIndex(for:)))
        return resultIndices
    }

    func resolvedPageIndex(for stroke: PKStroke, at index: Int) -> Int {
        guard index < currentStrokePageIndices.count,
              currentStrokePageIndices[index] >= 0,
              currentStrokePageIndices[index] < Self.maximumPageCount else {
            return pageIndex(for: stroke)
        }
        return currentStrokePageIndices[index]
    }

    func pageIndex(for stroke: PKStroke) -> Int {
        let stride = normalizedPageHeight() + JotBackgroundView.pageSpacing
        guard stride.isFinite, stride > 0 else { return 0 }
        let value = floor(stroke.renderBounds.midY / stride)
        guard value.isFinite, value > 0 else { return 0 }
        return min(Int(min(value, CGFloat(Self.maximumPageCount - 1))), Self.maximumPageCount - 1)
    }

    func insertionIndex(after index: Int?, totalPages: Int) -> Int {
        guard let index else { return totalPages }
        guard index < Int.max else { return totalPages }
        return min(max(0, index + 1), totalPages)
    }

    func drawingByInsertingPage(
        at insertionIndex: Int,
        pageStride: CGFloat
    ) -> (drawing: PKDrawing, indices: [Int], didMoveStrokes: Bool) {
        let strokes = currentDrawing.strokes
        let indices = normalizedStrokePageIndices(currentStrokePageIndices, for: currentDrawing)
        guard !strokes.isEmpty else { return (currentDrawing, [], false) }

        var transformedStrokes: [PKStroke] = []
        var transformedIndices: [Int] = []
        transformedStrokes.reserveCapacity(strokes.count)
        transformedIndices.reserveCapacity(strokes.count)
        var didMoveStrokes = false

        for (stroke, pageIndex) in zip(strokes, indices) {
            guard pageIndex >= insertionIndex else {
                transformedStrokes.append(stroke)
                transformedIndices.append(pageIndex)
                continue
            }

            didMoveStrokes = true
            let transform = stroke.transform.translatedBy(x: 0, y: pageStride)
            transformedStrokes.append(
                PKStroke(ink: stroke.ink, path: stroke.path, transform: transform, mask: stroke.mask)
            )
            transformedIndices.append(min(pageIndex + 1, Self.maximumPageCount - 1))
        }

        return (
            didMoveStrokes ? PKDrawing(strokes: transformedStrokes) : currentDrawing,
            transformedIndices,
            didMoveStrokes
        )
    }

    func drawingByDeletingPage(
        at deletionIndex: Int,
        pageStride: CGFloat
    ) -> PageDeletionMutation {
        let strokes = currentDrawing.strokes
        let indices = normalizedStrokePageIndices(currentStrokePageIndices, for: currentDrawing)
        var transformedStrokes: [PKStroke] = []
        var transformedIndices: [Int] = []
        var removedStrokes: [PKStroke] = []
        transformedStrokes.reserveCapacity(strokes.count)
        transformedIndices.reserveCapacity(strokes.count)

        for (stroke, pageIndex) in zip(strokes, indices) {
            if pageIndex == deletionIndex {
                removedStrokes.append(stroke)
            } else if pageIndex > deletionIndex {
                let transform = stroke.transform.translatedBy(x: 0, y: -pageStride)
                transformedStrokes.append(
                    PKStroke(ink: stroke.ink, path: stroke.path, transform: transform, mask: stroke.mask)
                )
                transformedIndices.append(pageIndex - 1)
            } else {
                transformedStrokes.append(stroke)
                transformedIndices.append(pageIndex)
            }
        }

        return PageDeletionMutation(
            drawing: PKDrawing(strokes: transformedStrokes),
            indices: transformedIndices,
            removedStrokes: removedStrokes
        )
    }

    func schedulePageTrashSave(
        strokes: [PKStroke],
        deleteIndex: Int,
        pageStride: CGFloat
    ) {
        let startY = CGFloat(deleteIndex) * pageStride
        let pageName = "Page \(deleteIndex + 1) from \(jotFileInfo.name)"
        let width = currentWidth
        let repository = repository
        let logger = logger
        let pageDeletion = TrashService.PageDeletionInfo(
            sourceJotPath: jotFileInfo.url.path,
            deletedPageIndex: deleteIndex,
            pageStride: pageStride
        )
        Task {
            do {
                try await repository.saveDeletedPageToTrash(
                    strokes: strokes,
                    pageStartY: startY,
                    width: width,
                    pageName: pageName,
                    pageDeletion: pageDeletion
                )
            } catch {
                logger.error("Failed to save deleted page to trash: \(error)")
            }
        }
    }

    func schedulePersistence() {
        guard isPersistenceReady else { return }
        isDirty = true
        let snapshot = makePersistenceSnapshot()
        let writer = persistenceWriter
        Task {
            await writer.schedule(snapshot)
        }
    }

    func persistCurrentContent() {
        guard isPersistenceReady else { return }
        isDirty = true
        let snapshot = makePersistenceSnapshot()
        let writer = persistenceWriter
        let logger = logger
        Task { [weak self] in
            do {
                try await writer.saveImmediately(snapshot)
                self?.markPersisted(revision: snapshot.revision)
            } catch {
                logger.error("Failed to persist jot: \(error)")
            }
        }
    }

    func markPersisted(revision: UInt64) {
        guard persistenceRevision == revision else { return }
        isDirty = false
    }

    func flushPendingChanges(presentsError: Bool = true) async -> Bool {
        // Before loading completes there is no editor-owned state to flush.
        // Navigation/file actions may safely operate on the untouched file.
        guard isPersistenceReady else { return !isDirty }

        while isDirty {
            let snapshot = makePersistenceSnapshot()
            do {
                try await persistenceWriter.saveImmediately(snapshot)
                markPersisted(revision: snapshot.revision)
            } catch {
                logger.error("Failed to flush jot: \(error)")
                if presentsError {
                    coordinator?.showInfoAlert(
                        title: String(localized: "editJot.save.error", defaultValue: "Unable to Save"),
                        message: error.localizedDescription
                    )
                }
                return false
            }
        }
        return true
    }

    func prepareForFileMutation() async -> Bool {
        if let backupTask {
            backupTask.cancel()
            await backupTask.value
            self.backupTask = nil
        }
        return await flushPendingChanges()
    }

    func makePersistenceSnapshot() -> EditJotPersistenceSnapshot {
        persistenceRevision += 1
        let content = JotContent(
            drawing: currentDrawing,
            width: currentWidth,
            pdfData: currentPdfData,
            extraPages: currentExtraPages,
            pdfInsertedPageSlots: currentPdfInsertedPageSlots,
            strokePageIndices: normalizedStrokePageIndices(
                currentStrokePageIndices,
                for: currentDrawing
            ),
            pdfMetadata: cachedPDFPageCount.map {
                JotPDFMetadata(
                    pageCount: $0,
                    pageAspectRatio: cachedPDFPageAspectRatio ?? (4.0 / 3.0)
                )
            }
        )
        currentStrokePageIndices = content.strokePageIndices
        return EditJotPersistenceSnapshot(revision: persistenceRevision, content: content)
    }

    func yieldBackground() {
        if let data = currentPdfData {
            backgroundContinuation.yield(
                .pdf(data: data, extraPages: currentExtraPages, insertedPageSlots: currentPdfInsertedPageSlots)
            )
        } else {
            backgroundContinuation.yield(.ruled(extraPages: currentExtraPages))
        }
    }

    func didTapDuplicateJot(jotFileInfo: JotFile.Info) {
        do {
            let duplicatedJotFileInfo = try repository.duplicate(jotFileInfo: jotFileInfo)
            coordinator?.openJot(jotFileInfo: duplicatedJotFileInfo)
        } catch {
            coordinator?.showInfoAlert(
                title: L10n.Jots.Duplicate.Error.generic(jotFileInfo.name),
                message: error.localizedDescription
            )
        }
    }
}

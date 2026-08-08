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
import PDFKit

@MainActor
final class EditJotViewModel {

    struct Drawing: Sendable {
        let value: PKDrawing
        let width: CGFloat
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
                guard let self else { return }
                self.coordinator?.showShareJot(
                    jotFileInfo: self.jotFileInfo,
                    format: format,
                    configurePopoverAnchor: configurePopoverAnchor
                )
            }
        },
        onRename: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.coordinator?.showRenameAlert(jotFileInfo: self.jotFileInfo)
            }
        },
        onDuplicate: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.didTapDuplicateJot(jotFileInfo: self.jotFileInfo)
            }
        },
        onDelete: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.coordinator?.openDeleteJot(jotFileInfo: self.jotFileInfo)
            }
        },
        onShowInFiles: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
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

    private var drawingUpdateTask: Task<Void, Never>?
    private let drawingUpdateContinuation: AsyncStream<PKDrawing>.Continuation
    private var loadingTask: Task<Void, Never>?

    var currentPdfData: Data? {
        didSet { cacheCurrentPDFPageAspectRatio() }
    }
    var currentExtraPages: Int = 0
    var currentPdfInsertedPageSlots: [Int] = []
    var currentDrawing: PKDrawing = PKDrawing()
    var previousDrawing: PKDrawing = PKDrawing()
    var currentWidth: CGFloat = 1200
    // Per-stroke page indices aligned with `currentDrawing.strokes`.
    // Each entry records the logical page index the stroke was created on.
    var currentStrokePageIndices: [Int] = []
    private var cachedPDFPageAspectRatio: CGFloat?

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

        let (drawingUpdate, drawingUpdateContinuation) = AsyncStream.makeStream(
            of: PKDrawing.self, bufferingPolicy: .bufferingNewest(1)
        )
        self.drawingUpdateContinuation = drawingUpdateContinuation

        drawingUpdateTask = Task { [logger] in
            for await drawing in drawingUpdate.dropFirst().debounce(for: 0.3) {
                do {
                    try await repository.writeContent(
                        jotFileInfo: jotFileInfo,
                        drawing: drawing,
                        pdfData: self.currentPdfData,
                        extraPages: self.currentExtraPages,
                        pdfInsertedPageSlots: self.currentPdfInsertedPageSlots,
                        strokePageIndices: self.currentStrokePageIndices
                    )
                } catch {
                    logger.error("Failed to write drawing: \(error)")
                }
            }
        }
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
            loadingTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let content = try await repository.readContent(
                        jotFileInfo: jotFileInfo,
                        onProgress: { [weak self] pct in self?.loadingProgressContinuation.yield(pct) }
                    )
                    currentPdfData = content.pdfData
                    currentExtraPages = content.extraPages
                    currentPdfInsertedPageSlots = content.pdfInsertedPageSlots
                    if currentPdfData != nil, currentPdfInsertedPageSlots.isEmpty, currentExtraPages > 0 {
                        let basePages = PDFDocument(data: currentPdfData ?? Data())?.pageCount ?? 1
                        currentPdfInsertedPageSlots = Array(basePages..<(basePages + currentExtraPages))
                    }
                    currentExtraPages = currentPdfInsertedPageSlots.isEmpty
                        ? currentExtraPages : currentPdfInsertedPageSlots.count
                    currentDrawing = content.drawing
                    previousDrawing = content.drawing
                    currentStrokePageIndices = content.strokePageIndices
                    currentWidth = content.width
                    drawingContinuation.yield(Drawing(value: content.drawing, width: content.width))
                    yieldBackground()
                    loadingProgressContinuation.yield(1.0)
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    loadingProgressContinuation.yield(nil)
                } catch {
                    loadingProgressContinuation.yield(nil)
                    logger.error("Failed to read drawing: \(error)")
                }
            }
        }
    }

    func didTapToggleEditingButton(isEditing: Bool) {
        isEditingContinuation.yield(!isEditing)
    }

    func didChangeDrawing(_ drawing: PKDrawing) {
        let prev = previousDrawing
        previousDrawing = drawing

        if let result = ScribbleEraseProcessor.process(newDrawing: drawing, previousDrawing: prev) {
            let processed = result.processedDrawing
            previousDrawing = processed
            currentDrawing = processed
            scribbleEraseContinuation.yield(ScribbleEraseEvent(
                beforeDrawing: drawing,
                result: Drawing(value: processed, width: currentWidth)
            ))
            drawingUpdateContinuation.yield(processed)
            return
        }

        currentDrawing = drawing

        if drawing.strokes.count != currentStrokePageIndices.count {
            let pageHeight = normalizedPageHeight()
            let pageStride = pageHeight + JotBackgroundView.pageSpacing
            if drawing.strokes.count > currentStrokePageIndices.count {
                for idx in currentStrokePageIndices.count..<drawing.strokes.count {
                    let page = Int(floor(drawing.strokes[idx].renderBounds.midY / pageStride))
                    currentStrokePageIndices.append(max(0, page))
                }
            } else {
                currentStrokePageIndices = drawing.strokes.map { stroke in
                    max(0, Int(floor(stroke.renderBounds.midY / pageStride)))
                }
            }
        }

        drawingUpdateContinuation.yield(drawing)
    }

    func didTapBackButton() {
        if let jotFileVersions = repository.getConflictingVersions(jotFileInfo: jotFileInfo) {
            coordinator?.showJotConflictPage(
                jotFileInfo: jotFileInfo,
                jotFileVersions: jotFileVersions
            ) { [weak self] (_: JotConflictResult) in
                Task { @MainActor in self?.coordinator?.goBack() }
            }
        } else {
            coordinator?.goBack()
        }
    }

    func prepareForUndoRedo(expectedDrawing: PKDrawing) {
        previousDrawing = expectedDrawing
    }

    func didDisappear() {
        webDAVBackupService.backup(
            jotFileInfo: jotFileInfo,
            drawing: currentDrawing,
            pdfData: currentPdfData,
            extraPages: currentExtraPages,
            pdfInsertedPageSlots: currentPdfInsertedPageSlots,
            width: currentWidth
        )
    }

    deinit { drawingUpdateTask?.cancel() }
}

// MARK: - Page Management

extension EditJotViewModel {

    func importPDF(data: Data) {
        currentPdfData = data
        currentPdfInsertedPageSlots = []
        yieldBackground()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await repository.writeContent(
                    jotFileInfo: jotFileInfo,
                    drawing: currentDrawing,
                    pdfData: data,
                    extraPages: currentExtraPages,
                    pdfInsertedPageSlots: currentPdfInsertedPageSlots,
                    strokePageIndices: currentStrokePageIndices
                )
            } catch {
                logger.error("Failed to save PDF: \(error)")
                coordinator?.showInfoAlert(
                    title: L10n.EditJot.PDF.Error.importFailed,
                    message: error.localizedDescription
                )
            }
        }
    }

    func addPage() { addPage(afterPageIndex: nil) }

    func addPage(afterPageIndex: Int?) {
        let pageHeight = normalizedPageHeight()
        let pageStride = pageHeight + JotBackgroundView.pageSpacing
        let basePages: Int = currentPdfData.flatMap { PDFDocument(data: $0)?.pageCount } ?? 1

        if currentPdfData != nil {
            if currentPdfInsertedPageSlots.isEmpty, currentExtraPages > 0 {
                currentPdfInsertedPageSlots = Array(basePages..<(basePages + currentExtraPages))
            }

            let totalPages = basePages + currentPdfInsertedPageSlots.count
            let insertIndex = afterPageIndex.map { min(max(0, $0 + 1), totalPages) } ?? totalPages
            let insertionBoundaryY = CGFloat(insertIndex) * pageStride
            let oldStrokes = currentDrawing.strokes
            let oldIndices = currentStrokePageIndices
            let shiftedDrawing = shiftDrawing(currentDrawing, by: pageStride, afterY: insertionBoundaryY)

            currentDrawing = shiftedDrawing
            previousDrawing = shiftedDrawing
            drawingContinuation.yield(Drawing(value: shiftedDrawing, width: currentWidth))
            drawingUpdateContinuation.yield(shiftedDrawing)

            if !oldIndices.isEmpty {
                var newIndices = oldIndices
                for (idx, stroke) in oldStrokes.enumerated() where stroke.renderBounds.minY >= insertionBoundaryY {
                    newIndices[idx] += 1
                }
                currentStrokePageIndices = newIndices
            } else {
                currentStrokePageIndices = currentDrawing.strokes.map { stroke in
                    max(0, Int(floor(stroke.renderBounds.midY / pageStride)))
                }
            }

            currentPdfInsertedPageSlots = currentPdfInsertedPageSlots
                .map { $0 >= insertIndex ? $0 + 1 : $0 }
            currentPdfInsertedPageSlots.append(insertIndex)
            currentPdfInsertedPageSlots.sort()
            currentExtraPages = currentPdfInsertedPageSlots.count

            yieldBackground()
            persistCurrentDrawing()
            return
        }

        let totalPages = basePages + currentExtraPages
        let insertIndex = afterPageIndex.map { min(max(0, $0 + 1), totalPages) } ?? totalPages
        let insertionBoundaryY = CGFloat(insertIndex) * pageStride
        let shiftedDrawing = shiftDrawing(currentDrawing, by: pageStride, afterY: insertionBoundaryY)

        if insertIndex < totalPages {
            currentDrawing = shiftedDrawing
            previousDrawing = shiftedDrawing
            drawingContinuation.yield(Drawing(value: shiftedDrawing, width: currentWidth))
            drawingUpdateContinuation.yield(shiftedDrawing)
        }

        currentExtraPages += 1
        yieldBackground()
        persistCurrentDrawing(drawing: shiftedDrawing)
    }

    func promptDeletePage() {
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
        guard !currentDrawing.strokes.isEmpty else { return }

        var newStrokes: [PKStroke] = []
        var newIndices: [Int] = []
        for (idx, stroke) in currentDrawing.strokes.enumerated() {
            let pageIdx = (idx < currentStrokePageIndices.count) ? currentStrokePageIndices[idx] : -1
            if pageIdx == page {
                // drop
            } else {
                newStrokes.append(stroke)
                if pageIdx >= 0 { newIndices.append(pageIdx) }
            }
        }

        let newDrawing = PKDrawing(strokes: newStrokes)
        currentDrawing = newDrawing
        currentStrokePageIndices = newIndices
        drawingContinuation.yield(Drawing(value: newDrawing, width: currentWidth))
        persistCurrentDrawing(drawing: newDrawing)
    }

    func deleteInkObjectsForVisiblePage() {
        guard let visible = visiblePageProvider?() else { return }
        deleteInkObjects(onPage: visible)
    }

    func deleteExtraPage(at index: Int?) {
        guard currentExtraPages > 0 else { return }

        let pageHeight = normalizedPageHeight()
        let pageStride = pageHeight + JotBackgroundView.pageSpacing
        let basePages: Int = currentPdfData.flatMap { PDFDocument(data: $0)?.pageCount } ?? 1

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
            currentExtraPages = currentPdfInsertedPageSlots.count
        } else {
            let totalPages = max(1, basePages + currentExtraPages)
            deleteIndex = index.map { min(max(0, $0), totalPages - 1) } ?? (totalPages - 1)
            currentExtraPages = max(0, currentExtraPages - 1)
        }

        schedulePageTrashSave(deleteIndex: deleteIndex, pageStride: pageStride)

        let (newDrawing, newIndices) = shiftedDrawingAfterPageDeletion(deleteIndex: deleteIndex, pageStride: pageStride)
        currentDrawing = newDrawing
        currentStrokePageIndices = newIndices
        drawingContinuation.yield(Drawing(value: newDrawing, width: currentWidth))
        yieldBackground()
        persistCurrentDrawing(drawing: newDrawing)
    }
}

// MARK: - Private Helpers

private extension EditJotViewModel {

    /// Returns the page height in the same rotation-aware coordinate system used
    /// by `PDFLoadService`, so page operations and the visible PDF stay aligned.
    /// The aspect ratio is cached when `currentPdfData` changes; this method is
    /// called after every newly committed ink stroke and must stay allocation-free.
    func normalizedPageHeight() -> CGFloat {
        let aspectRatio = cachedPDFPageAspectRatio ?? (4.0 / 3.0)
        let height = currentWidth * aspectRatio
        return height.isFinite && height > 0 ? height : currentWidth * (4.0 / 3.0)
    }

    /// Page boxes do not depend on PDF painting or transparency masks. Read
    /// their geometry directly once instead of constructing the sanitized,
    /// render-ready document for every PencilKit stroke.
    func cacheCurrentPDFPageAspectRatio() {
        guard let data = currentPdfData else {
            cachedPDFPageAspectRatio = nil
            return
        }

        let fallback = CGFloat(4.0 / 3.0)
        cachedPDFPageAspectRatio = fallback
        guard
            let provider = CGDataProvider(data: data as CFData),
            let document = CGPDFDocument(provider),
            document.isUnlocked,
            let page = document.page(at: 1)
        else { return }

        let bounds = PDFPageRenderer.displayBounds(for: page)
        guard bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }
        let aspectRatio = bounds.height / bounds.width
        if aspectRatio.isFinite, aspectRatio > 0 {
            cachedPDFPageAspectRatio = aspectRatio
        }
    }

    func schedulePageTrashSave(deleteIndex: Int, pageStride: CGFloat) {
        let startY = CGFloat(deleteIndex) * pageStride
        let endY = CGFloat(deleteIndex + 1) * pageStride
        let strokes = currentDrawing.strokes.filter {
            $0.renderBounds.minY < endY && $0.renderBounds.maxY > startY
        }
        let pageName = "Page \(deleteIndex + 1) from \(jotFileInfo.name)"
        let width = currentWidth
        let pageDeletion = TrashService.PageDeletionInfo(
            sourceJotPath: jotFileInfo.url.path,
            deletedPageIndex: deleteIndex,
            pageStride: pageStride
        )
        Task { [weak self] in
            guard let self else { return }
            try? await repository.saveDeletedPageToTrash(
                strokes: strokes,
                pageStartY: startY,
                width: width,
                pageName: pageName,
                pageDeletion: pageDeletion
            )
        }
    }

    func shiftedDrawingAfterPageDeletion(
        deleteIndex: Int,
        pageStride: CGFloat
    ) -> (drawing: PKDrawing, indices: [Int]) {
        let deletedPageStartY = CGFloat(deleteIndex) * pageStride
        let shiftThreshold = CGFloat(deleteIndex + 1) * pageStride

        var newIndices: [Int] = []
        var transformedStrokes: [PKStroke] = []
        for (idx, stroke) in currentDrawing.strokes.enumerated() {
            let pageIdx = (idx < currentStrokePageIndices.count)
                ? currentStrokePageIndices[idx]
                : Int(floor(stroke.renderBounds.midY / pageStride))
            if stroke.renderBounds.minY >= shiftThreshold {
                let transform = stroke.transform.translatedBy(x: 0, y: -pageStride)
                let shifted = PKStroke(ink: stroke.ink, path: stroke.path, transform: transform, mask: stroke.mask)
                transformedStrokes.append(shifted)
                newIndices.append(max(0, pageIdx - 1))
            } else if stroke.renderBounds.maxY <= deletedPageStartY {
                transformedStrokes.append(stroke)
                newIndices.append(pageIdx)
            }
        }
        return (PKDrawing(strokes: transformedStrokes), newIndices)
    }

    func shiftDrawing(_ drawing: PKDrawing, by offsetY: CGFloat, afterY thresholdY: CGFloat) -> PKDrawing {
        guard !drawing.strokes.isEmpty, offsetY != 0 else { return drawing }

        let translatedStrokes = drawing.strokes.map { stroke in
            guard stroke.renderBounds.minY >= thresholdY else { return stroke }
            let translatedTransform = stroke.transform.translatedBy(x: 0, y: offsetY)
            return PKStroke(ink: stroke.ink, path: stroke.path, transform: translatedTransform, mask: stroke.mask)
        }

        return PKDrawing(strokes: translatedStrokes)
    }

    func persistCurrentDrawing(drawing: PKDrawing? = nil) {
        let drawingToPersist = drawing ?? currentDrawing
        Task { [weak self] in
            guard let self else { return }
            do {
                try await repository.writeContent(
                    jotFileInfo: jotFileInfo,
                    drawing: drawingToPersist,
                    pdfData: currentPdfData,
                    extraPages: currentExtraPages,
                    pdfInsertedPageSlots: currentPdfInsertedPageSlots,
                    strokePageIndices: currentStrokePageIndices
                )
            } catch {
                logger.error("Failed to save extra page: \(error)")
            }
        }
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

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

@MainActor
final class EditJotViewModel {

    struct Drawing: Sendable {
        let value: PKDrawing
        let width: CGFloat
    }

    enum Background: Sendable {
        case ruled(extraPages: Int)
        case pdf(data: Data, extraPages: Int)
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
        onImportPDF: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.coordinator?.showPDFPicker { @MainActor [weak self] data in
                    guard let self else { return }
                    if let data {
                        self.importPDF(data: data)
                    } else {
                        self.coordinator?.showInfoAlert(
                            title: L10n.EditJot.PDF.Error.importFailed,
                            message: ""
                        )
                    }
                }
            }
        },
        onAddPage: { [weak self] in
            Task { @MainActor [weak self] in
                self?.addPage()
            }
        }
    )

    var title: String {
        jotFileInfo.name
    }

    let drawing: AsyncStream<Drawing>
    private let drawingContinuation: AsyncStream<Drawing>.Continuation

    let background: AsyncStream<Background>
    private let backgroundContinuation: AsyncStream<Background>.Continuation

    let isEditing: AsyncStream<Bool?>
    private let isEditingContinuation: AsyncStream<Bool?>.Continuation

    let showsBackButton: AsyncStream<Bool>
    private let showsBackButtonContinuation: AsyncStream<Bool>.Continuation

    private var drawingUpdateTask: Task<Void, Never>?
    private let drawingUpdateContinuation: AsyncStream<PKDrawing>.Continuation

    private var loadingTask: Task<Void, Never>?

    private var currentPdfData: Data?
    private var currentExtraPages: Int = 0
    private var currentPdfInsertedPageSlots: [Int] = []
    private var currentDrawing: PKDrawing = PKDrawing()
    private var currentStrokePageIndices: [Int] = []

    private let jotFileInfo: JotFile.Info
    private let repository: EditJotRepositoryProtocol
    private weak var coordinator: EditJotCoordinatorProtocol?
    private let menuConfigurationFactory: JotMenuConfigurationFactory
    private let logger: LoggerProtocol

    init(
        jotFileInfo: JotFile.Info,
        repository: EditJotRepositoryProtocol,
        coordinator: EditJotCoordinatorProtocol,
        menuConfigurationFactory: JotMenuConfigurationFactory,
        logger: LoggerProtocol
    ) {
        self.jotFileInfo = jotFileInfo
        self.coordinator = coordinator
        self.repository = repository
        self.menuConfigurationFactory = menuConfigurationFactory
        self.logger = logger
        (isEditing, isEditingContinuation) = AsyncStream.makeStream(
            of: Bool?.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        (drawing, drawingContinuation) = AsyncStream.makeStream(
            of: Drawing.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        (background, backgroundContinuation) = AsyncStream.makeStream(
            of: Background.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        (showsBackButton, showsBackButtonContinuation) = AsyncStream.makeStream(
            of: Bool.self,
            bufferingPolicy: .bufferingNewest(1)
        )

        #if targetEnvironment(macCatalyst)
        isEditingContinuation.yield(nil)
        #else
        isEditingContinuation.yield(true)
        #endif

        let (drawingUpdate, drawingUpdateContinuation) = AsyncStream.makeStream(
            of: PKDrawing.self,
            bufferingPolicy: .bufferingNewest(1)
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
                    case .keepAll:
                        self?.coordinator?.goBack()
                    case let .keep(jotFileInfo):
                        self?.coordinator?.openJot(jotFileInfo: jotFileInfo)
                    }
                }
            }
        } else {
            loadingTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let content = try await repository.readContent(jotFileInfo: jotFileInfo)
                    currentPdfData = content.pdfData
                    currentExtraPages = content.extraPages
                    currentDrawing = content.drawing
                    drawingContinuation.yield(Drawing(value: content.drawing, width: content.width))
                    yieldBackground()
                } catch {
                    logger.error("Failed to read drawing: \(error)")
                }
            }
        }
    }

    func didTapToggleEditingButton(isEditing: Bool) {
        isEditingContinuation.yield(!isEditing)
    }

    func didChangeDrawing(_ drawing: PKDrawing) {
        currentDrawing = drawing
        drawingUpdateContinuation.yield(drawing)
    }

    func didTapBackButton() {
        if let jotFileVersions = repository.getConflictingVersions(jotFileInfo: jotFileInfo) {
            coordinator?.showJotConflictPage(
                jotFileInfo: jotFileInfo,
                jotFileVersions: jotFileVersions
            ) { [weak self] (_: JotConflictResult) in
                Task { @MainActor in
                    self?.coordinator?.goBack()
                }
            }
        } else {
            coordinator?.goBack()
        }
    }

    func importPDF(data: Data) {
        currentPdfData = data
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

    func addPage() {
        currentExtraPages += 1
        yieldBackground()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await repository.writeContent(
                    jotFileInfo: jotFileInfo,
                    drawing: currentDrawing,
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

    // MARK: - Private

    private func yieldBackground() {
        if let data = currentPdfData {
            backgroundContinuation.yield(.pdf(data: data, extraPages: currentExtraPages))
        } else {
            backgroundContinuation.yield(.ruled(extraPages: currentExtraPages))
        }
    }

    private func didTapDuplicateJot(jotFileInfo: JotFile.Info) {
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

    deinit {
        drawingUpdateTask?.cancel()
    }
}

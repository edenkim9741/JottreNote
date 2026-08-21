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

import UIKit

@MainActor
final class JotsViewModel: PageViewModel, PageSelectableViewModel {

    var title: String? {
        switch location {
        case .root:
            #if targetEnvironment(macCatalyst)
            nil
            #else
            L10n.App.title
            #endif
        case let .directory(directoryLocation):
            directoryLocation.name
        }
    }

    let titleUpdates: AsyncStream<String?>
    private let titleUpdatesContinuation: AsyncStream<String?>.Continuation

    let leftNavigationItems: AsyncStream<[PageNavigationItem]>
    private let leftNavigationItemsContinuation: AsyncStream<[PageNavigationItem]>.Continuation

    let rightNavigationItems: AsyncStream<[PageNavigationItem]>
    private let rightNavigationItemsContinuation: AsyncStream<[PageNavigationItem]>.Continuation

    let items: AsyncStream<[PageCellItem]>
    private let itemsContinuation: AsyncStream<[PageCellItem]>.Continuation

    let selectionState: AsyncStream<PageSelectionState>
    private let selectionStateContinuation: AsyncStream<PageSelectionState>.Continuation

    let actions = [PageCallToActionView.ActionConfiguration]()

    private var itemsTask: Task<Void, Never>?
    private var sortOrderTask: Task<Void, Never>?
    private weak var coordinator: JotsCoordinatorProtocol?
    private let repository: JotsRepositoryProtocol
    private let menuConfigurationFactory: JotMenuConfigurationFactory
    private let logger: LoggerProtocol
    private let location: JotsLocation
    private let defaultsService: DefaultsServiceProtocol

    private var currentItems: [JotsItem] = []
    private var currentSelection = Set<AnyHashable>()
    private var isSelecting = false
    private var sortSymbolName = "clock"

    init(
        coordinator: JotsCoordinatorProtocol,
        repository: JotsRepositoryProtocol,
        menuConfigurationFactory: JotMenuConfigurationFactory,
        logger: LoggerProtocol,
        defaultsService: DefaultsServiceProtocol,
        location: JotsLocation = .root
    ) {
        self.coordinator = coordinator
        self.repository = repository
        self.menuConfigurationFactory = menuConfigurationFactory
        self.logger = logger
        self.location = location
        self.defaultsService = defaultsService

        (titleUpdates, titleUpdatesContinuation) = AsyncStream.makeStream(
            of: String?.self, bufferingPolicy: .bufferingNewest(1)
        )
        (items, itemsContinuation) = AsyncStream.makeStream(
            of: [PageCellItem].self, bufferingPolicy: .bufferingNewest(1)
        )
        (selectionState, selectionStateContinuation) = AsyncStream.makeStream(
            of: PageSelectionState.self, bufferingPolicy: .bufferingNewest(1)
        )
        (leftNavigationItems, leftNavigationItemsContinuation) = AsyncStream.makeStream(
            of: [PageNavigationItem].self, bufferingPolicy: .bufferingNewest(1)
        )
        (rightNavigationItems, rightNavigationItemsContinuation) = AsyncStream.makeStream(
            of: [PageNavigationItem].self, bufferingPolicy: .bufferingNewest(1)
        )

        let sortOrderValues = defaultsService.getValueStream(DefaultsKey<Int>("jots.sortOrder"))
        sortOrderTask = Task { @MainActor [weak self] in
            for await value in sortOrderValues {
                guard let self else { return }
                self.sortSymbolName = (value ?? 0) == 0 ? "clock" : "textformat"
                self.publishNavigationItems()
            }
        }

        // Start loading immediately so data is ready by the time the view appears,
        // overlapping with the navigation push animation rather than waiting for viewDidLoad.
        let itemUpdates = repository.getItems(location: location)
        itemsTask = Task { [weak self, logger] in
            do {
                for try await items in itemUpdates {
                    guard let self else { return }
                    self.handleItems(items)
                }
            } catch {
                guard !(error is CancellationError) else { return }
                logger.error("Failed to observe jots items: \(error)")
            }
        }

        publishLeftNavigationItems()
        publishSelectionState()
        publishNavigationItems()
    }

    func didLoad() { }

    private func handleItems(_ items: [JotsItem]) {
        currentItems = items

        if items.isEmpty {
            currentSelection.removeAll()
            isSelecting = false
            itemsContinuation.yield([.jotsEmptyState(title: L10n.Jots.Empty.title)])
            publishSelectionState()
            publishNavigationItems()
            return
        }

        let supportsMultipleScenes = repository.supportsMultipleScenes()
        let gridSizing: PageCellSizingStrategy = .adaptiveGrid(
            minColumns: 2, maxColumns: 8, minItemWidth: 160, maxItemWidth: 200,
            columnSpacing: DesignTokens.Spacing.md, rowSpacing: DesignTokens.Spacing.md,
            aspectRatio: CGSize(width: 7, height: 8)
        )

        let folderSizing: PageCellSizingStrategy = .fullWidth(
            estimatedHeight: 52,
            rowSpacing: DesignTokens.Spacing.sm
        )

        itemsContinuation.yield(items.map { item in
            switch item {
            case let .folder(folder):
                return makeFolderItem(folder: folder, sizing: folderSizing)
            case let .jot(jotFileInfo):
                return makeJotItem(
                    jotFileInfo: jotFileInfo,
                    sizing: gridSizing,
                    supportsMultipleScenes: supportsMultipleScenes
                )
            }
        })

        let validSelection = Set(items.compactMap { item -> AnyHashable? in
            guard case let .jot(jotFileInfo) = item else { return nil }
            return AnyHashable(jotFileInfo)
        })
        currentSelection = currentSelection.intersection(validSelection)
        publishSelectionState()
        publishNavigationItems()
    }

    private func makeFolderItem(folder: FolderBusinessModel, sizing: PageCellSizingStrategy) -> PageCellItem {
        .folder(
            folder: folder,
            sizing: sizing,
            onOpen: { [weak coordinator] in Task { @MainActor in coordinator?.openFolder(folder: folder) } },
            onRename: { [weak self] in Task { @MainActor in self?.promptRenameFolder(folder) } },
            onDelete: { [weak self] in Task { @MainActor in self?.promptDeleteFolder(folder) } }
        )
    }

    private func makeJotItem(
        jotFileInfo: JotFile.Info,
        sizing: PageCellSizingStrategy,
        supportsMultipleScenes: Bool
    ) -> PageCellItem {
        let jot = JotBusinessModel(jotFileInfo: jotFileInfo)
        return .jot(
            jot: jot,
            jotMenuConfigurations: makeMenuConfigurations(
                jotFileInfo: jotFileInfo,
                supportsMultipleScenes: supportsMultipleScenes
            ),
            sizing: sizing,
            repository: repository,
            onAction: { [weak coordinator] in
                Task { @MainActor in coordinator?.openJot(jotFileInfo: jotFileInfo, prefersNewWindow: false) }
            },
            onSelect: { [weak self] in
                Task { @MainActor in
                    self?.didTapSelectButton()
                    self?.didToggleSelection(for: jotFileInfo)
                }
            }
        )
    }

    private func publishLeftNavigationItems() {
        if case .root = location {
            leftNavigationItemsContinuation.yield([
                .symbol(systemImageName: "gear") { [weak coordinator] in
                    Task { @MainActor in coordinator?.openSettings() }
                },
                .symbol(systemImageName: "trash") { [weak coordinator] in
                    Task { @MainActor in coordinator?.openTrash() }
                }
            ])
        } else {
            leftNavigationItemsContinuation.yield([
                .symbol(systemImageName: "house") { [weak coordinator] in
                    Task { @MainActor in coordinator?.openRoot() }
                }
            ])
        }
    }

    private func publishNavigationItems() {
        if isSelecting {
            let count = currentSelection.count
            titleUpdatesContinuation.yield(
                count == 0
                    ? String(localized: "jots.selection.title.none", defaultValue: "Select Items")
                    : String(format: String(localized: "jots.selection.title.count", defaultValue: "%d Selected"), count)
            )
            leftNavigationItemsContinuation.yield([
                .text(title: L10n.Action.cancel) { [weak self] in
                    Task { @MainActor in self?.didTapCancelSelectionButton() }
                }
            ])
            rightNavigationItemsContinuation.yield([
                .symbol(systemImageName: "folder") { [weak self] in
                    Task { @MainActor in self?.didTapMoveSelectedButton() }
                },
                .symbol(systemImageName: "trash") { [weak self] in
                    Task { @MainActor in self?.didTapDeleteSelectedButton() }
                }
            ])
            return
        }

        titleUpdatesContinuation.yield(title)
        publishLeftNavigationItems()

        var buttons: [PageNavigationItem] = []

        if !currentItems.isEmpty {
            #if !targetEnvironment(macCatalyst)
            buttons.append(
                .symbol(systemImageName: sortSymbolName) { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        let current = self.defaultsService.getValue(DefaultsKey<Int>.init("jots.sortOrder")) ?? 0
                        let next = (current == 0) ? 1 : 0
                        self.defaultsService.set(DefaultsKey<Int>.init("jots.sortOrder"), value: next)
                    }
                }
            )
            #endif

            buttons.append(
                .text(title: L10n.Action.select) { [weak self] in
                    Task { @MainActor in self?.didTapSelectButton() }
                }
            )
        }

        #if !targetEnvironment(macCatalyst)
        buttons.append(
            .symbol(systemImageName: "folder.badge.plus") { [weak self] in
                Task { @MainActor in self?.didTapCreateFolder() }
            }
        )
        #endif

        buttons.append(
            .text(title: L10n.Action.create) { [weak self] in
                Task { @MainActor in self?.coordinator?.openCreateJot(location: self?.location ?? .root) }
            }
        )

        rightNavigationItemsContinuation.yield(buttons)
    }

    private func publishSelectionState() {
        selectionStateContinuation.yield(
            PageSelectionState(isSelecting: isSelecting, selectedItemIDs: currentSelection)
        )
    }

    private func selectedJotFileInfos() -> [JotFile.Info] {
        currentItems.compactMap { item in
            guard case let .jot(jotFileInfo) = item else { return nil }
            return currentSelection.contains(AnyHashable(jotFileInfo)) ? jotFileInfo : nil
        }
    }

    private func clearSelection() {
        currentSelection.removeAll()
        isSelecting = false
        publishSelectionState()
        publishNavigationItems()
    }

    private func promptRenameFolder(_ folder: FolderBusinessModel) {
        coordinator?.showTextInputAlert(
            title: L10n.Jots.Folder.Rename.title,
            message: nil,
            placeholder: L10n.Jots.Folder.Rename.placeholder,
            initialValue: folder.name
        ) { [weak self] newName in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try repository.renameFolder(folder: folder, newName: newName) } catch {
                    coordinator?.showInfoAlert(
                        title: L10n.Jots.Folder.Error.generic,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func promptDeleteFolder(_ folder: FolderBusinessModel) {
        coordinator?.showConfirmAlert(
            title: L10n.Jots.Folder.Delete.title(folder.name),
            message: L10n.Jots.Folder.Delete.message,
            confirmTitle: L10n.Action.delete,
            isDestructive: true
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try repository.deleteFolder(folder: folder) } catch {
                    coordinator?.showInfoAlert(
                        title: L10n.Jots.Folder.Error.generic,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func didTapCreateFolder() {
        coordinator?.showTextInputAlert(
            title: L10n.Jots.Folder.Create.title,
            message: nil,
            placeholder: L10n.Jots.Folder.Create.placeholder,
            initialValue: nil
        ) { [weak self] name in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await repository.createFolder(name: name, location: location) } catch {
                    coordinator?.showInfoAlert(
                        title: L10n.Jots.Folder.Error.generic,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    deinit {
        itemsTask?.cancel()
        sortOrderTask?.cancel()
        titleUpdatesContinuation.finish()
        leftNavigationItemsContinuation.finish()
        rightNavigationItemsContinuation.finish()
        itemsContinuation.finish()
        selectionStateContinuation.finish()
    }
}

// MARK: - PageSelectableViewModel

extension JotsViewModel {

    func didTapSelectButton() {
        guard !currentItems.isEmpty else { return }
        isSelecting = true
        publishSelectionState()
        publishNavigationItems()
    }

    func didTapCancelSelectionButton() {
        clearSelection()
    }

    func canSelectItem(_ item: PageCellItem) -> Bool {
        item.cellType == JotCell.self
    }

    func didToggleSelection(for jotFileInfo: JotFile.Info) {
        let itemID = AnyHashable(jotFileInfo)
        if currentSelection.contains(itemID) {
            currentSelection.remove(itemID)
        } else {
            currentSelection.insert(itemID)
            isSelecting = true
        }
        publishSelectionState()
        publishNavigationItems()
    }

    func didTapMoveSelectedButton() {
        guard !currentSelection.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let folders = try await repository.listFolders()
                coordinator?.showFolderSelectionAlert(
                    title: String(localized: "jots.selection.move.title", defaultValue: "Move To Folder"),
                    message: nil,
                    folders: folders
                ) { [weak self] folder in
                    Task { @MainActor in
                        await self?.moveSelectedJots(to: folder)
                    }
                }
            } catch {
                coordinator?.showInfoAlert(
                    title: String(localized: "jots.selection.error.generic", defaultValue: "An error occurred."),
                    message: error.localizedDescription
                )
            }
        }
    }

    func didTapDeleteSelectedButton() {
        guard !currentSelection.isEmpty else { return }
        let count = currentSelection.count
        coordinator?.showConfirmAlert(
            title: String(localized: "jots.selection.delete.title", defaultValue: "Delete Selected Items?"),
            message: String(localized: "jots.selection.delete.message", defaultValue: "This will delete \(count) selected notes."),
            confirmTitle: L10n.Action.delete,
            isDestructive: true
        ) { [weak self] in
            Task { @MainActor in
                await self?.deleteSelectedJots()
            }
        }
    }
}

// MARK: - Selection Operations

private extension JotsViewModel {

    func moveSelectedJots(to destinationFolder: FolderBusinessModel?) async {
        let selected = selectedJotFileInfos()
        guard !selected.isEmpty else { return }
        do {
            for jotFileInfo in selected {
                try await repository.moveJot(jotFileInfo: jotFileInfo, destinationFolder: destinationFolder)
            }
            clearSelection()
        } catch {
            coordinator?.showInfoAlert(
                title: String(localized: "jots.selection.error.generic", defaultValue: "An error occurred."),
                message: error.localizedDescription
            )
        }
    }

    func deleteSelectedJots() async {
        let selected = selectedJotFileInfos()
        guard !selected.isEmpty else { return }
        do {
            for jotFileInfo in selected {
                try await repository.deleteJot(jotFileInfo: jotFileInfo)
            }
            clearSelection()
        } catch {
            coordinator?.showInfoAlert(
                title: String(localized: "jots.selection.error.generic", defaultValue: "An error occurred."),
                message: error.localizedDescription
            )
        }
    }
}

// MARK: - Menu Configurations

private extension JotsViewModel {

    func makeMenuConfigurations(jotFileInfo: JotFile.Info, supportsMultipleScenes: Bool) -> JotMenuConfigurations {
        menuConfigurationFactory.make(
            onShare: { [weak coordinator] format, configurePopoverAnchor in
                Task { @MainActor in
                    coordinator?.showShareJot(
                        jotFileInfo: jotFileInfo,
                        format: format,
                        configurePopoverAnchor: configurePopoverAnchor
                    )
                }
            },
            onRename: { [weak coordinator] in
                Task { @MainActor in coordinator?.showRenameAlert(jotFileInfo: jotFileInfo) }
            },
            onDuplicate: { [weak self] in
                Task { @MainActor in self?.didTapDuplicateJot(jotFileInfo: jotFileInfo) }
            },
            onDelete: { [weak coordinator] in
                Task { @MainActor in coordinator?.openDeleteJot(jotFileInfo: jotFileInfo) }
            },
            onShowInFiles: { [weak coordinator] in
                Task { @MainActor in coordinator?.showInFiles(jotFileInfo: jotFileInfo) }
            },
            onOpenInNewWindow: supportsMultipleScenes
                ? { @Sendable [weak coordinator] in
                    Task { @MainActor in coordinator?.openJot(jotFileInfo: jotFileInfo, prefersNewWindow: true) }
                }
                : nil
        )
    }

    func didTapDuplicateJot(jotFileInfo: JotFile.Info) {
        do {
            _ = try repository.duplicate(jotFileInfo: jotFileInfo)
        } catch {
            coordinator?.showInfoAlert(
                title: L10n.Jots.Duplicate.Error.generic(jotFileInfo.name),
                message: error.localizedDescription
            )
        }
    }
}

// MARK: - PageDragDropViewModel

extension JotsViewModel: PageDragDropViewModel {

    func canDrag(cellItem: PageCellItem) -> Bool {
        cellItem.cellType == JotCell.self || cellItem.cellType == FolderCell.self
    }

    func canAddToDragSession(cellItem: PageCellItem, existingItems: [PageCellItem]) -> Bool {
        guard cellItem.cellType == JotCell.self else { return false }
        return !existingItems.contains { $0.cellType == FolderCell.self }
    }

    func shouldSpringLoad(draggedCellItems: [PageCellItem], onto targetCellItem: PageCellItem) -> Bool {
        guard targetCellItem.cellType == FolderCell.self else { return false }
        return draggedCellItems.allSatisfy { $0.cellType == JotCell.self }
    }

    func springLoad(onto targetCellItem: PageCellItem) {
        guard let targetFolder = folder(for: targetCellItem) else { return }
        coordinator?.openFolder(folder: targetFolder)
    }

    func canDrop(draggedCellItems: [PageCellItem], onto targetCellItem: PageCellItem) -> Bool {
        guard let targetFolder = folder(for: targetCellItem) else { return false }
        return draggedCellItems.allSatisfy { canDropSingle($0, onto: targetFolder) }
    }

    func performDrop(draggedCellItems: [PageCellItem], onto targetCellItem: PageCellItem) {
        guard let targetFolder = folder(for: targetCellItem) else { return }
        for item in draggedCellItems {
            performDropSingle(item, onto: targetFolder)
        }
    }

    func canDropIntoCurrentDirectory(draggedCellItems: [PageCellItem]) -> Bool {
        guard !draggedCellItems.isEmpty else { return false }
        return draggedCellItems.allSatisfy { cellItem in
            let alreadyHere = currentItems.contains { jotsItem in
                switch jotsItem {
                case let .jot(info): return (cellItem.id as? JotFile.Info) == info
                case let .folder(folder): return (cellItem.id as? URL) == folder.url
                }
            }
            if alreadyHere { return false }
            // Prevent moving a folder into its own descendant using URL directly
            if let folderURL = cellItem.id as? URL,
               case let .directory(dir) = location,
               dir.url.path.hasPrefix(folderURL.path + "/") {
                return false
            }
            return true
        }
    }

    func performDropIntoCurrentDirectory(draggedCellItems: [PageCellItem]) {
        let destinationFolder: FolderBusinessModel?
        if case let .directory(dir) = location {
            destinationFolder = FolderBusinessModel(url: dir.url, name: dir.name, modificationDate: nil)
        } else {
            destinationFolder = nil
        }
        for cellItem in draggedCellItems {
            if let jotInfo = cellItem.id as? JotFile.Info {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await repository.moveJot(jotFileInfo: jotInfo, destinationFolder: destinationFolder)
                    } catch {
                        coordinator?.showInfoAlert(
                            title: String(localized: "jots.selection.error.generic", defaultValue: "An error occurred."),
                            message: error.localizedDescription
                        )
                    }
                }
            } else if let folderURL = cellItem.id as? URL {
                let draggedFolder = FolderBusinessModel(
                    url: folderURL, name: folderURL.lastPathComponent, modificationDate: nil
                )
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await repository.moveFolder(folder: draggedFolder, destinationFolder: destinationFolder)
                    } catch {
                        coordinator?.showInfoAlert(
                            title: L10n.Jots.Folder.Error.generic,
                            message: error.localizedDescription
                        )
                    }
                }
            }
        }
    }

    private func canDropSingle(_ cellItem: PageCellItem, onto targetFolder: FolderBusinessModel) -> Bool {
        if let draggedFolder = folder(for: cellItem) {
            guard draggedFolder.url != targetFolder.url else { return false }
            guard !targetFolder.url.path.hasPrefix(draggedFolder.url.path + "/") else { return false }
            return true
        }
        if let jotInfo = cellItem.id as? JotFile.Info {
            return jotInfo.url.deletingLastPathComponent() != targetFolder.url
        }
        return false
    }

    private func performDropSingle(_ cellItem: PageCellItem, onto targetFolder: FolderBusinessModel) {
        if let jotInfo = cellItem.id as? JotFile.Info {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await repository.moveJot(jotFileInfo: jotInfo, destinationFolder: targetFolder)
                } catch {
                    coordinator?.showInfoAlert(
                        title: String(localized: "jots.selection.error.generic", defaultValue: "An error occurred."),
                        message: error.localizedDescription
                    )
                }
            }
        } else if let draggedFolder = folder(for: cellItem) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await repository.moveFolder(folder: draggedFolder, destinationFolder: targetFolder)
                } catch {
                    coordinator?.showInfoAlert(
                        title: L10n.Jots.Folder.Error.generic,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func folder(for cellItem: PageCellItem) -> FolderBusinessModel? {
        guard let url = cellItem.id as? URL else { return nil }
        return currentItems.compactMap { item -> FolderBusinessModel? in
            guard case let .folder(folder) = item, folder.url == url else { return nil }
            return folder
        }.first
    }
}

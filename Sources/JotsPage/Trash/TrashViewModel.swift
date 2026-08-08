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
protocol TrashCoordinatorProtocol: AnyObject {

    func showInfoAlert(title: String, message: String)

    func showConfirmAlert(
        title: String,
        message: String?,
        confirmTitle: String,
        isDestructive: Bool,
        onConfirm: @escaping @Sendable () -> Void
    )
}

@MainActor
final class TrashViewModel: PageViewModel, PageSelectableViewModel {

    var title: String? { nil }

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

    private var observeTask: Task<Void, Never>?
    private weak var coordinator: TrashCoordinatorProtocol?
    private let repository: TrashRepositoryProtocol

    private var currentItems: [TrashJotInfo] = []
    private var currentSelection = Set<AnyHashable>()
    private var isSelecting = false

    private let gridSizing: PageCellSizingStrategy = .adaptiveGrid(
        minColumns: 2, maxColumns: 8, minItemWidth: 160, maxItemWidth: 200,
        columnSpacing: DesignTokens.Spacing.md, rowSpacing: DesignTokens.Spacing.md,
        aspectRatio: CGSize(width: 7, height: 8)
    )

    init(coordinator: TrashCoordinatorProtocol, repository: TrashRepositoryProtocol) {
        self.coordinator = coordinator
        self.repository = repository

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

        observeTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await trashItems in repository.observeTrashedJots() {
                    handleItems(trashItems)
                }
            } catch {
                // Silently stop on error; the user can navigate back
            }
        }

        publishTitle()
        publishLeftNavigationItems()
        publishRightNavigationItems()
        publishSelectionState()
    }

    func didLoad() { }

    private func handleItems(_ trashItems: [TrashJotInfo]) {
        currentItems = trashItems

        if trashItems.isEmpty {
            currentSelection.removeAll()
            isSelecting = false
            itemsContinuation.yield([
                .jotsEmptyState(title: String(localized: "trash.empty.title", defaultValue: "Trash Is Empty"))
            ])
            publishSelectionState()
            publishRightNavigationItems()
            return
        }

        itemsContinuation.yield(trashItems.map { makeTrashJotItem(info: $0) })

        let validURLs = Set(trashItems.map { AnyHashable($0.trashURL) })
        currentSelection = currentSelection.intersection(validURLs)
        publishSelectionState()
        publishRightNavigationItems()
    }

    private func makeTrashJotItem(info: TrashJotInfo) -> PageCellItem {
        let jotFileInfo = JotFile.Info(url: info.trashURL, name: info.name, modificationDate: info.modificationDate)
        let jot = JotBusinessModel(jotFileInfo: jotFileInfo)
        return .jot(
            jot: jot,
            jotMenuConfigurations: makeMenuConfigurations(info: info),
            sizing: gridSizing,
            repository: repository,
            onAction: { },
            onSelect: { [weak self] in Task { @MainActor in self?.handleToggleSelection(for: info) } }
        )
    }

    private func makeMenuConfigurations(info: TrashJotInfo) -> JotMenuConfigurations {
        JotMenuConfigurations { [weak self] _ in [
            .action(JotMenuConfiguration.Action(
                title: String(localized: "trash.action.restore", defaultValue: "Restore"),
                systemImageName: "arrow.uturn.backward"
            ) { Task { @MainActor in await self?.restore(info: info) } }),
            .action(JotMenuConfiguration.Action(
                title: String(localized: "trash.action.delete_permanently", defaultValue: "Delete Permanently"),
                systemImageName: "trash",
                isDestructive: true
            ) { Task { @MainActor in self?.promptPermanentDelete(info: info) } })
        ]}
    }

    private func publishTitle() {
        titleUpdatesContinuation.yield(
            isSelecting
                ? (currentSelection.isEmpty
                    ? String(localized: "jots.selection.title.none", defaultValue: "Select Items")
                    : String(format: String(localized: "jots.selection.title.count", defaultValue: "%d Selected"),
                             currentSelection.count))
                : String(localized: "trash.title", defaultValue: "Trash")
        )
    }

    private func publishLeftNavigationItems() {
        if isSelecting {
            leftNavigationItemsContinuation.yield([
                .text(title: L10n.Action.cancel) { [weak self] in
                    Task { @MainActor in self?.didTapCancelSelectionButton() }
                }
            ])
        } else {
            leftNavigationItemsContinuation.yield([])
        }
    }

    private func publishRightNavigationItems() {
        if isSelecting {
            rightNavigationItemsContinuation.yield([
                .symbol(systemImageName: "arrow.uturn.backward") { [weak self] in
                    Task { @MainActor in await self?.restoreSelected() }
                },
                .symbol(systemImageName: "trash") { [weak self] in
                    Task { @MainActor in self?.promptPermanentDeleteSelected() }
                }
            ])
            return
        }

        var buttons: [PageNavigationItem] = []
        if !currentItems.isEmpty {
            buttons.append(
                .text(title: String(localized: "trash.action.empty", defaultValue: "Empty Trash")) { [weak self] in
                    Task { @MainActor in self?.promptEmptyTrash() }
                }
            )
            buttons.append(
                .text(title: L10n.Action.select) { [weak self] in
                    Task { @MainActor in self?.didTapSelectButton() }
                }
            )
        }
        rightNavigationItemsContinuation.yield(buttons)
    }

    private func publishSelectionState() {
        selectionStateContinuation.yield(
            PageSelectionState(isSelecting: isSelecting, selectedItemIDs: currentSelection)
        )
    }

    private func clearSelection() {
        currentSelection.removeAll()
        isSelecting = false
        publishTitle()
        publishLeftNavigationItems()
        publishRightNavigationItems()
        publishSelectionState()
    }

    private func selectedInfos() -> [TrashJotInfo] {
        currentItems.filter { currentSelection.contains(AnyHashable($0.trashURL)) }
    }

    private func handleToggleSelection(for info: TrashJotInfo) {
        let key = AnyHashable(info.trashURL)
        if currentSelection.contains(key) {
            currentSelection.remove(key)
        } else {
            currentSelection.insert(key)
            isSelecting = true
        }
        publishTitle()
        publishLeftNavigationItems()
        publishRightNavigationItems()
        publishSelectionState()
    }

    private func restore(info: TrashJotInfo) async {
        do {
            try await repository.restore(info: info)
        } catch {
            coordinator?.showInfoAlert(
                title: String(localized: "trash.error.restore", defaultValue: "Could Not Restore"),
                message: error.localizedDescription
            )
        }
    }

    private func promptPermanentDelete(info: TrashJotInfo) {
        coordinator?.showConfirmAlert(
            title: String(localized: "trash.delete.permanent.title", defaultValue: "Delete Permanently?"),
            message: String(localized: "trash.delete.permanent.message",
                            defaultValue: "This cannot be undone."),
            confirmTitle: L10n.Action.delete,
            isDestructive: true
        ) { [weak self] in
            Task { @MainActor in self?.permanentlyDelete(info: info) }
        }
    }

    private func permanentlyDelete(info: TrashJotInfo) {
        do {
            try repository.permanentlyDelete(info: info)
        } catch {
            coordinator?.showInfoAlert(
                title: String(localized: "trash.error.delete", defaultValue: "Could Not Delete"),
                message: error.localizedDescription
            )
        }
    }

    private func promptEmptyTrash() {
        coordinator?.showConfirmAlert(
            title: String(localized: "trash.empty.confirm.title", defaultValue: "Empty Trash?"),
            message: String(localized: "trash.empty.confirm.message",
                            defaultValue: "All items in Trash will be permanently deleted."),
            confirmTitle: String(localized: "trash.action.empty", defaultValue: "Empty Trash"),
            isDestructive: true
        ) { [weak self] in
            Task { @MainActor in await self?.emptyTrash() }
        }
    }

    private func emptyTrash() async {
        do {
            try await repository.emptyTrash()
        } catch {
            coordinator?.showInfoAlert(
                title: String(localized: "trash.error.empty", defaultValue: "Could Not Empty Trash"),
                message: error.localizedDescription
            )
        }
    }

    private func restoreSelected() async {
        let selected = selectedInfos()
        guard !selected.isEmpty else { return }
        for info in selected {
            do {
                try await repository.restore(info: info)
            } catch {
                coordinator?.showInfoAlert(
                    title: String(localized: "trash.error.restore", defaultValue: "Could Not Restore"),
                    message: error.localizedDescription
                )
                return
            }
        }
        clearSelection()
    }

    private func promptPermanentDeleteSelected() {
        let count = currentSelection.count
        guard count > 0 else { return }
        coordinator?.showConfirmAlert(
            title: String(localized: "trash.delete.permanent.title", defaultValue: "Delete Permanently?"),
            message: String(
                format: String(localized: "trash.delete.permanent.count.message",
                               defaultValue: "This will permanently delete %d items. This cannot be undone."),
                count
            ),
            confirmTitle: L10n.Action.delete,
            isDestructive: true
        ) { [weak self] in
            Task { @MainActor in self?.permanentDeleteSelected() }
        }
    }

    private func permanentDeleteSelected() {
        let selected = selectedInfos()
        for info in selected {
            do {
                try repository.permanentlyDelete(info: info)
            } catch {
                coordinator?.showInfoAlert(
                    title: String(localized: "trash.error.delete", defaultValue: "Could Not Delete"),
                    message: error.localizedDescription
                )
                return
            }
        }
        clearSelection()
    }

    deinit {
        observeTask?.cancel()
    }
}

// MARK: - PageSelectableViewModel

extension TrashViewModel {

    func didTapSelectButton() {
        guard !currentItems.isEmpty else { return }
        isSelecting = true
        publishTitle()
        publishLeftNavigationItems()
        publishRightNavigationItems()
        publishSelectionState()
    }

    func didTapCancelSelectionButton() {
        clearSelection()
    }

    func canSelectItem(_ item: PageCellItem) -> Bool {
        item.cellType == JotCell.self
    }

    func didToggleSelection(for jotFileInfo: JotFile.Info) {
        guard let info = currentItems.first(where: { $0.trashURL == jotFileInfo.url }) else { return }
        handleToggleSelection(for: info)
    }
}

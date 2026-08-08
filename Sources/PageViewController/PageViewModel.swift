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

struct PageSelectionState: @unchecked Sendable {
    let isSelecting: Bool
    let selectedItemIDs: Set<AnyHashable>
}

@MainActor
protocol PageSelectableViewModel: AnyObject {
    var selectionState: AsyncStream<PageSelectionState> { get }

    func didTapSelectButton()
    func didTapCancelSelectionButton()
    func didTapMoveSelectedButton()
    func didTapDeleteSelectedButton()

    func canSelectItem(_ item: PageCellItem) -> Bool
    func didToggleSelection(for jotFileInfo: JotFile.Info)
}

extension PageSelectableViewModel {
    func didTapSelectButton() { }
    func didTapCancelSelectionButton() { }
    func didTapMoveSelectedButton() { }
    func didTapDeleteSelectedButton() { }
    func canSelectItem(_ item: PageCellItem) -> Bool { false }
    func didToggleSelection(for jotFileInfo: JotFile.Info) { }
}

@MainActor
protocol PageViewModel: AnyObject {
    var title: String? { get }
    var titleUpdates: AsyncStream<String?> { get }
    var leftNavigationItems: AsyncStream<[PageNavigationItem]> { get }
    var rightNavigationItems: AsyncStream<[PageNavigationItem]> { get }

    var items: AsyncStream<[PageCellItem]> { get }
    var actions: [PageCallToActionView.ActionConfiguration] { get }

    func didLoad()
}

@MainActor
protocol PageDragDropViewModel: AnyObject {
    func canDrag(cellItem: PageCellItem) -> Bool
    func canAddToDragSession(cellItem: PageCellItem, existingItems: [PageCellItem]) -> Bool
    func canDrop(draggedCellItems: [PageCellItem], onto targetCellItem: PageCellItem) -> Bool
    func performDrop(draggedCellItems: [PageCellItem], onto targetCellItem: PageCellItem)
    func shouldSpringLoad(draggedCellItems: [PageCellItem], onto targetCellItem: PageCellItem) -> Bool
    func springLoad(onto targetCellItem: PageCellItem)
    func canDropIntoCurrentDirectory(draggedCellItems: [PageCellItem]) -> Bool
    func performDropIntoCurrentDirectory(draggedCellItems: [PageCellItem])
}

extension PageDragDropViewModel {
    func canAddToDragSession(cellItem: PageCellItem, existingItems: [PageCellItem]) -> Bool { canDrag(cellItem: cellItem) }
    func shouldSpringLoad(draggedCellItems: [PageCellItem], onto targetCellItem: PageCellItem) -> Bool { false }
    func springLoad(onto targetCellItem: PageCellItem) { }
    func canDropIntoCurrentDirectory(draggedCellItems: [PageCellItem]) -> Bool { false }
    func performDropIntoCurrentDirectory(draggedCellItems: [PageCellItem]) { }
}

extension PageViewModel {
    var title: String? { nil }

    var titleUpdates: AsyncStream<String?> { AsyncStream { $0.finish() } }

    var actions: [PageCallToActionView.ActionConfiguration] { [] }

    var leftNavigationItems: AsyncStream<[PageNavigationItem]> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    var rightNavigationItems: AsyncStream<[PageNavigationItem]> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func didLoad() {
        /* no-op */
    }
}

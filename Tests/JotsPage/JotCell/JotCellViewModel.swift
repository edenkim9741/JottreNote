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

final class JotCellViewModel: PageCellViewModel {

    enum Preview {
        case thumbnail
        case cloudImage
        case loadingIndicator
    }

    let name: String
    let preview: Preview
    let jotMenuConfigurations: JotMenuConfigurations
    let onAction: @Sendable () -> Void
    let onSelect: @Sendable () -> Void

    private let jot: JotBusinessModel
    private let repository: JotsRepositoryProtocol

    init(
        jot: JotBusinessModel,
        jotMenuConfigurations: JotMenuConfigurations,
        repository: JotsRepositoryProtocol,
        onAction: @Sendable @escaping () -> Void,
        onSelect: @Sendable @escaping () -> Void
    ) {
        self.name = jot.name
        self.preview =
            if jot.isDownloading {
                .loadingIndicator
            } else if jot.isDownloaded {
                .thumbnail
            } else {
                .cloudImage
            }
        self.jotMenuConfigurations = jotMenuConfigurations
        self.onAction = onAction
        self.onSelect = onSelect
        self.jot = jot
        self.repository = repository
    }

    func handle(action: PageCellAction) {
        switch action {
        case .tap: onAction()
        }
    }

    func getPreviewImage(
        userInterfaceStyle: UIUserInterfaceStyle,
        displayScale: CGFloat
    ) async -> UIImage? {
        await repository.getPreviewImage(
            jotFileInfo: jot.toJotFileInfo(),
            userInterfaceStyle: userInterfaceStyle,
            displayScale: displayScale
        )
    }

    func handleContextMenuConfiguration(
        point: CGPoint,
        sourceView: UIView
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(
            identifier: nil,
            previewProvider: nil
        ) { [weak self, weak sourceView] _ in
            guard let self else {
                return nil
            }
            let selectAction = UIAction(
                title: L10n.Action.select,
                image: UIImage(systemName: "checkmark.circle")
            ) { _ in
                self.onSelect()
            }
            let menu = UIMenu.make(
                jotMenuConfigurations: self.jotMenuConfigurations.make(popoverAnchorProvider: {
                    [weak sourceView] in
                    guard let sourceView else {
                        return nil
                    }
                    return { popover in
                        popover.sourceView = sourceView
                        popover.sourceRect = CGRect(origin: point, size: .zero)
                    }
                })
            )
            return UIMenu(title: "", children: [selectAction] + menu.children)
        }
    }
}

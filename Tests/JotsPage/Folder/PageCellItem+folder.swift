import UIKit

extension PageCellItem {

    static func folder(
        folder: FolderBusinessModel,
        sizing: PageCellSizingStrategy,
        onOpen: @escaping @Sendable () -> Void,
        onRename: @escaping @Sendable () -> Void,
        onDelete: @escaping @Sendable () -> Void
    ) -> PageCellItem {
        PageCellItem(
            id: folder.url,
            cellType: FolderCell.self,
            sizing: sizing,
            viewModel: FolderCellViewModel(
                folder: folder,
                onOpen: onOpen,
                onRename: onRename,
                onDelete: onDelete
            )
        )
    }
}

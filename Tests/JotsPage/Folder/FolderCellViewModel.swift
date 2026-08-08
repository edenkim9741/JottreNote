import UIKit

final class FolderCellViewModel: PageCellViewModel {

    let name: String

    private let folder: FolderBusinessModel
    private let onOpen: @Sendable () -> Void
    private let onRename: @Sendable () -> Void
    private let onDelete: @Sendable () -> Void

    init(
        folder: FolderBusinessModel,
        onOpen: @Sendable @escaping () -> Void,
        onRename: @Sendable @escaping () -> Void,
        onDelete: @Sendable @escaping () -> Void
    ) {
        self.folder = folder
        self.name = folder.name
        self.onOpen = onOpen
        self.onRename = onRename
        self.onDelete = onDelete
    }

    func handle(action: PageCellAction) {
        switch action {
        case .tap:
            onOpen()
        }
    }

    func handleContextMenuConfiguration(
        point: CGPoint,
        sourceView: UIView
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else {
                return nil
            }
            let rename = UIAction(
                title: L10n.Action.rename,
                image: UIImage(systemName: "pencil")
            ) { _ in
                self.onRename()
            }
            let delete = UIAction(
                title: L10n.Action.delete,
                image: UIImage(systemName: "trash"),
                attributes: [.destructive]
            ) { _ in
                self.onDelete()
            }
            return UIMenu(title: "", children: [rename, delete])
        }
    }
}

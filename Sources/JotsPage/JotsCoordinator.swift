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

protocol JotsCoordinatorProtocol: NavigationCoordinator {

    func openSettings()
    func openCreateJot(location: JotsLocation)
    func openJot(jotFileInfo: JotFile.Info, prefersNewWindow: Bool)
    func openFolder(folder: FolderBusinessModel)
    func showShareJot(
        jotFileInfo: JotFile.Info,
        format: ShareFormat,
        configurePopoverAnchor: PopoverAnchor?
    )
    func showRenameAlert(jotFileInfo: JotFile.Info)
    func openDeleteJot(jotFileInfo: JotFile.Info)
    func showInfoAlert(title: String, message: String)
    func showInFiles(jotFileInfo: JotFile.Info)
    func openRoot()

    func openTrash()

    func showTextInputAlert(
        title: String,
        message: String?,
        placeholder: String,
        initialValue: String?,
        onSubmit: @escaping @Sendable (_ text: String) -> Void
    )

    func showFolderSelectionAlert(
        title: String,
        message: String?,
        folders: [FolderBusinessModel],
        onSelect: @escaping @Sendable (_ folder: FolderBusinessModel?) -> Void
    )

    func showConfirmAlert(
        title: String,
        message: String?,
        confirmTitle: String,
        isDestructive: Bool,
        onConfirm: @escaping @Sendable () -> Void
    )
}

@MainActor
final class JotsCoordinator: NavigationCoordinator, JotsCoordinatorProtocol {

    private var retainedInfoAlertCoordinator: Coordinator?
    private var retainedShareJotCoordinator: Coordinator?
    private var retainedRenameJotCoordinator: Coordinator?
    private var retainedDeleteJotCoordinator: Coordinator?
    private var retainedCreateJotCoordinator: Coordinator?
    private var retainedRevealFileCoordinator: Coordinator?
    private var retainedSettingsCoordinator: Coordinator?
    private var retainedJotsViewController: UIViewController?
    private var retainedTrashViewController: UIViewController?

    private lazy var childCoordinators: [NavigationCoordinator] = [
        editJotCoordinatorFactory.make(navigation: navigation)
    ]

    private let navigation: Navigation
    private let jotsViewControllerFactory: JotsViewControllerFactoryProtocol
    private let settingsCoordinatorFactory: SettingsCoordinatorFactoryProtocol
    private let editJotCoordinatorFactory: EditJotCoordinatorFactoryProtocol
    private let createJotCoordinatorFactory: CreateJotCoordinatorFactoryProtocol
    private let deleteJotCoordinatorFactory: DeleteJotCoordinatorFactoryProtocol
    private let renameJotCoordinatorFactory: RenameJotCoordinatorFactoryProtocol
    private let shareJotCoordinatorFactory: ShareJotCoordinatorFactoryProtocol
    private let revealFileCoordinatorFactory: RevealFileCoordinatorFactoryProtocol
    private let trashViewControllerFactory: TrashViewControllerFactoryProtocol

    init(
        navigation: Navigation,
        jotsViewControllerFactory: JotsViewControllerFactoryProtocol,
        settingsCoordinatorFactory: SettingsCoordinatorFactoryProtocol,
        editJotCoordinatorFactory: EditJotCoordinatorFactoryProtocol,
        createJotCoordinatorFactory: CreateJotCoordinatorFactoryProtocol,
        deleteJotCoordinatorFactory: DeleteJotCoordinatorFactoryProtocol,
        renameJotCoordinatorFactory: RenameJotCoordinatorFactoryProtocol,
        shareJotCoordinatorFactory: ShareJotCoordinatorFactoryProtocol,
        revealFileCoordinatorFactory: RevealFileCoordinatorFactoryProtocol,
        trashViewControllerFactory: TrashViewControllerFactoryProtocol
    ) {
        self.navigation = navigation
        self.jotsViewControllerFactory = jotsViewControllerFactory
        self.settingsCoordinatorFactory = settingsCoordinatorFactory
        self.editJotCoordinatorFactory = editJotCoordinatorFactory
        self.createJotCoordinatorFactory = createJotCoordinatorFactory
        self.deleteJotCoordinatorFactory = deleteJotCoordinatorFactory
        self.renameJotCoordinatorFactory = renameJotCoordinatorFactory
        self.shareJotCoordinatorFactory = shareJotCoordinatorFactory
        self.revealFileCoordinatorFactory = revealFileCoordinatorFactory
        self.trashViewControllerFactory = trashViewControllerFactory
    }

    func shouldHandle(url: URL) -> Bool { true }

    func handle(url: URL) -> [UIViewController] {
        var viewControllers: [UIViewController]

        if let retainedJotsViewController {
            viewControllers = [retainedJotsViewController]
        } else {
            let jotsViewController = jotsViewControllerFactory.make(coordinator: self, location: .root)
            self.retainedJotsViewController = jotsViewController
            viewControllers = [jotsViewController]
        }

        if TrashURL(url: url) != nil {
            let trashVC = trashViewControllerFactory.make(coordinator: self)
            retainedTrashViewController = trashVC
            viewControllers.append(trashVC)
            return viewControllers
        }

        if let folderURL = JotsFolderURL(url: url) {
            viewControllers.append(contentsOf: makeFolderViewControllers(folderURL: folderURL))
            return viewControllers
        }

        if let childCoordinator = childCoordinators.first(where: { $0.shouldHandle(url: url) }) {
            if let editJotURL = EditJotURL(url: url) {
                viewControllers.append(contentsOf: makeFolderViewControllersForFile(fileURL: editJotURL.fileURL))
            }
            viewControllers.append(contentsOf: childCoordinator.handle(url: url))
        }

        return viewControllers
    }

    private func makeFolderViewControllersForFile(fileURL: URL) -> [UIViewController] {
        let parentFolder = fileURL.deletingLastPathComponent()
        guard parentFolder.lastPathComponent != "Documents" else { return [] }
        return makeFolderViewControllers(folderURL: JotsFolderURL(folderURL: parentFolder))
    }

    private func makeFolderViewControllers(folderURL: JotsFolderURL) -> [UIViewController] {
        var chain = [URL]()
        var pointer = folderURL.folderURL
        while pointer.lastPathComponent != "Documents" {
            chain.append(pointer)
            pointer = pointer.deletingLastPathComponent()
        }
        chain.reverse()

        return chain.map { url in
            jotsViewControllerFactory.make(
                coordinator: self,
                location: .directory(.init(url: url, name: url.lastPathComponent))
            )
        }
    }

    func openSettings() {
        let coordinator = settingsCoordinatorFactory.make(navigation: navigation)
        retainedSettingsCoordinator = coordinator
        coordinator.onEnd = { [weak self] in self?.retainedSettingsCoordinator = nil }
        coordinator.start()
    }

    func openCreateJot(location: JotsLocation) {
        let directory: CreateJotCoordinatorFactory.Directory?
        if case let .directory(directoryLocation) = location {
            directory = CreateJotCoordinatorFactory.Directory(url: directoryLocation.url)
        } else {
            directory = nil
        }
        let coordinator = createJotCoordinatorFactory.make(navigation: navigation, directory: directory, pdfData: nil)
        retainedCreateJotCoordinator = coordinator
        coordinator.onEnd = { [weak self] in self?.retainedCreateJotCoordinator = nil }
        coordinator.start()
    }

    func openFolder(folder: FolderBusinessModel) {
        navigation.open(url: JotsFolderURL(folderURL: folder.url))
    }

    func openJot(jotFileInfo: JotFile.Info, prefersNewWindow: Bool) {
        let url = EditJotURL(jotFileInfo: jotFileInfo)
        #if targetEnvironment(macCatalyst)
        navigation.openScene(url: url)
        #else
        if prefersNewWindow {
            navigation.openScene(url: url)
        } else {
            navigation.open(url: url)
        }
        #endif
    }

    func showShareJot(
        jotFileInfo: JotFile.Info,
        format: ShareFormat,
        configurePopoverAnchor: PopoverAnchor?
    ) {
        let coordinator = shareJotCoordinatorFactory.make(
            jotFileInfo: jotFileInfo,
            format: format,
            navigation: navigation,
            configurePopoverAnchor: configurePopoverAnchor
        )
        retainedShareJotCoordinator = coordinator
        coordinator.onEnd = { [weak self] in self?.retainedShareJotCoordinator = nil }
        coordinator.start()
    }

    func showRenameAlert(jotFileInfo: JotFile.Info) {
        let coordinator = renameJotCoordinatorFactory.make(
            jotFileInfo: jotFileInfo, navigation: navigation
        ) { _ in }
        retainedRenameJotCoordinator = coordinator
        coordinator.onEnd = { [weak self] in self?.retainedRenameJotCoordinator = nil }
        coordinator.start()
    }

    func openDeleteJot(jotFileInfo: JotFile.Info) {
        let coordinator = deleteJotCoordinatorFactory.make(jotFileInfo: jotFileInfo, navigation: navigation)
        retainedDeleteJotCoordinator = coordinator
        coordinator.onEnd = { [weak self] in self?.retainedDeleteJotCoordinator = nil }
        coordinator.start()
    }

    func showInfoAlert(title: String, message: String) {
        let coordinator = InfoAlertCoordinator(navigation: navigation, title: title, message: message)
        retainedInfoAlertCoordinator = coordinator
        coordinator.onEnd = { [weak self] in self?.retainedInfoAlertCoordinator = nil }
        coordinator.start()
    }

    func openRoot() {
        navigation.open(url: JotsPageURL())
    }

    func openTrash() {
        navigation.open(url: TrashURL().toURL())
    }

    func showInFiles(jotFileInfo: JotFile.Info) {
        let coordinator = revealFileCoordinatorFactory.make(jotFileInfo: jotFileInfo, navigation: navigation)
        retainedRevealFileCoordinator = coordinator
        coordinator.onEnd = { [weak self] in self?.retainedRevealFileCoordinator = nil }
        coordinator.start()
    }

    func showTextInputAlert(
        title: String,
        message: String?,
        placeholder: String,
        initialValue: String?,
        onSubmit: @escaping @Sendable (String) -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = placeholder
            field.text = initialValue
            field.autocapitalizationType = .sentences
            field.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: L10n.Action.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: L10n.Action.done, style: .default) { _ in
                guard let text = alert.textFields?.first?.text else { return }
                onSubmit(text)
            }
        )
        navigation.present(alert, animated: true)
    }

    func showFolderSelectionAlert(
        title: String,
        message: String?,
        folders: [FolderBusinessModel],
        onSelect: @escaping @Sendable (FolderBusinessModel?) -> Void
    ) {
        let picker = FolderPickerViewController(
            title: title,
            folders: folders,
            onConfirm: { folder in onSelect(folder) }
        )
        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .formSheet
        navigation.present(nav, animated: true)
    }

    func showConfirmAlert(
        title: String,
        message: String?,
        confirmTitle: String,
        isDestructive: Bool,
        onConfirm: @escaping @Sendable () -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Action.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: confirmTitle, style: isDestructive ? .destructive : .default) { _ in
                onConfirm()
            }
        )
        navigation.present(alert, animated: true)
    }
}

extension JotsCoordinator: TrashCoordinatorProtocol { }

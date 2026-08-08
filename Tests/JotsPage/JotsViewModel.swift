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
final class JotsViewModel: PageViewModel {

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

    let leftNavigationItems: AsyncStream<[PageNavigationItem]>
    private let leftNavigationItemsContinuation: AsyncStream<[PageNavigationItem]>.Continuation

    let rightNavigationItems: AsyncStream<[PageNavigationItem]>
    private let rightNavigationItemsContinuation: AsyncStream<[PageNavigationItem]>.Continuation

    let items: AsyncStream<[PageCellItem]>
    private let itemsContinuation: AsyncStream<[PageCellItem]>.Continuation

    let actions = [PageCallToActionView.ActionConfiguration]()

    private var itemsTask: Task<Void, Never>?

    private weak var coordinator: JotsCoordinatorProtocol?

    private let repository: JotsRepositoryProtocol
    private let menuConfigurationFactory: JotMenuConfigurationFactory
    private let logger: LoggerProtocol
    private let location: JotsLocation

    init(
        coordinator: JotsCoordinatorProtocol,
        repository: JotsRepositoryProtocol,
        menuConfigurationFactory: JotMenuConfigurationFactory,
        logger: LoggerProtocol,
        location: JotsLocation = .root
    ) {
        self.coordinator = coordinator
        self.repository = repository
        self.menuConfigurationFactory = menuConfigurationFactory
        self.logger = logger
        self.location = location

        (items, itemsContinuation) = AsyncStream.makeStream(
            of: [PageCellItem].self,
            bufferingPolicy: .bufferingNewest(1)
        )
        (leftNavigationItems, leftNavigationItemsContinuation) = AsyncStream.makeStream(
            of: [PageNavigationItem].self,
            bufferingPolicy: .bufferingNewest(1)
        )

        var leftNavigationItems = [PageNavigationItem]()

        if case .root = location {
            leftNavigationItems.append(
                .symbol(
                    systemImageName: "gear"
                ) { [weak coordinator] in
                    Task { @MainActor in
                        coordinator?.openSettings()
                    }
                }
            )

            if repository.shouldShowEnableICloudButton() {
                leftNavigationItems.append(
                    .symbol(
                        systemImageName: "icloud.slash"
                    ) { [weak coordinator] in
                        Task { @MainActor in
                            coordinator?.openEnableCloudPage()
                        }
                    }
                )
            }
        }

        leftNavigationItemsContinuation.yield(leftNavigationItems)

        (rightNavigationItems, rightNavigationItemsContinuation) = AsyncStream.makeStream(
            of: [PageNavigationItem].self,
            bufferingPolicy: .bufferingNewest(1)
        )
        #if !targetEnvironment(macCatalyst)
        rightNavigationItemsContinuation.yield(
            [
                .symbol(systemImageName: "folder.badge.plus") { [weak self] in
                    Task { @MainActor in
                        self?.didTapCreateFolder()
                    }
                },
                .text(title: L10n.Action.create) { [weak self] in
                    Task { @MainActor in
                        self?.coordinator?.openCreateJot(location: self?.location ?? .root)
                    }
                },
            ]
        )
        #endif
    }

    func didLoad() {
        itemsTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                for try await items in repository.getItems(location: location) {
                    handleItems(items)
                }
            } catch {
                logger.error("Failed to observe jots items: \(error)")
            }
        }
    }

    private func handleItems(_ items: [JotsItem]) {
        guard !items.isEmpty else {
            itemsContinuation.yield([
                .jotsEmptyState(title: L10n.Jots.Empty.title)
            ])
            return
        }
        let supportsMultipleScenes = repository.supportsMultipleScenes()

        let gridSizing: PageCellSizingStrategy = .adaptiveGrid(
            minColumns: 2,
            maxColumns: 8,
            minItemWidth: 160,
            maxItemWidth: 200,
            columnSpacing: DesignTokens.Spacing.md,
            rowSpacing: DesignTokens.Spacing.md,
            aspectRatio: CGSize(width: 7, height: 8)
        )

        itemsContinuation.yield(
            items.map { item in
                switch item {
                case let .folder(folder):
                    return .folder(
                        folder: folder,
                        sizing: gridSizing,
                        onOpen: { [weak coordinator] in
                            Task { @MainActor in
                                coordinator?.openFolder(folder: folder)
                            }
                        },
                        onRename: { [weak self] in
                            Task { @MainActor in
                                self?.promptRenameFolder(folder)
                            }
                        },
                        onDelete: { [weak self] in
                            Task { @MainActor in
                                self?.promptDeleteFolder(folder)
                            }
                        }
                    )
                case let .jot(jotFileInfo):
                    let jot = JotBusinessModel(jotFileInfo: jotFileInfo)
                    return .jot(
                        jot: jot,
                        jotMenuConfigurations: makeMenuConfigurations(
                            jotFileInfo: jotFileInfo,
                            supportsMultipleScenes: supportsMultipleScenes
                        ),
                        sizing: gridSizing,
                        repository: repository,
                        onAction: { [weak coordinator, weak self] in
                            Task { @MainActor in
                                guard let self else {
                                    return
                                }
                                if jot.isDownloaded {
                                    coordinator?.openJot(
                                        jotFileInfo: jotFileInfo,
                                        prefersNewWindow: !self.repository.isIPadOS()
                                    )
                                } else {
                                    do {
                                        try self.repository.download(jotFileInfo: jotFileInfo)
                                    } catch {
                                        coordinator?.showInfoAlert(
                                            title: L10n.Jots.Download.Error.generic(jotFileInfo.name),
                                            message: error.localizedDescription
                                        )
                                    }
                                }
                            }
                        },
                        onSelect: { [weak coordinator, weak self] in
                            Task { @MainActor in
                                guard let self else {
                                    return
                                }
                                coordinator?.showInfoAlert(
                                    title: L10n.Action.select,
                                    message: jot.name
                                )
                            }
                        }
                    )
                }
            }
        )
    }

    private func didTapCreateFolder() {
        coordinator?.showTextInputAlert(
            title: L10n.Jots.Folder.Create.title,
            message: nil,
            placeholder: L10n.Jots.Folder.Create.placeholder,
            initialValue: nil
        ) { [weak self] name in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                do {
                    try await repository.createFolder(name: name, location: location)
                } catch {
                    coordinator?.showInfoAlert(title: L10n.Jots.Folder.Error.generic, message: error.localizedDescription)
                }
            }
        }
    }

    private func promptRenameFolder(_ folder: FolderBusinessModel) {
        coordinator?.showTextInputAlert(
            title: L10n.Jots.Folder.Rename.title,
            message: nil,
            placeholder: L10n.Jots.Folder.Rename.placeholder,
            initialValue: folder.name
        ) { [weak self] newName in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                do {
                    try repository.renameFolder(folder: folder, newName: newName)
                } catch {
                    coordinator?.showInfoAlert(title: L10n.Jots.Folder.Error.generic, message: error.localizedDescription)
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
                guard let self else {
                    return
                }
                do {
                    try repository.deleteFolder(folder: folder)
                } catch {
                    coordinator?.showInfoAlert(title: L10n.Jots.Folder.Error.generic, message: error.localizedDescription)
                }
            }
        }
    }

    private func makeMenuConfigurations(
        jotFileInfo: JotFile.Info,
        supportsMultipleScenes: Bool
    ) -> JotMenuConfigurations {
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
                Task { @MainActor in
                    coordinator?.showRenameAlert(jotFileInfo: jotFileInfo)
                }
            },
            onDuplicate: { [weak self] in
                Task { @MainActor in
                    self?.didTapDuplicateJot(jotFileInfo: jotFileInfo)
                }
            },
            onDelete: { [weak coordinator] in
                Task { @MainActor in
                    coordinator?.openDeleteJot(jotFileInfo: jotFileInfo)
                }
            },
            onShowInFiles: { [weak coordinator] in
                Task { @MainActor in
                    coordinator?.showInFiles(jotFileInfo: jotFileInfo)
                }
            },
            onOpenInNewWindow: supportsMultipleScenes
                ? { @Sendable [weak coordinator] in
                    Task { @MainActor in
                        coordinator?.openJot(
                            jotFileInfo: jotFileInfo,
                            prefersNewWindow: true
                        )
                    }
                } : nil
        )
    }

    private func didTapDuplicateJot(jotFileInfo: JotFile.Info) {
        do {
            _ = try repository.duplicate(jotFileInfo: jotFileInfo)
        } catch {
            coordinator?.showInfoAlert(
                title: L10n.Jots.Duplicate.Error.generic(jotFileInfo.name),
                message: error.localizedDescription
            )
        }
    }

    deinit {
        itemsTask?.cancel()
    }
}

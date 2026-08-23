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
final class SettingsViewModel: PageViewModel {

    private enum Constants {
        static let userInterfaceStyleOptions: [UIUserInterfaceStyle] = [.unspecified, .dark, .light]
    }

    var title: String? {
        L10n.Settings.title
    }

    let rightNavigationItems: AsyncStream<[PageNavigationItem]>
    private let rightNavigationItemsContinuation: AsyncStream<[PageNavigationItem]>.Continuation

    let items: AsyncStream<[PageCellItem]>
    private let itemsContinuation: AsyncStream<[PageCellItem]>.Continuation

    private let repository: SettingsRepositoryProtocol
    private weak var coordinator: SettingsCoordinatorProtocol?

    private var loadingTask: Task<Void, Never>?
    private var currentUserInterfaceStyle: UIUserInterfaceStyle = .unspecified
    private var appVersion: String = "-"

    init(
        repository: SettingsRepositoryProtocol,
        coordinator: SettingsCoordinatorProtocol
    ) {
        self.repository = repository
        self.coordinator = coordinator
        (items, itemsContinuation) = AsyncStream.makeStream(
            of: [PageCellItem].self,
            bufferingPolicy: .bufferingNewest(1)
        )
        (rightNavigationItems, rightNavigationItemsContinuation) = AsyncStream.makeStream(
            of: [PageNavigationItem].self,
            bufferingPolicy: .bufferingNewest(1)
        )
        rightNavigationItemsContinuation.yield([
            .symbol(systemImageName: "xmark") { [weak coordinator] in
                Task { @MainActor in coordinator?.dismiss() }
            }
        ])
    }

    func didLoad() {
        appVersion = repository.appVersion()
        loadingTask = Task { [weak self] in
            guard let repository = self?.repository else { return }
            for await userInterfaceStyle in repository.userInterfaceStyle() {
                guard let self else { return }
                currentUserInterfaceStyle = userInterfaceStyle
                refreshItems()
            }
        }
    }

    private func refreshItems() {
        itemsContinuation.yield(makePageItems(userInterfaceStyle: currentUserInterfaceStyle))
    }

    private func makePageItems(userInterfaceStyle: UIUserInterfaceStyle) -> [PageCellItem] {
        var items: [PageCellItem] = [
            .settingsDropdown(
                settingsDropdown: SettingsDropdownBusinessModel(
                    name: L10n.Settings.Appearance.title,
                    current: SettingsDropdownBusinessModel.Option(
                        label: SettingsViewModel.makeLabel(userInterfaceStyle: userInterfaceStyle),
                        value: userInterfaceStyle
                    ),
                    options: Constants.userInterfaceStyleOptions.map { style in
                        SettingsDropdownBusinessModel.Option(
                            label: SettingsViewModel.makeLabel(userInterfaceStyle: style),
                            value: style
                        )
                    }
                ),
                onAction: { [weak self] option in
                    guard let style = option.value as? UIUserInterfaceStyle else { return }
                    self?.repository.updateUserInterfaceStyle(style)
                }
            )
        ]

        items.append(contentsOf: makeWebDAVItems())

        items.append(contentsOf: [
            .settingsExternalLink(
                settingsExternalLink: SettingsExternalLinkBusinessModel(
                    name: L10n.Settings.Github.title,
                    info: nil
                ),
                onAction: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.coordinator?.openExternalLink(url: JottreGithubURL().toURL())
                    }
                }
            ),
            .settingsInfo(
                settingsInfo: SettingsInfoBusinessModel(
                    name: L10n.Settings.Version.title,
                    value: appVersion
                )
            ),
        ])

        return items
    }

    private func makeWebDAVItems() -> [PageCellItem] {
        let url = repository.getWebDAVURL()
        let info = url.flatMap { $0.isEmpty ? nil : $0 } ?? "Not configured"
        return [
            .settingsExternalLink(
                settingsExternalLink: SettingsExternalLinkBusinessModel(
                    name: "WebDAV Backup",
                    info: info
                ),
                onAction: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.showWebDAVSettings()
                    }
                }
            )
        ]
    }

    private func showWebDAVSettings() {
        let initial = WebDAVSettingsViewController.Configuration(
            url: repository.getWebDAVURL() ?? "",
            username: repository.getWebDAVUsername() ?? "",
            password: repository.getWebDAVPassword() ?? "",
            backupIntervalMinutes: repository.getWebDAVBackupIntervalMinutes()
        )
        coordinator?.showWebDAVSettings(
            initial: initial,
            onSave: { [weak self] config in
                self?.repository.setWebDAVURL(config.url)
                self?.repository.setWebDAVUsername(config.username)
                self?.repository.setWebDAVPassword(config.password)
                self?.repository.setWebDAVBackupIntervalMinutes(config.backupIntervalMinutes)
                self?.refreshItems()
            },
            onTest: { [weak self] config in
                await self?.repository.testWebDAVConnection(
                    url: config.url,
                    username: config.username,
                    password: config.password
                ) ?? false
            },
            onBackupAll: { [weak self] in
                self?.repository.backupAllJots() ?? AsyncStream { $0.finish() }
            }
        )
    }

    private static func makeLabel(userInterfaceStyle: UIUserInterfaceStyle) -> String {
        switch userInterfaceStyle {
        case .light:
            L10n.Settings.Appearance.light
        case .dark:
            L10n.Settings.Appearance.dark
        default:
            L10n.Settings.Appearance.system
        }
    }

    deinit {
        loadingTask?.cancel()
        itemsContinuation.finish()
        rightNavigationItemsContinuation.finish()
    }
}

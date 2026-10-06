import UIKit

@MainActor
final class SettingsViewModel: PageViewModel {
    private static let styleOptions: [UIUserInterfaceStyle] = [.unspecified, .dark, .light]
    var title: String? { L10n.Settings.title }
    let rightNavigationItems: AsyncStream<[PageNavigationItem]>
    private let rightContinuation: AsyncStream<[PageNavigationItem]>.Continuation
    let items: AsyncStream<[PageCellItem]>
    private let itemsContinuation: AsyncStream<[PageCellItem]>.Continuation
    private let repository: SettingsRepositoryProtocol
    private weak var coordinator: SettingsCoordinatorProtocol?
    private var loadingTask: Task<Void, Never>?
    private var currentStyle: UIUserInterfaceStyle = .unspecified
    private var appVersion = "-"

    init(repository: SettingsRepositoryProtocol, coordinator: SettingsCoordinatorProtocol) {
        self.repository = repository
        self.coordinator = coordinator
        (items, itemsContinuation) = AsyncStream.makeStream(of: [PageCellItem].self, bufferingPolicy: .bufferingNewest(1))
        (rightNavigationItems, rightContinuation) = AsyncStream.makeStream(of: [PageNavigationItem].self, bufferingPolicy: .bufferingNewest(1))
        rightContinuation.yield([.symbol(systemImageName: "xmark") { [weak coordinator] in
            Task { @MainActor in coordinator?.dismiss() }
        }])
    }

    func didLoad() {
        appVersion = repository.appVersion()
        loadingTask = Task { [weak self] in
            guard let repository = self?.repository else { return }
            for await style in repository.userInterfaceStyle() {
                guard let self else { return }
                currentStyle = style
                refreshItems()
            }
        }
    }

    private func refreshItems() {
        let appearance = PageCellItem.settingsDropdown(
            settingsDropdown: SettingsDropdownBusinessModel(
                name: L10n.Settings.Appearance.title,
                current: .init(label: Self.label(currentStyle), value: currentStyle),
                options: Self.styleOptions.map { .init(label: Self.label($0), value: $0) }
            ),
            onAction: { [weak self] option in
                guard let style = option.value as? UIUserInterfaceStyle else { return }
                self?.repository.updateUserInterfaceStyle(style)
            }
        )
        itemsContinuation.yield([
            appearance,
            .settingsExternalLink(settingsExternalLink: .init(name: L10n.Settings.Github.title, info: nil), onAction: { [weak self] in
                Task { @MainActor in self?.coordinator?.openExternalLink(url: JottreGithubURL().toURL()) }
            }),
            .settingsInfo(settingsInfo: .init(name: L10n.Settings.Version.title, value: appVersion))
        ])
    }

    private static func label(_ style: UIUserInterfaceStyle) -> String {
        switch style {
        case .light: L10n.Settings.Appearance.light
        case .dark: L10n.Settings.Appearance.dark
        default: L10n.Settings.Appearance.system
        }
    }

    deinit {
        loadingTask?.cancel()
        itemsContinuation.finish()
        rightContinuation.finish()
    }
}

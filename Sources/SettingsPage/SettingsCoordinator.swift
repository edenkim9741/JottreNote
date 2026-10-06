import UIKit

protocol SettingsCoordinatorProtocol: Coordinator {
    func openExternalLink(url: URL)
    func dismiss()
}

final class SettingsCoordinator: Coordinator, SettingsCoordinatorProtocol {
    var onEnd: (() -> Void)?
    private let navigation: Navigation
    private let settingsViewControllerFactory: SettingsViewControllerFactoryProtocol

    init(navigation: Navigation, settingsViewControllerFactory: SettingsViewControllerFactoryProtocol) {
        self.navigation = navigation
        self.settingsViewControllerFactory = settingsViewControllerFactory
    }

    func start() {
        let controller = UINavigationController(rootViewController: settingsViewControllerFactory.make(coordinator: self))
        controller.navigationBar.prefersLargeTitles = true
        navigation.present(controller, animated: true)
    }

    func openExternalLink(url: URL) { navigation.openExternal(url: url) }

    func dismiss() {
        navigation.dismiss(animated: true) { [weak self] in
            Task { @MainActor in self?.onEnd?() }
        }
    }
}

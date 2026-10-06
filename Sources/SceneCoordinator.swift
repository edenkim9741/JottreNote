import UIKit

@MainActor
final class SceneCoordinator {
    enum Constants {
        static let activityType = "com.antonlorani.jottre.openJot"
        static let urlKey = "url"
    }

    private let navigation: Navigation
    private let defaultsService: DefaultsServiceProtocol
    private let editJotCoordinatorFactory: EditJotCoordinatorFactoryProtocol
    private let onUpdateUserInterfaceStyle: @Sendable (UIUserInterfaceStyle) -> Void
    private var activeEditCoordinator: NavigationCoordinator?
    private var userInterfaceStyleTask: Task<Void, Never>?
    private var lastActiveURL: URL?

    init(
        navigation: Navigation,
        defaultsService: DefaultsServiceProtocol,
        editJotCoordinatorFactory: EditJotCoordinatorFactoryProtocol,
        onUpdateUserInterfaceStyle: @Sendable @escaping (UIUserInterfaceStyle) -> Void
    ) {
        self.navigation = navigation
        self.defaultsService = defaultsService
        self.editJotCoordinatorFactory = editJotCoordinatorFactory
        self.onUpdateUserInterfaceStyle = onUpdateUserInterfaceStyle
    }

    func start() {
        userInterfaceStyleTask?.cancel()
        let updates = defaultsService.getValueStream(.userInterfaceStyle)
        userInterfaceStyleTask = Task { [onUpdateUserInterfaceStyle] in
            for await value in updates {
                onUpdateUserInterfaceStyle(value.flatMap(UIUserInterfaceStyle.init(rawValue:)) ?? .unspecified)
            }
        }
    }

    func handle(url: URL) -> [UIViewController] {
        let editURL: URL
        if EditJotURL(url: url) != nil {
            editURL = url
        } else if url.isFileURL, url.pathExtension.lowercased() == JotFile.Info.fileExtension {
            let info = JotFile.Info(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                modificationDate: nil
            )
            editURL = EditJotURL(jotFileInfo: info).toURL()
        } else {
            return []
        }
        lastActiveURL = editURL
        let coordinator = editJotCoordinatorFactory.make(navigation: navigation)
        activeEditCoordinator = coordinator
        return coordinator.handle(url: editURL)
    }

    func handleURLs(_ urls: [URL]) {
        guard let jotURL = urls.first(where: {
            $0.isFileURL && $0.pathExtension.lowercased() == JotFile.Info.fileExtension
        }) else { return }
        let info = JotFile.Info(
            url: jotURL,
            name: jotURL.deletingPathExtension().lastPathComponent,
            modificationDate: nil
        )
        navigation.open(url: EditJotURL(jotFileInfo: info))
    }

    func makeStateRestorationActivity() -> NSUserActivity? {
        guard let lastActiveURL else { return nil }
        let activity = NSUserActivity(activityType: Constants.activityType)
        activity.userInfo = [Constants.urlKey: lastActiveURL.absoluteString]
        return activity
    }

    deinit { userInterfaceStyleTask?.cancel() }
}

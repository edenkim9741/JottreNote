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
import SwiftUI

/// Keeps navigation buttons interactive while allowing PencilKit to receive
/// touches through the otherwise empty, transparent navigation-bar area.
final class JottreNavigationBar: UINavigationBar {

    var passesThroughBackgroundTouches = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hitView = super.hitTest(point, with: event) else { return nil }
        guard passesThroughBackgroundTouches else { return hitView }

        var view: UIView? = hitView
        while let current = view, current !== self {
            if current is UIControl || current.accessibilityTraits.contains(.button) {
                return hitView
            }
            view = current.superview
        }
        return nil
    }
}

private struct SceneServices {
    let fileService: FileServiceProtocol
    let externalFileImportService: ExternalFileImportServiceProtocol
    let applicationService: ApplicationServiceProtocol
    let jotFileService: JotFileServiceProtocol
    let jotFileConflictService: JotFileConflictService
    let jotFilePreviewImageService: JotFilePreviewImageServiceProtocol
}

private struct SceneUIFactories {
    let menuConfigurationFactory: JotMenuConfigurationFactory
    let textBarButtonItemFactory: TextBarButtonItemFactory
    let symbolBarButtonItemFactory: SymbolBarButtonItemFactory
}

private struct SceneCoordinatorFactories {
    let deleteJotCoordinatorFactory: DeleteJotCoordinatorFactoryProtocol
    let shareJotCoordinatorFactory: ShareJotCoordinatorFactoryProtocol
    let revealFileCoordinatorFactory: RevealFileCoordinatorFactoryProtocol
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    private static var defaultsService: DefaultsService {
        ZoteroApplicationServices.shared.defaultsService
    }

    #if targetEnvironment(macCatalyst)
    private lazy var appKitPluginService = MacCatalystAppKitPluginService(bundle: .main)
    #endif

    var window: UIWindow?
    private var sceneCoordinator: SceneCoordinator?
    private var zoteroRootViewController: UIViewController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let fileManager = FileManager.default
        let fileService = LocalFileService(fileManager: fileManager)
        let services = makeServices(fileManager: fileManager, fileService: fileService)
        let (textFactory, symbolFactory) = makeBarButtonItemFactories()
        let uiFactories = SceneUIFactories(
            menuConfigurationFactory: JotMenuConfigurationFactory(),
            textBarButtonItemFactory: textFactory,
            symbolBarButtonItemFactory: symbolFactory
        )
        let coordinators = makeCoordinatorFactories(services: services, fileService: fileService)
        let zoteroDocumentSyncService = ZoteroApplicationServices.shared.documentSyncService
        let editJotCoordinatorFactory = makeEditJotCoordinatorFactory(
            services: services,
            uiFactories: uiFactories,
            coordinators: coordinators,
            zoteroDocumentSyncService: zoteroDocumentSyncService
        )
        let navigationController = makeNavigationController()
        let navigation = makeNavigation(
            navigationController: navigationController,
            applicationService: services.applicationService
        )
        self.window = UIWindow(windowScene: windowScene)
        self.window?.rootViewController = navigationController
        let sceneCoordinator = makeSceneCoordinator(
            navigation: navigation,
            editJotCoordinatorFactory: editJotCoordinatorFactory
        )
        self.sceneCoordinator = sceneCoordinator
        sceneCoordinator.start()
        let rootController = UIHostingController(rootView: ZoteroLibraryView(
            cacheStore: ZoteroApplicationServices.shared.cacheStore,
            engine: ZoteroApplicationServices.shared.syncEngine,
            syncProgress: ZoteroApplicationServices.shared.syncProgress,
            defaults: Self.defaultsService,
            onOpenJot: { [navigation] jotInfo in
                navigation.open(url: EditJotURL(jotFileInfo: jotInfo))
            }
        ))
        rootController.title = "Zotero"
        zoteroRootViewController = rootController
        navigationController.viewControllers = [rootController]
        self.window?.makeKeyAndVisible()
        let activityURLString = connectionOptions.userActivities
            .first(where: { $0.activityType == SceneCoordinator.Constants.activityType })?
            .userInfo?[SceneCoordinator.Constants.urlKey] as? String
            ?? session.stateRestorationActivity?.userInfo?[SceneCoordinator.Constants.urlKey] as? String
        let incomingURL = activityURLString.flatMap(URL.init(string:))
            ?? connectionOptions.urlContexts.map(\.url).first(where: {
                $0.isFileURL && $0.pathExtension.lowercased() == JotFile.Info.fileExtension
            })
        if let incomingURL {
            let viewControllers = sceneCoordinator.handle(url: incomingURL)
            guard !viewControllers.isEmpty else { return }
            navigationController.setViewControllers([rootController] + viewControllers, animated: false)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {}

    func sceneWillResignActive(_ scene: UIScene) {}

    func sceneDidDisconnect(_ scene: UIScene) {
        #if targetEnvironment(macCatalyst)
        guard
            UIApplication.shared.connectedScenes.isEmpty,
            let appKitPluginService
        else {
            return
        }
        appKitPluginService.terminate()
        #endif
    }

    func scene(
        _ scene: UIScene,
        openURLContexts URLContexts: Set<UIOpenURLContext>
    ) {
        let urls = Array(URLContexts.map { $0.url })
        sceneCoordinator?.handleURLs(urls)
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        sceneCoordinator?.makeStateRestorationActivity()
    }
}

// MARK: - Private

extension SceneDelegate {

    fileprivate func makeServices(fileManager: FileManager, fileService: LocalFileService) -> SceneServices {
        let jotFileService = JotFileService(fileService: fileService)
        let jotFilePreviewImageService = CachedJotFilePreviewImageService(
            localFileService: fileService,
            jotFilePreviewImageService: JotFilePreviewImageService(jotFileService: jotFileService)
        )
        return SceneServices(
            fileService: fileService,
            externalFileImportService: ExternalFileImportService(),
            applicationService: ApplicationService(application: .shared),
            jotFileService: jotFileService,
            jotFileConflictService: JotFileConflictService(
                fileConflictService: FileConflictService(fileManager: fileManager)
            ),
            jotFilePreviewImageService: jotFilePreviewImageService
        )
    }

    fileprivate func makeCoordinatorFactories(
        services: SceneServices,
        fileService: FileServiceProtocol
    ) -> SceneCoordinatorFactories {
        SceneCoordinatorFactories(
            deleteJotCoordinatorFactory: DeleteJotCoordinatorFactory(
                repository: DeleteJotRepository(
                    jotFileService: services.jotFileService,
                    fileService: fileService,
                    trashService: TrashService()
                )
            ),
            shareJotCoordinatorFactory: ShareJotCoordinatorFactory(
                repository: ShareJotRepository(
                    jotFileService: services.jotFileService,
                    fileService: fileService
                )
            ),
            revealFileCoordinatorFactory: RevealFileCoordinatorFactory(
                applicationService: services.applicationService
            )
        )
    }

    fileprivate func makeSceneCoordinator(
        navigation: Navigation,
        editJotCoordinatorFactory: EditJotCoordinatorFactoryProtocol
    ) -> SceneCoordinator {
        SceneCoordinator(
            navigation: navigation,
            defaultsService: Self.defaultsService,
            editJotCoordinatorFactory: editJotCoordinatorFactory,
            onUpdateUserInterfaceStyle: { [weak self] style in
                Task { @MainActor in self?.window?.overrideUserInterfaceStyle = style }
            }
        )
    }

    fileprivate func makeBarButtonItemFactories() -> (TextBarButtonItemFactory, SymbolBarButtonItemFactory) {
        guard #available(iOS 26, *) else {
            return (IOS18TextBarButtonItemFactory(), IOS18SymbolBarButtonItemFactory())
        }
        return (IOS26TextBarButtonItemFactory(), IOS26SymbolBarButtonItemFactory())
    }

    fileprivate func makeEditJotCoordinatorFactory(
        services: SceneServices,
        uiFactories: SceneUIFactories,
        coordinators: SceneCoordinatorFactories,
        zoteroDocumentSyncService: ZoteroDocumentSyncService
    ) -> EditJotCoordinatorFactory {
        let editJotRepository = EditJotRepository(
            jotFileService: services.jotFileService,
            jotFileConflictService: services.jotFileConflictService,
            fileService: services.fileService,
            trashService: TrashService(),
            zoteroCacheStore: ZoteroApplicationServices.shared.cacheStore,
            defaultsService: Self.defaultsService
        )
        return EditJotCoordinatorFactory(
            repository: editJotRepository,
            externalFileImportService: services.externalFileImportService,
            editJotViewControllerFactory: EditJotViewControllerFactory(
                repository: editJotRepository,
                menuConfigurationFactory: uiFactories.menuConfigurationFactory,
                symbolBarButtonItemFactory: uiFactories.symbolBarButtonItemFactory,
                defaultsService: Self.defaultsService,
                zoteroDocumentSyncService: zoteroDocumentSyncService,
                logger: OSLogLogger(category: "EditJotViewModel")
            ),
            jotConflictCoordinatorFactory: JotConflictCoordinatorFactory(
                jotConflictViewControllerFactory: JotConflictViewControllerFactory(
                    textBarButtonItemFactory: uiFactories.textBarButtonItemFactory,
                    symbolBarButtonItemFactory: uiFactories.symbolBarButtonItemFactory
                ),
                repository: JotConflictRepository(
                    jotFileConflictService: services.jotFileConflictService,
                    jotFilePreviewImageService: services.jotFilePreviewImageService,
                    logger: OSLogLogger(category: "JotConflictRepository")
                )
            ),
            renameJotCoordinatorFactory: RenameJotCoordinatorFactory(
                repository: RenameJotRepository(
                    jotFileService: services.jotFileService
                )
            ),
            deleteJotCoordinatorFactory: coordinators.deleteJotCoordinatorFactory,
            shareJotCoordinatorFactory: coordinators.shareJotCoordinatorFactory,
            revealFileCoordinatorFactory: coordinators.revealFileCoordinatorFactory
        )
    }

    fileprivate func makeNavigation(
        navigationController: UINavigationController,
        applicationService: ApplicationServiceProtocol
    ) -> Navigation {
        Navigation(
            openURLProvider: { [weak self, weak navigationController] url in
                Task { @MainActor in
                    guard let self, let viewControllers = self.sceneCoordinator?.handle(url: url) else { return }
                    let root = self.zoteroRootViewController.map { [$0] } ?? []
                    navigationController?.setViewControllers(root + viewControllers, animated: true)
                }
            },
            openExternalURLProvider: { url in
                Task { @MainActor in
                    guard applicationService.canOpen(url: url) else { return }
                    applicationService.open(url: url)
                }
            },
            openSceneProvider: { _ in },
            presentViewControllerProvider: { [weak navigationController] viewController, animated in
                Task { @MainActor in navigationController?.present(viewController, animated: animated) }
            },
            dismissViewControllerProvider: { [weak navigationController] animated, completion in
                Task { @MainActor in
                    navigationController?.dismiss(animated: animated, completion: completion)
                }
            },
            popViewControllerProvider: { [weak navigationController] animated in
                Task { @MainActor in
                    navigationController?.popViewController(animated: animated)
                }
            },
            getViewControllersProvider: { [weak navigationController] in
                navigationController?.viewControllers ?? []
            }
        )
    }

    fileprivate func makeNavigationController() -> UINavigationController {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()

        let navigationController = UINavigationController(
            navigationBarClass: JottreNavigationBar.self,
            toolbarClass: nil
        )
        navigationController.navigationBar.prefersLargeTitles = true
        navigationController.navigationBar.standardAppearance = appearance
        navigationController.navigationBar.scrollEdgeAppearance = appearance
        navigationController.navigationBar.tintColor = .label
        return navigationController
    }
}

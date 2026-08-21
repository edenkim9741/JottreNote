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
    let deviceService: DeviceServiceProtocol
    let bundleService: BundleServiceProtocol
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

    private static let defaultsService = DefaultsService(userDefaults: .standard)

    #if targetEnvironment(macCatalyst)
    private lazy var appKitPluginService = MacCatalystAppKitPluginService(bundle: .main)
    #endif

    var window: UIWindow?
    private var sceneCoordinator: SceneCoordinator?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if redirectToExistingSceneIfNeeded(scene: scene, session: session, connectionOptions: connectionOptions) {
            return
        }
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
        let webDAVBackupService = WebDAVBackupService(defaultsService: Self.defaultsService)
        let editJotCoordinatorFactory = makeEditJotCoordinatorFactory(
            services: services, uiFactories: uiFactories, coordinators: coordinators,
            webDAVBackupService: webDAVBackupService
        )
        let jotsCoordinatorFactory = makeJotsCoordinatorFactory(
            services: services, uiFactories: uiFactories, coordinators: coordinators,
            editJotCoordinatorFactory: editJotCoordinatorFactory,
            webDAVBackupService: webDAVBackupService
        )
        let rootCoordinatorFactory = RootCoordinatorFactory(jotsCoordinatorFactory: jotsCoordinatorFactory)
        let navigationController = makeNavigationController()
        let navigation = makeNavigation(
            navigationController: navigationController,
            applicationService: services.applicationService
        )
        self.window = UIWindow(windowScene: windowScene)
        self.window?.rootViewController = navigationController
        let sceneCoordinator = makeSceneCoordinator(
            navigation: navigation,
            services: services,
            rootCoordinatorFactory: rootCoordinatorFactory,
            editJotCoordinatorFactory: editJotCoordinatorFactory
        )
        self.sceneCoordinator = sceneCoordinator
        navigationController.viewControllers = sceneCoordinator.handle(
            session: session, connectionOptions: connectionOptions
        )
        self.window?.makeKeyAndVisible()
        let incomingURLs = connectionOptions.urlContexts.map(\.url)
        if incomingURLs.contains(where: {
            $0.isFileURL && $0.pathExtension.lowercased() == "pdf"
        }) {
            sceneCoordinator.handleURLs(incomingURLs)
        }
    }

    #if targetEnvironment(macCatalyst)
    func sceneDidDisconnect(_ scene: UIScene) {
        guard
            UIApplication.shared.connectedScenes.isEmpty,
            let appKitPluginService
        else {
            return
        }
        appKitPluginService.terminate()
    }
    #endif

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

private extension SceneDelegate {

    func redirectToExistingSceneIfNeeded(
        scene: UIScene,
        session: UISceneSession,
        connectionOptions: UIScene.ConnectionOptions
    ) -> Bool {
        let pdfURLs = connectionOptions.urlContexts
            .map(\.url)
            .filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.absoluteString.localizedStandardCompare($1.absoluteString) == .orderedAscending }
        guard !pdfURLs.isEmpty else { return false }

        let readyWindowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { candidate in
                guard candidate !== scene, candidate.activationState != .unattached else {
                    return false
                }
                // A scene that was just redirected is still present in
                // `connectedScenes` until its destruction completes, but it has
                // no coordinator. Forwarding another URL to it silently drops
                // that file, so only target a fully initialized scene.
                return (candidate.delegate as? SceneDelegate)?.sceneCoordinator != nil
            }
            .sorted(by: isPreferredRedirectTarget)
            .first
        guard
            let windowScene = readyWindowScene,
            let existingDelegate = windowScene.delegate as? SceneDelegate,
            let existingCoordinator = existingDelegate.sceneCoordinator
        else {
            return false
        }
        // Acquire the grants before returning from `willConnectTo`. Some File
        // Providers revoke the URLs as soon as this source scene is released.
        let scopedURLs = pdfURLs.filter { $0.startAccessingSecurityScopedResource() }
        UIApplication.shared.requestSceneSessionActivation(
            windowScene.session, userActivity: nil, options: nil, errorHandler: nil
        )
        Task { @MainActor in
            // Keep the source scene alive until File Provider URLs have been
            // copied into app-owned storage. Destroying it earlier revokes some
            // providers' access and silently loses every file after the first.
            await existingCoordinator.handleRedirectedPDFURLs(
                pdfURLs,
                securityScopedURLs: scopedURLs
            )
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil, errorHandler: nil)
        }
        return true
    }

    func isPreferredRedirectTarget(_ lhs: UIWindowScene, _ rhs: UIWindowScene) -> Bool {
        let lhsIsKey = lhs.windows.contains { $0.isKeyWindow }
        let rhsIsKey = rhs.windows.contains { $0.isKeyWindow }
        if lhsIsKey != rhsIsKey {
            return lhsIsKey
        }

        let lhsActivationRank = redirectTargetActivationRank(lhs.activationState)
        let rhsActivationRank = redirectTargetActivationRank(rhs.activationState)
        if lhsActivationRank != rhsActivationRank {
            return lhsActivationRank < rhsActivationRank
        }

        // `connectedScenes` is a Set. A stable tie-break keeps sibling scene
        // callbacks from selecting different target coordinators as that Set
        // changes while redirected source scenes are being destroyed.
        return lhs.session.persistentIdentifier < rhs.session.persistentIdentifier
    }

    func redirectTargetActivationRank(_ activationState: UIScene.ActivationState) -> Int {
        switch activationState {
        case .foregroundActive:
            return 0
        case .foregroundInactive:
            return 1
        case .background:
            return 2
        case .unattached:
            return 3
        @unknown default:
            return 4
        }
    }

    func makeServices(fileManager: FileManager, fileService: LocalFileService) -> SceneServices {
        let jotFileService = JotFileService(fileService: fileService)
        let jotFilePreviewImageService = CachedJotFilePreviewImageService(
            localFileService: fileService,
            jotFilePreviewImageService: JotFilePreviewImageService(jotFileService: jotFileService)
        )
        return SceneServices(
            fileService: fileService,
            externalFileImportService: ExternalFileImportService(),
            applicationService: ApplicationService(application: .shared),
            deviceService: DeviceService(device: .current),
            bundleService: BundleService(bundle: .main),
            jotFileService: jotFileService,
            jotFileConflictService: JotFileConflictService(
                fileConflictService: FileConflictService(fileManager: fileManager)
            ),
            jotFilePreviewImageService: jotFilePreviewImageService
        )
    }

    func makeCoordinatorFactories(
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

    func makeSceneCoordinator(
        navigation: Navigation,
        services: SceneServices,
        rootCoordinatorFactory: RootCoordinatorFactoryProtocol,
        editJotCoordinatorFactory: EditJotCoordinatorFactoryProtocol
    ) -> SceneCoordinator {
        let createJotCoordinatorFactory = CreateJotCoordinatorFactory(
            repository: CreateJotRepository(
                fileService: services.fileService,
                jotFileService: services.jotFileService
            ),
            externalFileImportService: services.externalFileImportService
        )
        return SceneCoordinator(
            navigation: navigation,
            defaultsService: Self.defaultsService,
            applicationService: services.applicationService,
            fileService: services.fileService,
            externalFileImportService: services.externalFileImportService,
            logger: OSLogLogger(category: "SceneCoordinator"),
            rootCoordinatorFactory: rootCoordinatorFactory,
            editJotCoordinatorFactory: editJotCoordinatorFactory,
            createJotCoordinatorFactory: createJotCoordinatorFactory,
            onUpdateUserInterfaceStyle: { [weak self] userInterfaceStyle in
                Task { @MainActor in self?.window?.overrideUserInterfaceStyle = userInterfaceStyle }
            },
            requestSceneSessionActivationProvider: { url in
                Task { @MainActor in
                    let activity = NSUserActivity(activityType: SceneCoordinator.Constants.activityType)
                    activity.userInfo = [SceneCoordinator.Constants.urlKey: url.absoluteString]
                    UIApplication.shared.requestSceneSessionActivation(
                        nil, userActivity: activity, options: nil, errorHandler: nil
                    )
                }
            }
        )
    }

    func makeBarButtonItemFactories() -> (TextBarButtonItemFactory, SymbolBarButtonItemFactory) {
        if #available(iOS 26, *) {
            return (IOS26TextBarButtonItemFactory(), IOS26SymbolBarButtonItemFactory())
        } else {
            return (IOS18TextBarButtonItemFactory(), IOS18SymbolBarButtonItemFactory())
        }
    }

    func makeEditJotCoordinatorFactory(
        services: SceneServices,
        uiFactories: SceneUIFactories,
        coordinators: SceneCoordinatorFactories,
        webDAVBackupService: WebDAVBackupService
    ) -> EditJotCoordinatorFactory {
        let editJotRepository = EditJotRepository(
            jotFileService: services.jotFileService,
            jotFileConflictService: services.jotFileConflictService,
            fileService: services.fileService,
            trashService: TrashService()
        )
        return EditJotCoordinatorFactory(
            repository: editJotRepository,
            externalFileImportService: services.externalFileImportService,
            editJotViewControllerFactory: EditJotViewControllerFactory(
                repository: editJotRepository,
                menuConfigurationFactory: uiFactories.menuConfigurationFactory,
                symbolBarButtonItemFactory: uiFactories.symbolBarButtonItemFactory,
                defaultsService: Self.defaultsService,
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
                    jotFileService: services.jotFileService,
                    webDAVBackupService: webDAVBackupService
                )
            ),
            deleteJotCoordinatorFactory: coordinators.deleteJotCoordinatorFactory,
            shareJotCoordinatorFactory: coordinators.shareJotCoordinatorFactory,
            revealFileCoordinatorFactory: coordinators.revealFileCoordinatorFactory
        )
    }

    func makeJotsCoordinatorFactory(
        services: SceneServices,
        uiFactories: SceneUIFactories,
        coordinators: SceneCoordinatorFactories,
        editJotCoordinatorFactory: EditJotCoordinatorFactory,
        webDAVBackupService: WebDAVBackupService
    ) -> JotsCoordinatorFactoryProtocol {
        JotsCoordinatorFactory(
            jotsViewControllerFactory: JotsViewControllerFactory(
                repository: JotsRepository(
                    fileService: services.fileService,
                    applicationService: services.applicationService,
                    deviceService: services.deviceService,
                    jotFileService: services.jotFileService,
                    jotFilePreviewImageService: services.jotFilePreviewImageService,
                    defaultsService: Self.defaultsService,
                    webDAVBackupService: webDAVBackupService,
                    trashService: TrashService()
                ),
                menuConfigurationFactory: uiFactories.menuConfigurationFactory,
                textBarButtonItemFactory: uiFactories.textBarButtonItemFactory,
                symbolBarButtonItemFactory: uiFactories.symbolBarButtonItemFactory,
                logger: OSLogLogger(category: "JotsViewModel"),
                defaultsService: Self.defaultsService
            ),
            settingsCoordinatorFactory: SettingsCoordinatorFactory(
                settingsViewControllerFactory: SettingsViewControllerFactory(
                    repository: SettingsRepository(
                        bundleService: services.bundleService,
                        defaultsService: Self.defaultsService,
                        webDAVBackupService: webDAVBackupService
                    ),
                    textBarButtonItemFactory: uiFactories.textBarButtonItemFactory,
                    symbolBarButtonItemFactory: uiFactories.symbolBarButtonItemFactory
                )
            ),
            editJotCoordinatorFactory: editJotCoordinatorFactory,
            createJotCoordinatorFactory: CreateJotCoordinatorFactory(
                repository: CreateJotRepository(
                    fileService: services.fileService,
                    jotFileService: services.jotFileService
                ),
                externalFileImportService: services.externalFileImportService
            ),
            deleteJotCoordinatorFactory: coordinators.deleteJotCoordinatorFactory,
            renameJotCoordinatorFactory: RenameJotCoordinatorFactory(
                repository: RenameJotRepository(
                    jotFileService: services.jotFileService,
                    webDAVBackupService: webDAVBackupService
                )
            ),
            shareJotCoordinatorFactory: coordinators.shareJotCoordinatorFactory,
            revealFileCoordinatorFactory: coordinators.revealFileCoordinatorFactory,
            trashViewControllerFactory: TrashViewControllerFactory(
                repository: TrashRepository(
                    fileService: services.fileService,
                    trashService: TrashService(),
                    previewService: services.jotFilePreviewImageService
                ),
                textBarButtonItemFactory: uiFactories.textBarButtonItemFactory,
                symbolBarButtonItemFactory: uiFactories.symbolBarButtonItemFactory
            )
        )
    }

    func makeNavigation(
        navigationController: UINavigationController,
        applicationService: ApplicationServiceProtocol
    ) -> Navigation {
        Navigation(
            openURLProvider: { [weak self, weak navigationController] url in
                Task { @MainActor in
                    guard let viewControllers = self?.sceneCoordinator?.handle(url: url) else { return }
                    navigationController?.setViewControllers(viewControllers, animated: true)
                }
            },
            openExternalURLProvider: { url in
                Task { @MainActor in
                    guard applicationService.canOpen(url: url) else { return }
                    applicationService.open(url: url)
                }
            },
            openSceneProvider: { [weak self] url in
                Task { @MainActor in self?.sceneCoordinator?.openScene(url: url) }
            },
            presentViewControllerProvider: { [weak navigationController] viewController, animated in
                Task { @MainActor in navigationController?.present(viewController, animated: animated) }
            },
            dismissViewControllerProvider: { [weak navigationController] animated, completion in
                Task { @MainActor in
                    navigationController?.dismiss(animated: animated, completion: completion)
                }
            },
            popViewControllerProvider: { [weak self, weak navigationController] animated in
                Task { @MainActor in
                    navigationController?.popViewController(animated: animated)
                    self?.sceneCoordinator?.handlePop()
                }
            },
            getViewControllersProvider: { [weak navigationController] in
                navigationController?.viewControllers ?? []
            }
        )
    }

    func makeNavigationController() -> UINavigationController {
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

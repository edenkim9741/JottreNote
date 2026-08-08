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
final class SceneCoordinator {

    enum Constants {
        static let activityType = "com.antonlorani.jottre.openJot"
        static let urlKey = "url"
        static let fileBookmarkKey = "fileBookmark"
    }

    private var lastActiveURL: URL?
    private var navigationController: UINavigationController?
    private var retainedRootCoordinator: NavigationCoordinator?
    private var retainedCreateJotCoordinator: Coordinator?
    private var pendingPDFImports: [(data: Data, name: String)] = []
    private var pendingPDFImportSelectedCount = 0
    private var pendingPDFImportFailures: [String] = []
    private var activePDFMaterializationCount = 0
    private var pendingPDFImportTask: Task<Void, Never>?
    private var userInterfaceStyleTask: Task<Void, Never>?
    #if targetEnvironment(macCatalyst)
    private var securityScopedURL: URL?
    #endif

    private let navigation: Navigation
    private let defaultsService: DefaultsServiceProtocol
    private let applicationService: ApplicationServiceProtocol
    private let fileService: FileServiceProtocol
    private let externalFileImportService: ExternalFileImportServiceProtocol
    private let logger: LoggerProtocol
    private let rootCoordinatorFactory: RootCoordinatorFactoryProtocol
    private let editJotCoordinatorFactory: EditJotCoordinatorFactoryProtocol
    private let createJotCoordinatorFactory: CreateJotCoordinatorFactoryProtocol
    private let onUpdateUserInterfaceStyle: @Sendable (_ userInterfaceStyle: UIUserInterfaceStyle) -> Void
    private let requestSceneSessionActivationProvider: @Sendable (_ url: URL) -> Void

    init(
        navigation: Navigation,
        defaultsService: DefaultsServiceProtocol,
        applicationService: ApplicationServiceProtocol,
        fileService: FileServiceProtocol,
        externalFileImportService: ExternalFileImportServiceProtocol,
        logger: LoggerProtocol,
        rootCoordinatorFactory: RootCoordinatorFactoryProtocol,
        editJotCoordinatorFactory: EditJotCoordinatorFactoryProtocol,
        createJotCoordinatorFactory: CreateJotCoordinatorFactoryProtocol,
        onUpdateUserInterfaceStyle: @Sendable @escaping (_ userInterfaceStyle: UIUserInterfaceStyle) -> Void,
        requestSceneSessionActivationProvider: @Sendable @escaping (_ url: URL) -> Void
    ) {
        self.navigation = navigation
        self.defaultsService = defaultsService
        self.applicationService = applicationService
        self.fileService = fileService
        self.externalFileImportService = externalFileImportService
        self.logger = logger
        self.rootCoordinatorFactory = rootCoordinatorFactory
        self.editJotCoordinatorFactory = editJotCoordinatorFactory
        self.createJotCoordinatorFactory = createJotCoordinatorFactory
        self.onUpdateUserInterfaceStyle = onUpdateUserInterfaceStyle
        self.requestSceneSessionActivationProvider = requestSceneSessionActivationProvider
    }

    func handle(url: URL) -> [UIViewController] {
        lastActiveURL = url
        return retainedRootCoordinator?.handle(url: url) ?? []
    }

    func handle(
        session: UISceneSession,
        connectionOptions: UIScene.ConnectionOptions
    ) -> [UIViewController] {
        let url: URL
        let coordinator: NavigationCoordinator

        if let (activityURL, isRestored) = getActivityURL(session: session, connectionOptions: connectionOptions) {
            (url, coordinator) = resolveURLAndCoordinator(activityURL: activityURL, isRestored: isRestored)
        } else {
            url = JotsPageURL().toURL()
            coordinator = rootCoordinatorFactory.make(navigation: navigation)
        }

        lastActiveURL = url
        retainedRootCoordinator = coordinator
        startUserInterfaceStyleTask()
        initializeDocumentsDirectory()

        return coordinator.handle(url: url)
    }

    func handleURLContexts(urlContexts: Set<UIOpenURLContext>) {
        let pdfURLs = urlContexts.map { $0.url }.filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
        if !pdfURLs.isEmpty {
            Task { [weak self] in
                await self?.materializeAndEnqueuePDFImports(from: pdfURLs)
            }
            return
        }

        guard let incomingURL = urlContexts.first?.url else { return }

        guard incomingURL.pathExtension == JotFile.Info.fileExtension else {
            navigation.open(url: incomingURL)
            return
        }

        openScene(url: incomingURL)
    }

    /// Copies File Provider URLs while the scene that granted access is still
    /// alive. Callers that redirect a document-opening scene await this method
    /// before destroying that source scene.
    func handleRedirectedPDFURLs(_ urls: [URL], securityScopedURLs: [URL]) async {
        await materializeAndEnqueuePDFImports(
            from: urls,
            preaccessedSecurityScopedURLs: securityScopedURLs
        )
    }

    func openScene(url: URL) {
        if applicationService.supportsMultipleScenes() {
            requestSceneSessionActivationProvider(url)
        } else {
            navigation.open(url: url)
        }
    }

    func handlePop() {
        lastActiveURL = nil
    }

    func makeStateRestorationActivity() -> NSUserActivity? {
        guard
            let lastActiveURL,
            applicationService.supportsMultipleScenes()
        else {
            return nil
        }
        let activity = NSUserActivity(activityType: Constants.activityType)
        activity.userInfo = makeUserInfo(lastActiveURL: lastActiveURL)
        return activity
    }

    deinit {
        #if targetEnvironment(macCatalyst)
        securityScopedURL?.stopAccessingSecurityScopedResource()
        #endif
        pendingPDFImportTask?.cancel()
        userInterfaceStyleTask?.cancel()
    }
}

// MARK: - Private

private extension SceneCoordinator {

    func resolveURLAndCoordinator(
        activityURL: URL,
        isRestored: Bool
    ) -> (url: URL, coordinator: NavigationCoordinator) {
        lazy var editJotCoordinator = editJotCoordinatorFactory.make(navigation: navigation)
        lazy var rootCoordinator = rootCoordinatorFactory.make(navigation: navigation)

        let preferredCoordinator: NavigationCoordinator
        let resolvedURL: URL

        if isEditJotURL(url: activityURL) {
            preferredCoordinator = editJotCoordinator
            resolvedURL = activityURL
        } else if let editJotURL = makeEditJotURL(fileURL: activityURL) {
            preferredCoordinator = editJotCoordinator
            resolvedURL = editJotURL
        } else {
            preferredCoordinator = rootCoordinator
            resolvedURL = activityURL
        }

        let coordinator: NavigationCoordinator
        if isRestored {
            #if targetEnvironment(macCatalyst)
            coordinator = preferredCoordinator
            #else
            // On iPadOS its more tedious for users to create a new fresh window. Therefore we prefer
            // restoring a scene that allows navigating back to a jots overview (When the activityURL
            // opens a nested hierarchy).
            coordinator = rootCoordinator
            #endif
        } else {
            coordinator = applicationService.supportsMultipleScenes() ? preferredCoordinator : rootCoordinator
        }

        return (url: resolvedURL, coordinator: coordinator)
    }

    func startUserInterfaceStyleTask() {
        userInterfaceStyleTask?.cancel()
        userInterfaceStyleTask = Task {
            for await userInterfaceStyle in defaultsService.getValueStream(.userInterfaceStyle) {
                let userInterfaceStyle =
                    userInterfaceStyle
                    .flatMap(UIUserInterfaceStyle.init(rawValue:)) ?? .unspecified
                onUpdateUserInterfaceStyle(userInterfaceStyle)
            }
        }
    }

    func initializeDocumentsDirectory() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await fileService.initializeDocumentsDirectory()
                logger.info("Initialized documents directory.")
            } catch {
                logger.error("Failed to initialize documents directory: \(error)")
            }
        }
    }

    /// Files can deliver one multi-document Open operation as several scene URL
    /// callbacks. Materialize every callback immediately, then collect the local
    /// data before deciding between the single and batch UI.
    func materializeAndEnqueuePDFImports(
        from urls: [URL],
        preaccessedSecurityScopedURLs: [URL]? = nil
    ) async {
        guard !urls.isEmpty else { return }
        pendingPDFImportTask?.cancel()
        pendingPDFImportTask = nil
        activePDFMaterializationCount += 1

        let scopedURLs = preaccessedSecurityScopedURLs
            ?? urls.filter { $0.startAccessingSecurityScopedResource() }
        let externalFileImportService = externalFileImportService
        let result = await Task.detached {
            defer {
                for url in scopedURLs {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            var documents: [(data: Data, name: String)] = []
            var failedNames: [String] = []
            for url in urls {
                let name = url.deletingPathExtension().lastPathComponent
                do {
                    let file = try externalFileImportService.importAndReadFile(sourceURL: url)
                    documents.append((data: file.data, name: name))
                } catch {
                    failedNames.append(name)
                }
            }
            return (documents: documents, failedNames: failedNames)
        }.value

        pendingPDFImportSelectedCount += urls.count
        pendingPDFImports.append(contentsOf: result.documents)
        pendingPDFImportFailures.append(contentsOf: result.failedNames)
        activePDFMaterializationCount -= 1
        schedulePendingPDFImportPresentationIfReady()
    }

    func schedulePendingPDFImportPresentationIfReady() {
        guard activePDFMaterializationCount == 0 else { return }
        pendingPDFImportTask?.cancel()
        pendingPDFImportTask = Task { @MainActor [weak self] in
            do {
                // Scene-based Open requests for one multi-selection arrive as
                // sibling callbacks. Allow the connection callbacks to settle,
                // while active File Provider copies keep this timer cancelled.
                try await Task.sleep(for: .milliseconds(800))
            } catch {
                return
            }
            guard let self, activePDFMaterializationCount == 0 else { return }
            let pdfs = pendingPDFImports
            let selectedCount = pendingPDFImportSelectedCount
            let failedNames = pendingPDFImportFailures
            pendingPDFImports.removeAll(keepingCapacity: true)
            pendingPDFImportSelectedCount = 0
            pendingPDFImportFailures.removeAll(keepingCapacity: true)
            pendingPDFImportTask = nil
            presentMaterializedPDFImports(
                pdfs: pdfs,
                selectedCount: selectedCount,
                failedNames: failedNames
            )
        }
    }

    func presentMaterializedPDFImports(
        pdfs: [(data: Data, name: String)],
        selectedCount: Int,
        failedNames: [String]
    ) {
        guard !pdfs.isEmpty else {
            presentPDFImportFailure(names: failedNames)
            return
        }
        if selectedCount == 1, let pdf = pdfs.first {
            presentFolderSelectionForImportedPDF(pdfData: pdf.data, pdfName: pdf.name)
        } else {
            presentFolderSelectionForImportedPDFs(pdfs: pdfs)
        }
    }

    func presentPDFImportFailure(names: [String]) {
        let alert = UIAlertController(
            title: L10n.EditJot.PDF.Error.importFailed,
            message: names.joined(separator: "\n"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.Action.ok, style: .default))
        navigation.present(alert, animated: true)
    }

    func presentFolderSelectionForImportedPDF(pdfData: Data, pdfName: String) {
        presentFolderPickerForPDFImport { [weak self] folder in
            self?.startCreateJot(directory: folder.map { .init(url: $0.url) }, pdfData: pdfData, pdfName: pdfName)
        }
    }

    func presentFolderSelectionForImportedPDFs(pdfs: [(data: Data, name: String)]) {
        presentFolderPickerForPDFImport { [weak self] folder in
            self?.startCreateJots(directory: folder.map { .init(url: $0.url) }, pdfs: pdfs)
        }
    }

    func startCreateJot(directory: CreateJotCoordinatorFactory.Directory?, pdfData: Data, pdfName: String) {
        let coordinator = createJotCoordinatorFactory.make(navigation: navigation, directory: directory,
            pdfData: pdfData, pdfName: pdfName)
        retainedCreateJotCoordinator = coordinator
        coordinator.onEnd = { [weak self] in self?.retainedCreateJotCoordinator = nil }
        coordinator.start()
    }

    func startCreateJots(directory: CreateJotCoordinatorFactory.Directory?, pdfs: [(data: Data, name: String)]) {
        let coordinator = createJotCoordinatorFactory.makeBatch(navigation: navigation, directory: directory,
            pdfs: pdfs)
        retainedCreateJotCoordinator = coordinator
        coordinator.onEnd = { [weak self] in self?.retainedCreateJotCoordinator = nil }
        coordinator.start()
    }

    private func presentFolderPickerForPDFImport(onConfirm: @escaping @MainActor (FolderBusinessModel?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let folders = try? await listFoldersForSelection() else { onConfirm(nil); return }
            let picker = FolderPickerViewController(
                title: String(localized: "scene.import.pdf.folder.title", defaultValue: "Choose Folder"),
                folders: folders,
                onCreateFolder: { [weak self] name, parentURL in
                    guard let self else { throw CancellationError() }
                    let newFolderURL = parentURL.appendingPathComponent(name)
                    try self.fileService.createDirectory(directoryURL: newFolderURL)
                    return FolderBusinessModel(url: newFolderURL, name: name, modificationDate: Date())
                },
                onConfirm: onConfirm
            )
            let nav = UINavigationController(rootViewController: picker)
            nav.modalPresentationStyle = .formSheet
            navigation.present(nav, animated: true)
        }
    }

    func listFoldersForSelection() async throws -> [FolderBusinessModel] {
        guard let root = try await fileService.documentsDirectory() else { return [] }
        return try listFoldersRecursively(directory: root)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func listFoldersRecursively(directory: URL) throws -> [FolderBusinessModel] {
        let urls = try fileService.listContents(
            directory: directory,
            properties: [.isDirectoryKey, .contentModificationDateKey]
        )
        var folders = [FolderBusinessModel]()
        for url in urls {
            let properties = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard properties.isDirectory == true, url.lastPathComponent != "Inbox" else { continue }
            folders.append(
                FolderBusinessModel(
                    url: url,
                    name: url.lastPathComponent,
                    modificationDate: properties.contentModificationDate
                )
            )
            folders.append(contentsOf: try listFoldersRecursively(directory: url))
        }
        return folders
    }

    func makeUserInfo(lastActiveURL: URL) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [Constants.urlKey: lastActiveURL.absoluteString]
        guard let fileURL = EditJotURL(url: lastActiveURL)?.fileURL else { return userInfo }
        #if targetEnvironment(macCatalyst)
        let bookmarkOptions = URL.BookmarkCreationOptions.withSecurityScope
        #else
        let bookmarkOptions = URL.BookmarkCreationOptions()
        #endif

        if let bookmark = try? fileURL.bookmarkData(options: bookmarkOptions) {
            userInfo[Constants.fileBookmarkKey] = bookmark
        }
        return userInfo
    }

    func getActivityURL(
        session: UISceneSession,
        connectionOptions: UIScene.ConnectionOptions
    ) -> (url: URL, isRestored: Bool)? {
        if let activity = session.stateRestorationActivity,
            let url = getURL(activity: activity) {
            return (url: url, isRestored: true)
        }

        if let activity = connectionOptions.userActivities.first(where: { $0.activityType == Constants.activityType }),
            let url = getURL(activity: activity) {
            return (url: url, isRestored: false)
        }

        if let firstURLContextURL = connectionOptions.urlContexts.first?.url {
            if firstURLContextURL.isFileURL, firstURLContextURL.pathExtension.lowercased() == "pdf" {
                return (url: JotsPageURL().toURL(), isRestored: false)
            }
            return (url: firstURLContextURL, isRestored: false)
        }

        return nil
    }

    func getURL(activity: NSUserActivity) -> URL? {
        guard activity.activityType == Constants.activityType,
            let urlString = activity.userInfo?[Constants.urlKey] as? String,
            let url = URL(string: urlString)
        else { return nil }

        guard let bookmark = activity.userInfo?[Constants.fileBookmarkKey] as? Data else {
            return url
        }

        var isStale = false

        #if targetEnvironment(macCatalyst)
        let bookmarkOptions = URL.BookmarkResolutionOptions.withSecurityScope
        #else
        let bookmarkOptions = URL.BookmarkResolutionOptions()
        #endif

        guard
            let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: bookmarkOptions,
                bookmarkDataIsStale: &isStale
            ),
            EditJotURL(url: url) != nil,
            let rebuilt = makeEditJotURL(fileURL: resolved)
        else {
            return url
        }

        #if targetEnvironment(macCatalyst)
        if resolved.startAccessingSecurityScopedResource() {
            securityScopedURL?.stopAccessingSecurityScopedResource()
            securityScopedURL = resolved
        }
        #endif

        return rebuilt
    }

    func isEditJotURL(url: URL) -> Bool {
        EditJotURL(url: url) != nil
    }

    func makeEditJotURL(fileURL: URL) -> URL? {
        guard let jotFileInfo = JotFile.Info(url: fileURL, modificationDate: nil) else {
            return nil
        }
        return EditJotURL(jotFileInfo: jotFileInfo).toURL()
    }
}

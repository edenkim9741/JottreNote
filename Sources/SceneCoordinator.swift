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
    private var retainedCreateJotCoordinators: [UUID: Coordinator] = [:]
    private var userInterfaceStyleTask: Task<Void, Never>?
    private lazy var externalPDFImportCoalescer = ExternalPDFImportCoalescer { [weak self] urls in
        await self?.handleCoalescedExternalPDFURLs(urls)
    }
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

    func handleURLs(_ urls: [URL]) {
        let pdfURLs = urls
            .filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.absoluteString.localizedStandardCompare($1.absoluteString) == .orderedAscending }

        guard pdfURLs.isEmpty else {
            // Acquiring the grants is synchronous. The coalescer therefore owns
            // them before this UIKit URL-delivery callback is allowed to return.
            externalPDFImportCoalescer.submit(pdfURLs)
            return
        }

        guard let incomingURL = urls.first else { return }

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
        await externalPDFImportCoalescer.submitPreaccessed(
            urls,
            securityScopedURLs: securityScopedURLs
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
        let styleUpdates = defaultsService.getValueStream(.userInterfaceStyle)
        let onUpdateUserInterfaceStyle = onUpdateUserInterfaceStyle
        userInterfaceStyleTask = Task {
            for await userInterfaceStyle in styleUpdates {
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

    func handleCoalescedExternalPDFURLs(_ urls: [URL]) async {
        // A Set-backed UIKit callback has no stable iteration order. Sorting the
        // complete aggregate also makes duplicate-name suffixing deterministic.
        let urls = urls.sorted {
            $0.absoluteString.localizedStandardCompare($1.absoluteString) == .orderedAscending
        }

        // Route on the number selected, before any individual read can fail and
        // accidentally turn a batch into the single-file presentation path.
        switch ExternalPDFImportRoute(urls: urls) {
        case .none:
            return
        case .single(let url):
            await importSinglePDF(from: url)
        case .batch(let urls):
            await importPDFBatch(from: urls)
        }
    }

    func importSinglePDF(from url: URL) async {
        let result = await materializePDFs(from: [url])

        guard let pdf = result.documents.first else {
            presentPDFImportFailure(names: result.failedNames)
            return
        }

        presentFolderSelectionForImportedPDF(pdfData: pdf.data, pdfName: pdf.name)
    }

    func importPDFBatch(from urls: [URL]) async {
        var failedNames = [String]()

        for url in urls {
            let result = await materializePDFs(from: [url])
            failedNames.append(contentsOf: result.failedNames)

            guard let document = result.documents.first else { continue }

            // Persist each owned Data value before reading the next File
            // Provider item so a large selection cannot accumulate in memory.
            await startCreateJotsAndWait(directory: nil, pdfs: [document])
        }

        if !failedNames.isEmpty {
            logger.error("Failed to read PDFs during batch import: \(failedNames.joined(separator: ", "))")
        }
    }

    func materializePDFs(
        from urls: [URL]
    ) async -> (documents: [(data: Data, name: String)], failedNames: [String]) {
        let externalFileImportService = externalFileImportService
        return await Task.detached(priority: .userInitiated) {
            var documents: [(data: Data, name: String)] = []
            var failedNames: [String] = []

            for url in urls {
                let name = ExternalPDFImportRoute.suggestedTitle(for: url)
                do {
                    let data = try externalFileImportService.readExternalFile(sourceURL: url)
                    documents.append((data: data, name: name))
                } catch {
                    failedNames.append(name)
                }
            }

            return (documents: documents, failedNames: failedNames)
        }.value
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

    func startCreateJot(directory: CreateJotCoordinatorFactory.Directory?, pdfData: Data, pdfName: String) {
        let coordinator = createJotCoordinatorFactory.make(navigation: navigation, directory: directory,
            pdfData: pdfData, pdfName: pdfName)
        startAndRetainCreateJotCoordinator(coordinator)
    }

    func startCreateJotsAndWait(
        directory: CreateJotCoordinatorFactory.Directory?,
        pdfs: [(data: Data, name: String)]
    ) async {
        let coordinator = createJotCoordinatorFactory.makeBatch(
            navigation: navigation,
            directory: directory,
            pdfs: pdfs
        )
        let id = UUID()
        retainedCreateJotCoordinators[id] = coordinator

        await withCheckedContinuation { continuation in
            coordinator.onEnd = { [weak self] in
                self?.retainedCreateJotCoordinators.removeValue(forKey: id)
                continuation.resume()
            }
            coordinator.start()
        }
    }

    func startAndRetainCreateJotCoordinator(_ coordinator: Coordinator) {
        let id = UUID()
        retainedCreateJotCoordinators[id] = coordinator
        coordinator.onEnd = { [weak self] in
            self?.retainedCreateJotCoordinators.removeValue(forKey: id)
        }
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

        let incomingURLs = connectionOptions.urlContexts.map(\.url)
        if incomingURLs.contains(where: {
            $0.isFileURL && $0.pathExtension.lowercased() == "pdf"
        }) {
            return (url: JotsPageURL().toURL(), isRestored: false)
        }

        if let firstURLContextURL = incomingURLs.first {
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

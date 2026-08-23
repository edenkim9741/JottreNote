@preconcurrency import PencilKit
import UIKit

struct WebDAVBackupService: Sendable {

    // Mirrors Self.pageSpacing (32 pt); keep in sync if that constant changes.
    private static let pageSpacing: CGFloat = 32
    private static let maximumPageCount = 10_000

    private struct PageLayout {
        let pageSize: CGSize
        let pdfPageCount: Int
        let logicalToPDFPage: [Int?]
        let totalPages: Int

        func pdfPageIndex(for logicalPageIndex: Int) -> Int? {
            guard logicalToPDFPage.indices.contains(logicalPageIndex) else { return nil }
            return logicalToPDFPage[logicalPageIndex]
        }
    }

    private enum BackupJotResult {
        case uploaded
        case skipped
        case failed
    }

    private let defaultsService: DefaultsServiceProtocol
    private let fileService: FileServiceProtocol
    private let operationGate: WebDAVBackupOperationGate

    init(
        defaultsService: DefaultsServiceProtocol,
        fileService: FileServiceProtocol = LocalFileService(fileManager: .default),
        operationGate: WebDAVBackupOperationGate = WebDAVBackupOperationGate()
    ) {
        self.defaultsService = defaultsService
        self.fileService = fileService
        self.operationGate = operationGate
    }

    // MARK: - Auto-backup (on note exit)

    func backup(
        jotFileInfo: JotFile.Info,
        content: JotContent
    ) async {
        guard await operationGate.acquire() else { return }
        _ = await performBackup(jotFileInfo: jotFileInfo, content: content)
        await operationGate.release()
    }

    private func performBackup(
        jotFileInfo: JotFile.Info,
        content: JotContent
    ) async -> Bool {
        guard
            let service = makeWebDAVService(),
            !Task.isCancelled
        else { return false }
        guard !Task.isCancelled,
            let jotData = try? fileService.readFile(fileURL: jotFileInfo.url)
        else { return false }

        let remoteFolderPath = remoteFolder(for: jotFileInfo)
        if let folder = remoteFolderPath {
            await makeDirectoryHierarchy(folder, service: service)
        }

        guard !Task.isCancelled else { return false }
        let jotRemotePath = remotePath(for: jotFileInfo, extension: "jot", folder: remoteFolderPath)
        do {
            try await service.upload(data: jotData, remotePath: jotRemotePath)
        } catch {
            return false
        }

        guard !Task.isCancelled else { return false }
        // The caller flushes this exact snapshot before backup, so the native
        // jot and rendered PDF represent the same editor revision.
        let pdfRemotePath = remotePath(for: jotFileInfo, extension: "pdf", folder: remoteFolderPath)
        let renderedPDF = makePDF(
            drawing: content.drawing,
            pdfData: content.pdfData,
            extraPages: content.extraPages,
            pdfInsertedPageSlots: content.pdfInsertedPageSlots,
            width: content.width
        )
        guard let renderedPDF, !Task.isCancelled else { return false }
        do {
            try await service.upload(data: renderedPDF, remotePath: pdfRemotePath)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Manual backup (all notes)

    /// Enumerates every .jot file under the Documents directory and uploads each to WebDAV.
    /// Reports progress in [0, 1] after each file completes. Finished when the stream ends.
    func backupAll() -> AsyncStream<Double> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                guard await operationGate.acquire() else {
                    continuation.finish()
                    return
                }
                _ = await performBackupAll { progress in
                    continuation.yield(progress)
                }
                await operationGate.release()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Entry point used by foreground and BackgroundTasks scheduling. The Bool
    /// is suitable for `BGTask.setTaskCompleted(success:)`; failures remain
    /// silent to the user and are retried by the next scheduled lifecycle.
    func backupAllAutomatically() async -> Bool {
        guard await operationGate.acquire() else { return false }
        let success = await performBackupAll(progress: nil)
        await operationGate.release()
        return success
    }

    private func performBackupAll(
        progress: (@Sendable (Double) -> Void)?
    ) async -> Bool {
        guard let service = makeWebDAVService(), !Task.isCancelled else { return false }

        let jotURLs = enumerateJotFiles()
        guard !jotURLs.isEmpty else {
            progress?(1.0)
            return true
        }

        var succeeded = true
        var createdFolders = Set<String>()
        for (index, jotURL) in jotURLs.enumerated() {
            guard !Task.isCancelled else { return false }
            let result = await backupJotFile(
                jotURL,
                service: service,
                createdFolders: &createdFolders
            )
            if case .failed = result {
                succeeded = false
            }
            progress?(Double(index + 1) / Double(jotURLs.count))
        }
        return succeeded && !Task.isCancelled
    }

    // Uploads one .jot file plus its rendered PDF only when the local file is newer than the
    // remote copy (or the remote copy does not exist yet). Creates the remote folder hierarchy
    // if needed (each ancestor level in order, so paths like "한글/하위" work correctly).
    // Returns whether work uploaded, was already current, or failed.
    private func backupJotFile(
        _ jotURL: URL,
        service: WebDAVService,
        createdFolders: inout Set<String>
    ) async -> BackupJotResult {
        guard !Task.isCancelled else { return .failed }
        let info = JotFile.Info(
            url: jotURL,
            name: jotURL.deletingPathExtension().lastPathComponent,
            modificationDate: nil
        )
        let folderPath = remoteFolder(for: info)
        let jotPath = remotePath(for: info, extension: "jot", folder: folderPath)
        let pdfPath = remotePath(for: info, extension: "pdf", folder: folderPath)

        let localModDate = (try? jotURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        async let remoteJotModDate = service.lastModified(remotePath: jotPath)
        async let remotePDFModDate = service.lastModified(remotePath: pdfPath)
        let (jotModDate, pdfModDate) = await (remoteJotModDate, remotePDFModDate)
        let shouldUploadJot = shouldUpload(local: localModDate, remote: jotModDate)
        let shouldUploadPDF = shouldUpload(local: localModDate, remote: pdfModDate)

        guard shouldUploadJot || shouldUploadPDF else {
            return .skipped
        }

        guard !Task.isCancelled else { return .failed }

        if let folderPath, !createdFolders.contains(folderPath) {
            await makeDirectoryHierarchy(folderPath, service: service)
            createdFolders.insert(folderPath)
        }

        guard let rawData = try? fileService.readFile(fileURL: jotURL) else { return .failed }
        var failed = false
        if shouldUploadJot {
            do {
                try await service.upload(data: rawData, remotePath: jotPath)
            } catch {
                failed = true
            }
        }

        guard !Task.isCancelled else { return .failed }

        if shouldUploadPDF {
            guard let jot = try? PropertyListDecoder().decode(Jot.self, from: rawData),
                let drawing = try? PKDrawing(data: jot.drawing),
                let pdf = makePDF(
                    drawing: drawing,
                    pdfData: jot.pdfData,
                    extraPages: jot.extraPages,
                    pdfInsertedPageSlots: jot.pdfInsertedPageSlots,
                    width: jot.width
                ), !Task.isCancelled
            else { return .failed }
            do {
                try await service.upload(data: pdf, remotePath: pdfPath)
            } catch {
                failed = true
            }
        }
        return failed ? .failed : .uploaded
    }

    private func shouldUpload(local: Date?, remote: Date?) -> Bool {
        guard let local, let remote else { return true }
        return local > remote
    }

    // Creates every ancestor level of a slash-separated path so that nested remote
    // directories (e.g. "폴더A/하위폴더B") are all present before any file is uploaded.
    private func makeDirectoryHierarchy(_ path: String, service: WebDAVService) async {
        var accumulated = ""
        for component in path.split(separator: "/") {
            accumulated = accumulated.isEmpty ? String(component) : "\(accumulated)/\(component)"
            try? await service.makeDirectory(remotePath: accumulated)
        }
    }

    // MARK: - Move / Rename

    func moveFiles(from oldInfo: JotFile.Info, to newInfo: JotFile.Info) {
        Task {
            guard await operationGate.acquire() else { return }
            await performMoveFiles(from: oldInfo, to: newInfo)
            await operationGate.release()
        }
    }

    private func performMoveFiles(from oldInfo: JotFile.Info, to newInfo: JotFile.Info) async {
        guard let service = makeWebDAVService(), !Task.isCancelled else { return }

        let oldFolder = remoteFolder(for: oldInfo)
        let newFolder = remoteFolder(for: newInfo)

        if let newFolder {
            await makeDirectoryHierarchy(newFolder, service: service)
        }

        let oldJotPath = remotePath(for: oldInfo, extension: "jot", folder: oldFolder)
        let newJotPath = remotePath(for: newInfo, extension: "jot", folder: newFolder)
        try? await service.move(fromPath: oldJotPath, toPath: newJotPath)

        guard !Task.isCancelled else { return }
        let oldPdfPath = remotePath(for: oldInfo, extension: "pdf", folder: oldFolder)
        let newPdfPath = remotePath(for: newInfo, extension: "pdf", folder: newFolder)
        try? await service.move(fromPath: oldPdfPath, toPath: newPdfPath)
    }

    private func makeWebDAVService() -> WebDAVService? {
        guard let urlString = defaultsService.getValue(DefaultsKey<String>.webDAVURL),
            !urlString.isEmpty,
            let baseURL = URL(string: urlString)
        else { return nil }
        return WebDAVService(
            baseURL: baseURL,
            username: defaultsService.getValue(DefaultsKey<String>.webDAVUsername) ?? "",
            password: defaultsService.getValue(DefaultsKey<String>.webDAVPassword) ?? ""
        )
    }

    // MARK: - Private

    private func enumerateJotFiles() -> [URL] {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        var results: [URL] = []
        collectJotFiles(in: documentsURL, into: &results)
        return results
    }

    private func collectJotFiles(in directory: URL, into results: inout [URL]) {
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey]
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles]
            )
        else { return }

        for url in contents {
            let isDirectory = (try? url.resourceValues(forKeys: Set(resourceKeys)))?.isDirectory ?? false
            if isDirectory {
                collectJotFiles(in: url, into: &results)
            } else if url.pathExtension == "jot" {
                results.append(url)
            }
        }
    }

    private func remoteFolder(for jotFileInfo: JotFile.Info) -> String? {
        guard
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }

        let resolvedDocs = documentsURL.resolvingSymlinksInPath()
        let resolvedDir = jotFileInfo.url.deletingLastPathComponent().resolvingSymlinksInPath()

        guard resolvedDir != resolvedDocs else { return nil }

        let relativePath = resolvedDir.path
            .replacingOccurrences(of: resolvedDocs.path + "/", with: "")
        return relativePath.isEmpty ? nil : relativePath
    }

    private func remotePath(for jotFileInfo: JotFile.Info, extension ext: String, folder: String?) -> String {
        let fileName = "\(jotFileInfo.name).\(ext)"
        guard let folder else { return fileName }
        return "\(folder)/\(fileName)"
    }

    // Runs in background — UIGraphicsPDFRenderer and PKDrawing.image(from:scale:) are safe
    // to call from background contexts because they operate on thread-local graphics contexts.
    private func makePDF(
        drawing: PKDrawing,
        pdfData: Data?,
        extraPages: Int,
        pdfInsertedPageSlots: [Int],
        width: CGFloat
    ) -> Data? {
        guard !Task.isCancelled else { return nil }
        let document = pdfData.flatMap(PDFRenderDocument.init(data:))
        let layers = JotDrawingLayerPartition(drawing: drawing)
        let layout = makePageLayout(
            document: document,
            extraPages: extraPages,
            pdfInsertedPageSlots: pdfInsertedPageSlots,
            width: width
        )
        let pageBounds = CGRect(x: 0, y: 0, width: layout.pageSize.width, height: layout.pageSize.height)

        var wasCancelled = false
        let data = UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
            for pageIndex in 0..<layout.totalPages {
                guard !Task.isCancelled else {
                    wasCancelled = true
                    break
                }
                autoreleasepool {
                    context.beginPage()
                    let pageY = CGFloat(pageIndex) * (layout.pageSize.height + Self.pageSpacing)
                    let canvasRect = CGRect(
                        x: 0,
                        y: pageY,
                        width: layout.pageSize.width,
                        height: layout.pageSize.height
                    )
                    UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                        let pdfIndex = layout.pdfPageIndex(for: pageIndex)
                        if pdfIndex != nil {
                            context.cgContext.setFillColor(gray: 1, alpha: 1)
                            context.cgContext.fill(pageBounds)
                        } else {
                            drawRuledPage(in: pageBounds, cgContext: context.cgContext)
                        }

                        if let pdfIndex,
                            pdfIndex < layout.pdfPageCount
                        {
                            document?.drawPage(
                                at: pdfIndex,
                                in: pageBounds,
                                context: context.cgContext,
                                fillsBackground: false
                            )
                        }
                        if let cgImage = layers.highlighter.image(from: canvasRect, scale: 2).cgImage {
                            embedCGImage(
                                cgImage,
                                in: pageBounds,
                                blendMode: .multiply,
                                cgContext: context.cgContext
                            )
                        }
                        if let cgImage = layers.foreground.image(from: canvasRect, scale: 2).cgImage {
                            embedCGImage(cgImage, in: pageBounds, cgContext: context.cgContext)
                        }
                    }
                }
            }
        }
        return wasCancelled ? nil : data
    }

    private func makePageLayout(
        document: PDFRenderDocument?,
        extraPages: Int,
        pdfInsertedPageSlots: [Int],
        width: CGFloat
    ) -> PageLayout {
        let defaultHeight = width * (4.0 / 3.0)
        let pageSize: CGSize
        if let document {
            let bounds = document.bounds(at: 0)
            pageSize =
                bounds.width > 0
                ? CGSize(width: width, height: width * bounds.height / bounds.width)
                : CGSize(width: width, height: defaultHeight)
        } else {
            pageSize = CGSize(width: width, height: defaultHeight)
        }
        let pdfPageCount = min(document?.pageCount ?? 0, Self.maximumPageCount)
        let safeExtraPages = min(
            max(0, extraPages),
            max(0, Self.maximumPageCount - max(1, pdfPageCount))
        )
        let legacySlots = Array(pdfPageCount..<(pdfPageCount + safeExtraPages))
        let sourceSlots = pdfInsertedPageSlots.isEmpty ? legacySlots : pdfInsertedPageSlots
        let maximumSlot = min(
            Self.maximumPageCount,
            pdfPageCount + min(sourceSlots.count, Self.maximumPageCount - pdfPageCount)
        )
        let slots =
            document == nil
            ? []
            : Array(
                Set(sourceSlots.lazy.filter { $0 >= 0 && $0 < maximumSlot })
            ).sorted()
        let totalPages = document == nil ? 1 + safeExtraPages : pdfPageCount + slots.count
        let slotSet = Set(slots)
        var nextPDFPage = 0
        let logicalToPDFPage: [Int?] = (0..<max(1, totalPages)).map { logicalPage in
            guard !slotSet.contains(logicalPage), nextPDFPage < pdfPageCount else { return nil }
            defer { nextPDFPage += 1 }
            return nextPDFPage
        }
        return PageLayout(
            pageSize: pageSize,
            pdfPageCount: pdfPageCount,
            logicalToPDFPage: logicalToPDFPage,
            totalPages: max(1, totalPages)
        )
    }

    // UIImage.draw(in:) in a PDF context downsizes to 1× (context scale = 1.0).
    // Drawing the CGImage directly bypasses UIKit's scale reduction and embeds
    // the full-resolution pixels. The Y-flip corrects for UIKit's Y-down CTM.
    private func embedCGImage(
        _ cgImage: CGImage,
        in rect: CGRect,
        blendMode: CGBlendMode = .normal,
        cgContext: CGContext
    ) {
        cgContext.saveGState()
        cgContext.setBlendMode(blendMode)
        cgContext.translateBy(x: 0, y: rect.height)
        cgContext.scaleBy(x: 1, y: -1)
        cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        cgContext.restoreGState()
    }

    private func drawRuledPage(in pageRect: CGRect, cgContext: CGContext) {
        cgContext.setFillColor(red: 0.99, green: 0.97, blue: 0.90, alpha: 1)
        cgContext.fill(pageRect)
        cgContext.setStrokeColor(gray: 0.62, alpha: 0.55)
        cgContext.setLineWidth(0.5)
        let lineSpacing: CGFloat = 32
        var lineY = pageRect.minY + lineSpacing
        while lineY < pageRect.maxY {
            cgContext.move(to: CGPoint(x: pageRect.minX, y: lineY))
            cgContext.addLine(to: CGPoint(x: pageRect.maxX, y: lineY))
            lineY += lineSpacing
        }
        cgContext.strokePath()
    }
}

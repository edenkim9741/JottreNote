@preconcurrency import PencilKit
import UIKit
import XCTest

@testable import Jottre

@MainActor
final class EditorPagePersistenceTests: XCTestCase {
    private let coordinator = PagePersistenceCoordinator()
    private let file = JotFile.Info(url: URL(fileURLWithPath: "/tmp/page-persistence-test.jot"), modificationDate: nil)!

    func testPageCommitsCoalesceAndBackgroundFlushIncludesTheLastStroke() async throws {
        let repository = PagePersistenceRepository()
        let model = await loadedModel(repository)
        for count in 1...100 {
            model.didChangePageDrawing(PKDrawing(strokes: (0..<count).map(stroke)), at: 2)
        }
        let before = await repository.state.saved()
        XCTAssertTrue(before.isEmpty, "Do not create/save a snapshot in each callback")
        await model.didEnterBackground()
        let writes = await repository.state.saved()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.last?.drawing.strokes.count, 100)
        XCTAssertEqual(writes.last?.strokePageIndices, Array(repeating: 2, count: 100))
        XCTAssertEqual(writes.last?.dirtyPageIndices, [2])
        await model.didEnterBackground()
        let after = await repository.state.saved()
        XCTAssertEqual(after.count, 1, "The same revision must not be saved twice")
    }

    func testAutosaveDefersWhilePencilIsDownThenFlushesOnExit() async throws {
        let repository = PagePersistenceRepository()
        let model = await loadedModel(repository)
        model.setDrawingInputActive(true)
        model.didChangePageDrawing(PKDrawing(strokes: [stroke(0)]), at: 0)
        try await Task.sleep(for: .milliseconds(2_150))
        let whileWriting = await repository.state.saved()
        XCTAssertTrue(whileWriting.isEmpty)
        model.setDrawingInputActive(false)
        await model.didDisappear(isLeavingEditor: true)
        let writes = await repository.state.saved()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.drawing.strokes.count, 1)
    }

    func testQuietPeriodCreatesOnlyTheLatestSnapshot() async throws {
        let repository = PagePersistenceRepository()
        let model = await loadedModel(repository)
        model.didChangePageDrawing(PKDrawing(strokes: [stroke(0)]), at: 0)
        model.didChangePageDrawing(PKDrawing(strokes: [stroke(0), stroke(1)]), at: 0)
        try await Task.sleep(for: .milliseconds(2_200))
        let writes = await repository.state.saved()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.last?.drawing.strokes.count, 2)
        await model.didEnterBackground()
        let afterFlush = await repository.state.saved()
        XCTAssertEqual(afterFlush.count, 1)
    }

    func testFailedSaveRetainsDirtyRevisionAndCanRetryTheSameRevision() async {
        let repository = PagePersistenceRepository(failures: 1)
        let model = await loadedModel(repository)
        model.didChangePageDrawing(PKDrawing(strokes: [stroke(0)]), at: 0)
        await model.didEnterBackground()
        XCTAssertEqual(model.dirtyPageIndices, [0])
        await model.didEnterBackground()
        let writes = await repository.state.saved()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.last?.drawing.strokes.count, 1)
        XCTAssertTrue(model.dirtyPageIndices.isEmpty)
    }

    func testEditingDuringSlowFlushPersistsTheNewRevisionBeforeReturning() async throws {
        let repository = PagePersistenceRepository(delay: .milliseconds(100))
        let model = await loadedModel(repository)
        model.didChangePageDrawing(PKDrawing(strokes: [stroke(0)]), at: 0)
        async let flush: Void = model.didEnterBackground()
        await repository.state.waitForStart()
        model.didChangePageDrawing(PKDrawing(strokes: [stroke(0), stroke(1)]), at: 0)
        await flush
        let writes = await repository.state.saved()
        XCTAssertEqual(writes.last?.drawing.strokes.count, 2)
        XCTAssertTrue(model.dirtyPageIndices.isEmpty)
        let maximum = await repository.state.maximumConcurrentWrites
        XCTAssertEqual(maximum, 1)
    }

    private func loadedModel(_ repository: PagePersistenceRepository) async -> EditJotViewModel {
        let defaults = DefaultsService(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let model = EditJotViewModel(
            jotFileInfo: file,
            repository: repository,
            coordinator: coordinator,
            menuConfigurationFactory: JotMenuConfigurationFactory(),
            zoteroDocumentSyncService: ZoteroDocumentSyncService(defaultsService: defaults),
            logger: PagePersistenceLogger()
        )
        var drawings = model.drawing.makeAsyncIterator()
        model.didLoad()
        _ = await drawings.next()
        return model
    }

    private func stroke(_ index: Int) -> PKStroke {
        let points = [0, 1, 2].map { sample in
            PKStrokePoint(
                location: CGPoint(x: CGFloat(sample * 10), y: CGFloat(index * 5 + sample)),
                timeOffset: Double(sample) / 60,
                size: CGSize(width: 2, height: 2),
                opacity: 1,
                force: 0.7,
                azimuth: 0.3,
                altitude: 1.2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: .distantPast)
        )
    }
}

private struct PagePersistenceRepository: EditJotRepositoryProtocol {
    actor State {
        private var contents: [JotContent] = []
        private var failures: Int
        private var activeWrites = 0
        private(set) var maximumConcurrentWrites = 0
        private var started = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        init(failures: Int) { self.failures = failures }
        func begin() {
            activeWrites += 1
            maximumConcurrentWrites = max(maximumConcurrentWrites, activeWrites)
            started = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
        func finish(_ content: JotContent) throws {
            activeWrites -= 1
            if failures > 0 {
                failures -= 1
                throw CocoaError(.fileWriteUnknown)
            }
            contents.append(content)
        }
        func saved() -> [JotContent] { contents }
        func waitForStart() async {
            if started { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }
    let state: State
    let delay: Duration
    init(failures: Int = 0, delay: Duration = .zero) {
        state = State(failures: failures)
        self.delay = delay
    }
    func readContent(jotFileInfo: JotFile.Info, onProgress: @Sendable (Double) -> Void) async throws -> JotContent {
        JotContent(
            drawing: PKDrawing(),
            width: 1_200,
            pdfData: nil,
            extraPages: 2,
            pdfInsertedPageSlots: [],
            strokePageIndices: []
        )
    }
    func writeContent(jotFileInfo: JotFile.Info, content: JotContent) async throws {
        await state.begin()
        try await Task.sleep(for: delay)
        try await state.finish(content)
    }
    func getConflictingVersions(jotFileInfo: JotFile.Info) -> [JotFileVersion]? { nil }
    func duplicate(jotFileInfo: JotFile.Info) throws -> JotFile.Info { jotFileInfo }
    func saveDeletedPageToTrash(
        strokes: [PKStroke],
        pageStartY: CGFloat,
        width: CGFloat,
        pageName: String,
        pageDeletion: TrashService.PageDeletionInfo
    ) async throws {}
}

private struct PagePersistenceLogger: LoggerProtocol {
    func debug(_ message: @autoclosure () -> String) {}
    func info(_ message: @autoclosure () -> String) {}
    func error(_ message: @autoclosure () -> String) {}
}

@MainActor
private final class PagePersistenceCoordinator: EditJotCoordinatorProtocol {
    func shouldHandle(url: URL) -> Bool { false }
    func handle(url: URL) -> [UIViewController] { [] }
    func showShareJot(jotFileInfo: JotFile.Info, format: ShareFormat, configurePopoverAnchor: PopoverAnchor?) {}
    func showRenameAlert(jotFileInfo: JotFile.Info) {}
    func openDeleteJot(jotFileInfo: JotFile.Info) {}
    func openJot(jotFileInfo: JotFile.Info) {}
    func showInFiles(jotFileInfo: JotFile.Info) {}
    func showJotConflictPage(
        jotFileInfo: JotFile.Info,
        jotFileVersions: [JotFileVersion],
        onResult: @Sendable @escaping (JotConflictResult) -> Void
    ) {}
    func canGoBack() -> Bool { false }
    func goBack() {}
    func showInfoAlert(title: String, message: String) {}
    func showConfirmAlert(
        title: String,
        message: String?,
        confirmTitle: String,
        isDestructive: Bool,
        onConfirm: @escaping @Sendable () -> Void
    ) {}
    func showPDFPicker(onPick: @MainActor @Sendable @escaping (Data?) -> Void) {}
}

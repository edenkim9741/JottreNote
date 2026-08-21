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

import Foundation
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import Jottre

final class ExternalPDFImportTests: XCTestCase {

    @MainActor
    func testPDFDocumentPickerAllowsMultipleSelection() {
        let adapter = PDFDocumentPickerAdapter(onRoute: { _ in }, onCancel: { })
        let coordinator = CreateJotCoordinator(
            navigation: Self.makeNavigation(),
            repository: RecordingCreateJotRepository(),
            directory: nil,
            externalFileImportService: StubExternalFileImportService()
        )

        let picker = coordinator.makePDFPicker(delegate: adapter)

        XCTAssertTrue(picker.allowsMultipleSelection)
        XCTAssertTrue(picker.delegate === adapter)
    }

    @MainActor
    func testPDFDocumentPickerDelegateRoutesTheCompleteSelectionAsOneBatch() async {
        let firstURL = URL(fileURLWithPath: "/external/First.pdf")
        let secondURL = URL(fileURLWithPath: "/external/Second.pdf")
        let recorder = PickerRouteRecorder(
            expectation: expectation(description: "picker routed its selection")
        )
        let adapter = PDFDocumentPickerAdapter(
            onRoute: { route in recorder.record(route) },
            onCancel: { XCTFail("Unexpected picker cancellation") }
        )
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)

        adapter.documentPicker(
            picker,
            didPickDocumentsAt: [firstURL, secondURL]
        )
        await fulfillment(of: [recorder.expectation], timeout: 1)

        XCTAssertEqual(recorder.routes, [.batch([firstURL, secondURL])])
    }

    @MainActor
    func testPDFDocumentPickerDelegateRoutesOneSelectionAsSingle() async {
        let url = URL(fileURLWithPath: "/external/Only.pdf")
        let recorder = PickerRouteRecorder(
            expectation: expectation(description: "picker routed its selection")
        )
        let adapter = PDFDocumentPickerAdapter(
            onRoute: { route in recorder.record(route) },
            onCancel: { XCTFail("Unexpected picker cancellation") }
        )
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)

        adapter.documentPicker(picker, didPickDocumentsAt: [url])
        await fulfillment(of: [recorder.expectation], timeout: 1)

        XCTAssertEqual(recorder.routes, [.single(url)])
    }

    @MainActor
    func testPickedPDFBatchCreatesEveryNoteWithoutPresentingRenameUI() async {
        let firstURL = URL(fileURLWithPath: "/external/First.pdf")
        let secondURL = URL(fileURLWithPath: "/external/Second.pdf")
        let repository = RecordingCreateJotRepository()
        let presentations = NavigationPresentationRecorder()
        let coordinator = CreateJotCoordinator(
            navigation: Self.makeNavigation(presentationRecorder: presentations),
            repository: repository,
            directory: nil,
            externalFileImportService: StubExternalFileImportService()
        )
        let completed = expectation(description: "picker batch completed")
        coordinator.onEnd = { completed.fulfill() }

        coordinator.handlePickedPDFRoute(.batch([firstURL, secondURL]))
        await fulfillment(of: [completed], timeout: 1)

        let createdNames = await repository.createdNames()
        XCTAssertEqual(createdNames, ["First", "Second"])
        XCTAssertEqual(presentations.count(), 0)
    }

    @MainActor
    func testPickedPDFBatchReadFailureDoesNotFallBackToSingleFileUI() async {
        let readableURL = URL(fileURLWithPath: "/external/Readable.pdf")
        let rejectedURL = URL(fileURLWithPath: "/external/Rejected.pdf")
        let repository = RecordingCreateJotRepository()
        let presentations = NavigationPresentationRecorder()
        let coordinator = CreateJotCoordinator(
            navigation: Self.makeNavigation(presentationRecorder: presentations),
            repository: repository,
            directory: nil,
            externalFileImportService: StubExternalFileImportService(
                rejectedURLs: [rejectedURL]
            )
        )
        let completed = expectation(description: "partial picker batch completed")
        coordinator.onEnd = { completed.fulfill() }

        coordinator.handlePickedPDFRoute(.batch([readableURL, rejectedURL]))
        await fulfillment(of: [completed], timeout: 1)

        let createdNames = await repository.createdNames()
        XCTAssertEqual(createdNames, ["Readable"])
        XCTAssertEqual(presentations.count(), 0)
    }

    @MainActor
    func testExternalCoalescerRoutesOneMultiURLCallbackAsOneBatch() async {
        let firstURL = URL(fileURLWithPath: "/external/First.pdf")
        let secondURL = URL(fileURLWithPath: "/external/Second.pdf")
        let recorder = CoalescedRouteRecorder()
        let coalescer = ExternalPDFImportCoalescer(
            debounceNanoseconds: 60_000_000_000,
            onFlush: { urls in recorder.record(urls) }
        )

        coalescer.submit([firstURL, secondURL])
        await coalescer.flushNow()

        XCTAssertEqual(recorder.routes, [.batch([firstURL, secondURL])])
    }

    @MainActor
    func testExternalCoalescerCombinesRapidSingleURLCallbacksIntoOneBatch() async {
        let firstURL = URL(fileURLWithPath: "/external/First.pdf")
        let secondURL = URL(fileURLWithPath: "/external/Second.pdf")
        let recorder = CoalescedRouteRecorder()
        let coalescer = ExternalPDFImportCoalescer(
            debounceNanoseconds: 60_000_000_000,
            onFlush: { urls in recorder.record(urls) }
        )

        coalescer.submit([firstURL])
        coalescer.submit([secondURL])
        await coalescer.flushNow()

        XCTAssertEqual(recorder.routes, [.batch([firstURL, secondURL])])
    }

    @MainActor
    func testExternalCoalescerKeepsOneURLAsSingleImport() async {
        let url = URL(fileURLWithPath: "/external/Only.pdf")
        let recorder = CoalescedRouteRecorder()
        let coalescer = ExternalPDFImportCoalescer(
            debounceNanoseconds: 60_000_000_000,
            onFlush: { urls in recorder.record(urls) }
        )

        coalescer.submit([url])
        await coalescer.flushNow()

        XCTAssertEqual(recorder.routes, [.single(url)])
    }

    @MainActor
    func testExternalCoalescerBalancesEveryAcquiredSecurityScope() async {
        let firstURL = URL(fileURLWithPath: "/external/First.pdf")
        let secondURL = URL(fileURLWithPath: "/external/Second.pdf")
        let scopeRecorder = SecurityScopeRecorder()
        let recorder = CoalescedRouteRecorder()
        let coalescer = ExternalPDFImportCoalescer(
            debounceNanoseconds: 60_000_000_000,
            startAccessingSecurityScopedResource: scopeRecorder.startAccessing,
            stopAccessingSecurityScopedResource: scopeRecorder.stopAccessing,
            onFlush: { urls in recorder.record(urls) }
        )

        coalescer.submit([firstURL])
        coalescer.submit([secondURL])
        await coalescer.flushNow()

        let accesses = scopeRecorder.accesses()
        XCTAssertEqual(accesses.started, [firstURL, secondURL])
        XCTAssertEqual(accesses.stopped, [firstURL, secondURL])
        XCTAssertEqual(recorder.routes, [.batch([firstURL, secondURL])])
    }

    @MainActor
    func testPreaccessedScopesRemainActiveUntilRedirectedFlushFinishes() async {
        let firstURL = URL(fileURLWithPath: "/external/First.pdf")
        let secondURL = URL(fileURLWithPath: "/external/Second.pdf")
        let scopeRecorder = SecurityScopeRecorder()
        let gate = AsyncTestGate()
        let flushStarted = expectation(description: "redirected flush started")
        let coalescer = ExternalPDFImportCoalescer(
            debounceNanoseconds: 60_000_000_000,
            stopAccessingSecurityScopedResource: scopeRecorder.stopAccessing,
            onFlush: { _ in
                flushStarted.fulfill()
                await gate.wait()
            }
        )

        let submission = Task { @MainActor in
            await coalescer.submitPreaccessed(
                [firstURL, secondURL],
                securityScopedURLs: [firstURL, secondURL]
            )
        }
        await Task.yield()
        let flush = Task { @MainActor in await coalescer.flushNow() }
        await fulfillment(of: [flushStarted], timeout: 1)

        XCTAssertEqual(scopeRecorder.accesses().stopped, [])

        await gate.open()
        await flush.value
        await submission.value
        XCTAssertEqual(scopeRecorder.accesses().stopped, [firstURL, secondURL])
    }

    @MainActor
    func testSceneURLHandlerCoalescesCallbacksAndNeverPresentsBatchUI() async {
        let rejectedURL = URL(fileURLWithPath: "/external/A-Rejected.pdf")
        let readableURL = URL(fileURLWithPath: "/external/B-Readable.pdf")
        let batchCreated = expectation(description: "scene selected silent batch coordinator")
        let factory = SceneCreateJotFactoryRecorder(batchExpectation: batchCreated)
        let presentations = NavigationPresentationRecorder()
        let coordinator = SceneCoordinator(
            navigation: Self.makeNavigation(presentationRecorder: presentations),
            defaultsService: DefaultsService(userDefaults: .standard),
            applicationService: SceneApplicationServiceStub(),
            fileService: SceneFileServiceStub(),
            externalFileImportService: StubExternalFileImportService(
                rejectedURLs: [rejectedURL]
            ),
            logger: ImportTestLogger(),
            rootCoordinatorFactory: SceneRootCoordinatorFactoryStub(),
            editJotCoordinatorFactory: SceneEditJotCoordinatorFactoryStub(),
            createJotCoordinatorFactory: factory,
            onUpdateUserInterfaceStyle: { _ in },
            requestSceneSessionActivationProvider: { _ in }
        )

        // Mirrors two rapid `openURLContexts` deliveries containing one URL
        // each. Routing must use the aggregate count, even though one read fails.
        coordinator.handleURLs([rejectedURL])
        coordinator.handleURLs([readableURL])
        await fulfillment(of: [batchCreated], timeout: 2)
        await Task.yield()

        XCTAssertEqual(factory.singleCreationCount, 0)
        XCTAssertEqual(factory.batchNames, [["B-Readable"]])
        XCTAssertEqual(presentations.count(), 0)
    }

    func testRouteUsesOriginalURLCount() {
        let firstURL = URL(fileURLWithPath: "/external/First.pdf")
        let secondURL = URL(fileURLWithPath: "/external/Second.pdf")

        XCTAssertEqual(ExternalPDFImportRoute(urls: []), .none)
        XCTAssertEqual(ExternalPDFImportRoute(urls: [firstURL]), .single(firstURL))
        XCTAssertEqual(
            ExternalPDFImportRoute(urls: [firstURL, secondURL]),
            .batch([firstURL, secondURL])
        )
    }

    func testSuggestedTitleRemovesOnlyThePDFExtension() {
        let url = URL(fileURLWithPath: "/external/Quarter.final.PDF")

        XCTAssertEqual(ExternalPDFImportRoute.suggestedTitle(for: url), "Quarter.final")
    }

    func testExternalReaderBalancesSecurityScopeForEverySuccessAndFailure() throws {
        let recorder = SecurityScopeRecorder()
        let service = ExternalFileImportService(
            startAccessingSecurityScopedResource: recorder.startAccessing,
            stopAccessingSecurityScopedResource: recorder.stopAccessing
        )
        let readableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalPDFImportTests-\(UUID().uuidString).pdf")
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalPDFImportTests-missing-\(UUID().uuidString).pdf")
        let expectedData = Data("PDF data".utf8)
        try expectedData.write(to: readableURL)
        defer { try? FileManager.default.removeItem(at: readableURL) }

        XCTAssertEqual(try service.readExternalFile(sourceURL: readableURL), expectedData)
        XCTAssertThrowsError(try service.readExternalFile(sourceURL: missingURL))

        let accesses = recorder.accesses()
        XCTAssertEqual(accesses.started, [readableURL, missingURL])
        XCTAssertEqual(accesses.stopped, [readableURL, missingURL])
    }

    func testBatchCollisionResolutionUsesIncrementingSuffixes() async throws {
        let repository = RecordingCreateJotRepository(existingNames: ["Report"])

        let first = try await repository.createJotResolvingNameCollision(
            name: "Report",
            directory: nil,
            pdfData: Data([1])
        )
        let second = try await repository.createJotResolvingNameCollision(
            name: "Report",
            directory: nil,
            pdfData: Data([2])
        )

        XCTAssertEqual(first.name, "Report 2")
        XCTAssertEqual(second.name, "Report 3")
        let createdNames = await repository.createdNames()
        XCTAssertEqual(createdNames, ["Report 2", "Report 3"])
    }

    @MainActor
    func testBatchContinuesAfterIndividualCreationFailure() async {
        let rejectedData = Data([0])
        let repository = RecordingCreateJotRepository(rejectedData: rejectedData)
        let coordinator = CreateJotBatchCoordinator(
            repository: repository,
            directory: nil,
            pdfs: [
                (data: Data([1]), name: "First"),
                (data: rejectedData, name: "Broken"),
                (data: Data([2]), name: "Last"),
            ],
            logger: ImportTestLogger()
        )
        let completed = expectation(description: "batch completed")
        var completionCount = 0
        coordinator.onEnd = {
            completionCount += 1
            completed.fulfill()
        }

        coordinator.start()
        await fulfillment(of: [completed], timeout: 1)

        let createdNames = await repository.createdNames()
        XCTAssertEqual(createdNames, ["First", "Last"])
        XCTAssertEqual(completionCount, 1)
    }

    @MainActor
    func testBatchRetainsItsWorkUntilCreationFinishes() async {
        let repository = RecordingCreateJotRepository()
        let completed = expectation(description: "batch completed after coordinator release")
        var coordinator: CreateJotBatchCoordinator? = CreateJotBatchCoordinator(
            repository: repository,
            directory: nil,
            pdfs: [(data: Data([1]), name: "Retained")],
            logger: ImportTestLogger()
        )
        coordinator?.onEnd = { completed.fulfill() }

        coordinator?.start()
        coordinator = nil
        await fulfillment(of: [completed], timeout: 1)

        let createdNames = await repository.createdNames()
        XCTAssertEqual(createdNames, ["Retained"])
    }

    private static func makeNavigation(
        presentationRecorder: NavigationPresentationRecorder? = nil
    ) -> Navigation {
        Navigation(
            openURLProvider: { _ in },
            openExternalURLProvider: { _ in },
            openSceneProvider: { _ in },
            presentViewControllerProvider: { viewController, _ in
                presentationRecorder?.record(viewController)
            },
            dismissViewControllerProvider: { _, completion in completion?() },
            popViewControllerProvider: { _ in },
            getViewControllersProvider: { [] }
        )
    }
}

@MainActor
private final class PickerRouteRecorder {

    let expectation: XCTestExpectation
    private(set) var routes: [ExternalPDFImportRoute] = []

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func record(_ route: ExternalPDFImportRoute) {
        routes.append(route)
        expectation.fulfill()
    }
}

@MainActor
private final class CoalescedRouteRecorder {

    private(set) var routes: [ExternalPDFImportRoute] = []

    func record(_ urls: [URL]) {
        routes.append(ExternalPDFImportRoute(urls: urls))
    }
}

private struct StubExternalFileImportService: ExternalFileImportServiceProtocol {

    enum Failure: Error {
        case rejected
    }

    let rejectedURLs: Set<URL>

    init(rejectedURLs: Set<URL> = []) {
        self.rejectedURLs = rejectedURLs
    }

    func readExternalFile(sourceURL: URL) throws -> Data {
        guard !rejectedURLs.contains(sourceURL) else { throw Failure.rejected }
        return Data(sourceURL.lastPathComponent.utf8)
    }
}

private final class NavigationPresentationRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var presentationCount = 0

    func record(_ viewController: UIViewController) {
        lock.withLock { presentationCount += 1 }
    }

    func count() -> Int {
        lock.withLock { presentationCount }
    }
}

private final class SecurityScopeRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var startedURLs = [URL]()
    private var stoppedURLs = [URL]()

    func startAccessing(_ url: URL) -> Bool {
        lock.lock()
        startedURLs.append(url)
        lock.unlock()
        return true
    }

    func stopAccessing(_ url: URL) {
        lock.lock()
        stoppedURLs.append(url)
        lock.unlock()
    }

    func accesses() -> (started: [URL], stopped: [URL]) {
        lock.lock()
        defer { lock.unlock() }
        return (startedURLs, stoppedURLs)
    }
}

private actor AsyncTestGate {

    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}

@MainActor
private struct SceneApplicationServiceStub: ApplicationServiceProtocol {

    func supportsMultipleScenes() -> Bool { false }
    func open(url: URL) { }
    func canOpen(url: URL) -> Bool { false }
}

private final class SceneFileServiceStub: FileServiceProtocol, @unchecked Sendable {

    func isEnabled() -> Bool { true }
    func initializeDocumentsDirectory() async throws { }
    func documentsDirectory() async throws -> URL? { URL(fileURLWithPath: "/documents") }
    func temporaryDirectory() -> URL { URL(fileURLWithPath: "/tmp") }
    func listContents(directory: URL, properties: [URLResourceKey]) throws -> [URL] { [] }
    func directoryChanges(directory: URL) -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func readFile(fileURL: URL) throws -> Data { throw CocoaError(.fileNoSuchFile) }
    func writeFile(fileURL: URL, data: Data) throws { }
    func createFile(fileURL: URL, data: Data) throws { }
    func fileExists(fileURL: URL) -> Bool { false }
    func removeFile(fileURL: URL) throws { }
    func moveFile(fileURL: URL, newFileURL: URL) throws { }
    func duplicateFile(fileURL: URL) throws -> URL { fileURL }
    func createDirectory(directoryURL: URL) throws { }
}

@MainActor
private final class SceneNavigationCoordinatorStub: NavigationCoordinator {

    func shouldHandle(url: URL) -> Bool { false }
    func handle(url: URL) -> [UIViewController] { [] }
}

@MainActor
private struct SceneRootCoordinatorFactoryStub: RootCoordinatorFactoryProtocol {

    func make(navigation: Navigation) -> NavigationCoordinator {
        SceneNavigationCoordinatorStub()
    }
}

@MainActor
private struct SceneEditJotCoordinatorFactoryStub: EditJotCoordinatorFactoryProtocol {

    func make(navigation: Navigation) -> NavigationCoordinator {
        SceneNavigationCoordinatorStub()
    }
}

@MainActor
private final class SceneCreateJotFactoryRecorder: CreateJotCoordinatorFactoryProtocol {

    private let batchExpectation: XCTestExpectation
    private(set) var singleCreationCount = 0
    private(set) var batchNames = [[String]]()

    init(batchExpectation: XCTestExpectation) {
        self.batchExpectation = batchExpectation
    }

    func make(
        navigation: Navigation,
        directory: CreateJotCoordinatorFactory.Directory?,
        pdfData: Data?,
        pdfName: String?
    ) -> Coordinator {
        singleCreationCount += 1
        return ImmediateTestCoordinator()
    }

    func makeBatch(
        navigation: Navigation,
        directory: CreateJotCoordinatorFactory.Directory?,
        pdfs: [(data: Data, name: String)]
    ) -> Coordinator {
        batchNames.append(pdfs.map(\.name))
        batchExpectation.fulfill()
        return ImmediateTestCoordinator()
    }
}

@MainActor
private final class ImmediateTestCoordinator: Coordinator {

    var onEnd: (() -> Void)?

    func start() {
        onEnd?()
    }
}

private actor RecordingCreateJotRepository: CreateJotRepositoryProtocol {

    enum Failure: Error {
        case rejected
    }

    private var unavailableNames: Set<String>
    private var successfulNames = [String]()
    private let rejectedData: Data?

    init(existingNames: Set<String> = [], rejectedData: Data? = nil) {
        self.unavailableNames = existingNames
        self.rejectedData = rejectedData
    }

    func createJot(
        name: String,
        directory: CreateJotCoordinatorFactory.Directory?,
        pdfData: Data?
    ) async throws -> JotFile.Info {
        if pdfData == rejectedData {
            throw Failure.rejected
        }
        guard unavailableNames.insert(name).inserted else {
            throw CreateJotRepository.Failure.fileExists
        }
        successfulNames.append(name)
        return JotFile.Info(
            url: URL(fileURLWithPath: "/documents/\(name).jot"),
            name: name,
            modificationDate: nil
        )
    }

    func importJotFile(
        name: String,
        data: Data,
        directory: CreateJotCoordinatorFactory.Directory?
    ) async throws -> JotFile.Info {
        throw Failure.rejected
    }

    func createdNames() -> [String] {
        successfulNames
    }
}

private struct ImportTestLogger: LoggerProtocol {

    func debug(_ message: @autoclosure () -> String) { }
    func info(_ message: @autoclosure () -> String) { }
    func error(_ message: @autoclosure () -> String) { }
}

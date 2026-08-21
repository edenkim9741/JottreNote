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
@preconcurrency import PencilKit
import XCTest
@testable import Jottre

final class CorePersistenceTests: XCTestCase {

    func testLegacyJotDecodesMissingOptionalMetadata() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "Calculator Pro", withExtension: "jot")
        )
        let data = try Data(contentsOf: fixtureURL)

        let jot = try PropertyListDecoder().decode(Jot.self, from: data)

        XCTAssertEqual(jot.version, 3)
        XCTAssertEqual(jot.width, 1200)
        XCTAssertEqual(jot.extraPages, 0)
        XCTAssertEqual(jot.pdfInsertedPageSlots, [])
        XCTAssertEqual(jot.strokePageIndices, [])
    }

    func testJotWithoutVersionUsesLegacyVersionAndSafeDefaults() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "drawing": PKDrawing().dataRepresentation(),
                "width": 900.0,
            ],
            format: .binary,
            options: 0
        )

        let jot = try PropertyListDecoder().decode(Jot.self, from: data)

        XCTAssertEqual(jot.version, 1)
        XCTAssertEqual(jot.width, 900)
        XCTAssertEqual(jot.extraPages, 0)
    }

    func testJotFileServiceWritesBinaryPlistAndPreservesWidth() throws {
        let fileService = MemoryFileService()
        let service = JotFileService(fileService: fileService)
        let info = JotFile.Info(
            url: URL(fileURLWithPath: "/tmp/width.jot"),
            name: "width",
            modificationDate: nil
        )
        let source = JotFile(
            info: info,
            jot: Jot(drawing: PKDrawing().dataRepresentation(), width: 987)
        )

        try service.write(jotFile: source)

        let data = try XCTUnwrap(fileService.data(at: info.url))
        XCTAssertEqual(data.prefix(8), Data("bplist00".utf8))
        let decoded = try PropertyListDecoder().decode(Jot.self, from: data)
        XCTAssertEqual(decoded.width, 987)
    }

    func testLocalFileServiceCreateDoesNotOverwriteAnExistingFile() throws {
        let service = LocalFileService(fileManager: .default)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CorePersistenceTests-\(UUID().uuidString).jot")
        let originalData = Data([1])
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try service.createFile(fileURL: fileURL, data: originalData)

        XCTAssertThrowsError(try service.createFile(fileURL: fileURL, data: Data([2])))
        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
    }

    func testCreateJotRepositoryMapsExclusiveWriteCollisionToFileExists() async throws {
        let fileService = MemoryFileService()
        let repository = CreateJotRepository(
            fileService: fileService,
            jotFileService: JotFileService(fileService: fileService)
        )

        _ = try await repository.createJot(
            name: "Atomic",
            directory: nil,
            pdfData: Data([1])
        )

        do {
            _ = try await repository.createJot(
                name: "Atomic",
                directory: nil,
                pdfData: Data([2])
            )
            XCTFail("Expected an exclusive-create collision")
        } catch CreateJotRepository.Failure.fileExists {
            // Expected: the existing note was not replaced.
        }
    }

    func testPersistenceWriterSerializesAndCoalescesPendingSnapshots() async throws {
        let repository = RecordingEditJotRepository(writeDelay: .milliseconds(80))
        let writer = EditJotPersistenceWriter(
            jotFileInfo: Self.jotFileInfo,
            repository: repository,
            logger: SilentLogger(),
            debounceDuration: .milliseconds(10)
        )

        let firstSnapshot = snapshot(revision: 1, marker: 1)
        let secondSnapshot = snapshot(revision: 2, marker: 2)
        let thirdSnapshot = snapshot(revision: 3, marker: 3)
        async let firstWrite: Void = writer.saveImmediately(firstSnapshot)
        await repository.state.waitForFirstWriteToStart()
        await writer.schedule(secondSnapshot)
        await writer.schedule(thirdSnapshot)
        try await writer.saveImmediately(thirdSnapshot)
        try await firstWrite

        let result = await repository.state.result()
        XCTAssertEqual(result.completedMarkers, [1, 3])
        XCTAssertEqual(result.maximumConcurrentWrites, 1)
    }

    func testPersistenceWriterDoesNotRequeueAnActiveRevision() async throws {
        let repository = RecordingEditJotRepository(writeDelay: .milliseconds(80))
        let writer = EditJotPersistenceWriter(
            jotFileInfo: Self.jotFileInfo,
            repository: repository,
            logger: SilentLogger(),
            debounceDuration: .milliseconds(10)
        )
        let current = snapshot(revision: 2, marker: 2)
        let stale = snapshot(revision: 1, marker: 1)

        async let firstWrite: Void = writer.saveImmediately(current)
        await repository.state.waitForFirstWriteToStart()
        async let duplicateRequest: Void = writer.saveImmediately(current)
        try await writer.saveImmediately(stale)
        try await duplicateRequest
        try await firstWrite

        let result = await repository.state.result()
        XCTAssertEqual(result.completedMarkers, [2])
        XCTAssertEqual(result.maximumConcurrentWrites, 1)
    }

    func testPersistenceWriterDebouncesToLatestScheduledSnapshot() async {
        let repository = RecordingEditJotRepository(writeDelay: .milliseconds(5))
        let writer = EditJotPersistenceWriter(
            jotFileInfo: Self.jotFileInfo,
            repository: repository,
            logger: SilentLogger(),
            debounceDuration: .milliseconds(15)
        )

        await writer.schedule(snapshot(revision: 1, marker: 1))
        await writer.schedule(snapshot(revision: 2, marker: 2))
        await repository.state.waitForCompletedWrites(1)

        let result = await repository.state.result()
        XCTAssertEqual(result.completedMarkers, [2])
        XCTAssertEqual(result.maximumConcurrentWrites, 1)
    }

    func testDefaultsContinuationRemovalUsesStableToken() {
        let storage = DefaultsContinuationStorage()
        let key = DefaultsKey<Int>("test.subscription")
        let id = UUID()
        let (_, continuation) = AsyncStream<Int?>.makeStream()

        storage.add(continuation, id: id, defaultsKey: key)
        XCTAssertEqual(storage.continuationCount(defaultsKey: key), 1)

        storage.remove(id: id, defaultsKey: key)
        XCTAssertEqual(storage.continuationCount(defaultsKey: key), 0)
        continuation.finish()
    }

    func testDefaultsStreamDeliversUpdatesAndRemovesCanceledSubscriber() async {
        let suiteName = "CorePersistenceTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let service = DefaultsService(userDefaults: userDefaults)
        let key = DefaultsKey<Int>("stream.value")
        let receivedInitialValue = expectation(description: "initial value")
        let receivedUpdate = expectation(description: "updated value")

        let subscriber = Task {
            var isFirst = true
            for await value in service.getValueStream(key) {
                if isFirst {
                    isFirst = false
                    receivedInitialValue.fulfill()
                } else if value == 42 {
                    receivedUpdate.fulfill()
                }
            }
        }
        await fulfillment(of: [receivedInitialValue], timeout: 1)
        XCTAssertEqual(service.activeSubscriberCount(for: key), 1)

        service.set(key, value: 42)
        await fulfillment(of: [receivedUpdate], timeout: 1)
        XCTAssertEqual(service.getValue(key), 42)
        subscriber.cancel()
        await subscriber.value
        XCTAssertEqual(service.activeSubscriberCount(for: key), 0)
    }

    private static let jotFileInfo = JotFile.Info(
        url: URL(fileURLWithPath: "/tmp/writer.jot"),
        name: "writer",
        modificationDate: nil
    )

    private func snapshot(revision: UInt64, marker: Int) -> EditJotPersistenceSnapshot {
        EditJotPersistenceSnapshot(
            revision: revision,
            content: JotContent(
                drawing: PKDrawing(),
                width: Jot.defaultWidth,
                pdfData: nil,
                extraPages: marker,
                pdfInsertedPageSlots: [],
                strokePageIndices: []
            )
        )
    }
}

private struct SilentLogger: LoggerProtocol {
    func debug(_ message: @autoclosure () -> String) { }
    func info(_ message: @autoclosure () -> String) { }
    func error(_ message: @autoclosure () -> String) { }
}

private final class MemoryFileService: FileServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL: Data] = [:]

    func data(at url: URL) -> Data? {
        lock.withLock { files[url] }
    }

    func isEnabled() -> Bool { true }
    func initializeDocumentsDirectory() async throws { }
    func documentsDirectory() async throws -> URL? { URL(fileURLWithPath: "/tmp") }
    func temporaryDirectory() -> URL { URL(fileURLWithPath: "/tmp") }
    func listContents(directory: URL, properties: [URLResourceKey]) throws -> [URL] { [] }
    func directoryChanges(directory: URL) -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
    func readFile(fileURL: URL) throws -> Data {
        guard let data = data(at: fileURL) else { throw CocoaError(.fileNoSuchFile) }
        return data
    }
    func writeFile(fileURL: URL, data: Data) throws {
        lock.withLock { files[fileURL] = data }
    }
    func createFile(fileURL: URL, data: Data) throws {
        try lock.withLock {
            guard files[fileURL] == nil else { throw CocoaError(.fileWriteFileExists) }
            files[fileURL] = data
        }
    }
    func fileExists(fileURL: URL) -> Bool { data(at: fileURL) != nil }
    func removeFile(fileURL: URL) throws { lock.withLock { _ = files.removeValue(forKey: fileURL) } }
    func moveFile(fileURL: URL, newFileURL: URL) throws { }
    func duplicateFile(fileURL: URL) throws -> URL { fileURL }
    func createDirectory(directoryURL: URL) throws { }
}

private final class RecordingEditJotRepository: EditJotRepositoryProtocol, @unchecked Sendable {

    actor State {
        private var activeWrites = 0
        private var maximumConcurrentWrites = 0
        private var completedMarkers: [Int] = []
        private var firstWriteWaiters: [CheckedContinuation<Void, Never>] = []
        private var completionWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var hasStartedWrite = false

        func startedWrite() {
            activeWrites += 1
            maximumConcurrentWrites = max(maximumConcurrentWrites, activeWrites)
            guard !hasStartedWrite else { return }
            hasStartedWrite = true
            let waiters = firstWriteWaiters
            firstWriteWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func completedWrite(marker: Int) {
            completedMarkers.append(marker)
            activeWrites -= 1
            let ready = completionWaiters.filter { completedMarkers.count >= $0.count }
            completionWaiters.removeAll { completedMarkers.count >= $0.count }
            ready.forEach { $0.continuation.resume() }
        }

        func waitForFirstWriteToStart() async {
            guard !hasStartedWrite else { return }
            await withCheckedContinuation { firstWriteWaiters.append($0) }
        }

        func waitForCompletedWrites(_ count: Int) async {
            guard completedMarkers.count < count else { return }
            await withCheckedContinuation { continuation in
                completionWaiters.append((count, continuation))
            }
        }

        func result() -> (completedMarkers: [Int], maximumConcurrentWrites: Int) {
            (completedMarkers, maximumConcurrentWrites)
        }
    }

    let state = State()
    private let writeDelay: Duration

    init(writeDelay: Duration) {
        self.writeDelay = writeDelay
    }

    func readContent(
        jotFileInfo: JotFile.Info,
        onProgress: @Sendable (Double) -> Void
    ) async throws -> JotContent {
        throw CocoaError(.fileReadUnknown)
    }

    func writeContent(jotFileInfo: JotFile.Info, content: JotContent) async throws {
        await state.startedWrite()
        try await Task.sleep(for: writeDelay)
        await state.completedWrite(marker: content.extraPages)
    }

    func getConflictingVersions(jotFileInfo: JotFile.Info) -> [JotFileVersion]? { nil }
    func duplicate(jotFileInfo: JotFile.Info) throws -> JotFile.Info { jotFileInfo }
    func saveDeletedPageToTrash(
        strokes: [PKStroke],
        pageStartY: CGFloat,
        width: CGFloat,
        pageName: String,
        pageDeletion: TrashService.PageDeletionInfo
    ) async throws { }
}

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
import XCTest

@testable import Jottre

@MainActor
final class WebDAVAutoBackupSchedulerTests: XCTestCase {

    func testPolicyNormalizesDisabledAndExtremeIntervals() {
        XCTAssertEqual(WebDAVAutoBackupPolicy.normalizedIntervalMinutes(nil), 0)
        XCTAssertEqual(WebDAVAutoBackupPolicy.normalizedIntervalMinutes(-10), 0)
        XCTAssertEqual(WebDAVAutoBackupPolicy.normalizedIntervalMinutes(5), 5)
        XCTAssertEqual(
            WebDAVAutoBackupPolicy.normalizedIntervalMinutes(Int.max),
            WebDAVAutoBackupPolicy.maximumIntervalMinutes
        )
        XCTAssertEqual(WebDAVAutoBackupPolicy.intervalSeconds(5), 300)
        XCTAssertNil(
            WebDAVAutoBackupPolicy.earliestBeginDate(
                intervalMinutes: 0,
                now: Date(timeIntervalSince1970: 100)
            )
        )
        XCTAssertEqual(
            WebDAVAutoBackupPolicy.earliestBeginDate(
                intervalMinutes: 5,
                now: Date(timeIntervalSince1970: 100)
            ),
            Date(timeIntervalSince1970: 400)
        )
    }

    func testZeroDisablesAndASettingsUpdateStartsForegroundAndBackgroundScheduling() async {
        let fixture = makeFixture(intervalMinutes: 0)
        XCTAssertTrue(fixture.scheduler.registerBackgroundTask())
        fixture.scheduler.start()
        fixture.scheduler.sceneDidBecomeActive(identifier: "scene-a")

        XCTAssertTrue(fixture.backgroundScheduler.requests.isEmpty)
        XCTAssertEqual(
            fixture.backgroundScheduler.cancelledIdentifiers,
            [fixture.taskIdentifier]
        )
        let disabledPendingSleepCount = await fixture.sleeper.pendingCount()
        XCTAssertEqual(disabledPendingSleepCount, 0)

        fixture.defaultsService.set(.webDAVBackupIntervalMinutes, value: 2)
        await waitUntil {
            let pendingSleepCount = await fixture.sleeper.pendingCount()
            return fixture.backgroundScheduler.requests.count == 1
                && pendingSleepCount == 1
        }

        let request = fixture.backgroundScheduler.requests.last
        XCTAssertEqual(request?.identifier, fixture.taskIdentifier)
        XCTAssertEqual(request?.earliestBeginDate, fixture.now.addingTimeInterval(120))
        XCTAssertEqual(request?.requiresNetworkConnectivity, true)
        XCTAssertEqual(request?.requiresExternalPower, false)

        await fixture.sleeper.resumeNext()
        await waitUntil { await fixture.backupSpy.callCount() == 1 }
        XCTAssertEqual(fixture.flushSpy.callCount, 1)

        fixture.scheduler.stop()
    }

    func testLastActiveSceneResigningCancelsForegroundLoopAndResubmitsBackgroundWork() async {
        let fixture = makeFixture(intervalMinutes: 3)
        XCTAssertTrue(fixture.scheduler.registerBackgroundTask())
        fixture.scheduler.start()
        fixture.scheduler.sceneDidBecomeActive(identifier: "scene-a")
        fixture.scheduler.sceneDidBecomeActive(identifier: "scene-b")
        await waitUntil { await fixture.sleeper.pendingCount() == 1 }

        fixture.scheduler.sceneWillResignActive(identifier: "scene-a")
        let firstResignPendingSleepCount = await fixture.sleeper.pendingCount()
        XCTAssertEqual(firstResignPendingSleepCount, 1)

        fixture.scheduler.sceneWillResignActive(identifier: "scene-b")
        await waitUntil { await fixture.sleeper.pendingCount() == 0 }
        XCTAssertGreaterThanOrEqual(fixture.backgroundScheduler.requests.count, 2)
        let backupCallCount = await fixture.backupSpy.callCount()
        XCTAssertEqual(backupCallCount, 0)

        fixture.scheduler.stop()
    }

    func testBackgroundLaunchReschedulesAndCompletesAfterFlushAndBackup() async throws {
        let fixture = makeFixture(intervalMinutes: 5)
        XCTAssertTrue(fixture.scheduler.registerBackgroundTask())
        fixture.scheduler.start()
        let initialRequestCount = fixture.backgroundScheduler.requests.count

        let task = try XCTUnwrap(fixture.backgroundScheduler.launchRegisteredTask())
        await waitUntil { task.completions.count == 1 }

        XCTAssertEqual(task.completions, [true])
        XCTAssertEqual(fixture.flushSpy.callCount, 1)
        let backupCallCount = await fixture.backupSpy.callCount()
        XCTAssertEqual(backupCallCount, 1)
        XCTAssertGreaterThan(fixture.backgroundScheduler.requests.count, initialRequestCount)
        fixture.scheduler.stop()
    }

    func testBackgroundExpirationCancelsWorkAndCompletesAsFailure() async throws {
        let fixture = makeFixture(intervalMinutes: 5, backupDelay: .seconds(60))
        XCTAssertTrue(fixture.scheduler.registerBackgroundTask())
        fixture.scheduler.start()

        let task = try XCTUnwrap(fixture.backgroundScheduler.launchRegisteredTask())
        await waitUntil { await fixture.backupSpy.callCount() == 1 }
        task.expire()
        await waitUntil { task.completions.count == 1 }

        XCTAssertEqual(task.completions, [false])
        fixture.scheduler.stop()
    }

    func testFlushFailurePreventsAutomaticBackup() async throws {
        let fixture = makeFixture(intervalMinutes: 5, flushResult: false)
        XCTAssertTrue(fixture.scheduler.registerBackgroundTask())
        fixture.scheduler.start()

        let task = try XCTUnwrap(fixture.backgroundScheduler.launchRegisteredTask())
        await waitUntil { task.completions.count == 1 }

        XCTAssertEqual(task.completions, [false])
        let backupCallCount = await fixture.backupSpy.callCount()
        XCTAssertEqual(backupCallCount, 0)
        fixture.scheduler.stop()
    }

    func testEditorFlushRegistryUnregistersAndStopsAfterFailure() async {
        let registry = WebDAVEditorFlushRegistry()
        var calls: [Int] = []
        let first = registry.register {
            calls.append(1)
            return true
        }
        _ = registry.register {
            calls.append(2)
            return false
        }

        let succeeded = await registry.flushAll()
        XCTAssertFalse(succeeded)
        XCTAssertTrue(calls.contains(2))
        registry.unregister(first)
        XCTAssertEqual(registry.activeRegistrationCount, 1)
    }

    func testCancelledBackupDoesNotRemainQueuedInOperationGate() async {
        let gate = WebDAVBackupOperationGate()
        let holderAcquired = await gate.acquire()
        XCTAssertTrue(holderAcquired)

        let queued = Task { await gate.acquire() }
        await waitUntil { await gate.waitingOperationCount == 1 }
        queued.cancel()

        let queuedAcquired = await queued.value
        XCTAssertFalse(queuedAcquired)
        let waitingCount = await gate.waitingOperationCount
        XCTAssertEqual(waitingCount, 0)

        await gate.release()
        let nextAcquired = await gate.acquire()
        XCTAssertTrue(nextAcquired)
        await gate.release()
    }

    private struct Fixture {
        let scheduler: WebDAVAutoBackupScheduler
        let backgroundScheduler: TestBackgroundTaskScheduler
        let defaultsService: DefaultsService
        let sleeper: ManualSleeper
        let flushSpy: FlushSpy
        let backupSpy: BackupSpy
        let now: Date
        let taskIdentifier: String
        let suiteName: String
    }

    private func makeFixture(
        intervalMinutes: Int,
        flushResult: Bool = true,
        backupDelay: Duration? = nil
    ) -> Fixture {
        let suiteName = "WebDAVAutoBackupSchedulerTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        let defaultsService = DefaultsService(userDefaults: userDefaults)
        defaultsService.set(.webDAVBackupIntervalMinutes, value: intervalMinutes)

        let backgroundScheduler = TestBackgroundTaskScheduler()
        let sleeper = ManualSleeper()
        let flushSpy = FlushSpy(result: flushResult)
        let backupSpy = BackupSpy(delay: backupDelay)
        let now = Date(timeIntervalSince1970: 1_000)
        let taskIdentifier = "tests.webdav.backup.\(UUID().uuidString)"
        let scheduler = WebDAVAutoBackupScheduler(
            defaultsService: defaultsService,
            backgroundTaskScheduler: backgroundScheduler,
            flushEditors: { flushSpy.flush() },
            performBackup: { await backupSpy.run() },
            sleep: { duration in try await sleeper.sleep(for: duration) },
            now: { now },
            logger: AutoBackupSilentLogger(),
            backgroundTaskIdentifier: taskIdentifier
        )
        return Fixture(
            scheduler: scheduler,
            backgroundScheduler: backgroundScheduler,
            defaultsService: defaultsService,
            sleeper: sleeper,
            flushSpy: flushSpy,
            backupSpy: backupSpy,
            now: now,
            taskIdentifier: taskIdentifier,
            suiteName: suiteName
        )
    }

    private func waitUntil(
        timeoutIterations: Int = 500,
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous scheduler state")
    }
}

@MainActor
private final class TestBackgroundTaskScheduler: WebDAVBackgroundTaskScheduling {

    struct Request {
        let identifier: String
        let earliestBeginDate: Date
        let requiresNetworkConnectivity: Bool
        let requiresExternalPower: Bool
    }

    private var launchHandler: LaunchHandler?
    private(set) var requests: [Request] = []
    private(set) var cancelledIdentifiers: [String] = []

    func register(identifier: String, launchHandler: @escaping LaunchHandler) -> Bool {
        self.launchHandler = launchHandler
        return true
    }

    func submitProcessingTask(
        identifier: String,
        earliestBeginDate: Date,
        requiresNetworkConnectivity: Bool,
        requiresExternalPower: Bool
    ) throws {
        requests.append(
            Request(
                identifier: identifier,
                earliestBeginDate: earliestBeginDate,
                requiresNetworkConnectivity: requiresNetworkConnectivity,
                requiresExternalPower: requiresExternalPower
            )
        )
    }

    func cancel(identifier: String) {
        cancelledIdentifiers.append(identifier)
    }

    func launchRegisteredTask() -> TestBackgroundTask? {
        guard let launchHandler else { return nil }
        let task = TestBackgroundTask()
        launchHandler(task)
        return task
    }
}

@MainActor
private final class TestBackgroundTask: WebDAVBackgroundTaskHandle {

    private var expirationHandler: (@Sendable () -> Void)?
    private(set) var completions: [Bool] = []

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        expirationHandler = handler
    }

    func clearExpirationHandler() {
        expirationHandler = nil
    }

    func complete(success: Bool) {
        completions.append(success)
    }

    func expire() {
        expirationHandler?()
    }
}

private actor ManualSleeper {

    private struct Waiter {
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [UUID: Waiter] = [:]
    private var order: [UUID] = []

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(duration: duration, continuation: continuation)
                order.append(id)
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func pendingCount() -> Int {
        waiters.count
    }

    func resumeNext() {
        guard let id = order.first else { return }
        order.removeFirst()
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume()
    }

    private func cancel(id: UUID) {
        order.removeAll { $0 == id }
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }
}

@MainActor
private final class FlushSpy {
    private(set) var callCount = 0
    let result: Bool

    init(result: Bool) {
        self.result = result
    }

    func flush() -> Bool {
        callCount += 1
        return result
    }
}

private actor BackupSpy {
    private var calls = 0
    let delay: Duration?

    init(delay: Duration?) {
        self.delay = delay
    }

    func run() async -> Bool {
        calls += 1
        if let delay {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    func callCount() -> Int {
        calls
    }
}

private struct AutoBackupSilentLogger: LoggerProtocol {
    func debug(_ message: @autoclosure () -> String) {}
    func info(_ message: @autoclosure () -> String) {}
    func error(_ message: @autoclosure () -> String) {}
}

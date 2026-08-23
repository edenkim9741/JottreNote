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

@preconcurrency import BackgroundTasks
import Foundation

enum WebDAVAutoBackupPolicy {

    static let disabledIntervalMinutes = 0

    /// Bounds user input so converting minutes to seconds stays predictable and
    /// an accidental pasted integer cannot create an effectively immortal task.
    static let maximumIntervalMinutes = 365 * 24 * 60

    static func normalizedIntervalMinutes(_ value: Int?) -> Int {
        min(max(value ?? disabledIntervalMinutes, disabledIntervalMinutes), maximumIntervalMinutes)
    }

    static func intervalSeconds(_ value: Int?) -> TimeInterval {
        TimeInterval(normalizedIntervalMinutes(value)) * 60
    }

    static func earliestBeginDate(intervalMinutes: Int, now: Date) -> Date? {
        let seconds = intervalSeconds(intervalMinutes)
        guard seconds > 0 else { return nil }
        return now.addingTimeInterval(seconds)
    }
}

@MainActor
protocol WebDAVBackgroundTaskHandle: AnyObject {

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void)
    func clearExpirationHandler()
    func complete(success: Bool)
}

@MainActor
protocol WebDAVBackgroundTaskScheduling: AnyObject {

    typealias LaunchHandler = @MainActor @Sendable (any WebDAVBackgroundTaskHandle) -> Void

    @discardableResult
    func register(identifier: String, launchHandler: @escaping LaunchHandler) -> Bool

    func submitProcessingTask(
        identifier: String,
        earliestBeginDate: Date,
        requiresNetworkConnectivity: Bool,
        requiresExternalPower: Bool
    ) throws

    func cancel(identifier: String)
}

@MainActor
private final class SystemWebDAVBackgroundTaskHandle: WebDAVBackgroundTaskHandle {

    private let task: BGTask

    init(task: BGTask) {
        self.task = task
    }

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        task.expirationHandler = handler
    }

    func clearExpirationHandler() {
        task.expirationHandler = nil
    }

    func complete(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

@MainActor
final class SystemWebDAVBackgroundTaskScheduler: WebDAVBackgroundTaskScheduling {

    func register(identifier: String, launchHandler: @escaping LaunchHandler) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { task in
            // The framework invokes this handler on the queue supplied above.
            MainActor.assumeIsolated {
                launchHandler(SystemWebDAVBackgroundTaskHandle(task: task))
            }
        }
    }

    func submitProcessingTask(
        identifier: String,
        earliestBeginDate: Date,
        requiresNetworkConnectivity: Bool,
        requiresExternalPower: Bool
    ) throws {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBeginDate
        request.requiresNetworkConnectivity = requiresNetworkConnectivity
        request.requiresExternalPower = requiresExternalPower
        try BGTaskScheduler.shared.submit(request)
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

/// Owns the single in-app cadence and the single BackgroundTasks request for
/// every connected scene. Heavy file, PDF, and network work is delegated to a
/// Sendable backup operation and never performed on the main actor.
@MainActor
final class WebDAVAutoBackupScheduler {

    static let backgroundTaskIdentifier = "com.edenkim.jottre.webdav-auto-backup"

    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias FlushEditors = @MainActor @Sendable () async -> Bool
    typealias PerformBackup = @Sendable () async -> Bool

    private let defaultsService: DefaultsServiceProtocol
    private let backgroundTaskScheduler: any WebDAVBackgroundTaskScheduling
    private let flushEditors: FlushEditors
    private let performBackup: PerformBackup
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    private let logger: LoggerProtocol
    private let backgroundTaskIdentifier: String

    private var activeSceneIdentifiers = Set<String>()
    private var intervalMinutes = -1
    private var isBackgroundTaskRegistered = false
    private var configurationTask: Task<Void, Never>?
    private var foregroundLoopTask: Task<Void, Never>?
    private var backgroundWorkTask: Task<Void, Never>?
    private var backgroundWorkGeneration: UUID?

    init(
        defaultsService: DefaultsServiceProtocol,
        backgroundTaskScheduler: any WebDAVBackgroundTaskScheduling,
        flushEditors: @escaping FlushEditors,
        performBackup: @escaping PerformBackup,
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) },
        now: @escaping @Sendable () -> Date = Date.init,
        logger: LoggerProtocol,
        backgroundTaskIdentifier: String = WebDAVAutoBackupScheduler.backgroundTaskIdentifier
    ) {
        self.defaultsService = defaultsService
        self.backgroundTaskScheduler = backgroundTaskScheduler
        self.flushEditors = flushEditors
        self.performBackup = performBackup
        self.sleep = sleep
        self.now = now
        self.logger = logger
        self.backgroundTaskIdentifier = backgroundTaskIdentifier
    }

    @discardableResult
    func registerBackgroundTask() -> Bool {
        guard !isBackgroundTaskRegistered else { return true }
        let registered = backgroundTaskScheduler.register(
            identifier: backgroundTaskIdentifier
        ) { [weak self] task in
            self?.handleBackgroundTask(task)
        }
        isBackgroundTaskRegistered = registered
        if !registered {
            logger.error("Failed to register WebDAV background task")
        }
        return registered
    }

    func start() {
        guard configurationTask == nil else { return }
        applyInterval(defaultsService.getValue(.webDAVBackupIntervalMinutes))

        let updates = defaultsService.getValueStream(
            DefaultsKey<Int>.webDAVBackupIntervalMinutes
        )
        configurationTask = Task { @MainActor [weak self] in
            for await value in updates {
                guard !Task.isCancelled, let self else { return }
                self.applyInterval(value)
            }
        }
    }

    func stop() {
        configurationTask?.cancel()
        configurationTask = nil
        foregroundLoopTask?.cancel()
        foregroundLoopTask = nil
        backgroundWorkTask?.cancel()
        backgroundWorkTask = nil
        backgroundWorkGeneration = nil
        activeSceneIdentifiers.removeAll()
        backgroundTaskScheduler.cancel(identifier: backgroundTaskIdentifier)
    }

    func sceneDidBecomeActive(identifier: String) {
        let wasInactive = activeSceneIdentifiers.isEmpty
        activeSceneIdentifiers.insert(identifier)
        if wasInactive {
            restartForegroundLoop()
        }
    }

    func sceneWillResignActive(identifier: String) {
        activeSceneIdentifiers.remove(identifier)
        if activeSceneIdentifiers.isEmpty {
            restartForegroundLoop()
            scheduleBackgroundTaskIfNeeded()
        }
    }

    func sceneDidDisconnect(identifier: String) {
        activeSceneIdentifiers.remove(identifier)
        if activeSceneIdentifiers.isEmpty {
            restartForegroundLoop()
        }
    }

    /// Re-reads the value immediately. Settings normally propagate through the
    /// Defaults stream; this hook is useful after bulk defaults restoration.
    func refreshConfiguration() {
        applyInterval(defaultsService.getValue(.webDAVBackupIntervalMinutes))
    }

    private func applyInterval(_ rawValue: Int?) {
        let normalized = WebDAVAutoBackupPolicy.normalizedIntervalMinutes(rawValue)
        guard normalized != intervalMinutes else { return }
        intervalMinutes = normalized
        restartForegroundLoop()

        if normalized == WebDAVAutoBackupPolicy.disabledIntervalMinutes {
            backgroundTaskScheduler.cancel(identifier: backgroundTaskIdentifier)
        } else {
            scheduleBackgroundTaskIfNeeded()
        }
    }

    private func restartForegroundLoop() {
        foregroundLoopTask?.cancel()
        foregroundLoopTask = nil

        guard !activeSceneIdentifiers.isEmpty,
            intervalMinutes > WebDAVAutoBackupPolicy.disabledIntervalMinutes
        else { return }

        let scheduledInterval = intervalMinutes
        let delay = Duration.seconds(
            WebDAVAutoBackupPolicy.intervalSeconds(scheduledInterval)
        )
        let sleep = sleep
        foregroundLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(delay)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                    let self,
                    self.intervalMinutes == scheduledInterval,
                    !self.activeSceneIdentifiers.isEmpty
                else { return }
                _ = await self.runAutomaticBackup()
            }
        }
    }

    private func runAutomaticBackup() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard await flushEditors(), !Task.isCancelled else { return false }
        return await performBackup()
    }

    private func scheduleBackgroundTaskIfNeeded() {
        guard isBackgroundTaskRegistered,
            let earliestBeginDate = WebDAVAutoBackupPolicy.earliestBeginDate(
                intervalMinutes: intervalMinutes,
                now: now()
            )
        else {
            if intervalMinutes <= WebDAVAutoBackupPolicy.disabledIntervalMinutes {
                backgroundTaskScheduler.cancel(identifier: backgroundTaskIdentifier)
            }
            return
        }

        do {
            // Keep exactly one pending request. This also replaces an older
            // earliestBeginDate immediately when the user changes the cadence.
            backgroundTaskScheduler.cancel(identifier: backgroundTaskIdentifier)
            try backgroundTaskScheduler.submitProcessingTask(
                identifier: backgroundTaskIdentifier,
                earliestBeginDate: earliestBeginDate,
                requiresNetworkConnectivity: true,
                requiresExternalPower: false
            )
        } catch {
            // Scheduling is best-effort (for example, Background App Refresh
            // may be disabled). The foreground loop continues unaffected.
            logger.error("Failed to schedule WebDAV background task: \(error)")
        }
    }

    private func handleBackgroundTask(_ task: any WebDAVBackgroundTaskHandle) {
        // Apple recommends scheduling the next request as soon as a task is
        // launched so expiration or a transient network failure cannot break
        // the recurring lifecycle.
        scheduleBackgroundTaskIfNeeded()

        backgroundWorkTask?.cancel()
        let generation = UUID()
        backgroundWorkGeneration = generation
        let work = Task { @MainActor [weak self, task] in
            guard let self else {
                task.complete(success: false)
                return
            }
            let success = await self.runAutomaticBackup()
            let completedSuccessfully = success && !Task.isCancelled
            task.clearExpirationHandler()
            task.complete(success: completedSuccessfully)
            if self.backgroundWorkGeneration == generation {
                self.backgroundWorkTask = nil
                self.backgroundWorkGeneration = nil
            }
        }
        task.setExpirationHandler {
            work.cancel()
        }
        backgroundWorkTask = work
    }

    deinit {
        configurationTask?.cancel()
        foregroundLoopTask?.cancel()
        backgroundWorkTask?.cancel()
    }
}

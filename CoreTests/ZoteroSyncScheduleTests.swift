import XCTest

@testable import Jottre

final class ZoteroSyncScheduleTests: XCTestCase {
    func testAutomaticTriggersAreLimitedToTenMinutes() {
        let lastAttempt = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(ZoteroSyncSchedule.shouldRun(
            .networkReconnect,
            lastAttempt: lastAttempt,
            now: lastAttempt.addingTimeInterval(599)
        ))
        XCTAssertTrue(ZoteroSyncSchedule.shouldRun(
            .periodic,
            lastAttempt: lastAttempt,
            now: lastAttempt.addingTimeInterval(600)
        ))
    }

    func testExplicitTriggersBypassAutomaticInterval() {
        let lastAttempt = Date(timeIntervalSince1970: 1_000)
        let now = lastAttempt.addingTimeInterval(1)

        XCTAssertTrue(ZoteroSyncSchedule.shouldRun(.appLaunch, lastAttempt: lastAttempt, now: now))
        XCTAssertTrue(ZoteroSyncSchedule.shouldRun(.editorFinished, lastAttempt: lastAttempt, now: now))
        XCTAssertTrue(ZoteroSyncSchedule.shouldRun(.manual, lastAttempt: lastAttempt, now: now))
        XCTAssertTrue(ZoteroSyncSchedule.shouldRun(.accountChanged, lastAttempt: lastAttempt, now: now))
    }
}

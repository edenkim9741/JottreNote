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

import CoreGraphics
import XCTest

@testable import Jottre

final class EndpointHoldDetectorTests: XCTestCase {

    func testHoldBecomesEligibleAtConfiguredDeadline() throws {
        var detector = makeDetector()
        detector.begin(at: CGPoint(x: 10, y: 20), timestamp: 1)

        XCTAssertEqual(detector.phase, .tracking)
        XCTAssertEqual(try XCTUnwrap(detector.deadline), 1.4, accuracy: 0.0001)
        XCTAssertFalse(detector.update(at: 1.399))
        XCTAssertTrue(detector.update(at: 1.4))
        XCTAssertEqual(detector.phase, .held)
        XCTAssertTrue(detector.end(at: 1.41))
        XCTAssertTrue(detector.shouldSnapAfterStrokeCommit)
    }

    func testSubToleranceJitterDoesNotResetDeadline() throws {
        var detector = makeDetector()
        detector.begin(at: .zero, timestamp: 5)
        let generation = detector.generation

        XCTAssertFalse(detector.move(to: CGPoint(x: 3, y: 4), timestamp: 5.2))
        XCTAssertEqual(detector.generation, generation)
        XCTAssertEqual(try XCTUnwrap(detector.deadline), 5.4, accuracy: 0.0001)
        XCTAssertTrue(detector.update(at: 5.4, generation: generation))
    }

    func testMovementBeyondToleranceRevokesHoldAndRestartsDeadline() throws {
        var detector = makeDetector()
        detector.begin(at: .zero, timestamp: 2)
        let staleGeneration = detector.generation
        XCTAssertTrue(detector.update(at: 2.4))

        XCTAssertTrue(detector.move(to: CGPoint(x: 6, y: 0), timestamp: 2.5))
        XCTAssertEqual(detector.phase, .tracking)
        XCTAssertNotEqual(detector.generation, staleGeneration)
        XCTAssertEqual(try XCTUnwrap(detector.deadline), 2.9, accuracy: 0.0001)
        XCTAssertFalse(detector.update(at: 2.9, generation: staleGeneration))
        XCTAssertFalse(detector.end(at: 2.89))
    }

    func testEndingAtDeadlineEvaluatesWithoutTimerDelivery() {
        var detector = makeDetector()
        detector.begin(at: CGPoint(x: 1, y: 1), timestamp: 10)

        XCTAssertTrue(detector.end(at: 10.4))
        XCTAssertEqual(detector.phase, .ended(shouldSnap: true))
    }

    func testEarlyEndIsNotEligible() {
        var detector = makeDetector()
        detector.begin(at: .zero, timestamp: 0)

        XCTAssertFalse(detector.end(at: 0.399))
        XCTAssertEqual(detector.phase, .ended(shouldSnap: false))
        XCTAssertFalse(detector.shouldSnapAfterStrokeCommit)
    }

    func testCancellationInvalidatesScheduledGeneration() {
        var detector = makeDetector()
        detector.begin(at: .zero, timestamp: 0)
        let staleGeneration = detector.generation

        detector.cancel()

        XCTAssertEqual(detector.phase, .cancelled)
        XCTAssertNil(detector.deadline)
        XCTAssertFalse(detector.update(at: 1, generation: staleGeneration))
        XCTAssertFalse(detector.shouldSnapAfterStrokeCommit)
    }

    func testResetAllowsACompletelyNewGesture() {
        var detector = makeDetector()
        detector.begin(at: .zero, timestamp: 0)
        _ = detector.end(at: 0.4)
        detector.reset()

        XCTAssertEqual(detector.phase, .idle)
        XCTAssertNil(detector.anchorLocation)
        XCTAssertNil(detector.stationarySince)

        detector.begin(at: CGPoint(x: 50, y: 60), timestamp: 2)
        XCTAssertEqual(detector.phase, .tracking)
        XCTAssertEqual(detector.anchorLocation, CGPoint(x: 50, y: 60))
    }

    func testConfigurationClampsInvalidNegativeValues() {
        let configuration = EndpointHoldDetector.Configuration(
            holdDuration: -1,
            movementTolerance: -2
        )

        XCTAssertEqual(configuration.holdDuration, 0)
        XCTAssertEqual(configuration.movementTolerance, 0)
    }

    private func makeDetector() -> EndpointHoldDetector {
        EndpointHoldDetector(configuration: .init(holdDuration: 0.4, movementTolerance: 5))
    }
}

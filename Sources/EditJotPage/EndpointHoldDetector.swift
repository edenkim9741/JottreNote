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
import Foundation

/// Pure state machine for the stationary-at-end portion of draw-and-hold.
///
/// UIKit owns scheduling and feeds monotonically increasing timestamps into
/// this value. Keeping time and touch delivery outside the detector makes the
/// behavior deterministic in tests and lets a controller invalidate stale
/// scheduled tasks with `generation`.
struct EndpointHoldDetector: Sendable {

    struct Configuration: Equatable, Sendable {
        let holdDuration: TimeInterval
        let movementTolerance: CGFloat

        init(holdDuration: TimeInterval = 0.42, movementTolerance: CGFloat = 5) {
            self.holdDuration = max(0, holdDuration)
            self.movementTolerance = max(0, movementTolerance)
        }
    }

    enum Phase: Equatable, Sendable {
        case idle
        case tracking
        case held
        case ended(shouldSnap: Bool)
        case cancelled
    }

    let configuration: Configuration
    private(set) var phase = Phase.idle
    private(set) var generation = UInt64.zero
    private(set) var anchorLocation: CGPoint?
    private(set) var stationarySince: TimeInterval?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var deadline: TimeInterval? {
        guard phase == .tracking || phase == .held, let stationarySince else { return nil }
        return stationarySince + configuration.holdDuration
    }

    var isHeld: Bool {
        if phase == .held { return true }
        if case let .ended(shouldSnap) = phase { return shouldSnap }
        return false
    }

    var shouldSnapAfterStrokeCommit: Bool {
        guard case let .ended(shouldSnap) = phase else { return false }
        return shouldSnap
    }

    /// Starts a new candidate and invalidates any timer from an earlier gesture.
    mutating func begin(at location: CGPoint, timestamp: TimeInterval) {
        generation &+= 1
        phase = .tracking
        anchorLocation = location
        stationarySince = timestamp
    }

    /// Records endpoint movement. Returns `true` when a significant movement
    /// reset the stationary deadline and the caller should schedule a new timer.
    @discardableResult
    mutating func move(to location: CGPoint, timestamp: TimeInterval) -> Bool {
        guard phase == .tracking || phase == .held, let anchorLocation else { return false }
        let movement = hypot(location.x - anchorLocation.x, location.y - anchorLocation.y)
        guard movement > configuration.movementTolerance else {
            _ = update(at: timestamp)
            return false
        }

        generation &+= 1
        phase = .tracking
        self.anchorLocation = location
        stationarySince = timestamp
        return true
    }

    /// Advances the detector to held once its current stationary interval has
    /// elapsed. The generation overload lets an asynchronously scheduled timer
    /// prove that it still represents the current endpoint.
    @discardableResult
    mutating func update(at timestamp: TimeInterval, generation expectedGeneration: UInt64? = nil) -> Bool {
        if let expectedGeneration, expectedGeneration != generation { return false }
        guard phase == .tracking, let stationarySince else { return phase == .held }
        // Compare against the same absolute deadline exposed to schedulers.
        // Subtracting decimal `TimeInterval` values can round an exact boundary
        // (for example, 1.4 - 1.0) just below the configured duration.
        guard timestamp >= stationarySince + configuration.holdDuration else { return false }
        phase = .held
        return true
    }

    /// Ends touch tracking but retains whether the eventual PencilKit stroke
    /// commit should be snapped. Call `reset()` after consuming that commit.
    @discardableResult
    mutating func end(at timestamp: TimeInterval) -> Bool {
        guard phase == .tracking || phase == .held else {
            phase = .ended(shouldSnap: false)
            anchorLocation = nil
            stationarySince = nil
            return false
        }
        _ = update(at: timestamp)
        let shouldSnap = phase == .held
        phase = .ended(shouldSnap: shouldSnap)
        anchorLocation = nil
        stationarySince = nil
        return shouldSnap
    }

    mutating func cancel() {
        generation &+= 1
        phase = .cancelled
        anchorLocation = nil
        stationarySince = nil
    }

    mutating func reset() {
        generation &+= 1
        phase = .idle
        anchorLocation = nil
        stationarySince = nil
    }
}

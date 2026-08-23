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

/// App-global bridge between automatic backup and open editor view models.
/// Registrations should capture their editor weakly, flush its current revision,
/// and return false if the durable write fails. Closures are main-actor isolated
/// because editor state belongs to UIKit; disk persistence remains actor-backed.
@MainActor
final class WebDAVEditorFlushRegistry {

    struct Registration: Hashable, Sendable {
        fileprivate let id: UUID
    }

    typealias FlushOperation = @MainActor @Sendable () async -> Bool

    private var operations: [UUID: FlushOperation] = [:]

    @discardableResult
    func register(_ operation: @escaping FlushOperation) -> Registration {
        let registration = Registration(id: UUID())
        operations[registration.id] = operation
        return registration
    }

    func unregister(_ registration: Registration?) {
        guard let registration else { return }
        operations.removeValue(forKey: registration.id)
    }

    func flushAll() async -> Bool {
        // Snapshotting prevents a deinit/unregister callback from mutating the
        // collection while an awaited flush is in progress.
        let currentOperations = Array(operations.values)
        for operation in currentOperations {
            guard !Task.isCancelled, await operation() else { return false }
        }
        return !Task.isCancelled
    }

    var activeRegistrationCount: Int {
        operations.count
    }
}

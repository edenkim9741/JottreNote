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

final class DefaultsContinuationStorage: @unchecked Sendable {

    private struct StorageKey: Hashable {
        let name: String
        let valueType: ObjectIdentifier
    }

    private let lock = NSLock()
    private var continuations: [StorageKey: [UUID: Any]] = [:]

    func add<T: LosslessStringConvertible & Sendable>(
        _ continuation: AsyncStream<T?>.Continuation,
        id: UUID,
        defaultsKey: DefaultsKey<T>
    ) {
        lock.withLock {
            continuations[storageKey(for: defaultsKey), default: [:]][id] = continuation
        }
    }

    func remove<T: LosslessStringConvertible & Sendable>(
        id: UUID,
        defaultsKey: DefaultsKey<T>
    ) {
        lock.withLock {
            let key = storageKey(for: defaultsKey)
            continuations[key]?.removeValue(forKey: id)
            if continuations[key]?.isEmpty == true {
                continuations.removeValue(forKey: key)
            }
        }
    }

    func continuations<T: LosslessStringConvertible & Sendable>(
        defaultsKey: DefaultsKey<T>
    ) -> [AsyncStream<T?>.Continuation]? {
        lock.withLock {
            continuations[storageKey(for: defaultsKey)]?
                .values
                .compactMap { continuation in
                    continuation as? AsyncStream<T?>.Continuation
                }
        }
    }

    func continuationCount<T: LosslessStringConvertible & Sendable>(
        defaultsKey: DefaultsKey<T>
    ) -> Int {
        lock.withLock {
            continuations[storageKey(for: defaultsKey)]?.count ?? 0
        }
    }

    private func storageKey<T: LosslessStringConvertible & Sendable>(
        for defaultsKey: DefaultsKey<T>
    ) -> StorageKey {
        StorageKey(
            name: defaultsKey.description,
            valueType: ObjectIdentifier(T.self)
        )
    }
}

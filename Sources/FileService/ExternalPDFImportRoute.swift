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

enum ExternalPDFImportRoute: Equatable, Sendable {

    case none
    case single(URL)
    case batch([URL])

    init(urls: [URL]) {
        switch urls.count {
        case 0:
            self = .none
        case 1:
            self = .single(urls[0])
        default:
            self = .batch(urls)
        }
    }

    static func suggestedTitle(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// Collects sibling external-open callbacks before deciding whether the
/// operation is a single-file or batch import.
///
/// The collector owns every security-scope access passed to it. It keeps those
/// accesses alive through `onFlush`, releases them afterwards, and only then
/// resumes redirected scene submissions that are waiting to be destroyed.
@MainActor
final class ExternalPDFImportCoalescer {

    typealias FlushHandler = @MainActor @Sendable (_ urls: [URL]) async -> Void

    private struct Submission {
        let urls: [URL]
        let securityScopedURLs: [URL]
        let onCompletion: (@Sendable () -> Void)?
    }

    private let debounceNanoseconds: UInt64
    private let startAccessingSecurityScopedResource: @Sendable (_ url: URL) -> Bool
    private let stopAccessingSecurityScopedResource: @Sendable (_ url: URL) -> Void
    private let onFlush: FlushHandler

    private var submissions: [Submission] = []
    private var debounceTask: Task<Void, Never>?
    private var debounceGeneration: UInt = 0

    init(
        debounceNanoseconds: UInt64 = 200_000_000,
        startAccessingSecurityScopedResource: @Sendable @escaping (_ url: URL) -> Bool = {
            $0.startAccessingSecurityScopedResource()
        },
        stopAccessingSecurityScopedResource: @Sendable @escaping (_ url: URL) -> Void = {
            $0.stopAccessingSecurityScopedResource()
        },
        onFlush: @escaping FlushHandler
    ) {
        self.debounceNanoseconds = debounceNanoseconds
        self.startAccessingSecurityScopedResource = startAccessingSecurityScopedResource
        self.stopAccessingSecurityScopedResource = stopAccessingSecurityScopedResource
        self.onFlush = onFlush
    }

    /// Starts security-scoped access synchronously so grants are retained before
    /// the UIKit URL callback returns, then schedules a trailing-edge flush.
    func submit(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let securityScopedURLs = urls.filter(startAccessingSecurityScopedResource)
        enqueue(
            urls: urls,
            securityScopedURLs: securityScopedURLs,
            onCompletion: nil
        )
    }

    /// Transfers scopes acquired by a source scene and waits until the files
    /// have been materialized and all transferred scopes have been released.
    func submitPreaccessed(
        _ urls: [URL],
        securityScopedURLs: [URL]
    ) async {
        guard !urls.isEmpty else {
            securityScopedURLs.forEach(stopAccessingSecurityScopedResource)
            return
        }

        await withCheckedContinuation { continuation in
            enqueue(
                urls: urls,
                securityScopedURLs: securityScopedURLs,
                onCompletion: { continuation.resume() }
            )
        }
    }

    /// Deterministic seam for tests and lifecycle drains.
    func flushNow() async {
        debounceGeneration &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        await flushPendingSubmissions()
    }

    func cancelPending() {
        debounceGeneration &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        releasePendingSubmissions()
    }

    deinit {
        debounceTask?.cancel()
        let pendingSubmissions = submissions
        for submission in pendingSubmissions {
            submission.securityScopedURLs.forEach(stopAccessingSecurityScopedResource)
        }
        for submission in pendingSubmissions {
            submission.onCompletion?()
        }
    }
}

private extension ExternalPDFImportCoalescer {

    func enqueue(
        urls: [URL],
        securityScopedURLs: [URL],
        onCompletion: (@Sendable () -> Void)?
    ) {
        submissions.append(
            Submission(
                urls: urls,
                securityScopedURLs: securityScopedURLs,
                onCompletion: onCompletion
            )
        )

        debounceGeneration &+= 1
        let scheduledGeneration = debounceGeneration
        let delay = debounceNanoseconds
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }

            guard
                let self,
                !Task.isCancelled,
                debounceGeneration == scheduledGeneration
            else {
                return
            }

            debounceTask = nil
            await flushPendingSubmissions()
        }
    }

    func flushPendingSubmissions() async {
        guard !submissions.isEmpty else { return }
        let pendingSubmissions = submissions
        submissions.removeAll(keepingCapacity: true)

        let urls = pendingSubmissions.flatMap(\.urls)
        defer {
            for submission in pendingSubmissions {
                submission.securityScopedURLs.forEach(stopAccessingSecurityScopedResource)
            }
            for submission in pendingSubmissions {
                submission.onCompletion?()
            }
        }

        await onFlush(urls)
    }

    func releasePendingSubmissions() {
        guard !submissions.isEmpty else { return }
        let pendingSubmissions = submissions
        submissions.removeAll(keepingCapacity: true)
        for submission in pendingSubmissions {
            submission.securityScopedURLs.forEach(stopAccessingSecurityScopedResource)
        }
        for submission in pendingSubmissions {
            submission.onCompletion?()
        }
    }
}

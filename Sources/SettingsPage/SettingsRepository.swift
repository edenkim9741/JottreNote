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

import UIKit

protocol SettingsRepositoryProtocol: Sendable {

    func appVersion() -> String

    func userInterfaceStyle() -> AsyncStream<UIUserInterfaceStyle>

    func updateUserInterfaceStyle(_ style: UIUserInterfaceStyle)

    func getWebDAVURL() -> String?
    func setWebDAVURL(_ value: String)

    func getWebDAVUsername() -> String?
    func setWebDAVUsername(_ value: String)

    func getWebDAVPassword() -> String?
    func setWebDAVPassword(_ value: String)

    func getWebDAVBackupIntervalMinutes() -> Int
    func setWebDAVBackupIntervalMinutes(_ value: Int)

    func testWebDAVConnection(url: String, username: String, password: String) async -> Bool

    func backupAllJots() -> AsyncStream<Double>
}

struct SettingsRepository: SettingsRepositoryProtocol {

    private let bundleService: BundleServiceProtocol
    private let defaultsService: DefaultsServiceProtocol
    private let webDAVBackupService: WebDAVBackupService

    init(
        bundleService: BundleServiceProtocol,
        defaultsService: DefaultsServiceProtocol,
        webDAVBackupService: WebDAVBackupService
    ) {
        self.bundleService = bundleService
        self.defaultsService = defaultsService
        self.webDAVBackupService = webDAVBackupService
    }

    func appVersion() -> String {
        bundleService.shortVersionString() ?? "-"
    }

    func userInterfaceStyle() -> AsyncStream<UIUserInterfaceStyle> {
        defaultsService.getValueStream(.userInterfaceStyle)
            .map { value in
                value
                    .flatMap { UIUserInterfaceStyle(rawValue: $0) }
                    ?? .unspecified
            }
            .toAsyncStream()
    }

    func updateUserInterfaceStyle(_ style: UIUserInterfaceStyle) {
        defaultsService.set(.userInterfaceStyle, value: style.rawValue)
    }

    func getWebDAVURL() -> String? { defaultsService.getValue(.webDAVURL) }
    func setWebDAVURL(_ value: String) { defaultsService.set(.webDAVURL, value: value) }

    func getWebDAVUsername() -> String? { defaultsService.getValue(.webDAVUsername) }
    func setWebDAVUsername(_ value: String) { defaultsService.set(.webDAVUsername, value: value) }

    func getWebDAVPassword() -> String? { defaultsService.getValue(.webDAVPassword) }
    func setWebDAVPassword(_ value: String) { defaultsService.set(.webDAVPassword, value: value) }

    func getWebDAVBackupIntervalMinutes() -> Int {
        WebDAVAutoBackupPolicy.normalizedIntervalMinutes(
            defaultsService.getValue(.webDAVBackupIntervalMinutes)
        )
    }

    func setWebDAVBackupIntervalMinutes(_ value: Int) {
        defaultsService.set(
            .webDAVBackupIntervalMinutes,
            value: WebDAVAutoBackupPolicy.normalizedIntervalMinutes(value)
        )
    }

    func testWebDAVConnection(url: String, username: String, password: String) async -> Bool {
        guard !url.isEmpty, let baseURL = URL(string: url) else { return false }
        var request = URLRequest(url: baseURL, timeoutInterval: 10)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        let credentials = "\(username):\(password)"
        if let encoded = credentials.data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    func backupAllJots() -> AsyncStream<Double> {
        webDAVBackupService.backupAll()
    }
}

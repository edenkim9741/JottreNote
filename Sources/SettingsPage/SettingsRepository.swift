import UIKit

protocol SettingsRepositoryProtocol: Sendable {
    func appVersion() -> String
    func userInterfaceStyle() -> AsyncStream<UIUserInterfaceStyle>
    func updateUserInterfaceStyle(_ style: UIUserInterfaceStyle)
}

struct SettingsRepository: SettingsRepositoryProtocol {
    private let bundleService: BundleServiceProtocol
    private let defaultsService: DefaultsServiceProtocol

    init(bundleService: BundleServiceProtocol, defaultsService: DefaultsServiceProtocol) {
        self.bundleService = bundleService
        self.defaultsService = defaultsService
    }

    func appVersion() -> String { bundleService.shortVersionString() ?? "-" }

    func userInterfaceStyle() -> AsyncStream<UIUserInterfaceStyle> {
        defaultsService.getValueStream(.userInterfaceStyle)
            .map { $0.flatMap { UIUserInterfaceStyle(rawValue: $0) } ?? .unspecified }
            .toAsyncStream()
    }

    func updateUserInterfaceStyle(_ style: UIUserInterfaceStyle) {
        defaultsService.set(.userInterfaceStyle, value: style.rawValue)
    }
}

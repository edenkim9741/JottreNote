import Foundation

/// Cold launches show the library. Only an explicit open/Handoff request can
/// put an editor on the initial navigation stack; saved scene activity is ignored.
enum SceneLaunchPolicy {
    static func documentURL(explicitActivityURL: String?, fileURLs: [URL]) -> URL? {
        if let string = explicitActivityURL, let url = URL(string: string), EditJotURL(url: url) != nil {
            return url
        }
        return fileURLs.first { $0.isFileURL && $0.pathExtension.lowercased() == JotFile.Info.fileExtension }
    }
}

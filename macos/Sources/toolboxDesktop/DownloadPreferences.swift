import Foundation

/// Stores the user's preferred download directory. The app is not sandboxed,
/// so a stable path is sufficient; a security-scoped bookmark is unnecessary.
struct DownloadPreferences {
    private static let key = "toolboxDefaultDownloadDirectory"
    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default

    var directory: URL {
        if let path = defaults.string(forKey: Self.key),
           fileManager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        // A removed drive or renamed folder should not make downloads fail
        // forever. Fall back to the current account's standard Downloads path.
        return fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }

    func save(_ directory: URL) {
        defaults.set(directory.standardizedFileURL.path, forKey: Self.key)
    }
}

import Foundation

/// Desktop-side settings that mirror the website's `toolbox.json`.
///
/// Edit the values in this file when moving the catalog or repository. URLs
/// used by the welcome window and updater are derived below, so they cannot
/// quietly drift apart.
enum ToolboxConfig {
    // This is the single desktop version source. build-app.sh copies it into
    // Info.plist, and release-macos.yml requires release tags to match it.
    static let version = "1.0.2"
    static let siteTitle = "toolbox"
    static let siteDescription = "My personal toolbox of utility scripts"
    static let siteAuthor = "PiSaucer"
    static let siteLanguage = "en"
    static let baseURL = URL(string: "https://pisaucer.github.io/toolbox")!
    static let repository = "PiSaucer/toolbox"
    static let branch = "main"

    // Keep the editable values above close to toolbox.json. Everything below
    // is derived so changing the repository or title updates all consumers.
    static let desktopName = "\(siteTitle) desktop"
    static let catalogURL = baseURL.appendingPathComponent("")
    static let repositoryURL = URL(string: "https://github.com/\(repository)")!
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    static func rawRepositoryFile(_ path: String, reference: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(repository)/\(reference)/\(path)")!
    }
}

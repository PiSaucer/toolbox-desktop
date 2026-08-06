import CryptoKit
import Foundation

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

actor toolboxUpdater {
    /// Serializing update work prevents two incoming links from racing while
    /// replacing the launcher stored in Application Support.
    static let shared = toolboxUpdater()

    private let session: URLSession
    private let fileManager: FileManager
    private let releasesURL = ToolboxConfig.latestReleaseURL

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    var installedLauncherURL: URL {
        get throws {
            let support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("toolbox", isDirectory: true)
            try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
            return support.appendingPathComponent("toolbox.py")
        }
    }

    func installBundledLauncherIfNeeded() throws -> URL {
        let destination = try installedLauncherURL
        guard let bundled = Bundle.main.url(forResource: "toolbox", withExtension: "py") else {
            throw toolboxDesktopError.invalidRelease("The bundled toolbox launcher is missing.")
        }
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.copyItem(at: bundled, to: destination)
            return destination
        }

        // Installing a newer desktop app must also advance an older cached
        // launcher. Keep a newer cache, since it may have arrived from GitHub
        // after this particular app build was published.
        let bundledData = try Data(contentsOf: bundled)
        let bundledVersion = try Self.extractVersion(from: bundledData)
        let installedVersion = try? Self.extractVersion(from: Data(contentsOf: destination))
        let shouldInstallBundled = installedVersion.map {
            Self.compareVersions(bundledVersion, $0) == .orderedDescending
        } ?? true
        if shouldInstallBundled {
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".toolbox-bundled-\(UUID().uuidString).py")
            try fileManager.copyItem(at: bundled, to: temporary)
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        }
        return destination
    }

    func checkForUpdate() async throws -> Bool {
        // A catalog download is the natural update boundary: check immediately
        // before running toolbox, but never delay someone merely opening the UI.
        let launcher = try installBundledLauncherIfNeeded()
        let localData = try Data(contentsOf: launcher)
        let localVersion = try Self.extractVersion(from: localData)

        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(ToolboxConfig.siteTitle)-desktop/1.0", forHTTPHeaderField: "User-Agent")
        let (releaseData, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: releaseData)
        let releaseVersion = String(release.tagName.drop(while: { $0 == "v" || $0 == "V" }))
        guard Self.compareVersions(releaseVersion, localVersion) == .orderedDescending else {
            return false
        }

        // Fetch from the exact release tag rather than main. That keeps the tag,
        // embedded version, and optional published checksum tied together.
        let sourceURL = ToolboxConfig.rawRepositoryFile("toolbox.py", reference: release.tagName)
        let (candidate, sourceResponse) = try await session.data(from: sourceURL)
        try Self.requireSuccess(sourceResponse)
        guard try Self.extractVersion(from: candidate) == releaseVersion else {
            throw toolboxDesktopError.invalidRelease("The release tag and launcher version do not match.")
        }

        let digest = SHA256.hash(data: candidate).map { String(format: "%02x", $0) }.joined()
        // Older releases may not publish a checksum sidecar. Those still get
        // HTTPS plus tag/version validation; new releases should include the
        // sidecar so the candidate is also pinned to its published digest.
        if let checksumAsset = release.assets.first(where: { $0.name == "toolbox.py.sha256" }) {
            let (checksumData, checksumResponse) = try await session.data(from: checksumAsset.browserDownloadURL)
            try Self.requireSuccess(checksumResponse)
            let expected = String(decoding: checksumData, as: UTF8.self)
                .split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased()
            guard expected == digest else {
                throw toolboxDesktopError.invalidRelease("The toolbox update failed SHA-256 verification.")
            }
        }

        let temporary = launcher.deletingLastPathComponent().appendingPathComponent(".toolbox-\(UUID().uuidString).py")
        try candidate.write(to: temporary, options: .atomic)
        _ = try fileManager.replaceItemAt(launcher, withItemAt: temporary)
        UserDefaults.standard.set(releaseVersion, forKey: "toolboxDesktopLauncherVersion")
        UserDefaults.standard.set(digest, forKey: "toolboxDesktopLauncherSHA256")
        return true
    }

    static func extractVersion(from data: Data) throws -> String {
        // Parse the same single source of truth used by pyproject.toml. This
        // avoids importing or executing untrusted candidate Python code.
        guard let source = String(data: data, encoding: .utf8) else {
            throw toolboxDesktopError.invalidRelease("toolbox.py is not valid UTF-8.")
        }
        let regex = try NSRegularExpression(pattern: #"(?m)^__version__\s*=\s*\"([^\"]+)\"\s*$"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              let versionRange = Range(match.range(at: 1), in: source) else {
            throw toolboxDesktopError.invalidRelease("toolbox.py has no recognizable version.")
        }
        return String(source[versionRange])
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw toolboxDesktopError.invalidRelease("GitHub returned an unsuccessful response.")
        }
    }
}

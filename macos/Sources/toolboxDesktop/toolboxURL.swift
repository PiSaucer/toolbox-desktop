import Foundation

struct toolboxRequest: Equatable {
    /// Accept only the narrow download route. A link may select a manifest ID,
    /// but it cannot inject command-line flags, paths, or alternate servers.
    let scriptID: String

    init(url: URL) throws {
        guard url.scheme?.lowercased() == "toolbox" else {
            throw toolboxDesktopError.invalidLink("The URL scheme must be toolbox.")
        }
        guard url.host?.lowercased() == "download" else {
            throw toolboxDesktopError.invalidLink("Only toolbox://download/<script-id> links are supported.")
        }

        let value = url.path.removingPercentEncoding?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let allowed = try NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard allowed.firstMatch(in: value, range: range) != nil else {
            throw toolboxDesktopError.invalidLink("The script ID is invalid.")
        }
        scriptID = value
    }
}

enum toolboxDesktopError: LocalizedError {
    // Keep user-facing failures in one type so AppKit alerts receive useful
    // text whether the error began in URL parsing, updates, or a subprocess.
    case invalidLink(String)
    case invalidRelease(String)
    case launcherUnavailable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidLink(let message), .invalidRelease(let message), .commandFailed(let message):
            return message
        case .launcherUnavailable:
            return "toolbox needs Python 3.11+ with Rich installed. Install toolbox with Homebrew or pipx, then try the link again."
        }
    }
}

import Foundation

struct toolboxLauncher {
    private let fileManager = FileManager.default

    /// Prefer an existing managed CLI installation. Falling back to the staged
    /// launcher keeps the app self-contained while preserving the CLI's own
    /// manifest lookup, temporary-file, and checksum-verification behavior.
    func download(_ request: toolboxRequest, to output: URL) async throws -> String {

        // The packaged runtime is the primary path so a downloaded app has no
        // dependency on Homebrew, Xcode command-line tools, or system Python.
        if let python = bundledPythonExecutable() {
            let launcher = try await toolboxUpdater.shared.installBundledLauncherIfNeeded()
            return try await run(python, arguments: [launcher.path, request.scriptID, "--output-dir", output.path])
        }

        // Development builds created before the runtime is staged retain these
        // fallbacks, which also makes source-level debugging more convenient.
        if let executable = installedToolboxExecutable() {
            return try await run(executable, arguments: [request.scriptID, "--output-dir", output.path])
        }

        let launcher = try await toolboxUpdater.shared.installBundledLauncherIfNeeded()
        guard let python = pythonWithRich() else {
            throw toolboxDesktopError.launcherUnavailable
        }
        return try await run(python, arguments: [launcher.path, request.scriptID, "--output-dir", output.path])
    }

    private func bundledPythonExecutable() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidate = resources.appendingPathComponent("python/bin/python3")
        return fileManager.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    private func installedToolboxExecutable() -> URL? {
        // GUI apps do not inherit an interactive shell's PATH. Search only the
        // standard locations supported by this repository's installers.
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/toolbox"),
            URL(fileURLWithPath: "/opt/homebrew/bin/toolbox"),
            URL(fileURLWithPath: "/usr/local/bin/toolbox"),
        ]
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private func pythonWithRich() -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
            URL(fileURLWithPath: "/usr/local/bin/python3"),
            home.appendingPathComponent(".local/bin/python3"),
            URL(fileURLWithPath: "/usr/bin/python3"),
        ]
        return candidates.first { candidate in
            guard fileManager.isExecutableFile(atPath: candidate.path) else { return false }
            let process = Process()
            process.executableURL = candidate
            process.arguments = ["-c", "import rich"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    }

    private func run(_ executable: URL, arguments: [String]) async throws -> String {
        // Process arguments are passed as an array rather than through a shell,
        // so a manifest ID can never gain shell-expansion semantics.
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            // A signed app bundle must remain immutable. Prevent the embedded
            // interpreter from creating new __pycache__ files in Resources.
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["PYTHONDONTWRITEBYTECODE": "1"],
                uniquingKeysWith: { _, bundledValue in bundledValue }
            )
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 {
                    // The CLI ends successful downloads with terminal artwork.
                    // Native alerts should show only the useful receipt fields.
                    let receipt = output.split(separator: "\n")
                        .map(String.init)
                        .filter {
                            $0.hasPrefix("Downloaded:") ||
                            $0.hasPrefix("SHA-256:") ||
                            $0.hasPrefix("Saved to:")
                        }
                        .joined(separator: "\n")
                    continuation.resume(returning: receipt)
                } else {
                    continuation.resume(throwing: toolboxDesktopError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

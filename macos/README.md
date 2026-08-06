# toolbox desktop for macOS

`toolbox desktop` is the native macOS listener and graphical companion for [PiSaucer/toolbox](https://github.com/PiSaucer/toolbox). It registers the `toolbox://` URL scheme, confirms catalog downloads, delegates the actual work to the bundled Python launcher, and presents the verified result with native AppKit windows.

The application is intentionally self-contained. A release bundle includes the Swift executable, `toolbox.py`, Rich, and a relocatable CPython runtime. Users do not need to install Python or modify their shell unless they choose to install the optional `toolbox` terminal command.

## Features

* Handles links such as `toolbox://download/id`.
* Accepts only the fixed download route and a restricted manifest ID.
* Lets the user choose and persist a default download directory.
* Verifies downloads through the same manifest and SHA-256 flow as the TUI.
* Checks for newer `toolbox.py` releases at launch, before opening the TUI, and before a link download.
* Opens the bundled TUI with the user's preferred `.command`-file terminal.
* Supports system, light, and dark appearances using the website color tokens.
* Installs or safely removes an optional `~/.local/bin/toolbox` command.
* Can move its own application bundle to the macOS Trash.
* Builds a styled, licensed drag-to-Applications DMG.

## Requirements

The application targets macOS 13 Ventura or newer. Building requires:

* Xcode or the Xcode Command Line Tools, including `swift`, `codesign`, `iconutil`, `sips`, and `plutil`.
* [`librsvg`](https://gitlab.gnome.org/GNOME/librsvg), providing `rsvg-convert` for deterministic SVG and app-icon rendering.
* [`create-dmg`](https://github.com/create-dmg/create-dmg) for DMG assembly.
* Standard macOS command-line tools.

For example, the two third-party build dependencies can be installed with:

```bash
brew install librsvg create-dmg
```

## Quick start

Build and open the application:

```bash
cd macos
./scripts/build-app.sh
open "dist/toolbox desktop.app"
```

Build the distributable installer:

```bash
./scripts/build-dmg.sh
open "dist/toolbox-installer-X.X.X.dmg"
```

## Project layout

| Path                                               | Purpose                                                                                             |
| :------------------------------------------------- | :-------------------------------------------------------------------------------------------------- |
| `Sources/toolboxDesktop/AppDelegate.swift`         | AppKit lifecycle, windows, menus, link confirmation, downloads, terminal actions, and uninstall UI. |
| `Sources/toolboxDesktop/ToolboxConfig.swift`       | Human-edited desktop version and website/repository settings.                                       |
| `Sources/toolboxDesktop/toolboxURL.swift`          | Strict parsing and validation for `toolbox://` links plus shared errors.                            |
| `Sources/toolboxDesktop/Updater.swift`             | Cached launcher installation and GitHub release update checks.                                      |
| `Sources/toolboxDesktop/Launcher.swift`            | Executes the bundled launcher and reduces CLI output to a native receipt.                           |
| `Sources/toolboxDesktop/TerminalInstaller.swift`   | Installs and removes the optional user-local terminal shim.                                         |
| `Sources/toolboxDesktop/DownloadPreferences.swift` | Persists the chosen download directory.                                                             |
| `Sources/toolboxDesktop/main.swift`                | Storyboard-free AppKit entry point.                                                                 |
| `scripts/build-app.sh`                             | Clean Swift build, bundle assembly, runtime copying, and ad-hoc signing.                            |
| `scripts/build-dmg.sh`                             | Version-safe DMG staging, Finder layout, license formatting, and compression.                       |
| `tools/build-icons.sh`                             | Timestamp-aware PNG, asset-catalog, and ICNS generation.                                            |
| `tools/setup-toolbox.sh`                           | Selects and stages the canonical `toolbox.py`.                                                      |
| `tools/setup-python-runtime.sh`                    | Downloads, verifies, prepares, and caches relocatable CPython with Rich.                            |
| `tools/toolbox-cli`                                | Relocatable command shipped at `Contents/MacOS/toolbox`.                                            |
| `Info.plist`                                       | Bundle identifier, URL scheme, executable, icon, and minimum macOS metadata.                        |
| `Package.swift`                                    | SwiftPM executable target and macOS deployment target.                                              |
| `Assets/`                                          | Canonical app/DMG artwork plus generated PNG and ICNS files.                                        |
| `Assets.xcassets/`                                 | Generated icon sizes used by Xcode and ICNS compilation.                                            |
| `dist/`                                            | Generated app and DMG output.                                                                       |

## Configuration and versioning

Edit `Sources/toolboxDesktop/ToolboxConfig.swift` for the desktop app based on website's settings:

```swift
enum ToolboxConfig {
    static let version = "1.0.0"
    static let siteTitle = "toolbox"
    static let siteDescription = "My personal toolbox of utility scripts"
    static let siteAuthor = "PiSaucer"
    static let siteLanguage = "en"
    static let baseURL = URL(string: "https://pisaucer.github.io/toolbox")!
    static let repository = "PiSaucer/toolbox"
    static let branch = "main"
}
```

Derived catalog, repository, GitHub Releases API, and raw-file URLs live below the editable values. Add new derived URLs there instead of hard-coding them in views or networking code.

`ToolboxConfig.version` is the single desktop version source:

* `build-app.sh` copies it to `CFBundleShortVersionString`.
* The About window displays it directly.
* `build-dmg.sh` uses it in the default installer filename.
* The release workflow requires a tag with the same value.

`BUILD_NUMBER` optionally sets the numeric `CFBundleVersion`. If unset, the build script uses the current Actions run number or `0` for local builds.

## Application startup and URL handling

The project has no storyboard or nib. `main.swift` creates `NSApplication`, assigns `AppDelegate`, and enters the AppKit event loop. The delegate registers for `kAEGetURL` Apple Events before launch completes so the first custom URL is not lost.

Incoming links can arrive through Apple Events, `application(_:open:)`, or a command-line argument. URLs received before launch finishes are queued and processed afterward. A normal Dock launch shows the welcome window.

The only supported route is:

```text
toolbox://download/<script-id>
```

`script-id` must start with an ASCII letter or number, may contain letters, numbers, `.`, `_`, or `-`, and is limited to 128 characters. Links cannot pass shell flags, output paths, commands, alternate manifests, or alternate servers.

## Download flow

1. `toolboxRequest` validates the custom URL and extracts the manifest ID.
2. The app asks the user to use the saved folder, choose another folder, or cancel.
3. The updater checks for a newer cached `toolbox.py` release.
4. `toolboxLauncher` invokes the launcher with a `Process` argument array, not a shell command string.
5. The Python launcher resolves the fixed manifest entry, downloads the file, and verifies its published SHA-256 value.
6. The app extracts `Downloaded`, `SHA-256`, and `Saved to` receipt fields and presents them in a native success window.

The preferred folder is stored in `UserDefaults` under `toolboxDefaultDownloadDirectory`. If that directory disappears, the app falls back to the current user's standard Downloads directory.

## Launcher updates and trust model

The signed app bundle is never modified after assembly. On first use, its embedded `toolbox.py` is copied to:

```text
~/Library/Application Support/toolbox/toolbox.py
```

On every app launch, before opening the TUI, and before an accepted catalog download, the updater first compares the bundled launcher with the cached launcher. A newer bundled copy replaces an older cache without requiring network access. It then:

1. Requests the latest release from the configured GitHub repository.
2. Compares its tag to the cached launcher's `__version__` numerically.
3. Fetches `toolbox.py` from that exact release tag rather than from `main`.
4. Confirms the downloaded file's `__version__` matches the release tag.
5. Calculates SHA-256 and, when the release publishes `toolbox.py.sha256`, requires the digest to match.
6. Atomically replaces the cached launcher.

The version parser reads source text with a regular expression and never imports or executes an update candidate during validation. Publishing `toolbox.py.sha256` with every toolbox release is strongly recommended. Older releases without it retain HTTPS and tag/version validation but do not have the additional published-digest check.

## Bundled Python runtime

`tools/setup-python-runtime.sh` uses a checksum-pinned [`python-build-standalone`](https://github.com/astral-sh/python-build-standalone) archive instead of a conventional virtual environment. macOS virtual environments commonly retain absolute links to the creating framework or package-manager Python and would stop working on another Mac.

The script currently prepares:

* CPython `3.13.14`
* python-build-standalone release `20260728`
* `rich>=13.9,<15`
* Separate ARM64 and x86_64 archives with hard-coded SHA-256 values

Downloaded archives are cached under `tools/.cache`. Prepared runtimes are cached under `tools/python-arm64` or `tools/python-x86_64`, then copied into the app at `Contents/Resources/python`. The runtime marker prevents unnecessary bundle copies when the prepared version has not changed.

`PYTHONDONTWRITEBYTECODE=1` and Python's `-B` flag prevent `__pycache__` writes inside the signed app bundle.

## Choosing the bundled toolbox.py

`tools/setup-toolbox.sh` uses this precedence:

1. A canonical `toolbox.py` in the neighboring parent toolbox repository.
2. A previously staged `macos/tools/toolbox.py` in the working tree.
3. A download from the configured PiSaucer toolbox GitHub repository when both local copies are absent.

Downloaded fallback files must contain a recognizable `__version__` assignment. Staging is atomic, and unchanged files retain their modification time to avoid unnecessary resource copies and signatures.

## TUI and terminal command

**Open TUI** writes an executable `Open toolbox TUI.command` file under Application Support and asks Launch Services to open it. This respects the user's selected `.command` application, such as iTerm2, and falls back to Terminal when no custom association is set.

**Install terminal command** creates:

```text
~/.local/bin/toolbox
```

The generated shim points to the app's bundled Python and cached launcher. If necessary, the installer appends a marked PATH block to `~/.zprofile`. Moving the app afterward requires reinstalling the command because the shim contains the application path.

**Uninstall command** removes only a shim containing the app's generation marker. It refuses to delete an unrelated command with the same filename and removes only the exact marked PATH block it previously added.

**Move app to Trash** asks Finder to recycle the running `.app` bundle and then terminates. It deliberately leaves the terminal command, preferences, cached launcher, and downloaded files in place so each can be managed independently.

## Appearance and native UI

`ToolboxPalette` mirrors the website's primary, surface, border, text, and muted color tokens for light and dark appearances. The selected appearance is stored under the `toolboxAppearance` user-default key. System appearance remains the default.

The About window reads the desktop version from `ToolboxConfig`, the TUI version from the embedded launcher, and the Python version from the bundled runtime. The native license window reflows the source paragraphs and displays them in Menlo with theme-aware colors.

## Icon pipeline

`tools/build-icons.sh` is called automatically by app and DMG builds and skips outputs that are newer than their inputs.

Application icon pipeline:

```text
Assets/AppIcon.png
  -> Assets/AppIconPadded.png
  -> Assets.xcassets/AppIcon.appiconset/*.png
  -> Sources/toolboxDesktop/toolbox.icns
```

The generated `AppIconPadded.png` places 824-by-824 artwork in a 1024-by-1024 canvas. That follows the macOS safe area and keeps the icon proportional in older Docks. The PNG is embedded in a temporary SVG data URL so librsvg behaves the same locally and on GitHub runners.

DMG volume icon pipeline:

```text
Assets/DMGVolumeIcon.svg
  -> Assets/DMGVolumeIcon.png
  -> Assets.xcassets/DMGVolumeIcon.appiconset/*.png
  -> Assets/DMGVolumeIcon.icns
```

## App build details

`scripts/build-app.sh` performs these phases:

1. Validates the platform, tools, version, and numeric build number.
2. Refreshes generated icon assets.
3. Runs `swift package clean` to prevent stale object files.
4. Stages `toolbox.py` and compiles the release Swift executable.
5. Recreates `dist/toolbox desktop.app` with standard `Contents/MacOS` and `Contents/Resources` directories.
6. Copies the executable, CLI shim, launcher, license, ICNS, and private Python.
7. Writes the configured version/build metadata to `Info.plist`.
8. Applies an ad-hoc deep signature.

`CONFIGURATION=debug` can be used for a debug SwiftPM build:

```bash
CONFIGURATION=debug ./scripts/build-app.sh
```

The output is:

```text
dist/toolbox desktop.app
```

## DMG build details

With no arguments, `scripts/build-dmg.sh` rebuilds the app first so a stale app cannot determine the installer version:

```bash
./scripts/build-dmg.sh
```

A prebuilt app and explicit output can be supplied for CI:

```bash
./scripts/build-dmg.sh "dist/toolbox desktop.app" "dist/toolbox-installer-1.0.0-macos-arm64.dmg"
```

The script rejects a supplied app whose `CFBundleShortVersionString` differs from `ToolboxConfig.version`. It stages the app with `ditto`, reflows the MIT license, converts it to Menlo RTF, and invokes `create-dmg` with:

* A 720×460 Finder window and dark blueprint background
* The custom toolbox installer volume icon
* `toolbox desktop.app` and an Applications shortcut
* A visible `License.txt` plus the pre-mount EULA
* HFS+, compressed UDZO output, and no legacy internet-enable flag

The default output is:

```text
dist/toolbox-installer-<version>.dmg
```

## GitHub release workflow

`.github/workflows/release-macos.yml` runs for `v*` tags and manual dispatches. It builds native installers on ARM64 and Intel macOS runners. For tag builds, the tag without its leading `v` must exactly match `ToolboxConfig.version`.

Each architecture job:

1. Installs `librsvg` and `create-dmg`.
2. Builds the self-contained app with the Actions run number as bundle build.
3. Verifies the app signature.
4. Creates an architecture-specific DMG.
5. Generates a SHA-256 sidecar.
6. Uploads both as workflow artifacts.

For tags, the publish job creates or updates the GitHub release and uploads:

```text
toolbox-installer-<version>-macos-arm64.dmg
toolbox-installer-<version>-macos-arm64.dmg.sha256
toolbox-installer-<version>-macos-x86_64.dmg
toolbox-installer-<version>-macos-x86_64.dmg.sha256
```

## Validation

Useful local checks after changing Swift or packaging code:

```bash
# Parse every shell script.
sh -n scripts/*.sh tools/*.sh

# Build and verify the app.
./scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 "dist/toolbox desktop.app"

# Build and verify the installer.
./scripts/build-dmg.sh
hdiutil verify "dist/toolbox-installer-$(sed -n 's/^[[:space:]]*static let version = "\([^"]*\)".*/\1/p' Sources/toolboxDesktop/ToolboxConfig.swift).dmg"
```

## Troubleshooting

### “The app may be damaged or incomplete”

This commonly means the bundle was only partially assembled, its executable is missing, or its signature was invalidated after assembly. Rebuild with `scripts/build-app.sh` and verify with `codesign`. For downloaded public builds, Developer ID signing and notarization are required for the normal Gatekeeper experience.

### The DMG has the wrong version

Change `ToolboxConfig.version`, then rebuild. A normal no-argument DMG build always rebuilds the app. When supplying a custom app path, the script stops if the bundle and config versions differ.

### `iconutil` reports “Invalid Iconset”

Confirm every required catalog PNG exists at its expected size. In restricted automation environments, Apple tooling can also fail while trying to use its normal caches; rerun with access to standard Xcode and temporary directories.

### A website link opens an old application

Remove duplicate applications that register the `toolbox` scheme, empty Trash, and launch the desired app once so Launch Services sees the current bundle.

### The terminal command points to a missing app

Moving the app changes its bundled runtime path. Use **Install terminal command** again from the app to regenerate `~/.local/bin/toolbox`.

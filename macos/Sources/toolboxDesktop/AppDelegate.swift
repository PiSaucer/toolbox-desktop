import AppKit
import Carbon.HIToolbox

private enum ToolboxPalette {
    // These values mirror the website's CSS tokens. Keeping them together here
    // makes light and dark mode changes deliberate instead of view-by-view.
    static func rgb(_ value: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: alpha
        )
    }

    static func adaptive(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return rgb(value)
        }
    }

    static let primary = adaptive(light: 0x2980b9, dark: 0x206894)
    static let primaryHover = adaptive(light: 0x206894, dark: 0x2980b9)
    static let primarySoft = adaptive(light: 0xeaf4fb, dark: 0x0d2533)
    static let border = adaptive(light: 0xd9e6ef, dark: 0x282d31)
    static let background = adaptive(light: 0xf5f8fb, dark: 0x101214)
    static let surface = adaptive(light: 0xffffff, dark: 0x181b1e)
    static let text = adaptive(light: 0x17212b, dark: 0xe8f0f5)
    static let muted = adaptive(light: 0x667482, dark: 0x9fb0bc)
}

private final class ToolboxButton: NSButton {
    // A borderless AppKit button does not receive a useful hover treatment for
    // free, so this small subclass supplies the website-like state changes.
    private let primaryStyle: Bool
    private var pointerInside = false
    private var hoverTrackingArea: NSTrackingArea?

    init(title: String, target: AnyObject?, action: Selector?, primary: Bool) {
        primaryStyle = primary
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 24, height: max(size.height, 36))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        updateColors()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let background: NSColor
        let border: NSColor
        let foreground: NSColor
        if primaryStyle {
            background = ToolboxPalette.rgb(pointerInside ? (dark ? 0x2980b9 : 0x206894) : (dark ? 0x206894 : 0x2980b9))
            border = background
            foreground = .white
        } else {
            background = ToolboxPalette.rgb(pointerInside ? (dark ? 0x0d2533 : 0xeaf4fb) : (dark ? 0x181b1e : 0xffffff))
            border = ToolboxPalette.rgb(pointerInside ? (dark ? 0x206894 : 0x2980b9) : (dark ? 0x282d31 : 0xd9e6ef))
            foreground = ToolboxPalette.rgb(pointerInside ? (dark ? 0x206894 : 0x2980b9) : (dark ? 0xe8f0f5 : 0x17212b))
        }
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = border.cgColor
        contentTintColor = foreground
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: foreground,
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            ]
        )
    }
}

/// Owns the native macOS lifecycle and translates operating-system URL events
/// into the same verified-download workflow used by the command-line client.
///
/// The delegate intentionally keeps networking and process launching in the
/// smaller `toolboxUpdater` and `toolboxLauncher` types. That separation keeps
/// AppKit callbacks focused on UI state and makes the security boundaries much
/// easier to audit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []
    private var hasFinishedLaunching = false
    private var welcomeWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private weak var downloadFolderLabel: NSTextField?
    private var appearanceMenuItems: [String: NSMenuItem] = [:]
    private static let appearanceKey = "toolboxAppearance"

    // MARK: - Application lifecycle and URL delivery

    /// AppKit enables restoration automatically for modern applications, but
    /// macOS 13 still expects the delegate to explicitly confirm secure coding.
    /// Returning true ensures any restored window state is decoded exclusively
    /// through NSSecureCoding and removes the runtime StateRestoration warning.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSLog("toolbox desktop: applicationWillFinishLaunching")
        // Custom URL schemes arrive as kAEGetURL Apple Events. Register before
        // didFinishLaunching so the first event cannot be lost during startup.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("toolbox desktop: applicationDidFinishLaunching with %d pending URL(s)", pendingURLs.count)
        NSApp.setActivationPolicy(.regular)
        applySavedAppearance()
        configureMainMenu()
        hasFinishedLaunching = true

        // Refresh in the background on every launch. The welcome window does
        // not wait for GitHub, and offline launches continue with the cache.
        Task {
            do {
                let updated = try await toolboxUpdater.shared.checkForUpdate()
                NSLog("toolbox desktop: launch update check completed; updated=%d", updated ? 1 : 0)
            } catch {
                NSLog("toolbox desktop: launch update check failed: %@", error.localizedDescription)
            }
        }
        let argumentURLs = CommandLine.arguments.dropFirst().compactMap { value -> URL? in
            guard let url = URL(string: value), url.scheme?.lowercased() == "toolbox" else {
                return nil
            }
            return url
        }
        NSLog("toolbox desktop: command line contained %d toolbox URL(s)", argumentURLs.count)
        let urls = pendingURLs + argumentURLs
        pendingURLs.removeAll()
        if urls.isEmpty {
            showWelcomeWindow()
            return
        }
        process(urls)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receive(urls)
    }

    /// macOS does not launch a second copy when the Dock/Finder icon is clicked
    /// while toolbox is already running. Instead it asks the existing process
    /// to reopen. Always restore the welcome window for that event.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        Task { @MainActor in
            if let welcomeWindow {
                NSApp.activate(ignoringOtherApps: true)
                welcomeWindow.makeKeyAndOrderFront(nil)
            } else {
                showWelcomeWindow()
            }
        }
        return true
    }

    @objc private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        NSLog("toolbox desktop: received kAEGetURL Apple Event")
        guard let value = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: value) else {
            NSLog("toolbox desktop: Apple Event did not contain a valid URL")
            return
        }
        NSLog("toolbox desktop: Apple Event URL %@", url.absoluteString)
        receive([url])
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    private func receive(_ urls: [URL]) {
        NSLog("toolbox desktop: receive called with %d URL(s); finished=%d", urls.count, hasFinishedLaunching)
        guard hasFinishedLaunching else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        welcomeWindow?.close()
        welcomeWindow = nil
        process(urls)
    }

    // MARK: - Welcome window

    @MainActor
    private func showWelcomeWindow() {
        NSLog("toolbox desktop: showing welcome window")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 525),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ToolboxConfig.desktopName
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ToolboxPalette.background

        let appIcon = roundedAppIcon(size: 72, radius: 16)

        let title = NSTextField(labelWithString: "\(ToolboxConfig.desktopName) is ready")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .center
        title.textColor = ToolboxPalette.text

        // Keep implementation details out of the welcome copy. People only
        // need to know what the app does; the registered scheme is an internal
        // transport detail exposed by links on the catalog website.
        let detail = NSTextField(wrappingLabelWithString: "Open a download from the toolbox catalog and this app will securely fetch and verify it.")
        detail.alignment = .center
        detail.textColor = ToolboxPalette.muted

        let verifiedRow = featureRow(
            symbol: "checkmark.shield.fill",
            color: .systemGreen,
            text: "SHA-256 verified downloads"
        )
        let currentRow = featureRow(
            symbol: "arrow.triangle.2.circlepath.circle.fill",
            color: ToolboxPalette.primary,
            text: "Automatic launcher updates"
        )

        let website = actionButton("Catalog website", symbol: "safari", action: #selector(openCatalog), primary: true)
        let tui = actionButton("Open TUI", symbol: "terminal.fill", action: #selector(openTUI))
        let terminal = actionButton("Install terminal command", symbol: "terminal", action: #selector(installTerminalCommand))
        let folder = actionButton("Change folder", symbol: "folder", action: #selector(changeDownloadDirectory))
        let uninstallCommand = actionButton("Uninstall command", symbol: "trash", action: #selector(uninstallTerminalCommand))
        let uninstallApp = actionButton("Move app to Trash", symbol: "trash.fill", action: #selector(uninstallApplication))

        let firstActions = NSStackView(views: [website, terminal])
        firstActions.orientation = .horizontal
        firstActions.spacing = 12
        firstActions.distribution = .fillEqually
        let secondActions = NSStackView(views: [tui, folder])
        secondActions.orientation = .horizontal
        secondActions.spacing = 12
        secondActions.distribution = .fillEqually
        let uninstallActions = NSStackView(views: [uninstallCommand, uninstallApp])
        uninstallActions.orientation = .horizontal
        uninstallActions.spacing = 12
        uninstallActions.distribution = .fillEqually
        NSLayoutConstraint.activate([
            firstActions.widthAnchor.constraint(equalToConstant: 440),
            secondActions.widthAnchor.constraint(equalToConstant: 440),
            uninstallActions.widthAnchor.constraint(equalToConstant: 440),
        ])

        let folderLabel = NSTextField(wrappingLabelWithString: "Downloads save to: \(DownloadPreferences().directory.path)")
        folderLabel.alignment = .center
        folderLabel.textColor = ToolboxPalette.muted.withAlphaComponent(0.7)
        folderLabel.font = .systemFont(ofSize: 11)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.maximumNumberOfLines = 1
        downloadFolderLabel = folderLabel

        let stack = NSStackView(views: [appIcon, title, detail, verifiedRow, currentRow, firstActions, secondActions, uninstallActions, folderLabel])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: window.contentView!.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: window.contentView!.trailingAnchor, constant: -30),
            stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
            detail.widthAnchor.constraint(equalToConstant: 410),
            folderLabel.widthAnchor.constraint(equalToConstant: 440),
        ])

        welcomeWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openCatalog() {
        NSWorkspace.shared.open(ToolboxConfig.catalogURL)
    }

    @MainActor @objc private func changeDownloadDirectory() {
        if let directory = chooseDownloadDirectory() {
            downloadFolderLabel?.stringValue = "Downloads save to: \(directory.path)"
        }
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        action: Selector,
        primary: Bool = false
    ) -> NSButton {
        let button = ToolboxButton(title: title, target: self, action: action, primary: primary)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        if primary {
            button.keyEquivalent = "\r"
        }
        return button
    }

    private func roundedAppIcon(size: CGFloat, radius: CGFloat) -> NSImageView {
        let view = NSImageView(image: NSApp.applicationIconImage)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.masksToBounds = true
        view.layer?.shadowOpacity = 0
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: size),
            view.heightAnchor.constraint(equalToConstant: size),
        ])
        return view
    }

    /// Builds a compact icon-and-label row for the welcome window.
    private func featureRow(symbol: String, color: NSColor, text: String) -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: text) ?? NSImage())
        image.contentTintColor = color
        let label = NSTextField(labelWithString: text)
        label.textColor = color
        let row = NSStackView(views: [image, label])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: - Application menu and appearance

    /// Installs an explicit application menu because this project is built
    /// without a storyboard or nib. The custom About item reports both layers
    /// users interact with: the Swift bridge and the embedded Python TUI.
    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)

        let applicationMenu = NSMenu()
        let aboutItem = applicationMenu.addItem(
            withTitle: "About \(ToolboxConfig.desktopName)",
            action: #selector(showAboutPanel),
            keyEquivalent: ""
        )
        aboutItem.target = self
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)

        let installItem = applicationMenu.addItem(
            withTitle: "Install Terminal Command…",
            action: #selector(installTerminalCommand),
            keyEquivalent: ""
        )
        installItem.target = self
        installItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)

        let uninstallCommandItem = applicationMenu.addItem(
            withTitle: "Uninstall Terminal Command…",
            action: #selector(uninstallTerminalCommand),
            keyEquivalent: ""
        )
        uninstallCommandItem.target = self
        uninstallCommandItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)

        let tuiItem = applicationMenu.addItem(
            withTitle: "Open TUI",
            action: #selector(openTUI),
            keyEquivalent: "t"
        )
        tuiItem.target = self
        tuiItem.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil)

        let folderItem = applicationMenu.addItem(
            withTitle: "Change Download Folder…",
            action: #selector(changeDownloadDirectory),
            keyEquivalent: ""
        )
        folderItem.target = self
        folderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)

        let uninstallAppItem = applicationMenu.addItem(
            withTitle: "Move App to Trash…",
            action: #selector(uninstallApplication),
            keyEquivalent: ""
        )
        uninstallAppItem.target = self
        uninstallAppItem.image = NSImage(systemSymbolName: "trash.fill", accessibilityDescription: nil)

        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        let appearanceMenu = NSMenu(title: "Appearance")
        let choices: [(String, String, Selector, String)] = [
            ("System", "circle.lefthalf.filled", #selector(useSystemAppearance), "system"),
            ("Light", "sun.max", #selector(useLightAppearance), "light"),
            ("Dark", "moon", #selector(useDarkAppearance), "dark"),
        ]
        appearanceMenuItems.removeAll()
        let selectedAppearance = UserDefaults.standard.string(forKey: Self.appearanceKey) ?? "system"
        for (title, symbol, action, key) in choices {
            let item = appearanceMenu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.state = selectedAppearance == key ? .on : .off
            appearanceMenuItems[key] = item
        }
        appearanceItem.submenu = appearanceMenu
        applicationMenu.addItem(appearanceItem)
        applicationMenu.addItem(.separator())
        let quitItem = applicationMenu.addItem(
            withTitle: "Quit \(ToolboxConfig.desktopName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        applicationItem.submenu = applicationMenu
        NSApp.mainMenu = mainMenu
    }

    private func applySavedAppearance() {
        switch UserDefaults.standard.string(forKey: Self.appearanceKey) ?? "system" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    private func selectAppearance(_ value: String) {
        UserDefaults.standard.set(value, forKey: Self.appearanceKey)
        applySavedAppearance()
        for (key, item) in appearanceMenuItems {
            item.state = key == value ? .on : .off
        }
    }

    @objc private func useSystemAppearance() { selectAppearance("system") }
    @objc private func useLightAppearance() { selectAppearance("light") }
    @objc private func useDarkAppearance() { selectAppearance("dark") }

    // MARK: - About and license

    /// Presents version information without triggering a network request.
    /// The TUI version is read from the launcher embedded in this exact build,
    /// so the About panel remains useful even when the Mac is offline.
    @objc private func showAboutPanel() {
        let appVersion = ToolboxConfig.version
        let tuiVersion = effectiveLauncherVersion()
        let pythonVersion = bundledPythonVersion()

        if let aboutWindow {
            aboutWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 430),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "About \(ToolboxConfig.desktopName)"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ToolboxPalette.background

        let icon = roundedAppIcon(size: 96, radius: 22)
        let name = NSTextField(labelWithString: ToolboxConfig.desktopName)
        name.font = .systemFont(ofSize: 24, weight: .bold)
        name.alignment = .center
        name.textColor = ToolboxPalette.text
        let versions = NSTextField(labelWithString: "Swift app version: \(appVersion)\nTUI version: \(tuiVersion)\nPython version: \(pythonVersion)")
        versions.alignment = .center
        versions.textColor = ToolboxPalette.muted
        let repository = actionButton("GitHub repository", symbol: "link", action: #selector(openRepository))
        let catalog = actionButton("toolbox catalog", symbol: "safari", action: #selector(openCatalog))
        let links = NSStackView(views: [catalog, repository])
        links.orientation = .horizontal
        links.spacing = 12
        links.distribution = .fillEqually
        let license = actionButton("MIT License", symbol: "doc.text", action: #selector(showLicense))
        let copyright = NSTextField(labelWithString: "MIT licensed · Copyright © 2026 \(ToolboxConfig.siteAuthor)")
        copyright.alignment = .center
        copyright.textColor = ToolboxPalette.muted.withAlphaComponent(0.7)

        let stack = NSStackView(views: [icon, name, versions, links, license, copyright])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
            links.widthAnchor.constraint(equalToConstant: 360),
            license.widthAnchor.constraint(equalToConstant: 174),
        ])

        aboutWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openRepository() {
        NSWorkspace.shared.open(ToolboxConfig.repositoryURL)
    }

    private func bundledPythonVersion() -> String {
        guard let python = Bundle.main.resourceURL?.appendingPathComponent("python/bin/python3"),
              FileManager.default.isExecutableFile(atPath: python.path) else { return "unknown" }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = python
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return output.replacingOccurrences(of: "Python ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "unknown"
        }
    }

    /// Report the launcher the app will actually execute. Application Support
    /// wins over the bundle once the first launcher has been installed.
    private func effectiveLauncherVersion() -> String {
        let fileManager = FileManager.default
        let support = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("toolbox/toolbox.py")
        let candidate = support.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Bundle.main.url(forResource: "toolbox", withExtension: "py")
        guard let candidate,
              let data = try? Data(contentsOf: candidate),
              let version = try? toolboxUpdater.extractVersion(from: data) else {
            return "unknown"
        }
        return version
    }

    @MainActor @objc private func showLicense() {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            show(message: "MIT License", detail: "The bundled license could not be opened.", isError: true)
            return
        }

        // The source license is wrapped for plain-text readers. Reflow each
        // paragraph here and let the native text container wrap it to the
        // actual window width, just as the DMG license formatter does.
        let paragraphs = text.components(separatedBy: "\n\n").map { paragraph in
            paragraph.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let displayedText = paragraphs.joined(separator: "\n\n")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 340))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 10
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = ToolboxPalette.border.cgColor

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = ToolboxPalette.surface
        textView.textContainerInset = NSSize(width: 20, height: 18)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3
        paragraphStyle.paragraphSpacing = 12
        let licenseFont = NSFont(name: "Menlo", size: 12)
            ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: displayedText,
            attributes: [
                .font: licenseFont,
                .foregroundColor: ToolboxPalette.text,
                .paragraphStyle: paragraphStyle,
            ]
        ))
        scrollView.documentView = textView

        let alert = NSAlert()
        alert.messageText = "MIT License"
        alert.informativeText = "\(ToolboxConfig.desktopName) is open-source software."
        alert.accessoryView = scrollView
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - TUI, folders, and terminal command

    /// Opens the bundled TUI with the app registered for shell scripts. This
    /// respects the user's Launch Services choice (for example iTerm2) and
    /// falls back to Terminal when macOS has no custom association.
    @objc private func openTUI() {
        Task { @MainActor in
            do {
                guard let python = Bundle.main.resourceURL?.appendingPathComponent("python/bin/python3"),
                      FileManager.default.isExecutableFile(atPath: python.path) else {
                    throw toolboxDesktopError.launcherUnavailable
                }
                do {
                    _ = try await toolboxUpdater.shared.checkForUpdate()
                } catch {
                    // Network trouble should not make the bundled TUI unusable.
                    // Record the cause while continuing with the cached copy.
                    NSLog("toolbox desktop: TUI update check failed: %@", error.localizedDescription)
                }
                let launcher = try await toolboxUpdater.shared.installBundledLauncherIfNeeded()
                let directory = DownloadPreferences().directory
                let support = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                ).appendingPathComponent("toolbox", isDirectory: true)
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                let command = support.appendingPathComponent("Open toolbox TUI.command")
                let contents = """
                #!/bin/zsh
                cd \(shellQuoted(directory.path))
                export PYTHONDONTWRITEBYTECODE=1
                \(shellQuoted(python.path)) -B \(shellQuoted(launcher.path)) --output-dir \(shellQuoted(directory.path))
                """
                try contents.write(to: command, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
                guard NSWorkspace.shared.open(command) else {
                    throw toolboxDesktopError.commandFailed("macOS could not open the TUI command in a terminal.")
                }
            } catch {
                show(message: "Couldn't open the TUI", detail: error.localizedDescription, isError: true)
            }
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Lets the user select and persist a default folder. Starting at the
    /// current choice makes both first-run and later changes predictable.
    @MainActor
    private func chooseDownloadDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose toolbox download folder"
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = DownloadPreferences().directory
        guard panel.runModal() == .OK, let directory = panel.url else { return nil }
        DownloadPreferences().save(directory)
        return directory
    }

    /// Installs the `toolbox` command only after a clear native confirmation,
    /// since this action writes to ~/.local/bin and may append to ~/.zprofile.
    @objc private func installTerminalCommand() {
        let confirmation = NSAlert()
        confirmation.messageText = "Install the toolbox terminal command?"
        confirmation.informativeText = "This creates ~/.local/bin/toolbox and ensures that directory is present in your zsh PATH. The command uses the Python and Rich bundled inside this app."
        confirmation.addButton(withTitle: "Install")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor in
            do {
                let launcher = try await toolboxUpdater.shared.installBundledLauncherIfNeeded()
                let command = try TerminalInstaller().install(launcher: launcher)
                show(message: "Terminal command installed", detail: "Installed at \(command.path). Open a new terminal and run: toolbox --version")
            } catch {
                show(message: "Couldn't install the terminal command", detail: error.localizedDescription, isError: true)
            }
        }
    }

    /// Removes the optional ~/.local/bin shim without touching commands owned
    /// by Homebrew, another installer, or the user.
    @MainActor @objc private func uninstallTerminalCommand() {
        let confirmation = NSAlert()
        confirmation.messageText = "Uninstall the toolbox terminal command?"
        confirmation.informativeText = "This removes ~/.local/bin/toolbox and the PATH entry added by this app. The desktop app and downloaded files will remain."
        let uninstallButton = confirmation.addButton(withTitle: "Uninstall Command")
        uninstallButton.hasDestructiveAction = true
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        do {
            let command = try TerminalInstaller().uninstall()
            show(message: "Terminal command uninstalled", detail: "Removed \(command.path).")
        } catch {
            show(message: "Couldn't uninstall the terminal command", detail: error.localizedDescription, isError: true)
        }
    }

    /// Ask Finder to move the bundle to Trash instead of deleting it directly,
    /// keeping the operation recoverable and letting macOS update Launch Services.
    @MainActor @objc private func uninstallApplication() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension.lowercased() == "app" else {
            show(message: "Couldn't uninstall the app", detail: "This build is not running from an application bundle.", isError: true)
            return
        }

        let confirmation = NSAlert()
        confirmation.messageText = "Move \(ToolboxConfig.desktopName) to Trash?"
        confirmation.informativeText = "This removes the URL listener application. The terminal command, preferences, and downloaded files will remain unless you remove them separately."
        let trashButton = confirmation.addButton(withTitle: "Move to Trash")
        trashButton.hasDestructiveAction = true
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        NSWorkspace.shared.recycle([bundleURL]) { _, error in
            DispatchQueue.main.async {
                if let error {
                    NSApp.presentError(error)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - Verified download flow

    private func process(_ urls: [URL]) {
        NSLog("toolbox desktop: processing %d URL(s)", urls.count)
        Task {
            for url in urls { await handle(url) }
        }
    }

    @MainActor
    private func handle(_ url: URL) async {
        NSLog("toolbox desktop: handling URL %@", url.absoluteString)
        do {
            let request = try toolboxRequest(url: url)
            NSApp.activate(ignoringOtherApps: true)
            let confirmation = NSAlert()
            confirmation.messageText = "Download “\(request.scriptID)” with toolbox?"
            let defaultDirectory = DownloadPreferences().directory
            confirmation.informativeText = "toolbox will verify the published SHA-256 checksum. Choose another folder or download to:\n\(defaultDirectory.path)"
            confirmation.addButton(withTitle: "Use Default Folder")
            confirmation.addButton(withTitle: "Choose Folder…")
            let cancelButton = confirmation.addButton(withTitle: "Cancel")
            cancelButton.hasDestructiveAction = true
            confirmation.accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1))
            let response = confirmation.runModal()
            guard response != .alertThirdButtonReturn else {
                NSApp.terminate(nil)
                return
            }
            let destination: URL
            if response == .alertSecondButtonReturn {
                guard let chosen = chooseDownloadDirectory() else { return }
                destination = chosen
            } else {
                destination = defaultDirectory
            }

            // Keep update latency behind the user's explicit confirmation so
            // opening a link always produces immediate visible feedback.
            do {
                _ = try await toolboxUpdater.shared.checkForUpdate()
            } catch {
                // Downloads remain available offline or during a GitHub outage;
                // the failure is visible in Console instead of disappearing.
                NSLog("toolbox desktop: link update check failed: %@", error.localizedDescription)
            }
            let output = try await toolboxLauncher().download(request, to: destination)
            showDownloadSuccess(receipt: output, fallbackDirectory: destination)
        } catch {
            show(message: "\(ToolboxConfig.desktopName) couldn't open this link", detail: error.localizedDescription, isError: true)
        }
        NSApp.terminate(nil)
    }

    @MainActor
    private func show(message: String, detail: String, isError: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = isError ? .critical : .informational
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    /// Presents a compact native receipt instead of dumping terminal output
    /// into the alert. The downloaded file can be revealed directly in Finder.
    @MainActor
    private func showDownloadSuccess(receipt: String, fallbackDirectory: URL) {
        let name = receiptValue("Downloaded:", in: receipt) ?? "Download"
        let sha256 = receiptValue("SHA-256:", in: receipt) ?? "Verified"
        let savedPath = receiptValue("Saved to:", in: receipt)
        let savedURL = savedPath.map { URL(fileURLWithPath: $0) }

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        let verifiedIcon = NSImageView(image: NSImage(
            systemSymbolName: "checkmark.shield.fill",
            accessibilityDescription: "SHA-256 verified"
        ) ?? NSImage())
        verifiedIcon.contentTintColor = .systemGreen
        let verifiedLabel = NSTextField(labelWithString: "Verified with SHA-256")
        verifiedLabel.textColor = .systemGreen
        verifiedLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let verifiedRow = NSStackView(views: [verifiedIcon, verifiedLabel])
        verifiedRow.orientation = .horizontal
        verifiedRow.spacing = 7

        let hashLabel = NSTextField(labelWithString: sha256)
        hashLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        hashLabel.textColor = .secondaryLabelColor
        hashLabel.isSelectable = true
        hashLabel.lineBreakMode = .byClipping

        let location = savedURL?.path ?? fallbackDirectory.path
        let locationLabel = NSTextField(labelWithString: "Saved to: \(location)")
        locationLabel.font = .systemFont(ofSize: 12)
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [nameLabel, verifiedRow, hashLabel, locationLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        // NSAlert does not infer a reliable height from an Auto Layout stack
        // used directly as its accessory view. Give it a concrete container so
        // the receipt can never overlap the title, message, or buttons.
        let receiptView = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 130))
        receiptView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: receiptView.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: receiptView.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: receiptView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: receiptView.bottomAnchor, constant: -10),
            hashLabel.widthAnchor.constraint(equalToConstant: 410),
            locationLabel.widthAnchor.constraint(equalToConstant: 410),
        ])

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        alert.messageText = "Download complete"
        alert.informativeText = "The file was downloaded and verified successfully."
        alert.accessoryView = receiptView
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Show in Finder")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            if let savedURL {
                NSWorkspace.shared.activateFileViewerSelecting([savedURL])
            } else {
                NSWorkspace.shared.open(fallbackDirectory)
            }
        }
    }

    private func receiptValue(_ prefix: String, in receipt: String) -> String? {
        receipt.split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasPrefix(prefix) })?
            .dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespaces)
    }
}

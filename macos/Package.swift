// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "toolboxDesktop",
    platforms: [.macOS(.v13)],
    targets: [
        // build-app.sh assembles the final .app bundle and copies these
        // generated resources itself. Excluding them here prevents SwiftPM
        // from treating binary assets as source-side resources as well.
        .executableTarget(
            name: "toolboxDesktop",
            exclude: ["Resources", "toolbox.icns"]
        ),
    ]
)

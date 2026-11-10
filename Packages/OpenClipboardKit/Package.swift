// swift-tools-version: 6.2
import PackageDescription

// Everything that is not user interface: capturing the pasteboard, working out what a clip
// is, storing the history and writing a clip back. The app target only adds windows on top.
let package = Package(
    name: "OpenClipboardKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OpenClipboardKit", targets: ["OpenClipboardKit"]),
    ],
    targets: [
        .target(
            name: "OpenClipboardKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "OpenClipboardKitTests",
            dependencies: ["OpenClipboardKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

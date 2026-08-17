// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "WMPLauncher",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "WMPLauncher",
            path: "Sources"
        )
    ],
    swiftLanguageModes: [.v5]
)

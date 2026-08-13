// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WMPLauncher",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "WMPLauncher",
            path: "Sources"
        )
    ]
)

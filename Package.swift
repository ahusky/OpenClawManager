// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "OpenClawManager",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "OpenClawManager",
            path: "Sources"
        )
    ]
)

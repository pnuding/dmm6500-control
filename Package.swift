// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DMM6500Control",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DMM6500Control",
            path: "Sources/DMM6500Control"
        )
    ]
)

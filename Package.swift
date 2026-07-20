// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZundaNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ZundaNotch", path: "Sources/ZundaNotch")
    ]
)

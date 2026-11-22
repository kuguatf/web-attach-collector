// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WebAttachCollector",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WebAttachCollector", targets: ["WebAttachCollector"])
    ],
    targets: [
        .executableTarget(
            name: "WebAttachCollector",
            path: "Sources/WebAttachCollector"
        )
    ]
)

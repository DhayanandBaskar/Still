// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Still",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Still", targets: ["Still"])],
    targets: [.executableTarget(name: "Still", path: "Sources")]
)

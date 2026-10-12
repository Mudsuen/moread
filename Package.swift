// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MudsReader", platforms: [.macOS(.v14)], products: [.executable(name: "MudsReader", targets: ["MudsReader"])], targets: [.target(name: "ReaderCore"), .executableTarget(name: "MudsReader", dependencies: ["ReaderCore"]), .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"]), .testTarget(name: "ReaderUITests", dependencies: ["MudsReader"])], swiftLanguageModes: [.v5])

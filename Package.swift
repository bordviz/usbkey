// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "USBKey", platforms: [.macOS(.v13)], products: [.executable(name: "USBKey", targets: ["USBKey"]), .executable(name: "USBKeyLifecycle", targets: ["USBKeyLifecycle"])], targets: [.target(name: "KeyCore"), .executableTarget(name: "USBKey", dependencies: ["KeyCore"]), .executableTarget(name: "USBKeyLifecycle"), .testTarget(name: "KeyCoreTests", dependencies: ["KeyCore"])])

// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "PrivateInputKit", platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "PrivateInputKit", targets: ["PrivateInputKit"])],
    targets: [.systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
              .target(name: "PrivateInputKit", dependencies: ["CSQLite"]),
              .executableTarget(name: "PrivateInputVectors", dependencies: ["PrivateInputKit"], path: "Tools/PrivateInputVectors"),
              .executableTarget(name: "PrivateInputNetworkPeer", dependencies: ["PrivateInputKit"], path: "Tools/PrivateInputNetworkPeer"),
              .executableTarget(name: "PrivateInputRelayProbe", dependencies: ["PrivateInputKit"], path: "Tools/PrivateInputRelayProbe"),
              .testTarget(name: "PrivateInputKitTests", dependencies: ["PrivateInputKit"])]
)

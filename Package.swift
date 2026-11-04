// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Orbit", dependencies: ["OrbitBridge"]),
        // Shared by Orbit and the Brave native messaging helper: framing,
        // message validation and the local socket.
        .target(name: "OrbitBridge"),
        .executableTarget(name: "OrbitBraveHelper", dependencies: ["OrbitBridge"]),
        .testTarget(name: "OrbitTests", dependencies: ["Orbit", "OrbitBridge"])
    ]
)

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Orbit Pet's animation engine (Milestone 10). MIT runtime, pinned:
        // a binary framework that builds with Command Line Tools (verified).
        .package(url: "https://github.com/rive-app/rive-ios", exact: "6.29.0"),
    ],
    targets: [
        .executableTarget(
            name: "Orbit",
            dependencies: ["OrbitBridge", .product(name: "RiveRuntime", package: "rive-ios")],
            linkerSettings: [
                // RiveRuntime.framework: Contents/Frameworks in Orbit.app (scripts/run.sh copies it),
                // next to the binary for development runs.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path"]),
            ]),
        // Shared by Orbit and the Brave native messaging helper: framing,
        // message validation and the local socket.
        .target(name: "OrbitBridge"),
        .executableTarget(name: "OrbitBraveHelper", dependencies: ["OrbitBridge"]),
        // The AI Hub's hook helper: one agent event from stdin to Orbit's socket.
        .executableTarget(name: "OrbitAgentHook", dependencies: ["OrbitBridge"]),
        .testTarget(name: "OrbitTests", dependencies: ["Orbit", "OrbitBridge"],
                    linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])])
    ]
)

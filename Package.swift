// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "moto-service-tool",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Shared engine: serial I/O, ELM327/UDS, capture proxy, high-level ops.
        .target(
            name: "DucatiResetKit",
            path: "Sources/DucatiResetKit"
        ),
        // Command-line interface.
        .executableTarget(
            name: "motodiag",
            dependencies: ["DucatiResetKit"],
            path: "Sources/motodiag"
        ),
        // Native SwiftUI desktop app.
        .executableTarget(
            name: "DucatiResetGUI",
            dependencies: ["DucatiResetKit"],
            path: "Sources/DucatiResetGUI"
        )
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "moto-service-tool",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "DucatiResetKit", targets: ["DucatiResetKit"])
    ],
    targets: [
        // Shared engine: ELM327/UDS, BLE transport (cross-platform);
        // serial I/O + capture proxy are macOS-only (guarded by #if os(macOS)).
        .target(
            name: "DucatiResetKit",
            path: "Sources/DucatiResetKit"
        ),
        // Command-line interface (macOS).
        .executableTarget(
            name: "motodiag",
            dependencies: ["DucatiResetKit"],
            path: "Sources/motodiag"
        ),
        // Native SwiftUI desktop app (macOS).
        .executableTarget(
            name: "DucatiResetGUI",
            dependencies: ["DucatiResetKit"],
            path: "Sources/DucatiResetGUI"
        )
    ]
)

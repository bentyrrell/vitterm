// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "vitterm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "vitterm", targets: ["vitterm"]),
        .executable(name: "vitbench", targets: ["vitbench"]),
    ],
    targets: [
        // -Ounchecked roughly doubles parser throughput, but removes overflow and precondition
        // checks in release builds. Numbers from terminal output are untrusted: clamp them where they
        // are parsed (see ImageStore.clampCells, CSI params capped at 65535) before any arithmetic.
        .target(
            name: "VitCore",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .target(name: "VitPTY"),
        .target(name: "VitConfig", resources: [.copy("Themes")]),
        .target(
            name: "VitRender",
            dependencies: ["VitCore", "VitConfig"],
            resources: [.copy("Shaders.metal")]
        ),
        .executableTarget(
            name: "vitterm",
            dependencies: ["VitCore", "VitPTY", "VitRender", "VitConfig"],
            resources: [.copy("ShellIntegration")]
        ),
        .executableTarget(name: "vitbench", dependencies: ["VitCore", "VitPTY", "VitRender"]),
        .testTarget(name: "VitCoreTests", dependencies: ["VitCore"]),
        .testTarget(name: "VitConfigTests", dependencies: ["VitConfig"]),
        .testTarget(name: "VitRenderTests", dependencies: ["VitRender", "VitCore"]),
        .testTarget(name: "VitPTYTests", dependencies: ["VitPTY", "VitCore"]),
        // Launches the built app (build/vitterm.app); skipped unless VITTERM_E2E=1.
        .testTarget(name: "E2ETests"),
    ],
    swiftLanguageModes: [.v5]
)

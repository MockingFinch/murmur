// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Murmur", targets: ["Murmur"]),
    ],
    targets: [
        // Pure logic and network clients: no UI, testable on their own.
        .target(
            name: "MurmurCore",
            linkerSettings: [.linkedLibrary("z")]
        ),
        // The app: menu bar, recording overlay, settings window.
        .executableTarget(
            name: "Murmur",
            dependencies: ["MurmurCore"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(
            name: "MurmurCoreTests",
            dependencies: ["MurmurCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)

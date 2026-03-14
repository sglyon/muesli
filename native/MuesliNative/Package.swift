// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MuesliNative",
    platforms: [
        .macOS("14.0"),
    ],
    products: [
        .executable(name: "MuesliNativeApp", targets: ["MuesliNativeApp"]),
        .executable(name: "MuesliSystemAudio", targets: ["MuesliSystemAudio"]),
    ],
    targets: [
        .executableTarget(
            name: "MuesliNativeApp",
            path: "Sources/MuesliNativeApp",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "MuesliSystemAudio",
            path: "Sources/MuesliSystemAudio"
        ),
    ]
)

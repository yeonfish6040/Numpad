// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrackpadNumpad",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TrackpadNumpad", targets: ["TrackpadNumpad"])],
    targets: [
        .target(name: "CTrackpad", linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("IOKit")]),
        .target(name: "TrackpadCore", resources: [.process("Resources")]),
        .executableTarget(name: "TrackpadNumpad", dependencies: ["CTrackpad", "TrackpadCore"],
                          linkerSettings: [.linkedFramework("Carbon")]),
        .testTarget(name: "TrackpadCoreTests", dependencies: ["TrackpadCore"]),
        .testTarget(name: "TrackpadNumpadTests", dependencies: ["TrackpadNumpad"])
    ]
)

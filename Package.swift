// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrackpadNumpad",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TrackpadNumpad", targets: ["TrackpadNumpad"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.10.1")
    ],
    targets: [
        .target(name: "CTrackpad", linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("IOKit")]),
        .target(name: "TrackpadCore", resources: [.process("Resources")]),
        .executableTarget(name: "TrackpadNumpad", dependencies: [
            "CTrackpad", "TrackpadCore", .product(name: "Sparkle", package: "Sparkle")
        ], linkerSettings: [
            .linkedFramework("Carbon"),
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
        ]),
        .testTarget(name: "TrackpadCoreTests", dependencies: ["TrackpadCore"]),
        .testTarget(name: "TrackpadNumpadTests", dependencies: ["TrackpadNumpad"])
    ]
)

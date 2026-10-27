// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clotho",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(path: "../ClothoKit"),
        // In-app updates. Pinned: scripts/release.sh uses the same version's sign_update.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.4"),
    ],
    targets: [
        .executableTarget(
            name: "Clotho",
            dependencies: [
                "SwiftTerm",
                .product(name: "ClothoKit", package: "ClothoKit"),
                .product(name: "ClothoFake", package: "ClothoKit"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // Sparkle.framework ships in Contents/Frameworks (build-app.sh copies it there).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "ClothoTests", dependencies: ["Clotho", "SwiftTerm"]),
    ]
)

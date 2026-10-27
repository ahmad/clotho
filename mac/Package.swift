// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clotho",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(path: "../ClothoKit"),
    ],
    targets: [
        .executableTarget(
            name: "Clotho",
            dependencies: [
                "SwiftTerm",
                .product(name: "ClothoKit", package: "ClothoKit"),
                .product(name: "ClothoFake", package: "ClothoKit"),
            ]
        )
    ]
)

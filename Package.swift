// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ProxyDog",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        .target(
            name: "ProcessProbe",
            path: "Sources/ProcessProbe"
        ),
        .target(
            name: "ZlibShim",
            path: "Sources/ZlibShim",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(
            name: "ProxyDog",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                "ProcessProbe",
                "ZlibShim",
            ],
            path: "Sources/ProxyDog"
        )
    ]
)

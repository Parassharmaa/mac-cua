// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CuaMcp",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "cua-mcp", targets: ["CuaMcp"]),
    ],
    targets: [
        .executableTarget(
            name: "CuaMcp",
            path: "Sources/CuaMcp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

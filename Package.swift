// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShipKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16)
    ],
    products: [
        .library(name: "ShipKit", targets: ["ShipKit"])
    ],
    targets: [
        .target(
            name: "ShipKit",
            path: "Sources/ShipKit",
            resources: [
                .process("Resources/Localization"),
                .copy("Resources/PrivacyInfo.xcprivacy")
            ]
        ),
        .testTarget(
            name: "ShipKitTests",
            dependencies: ["ShipKit"],
            path: "Tests/ShipKitTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NimbusSyncLocalizationPreview",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "NimbusSyncPackages", path: "../..")],
    targets: [
        .executableTarget(
            name: "LocalizationPreview",
            dependencies: [
                .product(name: "CloudreveDomainKit", package: "NimbusSyncPackages"),
                .product(name: "CloudreveDesignSystem", package: "NimbusSyncPackages"),
                .product(name: "CloudreveProductKit", package: "NimbusSyncPackages"),
            ]
        ),
    ]
)

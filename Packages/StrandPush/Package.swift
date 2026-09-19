// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StrandPush",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "StrandPush", targets: ["StrandPush"])],
    dependencies: [
        .package(path: "../WhoopStore"),
        // Supply-chain: pinned EXACT (not `from:`) so a clean resolve can't auto-pull a newer —
        // potentially compromised — upstream release. Must match the same exact version in the
        // other Packages/*/Package.swift and project.yml, or SPM resolution fails. Bump deliberately.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
    ],
    targets: [
        .target(
            name: "StrandPush",
            dependencies: [
                "WhoopStore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "StrandPushTests",
            dependencies: [
                "StrandPush",
                "WhoopStore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)

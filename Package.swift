// swift-tools-version: 6.2
import PackageDescription

// Guide Part 5.1: "new warnings are build failures". treatAllWarnings is
// unavailable before tools-version 6.2, which is the only reason this isn't 6.0.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "ClipMateMac",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "ClipMateCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "ClipMateApp",
            dependencies: ["ClipMateCore"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "ClipMateCoreTests",
            dependencies: ["ClipMateCore"],
            swiftSettings: strict
        ),
    ]
)

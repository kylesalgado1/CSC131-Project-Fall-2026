// swift-tools-version: 5.9
// WaitItOutUX - reusable feature package for the WAIT IT OUT UX prototype.
// Swift 5 language mode; builds with Xcode 15.0 or newer (iOS 17 SDK).
import PackageDescription

let package = Package(
    name: "WaitItOutUX",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "WaitItOutUX", targets: ["WaitItOutUX"])
    ],
    targets: [
        .target(
            name: "WaitItOutUX",
            path: "Sources/WaitItOutUX"
        ),
        .testTarget(
            name: "WaitItOutUXTests",
            dependencies: ["WaitItOutUX"],
            path: "Tests/WaitItOutUXTests"
        )
    ]
)

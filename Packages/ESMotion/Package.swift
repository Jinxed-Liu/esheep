// swift-tools-version: 6.2
// Modified for eSheep: iOS 17 support and library-only vendoring. See README.md.

import PackageDescription

let package = Package(
    name: "ESMotion",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v26),
    ],
    products: [
        .library(name: "ESMotion", targets: ["ESMotion"]),
        .library(name: "ESMotionCore", targets: ["ESMotionCore"]),
        .library(name: "ESMotionRuntime", targets: ["ESMotionRuntime"]),
        .library(name: "ESMotionMetal", targets: ["ESMotionMetal"]),
        .library(name: "ESMotionDocument", targets: ["ESMotionDocument"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/airbnb/lottie-spm.git",
            from: "4.6.0"
        ),
    ],
    targets: [
        .target(name: "ESMotionCore"),
        .target(
            name: "ESMotionDocument",
            dependencies: ["ESMotionCore"]
        ),
        .target(
            name: "ESMotionRuntime",
            dependencies: [
                "ESMotionCore",
                "ESMotionDocument",
                .product(name: "Lottie", package: "lottie-spm"),
            ]
        ),
        .target(
            name: "ESMotionMetal",
            dependencies: [
                "ESMotionCore",
                "ESMotionRuntime",
            ],
            resources: [.process("Shaders")]
        ),
        .target(
            name: "ESMotion",
            dependencies: [
                "ESMotionCore",
                "ESMotionDocument",
                "ESMotionRuntime",
                "ESMotionMetal",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

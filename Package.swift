// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacTaskManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacTaskManager", targets: ["MacTaskManager"])
    ],
    targets: [
        .executableTarget(
            name: "MacTaskManager",
            path: "Sources/MacTaskManager",
            swiftSettings: [
                // Mach / IOKit の C API を多用するため Swift 5 言語モードで運用する。
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacNotch",
            path: "Sources/MacNotch",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)

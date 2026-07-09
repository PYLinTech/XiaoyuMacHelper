// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "XiaoyuMacHelper",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "XiaoyuMacHelper", targets: ["XiaoyuMacHelper"])
    ],
    targets: [
        .executableTarget(
            name: "XiaoyuMacHelper",
            path: "Sources/XiaoyuMacHelper"
        )
    ]
)

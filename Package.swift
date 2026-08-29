// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "XiaoyuMacHelper",
    platforms: [
        .macOS(.v15)
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

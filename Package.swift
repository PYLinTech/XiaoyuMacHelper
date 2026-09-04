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
            path: "Sources/XiaoyuMacHelper",
            resources: [
                .copy("Resources/timer-start.m4a"),
                .copy("Resources/timer-countdown5.m4a"),
                // 工具栏/翻页栏图标（SVG 矢量，任意倍频锐利渲染）。
                .copy("Resources/hand.point.up.svg"),
                .copy("Resources/hand.point.up.fill.svg"),
                .copy("Resources/paintbrush.pointed.svg"),
                .copy("Resources/paintbrush.pointed.fill.svg"),
                .copy("Resources/eraser.svg"),
                .copy("Resources/eraser.fill.svg"),
                .copy("Resources/arrow.uturn.backward.svg"),
                .copy("Resources/arrow.uturn.forward.svg"),
                .copy("Resources/briefcase.svg"),
                .copy("Resources/xmark.circle.svg"),
                .copy("Resources/chevron.backward.svg"),
                .copy("Resources/chevron.forward.svg"),
                // 工具二级菜单四图标 + 橡皮二级菜单清空图标。
                .copy("Resources/scissors.svg"),
                .copy("Resources/timer.svg"),
                .copy("Resources/plus.magnifyingglass.svg"),
                .copy("Resources/rectangle.on.rectangle.angled.svg"),
                .copy("Resources/trash.square.svg"),
                .copy("Resources/trash.svg")
            ]
        )
    ]
)

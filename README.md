# Xiaoyu MacHelper

Xiaoyu MacHelper 是一个后台运行的 macOS 辅助工具。双击启动会显示控制窗口；重复启动只会唤起已有实例。

## 功能

- 后台常驻运行，不显示菜单栏图标。
- 支持登录自启动、辅助功能授权引导、清除设置并退出。
- Caps Lock 开启时显示 `大写` 指示器，可点击关闭大写锁定。
- 检测到选中文本时显示选区工具栏。
- 选区工具栏支持 `复制`、`粘贴`、`搜索`、`截图`，可启用、排序和设置搜索引擎。
- 新增桌面歌词模块：开启后显示悬浮桌面歌词，按 QQ 音乐、网易云音乐、Apple Music 的顺序搜索歌词。
- Apple Music 歌词源支持内置网页登录，登录后自动保存本机 media-user-token。
- 使用液态玻璃毛玻璃效果（macOS 26 原生 `NSGlassEffectView`，macOS 15 自动降级为 `NSVisualEffectView` 兼容实现）。

## 系统要求

- macOS 15 或更高版本（兼容 macOS 26）。
- 构建环境同时支持两种 SDK：macOS 15 SDK（Xcode 16.x / Swift 6.1）或 macOS 26 SDK（Xcode 26 / Swift 6.2+）均可编译；产物运行时自动适配——macOS 26 上使用系统原生液态玻璃，macOS 15 上自动降级为毛玻璃。
- 选区工具栏需要“辅助功能”权限。
- 桌面歌词需要联网访问歌词源；Apple Music 歌词源建议先在桌面歌词设置中完成网页登录。

## 构建

```zsh
cd /Users/pylin/Documents/PYLinTech/XiaoyuMacHelper
chmod +x build.sh
./build.sh
```

输出位置：`dist/Xiaoyu MacHelper.app`。

只构建不启动：

```zsh
SKIP_OPEN=1 ./build.sh
```

## 运行

```zsh
open "dist/Xiaoyu MacHelper.app"
```

退出：

```zsh
pkill -x "Xiaoyu MacHelper"
```

## 发布 DMG

```zsh
chmod +x build.sh release.sh
./release.sh
```

指定版本号和构建号：

```zsh
./release.sh 1.0.1 2
```

输出位置：`release/Xiaoyu MacHelper-版本号-构建号.dmg`。

可选签名和公证：

```zsh
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" ./release.sh 1.0.1 2
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE="xiaoyu-notary" ./release.sh 1.0.1 2
```

## 说明

当前版本只处理 Caps Lock 大写锁定提示和辅助功能选区工具栏，不读取输入法状态。

如果点击 `大写` 后没有关闭大写，请在系统隐私设置里允许 `Xiaoyu MacHelper` 控制电脑。不同应用暴露选区信息的稳定性取决于它的 Accessibility 支持。

## 协议与版权

本项目采用 MIT License，详见 [LICENSE](./LICENSE) 文件。

桌面歌词模块参考并大幅精简重写了 Lyricify Lyrics Helper 的歌词接口思路。原项目 Apache License 2.0 文本已保留在 [THIRD_PARTY_NOTICES](./THIRD_PARTY_NOTICES/) 目录。

版权所有 © 2026 重庆沛雨霖科技有限公司

Chongqing Peiyulin Technology Co., Ltd. (PYLinTech)

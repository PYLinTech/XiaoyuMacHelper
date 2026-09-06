# Xiaoyu MacHelper

Xiaoyu MacHelper 是一个后台运行的 macOS 辅助工具。双击启动会显示控制窗口；重复启动只会唤起已有实例。

## 功能

### 基础

- 后台常驻运行，不显示菜单栏图标，重复启动只唤起已有实例。
- 支持登录自启动、辅助功能授权引导、清除设置并退出。
- 使用液态玻璃毛玻璃效果（macOS 26 原生 `NSGlassEffectView`，macOS 15 自动降级为 `NSVisualEffectView` 兼容实现）。
- 自更新：每次启动检查新版本，自绘更新弹窗展示更新日志与下载/校验进度，辅助进程内容级替换安装。

### 大写指示器

- Caps Lock 开启时显示 `大写` 指示器，可点击关闭大写锁定。

### 选区工具栏

- 检测到选中文本时显示选区工具栏，支持 `全选`、`复制`、`粘贴`、`搜索`、`截图`，可启用、排序和设置搜索引擎。
- 全屏时可自动隐藏；搜索模板支持自定义。
- 截图支持框选区域、批注（箭头、矩形等，三档线宽、色板），可保存到指定目录或复制到剪贴板。

### 主动视觉感知

- 在系统息屏前提前使用摄像头进行本地人脸分析（不存储任何信息），支持两种独立模式：
  - 注视屏幕时不要息屏。
  - 面向屏幕时不要息屏。
- 延迟息屏时可弹出通知；摄像头启动超时与多帧阳性命中确认，避免误判。

### 音乐歌词

- 桌面歌词：悬浮歌词窗口，支持宽度、对齐、样式预设、字体、字号、颜色、描边、锁定位置等设置。
- 灵动大陆歌词：刘海区歌词形态，支持可视化频谱（需录音/屏幕录制权限）、鼠标移入隐藏、宽度/高度/圆角等微调。
- 任务栏歌词：菜单栏滚动歌词，支持宽度与对齐设置。
- 歌词源按 QQ 音乐、网易云音乐、Apple Music 的顺序回退搜索，可启用、排序；Apple Music 歌词源支持内置网页登录，登录后自动保存本机 media-user-token。
- 支持同时显示翻译和原文、首选语言、音乐应用白名单。

### 幻灯片批注（WPS 联动）

- 通过 WPS jsaddons 桥接加载项与本机 WebSocket 服务联动，在放映幻灯片时提供底部工具栏：笔、橡皮等批注工具与翻页控制。
- 点击页码弹出竖排页码缩略图预览；诊断日志写入 `~/Library/Logs/XiaoyuMacHelper/`。

### 杂项

- 鼠标组：
  - 滚轮反向：反转系统滚动方向（纵向与横向），无需修改系统设置即可独立开关。
  - 侧键映射前进/后退：鼠标侧键 4（后退）/ 侧键 5（前进）映射为 `⌘[` / `⌘]` 导航快捷键，适用于浏览器、访达等支持标准前进后退的应用。

## 系统要求

- macOS 15 或更高版本（兼容 macOS 26）。
- 构建环境同时支持两种 SDK：macOS 15 SDK（Xcode 16.x / Swift 6.1）或 macOS 26 SDK（Xcode 26 / Swift 6.2+）均可编译；产物运行时自动适配——macOS 26 上使用系统原生液态玻璃，macOS 15 上自动降级为毛玻璃。
- 选区工具栏、鼠标滚轮反向需要“辅助功能”权限。
- 主动视觉感知需要摄像头权限；截图与灵动大陆频谱需要屏幕录制权限。
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

双击启动会显示控制窗口，在“功能模块”分区勾选各功能；点击模块右侧的设置图标进入对应二级设置菜单。

如果点击 `大写` 后没有关闭大写，请在系统隐私设置里允许 `Xiaoyu MacHelper` 控制电脑。不同应用暴露选区信息的稳定性取决于它的 Accessibility 支持。

## 协议与版权

本项目采用 MIT License，详见 [LICENSE](./LICENSE) 文件。

桌面歌词模块参考并大幅精简重写了 Lyricify Lyrics Helper 的歌词接口思路。原项目 Apache License 2.0 文本已保留在 [THIRD_PARTY_NOTICES](./THIRD_PARTY_NOTICES/) 目录。

版权所有 © 2026 重庆沛雨霖科技有限公司

Chongqing Peiyulin Technology Co., Ltd. (PYLinTech)

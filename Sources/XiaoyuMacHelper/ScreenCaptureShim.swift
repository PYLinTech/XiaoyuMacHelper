import AppKit
import CoreGraphics
import Darwin

/// 通用屏幕捕获 shim：CGWindowListCreateImage 自 macOS 10.5 起存在，
/// 但 macOS 15 SDK 将其标记为 obsoleted，编译期不可直接调用。
/// 运行时符号始终存在，通过 dlsym 动态解析，获得跨系统版本的通用截图能力。
/// （放映批注的放大镜/截图工具与选区截图共用同一捕获实现。）
enum ScreenCaptureShim {
    /// AppKit 全局坐标点（左下原点）→ 所在屏显示器的 CG 坐标（左上原点）。
    /// 选区截图的矩形换算与放大镜取景共用同一公式，保证坐标语义一致。
    static func cgPoint(fromAppKit point: NSPoint, on screen: NSScreen) -> CGPoint? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        let displayBounds = CGDisplayBounds(displayID)
        return CGPoint(
            x: displayBounds.minX + point.x - screen.frame.minX,
            y: displayBounds.minY + screen.frame.maxY - point.y
        )
    }

    private typealias CaptureFn = @convention(c) (
        CGRect,
        UInt32,
        UInt32,
        UInt32
    ) -> Unmanaged<CGImage>?

    private static let capture: CaptureFn? = {
        // CoreGraphics 为常驻系统框架，dlopen 后不关闭，符号在进程生命周期内有效。
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else { return nil }
        guard let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CaptureFn.self)
    }()

    /// 捕获屏幕全局坐标（左上原点）中 rect 区域的画面，返回全分辨率图像。
    static func captureWindowListImage(in rect: CGRect) -> CGImage? {
        guard let capture else { return nil }
        let image = capture(
            rect,
            CGWindowListOption.optionAll.rawValue,
            kCGNullWindowID,
            // bestResolution：截图是一次性捕获，保存/剪贴板需要 Retina 全分辨率，
            // 不适用放大镜取景的 1× 提速取舍（那套逻辑见下方窗口级捕获函数）。
            CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue
        )
        return image?.takeRetainedValue()
    }

    /// 数组版捕获函数：**已弃用并移除**——macOS 15.5 实测 CGWindowListCreateImageFromArray
    /// 在 SkyLight 截屏权限校验路径（window_id_array_is_default_screen_capturable_internal_direct）
    /// 内必崩（CFArrayGetCount 段错误），与传入 option / 元素类型无关，任何调用都会
    /// 带崩整个进程。需要「本方浮层不入镜」的调用方改走截图前的临时隐藏
    /// （orderOut 立即离屏，捕获发生在交互数秒之后，远离 deprecated API 的帧滞后窗口期）。

    /// display 级兜底抓屏：按显示器 ID 捕获其坐标系中 rect 区域。
    /// CGDisplayCreateImageForRect 在新 SDK 同被标记不可用，走同样的 dlsym
    /// 运行时解析（符号在系统库中始终存在），供窗口列表捕获失败时使用。
    private typealias DisplayCaptureFn = @convention(c) (
        CGDirectDisplayID,
        CGRect
    ) -> Unmanaged<CGImage>?

    private static let displayCapture: DisplayCaptureFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else { return nil }
        guard let symbol = dlsym(handle, "CGDisplayCreateImageForRect") else { return nil }
        return unsafeBitCast(symbol, to: DisplayCaptureFn.self)
    }()

    /// 捕获指定显示器的 rect 区域（rect 为该显示器全局坐标空间，左上原点）。
    static func captureDisplayImage(displayID: CGDirectDisplayID, in rect: CGRect) -> CGImage? {
        guard let displayCapture else { return nil }
        return displayCapture(displayID, rect)?.takeRetainedValue()
    }

    /// 捕获 rect 区域中「本进程窗口以外」的合成画面（自底向上逐窗抓取拼合）。
    ///
    /// 用途：放大镜等需要「取景画面不含自身浮窗」的场景。整体合成式捕获
    /// （captureWindowListImage）会把调用方自己的窗口（镜头圆、工具栏、批注层）
    /// 一起画进画面——镜头会照到自身形成镜像递归。逐窗拼合并剔除本进程窗口后，
    /// 画面只剩放映内容；批注画布同属本进程一并剔除，与「放大镜压在画布之下」
    /// 的层级设计一致（放大内容不含批注笔迹）。
    static func captureOtherWindowsContent(in rect: CGRect, displayID: CGDirectDisplayID) -> CGImage? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else {
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        struct Candidate {
            let id: CGWindowID
            let bounds: CGRect
            let layer: Int
            let order: Int
        }

        var candidates: [Candidate] = []
        for (order, info) in infoList.enumerated() {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int, pid != ownPID else { continue }
            guard let rawID = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = info[kCGWindowLayer as String] as? Int else { continue }
            // 只取普通应用窗口；跳过系统浮层与高于批注体系的窗口。
            guard layer < Int(NSWindow.Level.screenSaver.rawValue) else { continue }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            guard bounds.intersects(rect) else { continue }
            candidates.append(Candidate(id: rawID, bounds: bounds, layer: layer, order: order))
        }
        guard !candidates.isEmpty else { return nil }
        // 自底向上：层低者先画；同层按窗口列表原序（原序越靠后越在上层）。
        candidates.sort { $0.layer != $1.layer ? $0.layer < $1.layer : $0.order < $1.order }

        let displayBounds = CGDisplayBounds(displayID)
        let scale = displayBounds.width > 0
            ? CGFloat(CGDisplayPixelsWide(displayID)) / displayBounds.width
            : 2
        let pixelWidth = Int(ceil(rect.width * scale))
        let pixelHeight = Int(ceil(rect.height * scale))
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        // 用户空间翻转为左上原点（与 CG 窗口坐标一致），再按像素密度放大。
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height))

        for candidate in candidates {
            let clipped = candidate.bounds.intersection(rect)
            guard clipped.width >= 1, clipped.height >= 1,
                  let image = captureWindowImage(candidate.id, in: clipped) else { continue }
            context.draw(
                image,
                in: CGRect(
                    x: clipped.minX - rect.minX,
                    y: clipped.minY - rect.minY,
                    width: clipped.width,
                    height: clipped.height
                )
            )
        }
        return context.makeImage()
    }

    /// 抓取单个窗口在给定屏幕区域内的图像（固定 nominalResolution 1×）。
    /// 仅供放大镜逐帧取景的兜底路径使用：内容为放大绘制，1× 足够且压低单帧成本。
    private static func captureWindowImage(_ windowID: CGWindowID, in rect: CGRect) -> CGImage? {
        guard let capture else { return nil }
        let image = capture(
            rect,
            CGWindowListOption.optionIncludingWindow.rawValue,
            windowID,
            // nominalResolution（1×）：放大镜内容是放大绘制，源图用逻辑分辨率
            // 足够；bestResolution 在 Retina 下像素量 ×4，是持续取景卡顿的大头。
            CGWindowImageOption.nominalResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue
        )
        return image?.takeRetainedValue()
    }

    /// 单次系统调用捕获「指定窗口之下」的全部画面。
    ///
    /// 用途：放大镜取景。以镜头窗口自身编号为界向下捕获，镜头/控制条/批注画布/
    /// 工具栏（全部在本进程且位于镜头之上）天然不入镜——既避免镜头照到自身的
    /// 镜像递归，又把每帧成本从「逐窗抓取+自拼合」降为一次系统合成，是放大镜
    /// 持续取景的首选路径。失败时调用方回退 captureOtherWindowsContent 等兜底。
    ///
    /// 分辨率分档（放大镜双档取景）：交互态（移动/改大小）传 `false` 用 1×
    /// 逻辑分辨率压低单帧成本换取帧率；静态态传 `true` 用 bestResolution
    /// （Retina 2×）保证放大画质。兜底路径（逐窗拼合/display 抓屏）恒为 1×。
    static func captureBelowWindow(windowNumber: CGWindowID, in rect: CGRect, highResolution: Bool) -> CGImage? {
        guard let capture, windowNumber != kCGNullWindowID else { return nil }
        // bestResolution 在 Retina 下像素量 ×4：仅静态低帧率时值得付出。
        let resolution: CGWindowImageOption = highResolution ? .bestResolution : .nominalResolution
        let image = capture(
            rect,
            CGWindowListOption.optionOnScreenBelowWindow.rawValue | CGWindowListOption.excludeDesktopElements.rawValue,
            windowNumber,
            resolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue
        )
        return image?.takeRetainedValue()
    }
}

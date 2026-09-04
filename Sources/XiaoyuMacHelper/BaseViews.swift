import AppKit
import QuartzCore

@MainActor
final class ClickableView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

// MARK: - CADisplayLink 驱动转发

/// CADisplayLink 每帧回调协议：由 DisplayLinkTarget 转发给弱引用视图。
@MainActor
protocol DisplayLinkResponding: AnyObject {
    func displayLinkDidFire(_ link: CADisplayLink)
}

/// CADisplayLink target 转发器：display link 会强持有 target，target 必须
/// 以 weak view 转发防环。各歌词/频谱视图原先各自手写一份同构样板类，
/// 统一收敛到本泛型实现。
@MainActor
final class DisplayLinkTarget<View: DisplayLinkResponding>: NSObject {
    private weak var view: View?

    init(view: View) {
        self.view = view
        super.init()
    }

    @objc func displayLinkDidFire(_ link: CADisplayLink) {
        view?.displayLinkDidFire(link)
    }
}

// MARK: - 水平边缘淡出

/// 文本横向滚动两端渐隐的共享渲染：以 `.destinationOut` 在左右边缘各绘制
/// 一段宽 `fade` 的透明度渐变。桌面歌词行视图（0.88，带缓存）与灵动岛
/// 标题跑马灯（0.82）共用绘制逻辑，仅端点 alpha 与缓存策略不同。
@MainActor
enum EdgeFadeRenderer {
    typealias FadeGradients = (left: CGGradient, right: CGGradient)

    /// 构造左右两组黑→透明渐变（`peakAlpha` 为贴边端点的不透明度）。
    static func makeGradients(peakAlpha: CGFloat) -> FadeGradients? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let leftGradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [
                    NSColor.black.withAlphaComponent(peakAlpha).cgColor,
                    NSColor.black.withAlphaComponent(0.0).cgColor
                ] as CFArray,
                locations: [0, 1]
            ),
            let rightGradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [
                    NSColor.black.withAlphaComponent(0.0).cgColor,
                    NSColor.black.withAlphaComponent(peakAlpha).cgColor
                ] as CFArray,
                locations: [0, 1]
            )
        else { return nil }
        return (leftGradient, rightGradient)
    }

    /// 在 `bounds` 左右边缘各绘制宽 `fade` 的渐隐（调用方已完成 fade clamp 与 >1 检查）。
    static func apply(in context: CGContext, bounds: NSRect, fade: CGFloat, gradients: FadeGradients) {
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.drawLinearGradient(
            gradients.left,
            start: CGPoint(x: bounds.minX, y: bounds.midY),
            end: CGPoint(x: bounds.minX + fade, y: bounds.midY),
            options: []
        )
        context.drawLinearGradient(
            gradients.right,
            start: CGPoint(x: bounds.maxX - fade, y: bounds.midY),
            end: CGPoint(x: bounds.maxX, y: bounds.midY),
            options: []
        )
        context.restoreGState()
    }
}

// MARK: - 点外收起监听

/// 「点击浮层外部自动收起」的 local 鼠标监听统一封装。页码预览窗、
/// 工具二级菜单、退出确认弹窗三处共用：监听掩码（左/右键按下）与
/// 生命周期管理一致，豁免判定与收起动作由各方提供。
@MainActor
final class OutsideClickDismissMonitor {
    private var monitor: Any?

    /// `isExempt` 返回 true 放行该点击（点浮层自身等）；否则触发 `onDismiss`。
    /// 事件始终照常传递给原窗口（只补收起，不吞事件）。
    func install(isExempt: @escaping (NSEvent) -> Bool, onDismiss: @escaping () -> Void) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if !isExempt(event) {
                onDismiss()
            }
            return event
        }
    }

    func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

@MainActor
class FloatingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    func configureFloatingOverlay() {
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = false
    }
}

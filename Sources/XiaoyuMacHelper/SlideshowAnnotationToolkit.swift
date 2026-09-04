import AppKit
import AVFoundation
import CoreGraphics

// MARK: - 自建工具条目

/// 底部工具栏「工具」(briefcase) 二级菜单里的自建工具。
enum SlideshowToolkitItem: Int, CaseIterable {
    case screenshot   // 截图
    case timer        // 计时器
    case magnifier    // 放大镜
    case scratchpad   // 草稿纸

    var title: String {
        switch self {
        case .screenshot: return "截图"
        case .timer: return "计时器"
        case .magnifier: return "放大镜"
        case .scratchpad: return "草稿纸"
        }
    }

    /// 二级菜单行图标（Bundle SVG 资源名，不含扩展名；与工具栏同源矢量）。
    var svgResource: String {
        switch self {
        case .screenshot: return "scissors"
        case .timer: return "timer"
        case .magnifier: return "plus.magnifyingglass"
        case .scratchpad: return "rectangle.on.rectangle.angled"
        }
    }
}

// MARK: - 二级菜单共享组件

/// 深色圆角底菜单容器基类：黑 0.72 圆角底 + 行间细分隔线（最后一行之后
/// 不再画），上下留白 12pt、行区左右内缩 8pt。工具 / 橡皮二级菜单共用。
@MainActor
class SlideshowMenuContainerView: NSView {
    private enum Metrics {
        static let cornerRadius: CGFloat = 20
        static let rowHeight: CGFloat = 40
        /// 行区域上下留白。
        static let verticalPadding: CGFloat = 12
        /// 行相对容器的左右内缩。
        static let rowHorizontalInset: CGFloat = 8
        /// 分隔线相对容器的左右内缩。
        static let separatorInset: CGFloat = 18
    }

    /// 菜单内容固有尺寸（宽 × 行数推得），供菜单窗口设定 contentSize。
    let intrinsicSize: NSSize
    /// 条目行数（决定分隔线数量）。
    private let rowCount: Int

    init(rowCount: Int, menuWidth: CGFloat) {
        self.rowCount = rowCount
        self.intrinsicSize = NSSize(
            width: menuWidth,
            height: Metrics.verticalPadding * 2 + Metrics.rowHeight * CGFloat(rowCount)
        )
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 第 index 行（从 0 起、自上而下）的 frame（isFlipped 布局）。
    func frameForRow(at index: Int) -> NSRect {
        NSRect(
            x: Metrics.rowHorizontalInset,
            y: Metrics.verticalPadding + Metrics.rowHeight * CGFloat(index),
            width: intrinsicSize.width - Metrics.rowHorizontalInset * 2,
            height: Metrics.rowHeight
        )
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds,
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        path.fill()
        // 行间细分隔线（最后一行之后不再画）。
        for i in 1..<rowCount {
            let y = Metrics.verticalPadding + Metrics.rowHeight * CGFloat(i)
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSRect(x: Metrics.separatorInset, y: y - 0.5, width: bounds.width - Metrics.separatorInset * 2, height: 1).fill()
        }
    }
}

/// 菜单单行条目（SVG 图标 + 名称）：整行可点，无选中态。
/// 工具二级菜单 / 橡皮菜单共用（排版参数一致）。
@MainActor
final class SlideshowMenuRow: NSView {
    var onClick: (() -> Void)?

    private enum Metrics {
        /// 菜单行内图标方框边长与对角线归一系数（0.85 实测匹配 14pt 行标题，
        /// 与工具栏 0.64@40pt 的视觉占幅相当）。
        static let iconBoxSide: CGFloat = 22
        static let iconDiagonalFraction: CGFloat = 0.85
        /// 行内左边距：图标起点 / 标题起点（图标框 + 间距）。
        static let leading: CGFloat = 14
        static let iconTitleGap: CGFloat = 10
    }

    private let svgResource: String
    private let title: NSAttributedString

    init(title: String, svgResource: String) {
        self.svgResource = svgResource
        self.title = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95)
        ])

        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// 无边框矩形：内容全部自绘、无子视图，默认 hitTest 即正确（点位在
    /// bounds 内返回自身），无需也不应重写 hitTest——重写必踩「point 在
    /// superview 坐标系」的坑，多行同容器时表现为点哪都命中最后一行。
    override func draw(_ dirtyRect: NSRect) {
        let iconY = (bounds.height - Metrics.iconBoxSide) / 2
        SlideshowToolbarIconButton.drawIcon(
            named: svgResource,
            box: NSRect(x: Metrics.leading, y: iconY, width: Metrics.iconBoxSide, height: Metrics.iconBoxSide),
            viewHeight: bounds.height,
            tint: NSColor.white.withAlphaComponent(0.95),
            diagonalFraction: Metrics.iconDiagonalFraction
        )
        let titleSize = title.size()
        let titleY = (bounds.height - titleSize.height) / 2
        title.draw(at: NSPoint(
            x: Metrics.leading + Metrics.iconBoxSide + Metrics.iconTitleGap,
            y: titleY
        ))
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - 工具二级菜单

/// 工具二级菜单内容视图：深色圆角底 + 四行「图标 + 名称」条目，
/// 与笔/橡皮胶囊同一套深底白字观感。点击某行收起菜单并回调。
@MainActor
private final class SlideshowToolkitMenuView: SlideshowMenuContainerView {
    var onItemSelected: ((SlideshowToolkitItem) -> Void)?

    init() {
        super.init(rowCount: SlideshowToolkitItem.allCases.count, menuWidth: 176)
        for (index, item) in SlideshowToolkitItem.allCases.enumerated() {
            let row = SlideshowMenuRow(title: item.title, svgResource: item.svgResource)
            row.frame = frameForRow(at: index)
            row.onClick = { [weak self] in
                self?.onItemSelected?(item)
            }
            addSubview(row)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 工具二级菜单窗口：复用基类的进出场动画与「点外收起」逻辑，
/// 锚点是底部工具栏的工具按钮（briefcase）。
@MainActor
final class SlideshowToolkitMenuWindow: SlideshowToolMenuWindow {
    var onItemSelected: ((SlideshowToolkitItem) -> Void)?

    private let menuView: SlideshowToolkitMenuView

    init() {
        menuView = SlideshowToolkitMenuView()
        super.init(contentSize: menuView.intrinsicSize)
        menuView.onItemSelected = { [weak self] item in
            guard let self else { return }
            // 选中即收起菜单，由调用方（工具栏）把选择交给控制器。
            self.hide()
            self.onItemSelected?(item)
        }
        menuView.frame = NSRect(origin: .zero, size: menuView.intrinsicSize)
        contentView = menuView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - 放大镜（矩形镜头 + 内嵌悬浮控制胶囊，层级在批注画布之下）

/// 放大镜窗口：矩形镜头，观感与截图选区一致（白色 2pt 直角边框 + 四角白色
/// 圆点）。压在批注画布之下（`SlideshowFloatingLevel.magnifier`）。
///
/// 交互：
/// - 放大镜全部 UI（镜头与外部工具条）都压在批注画布之下：选中放大镜工具
///   时工具栏会切到鼠标模式（画布穿透），此时可点工具条按钮、按住镜头拖动；
///   切回画笔/橡皮后画布拦截事件，笔迹直接画在放大画面之上。
/// - **工具条在镜头外部**（镜头下方居中的独立悬浮胶囊）：鼠标悬停时浮现、
///   **1.2 秒**无操作自动淡出；按住胶囊空白处 / 镜头任意处拖动即可移动镜头。
/// - 「放大 / 缩小」调整倍率（**1× – 10×**），中间实时显示当前倍率；
///   「关闭」隐藏放大镜（倍率与位置保留，工具菜单可再次呼出）。
/// - **拖动四角点调整镜头大小**（对角固定，最小 160×120，最大约屏 80%）；
///   拖动镜头本体移动位置。
@MainActor
final class SlideshowMagnifierWindow: NSPanel {
    /// 用户点工具条「关闭」时回调（供控制器记录日志）。
    var onClose: (() -> Void)?

    private enum Metrics {
        /// 镜头默认尺寸（矩形；窗口额外含底部工具条区，见 LensView.chromeHeight）。
        static let defaultSize = NSSize(width: 280, height: 190)
        /// 放大倍率默认值（工具条上每次 ±0.2×，可调范围 1×–10× 见 LensView.Metrics）。
        static let defaultZoom: CGFloat = 2.0
    }

    private let lensView: SlideshowMagnifierLensView

    init() {
        lensView = SlideshowMagnifierLensView(zoom: Metrics.defaultZoom)
        let windowSize = SlideshowMagnifierLensView.windowSize(for: Metrics.defaultSize)
        super.init(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        level = SlideshowFloatingLevel.magnifier
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        lensView.frame = NSRect(origin: .zero, size: windowSize)
        lensView.autoresizingMask = [.width, .height]
        contentView = lensView

        // 控制胶囊「关闭」：只隐藏（orderOut 连带停止捕获），不清任何状态；
        // 重新呼出时倍率与镜头位置原样恢复。
        lensView.onClose = { [weak self] in
            guard let self else { return }
            self.onClose?()
            self.orderOut(nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 显示在给定屏幕中央（默认取景位置）。
    func show(centeredIn screenFrame: NSRect) {
        show(in: NSRect(
            x: screenFrame.midX - frame.width / 2,
            y: screenFrame.midY - frame.height / 2,
            width: frame.width,
            height: frame.height
        ))
    }

    /// 按给定 frame 显示并恢复屏幕捕获（每次呼出由控制器给默认居中位——
    /// 放大镜重开回默认位是有意设计，与草稿纸的原位恢复语义不同）；
    /// 控制胶囊一并浮现（稍后自动淡出）。
    func show(in frame: NSRect) {
        setFrame(frame, display: true)
        orderFrontRegardless()
        lensView.startRefreshing()
        lensView.showControls()
    }

    /// 隐藏并停止屏幕捕获。
    override func orderOut(_ sender: Any?) {
        lensView.stopRefreshing()
        super.orderOut(sender)
    }
}

/// 控制工具条：镜头**外部**、镜头下方居中的深色悬浮胶囊 —— [−] 2.0× [+] | [×]。
/// 背景对鼠标事件**穿透**（按下即拖动镜头），只有四个按钮可点。
@MainActor
private final class SlideshowMagnifierControlOverlay: NSView {
    /// 三个按钮 + 中间倍率标签撑起条身。
    static let preferredSize = NSSize(width: 152, height: 32)

    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onClose: (() -> Void)?

    private enum Metrics {
        static let cornerRadius: CGFloat = 16
        static let buttonWidth: CGFloat = 34
    }

    private let zoomOutButton = MagnifierOverlayButton(symbolName: "minus.magnifyingglass", accessibilityLabel: "缩小")
    private let zoomInButton = MagnifierOverlayButton(symbolName: "plus.magnifyingglass", accessibilityLabel: "放大")
    private let closeButton = MagnifierOverlayButton(symbolName: "xmark", accessibilityLabel: "关闭")
    private let zoomLabel = NSTextField(labelWithString: "2.0×")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        zoomOutButton.onClick = { [weak self] in self?.onZoomOut?() }
        zoomInButton.onClick = { [weak self] in self?.onZoomIn?() }
        closeButton.onClick = { [weak self] in self?.onClose?() }
        zoomLabel.isEditable = false
        zoomLabel.isBordered = false
        zoomLabel.drawsBackground = false
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        zoomLabel.textColor = .white.withAlphaComponent(0.92)
        zoomLabel.alignment = .center
        addSubview(zoomOutButton)
        addSubview(zoomInButton)
        addSubview(closeButton)
        addSubview(zoomLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 倍率变化时刷新中间标签。
    func setZoom(_ zoom: CGFloat) {
        zoomLabel.stringValue = String(format: "%.1f×", zoom)
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        let h = bounds.height
        zoomOutButton.frame = NSRect(x: 0, y: 0, width: Metrics.buttonWidth, height: h)
        zoomInButton.frame = NSRect(x: Metrics.buttonWidth, y: 0, width: Metrics.buttonWidth, height: h)
        closeButton.frame = NSRect(x: bounds.width - Metrics.buttonWidth, y: 0, width: Metrics.buttonWidth, height: h)
        let labelX = Metrics.buttonWidth * 2
        zoomLabel.frame = NSRect(x: labelX, y: (h - 16) / 2, width: bounds.width - Metrics.buttonWidth * 3, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds,
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        )
        NSColor.black.withAlphaComponent(0.62).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 1
        path.stroke()
        // 倍率标签区与按钮区之间的细分隔线（两条）。
        NSColor.white.withAlphaComponent(0.10).setFill()
        let b = Metrics.buttonWidth
        NSRect(x: b - 0.5, y: 8, width: 1, height: bounds.height - 16).fill()
        NSRect(x: bounds.width - b - 0.5, y: 8, width: 1, height: bounds.height - 16).fill()
    }

    /// 命中分发：只接按钮，胶囊背景（倍率标签区）穿透给镜头拖动。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for button in [zoomOutButton, zoomInButton, closeButton] where button.frame.contains(local) {
            return button
        }
        return nil
    }
}

/// 控制胶囊单个图标按钮：符号图标居中，整面为点击区。
@MainActor
private final class MagnifierOverlayButton: NSView {
    var onClick: (() -> Void)?

    private let iconView: NSImageView

    init(symbolName: String, accessibilityLabel: String) {
        iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.92)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        super.init(frame: .zero)
        setAccessibilityLabel(accessibilityLabel)
        addSubview(iconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let iconSize: CGFloat = 16
        iconView.frame = NSRect(
            x: (bounds.width - iconSize) / 2,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 放大镜镜片：矩形画面 + 深色直角边框 + 四角深色圆点（借鉴截图选区的
/// 结构布局，但配色保持放大镜自身的深色系），四周留边保证角点完整不被
/// 窗口裁剪。
/// 内容为镜头下方屏幕区域的放大图，**双档取景**：交互态（移动/改大小）30fps
/// 高帧率 + 1× 低分辨率保跟手；静态态 3fps 低帧率 + bestResolution 高分辨率
/// 保画质（在途守卫 + 最小间隔双重去抖）。按住镜片拖动即移动镜头；拖四角点
/// 调整镜头大小（对角固定）。底部工具条悬浮在镜头外部（窗口底部透明条带内）：
/// 悬停浮现、1.2 秒无操作自动淡出；放大镜越出屏幕时工具条钳制在屏幕内
/// （可上移进镜头内部）。
@MainActor
private final class SlideshowMagnifierLensView: NSView {
    /// 工具条「关闭」回调（窗口据此隐藏自身并停止捕获）。
    var onClose: (() -> Void)?

    private enum Metrics {
        /// 镜头取景区四周留边：四角点（半径 8 + 光环）以镜头角点为圆心、
        /// 超出镜头边缘约 9pt——留边保证角点完整落在窗口内，不被裁剪。
        static let edgeMargin: CGFloat = 12
        /// 四角点半径与描边（深色实心圆 + 浅色细环，比截图选区圆点略小）。
        static let dotRadius: CGFloat = 8
        static let zoomRange: ClosedRange<CGFloat> = 1...10
        /// 倍率步进：每次 ±0.2× 线性加减（在 zoomIn/zoomOut 内联使用）。
        static let zoomStep: CGFloat = 0.2
        /// 双档取景——交互态（移动/改大小）：最高帧率 30fps + 1× 低分辨率，
        /// 优先跟手；静态态：低帧率 3fps + bestResolution 高分辨率，优先画质。
        static let activeRefreshInterval: TimeInterval = 1.0 / 30.0
        static let staticRefreshInterval: TimeInterval = 0.3
        /// 捕获最小启动间隔：与交互档帧率一致，防请求堆积（在途守卫兜底）。
        static let captureMinInterval: TimeInterval = 1.0 / 30.0
        /// 工具条无操作自动淡出的延时。
        static let controlsHideDelay: TimeInterval = 1.2
        /// 窗口底部工具条区总高：上 8 + 条高 32 + 下 8。
        static let chromeHeight: CGFloat = 48
        /// 工具条条身高与底部间距。
        static let toolbarHeight: CGFloat = 32
        static let toolbarBottomInset: CGFloat = 8
        /// 镜头可调尺寸范围（四角拖拽）。
        static let minLensSize = NSSize(width: 160, height: 120)
        static let maxLensSize = NSSize(width: 960, height: 640)
        /// 四角拖拽命中半径（距角点该距离内按下即进入缩放）。
        static let cornerGrabRadius: CGFloat = 20
    }

    /// 窗口尺寸 = 镜头尺寸 + 四周角点留边 + 底部工具条区。
    static func windowSize(for lensSize: NSSize) -> NSSize {
        NSSize(
            width: lensSize.width + Metrics.edgeMargin * 2,
            height: lensSize.height + Metrics.edgeMargin + Metrics.chromeHeight
        )
    }

    /// 镜头取景区（视图坐标、左下原点）：四周扣除角点留边，底部再扣工具条区。
    var lensBounds: NSRect {
        NSRect(
            x: Metrics.edgeMargin,
            y: Metrics.chromeHeight,
            width: bounds.width - Metrics.edgeMargin * 2,
            height: bounds.height - Metrics.chromeHeight - Metrics.edgeMargin
        )
    }

    private var zoom: CGFloat

    private var latestSource: CGImage?
    private var captureFailed = false
    private var refreshTimer: Timer?

    /// 内嵌工具条（镜头外部底部条带）与其显隐定时器。
    private let controlOverlay = SlideshowMagnifierControlOverlay()
    private var controlsHideTimer: Timer?
    private var controlsTrackingArea: NSTrackingArea?

    init(zoom: CGFloat) {
        self.zoom = zoom
        super.init(frame: .zero)
        wantsLayer = true
        controlOverlay.onZoomIn = { [weak self] in self?.zoomIn() }
        controlOverlay.onZoomOut = { [weak self] in self?.zoomOut() }
        controlOverlay.onClose = { [weak self] in self?.onClose?() }
        controlOverlay.setZoom(zoom)
        addSubview(controlOverlay)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        // 工具条默认：镜头外部、窗口底部条带内居中（非翻转坐标，y 小者为底）。
        let size = SlideshowMagnifierControlOverlay.preferredSize
        var frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: Metrics.toolbarBottomInset,
            width: size.width,
            height: size.height
        )
        // 屏幕内约束：放大镜窗口允许越出屏幕（移动/改大小均不设屏界），
        // 但工具条必须保持在屏幕内——窗口底边离屏时工具条上移，可进入
        // 镜头内部；窗口横向大部分离屏时同样向屏内收。
        if let screenFrame = window?.screen?.frame ?? NSScreen.main?.frame,
           let winFrame = window?.frame {
            let screenInWindow = NSRect(
                x: screenFrame.minX - winFrame.minX,
                y: screenFrame.minY - winFrame.minY,
                width: screenFrame.width,
                height: screenFrame.height
            )
            // 仅当屏幕范围容得下工具条时做 clamp，避免窗口几乎整体离屏时区间反转。
            if screenInWindow.width >= frame.width + 16 {
                frame.origin.x = min(
                    max(frame.minX, screenInWindow.minX + 8),
                    screenInWindow.maxX - frame.width - 8
                )
            }
            if screenInWindow.height >= frame.height + 16 {
                frame.origin.y = min(
                    max(frame.minY, screenInWindow.minY + 8),
                    screenInWindow.maxY - frame.height - 8
                )
            }
        }
        controlOverlay.frame = frame
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopRefreshing()
            hideControlsNow()
        }
    }

    // MARK: 倍率

    func zoomIn() { zoom(by: Metrics.zoomStep) }

    func zoomOut() { zoom(by: -Metrics.zoomStep) }

    /// ±0.2× 线性加减；以 0.1 精度取整规避浮点累加误差（如 2.7999998）。
    private func zoom(by delta: CGFloat) {
        showControls()
        // 先按 0.1 精度取整、再 clamp 到 1...10；clamp 必须作用在原始倍率上，
        // 若先 clamp ×10 后的值（8~120 落入 1...10）会得到 0.1...1.0 的错误范围。
        let next = clampZoom(((zoom + delta) * 10).rounded() / 10)
        guard next != zoom else { return }
        zoom = next
        controlOverlay.setZoom(zoom)
        refreshNow(force: true)
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, Metrics.zoomRange.lowerBound), Metrics.zoomRange.upperBound)
    }

    // MARK: 控制胶囊显隐（悬停浮现 / 无操作自动淡出）

    /// 显示控制胶囊并重置自动淡出计时（悬停、拖动、缩放、显示窗口时调用）。
    func showControls() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
        guard controlOverlay.alphaValue != 1 || controlOverlay.isHidden else {
            scheduleHideControls()
            return
        }
        controlOverlay.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.controlOverlay.animator().alphaValue = 1
        } completionHandler: {
            // 淡出中途被重新显示时，完成块里的旧状态不覆盖新状态。
            if self.controlOverlay.alphaValue >= 1 {
                self.scheduleHideControls()
            }
        }
    }

    private func scheduleHideControls() {
        controlsHideTimer?.invalidate()
        let timer = Timer(timeInterval: Metrics.controlsHideDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hideControls() }
        }
        RunLoop.main.add(timer, forMode: .common)
        controlsHideTimer = timer
    }

    private func hideControls() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
        // 光标仍悬停在控制胶囊上时不淡出（如停在按钮上连续点击放大/缩小、
        // 静止悬停查看倍率），继续等待离开后再计时。
        if isCursorOverControls {
            scheduleHideControls()
            return
        }
        guard controlOverlay.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.controlOverlay.animator().alphaValue = 0
        } completionHandler: {
            // 中途被重新显示（alpha 又回到 1）时不隐藏。
            if self.controlOverlay.alphaValue < 0.01 {
                self.controlOverlay.isHidden = true
            }
        }
    }

    /// 光标当前是否悬停在控制胶囊上（含 4pt 容差）。
    private var isCursorOverControls: Bool {
        guard let window else { return false }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return controlOverlay.frame.insetBy(dx: -4, dy: -4).contains(local)
    }

    /// 立即隐藏（窗口关闭 / 移出窗口层级时清理用，不带动画）。
    private func hideControlsNow() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
        // 直接赋值不走 animator()：隐式动画会与进行中的淡出动画叠加，
        // 与"立即"语义相悖，极端时序下胶囊会闪现。
        controlOverlay.alphaValue = 1
        controlOverlay.isHidden = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let controlsTrackingArea {
            removeTrackingArea(controlsTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        controlsTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        showControls()
    }

    override func mouseMoved(with event: NSEvent) {
        showControls()
    }

    override func mouseExited(with event: NSEvent) {
        // 离开镜头稍快淡出；胶囊上仍会先经 showControls 重置计时。
        scheduleHideControls()
    }

    // MARK: 取景刷新

    /// 双档取景状态：true = 交互态（移动/改大小，高帧率低分辨率），
    /// false = 静态态（低帧率高分辨率）。由 mouseDown/mouseUp 驱动切换。
    private var isInteracting = false
    /// 在途帧守卫：上一帧未回来不派发新捕获——拖动事件率（可达 120Hz）远高于
    /// 截屏耗时，无守卫时请求会无限排队、回主线程的重绘也连环堆积（卡顿根因）。
    private var captureInFlight = false
    /// 上次捕获启动时刻：与在途守卫配合构成帧率节流上限。
    private var lastCaptureStartedAt = Date.distantPast

    func startRefreshing() {
        stopRefreshing()
        isInteracting = false
        restartRefreshTimer()
        refreshNow(force: true)
    }

    func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// 切换取景档位并按新档帧率重建定时器（Timer 间隔固定，切换即重建）。
    private func applyRefreshMode(active: Bool) {
        guard isInteracting != active else { return }
        isInteracting = active
        restartRefreshTimer()
        if active {
            refreshNow(force: true)
        }
    }

    private func restartRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = isInteracting ? Metrics.activeRefreshInterval : Metrics.staticRefreshInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// 取景一帧。`force` 绕过最小间隔（缩放按钮等离散操作），但在途守卫始终生效。
    /// 分辨率随档位：交互态 1×（压单帧成本），静态态 bestResolution（保画质）。
    func refreshNow(force: Bool = false) {
        guard window?.isVisible == true else { return }
        guard !captureInFlight else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastCaptureStartedAt) >= Metrics.captureMinInterval else { return }
        lastCaptureStartedAt = now
        guard CGPreflightScreenCaptureAccess() else {
            if !captureFailed {
                captureFailed = true
                needsDisplay = true
            }
            return
        }
        captureFailed = false
        guard let (rect, screen) = sourceCaptureRect() else { return }
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        let windowNumber = window.map { CGWindowID($0.windowNumber) } ?? kCGNullWindowID
        let highResolution = !isInteracting
        captureInFlight = true
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            // 首选：以镜头窗口自身为界向下单次捕获（一次系统调用）。镜头/工具条/
            // 批注画布/工具栏都在镜头之上，天然不入镜——既避免镜头照到自身的
            // 镜像递归，也把每帧成本从「逐窗抓取+自拼合」降为一次系统合成。
            var image = ScreenCaptureShim.captureBelowWindow(windowNumber: windowNumber, in: rect, highResolution: highResolution)
            if image == nil {
                // 兜底1：逐窗拼合并剔除本进程窗口。
                image = ScreenCaptureShim.captureOtherWindowsContent(in: rect, displayID: displayID)
            }
            if image == nil {
                // 兜底2：display 级抓屏（不依赖窗口列表），保证出图。
                image = ScreenCaptureShim.captureDisplayImage(displayID: displayID, in: rect)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.captureInFlight = false
                self.latestSource = image
                self.needsDisplay = true
            }
        }
    }

    /// 镜头中心对应的源区域（屏幕全局 → CG 左上原点换算）。矩形取景：
    /// 源区域宽高分别等于镜头取景区宽高除以倍率。
    private func sourceCaptureRect() -> (CGRect, NSScreen)? {
        guard let screen = window?.screen ?? NSScreen.main else { return nil }
        // 镜头取景区中心（视图坐标 → 窗口坐标 → 屏幕全局坐标）。
        let lens = lensBounds
        let centerInWindow = convert(NSPoint(x: lens.midX, y: lens.midY), to: nil)
        let windowFrame = window?.frame ?? frame
        let centerX = windowFrame.origin.x + centerInWindow.x
        let centerY = windowFrame.origin.y + centerInWindow.y
        let sourceWidth = lens.width / zoom
        let sourceHeight = lens.height / zoom

        // AppKit（左下原点）→ CG（左上原点）换算：与选区截图共用同一公式。
        guard let cgCenter = ScreenCaptureShim.cgPoint(
            fromAppKit: NSPoint(x: centerX, y: centerY),
            on: screen
        ) else { return nil }
        return (
            CGRect(
                x: cgCenter.x - sourceWidth / 2,
                y: cgCenter.y - sourceHeight / 2,
                width: sourceWidth,
                height: sourceHeight
            ),
            screen
        )
    }

    // MARK: 拖动（移动 / 四角缩放）

    private enum DragMode {
        /// 移动镜头：记按下时鼠标与窗口原点。
        case move(startMouse: NSPoint, startOrigin: NSPoint)
        /// 四角缩放：记抓取角索引与固定对角点（屏幕全局坐标）。
        case resize(grabbedCorner: Int, anchor: NSPoint)
    }

    private var dragMode: DragMode?
    /// 拖动中工具条保活的重置节流（避免每帧重建计时器）。
    private var lastDragControlsReset = Date.distantPast

    /// 镜头取景区四角（视图坐标、左下原点）。顺序：0 左下 / 1 左上 / 2 右下 / 3 右上。
    private var lensCorners: [NSPoint] {
        let lens = lensBounds
        return [
            NSPoint(x: lens.minX, y: lens.minY),
            NSPoint(x: lens.minX, y: lens.maxY),
            NSPoint(x: lens.maxX, y: lens.minY),
            NSPoint(x: lens.maxX, y: lens.maxY)
        ]
    }

    /// 对角索引（0↔3、1↔2）。
    private static func oppositeCorner(_ index: Int) -> Int { index ^ 3 }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        // 四角命中 → 缩放模式：锚点 = 对角点换算到屏幕全局坐标（AppKit 左下原点）。
        if let index = lensCorners.firstIndex(where: { hypot(local.x - $0.x, local.y - $0.y) <= Metrics.cornerGrabRadius }) {
            let anchorInView = lensCorners[Self.oppositeCorner(index)]
            let anchorInWindow = convert(anchorInView, to: nil)
            let origin = window?.frame.origin ?? .zero
            dragMode = .resize(
                grabbedCorner: index,
                anchor: NSPoint(x: origin.x + anchorInWindow.x, y: origin.y + anchorInWindow.y)
            )
        } else {
            dragMode = .move(startMouse: NSEvent.mouseLocation, startOrigin: window?.frame.origin ?? .zero)
        }
        // 进入交互态：切到高帧率 + 低分辨率取景档。
        applyRefreshMode(active: true)
        NSCursor.closedHand.push()
        showControls()
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        switch dragMode {
        case .move(let start, let origin):
            window?.setFrameOrigin(NSPoint(
                x: origin.x + current.x - start.x,
                y: origin.y + current.y - start.y
            ))
        case .resize(_, let anchor):
            // 以固定对角为锚，按鼠标位置出新 frame；越界时朝鼠标侧收/放。
            var minX = min(anchor.x, current.x)
            var maxX = max(anchor.x, current.x)
            var minY = min(anchor.y, current.y)
            var maxY = max(anchor.y, current.y)
            let minS = Metrics.minLensSize
            let maxS = Metrics.maxLensSize
            if maxX - minX < minS.width {
                if current.x >= anchor.x { minX = maxX - minS.width } else { maxX = minX + minS.width }
            } else if maxX - minX > maxS.width {
                if current.x >= anchor.x { minX = maxX - maxS.width } else { maxX = minX + maxS.width }
            }
            if maxY - minY < minS.height {
                if current.y >= anchor.y { minY = maxY - minS.height } else { maxY = minY + minS.height }
            } else if maxY - minY > maxS.height {
                if current.y >= anchor.y { minY = maxY - maxS.height } else { maxY = minY + maxS.height }
            }
            // 不做屏幕边界钳制：放大镜允许越出屏幕（工具条另行保屏内）。
            // 鼠标矩形 = 新的镜头矩形（锚点为对角**镜头角点**）；窗口 frame
            // = 镜头矩形 + 左右/顶部角点留边 + 底部工具条区。
            let lensWidth = maxX - minX
            let lensHeight = maxY - minY
            window?.setFrame(
                NSRect(
                    x: minX - Metrics.edgeMargin,
                    y: minY - Metrics.chromeHeight,
                    width: lensWidth + Metrics.edgeMargin * 2,
                    height: lensHeight + Metrics.chromeHeight + Metrics.edgeMargin
                ),
                display: true
            )
        case nil:
            return
        }
        // 窗口位置变化后重新钳制工具条（保持屏幕内，可上移进镜头内部）；
        // 尺寸/位置变化后按节流刷新内容；工具条保活计时按 0.5s 节流重置
        // （每帧 invalidate+重建 Timer 也是一笔无谓开销）。
        needsLayout = true
        refreshNow()
        if Date().timeIntervalSince(lastDragControlsReset) > 0.5 {
            lastDragControlsReset = Date()
            scheduleHideControls()
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = nil
        NSCursor.pop()
        // 回到静态态：低帧率 + 高分辨率；补一帧高清定妆。
        applyRefreshMode(active: false)
        refreshNow(force: true)
        // 拖动/改大小结束：满额重置工具条淡出计时。
        showControls()
    }

    override func resetCursorRects() {
        // 四角十字光标提示可缩放，其余开放手掌提示可拖动。
        for corner in lensCorners {
            addCursorRect(
                NSRect(
                    x: corner.x - Metrics.cornerGrabRadius,
                    y: corner.y - Metrics.cornerGrabRadius,
                    width: Metrics.cornerGrabRadius * 2,
                    height: Metrics.cornerGrabRadius * 2
                ),
                cursor: .crosshair
            )
        }
        addCursorRect(bounds, cursor: .openHand)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        // 只绘制镜头取景区；四周留边与底部条带（工具条区）保持透明。
        let lens = lensBounds
        let contentPath = NSBezierPath(rect: lens)

        NSGraphicsContext.saveGraphicsState()
        contentPath.addClip()

        if let latestSource {
            // 源图像是「镜头中心下方的屏幕区域」，绘制时直接铺满取景区。
            if let context = NSGraphicsContext.current?.cgContext {
                context.interpolationQuality = .high
                context.draw(latestSource, in: lens)
            }
        } else {
            NSColor.black.withAlphaComponent(0.55).setFill()
            lens.fill()
            let text: String = captureFailed
                ? "需要屏幕录制权限\n才能显示放大内容"
                : "加载中…"
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            (text as NSString).draw(
                in: lens.insetBy(dx: 8, dy: 8),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: paragraph
                ]
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        // 边框：深色 2pt 直角边框——借鉴截图选区的结构（直角、不圆角），
        // 配色保持放大镜自身的深色系，与工具条胶囊同一族观感。
        NSColor.black.withAlphaComponent(0.80).setStroke()
        let border = NSBezierPath(rect: lens)
        border.lineWidth = 2
        border.stroke()

        // 四角点：深色实心圆（半径 8，比截图选区略小）+ 浅色细环保证任意
        // 深浅画面上都可辨；圆心在镜头角点上，四周留边保证圆点完整可见。
        for corner in lensCorners {
            let dotRect = NSRect(
                x: corner.x - Metrics.dotRadius,
                y: corner.y - Metrics.dotRadius,
                width: Metrics.dotRadius * 2,
                height: Metrics.dotRadius * 2
            )
            NSColor.black.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            NSColor.white.withAlphaComponent(0.60).setStroke()
            let ring = NSBezierPath(ovalIn: dotRect)
            ring.lineWidth = 1
            ring.stroke()
        }
    }
}

// MARK: - 计时器（正计时 + 倒计时）

/// 正计时显示格式：分:秒:厘秒（厘秒 = 百分之一秒，两位），上限 99:59:99
/// （超过封顶显示，内部计时不受影响）。
private func formatStopwatch(_ interval: TimeInterval) -> String {
    let cs = min(Int((interval * 100).rounded(.up)), 99 * 6000 + 59 * 100 + 99)
    return String(format: "%02d:%02d:%02d", cs / 6000, (cs / 100) % 60, cs % 100)
}

/// 倒计时显示格式：时:分:秒，上限 99:59:59（滚轮最大可选值一致）。
private func formatCountdown(_ interval: TimeInterval) -> String {
    let total = min(Int(interval.rounded(.up)), 99 * 3600 + 59 * 60 + 59)
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}

/// 放映计时器：正计时（可插旗记录间隔）/ 倒计时（快捷时长 + 滚轮选时长 +
/// 开始/停止）。工具层窗口，观感如普通窗口（深色实底卡片 + 发丝描边）；
/// 再点「计时器」收起后计时继续走，重新打开看到的是持续中的当前值。
/// 四角为隐形拖拽改大小把手（不绘制视觉点），内部布局随窗口尺寸自动缩放。
/// 插旗记录在计时器窗口**右侧**单列小窗显示（独立窗口，不挤占计时器布局）。
@MainActor
final class SlideshowTimerWindow: NSPanel {
    /// 用户点关闭按钮时回调（供控制器记录日志）。
    var onClose: (() -> Void)?

    private let surface: SlideshowTimerSurfaceView
    /// 插旗记录侧窗（右侧单列；无记录时隐藏，不改变计时器自身布局）。
    private let lapPanel = SlideshowTimerLapPanel()

    init() {
        let size = NSSize(width: 320, height: 232)
        surface = SlideshowTimerSurfaceView()
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        level = SlideshowFloatingLevel.tool
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        surface.frame = NSRect(origin: .zero, size: size)
        surface.autoresizingMask = [.width, .height]
        contentView = surface
        surface.onBeginDrag = { [weak self] in
            self?.beginDragFromSurface()
        }
        surface.onDragTo = { [weak self] delta in
            self?.moveWindow(by: delta)
        }
        surface.onLapsChanged = { [weak self] laps in
            self?.syncLapPanel(laps)
        }
        // 四角缩放改变了主窗 frame：插旗侧窗位置需要跟着重排。
        surface.onFrameChanged = { [weak self] in
            self?.positionLapPanel()
        }
        // 关闭按钮：仅隐藏窗口，计时/插旗/模式状态全部保留，可再次呼出续看。
        surface.onClose = { [weak self] in
            guard let self else { return }
            self.onClose?()
            self.orderOut(nil)
            self.lapPanel.orderOut(nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(centeredIn screenFrame: NSRect) {
        show(in: NSRect(
            x: screenFrame.midX - frame.width / 2,
            y: screenFrame.midY - frame.height / 2 + 40,
            width: frame.width,
            height: frame.height
        ))
    }

    /// 按给定 frame 显示。
    func show(in frame: NSRect) {
        setFrame(frame, display: true)
        orderFrontRegardless()
        positionLapPanel()
    }

    /// 收尾清理（放映结束 / 功能关闭）：停止内部计时并复位为初始状态。
    /// 与普通隐藏不同——普通隐藏（再次点「计时器」收起）计时继续走，
    /// 会话结束不应残留后台计时器。
    func shutdown() {
        surface.resetForShutdown()
        orderOut(nil)
        lapPanel.orderOut(nil)
    }

    /// 拖动起点（surface 每次回调的是自按下起的累计位移；固定以按下时的
    /// 窗口原点为基线再加位移，避免在已移过的原点上重复累加造成漂移加速）。
    private var dragStartFrameOrigin: NSPoint?

    private func beginDragFromSurface() {
        dragStartFrameOrigin = frame.origin
    }

    private func moveWindow(by delta: NSPoint) {
        guard let origin = dragStartFrameOrigin else { return }
        setFrameOrigin(NSPoint(x: origin.x + delta.x, y: origin.y + delta.y))
        positionLapPanel()
    }

    // MARK: 插旗侧窗（右侧单列）

    private func syncLapPanel(_ laps: [TimeInterval]) {
        guard !laps.isEmpty else {
            lapPanel.orderOut(nil)
            return
        }
        lapPanel.setLaps(laps)
        positionLapPanel()
        lapPanel.orderFrontRegardless()
    }

    /// 插旗侧窗贴主窗右侧居中；右侧屏幕放不下时翻到左侧；均夹在屏内。
    private func positionLapPanel() {
        guard lapPanel.contentlapsCount > 0, isVisible else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let height = min(max(frame.height * 0.85, 120), 260)
        let width = SlideshowTimerLapPanel.Metrics.width
        let x: CGFloat
        if frame.maxX + 10 + width <= visible.maxX - 8 {
            x = frame.maxX + 10
        } else if frame.minX - 10 - width >= visible.minX + 8 {
            x = frame.minX - 10 - width
        } else {
            x = min(max(frame.maxX + 10, visible.minX + 8), visible.maxX - width - 8)
        }
        let y = min(
            max(frame.midY - height / 2, visible.minY + 8),
            visible.maxY - height - 8
        )
        lapPanel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

/// 计时器表面：深色实底卡片（普通窗口观感），全部自绘控件，布局随窗口尺寸
/// 自动缩放（窗口越大字号/按钮越大）。
///
/// 布局（isFlipped）：顶部居中「正计时 | 倒计时」二分切换（默认正计时）→
/// - 正计时：时间大字 + 底部按钮行 插旗(左) + 播放/暂停(中, 主按钮) + 重置(右)；
/// - 倒计时未计时：**滚轮选择器**（时/分/秒三列，上下拖动选时长，类 iOS 闹钟，底部单位汉字行）
///   + 底部按钮行：开始主按钮两侧各两枚快捷时长圆圈（左 1'/3'，右 5'/10'，仅未计时显示）；
/// - 倒计时进行中/暂停：时间大字 + 暂停/继续主按钮（中）+ 重置(右，终止回滚轮)。
///   报数音效与最后 5 秒**逐秒同步**：暂停 pause 保位、继续 play 续播（不从头重播）、
///   重置/切模式终止、自然到点播完收尾。
/// 插旗记录不在此布局内——由窗口层的右侧单列独立小窗承载（onLapsChanged）。
/// 右上角关闭按钮：仅隐藏窗口（计时状态保留）。左上角为音效图标开关。
/// 四角为隐形改大小圆点热点（圆心在窗口角点，覆盖视觉圆角裁掉的弧外区域）。
@MainActor
private final class SlideshowTimerSurfaceView: NSView {
    /// 背景拖动协议：onBeginDrag 在按下时触发（一次），onDragTo 持续增量回调。
    var onBeginDrag: (() -> Void)?
    var onDragTo: ((NSPoint) -> Void)?
    /// 关闭按钮点击回调（窗口据此仅隐藏自身）。
    var onClose: (() -> Void)?
    /// 插旗记录变化（新增/清空/模式切换/复位）——窗口层同步右侧单列小窗。
    /// 每条记录 = 插旗时刻的累计时长（分:秒:厘秒展示）。
    var onLapsChanged: (([TimeInterval]) -> Void)?
    /// 四角缩放后窗口 frame 变化——窗口层重排右侧小窗位置。
    var onFrameChanged: (() -> Void)?

    private enum Mode { case stopwatch, countdown }

    private enum Metrics {
        static let cornerRadius: CGFloat = 22
        static let inset: CGFloat = 14
        /// 最小窗口尺寸（四角缩放下限）。
        static let minWindowSize = NSSize(width: 260, height: 200)
        /// 基准设计尺寸：自动缩放系数以它为参照。
        static let baseSize = NSSize(width: 320, height: 232)
        static let modePillSize = NSSize(width: 150, height: 30)
        static let buttonRowHeight: CGFloat = 46
        static let primaryButtonDiameter: CGFloat = 46
        static let sideButtonDiameter: CGFloat = 36
        /// 四角隐形圆点热点半径（圆心在窗口角点，不可见仅命中）。边缘只做
        /// 视觉圆角裁剪、命中不裁——圆点覆盖弧外区域，从真正的角点即可抓取缩放。
        static let resizeHandleRadius: CGFloat = 20
        /// 倒计时滚轮选择器基准尺寸（宽度给足 "00:00:00" 时钟串视幅）。
        static let wheelWidth: CGFloat = 240
        static let wheelHeight: CGFloat = 160
        /// 倒计时默认时长（3 分钟）。
        static let countdownDefault: TimeInterval = 3 * 60
        /// 倒计时时长下限（5 秒）。
        static let countdownMinimum: TimeInterval = 5
    }

    private enum DragMode {
        case none
        case move            // 背景（非控件区）拖动窗口
        case resize(Corner)
    }

    private typealias Corner = SlideshowCornerResize.Corner

    private let modePill = SlideshowTimerModePill()
    private let timeLabel = NSTextField(labelWithString: "00:00:00")
    /// 正计时时间大字下方的单位行（分/秒/厘），仅正计时模式显示。
    private let stopwatchUnitLabels = SlideshowTimerUnitLabelsView()
    private let flagButton = SlideshowTimerIconButton(symbolName: "flag", accessibilityLabel: "插旗记录")
    private let playButton = SlideshowTimerIconButton(symbolName: "play.fill", accessibilityLabel: "开始/暂停", emphasized: true)
    private let resetButton = SlideshowTimerIconButton(symbolName: "arrow.counterclockwise", accessibilityLabel: "重置")
    private let closeButton = SlideshowTimerIconButton(symbolName: "xmark", accessibilityLabel: "关闭")
    /// 音效开关：左上角小图标按钮（开=喇叭有声、关=喇叭斜杠），替代旧勾选框。
    private let soundButton = SlideshowTimerIconButton(symbolName: "speaker.wave.2.fill", accessibilityLabel: "音效开关")
    /// 倒计时时长滚轮选择器（时/分/秒三列，上下拖动选时长；类 iOS 闹钟，最大 99:59:59）。
    private let wheelPicker = SlideshowTimerWheelPicker()
    /// 倒计时快捷时长圆圈按钮：开始按钮左侧 1'/3'、右侧 5'/10'（仅未计时显示）。
    private let presetButtons: [SlideshowTimerPresetCircleButton] = [
        SlideshowTimerPresetCircleButton(title: "1'", value: 60),
        SlideshowTimerPresetCircleButton(title: "3'", value: 3 * 60),
        SlideshowTimerPresetCircleButton(title: "5'", value: 5 * 60),
        SlideshowTimerPresetCircleButton(title: "10'", value: 10 * 60),
    ]

    // 交互状态
    private var dragMode: DragMode = .none
    private var dragStartMouse: NSPoint?
    private var dragStartFrame: NSRect?

    // 计时状态
    // mode/running/countdownPaused 是 layout() 的布局输入（滚轮 vs 大字时间、
    // 预设圆圈/插旗/重置按钮显隐与摆放、字号公式两套），变化必须置 needsLayout
    // 触发重排；赋值只发生在用户操作路径（非 33ms tick），无重排开销问题。
    private var mode: Mode = .stopwatch {
        didSet { needsLayout = true }
    }
    private var accumulated: TimeInterval = 0        // 正计时已累计（暂停含）
    private var running = false {
        didSet { needsLayout = true }
    }
    private var runStartedAt: Date?
    /// 插旗记录（按时间顺序）：插旗时刻的累计时长。
    private var laps: [TimeInterval] = []
    private var countdownTotal = Metrics.countdownDefault
    private var countdownLeft = Metrics.countdownDefault
    private var countdownFinished = false
    /// 剩 5 秒整播报是否已触发（一次倒计时只播一次）。
    private var countdownFiveAnnounced = false
    /// 倒计时暂停态：主按钮进行中为「暂停」、暂停后为「继续」——暂停冻结
    /// 剩余时长（区别于重置回滚轮），与正计时的暂停语义对齐。
    private var countdownPaused = false {
        didSet { needsLayout = true }
    }
    /// 报数音效是否随暂停挂起：报数与最后 5 秒逐秒同步，暂停时 pause 保位、
    /// 继续时 play 续播（暂停期间剩余时长同样冻结，续播天然对齐不重头）。
    private var announcementSuspended = false
    private var tickTimer: Timer?

    // 音效（开始提示 / 倒计时剩 5 秒报数，懒加载自 Bundle 资源；始终播放，
    // 音量由「音效」开关控制——静音即 volume=0，播放中切换也生效）
    private var startPlayer: AVAudioPlayer?
    private var countdownPlayer: AVAudioPlayer?

    // 音量开关状态（true=有声 / false=静音；设定随退出放映复位为开）。
    private var soundEnabled = true

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // 注意：不要在这里设 layer cornerRadius + masksToBounds——layer 裁剪
        // 会把 draw 里铺的整窗微量填充（保住 WindowServer 弧外命中的关键）
        // 在弧外一并裁掉，角部圆点热点就收不到事件了；视觉圆角由 draw
        // 自绘的圆角路径给出，子视图控件均在卡片区内无需裁剪。

        modePill.onSelect = { [weak self] index in
            self?.modeChanged(selectedIndex: index)
        }
        for button in presetButtons {
            button.onClick = { [weak self] seconds in
                self?.presetSelected(seconds)
            }
        }
        flagButton.onClick = { [weak self] in self?.flagTapped() }
        playButton.onClick = { [weak self] in self?.primaryTapped() }
        resetButton.onClick = { [weak self] in self?.resetTapped() }
        closeButton.onClick = { [weak self] in self?.onClose?() }
        soundButton.onClick = { [weak self] in self?.soundTapped() }
        wheelPicker.onValueChanged = { [weak self] hours, minutes, seconds in
            self?.wheelValueChanged(hours: hours, minutes: minutes, seconds: seconds)
        }
        flagButton.isEnabled = false

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 44, weight: .semibold)
        timeLabel.textColor = .white

        addSubview(modePill)
        addSubview(timeLabel)
        addSubview(stopwatchUnitLabels)
        addSubview(wheelPicker)
        for button in presetButtons {
            addSubview(button)
        }
        addSubview(flagButton)
        addSubview(playButton)
        addSubview(resetButton)
        addSubview(closeButton)
        addSubview(soundButton)

        wheelPicker.setValues(
            hours: Int(Metrics.countdownDefault) / 3600,
            minutes: Int(Metrics.countdownDefault) % 3600 / 60,
            seconds: Int(Metrics.countdownDefault) % 60
        )
        updateTimeLabel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// 自动缩放系数：随窗口尺寸相对基准设计尺寸缩放（限制在合理区间）。
    private var scale: CGFloat {
        let raw = min(bounds.width / Metrics.baseSize.width, bounds.height / Metrics.baseSize.height)
        return min(max(raw, 0.8), 2.4)
    }

    // MARK: 布局（随窗口尺寸自动缩放）

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let s = scale
        let width = bounds.width
        let height = bounds.height

        // 顶部行：音效开关（左）· 模式胶囊（中）· 关闭（右）。
        // 两侧按钮直径 = 模式胶囊高度，三个控件同一行等高对齐。
        let topButtonD = Metrics.modePillSize.height * s
        let topRowHeight = topButtonD
        soundButton.frame = NSRect(
            x: Metrics.inset * s,
            y: Metrics.inset * s + (topRowHeight - topButtonD) / 2,
            width: topButtonD,
            height: topButtonD
        )
        closeButton.frame = NSRect(
            x: width - Metrics.inset * s - topButtonD,
            y: Metrics.inset * s + (topRowHeight - topButtonD) / 2,
            width: topButtonD,
            height: topButtonD
        )
        modePill.frame = NSRect(
            x: (width - Metrics.modePillSize.width * s) / 2,
            y: Metrics.inset * s,
            width: Metrics.modePillSize.width * s,
            height: topRowHeight
        )

        // 快捷时长圆圈按钮：仅倒计时**未启动**时显示（进行中/暂停隐藏）。
        let presetVisible = mode == .countdown && !running && !countdownPaused
        for button in presetButtons {
            button.isHidden = !presetVisible
        }

        let contentTop = modePill.frame.maxY + 8 * s
        let bottomRowY = height - Metrics.inset * s - Metrics.buttonRowHeight * s

        // 底部按钮行：主按钮居中；正计时左右各一枚（插旗/重置），
        // 倒计时未计时时两侧各两枚快捷时长圆圈（左 1'/3'，右 5'/10'）。
        let primaryD = Metrics.primaryButtonDiameter * s
        let mainCenterX = width / 2
        playButton.frame = NSRect(
            x: mainCenterX - primaryD / 2,
            y: bottomRowY + (Metrics.buttonRowHeight * s - primaryD) / 2,
            width: primaryD,
            height: primaryD
        )
        let stopwatch = mode == .stopwatch
        flagButton.isHidden = !stopwatch
        // 重置按钮：正计时常显；倒计时仅进行中/暂停时显示（终止回滚轮）。
        let countdownActive = mode == .countdown && (running || countdownPaused)
        resetButton.isHidden = !stopwatch && !countdownActive
        let presetD = Metrics.sideButtonDiameter * s
        let presetGap: CGFloat = 12 * s
        let presetY = bottomRowY + (Metrics.buttonRowHeight * s - presetD) / 2
        if stopwatch {
            let sideD = Metrics.sideButtonDiameter * s
            let gap: CGFloat = 20 * s
            let sideY = bottomRowY + (Metrics.buttonRowHeight * s - sideD) / 2
            flagButton.frame = NSRect(x: mainCenterX - primaryD / 2 - gap - sideD, y: sideY, width: sideD, height: sideD)
            resetButton.frame = NSRect(x: mainCenterX + primaryD / 2 + gap, y: sideY, width: sideD, height: sideD)
        } else if countdownActive {
            // 倒计时进行中/暂停：主按钮右侧一枚重置（终止回滚轮），左侧留空。
            let sideD = Metrics.sideButtonDiameter * s
            let gap: CGFloat = 20 * s
            let sideY = bottomRowY + (Metrics.buttonRowHeight * s - sideD) / 2
            resetButton.frame = NSRect(x: mainCenterX + primaryD / 2 + gap, y: sideY, width: sideD, height: sideD)
        } else if presetVisible {
            // 左侧 [1'][3']（3' 靠主按钮）、右侧 [5'][10']（5' 靠主按钮）。
            let leftInner = mainCenterX - primaryD / 2 - presetGap - presetD
            presetButtons[1].frame = NSRect(x: leftInner, y: presetY, width: presetD, height: presetD)
            presetButtons[0].frame = NSRect(x: leftInner - presetGap - presetD, y: presetY, width: presetD, height: presetD)
            let rightInner = mainCenterX + primaryD / 2 + presetGap
            presetButtons[2].frame = NSRect(x: rightInner, y: presetY, width: presetD, height: presetD)
            presetButtons[3].frame = NSRect(x: rightInner + presetGap + presetD, y: presetY, width: presetD, height: presetD)
        }

        // 中部时间区：在顶部内容与按钮行之间居中。
        // 倒计时未计时 → 滚轮选择器（时/分/秒三列拖动选时长）；
        // 其余（正计时全程、倒计时计时中/暂停/到点）→ 时间大字。
        let timeAreaBottom = bottomRowY - 4 * s
        let availableHeight = max(30, timeAreaBottom - contentTop)
        let wheelVisible = mode == .countdown && !running && !countdownPaused
        wheelPicker.isHidden = !wheelVisible
        timeLabel.isHidden = wheelVisible
        stopwatchUnitLabels.isHidden = wheelVisible
        if wheelVisible {
            let wheelHeight = min(availableHeight, Metrics.wheelHeight * s)
            let wheelWidth = min(width - Metrics.inset * s * 2, Metrics.wheelWidth * s)
            wheelPicker.frame = NSRect(
                x: (width - wheelWidth) / 2,
                y: contentTop + (availableHeight - wheelHeight) / 2,
                width: wheelWidth,
                height: wheelHeight
            )
        } else {
            // 正计时时下方还要放一行单位汉字（分/秒/厘），字体系数相应收紧；
            // 倒计时（时:分:秒）不显示单位行。
            // 字号两步走：先按可用高度给初始值，再 sizeToFit 实测文本宽度、
            // 超出可用宽度时按比例回压——只按高度放大的旧公式在「宽小高大」
            // 窗口下会让等宽 8 字符文本左右溢出窗口被裁切。
            let showUnits = stopwatch
            stopwatchUnitLabels.isHidden = !showUnits
            let maxWidth = width - Metrics.inset * s * 2
            var fontSize = max(
                18 * s,
                min(availableHeight * (showUnits ? 0.5 : 0.62), 52 * s)
            )
            timeLabel.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
            timeLabel.sizeToFit()
            let measuredWidth = timeLabel.frame.width
            if measuredWidth > maxWidth, measuredWidth > 0 {
                fontSize = max(12, fontSize * maxWidth / measuredWidth)
                timeLabel.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
                timeLabel.sizeToFit()
            }
            let timeSize = timeLabel.frame.size
            let unitLabelsHeight: CGFloat = showUnits ? 13 * s : 0
            let blockHeight = timeSize.height + (showUnits ? 2 * s : 0) + unitLabelsHeight
            let blockTop = contentTop + max(0, (availableHeight - blockHeight) / 2)
            timeLabel.frame = NSRect(
                x: mainCenterX - timeSize.width / 2,
                y: blockTop,
                width: timeSize.width,
                height: timeSize.height
            )
            if showUnits, let unitReferenceFont = timeLabel.font {
                stopwatchUnitLabels.units = ["分", "秒", "厘"]
                stopwatchUnitLabels.referenceFont = unitReferenceFont
                stopwatchUnitLabels.frame = NSRect(
                    x: timeLabel.frame.minX,
                    y: timeLabel.frame.maxY + 2 * s,
                    width: timeSize.width,
                    height: unitLabelsHeight
                )
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 先给整个窗口矩形铺一层隐形微量填充：非不透明无边框窗口的弧外
        // 全透明像素会被 WindowServer 判为「不属于本窗口」直接穿透，角部
        // 圆点热点收不到事件。1/255 是 8-bit 缓冲的最小非零 alpha——物理上
        // 仅一个色阶、肉眼不可见，但仍满足「非零 alpha 即命中」。
        NSColor.black.withAlphaComponent(1.0 / 255.0).setFill()
        bounds.fill()

        // 普通窗口观感：深色实底 + 一圈发丝描边（无角点把手视觉）。
        let path = NSBezierPath(
            roundedRect: bounds,
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        )
        NSColor.black.withAlphaComponent(0.82).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        let hairline = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        )
        hairline.lineWidth = 1
        hairline.stroke()
    }

    // MARK: 命中分发（控件交给子视图，其余区域归自己）

    override func hitTest(_ point: NSPoint) -> NSView? {
        // hitTest 的 point 在 superview 坐标系，先转本地（from: nil 语义是
        // 窗口基坐标，仅当本视图恰为 contentView 时才与 superview 等价）。
        // 注意：closeButton / soundButton 必须在列表内，否则点击会落到
        // 背景（返回 self）被当成拖动窗口——关闭按钮失效的根因。
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let interactive: [NSView] = [modePill, wheelPicker, flagButton, playButton, resetButton, soundButton, closeButton] + presetButtons
        for view in interactive where !view.isHidden && view.frame.contains(local) {
            return view
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let corner = resizeCorner(at: point) {
            dragMode = .resize(corner)
            dragStartMouse = NSEvent.mouseLocation
            dragStartFrame = window?.frame
            return
        }
        // 其余背景区域：拖动窗口。
        dragMode = .move
        dragStartMouse = NSEvent.mouseLocation
        onBeginDrag?()
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        switch dragMode {
        case .none:
            break
        case .move:
            guard let start = dragStartMouse else { return }
            onDragTo?(NSPoint(x: current.x - start.x, y: current.y - start.y))
        case .resize(let corner):
            guard let startMouse = dragStartMouse, let startFrame = dragStartFrame, let window else { return }
            applyResize(corner: corner, dx: current.x - startMouse.x, dy: current.y - startMouse.y, window: window, startFrame: startFrame)
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = .none
        dragStartMouse = nil
        dragStartFrame = nil
    }

    override func resetCursorRects() {
        // 隐形圆点热点只保留命中区与抓手光标提示（光标矩形取圆点在窗口内
        // 的角象限包围方框）。
        for corner in Corner.allCases {
            addCursorRect(
                SlideshowCornerResize.cursorRect(
                    for: corner, in: bounds, handleRadius: Metrics.resizeHandleRadius
                ),
                cursor: .closedHand
            )
        }
    }

    /// 对角固定的缩放：拖动某角只改变该角方向，保持对角点不动。
    private func applyResize(corner: Corner, dx: CGFloat, dy: CGFloat, window: NSWindow, startFrame: NSRect) {
        let frame = SlideshowCornerResize.resizedFrame(
            startFrame: startFrame, dx: dx, dy: dy,
            minSize: Metrics.minWindowSize,
            corner: corner
        )
        window.setFrame(frame, display: true)
        // 主窗 frame 变了：通知窗口层重排右侧插旗小窗。
        onFrameChanged?()
    }

    private func resizeCorner(at point: NSPoint) -> Corner? {
        SlideshowCornerResize.corner(at: point, in: bounds, handleRadius: Metrics.resizeHandleRadius)
    }

    // MARK: 计时逻辑

    /// 收尾复位：停止计时/音效并回到初始显示（正计时 00:00），供窗口 shutdown 调用。
    /// 音效设定随退出放映清空——这里复位为默认开启。
    func resetForShutdown() {
        running = false
        countdownPaused = false
        announcementSuspended = false
        stopTicking()
        stopSounds()
        accumulated = 0
        laps = []
        onLapsChanged?(laps)
        countdownTotal = Metrics.countdownDefault
        countdownLeft = countdownTotal
        countdownFinished = false
        countdownFiveAnnounced = false
        soundEnabled = true
        soundButton.symbolName = "speaker.wave.2.fill"
        modePill.selectedIndex = 0
        mode = .stopwatch
        playButton.symbolName = "play.fill"
        flagButton.isEnabled = false
        wheelPicker.setValues(
            hours: Int(Metrics.countdownDefault) / 3600,
            minutes: Int(Metrics.countdownDefault) % 3600 / 60,
            seconds: Int(Metrics.countdownDefault) % 60
        )
        updateTimeLabel()
    }

    private func modeChanged(selectedIndex: Int) {
        let newMode: Mode = selectedIndex == 0 ? .stopwatch : .countdown
        guard mode != newMode else { return }
        mode = newMode
        running = false
        countdownPaused = false
        announcementSuspended = false
        stopTicking()
        stopSounds()
        accumulated = 0
        if !laps.isEmpty {
            laps = []
            onLapsChanged?(laps)
        }
        countdownFinished = false
        countdownLeft = countdownTotal
        countdownFiveAnnounced = countdownTotal <= 5
        playButton.symbolName = "play.fill"
        flagButton.isEnabled = false
        updateTimeLabel()
    }

    /// 快捷时长点按：无选中态，仅非计时时改写倒计时数字（下限 5 秒），
    /// 滚轮选择器同步到所选时长。
    private func presetSelected(_ seconds: TimeInterval) {
        guard mode == .countdown, !running else { return }
        countdownFinished = false
        countdownTotal = max(seconds, Metrics.countdownMinimum)
        countdownLeft = countdownTotal
        countdownFiveAnnounced = countdownTotal <= 5
        playButton.symbolName = "play.fill"
        wheelPicker.setValues(
            hours: Int(countdownTotal) / 3600,
            minutes: Int(countdownTotal) % 3600 / 60,
            seconds: Int(countdownTotal) % 60
        )
        updateTimeLabel()
    }

    /// 滚轮选完时长（吸附后回调）：写回倒计时总时长（下限 5 秒）。
    /// 时/分/秒三列 → 总秒数；上限 99:59:59 由滚轮列值域保证。
    private func wheelValueChanged(hours: Int, minutes: Int, seconds: Int) {
        guard mode == .countdown, !running else { return }
        countdownFinished = false
        countdownTotal = max(TimeInterval(hours * 3600 + minutes * 60 + seconds), Metrics.countdownMinimum)
        countdownLeft = countdownTotal
        countdownFiveAnnounced = countdownTotal <= 5
        playButton.symbolName = "play.fill"
        updateTimeLabel()
    }

    private func primaryTapped() {
        if mode == .stopwatch {
            toggleStopwatch()
        } else {
            toggleCountdown()
        }
    }

    private func toggleStopwatch() {
        if running {
            accumulated += Date().timeIntervalSince(runStartedAt ?? Date())
            running = false
            stopTicking()
            stopSounds()
            playButton.symbolName = "play.fill"
            flagButton.isEnabled = false
        } else {
            runStartedAt = Date()
            running = true
            startTicking()
            playStartSound()
            playButton.symbolName = "pause.fill"
            flagButton.isEnabled = true
        }
        updateTimeLabel()
    }

    private func toggleCountdown() {
        if running {
            // 暂停：冻结剩余时长；报数音效同步 pause 保位（暂停期间两者
            // 一起冻结，不会错位），开始提示音与本时间线无关直接停掉。
            running = false
            countdownPaused = true
            stopTicking()
            startPlayer?.stop()
            if countdownPlayer?.isPlaying == true {
                countdownPlayer?.pause()
                announcementSuspended = true
            }
            playButton.symbolName = "play.fill"
        } else if countdownPaused {
            // 继续：剩余时长与报数音效都从挂起位置续走——剩 3 秒就续播
            // 报数的后 3 秒，绝不从头重播「5」。
            countdownPaused = false
            runStartedAt = Date()
            running = true
            startTicking()
            if announcementSuspended {
                announcementSuspended = false
                countdownPlayer?.play()
            }
            playButton.symbolName = "pause.fill"
        } else {
            // 全新启动（含到点后重开）：回到所选时长重新计时。
            countdownFinished = false
            countdownPaused = false
            announcementSuspended = false
            countdownLeft = countdownTotal
            // 开始提示音始终播放（掐掉上一轮残留）。总时长 ≤5 秒时报数
            // 音效本身就是完整时间线（前 5 秒逐秒同步 + 结尾到点提醒音），
            // 随启动立即从头播（与开始提示音同响，两者都要）并标记已武装；
            // >5 秒时由 tick 在剩 5 秒整触发报数。
            playStartSound()
            if countdownTotal <= 5 {
                countdownFiveAnnounced = true
                playCountdownSound()
            } else {
                countdownFiveAnnounced = false
            }
            runStartedAt = Date()
            running = true
            startTicking()
            playButton.symbolName = "pause.fill"
        }
        updateTimeLabel()
    }

    /// 插旗：记录插旗时刻的累计时长（分:秒:厘秒展示）；仅正计时运行中可用。
    private func flagTapped() {
        guard mode == .stopwatch, running else { return }
        let elapsed = accumulated + Date().timeIntervalSince(runStartedAt ?? Date())
        laps.append(elapsed)
        onLapsChanged?(laps)
    }

    private func resetTapped() {
        if mode == .stopwatch {
            running = false
            stopTicking()
            stopSounds()
            accumulated = 0
            if !laps.isEmpty {
                laps = []
                onLapsChanged?(laps)
            }
            playButton.symbolName = "play.fill"
            flagButton.isEnabled = false
        } else {
            // 倒计时重置：终止计时（进行中/暂停均可）回到滚轮重选时长。
            running = false
            countdownPaused = false
            announcementSuspended = false
            countdownFinished = false
            countdownFiveAnnounced = false
            stopTicking()
            stopSounds()
            countdownLeft = countdownTotal
            playButton.symbolName = "play.fill"
        }
        updateTimeLabel()
    }

    private func startTicking() {
        stopTicking()
        // 0.03s（约 33fps）：正计时展示厘秒（百分位）， tick 间隔必须明显
        // 小于 10ms×100 量级的显示粒度，否则厘秒跳变会显得迟滞。
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard running, let start = runStartedAt else { return }
        let elapsed = Date().timeIntervalSince(start)
        if mode == .stopwatch {
            updateTimeLabel()
        } else {
            countdownLeft = max(0, countdownLeft - elapsed)
            runStartedAt = Date()
            // 剩 5 秒整：立即播 5 秒倒计时报数音效（一次）。
            if !countdownFiveAnnounced, countdownLeft <= 5 {
                countdownFiveAnnounced = true
                playCountdownSound()
            }
            if countdownLeft <= 0 {
                running = false
                stopTicking()
                countdownFinished = true
                playButton.symbolName = "play.fill"
                updateTimeLabel()
            } else {
                updateTimeLabel()
            }
        }
    }

    // MARK: 显示

    private func updateTimeLabel() {
        let shown: TimeInterval
        if mode == .stopwatch {
            shown = accumulated + (running ? Date().timeIntervalSince(runStartedAt ?? Date()) : 0)
        } else {
            shown = countdownLeft
        }
        timeLabel.stringValue = mode == .stopwatch ? formatStopwatch(shown) : formatCountdown(shown)
        if countdownFinished || (mode == .countdown && countdownLeft > 0 && countdownLeft <= 5) {
            // 倒计时最后 5 秒（5·4·3·2·1，含暂停挂起时）与到点后：稳定红字。
            timeLabel.textColor = .systemRed
        } else {
            timeLabel.textColor = .white
        }
        // 仅更新文本/颜色触发重绘即可；每 33ms 的 tick 置 needsLayout 会让
        // layout() 以 30fps 全量重排（含字体创建与两次 sizeToFit），纯浪费。
    }

    // MARK: 音效

    private func soundPlayer(named name: String) -> AVAudioPlayer? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "m4a") else { return nil }
        return try? AVAudioPlayer(contentsOf: url)
    }

    /// 音效与 UI 生命周期对齐：暂停/停止/复位/切换模式时**立即中断**正在
    /// 播放的音效（stop 同时把播放头归零，下次 play 从头开始）。
    private func stopSounds() {
        startPlayer?.stop()
        countdownPlayer?.stop()
    }

    /// 音效开关：切换图标（有声喇叭 ↔ 静音喇叭）。音效**始终播放**，本开关
    /// 只控制音量（静音与否）——播放中点按切换也即时生效。
    private func soundTapped() {
        soundEnabled.toggle()
        let volume: Float = soundEnabled ? 1 : 0
        startPlayer?.volume = volume
        countdownPlayer?.volume = volume
        soundButton.symbolName = soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill"
    }

    private func playStartSound() {
        // 音效严格串行：新音效启动前先掐掉另一路（如上一轮倒计时到点报数
        // 的尾音）——任一时刻至多一路在响，与 UI 的单时间线一致。
        countdownPlayer?.stop()
        if startPlayer == nil {
            startPlayer = soundPlayer(named: "timer-start")
        }
        startPlayer?.volume = soundEnabled ? 1 : 0
        startPlayer?.currentTime = 0
        startPlayer?.play()
    }

    private func playCountdownSound() {
        // 不掐 startPlayer：≤5 秒启动时报数与开始提示音**同响**（用户要求
        // 两者都要）；5 秒整触发时开始音早已结束。上一轮报数残留由
        // playStartSound 统一掐掉。
        if countdownPlayer == nil {
            countdownPlayer = soundPlayer(named: "timer-countdown5")
        }
        countdownPlayer?.volume = soundEnabled ? 1 : 0
        countdownPlayer?.currentTime = 0
        countdownPlayer?.play()
    }
}

/// 计时器模式切换：两段二分（正计时 | 倒计时），默认正计时，选中段亮色高亮。
@MainActor
private final class SlideshowTimerModePill: NSView {
    var onSelect: ((Int) -> Void)?

    var selectedIndex = 0 {  // 默认正计时
        didSet { needsDisplay = true }
    }

    private let titles = ["正计时", "倒计时"]

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.white.withAlphaComponent(0.10).setFill()
        capsule.fill()

        // 选中段高亮胶囊。
        let segmentWidth = bounds.width / 2
        let selectedRect = NSRect(x: CGFloat(selectedIndex) * segmentWidth + 2, y: 2, width: segmentWidth - 4, height: bounds.height - 4)
        NSColor.white.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: selectedRect, xRadius: selectedRect.height / 2, yRadius: selectedRect.height / 2).fill()

        let fontSize = max(11, bounds.height * 0.42)
        for (index, title) in titles.enumerated() {
            let rect = NSRect(x: CGFloat(index) * segmentWidth, y: 0, width: segmentWidth, height: bounds.height)
            // 文本在段内垂直水平双居中：先实测行框尺寸再定位（draw(in:) 会把
            // 行框贴在矩形顶部，段内文字整体上移——错位的根因）。
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: index == selectedIndex
                    ? NSColor.white.withAlphaComponent(0.95)
                    : NSColor.white.withAlphaComponent(0.5),
            ]
            let size = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(
                at: NSPoint(x: rect.midX - size.width / 2, y: (rect.height - size.height) / 2),
                withAttributes: attrs
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = point.x < bounds.width / 2 ? 0 : 1
        guard index != selectedIndex else { return }
        selectedIndex = index
        onSelect?(index)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 倒计时快捷时长圆圈按钮：单枚圆形描边小按钮（如 1'），点按写回倒计时数字
/// （仅未计时时可见，回调由 surface 的 presetSelected 处理）。
/// 布局由 surface 安排——开始按钮左侧 1'/3'、右侧 5'/10' 各两枚。
@MainActor
private final class SlideshowTimerPresetCircleButton: NSView {
    /// 点按回调（携带该按钮的时长，单位秒）。
    var onClick: ((TimeInterval) -> Void)?

    private let title: String
    private let value: TimeInterval

    init(title: String, value: TimeInterval) {
        self.title = title
        self.value = value
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // 圆形底：与计时器控件同族的半透明圆 + 发丝描边。
        let inset = 0.5
        let circle = NSBezierPath(
            ovalIn: bounds.insetBy(dx: inset, dy: inset)
        )
        NSColor.white.withAlphaComponent(0.07).setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        // 文本圆内双居中（实测行框定位，不贴顶）。
        let fontSize = max(10, min(14, bounds.height * 0.38))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attrs
        )
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(value)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 插旗记录侧窗：贴计时器窗口右侧的单列独立小窗（borderless、与计时器同层）。
/// 行内容「编号 · 分:秒:厘秒」单列居中，行间细分隔线，滚轮上下滑动；
/// 新记录在底部并自动滚动到可见。
@MainActor
final class SlideshowTimerLapPanel: NSPanel {
    enum Metrics {
        static let width: CGFloat = 128
    }

    private let listView: SlideshowTimerLapListView

    init() {
        listView = SlideshowTimerLapListView()
        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Metrics.width, height: 180)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        level = SlideshowFloatingLevel.tool
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        listView.frame = NSRect(origin: .zero, size: NSSize(width: Metrics.width, height: 180))
        listView.autoresizingMask = [.width, .height]
        contentView = listView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 当前插旗条数（窗口层据此决定侧窗显隐）。
    var contentlapsCount: Int { listView.lapsCount }

    func setLaps(_ laps: [TimeInterval]) {
        listView.setLaps(laps)
    }
}

/// 插旗记录列表视图：深色实底卡片（与计时器表面同一观感），单列自绘行。
@MainActor
private final class SlideshowTimerLapListView: NSView {
    private var laps: [TimeInterval] = []
    /// 滚动偏移：0 = 顶对齐；向下滚动增大（内容上移）。
    private var scrollOffset: CGFloat = 0

    private enum Metrics {
        static let cornerRadius: CGFloat = 12
        static let padding: CGFloat = 6
    }

    override var isFlipped: Bool { true }

    var lapsCount: Int { laps.count }

    func setLaps(_ newLaps: [TimeInterval]) {
        laps = newLaps
        // 新记录自动滚到底部（最新一条可见）。
        scrollOffset = maxOffset()
        needsDisplay = true
    }

    private func rowHeight() -> CGFloat {
        min(max(bounds.height / 8, 22), 34)
    }

    private func contentHeight() -> CGFloat {
        Metrics.padding * 2 + CGFloat(laps.count) * rowHeight()
    }

    private func maxOffset() -> CGFloat {
        max(0, contentHeight() - bounds.height)
    }

    // MARK: 滚动（触摸板 / 鼠标滚轮 / 按住拖移平移）

    override func scrollWheel(with event: NSEvent) {
        guard !laps.isEmpty else { return }
        // 触摸板（精确滚动）：系统已按自然滚动方向换算 delta，取负 = 内容跟手
        // （指尖上滑 → 内容上移 → 看到后面的记录）。
        // 鼠标滚轮（非精确滚动）：scrollingDeltaY 不可用（为 0 或每格仅 ±1、
        // 体感滚不动），改用 deltaY（每格一格）×12 放大到合适体感；方向同样
        // 取负，与触摸板、系统自然滚动语义一致。
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.deltaY * 12
        guard delta != 0 else { return }
        scrollOffset = min(max(scrollOffset - delta, 0), maxOffset())
        needsDisplay = true
    }

    // 拖移平移（适配触摸习惯）：按住拖动，列表内容跟随光标移动。
    private var dragStartY: CGFloat?
    private var dragStartOffset: CGFloat = 0

    override func mouseDown(with event: NSEvent) {
        dragStartY = convert(event.locationInWindow, from: nil).y
        dragStartOffset = scrollOffset
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startY = dragStartY else { return }
        let y = convert(event.locationInWindow, from: nil).y
        // flipped 坐标：光标上移（y 减小）→ 内容上移 → offset 增加（跟手）。
        scrollOffset = min(max(dragStartOffset + (startY - y), 0), maxOffset())
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStartY = nil
    }

    override func resetCursorRects() {
        // 多于一条记录可滚动：抓手光标提示可拖移；其余常态箭头。
        addCursorRect(bounds, cursor: laps.count > 1 ? .openHand : .arrow)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 独立小窗：深色实底卡片 + 发丝描边（与计时器表面同一观感）。
        let base = NSBezierPath(roundedRect: bounds, xRadius: Metrics.cornerRadius, yRadius: Metrics.cornerRadius)
        NSColor.black.withAlphaComponent(0.82).setFill()
        base.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        base.lineWidth = 1
        base.stroke()

        let rowH = rowHeight()
        let offset = min(max(scrollOffset, 0), maxOffset())

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.cornerRadius, yRadius: Metrics.cornerRadius).addClip()

        for (index, lap) in laps.enumerated() {
            let rowY = Metrics.padding + CGFloat(index) * rowH - offset
            let rowRect = NSRect(x: 0, y: rowY, width: bounds.width, height: rowH)
            guard rowRect.maxY > 0, rowRect.minY < bounds.height else { continue }

            // 行内容「编号 · 分:秒:厘秒」（格式与正计时主显示共用 formatStopwatch，
            // 含 99:59:99 封顶）；单列居中（行内垂直居中，实测行框定位）。
            let fontSize = rowH * 0.42
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            ]
            let text = "\(index + 1) · \(formatStopwatch(lap))" as NSString
            let textSize = text.size(withAttributes: attrs)
            text.draw(
                at: NSPoint(
                    x: (rowRect.width - textSize.width) / 2,
                    y: rowRect.minY + (rowRect.height - textSize.height) / 2
                ),
                withAttributes: attrs
            )

            // 行间分隔线。
            if index < laps.count - 1 {
                NSColor.white.withAlphaComponent(0.10).setStroke()
                let line = NSBezierPath()
                line.lineWidth = 1
                line.move(to: NSPoint(x: 10, y: rowRect.maxY))
                line.line(to: NSPoint(x: bounds.width - 10, y: rowRect.maxY))
                line.stroke()
            }
        }

        NSGraphicsContext.restoreGraphicsState()
    }
}

/// 倒计时时长滚轮选择器：**对标正计时时钟**的「HH:MM:SS」大字样式——
/// 选中行白色 semibold 大字 + 两枚 `:` 冒号，上下相邻值按距离渐隐缩小；
/// 时/分/秒三组数字各自独立拖动滚动（按住某列上下拖，松手吸附最近整数）。
/// 列底部固定一条**单位汉字行**（时/分/秒），数字滚动区被裁剪在单位行
/// 之上——轮盘数字不会压到单位汉字，也不会压到底部的启动/暂停按钮。
/// 选中行字号按滚动区高度与整串实测宽度双约束（与时间大字同级视幅），
/// 不再整体等比缩小。最大可选 99 小时 59 分 59 秒；时与分均为 0 时秒列
/// 下限抬到 05。选中变化经 onValueChanged 回调（吸附后触发一次）。
@MainActor
private final class SlideshowTimerWheelPicker: NSView {
    var onValueChanged: ((_ hours: Int, _ minutes: Int, _ seconds: Int) -> Void)?

    private enum Metrics {
        /// 上下各绘制的行数（±2 行渐隐；空间不足时被滚动区自然裁剪）。
        static let visibleRows = 2
        /// 相邻行间距 = 选中字号 × 该系数（≈1 倍字高，行间留白清晰不挤压）。
        static let rowSpacingFraction: CGFloat = 0.95
        /// 相邻行字号 = 选中字号 × (minFontFraction + (1 − minFontFraction) × t)。
        /// 下限压低到 0.35：相邻行立刻明显小一号，选中/未选中对比强烈。
        static let minFontFraction: CGFloat = 0.35
        /// 选中行字号初值 = 滚动区高度 × 该系数（与宽度约束取小）。
        static let selectedFontHeightFraction: CGFloat = 0.40
        /// 选中行字号宽度约束 = 视图宽 ÷ 该系数（"00:00:00" ≈ 4.9 字宽）。
        static let clockStringWidthDivisor: CGFloat = 4.9
        /// 数字组与冒号的间距 = 选中字号 × 该系数。
        static let colonGapFraction: CGFloat = 0.10
        /// 小时列值域上限（最大 99 小时）。
        static let maxHours = 99
        /// 分钟列值域上限。
        static let maxMinutes = 59
        /// 秒钟列值域上限。
        static let maxSeconds = 59
        /// 时、分均为 0 时秒数列表下限：列表整体裁掉 00–04，从 05 起。
        static let minimumSeconds = 5
        /// 各列单位汉字。
        static let unitTitles = ["时", "分", "秒"]
    }

    /// 三列的连续值（拖动中为小数，松手吸附为整数）：[时, 分, 秒]。
    private var values: [Float] = [0, 3, 0]
    /// 拖动状态：正在滚动的列（0=时, 1=分, 2=秒）、起始 y 与起始值。
    private var activeColumn: Int?
    private var dragStartY: CGFloat = 0
    private var dragStartValue: Float = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// 数字滚动区（本视图顶部减去底部单位行）——行绘制与裁剪都以它为界。
    private var wheelRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - unitStripHeight))
    }

    private var unitStripHeight: CGFloat { max(14, min(20, bounds.height * 0.16)) }

    /// 选中行字号：先按滚动区高度 / 视图宽度给初值，再用整串 "00:00:00"
    /// 实测宽度回压——保证任何窗口尺寸下大字不溢出且视幅对标时间大字。
    private var selectedFontSize: CGFloat {
        let wheel = wheelRect
        var f = min(
            wheel.height * Metrics.selectedFontHeightFraction,
            bounds.width / Metrics.clockStringWidthDivisor
        )
        let measured = ("00:00:00" as NSString).size(
            withAttributes: Self.textAttributes(fontSize: f, alpha: 1, semibold: true)
        ).width
        let maxWidth = bounds.width * 0.96
        if measured > maxWidth, measured > 0 {
            f *= maxWidth / measured
        }
        return max(12, f)
    }

    /// 相邻行间距（拖动步进与行绘制共用）。
    private var rowSpacing: CGFloat { selectedFontSize * Metrics.rowSpacingFraction }

    private static func textAttributes(fontSize: CGFloat, alpha: CGFloat, semibold: Bool)
        -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: semibold ? .semibold : .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ]
    }

    /// 「HH:MM:SS」整体排版：三组两位数字 + 两枚冒号按选中字号计量，
    /// 返回各组数字中心 x 与各冒号中心 x（水平整体居中）。
    private func layout(for fontSize: CGFloat) -> (digitCenters: [CGFloat], colonCenters: [CGFloat]) {
        let attrs = Self.textAttributes(fontSize: fontSize, alpha: 1, semibold: true)
        let groupWidth = ("00" as NSString).size(withAttributes: attrs).width
        let colonWidth = (":" as NSString).size(withAttributes: attrs).width
        let gap = fontSize * Metrics.colonGapFraction
        let totalWidth = groupWidth * 3 + colonWidth * 2 + gap * 4
        var x = (bounds.width - totalWidth) / 2
        var digitCenters: [CGFloat] = []
        var colonCenters: [CGFloat] = []
        for column in 0..<3 {
            digitCenters.append(x + groupWidth / 2)
            x += groupWidth
            if column < 2 {
                x += gap
                colonCenters.append(x + colonWidth / 2)
                x += colonWidth + gap
            }
        }
        return (digitCenters, colonCenters)
    }

    /// 秒列下限：时、分均为 0（含拖动中间值）时列表裁掉 00–04，从 05 起。
    private var secondsLowerBound: Float {
        values[0] < 0.5 && values[1] < 0.5 ? Float(Metrics.minimumSeconds) : 0
    }

    /// 列值域钳制：时 0–99；分 0–59；秒 0–59，且时、分均为 0 时下限抬到 05。
    private func clamp(_ value: Float, column: Int) -> Float {
        switch column {
        case 0: return min(max(value, 0), Float(Metrics.maxHours))
        case 1: return min(max(value, 0), Float(Metrics.maxMinutes))
        default: return min(max(value, secondsLowerBound), Float(Metrics.maxSeconds))
        }
    }

    /// 外部写入选中值（快捷时长/复位时同步显示）。时、分均为 0 且秒低于下限
    /// 时自动回落到 05。
    func setValues(hours: Int, minutes: Int, seconds: Int) {
        let secondsFloor = (hours == 0 && minutes == 0) ? Metrics.minimumSeconds : 0
        values = [
            Float(min(max(hours, 0), Metrics.maxHours)),
            Float(min(max(minutes, 0), Metrics.maxMinutes)),
            Float(min(max(seconds, secondsFloor), Metrics.maxSeconds)),
        ]
        needsDisplay = true
    }

    // MARK: 拖动滚动

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 命中列 = 距哪组数字中心最近（按实际排版而非三分割）。
        let centers = layout(for: selectedFontSize).digitCenters
        var nearest = 0
        for column in 1...2 where abs(point.x - centers[column]) < abs(point.x - centers[nearest]) {
            nearest = column
        }
        activeColumn = nearest
        dragStartY = point.y
        dragStartValue = values[nearest]
    }

    override func mouseDragged(with event: NSEvent) {
        guard let column = activeColumn else { return }
        let point = convert(event.locationInWindow, from: nil)
        // 列表 00 在上、99 在下（同 iOS 闹钟）：手指上移列表上滚，
        // 更大的数字从下方滚入选中行 → 数值增大。
        let delta = (dragStartY - point.y) / rowSpacing
        values[column] = clamp(dragStartValue + Float(delta), column: column)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let column = activeColumn else { return }
        activeColumn = nil
        // 松手吸附到最近整数；时/分落到 0 时秒数联动钳到下限（自动回落 05）。
        values[column] = clamp(values[column].rounded(), column: column)
        values[2] = clamp(values[2], column: 2)
        needsDisplay = true
        onValueChanged?(Int(values[0]), Int(values[1]), Int(values[2]))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .closedHand)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        let wheel = wheelRect
        let font = selectedFontSize
        let spacing = rowSpacing
        let (digitCenters, colonCenters) = layout(for: font)

        // 数字滚动区裁剪：行只画在单位行之上，绝不压到单位汉字与下方按钮。
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: wheel).addClip()

        let center = wheel.midY
        // 数值列：选中值白色大字（对标正计时时钟），上下相邻值按距离渐隐
        // 缩小。列表方向：00 在上、99 在下——项值越大越靠下（flipped 坐标
        // y 越大）。同一列内按距离**从远到近**绘制：相邻行与选中行视觉重叠
        // 时，选中行完整压在上层（iOS 滚轮的紧凑排布）。
        for column in 0...2 {
            let value = values[column]
            let lower: Int
            let upper: Int
            switch column {
            case 0: lower = 0; upper = Metrics.maxHours
            case 1: lower = 0; upper = Metrics.maxMinutes
            default: lower = Int(secondsLowerBound); upper = Metrics.maxSeconds
            }
            var rows: [(item: Int, distance: Float)] = []
            for rowOffset in -Metrics.visibleRows...Metrics.visibleRows {
                let item = Int(value.rounded()) + rowOffset
                guard lower...upper ~= item else { continue }
                rows.append((item, abs(Float(item) - value)))
            }
            for row in rows.sorted(by: { $0.distance > $1.distance }) {
                // 优美曲线变换（ease-out 幂曲线，指数 1.8）：字号/亮度随行距
                // 非线性收敛——越靠近选中行变化越陡峭（相邻行立刻明显小一号、
                // 暗一截），远处渐趋平缓，比线性排布更贴近真实滚轮的透视感受。
                let x = min(row.distance, 2) / 2
                let t = pow(1 - x, 1.8)
                let fontSize = font * (Metrics.minFontFraction + (1 - Metrics.minFontFraction) * CGFloat(t))
                let alpha = 0.12 + 0.86 * CGFloat(t)
                let attrs = Self.textAttributes(fontSize: fontSize, alpha: alpha, semibold: row.distance < 0.5)
                let text = String(format: "%02d", row.item) as NSString
                let size = text.size(withAttributes: attrs)
                let y = center + (CGFloat(row.item) - CGFloat(value)) * spacing - size.height / 2
                text.draw(at: NSPoint(x: digitCenters[column] - size.width / 2, y: y), withAttributes: attrs)
            }
        }

        // 两枚 `:` 冒号：与选中行同行同字号（对标正计时「分:秒」的分隔样式）。
        let colonAttrs = Self.textAttributes(fontSize: font, alpha: 0.9, semibold: true)
        for colonX in colonCenters {
            let size = (":" as NSString).size(withAttributes: colonAttrs)
            (":" as NSString).draw(
                at: NSPoint(x: colonX - size.width / 2, y: center - size.height / 2),
                withAttributes: colonAttrs
            )
        }

        NSGraphicsContext.restoreGraphicsState()

        // 底部单位汉字行：各组数字正下方居中（时 / 分 / 秒），恒不被数字行覆盖。
        let unitAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(10, min(14, font * 0.3)), weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.4),
        ]
        let stripCenterY = wheel.maxY + unitStripHeight / 2
        for (column, unit) in Metrics.unitTitles.enumerated() {
            let size = (unit as NSString).size(withAttributes: unitAttrs)
            (unit as NSString).draw(
                at: NSPoint(x: digitCenters[column] - size.width / 2, y: stripCenterY - size.height / 2),
                withAttributes: unitAttrs
            )
        }
    }
}

/// 正计时时间大字下方的单位行：在「分:秒:厘秒」三组数字正下方绘制单位
/// 汉字（分 / 秒 / 厘）。timeLabel 用等宽数字字体且 sizeToFit 后文本恰好
/// 充满 frame——本视图与 timeLabel 同宽同位摆放，按同一字体的字宽（数字、
/// 冒号分开计量）复算各组字符的中心位，保证汉字精确对齐对应数字组。
@MainActor
private final class SlideshowTimerUnitLabelsView: NSView {
    /// 各组单位汉字（正计时固定为 分 / 秒 / 厘）。
    var units: [String] = []
    /// 与时间大字相同的字体（布局时同步），用于复算字符宽度。
    var referenceFont: NSFont = .monospacedDigitSystemFont(ofSize: 44, weight: .semibold)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard !units.isEmpty else { return }
        let charAttrs: [NSAttributedString.Key: Any] = [.font: referenceFont]
        let digitWidth = ("0" as NSString).size(withAttributes: charAttrs).width
        let colonWidth = (":" as NSString).size(withAttributes: charAttrs).width
        guard digitWidth > 0 else { return }

        // "MM:SS:CC" 的字符序列 = [数字×2, 冒号] ×3 组减尾冒号；
        // 第 g 组（0 基）前面有 g 个「两位数字 + 冒号」，组中心在其两位
        // 数字的中点 = 前缀宽 + 1×数字宽。
        var prefix: CGFloat = 0
        var centers: [CGFloat] = []
        for _ in 0..<units.count {
            centers.append(prefix + digitWidth)
            prefix += digitWidth * 2 + colonWidth
        }
        let textWidth = prefix - colonWidth

        let fontSize = max(9, bounds.height * 0.8)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.45),
        ]
        let originX = (bounds.width - textWidth) / 2
        for (index, unit) in units.enumerated() {
            let size = (unit as NSString).size(withAttributes: attrs)
            (unit as NSString).draw(
                at: NSPoint(
                    x: originX + centers[index] - size.width / 2,
                    y: (bounds.height - size.height) / 2
                ),
                withAttributes: attrs
            )
        }
    }
}

/// 计时器圆形图标按钮：emphasized 为亮底深字主按钮（播放/停止），否则暗底白图标。
/// 图标居中采用**像素级方案**：不走 NSImageView（SF 符号自带 alignmentRect
/// 元数据，ImageView 按「对齐框」而非「像素包围盒」摆图，视觉重心会偏离圆心），
/// 而是绘制时把符号栅格化为 CGImage（纯像素包围盒），以遮罩方式在圆心
/// 正中央填充着色——几何上强制双轴居中。
@MainActor
private final class SlideshowTimerIconButton: NSView {
    var onClick: (() -> Void)?

    var symbolName: String {
        didSet { needsDisplay = true }
    }

    var isEnabled = true {
        didSet { needsDisplay = true }
    }

    private let emphasized: Bool

    init(symbolName: String, accessibilityLabel: String, emphasized: Bool = false) {
        self.symbolName = symbolName
        self.emphasized = emphasized
        super.init(frame: .zero)
        setAccessibilityLabel(accessibilityLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : 0.35
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        if emphasized {
            NSColor.white.withAlphaComponent(0.92 * alpha).setFill()
            circle.fill()
        } else {
            NSColor.white.withAlphaComponent(0.10 * alpha).setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.18 * alpha).setStroke()
            circle.lineWidth = 1
            circle.stroke()
        }

        // 图标：以圆心为锚的居中方框，符号栅格化（CGImage = 纯像素包围盒，
        // 无 alignmentRect 干扰）后按遮罩填充着色——双轴严格居中。
        let side = min(bounds.width, bounds.height) * 0.52
        let iconRect = NSRect(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2,
            width: side,
            height: side
        )
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side * 0.8, weight: .medium)),
            let mask = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let context = NSGraphicsContext.current?.cgContext
        else { return }

        context.saveGState()
        // 本视图 flipped（y=0 在顶），CGImage 绘制基于未翻转坐标系：
        // 先把上下文整体翻转到 flipped 语义再画，保证非对称字形方向正确。
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: iconRect, mask: mask)
        (emphasized ? NSColor.black.withAlphaComponent(0.8 * alpha)
                    : NSColor.white.withAlphaComponent(0.9 * alpha)).setFill()
        context.fill(iconRect)
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - 草稿纸（高于放映画板的可漫游画板）

/// 草稿纸窗口：一块半透明纸面，高于放映批注画布（可被画笔书写）、低于工具栏
/// 等交互 UI。自身 UI 只有四角改大小；纸面画布开启**漫游**——鼠标态下在纸上
/// 按下拖动（或滚轮）平移的是画布内容（一块比窗口大的虚拟纸面），笔/橡皮态
/// 照常书写/擦除；改变大小只是改变「取景窗口」，纸上笔迹数据不删除。
@MainActor
final class SlideshowScratchpadWindow: NSPanel {
    /// 用户点纸面关闭按钮时回调（供控制器记录日志）。
    var onClose: (() -> Void)?

    let canvas = SlideshowAnnotationCanvasView()

    private let surface: SlideshowScratchpadSurface

    init() {
        surface = SlideshowScratchpadSurface(canvas: canvas)
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        level = SlideshowFloatingLevel.tool
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        canvas.allowsCanvasRoaming = true
        surface.autoresizingMask = [.width, .height]
        contentView = surface
        // 边框带拖动 = 移动整张草稿纸窗口（画布内拖动仍是漫游，互不干扰）。
        surface.onBeginMove = { [weak self] in
            self?.beginMoveFromSurface()
        }
        surface.onMoveTo = { [weak self] delta in
            self?.moveWindow(by: delta)
        }
        // 关闭按钮：仅隐藏窗口，纸上笔迹与漫游位置全部保留，可再次呼出。
        surface.onClose = { [weak self] in
            guard let self else { return }
            self.onClose?()
            self.orderOut(nil)
        }
    }

    /// 上次关闭时的 frame（重开原位原尺寸恢复用；nil = 尚未显示过）。
    /// 在 orderOut 时刻快照——边框拖动/角部缩放后的最新状态一定已反映在
    /// 当前 frame 上，比在 show 时记录更可靠。
    private(set) var lastShownFrame: NSRect?

    override func orderOut(_ sender: Any?) {
        if isVisible { lastShownFrame = frame }
        super.orderOut(sender)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 边框拖动起点（surface 回调累计位移；固定以按下时窗口原点为基线，
    /// 避免在已移过的原点上重复累加造成漂移加速）。
    private var moveStartFrameOrigin: NSPoint?

    private func beginMoveFromSurface() {
        moveStartFrameOrigin = frame.origin
    }

    private func moveWindow(by delta: NSPoint) {
        guard let origin = moveStartFrameOrigin else { return }
        setFrameOrigin(NSPoint(x: origin.x + delta.x, y: origin.y + delta.y))
        // 整窗平移：画布与窗口刚性一起动（偏移不变），锚点跟随窗口重推，
        // 保证后续缩放重算仍以「画布此刻的屏幕位置」为基准。
        canvas.refreshAnchor()
    }

    /// 在给定屏幕内打开一块草稿纸。
    /// 关闭后重开：恢复关闭时的原位原尺寸（用户对草稿纸的位置预期是「还在
    /// 原地」，区别于放大镜的回默认位设计）；首次呼出才取屏幕居中默认位。
    func show(in screenFrame: NSRect) {
        // 有限大画布：几倍于屏幕（漫游可用且有限）。幂等配置——重复显示
        // 不重置漫游位置与纸上内容；首次显示把视口居中到大画布中央。
        canvas.configureRoamingCanvas(contentSize: NSSize(
            width: screenFrame.width * 3,
            height: screenFrame.height * 3
        ))
        if let lastShownFrame {
            show(at: lastShownFrame)
            return
        }
        let size = NSSize(
            width: screenFrame.width * 0.5,
            height: screenFrame.height * 0.62
        )
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2 + size.height * 0.08
        )
        show(at: NSRect(origin: origin, size: size))
    }

    /// 按给定 frame 显示。
    /// 画布相对屏幕固定：显示后偏移按锚点重算；纸上内容与漫游位置保留。
    func show(at frame: NSRect) {
        setFrame(frame, display: true)
        surface.layoutCanvas()
        canvas.syncOffsetWithAnchor()
        // 视口尺寸就绪后执行首次配置的初始居中（幂等，仅首次生效）。
        canvas.centerRoamingViewportIfNeeded()
        orderFrontRegardless()
    }
}

/// 草稿纸表面：纸底 + 内嵌漫游批注画布（书写区）+ 隐形角部缩放圆点热点 +
/// 右上角关闭角标。画布内的拖动/滚轮漫游由画布自身处理；**画布外的边框带**
/// 在任何模式（鼠标/画笔/橡皮）下按下拖动 = 移动整个草稿纸窗口（非漫游）；
/// 角部圆点拖动为「自由裁切式」缩放（内容屏上不动）；右上角不设缩放圆点。
@MainActor
private final class SlideshowScratchpadSurface: NSView {
    /// 关闭按钮点击回调（窗口据此仅隐藏自身）。
    var onClose: (() -> Void)?
    /// 边框带拖动移动窗口：onBeginMove 按下时触发一次，onMoveTo 持续累计位移。
    var onBeginMove: (() -> Void)?
    var onMoveTo: ((NSPoint) -> Void)?

    /// 纸面度量（类为 file-private，Metrics 对同文件的关闭按钮可见——
    /// 角标贴纸角排布时需用同一圆角半径做裁剪）。
    enum Metrics {
        /// 纸张圆角。
        static let cornerRadius: CGFloat = 16
        /// 角部缩放热点：以窗口角点为圆心的隐形圆半径（不可见，仅命中）。
        /// 边缘只做视觉圆角裁剪、命中不裁——圆点覆盖弧外区域。右上角由
        /// 关闭角标占用，不设缩放圆点。
        static let handleRadius: CGFloat = 20
        /// 边框带宽度（画布到纸边的缩进，即窗口拖动热区；任何模式下可用）。
        static let inset: CGFloat = 10
        /// 画布圆角：与纸张圆角同心（纸张圆角 − 内边距）。
        static let canvasCornerRadius: CGFloat = cornerRadius - inset
        /// 点阵格间距。
        static let dotSpacing: CGFloat = 22
        /// 最小窗口尺寸（防把纸拖没）。
        static let minWindowSize = NSSize(width: 300, height: 220)
    }

    private enum DragMode {
        case none
        case move              // 边框带拖动：移动窗口（非漫游）
        case resize(ResizeCorner)
    }

    private typealias ResizeCorner = SlideshowCornerResize.Corner

    private let canvas: SlideshowAnnotationCanvasView
    private let closeButton = SlideshowScratchpadCloseButton()
    private var dragMode: DragMode = .none
    private var dragStartMouse: NSPoint?
    private var dragStartFrame: NSRect?

    init(canvas: SlideshowAnnotationCanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        addSubview(canvas)
        addSubview(closeButton)
        closeButton.onClick = { [weak self] in self?.onClose?() }
        // 画布四角圆角裁剪（同心：纸张圆角 16 − 内边距 10），笔迹与橡皮圆
        // 在四角被切齐，与画布阴影/点阵格的圆角内切路径一致。
        canvas.cornerClipRadius = Metrics.canvasCornerRadius
        // 画布漫游偏移变化（拖动/滚轮）时重绘纸面，让点阵格跟着内容平移。
        canvas.onRoamingChanged = { [weak self] in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutCanvas()
    }

    /// 画布占纸面中央书写区（四周留出把手边缘）。
    func layoutCanvas() {
        canvas.frame = NSRect(
            x: Metrics.inset,
            y: Metrics.inset,
            width: max(1, bounds.width - Metrics.inset * 2),
            height: max(1, bounds.height - Metrics.inset * 2)
        )
    }

    override func layout() {
        super.layout()
        // 关闭红标紧贴纸张右上角：上边贴上边、右边贴右边（无内收），角标
        // 右上角的圆角裁切交给纸张圆角（角标 draw 内按同一圆角半径自裁）。
        // 角标为子视图，点击优先于表面四角缩放命中。
        let size = SlideshowScratchpadCloseButton.badgeSize
        closeButton.frame = NSRect(
            x: bounds.width - size.width,
            y: 0,
            width: size.width,
            height: size.height
        )
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        // 先给整个窗口矩形铺一层隐形微量填充：非不透明无边框窗口的弧外
        // 全透明像素会被 WindowServer 判为「不属于本窗口」直接穿透，角部
        // 圆点热点收不到事件。1/255 是 8-bit 缓冲的最小非零 alpha——物理上
        // 仅一个色阶、肉眼不可见，但仍满足「非零 alpha 即命中」。
        NSColor.black.withAlphaComponent(1.0 / 255.0).setFill()
        bounds.fill()

        let path = NSBezierPath(
            roundedRect: bounds,
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        )
        // 纸底：暖白高不透明，深浅幻灯片上都可读，又透出少许背景层次。
        NSColor(calibratedRed: 0.985, green: 0.975, blue: 0.945, alpha: 0.95).setFill()
        path.fill()
        // 极淡外描边：让纸的轮廓在浅色幻灯片上也有边界感。
        NSColor.black.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1.2
        path.stroke()

        // 内书写区（与 canvas 对齐）。
        let contentRect = NSRect(
            x: Metrics.inset,
            y: Metrics.inset,
            width: bounds.width - Metrics.inset * 2,
            height: bounds.height - Metrics.inset * 2
        )

        // 点阵格：柔和浅灰圆点铺满书写区，比横线格更不打扰批注笔迹。
        // 点阵固定在**内容坐标**里随漫游一起平移，给出「在一张大纸上移动取景窗」
        // 的空间感；裁剪用与画布一致的圆角路径，四角不点进直角区。
        NSGraphicsContext.current?.cgContext.saveGState()
        NSBezierPath(
            roundedRect: contentRect,
            xRadius: Metrics.canvasCornerRadius,
            yRadius: Metrics.canvasCornerRadius
        ).addClip()
        let offset = canvas.roamingOffset
        NSColor.black.withAlphaComponent(0.08).setFill()
        let startX = contentRect.minX + Metrics.dotSpacing / 2 - offset.x
            .truncatingRemainder(dividingBy: Metrics.dotSpacing)
        var dotY = contentRect.minY + Metrics.dotSpacing / 2 - offset.y
            .truncatingRemainder(dividingBy: Metrics.dotSpacing)
        while dotY < contentRect.maxY {
            var dotX = startX
            while dotX < contentRect.maxX {
                NSBezierPath(
                    ovalIn: NSRect(x: dotX - 1, y: dotY - 1, width: 2, height: 2)
                ).fill()
                dotX += Metrics.dotSpacing
            }
            dotY += Metrics.dotSpacing
        }
        NSGraphicsContext.current?.cgContext.restoreGState()

        // 画布交界内部描边：与窗口外部描边同族的极淡版本（黑 0.14、1.2pt），
        // 沿画布（内书写区）圆角路径**内半边**绘制——先裁进路径再描边，
        // 外半边被裁掉，圆角处无裁剪缺口；画布本身仍无边框阴影。
        let canvasPath = NSBezierPath(
            roundedRect: contentRect,
            xRadius: Metrics.canvasCornerRadius,
            yRadius: Metrics.canvasCornerRadius
        )
        NSGraphicsContext.current?.cgContext.saveGState()
        canvasPath.addClip()
        NSColor.black.withAlphaComponent(0.14).setStroke()
        canvasPath.lineWidth = 1.2
        canvasPath.stroke()
        NSGraphicsContext.current?.cgContext.restoreGState()

        // 角部缩放为**隐形圆点热点**（不绘制任何角点视觉，用户明确要求移除
        // 圆点把手样式；命中范围是以窗口角点为圆心的圆）；边框带与角落以
        // 光标形态提示可拖动/可缩放。
    }

    /// 参与缩放热点的角：右上角被关闭角标占用，不设改大小圆点。
    private var resizeCorners: [ResizeCorner] { [.topLeft, .bottomLeft, .bottomRight] }

    private func corner(at point: NSPoint) -> ResizeCorner? {
        SlideshowCornerResize.corner(
            at: point, in: bounds, handleRadius: Metrics.handleRadius, activeCorners: resizeCorners
        )
    }

    // MARK: 手势（四角缩放 + 边框带拖动移动窗口；画布区域内由 canvas 子视图
    // 接收——笔/橡皮态书写擦除、鼠标态漫游平移画布内容）

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let corner = corner(at: point) {
            dragMode = .resize(corner)
            dragStartMouse = NSEvent.mouseLocation
            dragStartFrame = window?.frame
            return
        }
        // 画布之外的边框带：拖动移动整个窗口（「点击边框拖动改变位置」）。
        // 窗口即取景框：setFrameOrigin 整窗平移，画布作为子视图整体跟随，
        // 视觉上纸面/笔迹/点阵与边框同步移动、相对关系不变。
        if !canvas.frame.contains(point) {
            dragMode = .move
            dragStartMouse = NSEvent.mouseLocation
            dragStartFrame = window?.frame
            onBeginMove?()
            return
        }
        dragMode = .none
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse = dragStartMouse, let startFrame = dragStartFrame, let window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - startMouse.x
        let dy = current.y - startMouse.y

        switch dragMode {
        case .none:
            break
        case .move:
            onMoveTo?(NSPoint(x: dx, y: dy))
        case .resize(let corner):
            applyResize(corner: corner, dx: dx, dy: dy, window: window, startFrame: startFrame)
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = .none
        dragStartMouse = nil
        dragStartFrame = nil
    }

    /// 「视口式」缩放：拖动某角只改变窗口大小。画布相对屏幕固定（锚点模型），
    /// 画布几何变化时在 setFrameSize 内按锚点重算偏移——图形在屏幕上的位置
    /// 由构造保证不动，这里只需 setFrame，不存在任何改变画布的操作。
    /// （移动窗口走边框拖动：窗口本体与画布刚性一起动。）
    private func applyResize(corner: ResizeCorner, dx: CGFloat, dy: CGFloat, window: NSWindow, startFrame: NSRect) {
        // 画布相对屏幕固定，缩放不碰偏移——对齐由画布 setFrameSize 内的
        // 锚点重算完成（先于本帧重绘）。
        window.setFrame(
            SlideshowCornerResize.resizedFrame(
                startFrame: startFrame, dx: dx, dy: dy,
                minSize: Metrics.minWindowSize,
                corner: corner
            ),
            display: true
        )
    }

    override func resetCursorRects() {
        // 边框带 = 抓手（可拖动窗口）；角部圆点热点 = 缩放光标（后添加优先覆盖）。
        let band = borderBandRects()
        for rect in band {
            addCursorRect(rect, cursor: .openHand)
        }
        for corner in resizeCorners {
            // 光标矩形取圆点在窗口内的角象限包围方框。
            // 系统无内置对角箭头光标，四角一律用抓取光标近似。
            addCursorRect(
                SlideshowCornerResize.cursorRect(for: corner, in: bounds, handleRadius: Metrics.handleRadius),
                cursor: .closedHand
            )
        }
    }

    /// 边框带光标区：画布 frame 之外的四条带。右上角无缩放圆点（关闭角标
    /// 所在），顶带/右带在该角不再让位；其余三角让出圆点热点区。
    private func borderBandRects() -> [NSRect] {
        let canvasFrame = canvas.frame
        let cornerPad = Metrics.handleRadius
        var rects: [NSRect] = []
        // 顶带：左端让出左上圆点，右端直达右缘（右上无圆点）。
        rects.append(NSRect(x: cornerPad, y: 0, width: bounds.width - cornerPad, height: canvasFrame.minY))
        // 底带：两端各让出圆点。
        rects.append(NSRect(x: cornerPad, y: canvasFrame.maxY, width: bounds.width - cornerPad * 2, height: bounds.height - canvasFrame.maxY))
        // 左带：上下各让出圆点。
        rects.append(NSRect(x: 0, y: canvasFrame.minY + cornerPad, width: canvasFrame.minX, height: canvasFrame.height - cornerPad * 2))
        // 右带：上端直达顶缘（右上无圆点），下端让出右下圆点。
        rects.append(NSRect(x: canvasFrame.maxX, y: canvasFrame.minY, width: bounds.width - canvasFrame.maxX, height: canvasFrame.height - cornerPad))
        return rects.filter { $0.width > 1 && $0.height > 1 }
    }
}

/// 草稿纸关闭按钮：**紧贴纸张右上角**（上边贴上边、右边贴右边）的
/// **缎带式红标**——斜边左上→右下倾斜（陡角：水平投影 = 高度一半），斜边
/// 末端与底边交接处一个大圆角（0.4×高）。右上角为直角，由纸张圆角在
/// draw 内按同一圆角半径裁切给出弧形观感；右下自圆角化（小圆角）、
/// 斜边顶端小圆角收尖。红底白标：systemRed
/// 实底 + 白色「×」（居中公式同预览角标文字：可用区中心 = w/2 + slantDX/4），
/// 整面为点击区。
@MainActor
private final class SlideshowScratchpadCloseButton: NSView {
    var onClick: (() -> Void)?

    private enum Metrics {
        /// 角标高度。
        static let height: CGFloat = 20
        /// × 区宽度（斜边右侧的可用区）。
        static let crossAreaWidth: CGFloat = 24
        /// 斜边水平投影（陡角缎带样式，= 高度一半）。
        static let slantDX: CGFloat = height * 0.5
        /// 斜边末端圆角半径（0.4×高）。
        static let slantRadius: CGFloat = height * 0.4
        /// 右下自圆角半径（贴角排布后仅右下角需自圆角化；
        /// 右上角由纸张圆角裁切，见 draw）。
        static let outerRadius: CGFloat = 6
    }

    /// 角标整面尺寸（surface 布局据此定位）。
    static var badgeSize: NSSize {
        NSSize(width: Metrics.slantDX + Metrics.crossAreaWidth, height: Metrics.height)
    }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.badgeSize))
        setAccessibilityLabel("关闭草稿纸")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let h = bounds.height
        let slantDX = Metrics.slantDX
        let outerR = Metrics.outerRadius
        let paperR = SlideshowScratchpadSurface.Metrics.cornerRadius

        // 角标已贴到窗口右上角（surface 布局），先按纸张圆角裁剪本视图：
        // 只有右上角落在纸张圆角弧线内，弧外的三角形区域被裁掉——
        // 角标右上角的圆角观感完全由纸张圆角给出，自身不再画弧。
        let cornerClip = NSBezierPath()
        cornerClip.move(to: NSPoint(x: 0, y: 0))
        cornerClip.line(to: NSPoint(x: w - paperR, y: 0))
        cornerClip.curve(
            to: NSPoint(x: w, y: paperR),
            controlPoint1: NSPoint(x: w, y: 0),
            controlPoint2: NSPoint(x: w, y: 0)
        )
        cornerClip.line(to: NSPoint(x: w, y: h))
        cornerClip.line(to: NSPoint(x: 0, y: h))
        cornerClip.close()
        cornerClip.addClip()

        // 顶点（flipped，y=0 在顶）：斜边顶端小圆角 → 顶边直达右上角（直角，
        // 由上面的纸张圆角裁剪）→ 右边 → 右下自圆角 → 底边 → 斜边末端大圆角
        // （斜边→底边过渡）→ 沿斜边回到顶端小圆角闭合。
        let slantEndX = slantDX
        let slantLength = hypot(slantDX, h)
        // 斜边上距顶端 apexT 的点（顶端小圆角的收线起点）。
        let apexT: CGFloat = 5
        let apexQX = apexT * slantDX / slantLength
        let apexQY = apexT * h / slantLength
        let badge = NSBezierPath()
        badge.move(to: NSPoint(x: apexQX * 0.5, y: 0))
        badge.line(to: NSPoint(x: w, y: 0))
        badge.line(to: NSPoint(x: w, y: h - outerR))
        badge.curve(
            to: NSPoint(x: w - outerR, y: h),
            controlPoint1: NSPoint(x: w, y: h),
            controlPoint2: NSPoint(x: w, y: h)
        )
        badge.line(to: NSPoint(x: slantEndX + Metrics.slantRadius, y: h))
        badge.curve(
            to: NSPoint(
                x: slantEndX - Metrics.slantRadius * slantDX / slantLength,
                y: h - Metrics.slantRadius * h / slantLength
            ),
            controlPoint1: NSPoint(x: slantEndX, y: h),
            controlPoint2: NSPoint(x: slantEndX, y: h)
        )
        // 沿斜边上行到收线点，经顶端小圆角（控制点在斜边顶点）闭合。
        badge.line(to: NSPoint(x: apexQX, y: apexQY))
        badge.curve(
            to: NSPoint(x: apexQX * 0.5, y: 0),
            controlPoint1: NSPoint(x: 0, y: 0),
            controlPoint2: NSPoint(x: 0, y: 0)
        )
        badge.close()
        // 红底白标（同预览页码角标的实色缎带风格）。
        NSColor.systemRed.setFill()
        badge.fill()

        // 白色「×」：与预览角标文字同一居中公式——可用区（斜边以右）中心
        // = w/2 + slantDX/4。
        let cx = w / 2 + slantDX / 4
        let cy = h / 2
        let arm: CGFloat = 4.5
        let cross = NSBezierPath()
        cross.lineWidth = 2.0
        cross.lineCapStyle = .round
        cross.move(to: NSPoint(x: cx - arm, y: cy - arm))
        cross.line(to: NSPoint(x: cx + arm, y: cy + arm))
        cross.move(to: NSPoint(x: cx + arm, y: cy - arm))
        cross.line(to: NSPoint(x: cx - arm, y: cy + arm))
        NSColor.white.setStroke()
        cross.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 计时器浮窗与草稿纸浮窗共用的对角缩放几何：
/// 拖动某角只改变该角方向，保持对角点不动（AppKit 坐标 y 向上，
/// top 角 dy>0 增高、bottom 角 dy>0 意味着底边随鼠标上移）。
/// 浮层窗口「隐形圆点」角部缩放的共享几何：计时器面板与草稿纸共用。
/// 视觉上不绘制把手，仅提供热点命中、光标矩形与对角固定缩放；
/// 两处视图均为 flipped 坐标（y=0 为顶边）。
private enum SlideshowCornerResize {
    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    /// 角圆心（视图坐标，flipped：y=0 为顶边）。
    static func cornerPoint(for corner: Corner, in bounds: NSRect) -> NSPoint {
        switch corner {
        case .topLeft: return NSPoint(x: 0, y: 0)
        case .topRight: return NSPoint(x: bounds.width, y: 0)
        case .bottomLeft: return NSPoint(x: 0, y: bounds.height)
        case .bottomRight: return NSPoint(x: bounds.width, y: bounds.height)
        }
    }

    /// 圆点热点命中：点击点距该角圆心不超过 handleRadius 即命中。
    /// `activeCorners` 限定参与缩放的角（如草稿纸右上角被关闭角标占用）。
    static func corner(
        at point: NSPoint,
        in bounds: NSRect,
        handleRadius: CGFloat,
        activeCorners: [Corner] = Corner.allCases
    ) -> Corner? {
        for corner in activeCorners {
            let c = cornerPoint(for: corner, in: bounds)
            if hypot(point.x - c.x, point.y - c.y) <= handleRadius {
                return corner
            }
        }
        return nil
    }

    /// 角象限包围方框（resetCursorRects 光标区：圆点落在窗口角内的方框）。
    static func cursorRect(for corner: Corner, in bounds: NSRect, handleRadius: CGFloat) -> NSRect {
        NSRect(
            x: corner == .topLeft || corner == .bottomLeft ? 0 : bounds.width - handleRadius,
            y: corner == .topLeft || corner == .topRight ? 0 : bounds.height - handleRadius,
            width: handleRadius,
            height: handleRadius
        )
    }

    /// 对角固定的窗口缩放：拖动某角只改变该角方向，保持对角点不动。
    static func resizedFrame(
        startFrame: NSRect,
        dx: CGFloat,
        dy: CGFloat,
        minSize: NSSize,
        corner: Corner
    ) -> NSRect {
        resizedFrame(
            startFrame: startFrame, dx: dx, dy: dy, minSize: minSize,
            growRight: corner == .topRight || corner == .bottomRight,
            growUp: corner == .topRight || corner == .topLeft
        )
    }

    static func resizedFrame(
        startFrame: NSRect,
        dx: CGFloat,
        dy: CGFloat,
        minSize: NSSize,
        growRight: Bool,
        growUp: Bool
    ) -> NSRect {
        let newWidth = growRight
            ? max(minSize.width, startFrame.width + dx)
            : max(minSize.width, startFrame.width - dx)
        let newHeight = growUp
            ? max(minSize.height, startFrame.height + dy)
            : max(minSize.height, startFrame.height - dy)
        let newX = growRight ? startFrame.origin.x : startFrame.origin.x + (startFrame.width - newWidth)
        let newY = growUp ? startFrame.origin.y : startFrame.origin.y + (startFrame.height - newHeight)
        return NSRect(x: newX, y: newY, width: newWidth, height: newHeight)
    }
}

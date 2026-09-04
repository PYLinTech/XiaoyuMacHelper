import AppKit
import QuartzCore

// MARK: - 进出场 / 点击动效小工具

/// 轻微淡入（带小幅上浮回落）：先置透明并下沉，orderFront 后同步淡入、回到原位。
/// 供底部工具栏 / 翻页栏 / 笔橡皮二级菜单这些「轻微进出场」的浮层使用。
/// 目标透明度由调用方传入（工具栏是 barAlpha 0.72，二级菜单/弹窗为 1）。
@MainActor
private func fadeInWindow(
    _ window: NSWindow,
    targetAlpha: CGFloat,
    rise: CGFloat = 4,
    duration: TimeInterval = 0.15
) {
    guard !window.isVisible else { return }
    // 进场即恢复鼠标交互：退场动画会临时关闭窗口交互，统一在此复位，
    // 交互开关由 fadeOut(关) / fadeIn(开) 单向管理，调用方无需各自打理。
    window.ignoresMouseEvents = false
    let finalFrame = window.frame
    var startFrame = finalFrame
    startFrame.origin.y -= rise
    window.setFrame(startFrame, display: false)
    window.alphaValue = 0
    window.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        window.animator().alphaValue = targetAlpha
        window.animator().setFrame(finalFrame, display: false)
    }
}

/// 轻微淡出（下沉回落 + 透明度归零）：动画结束后才真正 orderOut。
/// 动画执行期间闭包强持有窗口——即使调用方已置空引用（如控制器 teardown
/// 后置 nil），窗口也能完整退场并正确关闭，不会残留悬浮窗。
/// `completion` 在 orderOut 之后调用，供需要「退场完成后再行动」的调用方
/// （如二级菜单退场中被请求重新进场时，由收尾自动补进）。
@MainActor
private func fadeOutWindow(
    _ window: NSWindow,
    drop: CGFloat = 4,
    duration: TimeInterval = 0.12,
    completion: (() -> Void)? = nil
) {
    guard window.isVisible else { completion?(); return }
    // 退场动画帧里窗口在移动/渐隐：关闭鼠标交互，杜绝动画期间点击内部控件
    // 触发同步重绘与移动帧叠加（「切换粗细后图标内部阴影/重叠」的诱发窗口期）。
    window.ignoresMouseEvents = true
    var targetFrame = window.frame
    targetFrame.origin.y -= drop
    NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.timingFunction = CAMediaTimingFunction(name: .easeIn)
        window.animator().alphaValue = 0
        window.animator().setFrame(targetFrame, display: false)
    } completionHandler: {
        window.orderOut(nil)
        completion?()
    }
}

/// 图标点按「弹跳」动画：模拟 macOS 工具栏图标被点击时的弹性反馈——图标先快速
/// 压缩、再带轻微过冲回弹到原尺寸。缩放用 translate×scale×translate 绕视图中心
/// 进行，不依赖 layer.anchorPoint，避免与 AppKit 的视图布局同步冲突。
@MainActor
private func playIconBounce(_ view: NSView) {
    view.wantsLayer = true
    guard let layer = view.layer else { return }
    let size = view.bounds.size
    guard size.width > 0, size.height > 0 else { return }
    func centered(_ scale: CGFloat) -> NSValue {
        var transform = CATransform3DIdentity
        transform = CATransform3DTranslate(transform, size.width / 2, size.height / 2, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -size.width / 2, -size.height / 2, 0)
        return NSValue(caTransform3D: transform)
    }
    let animation = CAKeyframeAnimation(keyPath: "transform")
    animation.values = [centered(1), centered(0.72), centered(1.10), centered(0.96), centered(1)]
    animation.keyTimes = [0, 0.16, 0.5, 0.78, 1]
    animation.duration = 0.32
    animation.timingFunctions = [
        CAMediaTimingFunction(name: .easeOut),
        CAMediaTimingFunction(name: .easeOut),
        CAMediaTimingFunction(name: .easeInEaseOut),
        CAMediaTimingFunction(name: .easeInEaseOut)
    ]
    layer.removeAnimation(forKey: "iconBounce")
    layer.add(animation, forKey: "iconBounce")
}

// MARK: - 幻灯片批注工具模型

/// 批注工具（互斥单选）。
enum SlideshowAnnotationTool: Int {
    case mouse      // 鼠标（默认）：事件穿透，不绘制
    case pen        // 画笔
    case eraser     // 橡皮：区域抹除
}

/// 画笔调色板（固定三色：红 / 蓝 / 黑）。
/// 画布默认笔色与画笔颜色胶囊共用同一常量表，保证初始选中圈与真实笔色一致。
enum SlideshowPenPalette {
    static let ordered: [(color: NSColor, name: String)] = [
        (.systemRed, "红色"),
        (.systemBlue, "蓝色"),
        (.black, "黑色")
    ]
}

/// 画笔粗细预设（细 / 中 / 粗）。
/// 中档与历史默认笔宽参数完全一致（细 / 粗是中档的等比缩放），
/// 画布实际笔宽与画笔粗细胶囊行共用同一常量表，保证初始选中圈与真实笔宽一致。
enum SlideshowPenWidthPreset {
    struct Preset {
        let name: String
        /// 快速甩动时最细的笔锋宽度。
        let minWidth: CGFloat
        /// 慢速停顿时可达到的最粗宽度。
        let maxWidth: CGFloat
        /// 起笔与单击落点的宽度。
        let startWidth: CGFloat
        /// 粗细胶囊里 S 型笔迹预览的线条宽度（视觉示意，非真实笔宽）。
        let previewStrokeWidth: CGFloat
    }

    /// 细：约为中档的 0.6 倍，快速出锋更细、慢写也更克制。
    /// 预览线宽刻意压到 1.0（中 2.8 / 粗 4.5），保证三个 S 型图标肉眼一眼可辨粗细差异。
    static let thin = Preset(name: "细", minWidth: 1.2, maxWidth: 3, startWidth: 1.8, previewStrokeWidth: 1.0)
    /// 中：与历史默认参数完全一致（宽度 2~5、起笔 3）。
    static let medium = Preset(name: "中", minWidth: 2, maxWidth: 5, startWidth: 3, previewStrokeWidth: 2.8)
    /// 粗：约为中档的 1.6 倍，慢速蓄墨更醒目、快速甩动也不至于过细。
    static let thick = Preset(name: "粗", minWidth: 3.2, maxWidth: 8, startWidth: 4.8, previewStrokeWidth: 4.5)

    static let ordered: [Preset] = [thin, medium, thick]

    /// 默认（中档）在 ordered 中的下标：画布与工具面板初始状态都对齐中档。
    static let defaultIndex = 1
}

/// 笔迹采样点：位置 + 该点处线宽（用于笔锋模拟与区域擦除）。
struct SlideshowStrokePoint {
    var point: NSPoint
    var width: CGFloat
}

/// 单条批注笔迹：一串带线宽的采样点（画布本地坐标，y 向上）。
/// 存储原始采样点而非路径，以便橡皮擦按区域剔除局部点后拆分为多段。
/// 线宽信息内嵌在每个采样点中（samples[].width），无独立的基础线宽字段。
struct SlideshowStroke {
    var samples: [SlideshowStrokePoint]
    var color: NSColor
}

/// 一页幻灯片的批注内容（撤销/还原由控制器统一链管理，这里只存笔迹）。
struct SlideshowSlideAnnotations {
    var strokes: [SlideshowStroke] = []
}

// MARK: - 批注画布

/// 覆盖在放映窗口上的透明批注画布：只负责绘制笔迹，不拦截任何鼠标/触摸板事件
/// （`ignoresMouseEvents` 由所属窗口控制）。绘制坐标使用画布本地坐标（y 向上）。
///
/// 画笔采用「最小间距采样 + 速度相关目标线宽 + EMA 平滑 + Catmull-Rom 样条」
/// 模拟真实笔触：低于最小间距的拖动事件丢弃，线宽向目标值指数逼近，
/// 避免逐事件噪声导致的线宽抖动与折角。
/// 橡皮擦为「区域抹除」：沿拖动轨迹扫过的圆形区域内断开笔迹，
/// 只在真正被擦到的位置拆分，未擦到的部分保持原始采样连续性不变。
@MainActor
final class SlideshowAnnotationCanvasView: NSView {
    private enum PenMetrics {
        /// 最小采样间距：低于该距离的拖动事件丢弃（去抖动 + 去过密采样）。
        static let minSampleDistance: CGFloat = 2
        /// 线宽 EMA 系数：新线宽向目标线宽靠近的比例（越小过渡越柔和）。
        static let widthSmoothing: CGFloat = 0.25
        /// 参考快速移动距离：单个采样间隔移动超过该值视为快速移动。
        static let fastMoveDistance: CGFloat = 28
        // 线宽上下限与起笔宽度不在此处固定：由粗细预设（penWidthPreset）决定，
        // 支持「细 / 中 / 粗」三档切换（中档即历史默认参数）。
    }

    private enum EraserMetrics {
        /// 橡皮半径随拖动**速度与加速度**共同动态变化：
        /// - 速度：划得快半径放大（大面积清除），划得慢半径收小（局部精修）；
        /// - 加速度：本帧比上一帧明显更快的「突然加速」会在速度基础上再放大，
        ///   爆发式挥动立刻撑大擦除带，更跟手；
        /// - 半径逼近用**不对称 EMA**：放大快（0.5）、缩小慢（0.09）——突然
        ///   加速瞬间变大，加速结束后缓慢回缩（衰减不突兀，快速大扫扫完不会
        ///   立刻缩成小圆，保持大面积清扫的连贯手感）。
        static let minRadius: CGFloat = 7
        static let maxRadius: CGFloat = 64
        /// 参考快速移动距离：单帧位移达到该值视为全速（与画笔同量级）。
        static let fastMoveDistance: CGFloat = 30
        /// 参考突然加速幅度：本帧位移比上一帧快出该值视为一次爆发加速。
        static let surgeDistance: CGFloat = 40
        /// 加速度的额外权重（0~1）：爆发全量时在速度因子之上再叠加的比例。
        static let surgeWeight: CGFloat = 0.4
        /// 不对称 EMA：目标变大时快速逼近 / 变小时缓慢回落。
        static let growSmoothing: CGFloat = 0.5
        static let shrinkSmoothing: CGFloat = 0.09
        /// 进入橡皮模式/新一笔擦除时重置的默认半径。
        static let defaultRadius: CGFloat = 16
    }

    private var activeStroke: SlideshowStroke?

    /// 橡皮当前位置（仅用于绘制提示圆，不参与数据结构）。
    private var eraserPosition: NSPoint?

    /// 橡皮上一次擦除位置，用于拖动补点插值。
    private var lastErasePoint: NSPoint?

    /// 橡皮拖动开始前的整页笔迹快照，用于拖动结束时判断是否产生有效擦除并只记一次撤销。
    private var eraserBeforeSnapshot: [SlideshowStroke]?

    /// 橡皮当前擦除半径：随拖动速度与加速度动态变化（爆发加速大圆、慢速小圆）。
    private var eraserRadius: CGFloat = EraserMetrics.defaultRadius

    /// 橡皮上一帧的位移（点/事件）：用于判定「突然加速」——本帧位移明显大于
    /// 上一帧位移时视为一次爆发，半径目标在速度基础上额外放大。
    private var eraserLastFrameDistance: CGFloat = 0

    var tool: SlideshowAnnotationTool = .mouse {
        didSet {
            guard tool != oldValue else { return }
            // 切换工具时丢弃进行中的笔画/橡皮状态：防止外部同步（applyTool-
            // Externally 等）在拖拽进行中换工具时，残留 activeStroke 持续入绘。
            activeStroke = nil
            eraserBeforeSnapshot = nil
            eraserPosition = nil
            lastErasePoint = nil
        }
    }
    var penColor: NSColor = SlideshowPenPalette.ordered[0].color
    /// 当前画笔粗细预设（粗细胶囊点选切换；默认中档 = 历史默认参数）。
    var penWidthPreset = SlideshowPenWidthPreset.medium
    /// 画布内容圆角裁剪半径（>0 时 draw 裁剪到圆角路径，笔迹/橡皮圆四角
    /// 被圆角切齐）：草稿纸画布用；演示画布保持 0（矩形裁剪，无可见差异）。
    var cornerClipRadius: CGFloat = 0

    /// 开启画布漫游（草稿纸专用）：鼠标态下在画布上按下拖动不平移窗口，
    /// 而是平移画布内容（漫游一块比窗口大的虚拟纸面）；滚轮同样漫游。
    /// 关闭（演示画布）时维持原行为——鼠标态窗口穿透，画布收不到事件。
    var allowsCanvasRoaming = false

    /// 一笔结束（画笔落盘 / 橡皮擦除 / 清空）时回调，供控制器写回内存映射。
    var onStrokeEnded: (() -> Void)?

    /// 一次批注动作（画笔落盘 / 橡皮擦除 / 清空）提交时回调，携带改动前后的
    /// 笔迹快照。撤销/还原统一由控制器单链管理（演示画布 + 草稿纸互通），
    /// 画布自身不再维护撤销栈。
    var onActionCommitted: ((_ before: [SlideshowStroke], _ after: [SlideshowStroke]) -> Void)?

    /// 页面级批注数据（内存级，按页码存储于控制器）。
    var slideAnnotations: SlideshowSlideAnnotations = SlideshowSlideAnnotations() {
        didSet { needsDisplay = true }
    }

    /// 漫游偏移：视图原点（左下）对应的画布内容坐标。view = content - offset。
    private var contentOffset: NSPoint = .zero

    /// 有限漫游画布的内容尺寸（几倍屏幕的大画布，漫游可用且有限）：
    /// nil = 无界（演示画布不漫游，偏移恒零、不夹取）。
    private var roamingContentSize: NSSize?

    /// 首次配置后的初始居中标记（视口尺寸就绪后执行一次）。
    private var pendingInitialCenter = false

    /// 画布内容原点 (0,0) 在**屏幕坐标系**中的锚点：画布相对屏幕固定，
    /// 锚点即内容 (0,0) 此刻落在屏幕上的位置（大画布居中屏幕 → 锚点在屏幕
    /// 左下方外侧）。窗口移动时锚点随窗口平移（画布与窗口刚性一起动）；
    /// 窗口缩放时锚点不动（画布锁在屏幕上），偏移由锚点重算——图形在屏幕
    /// 上的位置由构造保证不变，不存在「缩放改变画布」的操作。
    private var contentScreenAnchor: NSPoint = .zero
    private var anchorValid = false

    /// 配置有限漫游画布（草稿纸）：contentSize = 大画布尺寸（如 3× 屏幕）。
    /// 幂等——已按同尺寸配置过则不动（保留漫游位置与纸上内容）；首次配置
    /// 标记待居中，待视口尺寸就绪后由 centerRoamingViewportIfNeeded 执行。
    func configureRoamingCanvas(contentSize: NSSize) {
        guard allowsCanvasRoaming else { return }
        if let current = roamingContentSize,
           abs(current.width - contentSize.width) < 0.5,
           abs(current.height - contentSize.height) < 0.5 {
            return
        }
        roamingContentSize = contentSize
        pendingInitialCenter = true
    }

    /// 初始居中（幂等）：视口完整落在大画布中央，屏幕中心 = 画布中心。
    /// 窗口 show 完成布局后调用；居中后立即锚定。
    func centerRoamingViewportIfNeeded() {
        guard pendingInitialCenter, let size = roamingContentSize else { return }
        pendingInitialCenter = false
        contentOffset = NSPoint(
            x: max(0, (size.width - bounds.width) / 2),
            y: max(0, (size.height - bounds.height) / 2)
        )
        refreshAnchor()
        needsDisplay = true
        onRoamingChanged?()
    }

    /// 把漫游偏移夹回有限画布范围内：视口 [offset, offset+bounds] 必须
    /// 完整落在 [0, contentSize] 内——漫游到纸边即停，画布有限可尽。
    private func clampRoamingOffset() {
        guard let size = roamingContentSize else { return }
        let clamped = NSPoint(
            x: min(max(0, contentOffset.x), max(0, size.width - bounds.width)),
            y: min(max(0, contentOffset.y), max(0, size.height - bounds.height))
        )
        guard clamped != contentOffset else { return }
        contentOffset = clamped
        needsDisplay = true
        onRoamingChanged?()
    }

    /// 由当前窗口几何反推锚点：锚点 = 窗口原点 + 视图原点（窗口坐标）− 偏移。
    /// 漫游拖移 / 滚轮 / 窗口整体移动后调用，让锚点始终与偏移保持一致。
    func refreshAnchor() {
        guard allowsCanvasRoaming, let win = window else { return }
        let originInWindow = convert(NSPoint.zero, to: nil)
        contentScreenAnchor = NSPoint(
            x: win.frame.origin.x + originInWindow.x - contentOffset.x,
            y: win.frame.origin.y + originInWindow.y - contentOffset.y
        )
        anchorValid = true
    }

    /// 窗口几何变化（缩放 / 移动 / 恢复显示）后按锚点重算偏移：画布相对
    /// 屏幕固定（锚点不动），偏移 = 窗口原点 + 视图原点 − 锚点，完全由窗口
    /// 此刻在屏幕上的位置导出——缩放只增减可见范围，图形位置由构造保证不动。
    func syncOffsetWithAnchor() {
        guard allowsCanvasRoaming, anchorValid, let win = window else { return }
        let originInWindow = convert(NSPoint.zero, to: nil)
        contentOffset = NSPoint(
            x: win.frame.origin.x + originInWindow.x - contentScreenAnchor.x,
            y: win.frame.origin.y + originInWindow.y - contentScreenAnchor.y
        )
        clampRoamingOffset()
        refreshAnchor()
        needsDisplay = true
        onRoamingChanged?()
    }

    /// 当前漫游偏移（只读，供承载视图让点阵格等背景随之平移）。
    var roamingOffset: NSPoint { contentOffset }

    /// 漫游偏移变化（拖动/滚轮）时回调，供承载视图同步重绘背景。
    var onRoamingChanged: (() -> Void)?

    /// 漫游拖动状态（仅鼠标态 + allowsCanvasRoaming）。
    private var panStartMouse: NSPoint?
    private var panStartOffset: NSPoint?

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    // MARK: 鼠标绘制（画笔/橡皮模式下覆盖层不穿透，画布直接接收事件）

    override func mouseDown(with event: NSEvent) {
        if tool == .mouse {
            beginPanIfNeeded()
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        beginStroke(at: contentPoint(fromView: viewPoint), viewPoint: viewPoint)
    }

    override func mouseDragged(with event: NSEvent) {
        if tool == .mouse {
            continuePanIfNeeded()
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        continueStroke(to: contentPoint(fromView: viewPoint), viewPoint: viewPoint)
    }

    override func mouseUp(with event: NSEvent) {
        if tool == .mouse {
            panStartMouse = nil
            panStartOffset = nil
            return
        }
        endStroke()
    }

    /// 视图坐标 → 画布内容坐标（漫游开启时按偏移换算，关闭时两者重合）。
    private func contentPoint(fromView p: NSPoint) -> NSPoint {
        allowsCanvasRoaming
            ? NSPoint(x: p.x + contentOffset.x, y: p.y + contentOffset.y)
            : p
    }

    // MARK: 画布漫游（草稿纸）

    /// 鼠标态按下开始漫游拖动（内容跟随鼠标反向平移）。
    private func beginPanIfNeeded() {
        guard allowsCanvasRoaming else { return }
        panStartMouse = NSEvent.mouseLocation
        panStartOffset = contentOffset
    }

    private func continuePanIfNeeded() {
        guard allowsCanvasRoaming, let start = panStartMouse, let base = panStartOffset else { return }
        let current = NSEvent.mouseLocation
        // 鼠标向右/上拖 → 内容跟随右/上移 → 视图原点对应的内容坐标减小。
        contentOffset = NSPoint(
            x: base.x - (current.x - start.x),
            y: base.y - (current.y - start.y)
        )
        clampRoamingOffset()
        // 内容相对屏幕移动了 → 锚点随新偏移重推。
        refreshAnchor()
        needsDisplay = true
        onRoamingChanged?()
    }

    /// 滚轮 / 触摸板双指滚动：漫游画布直接平移内容（内容随手势方向漫游）；
    /// 演示画布在拦截态把滚动转发给下层 WPS（滚动翻页仍可用）。
    override func scrollWheel(with event: NSEvent) {
        if allowsCanvasRoaming {
            contentOffset.x += event.scrollingDeltaX
            contentOffset.y += event.scrollingDeltaY
            clampRoamingOffset()
            refreshAnchor()
            needsDisplay = true
            onRoamingChanged?()
            return
        }
        guard tool != .mouse else { return }
        (window as? SlideshowAnnotationOverlayWindow)?.forwardScrollToUnderlying(event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // 视口尺寸变化（窗口缩放等）：画布相对屏幕固定，偏移由锚点重算——
        // 发生在窗口几何已更新、本帧重绘之前，图形位置由构造保证不动。
        syncOffsetWithAnchor()
    }

    override func resetCursorRects() {
        // 漫游画布鼠标态整面显示抓手，提示「按住拖动漫游」。
        if allowsCanvasRoaming, tool == .mouse {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 画布内容（笔迹/橡皮提示圆）严格裁剪在本画布边界内：NSView 绘制
        // 默认不按自身 bounds 裁剪，草稿纸画布的笔迹与橡皮圆会溢出到纸面
        // 边框带、甚至纸张圆角区。演示画布为全窗内容，裁剪无可见差异。
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if cornerClipRadius > 0 {
            // 圆角裁剪：笔迹/橡皮圆在四角被圆角路径切齐（草稿纸画布）。
            NSBezierPath(
                roundedRect: bounds,
                xRadius: cornerClipRadius,
                yRadius: cornerClipRadius
            ).addClip()
        } else {
            context.clip(to: NSRect(origin: .zero, size: bounds.size))
        }

        let isRoamed = allowsCanvasRoaming && (contentOffset.x != 0 || contentOffset.y != 0)
        if isRoamed {
            context.saveGState()
            // 内容坐标 → 视图坐标平移（view = content - offset）。
            context.translateBy(x: -contentOffset.x, y: -contentOffset.y)
        }
        drawStrokes(slideAnnotations.strokes)
        if let activeStroke {
            drawStrokes([activeStroke])
        }
        if isRoamed {
            context.restoreGState()
        }
        // 橡皮提示圆跟随鼠标，用视图坐标绘制（不随内容平移）。
        drawEraserHint()

        context.restoreGState()
    }

    // MARK: - 笔触绘制（平滑 + 可变线宽）

    /// 用 Catmull-Rom 样条平滑绘制一条笔迹，并在相邻采样点间按线宽渐变。
    private func drawStrokes(_ strokes: [SlideshowStroke]) {
        for stroke in strokes {
            guard stroke.samples.count >= 2 else {
                drawSinglePoint(stroke)
                continue
            }

            // 1. 对采样点做 Catmull-Rom 平滑，得到密集的插值点（含线宽插值）。
            //    提高插值密度，使弯曲处的折线更贴合曲线，减小法线突变。
            let smoothed = Self.smoothSamples(stroke.samples, stepsPerSegment: 8)

            // 2. 逐段绘制：每段用两个控制点 + 端点线宽构建可变宽度带状四边形。
            for i in 0..<(smoothed.count - 1) {
                let a = smoothed[i]
                let b = smoothed[i + 1]
                drawSegment(from: a, to: b, color: stroke.color)
            }

            // 3. 在每个插值点补一个圆帽：弯曲处相邻四边形的法线不连续，
            //    会产生三角缝隙造成视觉“断点/分割”，圆帽（直径=该点线宽）
            //    沿路径叠加后可完全填平接缝，保证线条连续。
            for point in smoothed {
                drawCap(at: point.point, width: point.width, color: stroke.color)
            }
        }
    }

    /// 单点笔迹：画一个圆点。
    private func drawSinglePoint(_ stroke: SlideshowStroke) {
        guard let sample = stroke.samples.first else { return }
        drawCap(at: sample.point, width: sample.width, color: stroke.color)
    }

    /// 画一段可变线宽的线段：以 a、b 为两个控制点，沿法线方向各扩展 width/2，
    /// 构成四边形填充，实现从 a 线宽到 b 线宽的平滑过渡。
    private func drawSegment(from a: SlideshowStrokePoint, to b: SlideshowStrokePoint, color: NSColor) {
        let dx = b.point.x - a.point.x
        let dy = b.point.y - a.point.y
        let length = hypot(dx, dy)
        guard length > 0.0001 else { return }

        // 单位法线（垂直于线段方向）。
        let nx = -dy / length
        let ny = dx / length

        let halfA = a.width / 2
        let halfB = b.width / 2

        let p0 = NSPoint(x: a.point.x + nx * halfA, y: a.point.y + ny * halfA)
        let p1 = NSPoint(x: a.point.x - nx * halfA, y: a.point.y - ny * halfA)
        let p2 = NSPoint(x: b.point.x - nx * halfB, y: b.point.y - ny * halfB)
        let p3 = NSPoint(x: b.point.x + nx * halfB, y: b.point.y + ny * halfB)

        let path = NSBezierPath()
        path.move(to: p0)
        path.line(to: p1)
        path.line(to: p2)
        path.line(to: p3)
        path.close()
        color.setFill()
        path.fill()
    }

    /// 画圆帽（端点圆点）。
    private func drawCap(at point: NSPoint, width: CGFloat, color: NSColor) {
        let r = width / 2
        let rect = NSRect(x: point.x - r, y: point.y - r, width: width, height: width)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    /// Catmull-Rom 样条平滑：对原始采样点插值，输出密集点（位置 + 线宽线性插值）。
    /// 注：smoothSamples 输出会保留首末采样宽度；首点起笔 width 由 beginStroke 设为
    /// startWidth（中等），经 EMA 在书写中渐变到速度对应的目标宽度。
    private static func smoothSamples(
        _ samples: [SlideshowStrokePoint],
        stepsPerSegment: Int
    ) -> [SlideshowStrokePoint] {
        guard samples.count >= 3 else { return samples }

        var result: [SlideshowStrokePoint] = []
        result.append(samples[0])

        // p1、p2 为当前段的两个端点；p0、p3 为两侧控制点。
        for i in 0..<(samples.count - 1) {
            let p0 = samples[max(0, i - 1)]
            let p1 = samples[i]
            let p2 = samples[i + 1]
            let p3 = samples[min(samples.count - 1, i + 2)]

            for step in 1...stepsPerSegment {
                let t = CGFloat(step) / CGFloat(stepsPerSegment)
                let x = Self.catmullRom(p0.point.x, p1.point.x, p2.point.x, p3.point.x, t)
                let y = Self.catmullRom(p0.point.y, p1.point.y, p2.point.y, p3.point.y, t)
                let width = p1.width + (p2.width - p1.width) * t
                result.append(SlideshowStrokePoint(point: NSPoint(x: x, y: y), width: width))
            }
        }
        return result
    }

    /// Catmull-Rom 样条插值（标准公式，tension=0.5）。
    private static func catmullRom(_ p0: CGFloat, _ p1: CGFloat, _ p2: CGFloat, _ p3: CGFloat, _ t: CGFloat) -> CGFloat {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }

    // MARK: - 橡皮擦提示

    /// 在橡皮当前位置画一个提示圆（半径 = 擦除半径）。
    private func drawEraserHint() {
        guard let position = eraserPosition else { return }
        let rect = NSRect(
            x: position.x - eraserRadius,
            y: position.y - eraserRadius,
            width: eraserRadius * 2,
            height: eraserRadius * 2
        )
        // 内部：半透明深色圆底，拖动时标示擦除带覆盖范围（浅色幻灯片上清晰）。
        NSColor.black.withAlphaComponent(0.60).setFill()
        let path = NSBezierPath(ovalIn: rect)
        path.fill()
        // 边框：白色细描边。白色圆环在深色幻灯片/深色笔迹上都清晰可辨，
        // 与底部工具栏白色图标体系一致。
        NSColor.white.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    // MARK: - 交互

    /// `viewPoint` 仅供橡皮提示圆定位（视图坐标）；`point` 为画布内容坐标。
    func beginStroke(at point: NSPoint, viewPoint: NSPoint) {
        switch tool {
        case .mouse:
            return
        case .pen:
            // 起笔采样用中等宽度：单击可见、书写时随速度自然过渡到粗细两端。
            let start = penWidthPreset.startWidth
            let sample = SlideshowStrokePoint(point: point, width: start)
            activeStroke = SlideshowStroke(samples: [sample], color: penColor)
        case .eraser:
            // 记录擦除前快照，一次拖动结束时若产生变化才提交撤销动作。
            eraserBeforeSnapshot = slideAnnotations.strokes
            eraserPosition = viewPoint
            lastErasePoint = point
            // 每次落笔重置默认半径与上一帧位移，避免上一笔快速划动留下的
            // 粗半径/加速基线误伤本笔（首帧位移与 0 比较，起步即快视为加速）。
            eraserRadius = EraserMetrics.defaultRadius
            eraserLastFrameDistance = 0
            erase(from: point, to: point)
        }
        needsDisplay = true
    }

    /// `viewPoint` 仅供橡皮提示圆定位（视图坐标）；`point` 为画布内容坐标
    /// （漫游开启时已含偏移换算），绘制与擦除一律使用内容坐标。
    func continueStroke(to point: NSPoint, viewPoint: NSPoint) {
        switch tool {
        case .mouse:
            return
        case .pen:
            appendPenSample(to: point)
        case .eraser:
            eraserPosition = viewPoint
            if let last = lastErasePoint {
                // 半径由速度 + 加速度共同决定：
                // - speedFactor：本帧位移越大目标越大（快划大扫、慢划精修）；
                // - surgeFactor：本帧比上一帧快出的增量越大越「突然加速」，在
                //   速度基础上额外放大，让爆发式挥动立刻撑大擦除带；
                // - 不对称 EMA：变大快（跟手），变小慢（加速结束后缓缓回缩）。
                let distance = hypot(point.x - last.x, point.y - last.y)
                let speedFactor = min(distance / EraserMetrics.fastMoveDistance, 1)
                let surge = max(0, distance - eraserLastFrameDistance)
                let surgeFactor = min(surge / EraserMetrics.surgeDistance, 1)
                let drive = min(1, speedFactor + surgeFactor * EraserMetrics.surgeWeight)
                let targetRadius = EraserMetrics.minRadius
                    + (EraserMetrics.maxRadius - EraserMetrics.minRadius) * drive
                let smoothing = targetRadius >= eraserRadius
                    ? EraserMetrics.growSmoothing
                    : EraserMetrics.shrinkSmoothing
                eraserRadius += (targetRadius - eraserRadius) * smoothing
                eraserLastFrameDistance = distance
                // 沿上一擦除点到当前点做线段采样，避免快速拖动漏擦。
                let interpolated = Self.interpolatedPoints(from: last, to: point, maxStep: eraserRadius * 0.5)
                for i in 1..<interpolated.count {
                    erase(from: interpolated[i - 1], to: interpolated[i])
                }
            }
            lastErasePoint = point
        }
        needsDisplay = true
    }

    /// 追加画笔采样：低于最小间距的事件丢弃；目标线宽由移动速度决定，EMA 平滑逼近。
    private func appendPenSample(to point: NSPoint) {
        guard var stroke = activeStroke, let last = stroke.samples.last else { return }
        let distance = hypot(point.x - last.point.x, point.y - last.point.y)
        guard distance >= PenMetrics.minSampleDistance else { return }

        // 移动越快目标线宽越细（模拟快速出锋），移动越慢越粗（模拟停顿蓄墨）；
        // 上下限取自当前粗细预设，EMA 平滑避免逐事件噪声导致线宽抖动。
        let speedFactor = min(distance / PenMetrics.fastMoveDistance, 1)
        let target = penWidthPreset.minWidth
            + (penWidthPreset.maxWidth - penWidthPreset.minWidth) * (1 - speedFactor)
        let width = max(
            penWidthPreset.minWidth,
            min(penWidthPreset.maxWidth, last.width + (target - last.width) * PenMetrics.widthSmoothing)
        )
        stroke.samples.append(SlideshowStrokePoint(point: point, width: width))
        activeStroke = stroke
    }

    /// 结束一笔：笔迹落盘到当前页批注；橡皮结束清空提示。
    func endStroke() {
        switch tool {
        case .mouse:
            return
        case .pen:
            if let stroke = activeStroke, !stroke.samples.isEmpty {
                // 提交改动前后快照，由控制器统一撤销链记录（撤销恢复到本笔之前）。
                let before = slideAnnotations.strokes
                slideAnnotations.strokes.append(stroke)
                onActionCommitted?(before, slideAnnotations.strokes)
            }
            activeStroke = nil
        case .eraser:
            // 一次拖动结束：若相对快照产生了实际擦除，才提交一次撤销动作。
            if let snapshot = eraserBeforeSnapshot,
               !Self.strokesEqual(snapshot, slideAnnotations.strokes) {
                onActionCommitted?(snapshot, slideAnnotations.strokes)
            }
            eraserBeforeSnapshot = nil
            eraserPosition = nil
            lastErasePoint = nil
        }
        needsDisplay = true
        onStrokeEnded?()
    }

    // MARK: - 橡皮擦（区域抹除）

    /// 沿 from→to 线段（半径 eraserRadius 的擦除带）剔除笔迹：
    /// 只在真正被擦到的位置断开，未擦到的笔迹保持原始采样连续性不变。
    /// 注意：此处只改内存笔迹；撤销动作由 endStroke（一次拖动结束）统一提交。
    private func erase(from: NSPoint, to: NSPoint) {
        var mutated = false
        var newStrokes: [SlideshowStroke] = []

        for stroke in slideAnnotations.strokes {
            let fragments = Self.fragments(
                of: stroke.samples,
                erasingNear: from,
                to,
                radius: eraserRadius
            )
            if fragments.count != 1 || fragments[0].count != stroke.samples.count {
                mutated = true
            }
            for fragment in fragments {
                newStrokes.append(
                    SlideshowStroke(samples: fragment, color: stroke.color)
                )
            }
        }

        if mutated {
            slideAnnotations.strokes = newStrokes
        }
    }

    /// 把一条笔迹按擦除带切分：采样点落在带内、或相邻采样连线与擦除带相交处断开，
    /// 返回未被擦除的连续片段。不触碰未被擦到的区域。
    private static func fragments(
        of samples: [SlideshowStrokePoint],
        erasingNear a: NSPoint,
        _ b: NSPoint,
        radius: CGFloat
    ) -> [[SlideshowStrokePoint]] {
        let radiusSquared = radius * radius
        var result: [[SlideshowStrokePoint]] = []
        var current: [SlideshowStrokePoint] = []

        for sample in samples {
            if distanceSquared(from: sample.point, toSegment: a, b) <= radiusSquared {
                // 该采样点被擦除：在这里断开当前片段。
                if !current.isEmpty {
                    result.append(current)
                    current = []
                }
                continue
            }
            if let last = current.last,
               segmentTouchesBand(from: last.point, to: sample.point, bandStart: a, bandEnd: b, radius: radius) {
                // 两点间的墨迹穿过擦除带：断开，当前点另起新片段。
                result.append(current)
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    /// 判断笔迹线段 p→q 是否与擦除带（线段 ab 附近 radius 范围）相交。
    private static func segmentTouchesBand(
        from p: NSPoint,
        to q: NSPoint,
        bandStart a: NSPoint,
        bandEnd b: NSPoint,
        radius: CGFloat
    ) -> Bool {
        if segmentsIntersect(p, q, a, b) {
            return true
        }
        let radiusSquared = radius * radius
        return distanceSquared(from: p, toSegment: a, b) <= radiusSquared
            || distanceSquared(from: q, toSegment: a, b) <= radiusSquared
            || distanceSquared(from: a, toSegment: p, q) <= radiusSquared
            || distanceSquared(from: b, toSegment: p, q) <= radiusSquared
    }

    /// 两线段是否严格相交（跨立判定）。
    private static func segmentsIntersect(_ p1: NSPoint, _ p2: NSPoint, _ p3: NSPoint, _ p4: NSPoint) -> Bool {
        func orientation(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let d1 = orientation(p3, p4, p1)
        let d2 = orientation(p3, p4, p2)
        let d3 = orientation(p1, p2, p3)
        let d4 = orientation(p1, p2, p4)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
            && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    /// 点到线段的最短距离平方。
    private static func distanceSquared(from p: NSPoint, toSegment a: NSPoint, _ b: NSPoint) -> CGFloat {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let abLen2 = abx * abx + aby * aby

        if abLen2 < 0.0001 {
            let dx = p.x - a.x
            let dy = p.y - a.y
            return dx * dx + dy * dy
        }

        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / abLen2))
        let cx = a.x + t * abx
        let cy = a.y + t * aby
        let dx = p.x - cx
        let dy = p.y - cy
        return dx * dx + dy * dy
    }

    /// 在 from→to 之间插值采样点（用于橡皮拖动补点，避免快速移动漏擦）。
    private static func interpolatedPoints(from: NSPoint, to: NSPoint, maxStep: CGFloat) -> [NSPoint] {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let dist = hypot(dx, dy)
        guard dist > maxStep else { return [from, to] }

        let count = Int(ceil(dist / maxStep))
        var result: [NSPoint] = []
        for i in 0...count {
            let t = CGFloat(i) / CGFloat(count)
            result.append(NSPoint(x: from.x + dx * t, y: from.y + dy * t))
        }
        return result
    }

    // MARK: - 撤销 / 还原 / 清空

    /// 丢弃进行中的笔画/橡皮会话状态（不提交任何撤销动作）。
    /// 翻页时调用：拖拽中翻页（WPS 自动放映/遥控翻页可在未松开鼠标时触发）
    /// 后 slideAnnotations 会被整体替换为新页数据，若不清这些状态，松笔时
    /// 画笔会落进新页、橡皮会拿旧页快照与新页笔迹比对提交出跨页污染动作。
    func discardActiveStroke() {
        guard activeStroke != nil || eraserBeforeSnapshot != nil || eraserPosition != nil else { return }
        activeStroke = nil
        eraserBeforeSnapshot = nil
        eraserPosition = nil
        lastErasePoint = nil
        needsDisplay = true
    }

    /// 判断两页笔迹是否等价（用于橡皮擦结束后判断是否产生有效改动）。
    private static func strokesEqual(_ a: [SlideshowStroke], _ b: [SlideshowStroke]) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count {
            let sa = a[i].samples
            let sb = b[i].samples
            guard sa.count == sb.count else { return false }
            for j in 0..<sa.count {
                if sa[j].point.x != sb[j].point.x || sa[j].point.y != sb[j].point.y {
                    return false
                }
            }
        }
        return true
    }

    /// 清空当前画布批注（可撤销，经统一撤销链）。
    func clearCurrentPage() {
        guard !slideAnnotations.strokes.isEmpty else { return }
        let before = slideAnnotations.strokes
        slideAnnotations.strokes.removeAll()
        needsDisplay = true
        onActionCommitted?(before, [])
        onStrokeEnded?()
    }
}

/// 放映批注相关窗口的层级体系（由低到高）：
/// - `shield`：预览图栏防穿透遮罩，覆盖整屏、完全透明——预览显示期间拦截
///   落到外部进程的点击用于收起图栏（替代辅助功能 global 监听）；
/// - `magnifier`：放大镜，压在批注画布**之下**——画布拦截（画笔/橡皮态）时
///   放大镜收不到事件，只有画布穿透（鼠标态）时才能点住拖动调整位置；
/// - `canvas`：放映批注画布 overlay，覆盖 WPS 放映窗口；
/// - `tool`：自建工具窗口（草稿纸 / 计时器），高于放映画板、低于交互 UI——
///   草稿纸可被画笔命中书写、又不会盖住工具栏等操作界面；
/// - `chrome`：工具栏 / 翻页栏 / 二级菜单 / 退出弹窗等交互 UI。
enum SlideshowFloatingLevel {
    static let shield = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 2)
    static let magnifier = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
    static let canvas = NSWindow.Level.screenSaver
    static let tool = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    static let chrome = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
}

// MARK: - 放映窗口透明覆盖层

/// 精确覆盖在 WPS 放映窗口之上的透明窗口：`ignoresMouseEvents = true`
/// 让鼠标与触摸板事件完全穿透到 WPS，不影响放映交互；批注笔迹绘制在上层画布。
/// 覆盖区域由加载项上报的放映窗口位置决定（通常为整屏）。
@MainActor
final class SlideshowAnnotationOverlayWindow: NSPanel {
    let canvas = SlideshowAnnotationCanvasView()

    init(contentFrame: NSRect) {
        super.init(
            contentRect: contentFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        level = SlideshowFloatingLevel.canvas
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true

        canvas.frame = NSRect(origin: .zero, size: contentFrame.size)
        canvas.autoresizingMask = [.width, .height]
        contentView = canvas
    }

    /// 切换鼠标/触摸板事件是否穿透：
    /// - `true`（鼠标模式）：事件穿透到 WPS，不影响放映交互；
    /// - `false`（画笔/橡皮模式）：事件被画布拦截用于绘制批注。
    func setMousePassthrough(_ passthrough: Bool) {
        ignoresMouseEvents = passthrough
    }

    /// 拦截模式下的滚动恢复延迟：滚动事件流（含惯性期）中每个事件都会重置该
    /// 计时，事件停止后约一个延迟才恢复拦截。太短会在滚动间隙反复穿透/拦截、
    /// 且有把恢复后首帧滚动误吞的风险；太长则滚动刚停就点按会穿透给 WPS。
    private enum ScrollForwardMetrics {
        static let restoreDelay: TimeInterval = 0.05
    }

    private var scrollRestoreWorkItem: DispatchWorkItem?

    private static var loggedScrollPermissionIssue = false

    /// 把滚动事件转发给下层 WPS 放映窗口（画笔/橡皮拦截模式下调用）。
    ///
    /// 拦截期间 overlay 吞掉了本应到 WPS 的滚动，做法：把自身临时穿透 →
    /// 将原滚动事件重放回系统（CGEventPost，命中鼠标位置的下层窗口）→
    /// 滚动结束后恢复拦截。事件重放需要辅助功能或输入监控权限（工程截图
    /// 选区已依赖同一权限）；无权限时滚动行为与旧版一致（被拦截），仅记录
    /// 一次日志便于排查。
    func forwardScrollToUnderlying(_ event: NSEvent) {
        guard AccessibilityPermission.isTrusted() || CGPreflightPostEventAccess() else {
            if !Self.loggedScrollPermissionIssue {
                Self.loggedScrollPermissionIssue = true
                SlideshowAnnotationLog.info("滚轮转发被跳过：缺少辅助功能/输入监控权限，批注中滚动无法到达 WPS")
            }
            return
        }
        // 先让位：重放的事件按系统命中分发，此刻自身必须已穿透才不会回环到本窗。
        scrollRestoreWorkItem?.cancel()
        ignoresMouseEvents = true
        event.cgEvent?.post(tap: .cghidEventTap)
        let item = DispatchWorkItem { [weak self] in self?.restoreScrollInterception() }
        scrollRestoreWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ScrollForwardMetrics.restoreDelay,
            execute: item
        )
    }

    /// 滚动停止后恢复拦截；若期间工具已切回鼠标则保持穿透（由 setTool 统一维护）。
    private func restoreScrollInterception() {
        scrollRestoreWorkItem = nil
        guard canvas.tool != .mouse else { return }
        ignoresMouseEvents = false
    }

    func show() {
        orderFrontRegardless()
    }
}

// MARK: - 三段式底部工具栏（三个独立面板窗口）

/// 工具栏通用面板：一个圆角深色卡片底的可交互浮动窗口，承载一组图标按钮。
/// 布局体系：底板**由内部元素撑起**——按钮两两紧贴、左右无间距，两端各留
/// Metrics.edgePadding 的可点击边距填充（点击自动路由到最近的图标按钮）；
/// 底板由容器**自绘**（非系统玻璃材质），弧外像素全透明、WindowServer 层
/// 直接穿透；中间工具栏与左/右翻页栏共用这一套「紧贴胶囊」观感。
@MainActor
class SlideshowAnnotationPanelWindow: FloatingOverlayPanel {
    enum Metrics {
        /// 图标类矩形边长：长宽一致的正方形，矩形即点击范围。
        static let buttonSize: CGFloat = 40
        /// 玻璃圆角半径：等于半高时两端呈半圆（高 40 → 半径 20）。
        static let cornerRadius: CGFloat = 20
        static let bottomInset: CGFloat = 18
        /// 左右端边距填充：玻璃条两端各留出的可点击空白，避免最边的按钮
        /// 图标紧贴玻璃圆角；点击落在填充区时自动路由到最近的图标按钮。
        static let edgePadding: CGFloat = 10
        /// 页码标签宽度：比图标略宽（60 vs 40），容纳三位/三位斜分数；
        /// 整条翻页栏由 [‹][页码][›] 撑起。
        static let pageLabelWidth: CGFloat = 60
        /// 图标对角线归一系数：字形包围盒对角线 = 按钮短边 × 该系数。
        /// 0.64：40pt 按钮下方形图标（如退出圆叉）约 18pt 见方、细高箭头
        /// （翻页 chevron）约 23pt 高——对角线一致，视觉占幅统一。
        static let iconDiagonalFraction: CGFloat = 0.64
        /// 工具栏玻璃底整体透明度（1 为不透明，越低越透）。
        /// 0.72：左/中/右三栏常驻工具条既保留深色玻璃观感，又更透出幻灯片内容。
        static let barAlpha: CGFloat = 0.72
    }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        configureFloatingOverlay()
    }

    override func configureFloatingOverlay() {
        super.configureFloatingOverlay()
        // 强制深色外观：工具栏玻璃底（NSVisualEffectView hudWindow 材质 / 系统
        // 液态玻璃）的明暗默认跟随系统深浅色外观，浅色系统下会整体渲染成浅色
        // 毛玻璃、与深色自绘图标/白色文字不协调。批注工具栏按深色设计，
        // 固定 .darkAqua（含子视图 effectiveAppearance），不随系统切换。
        appearance = NSAppearance(named: .darkAqua)
        // 工具栏需稳定覆盖在批注层与自建工具层之上，保证可点击；显式抬到
        // chrome 层（screenSaver + 2），避免与覆盖层/工具层同 level 的 z-order 竞争。
        level = SlideshowFloatingLevel.chrome
        // 背景透明度：工具栏玻璃底整体半透明，放映时隐约透出幻灯片内容，
        // 避免常驻工具条视觉过重（macOS 15 / 26 双 SDK 统一的实现方式）。
        alphaValue = Metrics.barAlpha
        // 禁用系统阴影：非不透明窗口的 WindowServer 阴影在全屏放映上层
        // 收起/移动时会漏失效留下淡色残影，放映浮层家族统一关闭（同二级菜单）。
        hasShadow = false
    }

    /// 用给定视图组布局面板内容：底板**完全由内部元素撑起**——
    /// 高度取内容最大高度（图标类 40）、宽度取内容宽度和 + 两端边距填充
    /// （Metrics.edgePadding）；元素之间紧贴（左右无间距），四角由自绘圆角
    /// 裁切（弧外像素全透明、系统层穿透）。两端填充区可点击：自动路由到
    /// 最近（最左/最右）的图标按钮，保证最边的按钮图标不紧贴圆角、且边缘
    /// 留白不是「点了没反应」的死区。视图未预设尺寸时按 Metrics 兜底。
    func install(_ views: [NSView]) {
        for view in views {
            if view.frame.width <= 0 { view.frame.size.width = Metrics.buttonSize }
            if view.frame.height <= 0 { view.frame.size.height = Metrics.buttonSize }
        }
        let height = views.map(\.frame.height).max() ?? Metrics.buttonSize
        let contentWidth = views.reduce(CGFloat(0)) { $0 + $1.frame.width }
        let width = contentWidth + Metrics.edgePadding * 2

        // 背景**自绘**在容器内（深色实底圆角卡片，与计时器/工具菜单同族），
        // 刻意不用系统玻璃材质：系统材质（NSGlassEffectView / behind-window
        // 毛玻璃）的可命中区域由系统按视图 frame 决定，圆角只是视觉裁剪，
        // 弧外像素照样收事件；自绘让弧外像素 alpha=0，WindowServer 直接
        // 穿透——画笔模式由下层画布拦截、鼠标模式直达幻灯片，弧外彻底
        // 「不属于工具栏」（与计时器/草稿纸的弧外行为一致）。
        let container = SlideshowPanelContentView(
            frame: NSRect(origin: .zero, size: NSSize(width: width, height: height))
        )

        var x = Metrics.edgePadding
        for view in views {
            // 垂直居中：页码文本块矮于图标类时，文字行中心仍落在玻璃中线上。
            view.frame.origin = NSPoint(x: x, y: (height - view.frame.height) / 2)
            container.addSubview(view)
            x += view.frame.width
        }
        // 边距填充的点击路由目标：内容序列里最左 / 最右的图标按钮
        // （工具栏 = 鼠标/退出演示，翻页栏 = 上一页/下一页）。
        container.leadingClickTarget = views.compactMap { $0 as? SlideshowToolbarIconButton }.first
        container.trailingClickTarget = views.compactMap { $0 as? SlideshowToolbarIconButton }.last

        contentView = container
        setContentSize(NSSize(width: width, height: height))
    }

    /// 定位到屏幕底部：`anchor` 为 `.leading`（左）、`.center`（中）、`.trailing`（右）。
    enum Anchor {
        case leading
        case center
        case trailing
    }

    /// 定位到屏幕底部：`anchor` 为 `.leading`（左）、`.center`（中）、`.trailing`（右）。
    /// `horizontalMargin` 控制左右面板距屏幕水平边缘的距离（垂直统一贴 Metrics 底边距，
    /// 保证左/中/右三栏底边齐平），翻页面板可传更小值使其更贴近屏幕角落。
    func positionAtBottom(
        of screenFrame: NSRect,
        anchor: Anchor,
        horizontalMargin: CGFloat = Metrics.bottomInset * 1.5
    ) {
        let size = frame.size
        let x: CGFloat
        switch anchor {
        case .leading:
            x = screenFrame.minX + horizontalMargin
        case .center:
            x = screenFrame.midX - size.width / 2
        case .trailing:
            x = screenFrame.maxX - size.width - horizontalMargin
        }
        let origin = NSPoint(x: x, y: screenFrame.minY + Metrics.bottomInset)
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func show() {
        // 轻微进场：淡入（至 barAlpha）+ 从下方 6pt 上浮回位。
        fadeInWindow(self, targetAlpha: Metrics.barAlpha, rise: 6, duration: 0.15)
    }

    /// 轻微退场：淡出 + 下沉回落（收起批注层/放映结束时调用）。
    /// 动画结束后才真正 orderOut，期间强持有窗口保证退场完整。
    func dismissAnimated() {
        fadeOutWindow(self, drop: 6, duration: 0.12)
    }
}

/// 面板内容容器（直接作为面板窗口的 contentView）：自绘胶囊底 + 承载按钮行，
/// 并接管**两端边距填充区**的点击——命中时自动路由到最近（最左/最右）的
/// 图标按钮，与真实点击同路径（动作 + 弹跳反馈）。按钮/页码标签等子视图
/// 区域照常透传给子视图处理。
@MainActor
final class SlideshowPanelContentView: NSView {
    /// 左端填充命中的路由目标（内容序列最左的图标按钮）。
    var leadingClickTarget: SlideshowToolbarIconButton?
    /// 右端填充命中的路由目标（内容序列最右的图标按钮）。
    var trailingClickTarget: SlideshowToolbarIconButton?

    override var isOpaque: Bool { false }

    /// 自绘胶囊底：深色实底圆角卡片 + 发丝描边（与计时器/工具菜单同族）。
    /// 刻意不用系统玻璃材质——材质的可命中区域由系统按视图 frame 决定，
    /// 圆角弧外像素收得到事件；自绘让弧外 alpha=0，WindowServer 直接穿透。
    override func draw(_ dirtyRect: NSRect) {
        let path = Self.hitShape(for: bounds)
        NSColor.black.withAlphaComponent(0.75).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        let hairline = Self.hitShape(for: bounds.insetBy(dx: 0.5, dy: 0.5))
        hairline.lineWidth = 1
        hairline.stroke()
    }

    /// 点击落在左端填充（首按钮左缘之左）或右端填充（末按钮右缘之右）时
    /// 由容器接管；其余区域走默认 hitTest 递归，事件正常到达按钮/标签。
    override func hitTest(_ point: NSPoint) -> NSView? {
        // hitTest 的 point 在父视图坐标系：换算到本容器坐标系再判断。
        let local = convert(point, from: superview)
        // 圆角形状收口：弧外像素本已全透明（WindowServer 层穿透，事件根本
        // 不进窗口），这里再按同参圆角矩形兜底，挡住按钮 frame 与弧形的
        // 重叠区，双保险保证「裁掉的部分不响应」。
        guard Self.hitShape(for: bounds).contains(local) else { return nil }
        guard leadingClickTarget != nil, trailingClickTarget != nil else {
            return super.hitTest(point)
        }
        if paddingClickTarget(atX: local.x) != nil {
            return self
        }
        return super.hitTest(point)
    }

    /// x 落在两端填充区时返回对应的路由点击目标
    /// （首按钮左缘之左 → leading / 末按钮右缘之右 → trailing，否则 nil）。
    /// hitTest 与 mouseDown 共用同一判定，边界条件单点维护。
    private func paddingClickTarget(atX x: CGFloat) -> SlideshowToolbarIconButton? {
        if let leading = leadingClickTarget, x < leading.frame.minX { return leading }
        if let trailing = trailingClickTarget, x > trailing.frame.maxX { return trailing }
        return nil
    }

    /// 命中/绘制形状：圆角矩形（半径取面板 Metrics.cornerRadius，
    /// 高 40 → 半径 20 → 两端半圆端帽）。
    private static func hitShape(for rect: NSRect) -> NSBezierPath {
        let radius = SlideshowAnnotationPanelWindow.Metrics.cornerRadius
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let target = paddingClickTarget(atX: local.x) {
            target.performRoutedClick()
            return
        }
        super.mouseDown(with: event)
    }

    /// 两端填充区同样显示手型光标，提示「可点」。
    override func resetCursorRects() {
        if let leading = leadingClickTarget, leading.frame.minX > 0 {
            addCursorRect(
                NSRect(x: 0, y: 0, width: leading.frame.minX, height: bounds.height),
                cursor: .pointingHand
            )
        }
        if let trailing = trailingClickTarget, trailing.frame.maxX < bounds.maxX {
            addCursorRect(
                NSRect(x: trailing.frame.maxX, y: 0, width: bounds.maxX - trailing.frame.maxX, height: bounds.height),
                cursor: .pointingHand
            )
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

// MARK: - 工具按钮面板（底部居中）

/// 底部居中面板：鼠标 / 画笔 / 橡皮 / 撤销 / 还原 / 退出演示。
///
/// 画笔与橡皮是「带二级菜单的工具」：**首次点选只激活工具**（切换画笔/橡皮
/// 功能、不弹菜单），**已选中时再点同一按钮**才弹出/收起各自的设置胶囊——
/// 画笔弹出设置胶囊（上行红/蓝/黑三色色板，下行细/中/粗三档 S 型笔迹预览），
/// 橡皮弹出「清空当页」胶囊；胶囊展开期间点击胶囊外的任意位置自动收起
/// （笔菜单内选色/选粗细保持展开，橡皮菜单「清空草稿纸/清空当页」点击后收起并切回画笔）；
/// 两个胶囊互斥，同时至多显示一个。
@MainActor
final class SlideshowAnnotationToolsWindow: SlideshowAnnotationPanelWindow {
    var onToolSelected: ((SlideshowAnnotationTool) -> Void)?
    /// 用户从颜色行点选了画笔颜色（调用方应用到画布 penColor）。
    var onColorSelected: ((NSColor) -> Void)?
    /// 用户从粗细行点选了画笔粗细预设（调用方应用到画布 penWidthPreset）。
    var onWidthSelected: ((Int) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onExit: (() -> Void)?
    /// 橡皮二级菜单「清空草稿纸」。
    var onClearScratchpad: (() -> Void)?
    /// 橡皮二级菜单「清空当页」。
    var onClearPage: (() -> Void)?
    /// 用户在「工具」二级菜单中选择了自建工具（截图/计时器/放大镜/草稿纸），
    /// 由控制器负责工具的创建/切换/关闭。
    var onToolItemSelected: ((SlideshowToolkitItem) -> Void)?

    // 鼠标/橡皮按钮带选中态：isSelected 驱动「轮廓 ↔ 填充」图标切换（不再画圆形选中底）。
    private let mouseButton = SlideshowToolbarIconButton(
        kind: .toggling(offResource: "hand.point.up", onResource: "hand.point.up.fill"),
        accessibilityDescription: "鼠标"
    )
    // 画笔按钮带选中态：未选中显示轮廓图标（白色）；选中切换为 fill 图标——
    // 整体以当前笔色着色、轻微缩小并以白色描边勾边（深色笔在深底工具栏上
    // 依旧清晰），选中态所见即所得。
    private let penButton = SlideshowToolbarIconButton(
        kind: .toggling(offResource: "paintbrush.pointed", onResource: "paintbrush.pointed.fill"),
        accessibilityDescription: "画笔"
    )
    private let eraserButton = SlideshowToolbarIconButton(
        kind: .toggling(offResource: "eraser", onResource: "eraser.fill"),
        accessibilityDescription: "橡皮"
    )
    // 无选中态按钮：固定单一符号，永不切换。
    private let undoButton = SlideshowToolbarIconButton(kind: .fixed(svgResource: "arrow.uturn.backward"), accessibilityDescription: "撤销")
    private let redoButton = SlideshowToolbarIconButton(kind: .fixed(svgResource: "arrow.uturn.forward"), accessibilityDescription: "还原")
    /// 「工具」入口（briefcase）：点击弹出自建工具二级菜单（截图/计时器/
    /// 放大镜/草稿纸）。与撤销/还原一样无选中态，只负责菜单显隐。
    private let toolsButton = SlideshowToolbarIconButton(kind: .fixed(svgResource: "briefcase"), accessibilityDescription: "工具")
    private let exitButton = SlideshowToolbarIconButton(kind: .fixed(svgResource: "xmark.circle"), accessibilityDescription: "退出演示")

    private var toolButtons: [SlideshowAnnotationTool: SlideshowToolbarIconButton] = [:]

    /// 画笔设置胶囊（颜色行 + 粗细行）/ 橡皮「清空当页」胶囊：仅在对应工具
    /// **已选中**时再点按钮才弹出/收起；首次点选只激活工具、不弹胶囊。两胶囊
    /// 互斥显隐，显示期间点击胶囊外的任意区域（其它工具、画布、翻页条等）
    /// 一律自动收起。
    private let penMenuWindow = SlideshowPenMenuWindow()
    private let eraserMenuWindow = SlideshowEraserMenuWindow()
    /// 自建工具二级菜单：截图 / 计时器 / 放大镜 / 草稿纸。与笔/橡皮胶囊互斥。
    private let toolsMenuWindow = SlideshowToolkitMenuWindow()

    /// 当前画笔颜色索引（与画布 penColor 一致；画笔颜色只经本面板变更，
    /// 初始为调色板首色红色）。每次显示颜色胶囊时同步选中圈。
    private var penColorIndex = 0
    /// 当前画笔粗细索引（与画布 penWidthPreset 一致；初始为中档 = 历史默认参数）。
    /// 每次显示粗细胶囊行时同步选中圈。
    private var penWidthIndex = SlideshowPenWidthPreset.defaultIndex

    /// 当前激活的工具：驱动「未选中点按只切换功能 / 已选中再点切胶囊显隐」
    /// 的判定。与按钮图标选中态同一处（setSelectedButton）维护，保持同步。
    private var currentTool: SlideshowAnnotationTool = .mouse

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: Metrics.buttonSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        toolButtons = [
            .mouse: mouseButton,
            .pen: penButton,
            .eraser: eraserButton
        ]

        mouseButton.onClick = { [weak self] in self?.selectTool(.mouse) }
        penButton.onClick = { [weak self] in self?.selectTool(.pen) }
        eraserButton.onClick = { [weak self] in self?.selectTool(.eraser) }
        undoButton.onClick = { [weak self] in
            self?.hideToolMenus()
            self?.onUndo?()
        }
        redoButton.onClick = { [weak self] in
            self?.hideToolMenus()
            self?.onRedo?()
        }
        toolsButton.onClick = { [weak self] in
            guard let self else { return }
            // 工具按钮与笔/橡皮一样是「二级菜单入口」：点击直接切菜单显隐；
            // 弹出前先收起其它两个胶囊（互斥）。
            self.toggleToolMenu(self.toolsMenuWindow, above: self.toolsButton, logName: "工具二级菜单")
        }
        exitButton.onClick = { [weak self] in
            self?.hideToolMenus()
            self?.onExit?()
        }
        exitButton.tintColor = .systemRed

        penMenuWindow.onColorSelected = { [weak self] index, color in
            guard let self else { return }
            self.penColorIndex = index
            // 选色只发生在画笔选中态（画笔设置胶囊仅画笔激活时弹出）：
            // 选中态 fill 图标整体同步着刚选中的笔色（白色描边恒定）。
            self.penButton.tintColor = color
            self.onColorSelected?(color)
        }
        penMenuWindow.onWidthSelected = { [weak self] index in
            guard let self else { return }
            self.penWidthIndex = index
            self.onWidthSelected?(index)
        }
        eraserMenuWindow.onClearScratchpad = { [weak self] in
            self?.onClearScratchpad?()
            // 清空草稿纸后同样自动切回画笔：方便紧接着继续批注，无需再手动点一次笔。
            // 只切换工具、不弹颜色胶囊（胶囊只在用户显式点击工具按钮时弹出）。
            self?.switchToolQuietly(.pen)
        }
        eraserMenuWindow.onClearPage = { [weak self] in
            self?.onClearPage?()
            // 清空当页后自动切回画笔：方便紧接着继续批注，无需再手动点一次笔。
            // 只切换工具、不弹颜色胶囊（胶囊只在用户显式点击工具按钮时弹出）。
            self?.switchToolQuietly(.pen)
        }
        toolsMenuWindow.onItemSelected = { [weak self] item in
            guard let self else { return }
            // 条目点击：菜单已自行收起，把选择交给控制器处理工具的创建/切换。
            self.onToolItemSelected?(item)
        }

        install([mouseButton, penButton, eraserButton, undoButton, redoButton, toolsButton, exitButton])
        selectTool(.mouse)
    }

    // MARK: 工具选择与胶囊显隐

    /// 用户点击工具按钮，按「是否已是当前工具」分流：
    /// - 未选中（非当前工具）：只进入选中态并切换对应功能，**不**展开二级菜单，
    ///   同时收起任何残留胶囊（点工具按钮本身也属于点击胶囊外的区域）；
    /// - 已选中（当前工具）：再点才切换该工具二级菜单的显示/隐藏。
    private func selectTool(_ tool: SlideshowAnnotationTool) {
        let wasCurrent = (tool == currentTool)
        setSelectedButton(tool)
        guard wasCurrent else {
            hideToolMenus()
            onToolSelected?(tool)
            return
        }
        switch tool {
        case .pen:
            toggleToolMenu(penMenuWindow, above: penButton, logName: "画笔设置胶囊")
        case .eraser:
            toggleToolMenu(eraserMenuWindow, above: eraserButton, logName: "橡皮浮层")
        case .mouse:
            // 鼠标无二级菜单：兜底收起残留胶囊即可。
            hideToolMenus()
        }
        onToolSelected?(tool)
    }

    /// 程序化切换工具（不弹胶囊）：只更新选中态并通知控制器。
    /// 胶囊显隐只跟随用户对工具按钮的显式点击，避免后台自动切换
    /// （如清空当页后自动切回画笔）弹出干扰性 UI。
    private func switchToolQuietly(_ tool: SlideshowAnnotationTool) {
        setSelectedButton(tool)
        onToolSelected?(tool)
    }

    private func setSelectedButton(_ tool: SlideshowAnnotationTool) {
        // currentTool 与按钮图标选中态同步维护：所有工具切换路径
        // （selectTool / switchToolQuietly）都经过这里，「再点判当前」判定始终准确。
        currentTool = tool
        // isSelected 驱动鼠标/橡皮/画笔按钮的图标形态切换（轮廓 ↔ 填充）；
        // 无选中态按钮（撤销/还原/退出）不受影响。
        for (key, button) in toolButtons {
            button.isSelected = (key == tool)
        }
        // 画笔按钮选中态 = fill 图标轻微缩小 + 笔色整体着色 + 白色描边勾边
        // （深色笔在深底工具栏上依旧清晰）；未选中恢复轮廓图标的默认外观。
        let isPen = (tool == .pen)
        penButton.iconScale = isPen ? 0.88 : 1
        penButton.tintColor = isPen ? SlideshowPenPalette.ordered[penColorIndex].color : .white
        penButton.iconOutline = isPen ? .white : nil
    }

    /// 切换指定工具胶囊显隐：可见则收起；不可见则先收起另一胶囊再显示当前。
    /// 仅在「已选中工具再点」时由 selectTool 调用——菜单显隐与按钮选中态严格
    /// 绑定（未选中点按只切换工具、不碰菜单），不再对任意点击都做 toggle。
    private func toggleToolMenu(_ menu: SlideshowToolMenuWindow, above button: NSButton, logName: String) {
        // 用 isOpen（同步意图）而非 isVisible 判定：退场动画未走完时窗口仍可见，
        // 按 isVisible 会把「正在收起」误判为「已展开」而再次 hide（动画叠加），
        // 也无法在动画期间正确重新进场。
        if menu.isOpen {
            SlideshowAnnotationLog.info("\(logName): 已可见, 收起")
            menu.hide()
            return
        }
        hideToolMenus()
        // 画笔设置胶囊每次显示前同步当前笔色与粗细的选中圈。
        (menu as? SlideshowPenMenuWindow)?.setSelections(
            colorIndex: penColorIndex,
            widthIndex: penWidthIndex
        )
        guard let window = button.window else { return }
        let frameInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenFrame = window.convertToScreen(frameInWindow)
        menu.show(above: buttonScreenFrame, anchor: window)
        SlideshowAnnotationLog.info("\(logName): 已显示(工具按钮上方)")
    }

    /// 收起全部工具浮层菜单：点其它工具（鼠标）/ 撤销 / 还原 / 退出 / 收起批注层时调用。
    func hideToolMenus() {
        eraserMenuWindow.hide()
        penMenuWindow.hide()
        toolsMenuWindow.hide()
    }

    /// 立即关闭全部工具浮层菜单（**不播退场动画**）：截图前临时隐藏使用——
    /// 退场动画期间的窗口仍短暂在屏，可能被捕获入镜；直接离屏一步到位。
    func hideToolMenusImmediately() {
        eraserMenuWindow.closeImmediately()
        penMenuWindow.closeImmediately()
        toolsMenuWindow.closeImmediately()
    }

    /// 由外部（控制器）程序化切换工具，不弹任何二级菜单（如选择放大镜后
    /// 自动切到鼠标模式以便拖动镜片）。胶囊显隐只跟随用户对按钮的显式点击。
    func applyToolExternally(_ tool: SlideshowAnnotationTool) {
        switchToolQuietly(tool)
    }
}

// MARK: - 工具自绘浮层（基类 + 橡皮清空胶囊 + 画笔颜色胶囊）

/// 工具自绘浮层基类：nonactivating 透明小面板，承载一块自绘胶囊内容
/// （子类把胶囊视图设为 contentView），显示在所属工具按钮正上方。
///
/// 收起规则：
/// - 点击浮层自身窗口（胶囊内控件）时不在此处收起：笔菜单的选色/选粗细由
///   控件自身回调处理（保持展开），橡皮「清空当页」点击后自行收起并切画笔；
/// - 点击所属工具按钮（源按钮）时不在此处收起，显隐统一由按钮点击的 toggle
///   管理，避免与本次点击事件链互相打架；
/// - 点击其余任意区域（工具栏其它按钮、画布、翻页条、另一工具胶囊等）一律
///   自动收起。
/// 判定用事件所属窗口而非鼠标屏幕坐标——浮层打开瞬间鼠标往往仍停留在所属
/// 工具按钮（浮层外）上，屏幕坐标判定会把那次点击误判成“外部点击”立刻收起。
@MainActor
class SlideshowToolMenuWindow: NSPanel {
    /// 浮层与工具按钮上沿的间距：与底部工具栏保持一段明显间隔（14pt）。
    private enum Metrics {
        static let gapFromButton: CGFloat = 14
    }

    private weak var anchorWindow: NSWindow?
    private let outsideClickMonitor = OutsideClickDismissMonitor()

    /// 所属工具按钮的屏幕 frame：点外监听用它区分「点回按钮本身（交 toggle）」
    /// 与「点工具栏其它区域（视为点外收起）」。
    private var sourceButtonScreenFrame: NSRect = .zero

    /// 同步显隐意图（不受进出场动画窗口期影响）：show() 置 true、hide() 立即置 false。
    /// 外部 toggle / 收起判断一律用它，避免用 isVisible 判定时把「退场动画中
    /// 仍可见」的窗口误判成已展开。
    private(set) var isOpen = false

    /// 退场动画进行中标志：hide() 防重入，同时让 show() 知道当前不能进场。
    private var isHiding = false

    /// 退场动画期间收到的进场请求（animator 动画无法安全中途打断）：hide()
    /// 收尾完成退场后据此自动补进，避免旧动画 completion 的 orderOut 把刚
    /// 重新显示的窗口关掉。锚点窗口与 anchorWindow 同用弱引用（工具栏常驻，
    /// 退场 0.08s 内必然存活）。
    private weak var pendingAnchor: NSWindow?
    private var pendingButtonScreenFrame: NSRect = .zero

    init(contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        // 强制深色外观（与底部工具栏一致）：胶囊内容为深底白字自绘，固定
        // .darkAqua 避免系统浅色外观下控件/材质出现浅色变体。
        appearance = NSAppearance(named: .darkAqua)
        // 二级菜单属于交互 UI，抬到 chrome 层，恒在自建工具层（screenSaver + 1）之上。
        level = SlideshowFloatingLevel.chrome
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        backgroundColor = .clear
        isOpaque = false
        // 禁用系统阴影：非不透明窗口的系统阴影由 WindowServer 按内容 alpha 异步
        // 生成，在全屏放映上层的 borderless 浮窗 orderOut/移动时阴影与内容的
        // damage 失效不原子，漏失效会留下卡片形状的淡色残影（笔二级菜单/计时器
        // 已实测）。放映浮层家族统一 hasShadow = false，不再使用系统阴影。
        hasShadow = false
        ignoresMouseEvents = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 定位到所属工具按钮正上方并显示，随后安装「点外收起」监听。
    /// 退场动画（0.08s）未走完又收到进场请求时：动画无法安全中途打断，
    /// 记下请求由 hide() 收尾自动补进（见 hide），状态始终收敛到确定终态。
    func show(above buttonScreenFrame: NSRect, anchor: NSWindow) {
        guard !isHiding else {
            pendingButtonScreenFrame = buttonScreenFrame
            pendingAnchor = anchor
            return
        }
        anchorWindow = anchor
        sourceButtonScreenFrame = buttonScreenFrame
        isOpen = true
        let size = frame.size
        let origin = NSPoint(
            x: buttonScreenFrame.midX - size.width / 2,
            y: buttonScreenFrame.maxY + Metrics.gapFromButton
        )
        setFrame(NSRect(origin: origin, size: size), display: true)
        // 轻微进场：淡入 + 从下方 5pt 上浮回位（动画与交互恢复都在 fadeInWindow 内）。
        fadeInWindow(self, targetAlpha: 1, rise: 5, duration: 0.14)
        installOutsideClickMonitor()
    }

    /// 收起：立即置未展开并移除监听，随后播放退场动画（淡出 + 下沉回落，
    /// 动画期间窗口关闭鼠标交互，见 fadeOutWindow），结束后真正 orderOut；
    /// 若退场期间收到过新的进场请求，收尾时自动补进。
    func hide() {
        guard !isHiding, isVisible else { return }
        isHiding = true
        isOpen = false
        removeOutsideClickMonitor()
        anchorWindow = nil
        sourceButtonScreenFrame = .zero
        fadeOutWindow(self, drop: 5, duration: 0.08) { [weak self] in
            guard let self else { return }
            self.isHiding = false
            if let anchor = self.pendingAnchor {
                let frame = self.pendingButtonScreenFrame
                self.pendingAnchor = nil
                self.pendingButtonScreenFrame = .zero
                self.show(above: frame, anchor: anchor)
            }
        }
    }

    /// 立即关闭（**无动画**）：截图前临时隐藏使用——跳过退场动画与 pending
    /// 补进，直接离屏并复位全部状态，保证窗口即时不在屏、不进捕获画面。
    func closeImmediately() {
        pendingAnchor = nil
        pendingButtonScreenFrame = .zero
        isHiding = false
        isOpen = false
        removeOutsideClickMonitor()
        anchorWindow = nil
        sourceButtonScreenFrame = .zero
        orderOut(nil)
    }

    /// 本地鼠标按下监听：点击落在浮层与所属工具按钮之外时自动收起。
    /// - 浮层自身窗口（胶囊内控件）：不在此处收起。笔菜单选色/选粗细保持
    ///   展开、橡皮「清空当页」点击后自行收起，都由控件自身回调处理；
    /// - 所属工具按钮（源按钮）：不在此处收起，显隐统一由按钮的 toggle
    ///   管理，避免与本次点击事件链互相打架；
    /// - 其余任意区域（工具栏其它按钮、画布、翻页条等）——包括锚点工具栏
    ///   内非源按钮的位置——一律视为点击胶囊外，自动收起。
    private func installOutsideClickMonitor() {
        outsideClickMonitor.install(
            isExempt: { [weak self] event in
                guard let self else { return true }
                if let window = event.window {
                    if window === self {
                        // 点胶囊内：交给控件自身回调（选色/选粗细保持展开等）。
                        return true
                    }
                    if window === self.anchorWindow {
                        // 点锚点工具栏：仅源按钮豁免（交给 toggle），其余位置
                        // （别的工具/撤销等按钮、非交互区）都算胶囊外点击。
                        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
                        if self.sourceButtonScreenFrame.contains(screenPoint) {
                            return true
                        }
                    }
                }
                // 其余任意窗口 / 工具栏非源按钮区域：视为点击外部，收起浮层。
                return false
            },
            onDismiss: { [weak self] in self?.hide() }
        )
    }

    private func removeOutsideClickMonitor() {
        outsideClickMonitor.remove()
    }
}

/// 橡皮二级菜单：上下两行「图标 + 名称」条目——「清空草稿纸」(trash.square)、
/// 「清空当页」(trash)，与「工具」二级菜单同构（深色圆角底 + 行间细分隔线 +
/// 左对齐图标行），显示在橡皮按钮上方。
/// 点击某行收起菜单并触发对应回调（调用方随后自动切回画笔）。
@MainActor
final class SlideshowEraserMenuWindow: SlideshowToolMenuWindow {
    var onClearScratchpad: (() -> Void)?
    var onClearPage: (() -> Void)?

    private let menuView: SlideshowEraserMenuView

    init() {
        menuView = SlideshowEraserMenuView()
        super.init(contentSize: menuView.intrinsicSize)
        menuView.onClearScratchpad = { [weak self] in
            guard let self else { return }
            self.hide()
            self.onClearScratchpad?()
        }
        menuView.onClearPage = { [weak self] in
            guard let self else { return }
            self.hide()
            self.onClearPage?()
        }
        menuView.frame = NSRect(origin: .zero, size: menuView.intrinsicSize)
        contentView = menuView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 橡皮菜单内容视图：深色圆角底 + 两行「图标 + 名称」条目 + 行间分隔线。
@MainActor
private final class SlideshowEraserMenuView: SlideshowMenuContainerView {
    var onClearScratchpad: (() -> Void)?
    var onClearPage: (() -> Void)?

    init() {
        super.init(rowCount: 2, menuWidth: 152)
        // isFlipped = true：从上往下排——第一行清空草稿纸、第二行清空当页。
        let scratchpadRow = SlideshowMenuRow(title: "清空草稿纸", svgResource: "trash.square")
        scratchpadRow.frame = frameForRow(at: 0)
        scratchpadRow.onClick = { [weak self] in self?.onClearScratchpad?() }
        let pageRow = SlideshowMenuRow(title: "清空当页", svgResource: "trash")
        pageRow.frame = frameForRow(at: 1)
        pageRow.onClick = { [weak self] in self?.onClearPage?() }
        addSubview(scratchpadRow)
        addSubview(pageRow)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 画笔设置自绘浮层：胶囊内含两行设置——上行红/蓝/黑三色色板，下行细/中/粗
/// 三档笔宽（每档一个圆形选项，内画 S 型笔迹预览，线条粗细即该档示意），
/// 显示在画笔按钮上方。与「清空当页」胶囊不同：选色 / 选粗细只应用设置、
/// **保持胶囊展开**（便于连续试色对比）；收起只由「再点画笔按钮」或
/// 「点击胶囊外任意区域」触发。
@MainActor
final class SlideshowPenMenuWindow: SlideshowToolMenuWindow {
    var onColorSelected: ((_ index: Int, _ color: NSColor) -> Void)?
    var onWidthSelected: ((_ index: Int) -> Void)?

    private let swatchView: SlideshowPenSwatchView

    init() {
        swatchView = SlideshowPenSwatchView()
        super.init(contentSize: swatchView.intrinsicSize)
        swatchView.onColorSelected = { [weak self] index, color in
            guard let self else { return }
            // 选色只应用设置、不收起胶囊：支持连续试色（点其它色块直接对比）。
            self.onColorSelected?(index, color)
        }
        swatchView.onWidthSelected = { [weak self] index in
            guard let self else { return }
            // 选粗细同样保持胶囊展开。
            self.onWidthSelected?(index)
        }
        swatchView.frame = NSRect(origin: .zero, size: swatchView.intrinsicSize)
        contentView = swatchView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 同步当前画笔颜色与粗细的选中圈（每次显示前由工具栏调用）。
    func setSelections(colorIndex: Int, widthIndex: Int) {
        swatchView.setColorIndex(colorIndex)
        swatchView.setWidthIndex(widthIndex)
    }
}

/// 画笔设置胶囊内容视图：深色圆角底上两行控件——
/// 上行三个圆形色板（红/蓝/黑）：选中项显示白色对勾，未选中对勾与色块同色、
/// 融入背景不可见；下行三个圆形笔宽选项（S 型笔迹预览随当前画笔色着色、
/// 线条粗细即该档粗细，选中项仍为白色粗描边圈，与笔色无关）。
/// 与「清空当页」胶囊同款深色底，保证在浅色/深色幻灯片上都清晰可见。
@MainActor
private final class SlideshowPenSwatchView: NSView {
    var onColorSelected: ((_ index: Int, _ color: NSColor) -> Void)?
    var onWidthSelected: ((_ index: Int) -> Void)?

    /// 固有尺寸：两行各 28pt 圆点，行间与上下留白 14pt 排布宽松
    /// （14+28+16 行距+28+14=100），宽度 3*28 + 2*14 间距 + 2*16 侧留白。
    let intrinsicSize = NSSize(width: 144, height: 100)

    private enum Metrics {
        static let dotDiameter: CGFloat = 28
        static let dotGap: CGFloat = 14
        static let sideInset: CGFloat = 16
        static let verticalInset: CGFloat = 14
        static let cornerRadius: CGFloat = 22
    }

    private var colorDots: [SlideshowPenColorDotButton] = []
    private var widthDots: [SlideshowPenWidthDotButton] = []

    /// 当前画笔色：粗细行 S 型预览随它着色（点击色板与显示前同步）。
    private var penColor: NSColor = SlideshowPenPalette.ordered[0].color

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.60).cgColor
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.masksToBounds = true

        // 上行：色板行（贴顶）；下行：粗细行（贴底），行内三圆并排从同一
        // 左侧内边距起排。
        let colorRowY = intrinsicSize.height - Metrics.verticalInset - Metrics.dotDiameter
        let widthRowY = Metrics.verticalInset

        var x = Metrics.sideInset
        for (index, entry) in SlideshowPenPalette.ordered.enumerated() {
            let dot = SlideshowPenColorDotButton(
                color: entry.color,
                accessibilityLabel: entry.name,
                diameter: Metrics.dotDiameter
            )
            dot.frame = NSRect(x: x, y: colorRowY, width: Metrics.dotDiameter, height: Metrics.dotDiameter)
            dot.onClick = { [weak self] in
                guard let self else { return }
                // 点击即同步勾选与粗细行预览色（菜单随后收起，下次显示仍一致）。
                self.setColorIndex(index)
                self.onColorSelected?(index, entry.color)
            }
            addSubview(dot)
            colorDots.append(dot)
            x += Metrics.dotDiameter + Metrics.dotGap
        }

        x = Metrics.sideInset
        for (index, preset) in SlideshowPenWidthPreset.ordered.enumerated() {
            let dot = SlideshowPenWidthDotButton(
                glyphStrokeWidth: preset.previewStrokeWidth,
                strokeColor: penColor,
                accessibilityLabel: "\(preset.name)笔迹"
            )
            dot.frame = NSRect(x: x, y: widthRowY, width: Metrics.dotDiameter, height: Metrics.dotDiameter)
            dot.onClick = { [weak self] in
                guard let self else { return }
                // 点击即同步选中圈（选中项白色粗描边），保持展开期间实时可见；
                // 与色板行同构：先本地高亮再转发，避免只改画布笔宽、选中态停滞。
                self.setWidthIndex(index)
                self.onWidthSelected?(index)
            }
            addSubview(dot)
            widthDots.append(dot)
            x += Metrics.dotDiameter + Metrics.dotGap
        }
        frame.size = intrinsicSize
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 高亮指定索引的颜色色板（选中项显白勾、其余对勾与色块同色不可见），
    /// 并把粗细行 S 型预览同步着色为当前笔色（所见即所得）。
    func setColorIndex(_ index: Int) {
        penColor = SlideshowPenPalette.ordered[index].color
        for (i, dot) in colorDots.enumerated() {
            dot.isPicked = (i == index)
        }
        for dot in widthDots {
            dot.strokeColor = penColor
        }
    }

    /// 高亮指定索引的笔宽选项（其余恢复细描边）。
    func setWidthIndex(_ index: Int) {
        for (i, dot) in widthDots.enumerated() {
            dot.isPicked = (i == index)
        }
    }
}

/// 幻灯片浮层自绘按钮基类：统一「清默认标题、无边框、target-action →
/// onClick、首次点击生效、手型光标」样板配置，子类只保留绘制/选中态差异。
@MainActor
class SlideshowOverlayButton: NSButton {
    var onClick: (() -> Void)?

    /// 子类 init 中调用：统一按钮基础配置。
    func configureAsOverlayButton() {
        // 清掉 NSButton 默认的 "Button" 文本，避免叠在图形上显示。
        title = ""
        attributedTitle = NSAttributedString()
        attributedAlternateTitle = NSAttributedString()
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(clicked)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func clicked() {
        performClickAction()
    }

    /// 点击行为钩子（子类可覆写追加反馈动画等；默认仅触发 onClick）。
    func performClickAction() {
        onClick?()
    }
}

/// 圆形色板按钮：实色圆底 + 白色细描边（恒定，让深色/黑色色块在深色胶囊底上
/// 可辨）。选中标识为内部**白色对勾**：每个色块内置一枚 checkmark 模板图标，
/// 未选中时对勾与色块同色、融入背景不可见，选中时切换为白色显现
/// （选中态不再用描边加粗表达，描边始终细白不变）。
@MainActor
private final class SlideshowPenColorDotButton: SlideshowOverlayButton {

    /// 未选中态对勾颜色：与圆底背景**同一个已解析 CGColor** 转换而来——
    /// 对勾与底色绝对同色、不可见（若各自按动态色解析，浅色系统下会出现
    /// 亮暗差一档的对勾残影）。
    private let idleTint: NSColor

    var isPicked: Bool = false {
        didSet {
            contentTintColor = isPicked ? .white : idleTint
        }
    }

    init(color: NSColor, accessibilityLabel: String, diameter: CGFloat) {
        // 先解析一次底色：背景与未选中对勾共用同一 CGColor，保证同色融入。
        let resolvedBackground = color.cgColor
        self.idleTint = NSColor(cgColor: resolvedBackground) ?? color
        super.init(frame: .zero)
        configureAsOverlayButton()
        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)

        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.masksToBounds = true
        layer?.backgroundColor = resolvedBackground
        // 细白描边恒定：只用于让色块（尤其黑色块）从深色胶囊底上读出圆形选项位，
        // 不随选中态变化。
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor

        // 对勾图标：模板图随 contentTintColor 着色；初始未选中 = 底色同色
        // （不可见），选中时 isPicked 切白显现。
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        let checkmark = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "已选中")?
            .withSymbolConfiguration(configuration)
        checkmark?.isTemplate = true
        image = checkmark
        imagePosition = .imageOnly
        contentTintColor = idleTint
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func performClickAction() {
        // 先应用点击动作（状态/颜色更新到最新），再以最新外观播放弹跳：
        // 与笔宽按钮同序，避免弹跳动画窗口内旧外观参与合成。
        onClick?()
        playIconBounce(self)
    }
}

/// 笔宽选项圆形按钮：细白描边圆内画一条 S 型笔迹——线条粗细即该档笔宽视觉
/// 示意，颜色跟随当前画笔色（所见即所得）；选中时仍用**白色粗描边圈**标识，
/// 不随笔色变化，任何笔色下选中态都清晰可辨。S 型笔迹刻意克制并比圆缩小
/// 一档：高度约 9pt（28pt 圆内上下各留约 8pt 边距）、左右摆幅 ±3.2pt（与
/// 圆形描边留有约 10pt 间距），图标与圆圈之间留白充裕、层次分明。
@MainActor
private final class SlideshowPenWidthDotButton: SlideshowOverlayButton {
    var isPicked: Bool = false {
        didSet {
            guard isPicked != oldValue else { return }
            redrawNow()
        }
    }

    /// S 型笔迹预览颜色：跟随当前画笔色（红/蓝/黑，所见即所得），不做任何
    /// 颜色改写或底色联动。
    var strokeColor: NSColor = .white {
        didSet {
            guard strokeColor != oldValue else { return }
            redrawNow()
        }
    }

    /// 状态变化即整帧同步重绘：display() 立即全量重绘（并消费挂起的 needsDisplay
    /// 标志），图层 contents 在状态变更的同一帧内刷新为新选中态——不再依赖异步
    /// needsDisplay 等下个 runloop 合帧，杜绝弹跳压扁动画窗口内旧选中帧残留
    /// 导致的「切换后图标内部阴影」。
    private func redrawNow() {
        display()
    }

    /// S 型笔迹预览线条的宽度（由所在档位决定：细 1.0 / 中 2.8 / 粗 4.5）。
    private let glyphStrokeWidth: CGFloat

    init(glyphStrokeWidth: CGFloat, strokeColor: NSColor, accessibilityLabel: String) {
        self.glyphStrokeWidth = glyphStrokeWidth
        self.strokeColor = strokeColor
        super.init(frame: .zero)
        configureAsOverlayButton()

        // 显式层支持：与色板按钮一致，点击弹跳与状态重绘走同一图层通道，
        // 避免非显式层视图与父容器合成时序不一致产生残影。
        wantsLayer = true

        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func performClickAction() {
        // 先让回调完成状态切换（选中圈经 redrawNow 同步刷成最新选中态），
        // 再以新外观播放弹跳；若顺序相反，压扁动画播放期间异步 needsDisplay
        // 才落帧，旧选中帧会与动画合帧残留，表现为切换后图标内部阴影。
        onClick?()
        playIconBounce(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        // 描边圆：让线条整体落在视图内（描边越粗半径内收越多）。
        let strokeHalf = isPicked ? 1.5 : 0.5
        let radius = min(bounds.width, bounds.height) / 2 - 0.5 - strokeHalf

        // 底色：略亮半透明圆（读出「圆形选项位」），不随笔迹颜色变化。
        let bg = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        NSColor.white.withAlphaComponent(0.14).setFill()
        bg.fill()

        // 圆形描边：选中 3pt 白色高亮圈，未选中 1pt 半透明白——固定白色系，
        // 不随笔色切换。
        let ring = NSBezierPath(ovalIn: bg.bounds)
        if isPicked {
            NSColor.white.setStroke()
            ring.lineWidth = 3
        } else {
            NSColor.white.withAlphaComponent(0.55).setStroke()
            ring.lineWidth = 1
        }
        ring.stroke()

        // S 型笔迹：竖向正弦 S——起止点落在竖直中线上，上段弧偏左、下段弧偏右。
        // 图形刻意比圆缩小一档：高度 ±4.5pt（上下各留约 8pt 边距）、横向摆幅
        // ±3.2pt（左右各留约 10pt 间距），与圆形边框保持充裕留白，
        // 让选项更透气、突出「圆圈」与「笔迹」两个层次。
        let path = NSBezierPath()
        path.lineWidth = glyphStrokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let steps = 48
        var first = true
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = center.x - 3.2 * sin(2 * CGFloat.pi * t)
            let y = center.y + 4.5 - 9 * t
            if first {
                path.move(to: NSPoint(x: x, y: y))
                first = false
            } else {
                path.line(to: NSPoint(x: x, y: y))
            }
        }
        // 笔迹着色：所见即所得，直接用当前画笔色（红/蓝/黑），无任何转白。
        strokeColor.setStroke()
        path.stroke()
    }
}
// MARK: - 退出放映确认弹窗（自绘）

/// 自绘「退出放映」确认弹窗。
///
/// 不用系统 NSAlert：放映时 MacHelper 处于后台、批注层是 nonactivating 面板体系，
/// `NSAlert.runModal()` 的弹窗无法成为 key window，实测点击不到。自绘方案与工具栏
/// 同一套交互模型（nonactivating NSPanel + 高层级 + 控件直接响应鼠标），
/// level 抬到 `screenSaver + 1`，稳定浮在画布批注层（.screenSaver）之上。
@MainActor
final class SlideshowExitConfirmWindow: NSPanel {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    private let cancelButton: SlideshowExitConfirmButton
    private let confirmButton: SlideshowExitConfirmButton
    private let outsideClickMonitor = OutsideClickDismissMonitor()

    private enum Metrics {
        static let width: CGFloat = 264
        static let height: CGFloat = 128
        static let sideInset: CGFloat = 20
        static let buttonHeight: CGFloat = 34
        static let buttonGap: CGFloat = 10
        // 圆角与笔设置/橡皮清空胶囊（black 0.60 圆角 22）取同值，
        // 保证退出弹窗与各二级菜单浮层的视觉一致。
        // 注：工具/橡皮「菜单容器」为另一套观感（black 0.72 圆角 20），勿混用。
        static let cornerRadius: CGFloat = 22
    }

    init() {
        cancelButton = SlideshowExitConfirmButton(
            title: "返回",
            background: NSColor.white.withAlphaComponent(0.22)
        )
        confirmButton = SlideshowExitConfirmButton(
            title: "退出放映",
            background: NSColor.systemRed
        )
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        // 强制深色外观（与底部工具栏一致）：弹窗玻璃卡与白字内容按深色设计，
        // 固定 .darkAqua 避免系统浅色外观下玻璃整体变浅。
        appearance = NSAppearance(named: .darkAqua)
        // 退出弹窗属交互 UI，抬到 chrome 层：恒在自建工具层（screenSaver + 1）之上。
        level = SlideshowFloatingLevel.chrome
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false
        // 关键：窗口背景必须透明。contentView 是圆角裁剪的玻璃卡片，圆角外的
        // 四个切角区域会露出窗口自身底色——若这里不置 clear，四个角会显示成
        // 与玻璃不协调的方形底色块（「不正常的边角」）。工具栏等一律走
        // FloatingOverlayPanel.configureFloatingOverlay()（已置 clear），
        // 本弹窗直连 NSPanel 需手动补齐这一行。
        backgroundColor = .clear
        // 禁用系统阴影（残影根因，同 SlideshowToolMenuWindow 注释）。
        hasShadow = false

        confirmButton.onClick = { [weak self] in self?.confirmExit() }
        cancelButton.onClick = { [weak self] in self?.cancelExit() }
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 深色半透明卡片底 + 标题 / 说明 / 两个按钮的固定布局。
    private func buildContent() {
        // 背景与笔/橡皮二级菜单完全一致：一个 black 0.60 半透明圆角容器即内容视图，
        // 不再套 LiquidGlassEffectView 液态玻璃层——二级菜单胶囊本身就是纯色半透明底
        // （无玻璃材质），玻璃层在旧 SDK 上会退化成 hudWindow 毛玻璃，观感不一致。
        // 容器圆角外露出窗口透明背景（窗口已置 clear）；系统阴影已禁用（残影
        // 根因，见 SlideshowToolMenuWindow 注释），与二级菜单浮层同源。
        let container = NSView(frame: NSRect(origin: .zero, size: NSSize(width: Metrics.width, height: Metrics.height)))
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.60).cgColor
        container.layer?.cornerRadius = Metrics.cornerRadius
        container.layer?.masksToBounds = true
        contentView = container

        let title = NSTextField(labelWithString: "退出放映？")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white.withAlphaComponent(0.95)
        title.alignment = .center

        let message = NSTextField(labelWithString: "退出后当前放映的批注将被清空。")
        message.font = .systemFont(ofSize: 12)
        message.textColor = .white.withAlphaComponent(0.65)
        message.alignment = .center

        // 按钮行：宽 = (卡片宽 - 左右内边距 - 按钮间距) / 2，横排等分。
        let buttonWidth = (Metrics.width - Metrics.sideInset * 2 - Metrics.buttonGap) / 2
        cancelButton.frame = NSRect(
            x: Metrics.sideInset,
            y: 16,
            width: buttonWidth,
            height: Metrics.buttonHeight
        )
        confirmButton.frame = NSRect(
            x: Metrics.sideInset + buttonWidth + Metrics.buttonGap,
            y: 16,
            width: buttonWidth,
            height: Metrics.buttonHeight
        )

        // 自上而下布局：标题 → 说明 → 按钮行。
        let contentWidth = Metrics.width - Metrics.sideInset * 2
        title.frame = NSRect(x: Metrics.sideInset, y: Metrics.height - 40, width: contentWidth, height: 22)
        message.frame = NSRect(x: Metrics.sideInset, y: Metrics.height - 64, width: contentWidth, height: 18)

        container.addSubview(title)
        container.addSubview(message)
        container.addSubview(cancelButton)
        container.addSubview(confirmButton)
    }

    /// 居中显示在目标区域（画布/放映窗口）正中，并安装「点外部取消」监听。
    /// 进场动画：轻微淡入 + 卡片从 0.94 放大到 1.0（中规中矩的呈现感）。
    func show(centeredIn frame: NSRect) {
        var target = frame
        if target.width <= 0 || target.height <= 0 {
            target = NSScreen.main?.visibleFrame ?? .zero
        }
        let origin = NSPoint(
            x: target.midX - Metrics.width / 2,
            y: target.midY - Metrics.height / 2
        )
        setFrame(NSRect(origin: origin, size: NSSize(width: Metrics.width, height: Metrics.height)), display: true)

        // 进场动画：轻微淡入 + 卡片绕中心从 0.94 放大到 1.0。
        // 缩放先置最终态（identity）再赋初值，避免淡出残留的透明度/变换影响下一次。
        let contentSize = contentView?.bounds.size ?? NSSize(width: Metrics.width, height: Metrics.height)
        let initialTransform = Self.centeredScale(0.94, size: contentSize)
        alphaValue = 1
        contentView?.layer?.transform = CATransform3DIdentity
        alphaValue = 0
        contentView?.layer?.transform = initialTransform
        orderFrontRegardless()
        installOutsideClickMonitor()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
        if let contentLayer = contentView?.layer {
            contentLayer.transform = CATransform3DIdentity
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = NSValue(caTransform3D: initialTransform)
            scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            scale.duration = 0.18
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentLayer.removeAnimation(forKey: "exitDialogPresent")
            contentLayer.add(scale, forKey: "exitDialogPresent")
        }
    }

    /// 绕视图中心缩放（translate×scale×translate），不依赖 layer.anchorPoint。
    private static func centeredScale(_ scale: CGFloat, size: CGSize) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform = CATransform3DTranslate(transform, size.width / 2, size.height / 2, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -size.width / 2, -size.height / 2, 0)
        return transform
    }

    /// 退场动画防重入：hide 可能被多条路径重复触发（确认按钮回调里的 teardown
    /// 会再次调用 hide），重复触发只保留第一次的淡出。
    private var isHiding = false

    /// 退场动画：淡出后真正 orderOut。动画期间闭包强持有本窗口，保证调用方
    /// 已置空引用时（确认后控制器置 nil）退场仍能完整执行。
    func hide() {
        guard !isHiding else { return }
        isHiding = true
        removeOutsideClickMonitor()
        guard isVisible else {
            isHiding = false
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        } completionHandler: {
            self.orderOut(nil)
            self.alphaValue = 1
            self.isHiding = false
        }
    }

    private func confirmExit() {
        hide()
        onConfirm?()
    }

    private func cancelExit() {
        hide()
        onCancel?()
    }

    /// 点击弹窗自身（两个按钮）放行由按钮处理；点击其它任何窗口视为取消。
    /// 与橡皮浮层同款 event.window 归属判定，规避屏幕坐标竞态。
    private func installOutsideClickMonitor() {
        outsideClickMonitor.install(
            isExempt: { [weak self] event in
                // 点弹窗自身（两个按钮）：交给按钮的 onClick。
                guard let self, self.isVisible else { return true }
                return event.window === self
            },
            onDismiss: { [weak self] in self?.cancelExit() }
        )
    }

    private func removeOutsideClickMonitor() {
        outsideClickMonitor.remove()
    }
}

/// 退出确认弹窗内的文字胶囊按钮：固定底色无 hover，纯文本水平垂直居中。
@MainActor
private final class SlideshowExitConfirmButton: SlideshowOverlayButton {
    init(title: String, background: NSColor) {
        super.init(frame: .zero)
        configureAsOverlayButton()

        let text = NSMutableAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.96),
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
            ]
        )
        attributedTitle = text
        attributedAlternateTitle = text
        alignment = .center

        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.masksToBounds = true
        layer?.backgroundColor = background.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - 翻页面板（左下 / 右下）

/// 翻页面板：左 / 当前页码与总页数 / 右，屏幕左下角与右下角各一套。
@MainActor
final class SlideshowAnnotationNavigationWindow: SlideshowAnnotationPanelWindow {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    /// 点击页码标签：携带标签在屏幕坐标系下的 frame（页码预览窗口的锚点）。
    var onPageLabelClick: ((NSRect) -> Void)?

    private let previousButton = SlideshowToolbarIconButton(kind: .fixed(svgResource: "chevron.backward"), accessibilityDescription: "上一页")
    private let pageLabel = SlideshowToolbarPageLabel()
    private let nextButton = SlideshowToolbarIconButton(kind: .fixed(svgResource: "chevron.forward"), accessibilityDescription: "下一页")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: Metrics.buttonSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // 翻页箭头 SVG 字形视觉铺满无留白，按对角线归一后观感偏大：
        // 以 0.7 的视觉缩放系数整体收小（0.8 实测仍偏大）。
        previousButton.iconScale = 0.7
        nextButton.iconScale = 0.7

        previousButton.onClick = { [weak self] in self?.onPrevious?() }
        nextButton.onClick = { [weak self] in self?.onNext?() }
        pageLabel.onClick = { [weak self] in
            guard let self, let window = self.pageLabel.window else { return }
            // 传整个翻页面板的屏幕 frame：预览窗口以其为锚（宽度一致、
            // 居中于面板上方），点外收起监听也按它豁免面板整体。
            self.onPageLabelClick?(window.frame)
        }
        // 页码标签自绘槽位 = 60（比图标 40 略宽）× 40（与图标等高）：
        // 「当前页/总页」整串在槽位内垂直水平居中，视觉上即「页码槽位与
        // 图标等高、略宽」。
        // 翻页栏 = [‹][页码][›] 紧贴排列，无左右间距、无内边距，圆角裁切，
        // 与底部中间工具栏同构。
        install([previousButton, pageLabel, nextButton])
    }

    /// 更新页码显示：`total` 为 0（加载项未取到总页数）时只显示当前页。
    func setPage(_ index: Int, total: Int) {
        pageLabel.setPage(index, total: total)
    }
}

// MARK: - 工具栏图标按钮（SVG 资源）

/// SVG 图标源：Bundle.module 里的矢量图 + 一次性探针栅格化得到的字形包围盒。
/// 矢量图可在**任意分辨率**重复渲染——这是图标锐利（不因缩放插值发虚）的根本。
private struct SVGIconSource {
    let image: NSImage
    /// 字形包围盒（占 viewBox 的比例坐标 0–1）：SVG 常带透明边距，裁掉后
    /// 绘制矩形即字形矩形。
    let bbox: CGRect
    /// 字形包围盒宽高比（w / h），驱动绘制时的对角线归一。
    let aspect: CGFloat
}

/// 底部左 / 中 / 右三栏工具栏统一使用的图标按钮（三态基类）。
///
/// 三态配置：
/// - **无选中态**（`.fixed`）：任意时刻显示同一张 SVG 图标（翻页 / 撤销 /
///   还原 / 工具 / 退出）。
/// - **有选中态**（`.toggling`）：`isSelected == false` 显示未选中轮廓图，
///   选中后切换为填充图（鼠标 / 画笔 / 橡皮）。
///
/// 图标来源：**Bundle SVG 矢量资源**（不再用 SF Symbol）。渲染管线：
/// 探针栅格化扫描 alpha 得字形包围盒（比例）→ draw 时按对角线归一算出
/// 目标矩形 → 按目标矩形的**实际像素尺寸**（× 屏幕倍频）把矢量渲染成
/// 1:1 遮罩位图 → 遮罩填充 tintColor。矢量按最终像素尺寸直出、零缩放
/// 插值，图标锐利不糊；旧管线「固定 4× 栅格化再缩小绘制」的降采样发虚
/// 问题就此根除。
@MainActor
final class SlideshowToolbarIconButton: SlideshowOverlayButton {
    /// 三态图标配置（svgResource 为 Bundle.module 里的 SVG 资源名，不含扩展名）。
    enum Kind {
        /// 无选中态：任意时刻都显示该图标。
        case fixed(svgResource: String)
        /// 有选中态：未选中显示 offResource，选中显示 onResource。
        case toggling(offResource: String, onResource: String)

        fileprivate var switchesOnSelection: Bool {
            if case .toggling = self { return true }
            return false
        }
    }

    /// 图标着色：绘制时作为遮罩的填充色（换色即重绘）。
    var tintColor: NSColor = .white {
        didSet { needsDisplay = true }
    }

    /// 图标外描边色（可选）：绘制时先以该色沿 16 方向偏移铺出**宽度均匀的
    /// 膨胀底**（形态学膨胀，环宽 outlineWidth≈0.9pt），字形本体再按
    /// tintColor 覆盖其上——仅剩边缘一圈连贯描边可见。用于画笔选中态：
    /// 笔色填充图标加白描边，深色笔在深底工具栏上依旧清晰。置 nil 恢复无描边。
    var iconOutline: NSColor? {
        didSet { needsDisplay = true }
    }

    /// 选中态：`.toggling` 按钮据此在未选中/选中图标间切换；`.fixed` 按钮忽略。
    var isSelected: Bool = false {
        didSet {
            if kind.switchesOnSelection {
                reloadIcon()
            }
        }
    }

    /// 图标视觉缩放系数（1 = 与其他栏按钮一致的对角线归一尺寸）：翻页箭头类
    /// SVG 字形在画布内视觉铺满、无留白，观感偏大，用 <1 的系数整体缩小。
    var iconScale: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    private let kind: Kind
    private let accessibilityText: String
    /// 当前显示的资源名（fixed 恒定；toggling 随 isSelected 切换）。
    private var currentResource: String

    init(kind: Kind, accessibilityDescription: String) {
        self.kind = kind
        self.accessibilityText = accessibilityDescription
        switch kind {
        case .fixed(let name):
            currentResource = name
        case .toggling(let off, _):
            currentResource = off
        }
        super.init(frame: .zero)
        configureAsOverlayButton()

        // 图标完全由 draw 自绘（遮罩填充），杜绝 NSButton cell 渲染默认
        // "Button" 文本或自带 image 的重影。
        setAccessibilityLabel(accessibilityDescription)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 依据当前选中态切换图标（仅 toggling 按钮；着色保持当前 tintColor）。
    private func reloadIcon() {
        guard case let .toggling(offResource, onResource) = kind else { return }
        currentResource = isSelected ? onResource : offResource
        needsDisplay = true
    }

    /// 程序化触发按钮点击（面板两端边距填充路由用）：与真实点击同路径——
    /// 先执行动作，再以最新外观播放「弹跳」弹性反馈。
    func performRoutedClick() {
        performClickAction()
    }

    // MARK: SVG 加载与渲染（主线程静态缓存）

    /// SVG 源缓存（资源名 → 矢量图 + 包围盒）。包围盒与尺寸无关，一次扫描终身复用。
    private static var sourceCache: [String: SVGIconSource] = [:]
    /// 遮罩缓存（"资源名#宽x高" → 1:1 位图）。目标像素尺寸恒定，实际条目极少。
    private static var maskCache: [String: CGImage] = [:]

    /// 加载并解析 SVG 源（含字形包围盒扫描）。
    private static func source(named name: String) -> SVGIconSource? {
        if let cached = sourceCache[name] { return cached }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url),
              image.size.width > 0, image.size.height > 0 else { return nil }

        // 探针栅格化：中等分辨率渲染一次，扫描 alpha 求字形包围盒（比例坐标）。
        let viewBox = image.size
        let probeHeight: CGFloat = 160
        let probeWidth = max(1, viewBox.width / viewBox.height * probeHeight)
        guard let probe = render(image: image, pixelWidth: Int(probeWidth.rounded(.up)), pixelHeight: Int(probeHeight)),
              let base = probe.bitmapData,
              probe.samplesPerPixel == 4, probe.bitsPerSample == 8 else { return nil }
        let pw = probe.pixelsWide
        let ph = probe.pixelsHigh
        let bytesPerPixel = probe.bitsPerPixel / 8
        var minX = pw, maxX = -1
        var minY = ph, maxY = -1
        for y in 0..<ph {
            let row = base.advanced(by: y * probe.bytesPerRow)
            for x in 0..<pw where row[x * bytesPerPixel + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let bbox = CGRect(
            x: CGFloat(minX) / CGFloat(pw),
            y: CGFloat(minY) / CGFloat(ph),
            width: CGFloat(maxX - minX + 1) / CGFloat(pw),
            height: CGFloat(maxY - minY + 1) / CGFloat(ph)
        )
        let source = SVGIconSource(
            image: image,
            bbox: bbox,
            aspect: bbox.width * viewBox.width / max(bbox.height * viewBox.height, 1)
        )
        sourceCache[name] = source
        return source
    }

    /// 把 SVG 矢量渲染成指定像素尺寸的位图（矢量直出，无插值损失）。
    private static func render(image: NSImage, pixelWidth: Int, pixelHeight: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, pixelWidth),
            pixelsHigh: max(1, pixelHeight),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: pixelWidth, height: pixelHeight)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: rep.size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// 按字形目标像素尺寸渲染 1:1 遮罩：先按包围盒比例反推整幅 viewBox 的
    /// 像素尺寸渲染矢量，再裁出包围盒区域——遮罩像素与绘制矩形一一对应，
    /// 绘制时零缩放。
    private static func mask(named name: String, source: SVGIconSource, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        let key = "\(name)#\(pixelWidth)x\(pixelHeight)"
        if let cached = maskCache[key] { return cached }
        let fullWidth = Int((CGFloat(pixelWidth) / source.bbox.width).rounded(.up))
        let fullHeight = Int((CGFloat(pixelHeight) / source.bbox.height).rounded(.up))
        guard let rep = render(
            image: source.image,
            pixelWidth: fullWidth,
            pixelHeight: fullHeight
        ), let full = rep.cgImage else { return nil }
        // 包围盒像素区（fullWidth/fullHeight 取整带来的 ±1px 误差可忽略）；
        // 先与整幅图像边界求交，杜绝取整越界导致 cropping 返回 nil。
        let crop = CGRect(
            x: (source.bbox.origin.x * CGFloat(fullWidth)).rounded(),
            y: (source.bbox.origin.y * CGFloat(fullHeight)).rounded(),
            width: CGFloat(pixelWidth),
            height: CGFloat(pixelHeight)
        ).intersection(CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight))
        guard !crop.isNull, crop.width >= 1, crop.height >= 1,
              let cropped = full.cropping(to: crop) else { return nil }
        maskCache[key] = cropped
        return cropped
    }

    /// 共用 SVG 图标绘制入口（二级菜单等自绘视图复用，与按钮同一套渲染管线）：
    /// 在 `box`（调用方视图坐标系内的方框）中按对角线归一绘制图标并填充 `tint`，
    /// 可选先铺一份每侧外扩 `outlineWidth` 的字形底并填 `outlineColor`（白色
    /// 描边效果，字形本体随后覆盖其上）。
    ///
    /// 方向语义：CGImage 遮罩在**标准（非翻转）上下文**中直接绘制即与文件/
    /// 编辑器预览一致（正立）；在 **flipped 上下文**（CTM 已被 AppKit 设为
    /// y-down）中直接绘制会上下颠倒，须先把上下文翻回标准 CG 坐标再画。
    /// 调用方视图两者皆有（工具菜单行为 flipped，橡皮菜单行/工具栏按钮为
    /// 标准），故按当前上下文自适应；`viewHeight` 传调用方视图 bounds.height，
    /// 仅 flipped 分支用作翻转换量。
    static func drawIcon(
        named name: String,
        box: NSRect,
        viewHeight: CGFloat,
        tint: NSColor,
        diagonalFraction: CGFloat = SlideshowAnnotationPanelWindow.Metrics.iconDiagonalFraction,
        outlineColor: NSColor? = nil,
        // 选中态字形的白色描边宽度（形态学膨胀环宽）。
        outlineWidth: CGFloat = 0.9
    ) {
        guard let current = NSGraphicsContext.current,
              let source = source(named: name) else { return }
        let context = current.cgContext

        // 等视觉尺寸：按**包围盒对角线**归一到方框内——对角线相等的图形
        // 视觉占幅一致，细高（翻页箭头）/扁宽（撤销/还原）/方形（退出圆叉）
        // 三类图标观感大小统一、不变形、双轴居中。
        let boxSide = min(box.width, box.height) * diagonalFraction
        // aspect = w/h，对角线 = h·√(aspect²+1)；令对角线 = boxSide 解出 w/h。
        let height = boxSide / (source.aspect * source.aspect + 1).squareRoot()
        let width = height * source.aspect

        // 像素网格对齐（Retina 半像素栅格）：矩形与物理像素一一对应，杜绝
        // 亚像素采样发虚；遮罩按该矩形像素尺寸 1:1 渲染。
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let px = 1 / scale
        let drawWidth = (width * scale).rounded() * px
        let drawHeight = (height * scale).rounded() * px
        let iconRect = NSRect(
            x: ((box.width - drawWidth) / 2 * scale).rounded() * px + box.minX,
            y: ((box.height - drawHeight) / 2 * scale).rounded() * px + box.minY,
            width: drawWidth,
            height: drawHeight
        )
        let pixelWidth = max(1, Int((drawWidth * scale).rounded()))
        let pixelHeight = max(1, Int((drawHeight * scale).rounded()))
        guard let mask = mask(
            named: name,
            source: source,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        ) else { return }

        context.saveGState()
        // 方向自适应：flipped 上下文（CTM y-down）先把上下文翻回标准 CG 坐标，
        // 绘制矩形同步换算；标准上下文直接绘制。两种视图下字形均与文件/编辑器
        // 语义一致（正立）。
        let flipped = current.isFlipped
        if flipped {
            context.translateBy(x: 0, y: viewHeight)
            context.scaleBy(x: 1, y: -1)
        }
        let cgRect = flipped
            ? NSRect(
                x: iconRect.minX,
                y: viewHeight - iconRect.maxY,
                width: iconRect.width,
                height: iconRect.height
            )
            : iconRect
        // 描边（形态学膨胀）：以字形遮罩为样本，沿 16 个方向各偏移 outlineWidth
        // 重复铺色取并集——得到宽度均匀、连贯闭合的一圈底色，字形本体随后
        // 覆盖其上，仅边缘一圈描边可见，字形抗锯齿边缘与描边自然融合无灰缝。
        // （旧实现按比例放大整幅字形铺底：环宽 = 放大量 × 离字形中心距离，
        // 在字形中部趋近于零，实测描边断续且不明显——故弃用。）
        if let outlineColor {
            let steps = 16
            for i in 0..<steps {
                let angle = CGFloat(i) / CGFloat(steps) * 2 * .pi
                let rect = cgRect.offsetBy(dx: cos(angle) * outlineWidth, dy: sin(angle) * outlineWidth)
                context.saveGState()
                context.clip(to: rect, mask: mask)
                outlineColor.setFill()
                context.fill(rect)
                context.restoreGState()
            }
        }
        context.clip(to: cgRect, mask: mask)
        tint.setFill()
        context.fill(cgRect)
        context.restoreGState()
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.drawIcon(
            named: currentResource,
            box: bounds,
            viewHeight: bounds.height,
            tint: tintColor,
            diagonalFraction: SlideshowAnnotationPanelWindow.Metrics.iconDiagonalFraction * iconScale,
            outlineColor: iconOutline
        )
    }

    override func performClickAction() {
        // 先应用点击动作（图标/选中态已更新到最新），再以最新外观播放 macOS
        // 工具栏图标的「弹跳」弹性反馈（压缩 → 过冲回弹）——弹跳只搬运新外观。
        onClick?()
        playIconBounce(self)
    }
}

/// 页码标签（自绘，最简排版）：0 < 总页 ≤ 999 时显示「当前页/总页」——整串作为
/// 一段文本在槽位内**整体垂直水平居中**，不做斜分数上浮/下沉错位、不做空格占位、
/// 不单独锚定斜杠：斜杠只是普通文本字符，随整串一起居中。全程等宽数字。
///
/// 槽位与两侧图标等高（40pt）× 略宽（60pt），整串文本的单行行框中心对齐槽位
/// 中心，任何位数都完整可见不裁切（自绘——旧 NSTextField 单行文本贴顶无法垂直
/// 居中且槽位高 19pt 会裁字形，故弃用）。
///
/// 显示规则：
/// - 0 < 总页数 ≤ 999：「当前页/总页」（如 3/100），整串居中。
/// - 总页数 ≤ 0（未知）或 > 999：只显示当前页码；超过 7 位（>9999999）时
///   压缩为「*」+ 末六位（如 10000000 → *000000）。
/// - 字号按真实文本宽度逐档实测：从 12pt 往下找第一个放得进固定宽度（56pt）
///   的最大字号（下限 9pt），极端文本也完整显示。
@MainActor
final class SlideshowToolbarPageLabel: NSView {
    /// 点击页码标签（页码预览开关由控制器 toggle 管理）。
    var onClick: (() -> Void)?

    private enum Style {
        /// 首选字号（12pt 在 40pt 槽位内约占 1/3 高度，观感精致）。
        static let regular: CGFloat = 12
        static let minimum: CGFloat = 9
        /// 可用宽度：槽位 60pt 两侧各留 2pt 边距。
        static let availableWidth: CGFloat = SlideshowAnnotationPanelWindow.Metrics.pageLabelWidth - 4
    }

    private var text: String = ""
    private var fontSize: CGFloat = Style.regular

    /// y 向下：排版与绘制都按「顶 → 底」直觉计算。
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        frame.size = NSSize(
            width: SlideshowAnnotationPanelWindow.Metrics.pageLabelWidth,
            height: SlideshowAnnotationPanelWindow.Metrics.buttonSize
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPage(_ index: Int, total: Int) {
        // 0 < 总页 ≤ 999 拼「当前/总」整串；总页未知（≤0）或超过 999 只显示当前页。
        if total > 0 && total <= 999 {
            text = "\(index)/\(total)"
        } else {
            text = Self.compactPage(index)
        }
        fontSize = Self.fitSize(text)
        needsDisplay = true
    }

    /// 按可用宽度实测字号：取第一个放得下的最大字号，保证任何文本不截断。
    private static func fitSize(_ text: String) -> CGFloat {
        for size in stride(from: Style.regular, through: Style.minimum, by: -1) {
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
            let width = (text as NSString).size(withAttributes: [.font: font]).width
            if width <= Style.availableWidth {
                return size
            }
        }
        return Style.minimum
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]

        // 整串作为单行文本：行框中心对齐槽位垂直中心（垂直居中），水平上按
        // 文本真实宽度整体居中——「当前页/总页」的分割斜杠随整串居中，页码
        // 位数变化时文本左右对称扩展，不偏斜、不裁切。
        let textWidth = (text as NSString).size(withAttributes: attrs).width
        let lineHeight = font.ascender + (-font.descender)
        let x = (bounds.width - textWidth) / 2
        let top = bounds.midY - lineHeight / 2
        (text as NSString).draw(
            in: NSRect(x: x, y: top, width: textWidth, height: lineHeight),
            withAttributes: attrs
        )
    }

    /// 只显示当前页码（总页数未知或超过 999 的情况）；当前页码超过 7 位
    /// （>9999999）时压缩为「*」+ 末六位，其余情况原样显示。
    private static func compactPage(_ page: Int) -> String {
        let text = "\(page)"
        guard text.count > 7 else { return text }
        return "*" + String(text.suffix(6))
    }

    /// 可点击：点击标签弹出/收起页码预览（回调由翻页面板转发给控制器）。
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

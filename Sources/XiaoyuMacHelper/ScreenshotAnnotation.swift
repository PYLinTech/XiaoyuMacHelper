import AppKit
import Carbon

// MARK: - 批注工具与元素模型

/// 批注工具（互斥单选）。
enum AnnotationTool {
    case text
    case arrow
    case rect
}

/// 批注线宽档位（三档）：作用于箭头杆宽与矩形描边（图像像素），只影响新绘制的元素。
enum AnnotationThickness: CaseIterable {
    case thin
    case medium
    case thick

    /// 落笔描边线宽（图像像素）。
    var strokeWidth: CGFloat {
        switch self {
        case .thin: return 3
        case .medium: return 6
        case .thick: return 12
        }
    }

    /// 界面显示名（工具栏提示 / 面板行标签）。
    var displayName: String {
        switch self {
        case .thin: return "细"
        case .medium: return "中"
        case .thick: return "粗"
        }
    }
}

/// 一个批注元素：以 center/size/rotation 定义的独立个体，支持移动、缩放、旋转。
/// 所有几何量均为「图像坐标」（左上原点、y 向下、单位 = 截图像素）；
/// rotation 为弧度，正值 = 视觉顺时针（y 向下坐标系中 atan2 的自然方向）。
/// 本地坐标系：原点在元素中心，x 向右、y 向下；size 为未旋转时的宽高。
struct AnnotationElement: Equatable {
    enum Kind: Equatable {
        /// 空心描边矩形框（size = 框宽高）。
        case rect
        /// 箭头：沿本地 x 轴，从 (-w/2, 0) 指向 (+w/2, 0)。
        case arrow
        /// 文本：size 为排版尺寸（由内容测量而来），支持 \n 显式换行。
        case text(text: String)
    }

    var kind: Kind
    var color: NSColor
    var center: NSPoint = .zero
    var size: NSSize = .zero
    var rotation: CGFloat = 0          // 弧度
    var fontSize: CGFloat = 24         // 文本字号（图像像素）
    var strokeWidth: CGFloat = 6       // rect/arrow 线宽（图像像素）

    static func == (lhs: AnnotationElement, rhs: AnnotationElement) -> Bool {
        lhs.kind == rhs.kind
            && lhs.center == rhs.center
            && lhs.size == rhs.size
            && lhs.rotation == rhs.rotation
            && lhs.fontSize == rhs.fontSize
            && lhs.strokeWidth == rhs.strokeWidth
            && lhs.color.isEqual(rhs.color)
    }
}

// MARK: - 批注画布

/// 全屏批注画布：显示整屏截图 + 批注元素，支持选区放大动画、按钮/滚轮/双指缩放。
///
/// 坐标系：`isFlipped = true`（y 向下），与截图图像坐标方向一致，
/// 因此 `zoomRect`/元素坐标/鼠标坐标/绘制全部统一在图像坐标系内，无需翻转换算。
@MainActor
final class AnnotationCanvasView: NSView {
    enum Metrics {
        static let textFontSize: CGFloat = 24    // 文本字号（图像像素）
        static let maxZoomScale: CGFloat = 16    // 最大放大倍数
        static let maxOutspan: CGFloat = 3       // 可见区可扩展到图像宽度的倍数（看选区外）
        static let presentAnimationDuration: CFTimeInterval = 0.42
        static let zoomAnimationDuration: CFTimeInterval = 0.30   // 按钮缩放的平滑动画时长
        static let adjustModeMinSize: CGFloat = 18   // 调整选区时角点拖拽的最小尺寸（视图 pt）
        static let adjustHandleRadius: CGFloat = 10  // 角点手柄半径（视图 pt）
        static let adjustHandleHitRadius: CGFloat = 26   // 角点命中半径（视图 pt）
        static let textMinFontSize: CGFloat = 8      // 文本最小字号（图像像素）
        static let textMaxFontSize: CGFloat = 200    // 文本最大字号（图像像素）
        static let maxHistoryDepth = 100             // 撤销栈上限
    }

    private var image: NSImage?
    private var imageRect = NSRect.zero
    /// 选区（图像坐标），绘制为虚线轮廓提示截图范围。
    private var selectionRect = NSRect.zero
    /// 当前可见区域（图像坐标，宽高比恒等于画布可用区）。
    private var zoomRect = NSRect.zero
    private var elements: [AnnotationElement] = []
    private var redoStack: [[AnnotationElement]] = []

    var currentTool: AnnotationTool = .arrow
    var currentColor: NSColor = .systemRed
    /// 当前线宽档位：新绘制的箭头/矩形采用；历史元素保留各自的 strokeWidth。
    var currentThickness: AnnotationThickness = .medium

    var onZoomChanged: ((CGFloat) -> Void)?
    var onHistoryChanged: ((Bool, Bool) -> Void)?   // (canUndo, canRedo)
    var onCancel: (() -> Void)?
    var onInteraction: (() -> Void)?                 // 画布任意点击 → 关闭悬浮色板

    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var activeTextEditor: AnnotationTextEditorView?
    private var zoomAnimationTimer: Timer?
    private var zoomAnimationStart: CFTimeInterval = 0
    private var isAnimatingZoom = false
    /// 方向键微调的撤销合并状态（见 nudgeSelected）。
    private var lastNudgeAt: Date?
    private var lastNudgeElementIndex: Int?

    // MARK: 对象式选中与手柄（主流批注交互：选中 → 移动/缩放/旋转/删除）

    /// 当前选中元素索引；nil = 无选中。
    private var selectedIndex: Int?
    /// 指针位置（图像坐标）：驱动隐性角点的浮现与线框光标判定。
    private var hoverPoint: NSPoint?
    /// 正在拖拽的手柄。
    private var activeHandle: HandleKind?
    /// 正在拖动元素本体。
    private var isMovingElement = false
    private var moveStartPoint: NSPoint?
    private var moveStartCenter: NSPoint?
    /// 旋转：按下时指针方位角 + 元素原始角度。
    private var rotateStartAngle: CGFloat = 0
    private var rotateStartRotation: CGFloat = 0
    /// 缩放：起始尺寸/字号、对角锚点（世界坐标）、被拖角相对锚的方向 (±1, ±1)。
    private var resizeStartSize = NSSize.zero
    private var resizeStartFontSize: CGFloat = 0
    private var resizeAnchorWorld = NSPoint.zero
    private var resizeCornerSign = NSPoint.zero
    /// 箭头端点拖拽：按下时另一端点（世界坐标，保持不动）。
    private var endpointDragStart: NSPoint?
    /// 就地编辑的文本元素索引（nil = 新建文本；绘制时跳过该元素避免叠显）。
    private var editingElementIndex: Int?
    /// 编辑中文本的锚点信息（提交时保持文本左上角位置与角度不变）。
    private var editingTextTopLeftImage: NSPoint?
    private var editingTextRotation: CGFloat = 0
    /// 编辑中文本的字号/基础框宽（图像像素）。缩放时按当前 scale 换算回视图 pt，
    /// 使编辑框始终与底层图像同比例呈现，缩放不改写最终提交结果。
    private var editingFontSizeImage: CGFloat = 16
    private var editingBoxWidthImage: CGFloat = 220

    /// 手柄种类。corner 索引：0 左上 1 右上 2 左下 3 右下（本地 y 向下）。
    private enum HandleKind: Equatable {
        case rotation
        case corner(Int)
        case arrowEndpoint(Int)   // 0 = 起点, 1 = 终点
    }

    /// 快照式撤销栈：每次提交变更前压入完整元素数组（上限 100 步）。
    private var historyStack: [[AnnotationElement]] = []
    private var gestureSnapshot: [AnnotationElement]?

    /// 调整选区模式：复用选区截图的角点/拖动交互，批注元素作为虚拟层保留不丢弃。
    private var isAdjustingSelection = false
    var onAdjustModeChanged: ((Bool) -> Void)?

    private enum AdjustCorner {
        case minXMinY, minXMaxY, maxXMinY, maxXMaxY
    }
    private var adjustDraggedCorner: AdjustCorner?
    private var adjustMoveStartPoint: NSPoint?
    private var adjustMoveStartOrigin: NSPoint?

    /// 视图坐标 y 向上，避免 flipped 上下文中 NSImage.draw 的方向颠倒问题；
    /// 元素 / 选区 / 文字 / 缩放等内部状态仍用图像坐标（左上原点、y 向下），
    /// 与 CGImage 像素坐标和用户期望一致。
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// 重置选中/手柄/移动状态（不触及文本编辑与历史栈）。
    private func resetSelectionState() {
        selectedIndex = nil
        activeHandle = nil
        isMovingElement = false
        moveStartPoint = nil
        moveStartCenter = nil
        endpointDragStart = nil
    }

    // MARK: 快照式历史（撤销/重做）

    /// 手势开始：记录当前元素快照（拖动/缩放/旋转结束时可与现状比对入栈）。
    private func beginGesture() {
        gestureSnapshot = elements
    }

    /// 手势结束：若元素发生变化，把起始快照压入撤销栈。
    private func endGesture() {
        guard let snapshot = gestureSnapshot else { return }
        gestureSnapshot = nil
        guard snapshot != elements else { return }
        historyStack.append(snapshot)
        if historyStack.count > Metrics.maxHistoryDepth { historyStack.removeFirst() }
        redoStack.removeAll()
        notifyHistoryAndRedraw()
    }

    /// 提交一次非手势变更（添加/删除/编辑）：先快照再改，由调用方完成 mutation。
    private func pushHistory() {
        // 任何非微调的历史入栈都会打断方向键微调的撤销合并（见 nudgeSelected）。
        lastNudgeAt = nil
        lastNudgeElementIndex = nil
        historyStack.append(elements)
        if historyStack.count > Metrics.maxHistoryDepth { historyStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = historyStack.popLast() else { return }
        redoStack.append(elements)
        elements = previous
        resetSelectionState()
        notifyHistoryAndRedraw()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        historyStack.append(elements)
        elements = next
        resetSelectionState()
        notifyHistoryAndRedraw()
    }

    // MARK: 坐标换算（图像坐标 y 向下 ↔ 画布坐标 y 向上，y 轴镜像）

    var scale: CGFloat {
        zoomRect.width > 0 ? bounds.width / zoomRect.width : 1
    }

    func viewPoint(fromImage p: NSPoint) -> NSPoint {
        NSPoint(
            x: bounds.minX + (p.x - zoomRect.minX) * scale,
            y: bounds.maxY - (p.y - zoomRect.minY) * scale
        )
    }

    func imagePoint(fromView p: NSPoint) -> NSPoint {
        NSPoint(
            x: zoomRect.minX + (p.x - bounds.minX) / scale,
            y: zoomRect.minY + (bounds.maxY - p.y) / scale
        )
    }

    /// 会话结束（保存/取消/关闭）后由窗口 orderOut 统一调用：
    /// 释放整屏 NSImage 与元素缓存，避免数十 MB 位图滞留到下一次会话。
    func releaseSessionResources() {
        image = nil
        imageRect = .zero
        elements.removeAll()
        redoStack.removeAll()
        historyStack.removeAll()
        gestureSnapshot = nil
        lastNudgeAt = nil
        lastNudgeElementIndex = nil
        // 与 configure() 的防御一致：终止可能残留的缩放动画，
        // 避免 Timer 对已隐藏窗口继续触发 onZoomChanged。
        zoomAnimationTimer?.invalidate()
        zoomAnimationTimer = nil
        isAnimatingZoom = false
        needsDisplay = true
    }

    // MARK: 配置与入场动画

    func configure(image cgImage: CGImage, selection: NSRect) {
        // 复用窗口前先终止上一会话可能残留的缩放动画，
        // 否则旧 Timer 会以 60fps 覆盖新会话的 zoomRect 并吞掉滚轮缩放。
        zoomAnimationTimer?.invalidate()
        zoomAnimationTimer = nil
        isAnimatingZoom = false
        self.image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        imageRect = NSRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        selectionRect = selection
        elements.removeAll()
        historyStack.removeAll()
        redoStack.removeAll()
        gestureSnapshot = nil
        // 重置调整选区模式的拖拽状态，避免复用窗口时残留。
        isAdjustingSelection = false
        adjustDraggedCorner = nil
        adjustMoveStartPoint = nil
        adjustMoveStartOrigin = nil
        // 重置选中与文本编辑状态。
        resetSelectionState()
        if let editor = activeTextEditor {
            editor.removeFromSuperview()
            activeTextEditor = nil
        }
        editingElementIndex = nil
        editingTextTopLeftImage = nil
        // 初始整图以 cover 模式铺满整个画布（长边超出被裁剪、无黑边无拉伸），
        // 选区以虚线框标注且保证可见；入场动画再聚焦放大到选区铺满。
        let aspect = bounds.width / max(1, bounds.height)
        zoomRect = Self.coverZoomRect(
            imageRect: imageRect,
            canvasAspect: aspect,
            keepVisible: selectionRect
        )
        onHistoryChanged?(false, false)
        onZoomChanged?(scale)
        needsDisplay = true
    }

    /// 入场动画：可见区从「选区原大小」动画放大到「选区铺满可用区域」。
    func startPresentZoomAnimation() {
        let aspect = bounds.width / max(1, bounds.height)
        let target = Self.fittedZoomRect(selectionRect, canvasAspect: aspect)
        animateZoom(to: target, duration: Metrics.presentAnimationDuration)
    }

    static func fittedZoomRect(_ rect: NSRect, canvasAspect: CGFloat) -> NSRect {
        guard rect.width > 0, rect.height > 0, canvasAspect > 0 else { return rect }
        let aspect = rect.width / rect.height
        let center = NSPoint(x: rect.midX, y: rect.midY)
        var width = rect.width
        var height = rect.height
        if aspect > canvasAspect {
            height = width / canvasAspect
        } else {
            width = height * canvasAspect
        }
        return NSRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
    }

    /// cover 模式可见区：图像「完整铺满」画布（长短边都覆盖、长边超出被裁剪），
    /// 用作整图背景。中心优先取 focus（可滑动选择裁剪区域），并保证 keepVisible
    /// （选区）完整可见；若选区过大无法同时满足，退回整图适配。
    static func coverZoomRect(
        imageRect: NSRect,
        canvasAspect: CGFloat,
        focus: NSPoint? = nil,
        keepVisible: NSRect? = nil
    ) -> NSRect {
        guard imageRect.width > 0, imageRect.height > 0, canvasAspect > 0 else { return imageRect }
        var width = imageRect.width
        var height = imageRect.height
        if imageRect.width / imageRect.height > canvasAspect {
            // 图像更宽：高度对齐、宽度放大超出（左右裁剪）
            height = imageRect.height
            width = height * canvasAspect
        } else {
            // 画布更宽（图像更高）：宽度对齐、高度放大超出（上下裁剪）
            width = imageRect.width
            height = width / canvasAspect
        }
        var cx = focus.map { min(max($0.x, imageRect.minX), imageRect.maxX) } ?? imageRect.midX
        var cy = focus.map { min(max($0.y, imageRect.minY), imageRect.maxY) } ?? imageRect.midY
        // cover 可见区是图像的裁剪窗口（⊆ 图像）：中心只能在「图像边 − 窗口边」的
        // slack 范围内滑动；被对齐的轴 slack 为 0，中心强制居中，窗口不会越出图像。
        let xSlack = max(0, (imageRect.width - width) / 2)
        let ySlack = max(0, (imageRect.height - height) / 2)
        cx = min(max(cx, imageRect.midX - xSlack), imageRect.midX + xSlack)
        cy = min(max(cy, imageRect.midY - ySlack), imageRect.midY + ySlack)
        let rect = NSRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height)
        if let keep = keepVisible, !rect.contains(keep) {
            // 选区被裁剪出可见区 → 退回整图适配，保证选区完整可见。
            return fittedZoomRect(imageRect, canvasAspect: canvasAspect)
        }
        return rect
    }

    // MARK: 缩放（按钮 / 滚轮 / 双指共用，围绕视口中心）

    /// 按钮缩放：平滑动画（easeInOutCubic 起停都柔和，连续点击时 animateZoom 会从当前状态续动）。
    func zoom(by factor: CGFloat) {
        guard !isAdjustingSelection, factor > 0 else { return }
        let target = zoomRectFor(factor: factor)
        animateZoom(to: target, duration: Metrics.zoomAnimationDuration, curve: Self.easeInOutCubic)
    }

    /// 计算按 factor 缩放后的目标可见区（围绕当前视口中心，含边界 clamp）。
    private func zoomRectFor(factor: CGFloat) -> NSRect {
        let aspect = bounds.width / max(1, bounds.height)
        let minWidth = imageRect.width / Metrics.maxZoomScale
        let maxWidth = imageRect.width * Metrics.maxOutspan
        let newWidth = min(max(zoomRect.width / factor, minWidth), maxWidth)
        let newHeight = newWidth / aspect
        let center = NSPoint(x: zoomRect.midX, y: zoomRect.midY)

        // 允许可见区边缘轻微越出图像边界（看选区外），但中心始终留在图像内。
        let originX = min(
            max(center.x - newWidth / 2, imageRect.minX - newWidth * 0.5),
            imageRect.maxX - newWidth * 0.5
        )
        let originY = min(
            max(center.y - newHeight / 2, imageRect.minY - newHeight * 0.5),
            imageRect.maxY - newHeight * 0.5
        )
        return NSRect(
            origin: NSPoint(x: originX, y: originY),
            size: NSSize(width: newWidth, height: newHeight)
        )
    }

    private func applyZoom(_ factor: CGFloat) {
        zoomRect = zoomRectFor(factor: factor)
        needsDisplay = true
        refreshTextEditorForZoom()
        onZoomChanged?(scale)
    }

    override func scrollWheel(with event: NSEvent) {
        guard !isAnimatingZoom, !isAdjustingSelection else { return }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        // 每 10 个单位滚动 ≈ 15% 缩放，方向：上滑放大。
        let factor = CGFloat(pow(1.15, Double(delta / 10)))
        applyZoom(factor)
    }

    override func magnify(with event: NSEvent) {
        guard !isAnimatingZoom, !isAdjustingSelection else { return }
        let factor = 1 + event.magnification
        guard factor > 0.05 else { return }
        applyZoom(factor)
    }

    private func animateZoom(
        to target: NSRect,
        duration: CFTimeInterval,
        curve: (@MainActor @Sendable (CGFloat) -> CGFloat)? = nil
    ) {
        zoomAnimationTimer?.invalidate()
        let startRect = zoomRect
        isAnimatingZoom = true
        zoomAnimationStart = CACurrentMediaTime()
        let ease = curve ?? Self.easeOutBack

        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = min(1, (CACurrentMediaTime() - self.zoomAnimationStart) / duration)
                let eased = ease(t)
                self.zoomRect = Self.interpolate(startRect, target, eased)
                self.needsDisplay = true
                self.refreshTextEditorForZoom()
                self.onZoomChanged?(self.scale)
                if t >= 1 {
                    self.zoomAnimationTimer?.invalidate()
                    self.zoomAnimationTimer = nil
                    self.isAnimatingZoom = false
                }
            }
        }
        zoomAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// easeOutBack：起步干脆、收尾带轻微弹性过冲（约 6%），缩放更有吸附感而不生硬。
    private static func easeOutBack(_ t: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.1
        let c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }

    /// easeInOutCubic：起停两侧都平滑（S 曲线），缩放观感更自然、无突兀的起步顿挫。
    private static func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private static func interpolate(_ a: NSRect, _ b: NSRect, _ t: CGFloat) -> NSRect {
        NSRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }

    // MARK: 元素操作

    /// 新增元素并入历史，同时选中新元素。
    private func addElement(_ element: AnnotationElement) {
        pushHistory()
        elements.append(element)
        selectedIndex = elements.count - 1
        notifyHistoryAndRedraw()
    }

    private func notifyHistoryAndRedraw() {
        onHistoryChanged?(!elements.isEmpty, !redoStack.isEmpty)
        needsDisplay = true
    }

    // MARK: 元素几何（本地 ↔ 世界，y 向下、rotation 正值视觉顺时针）

    private func elementLocalPoint(from p: NSPoint, element: AnnotationElement) -> NSPoint {
        let dx = p.x - element.center.x
        let dy = p.y - element.center.y
        let c = cos(element.rotation)
        let s = sin(element.rotation)
        return NSPoint(x: dx * c + dy * s, y: -dx * s + dy * c)
    }

    private func elementWorldPoint(local: NSPoint, element: AnnotationElement) -> NSPoint {
        let c = cos(element.rotation)
        let s = sin(element.rotation)
        return NSPoint(
            x: element.center.x + local.x * c - local.y * s,
            y: element.center.y + local.x * s + local.y * c
        )
    }

    /// 本地四角符号：0 左上 1 右上 2 左下 3 右下（本地 y 向下）。
    private static func cornerSign(_ index: Int) -> NSPoint {
        switch index {
        case 0: return NSPoint(x: -1, y: -1)
        case 1: return NSPoint(x: 1, y: -1)
        case 2: return NSPoint(x: -1, y: 1)
        default: return NSPoint(x: 1, y: 1)
        }
    }

    /// 归一化角度差到 (-π, π]。
    private static func angleDelta(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = a - b
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }

    private static func makeArrow(
        from start: NSPoint,
        to end: NSPoint,
        width: CGFloat,
        color: NSColor
    ) -> AnnotationElement {
        var element = AnnotationElement(kind: .arrow, color: color)
        let length = max(hypot(end.x - start.x, end.y - start.y), width * 4)
        element.center = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        element.size = NSSize(width: length, height: width)
        element.rotation = atan2(end.y - start.y, end.x - start.x)
        element.strokeWidth = width
        return element
    }

    // MARK: 交互

    /// 窗口非激活态下的首次点击也要送达画布：否则该次 mouseDown 被「激活窗口」吞掉，
    /// 拖动链路（dragStart 未设置）整段失效。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        let point = imagePoint(fromView: convert(event.locationInWindow, from: nil))
        // 正在就地编辑文本：本次点击只用于结束编辑（提交由字段回调完成），
        // 吞掉点击本身，避免同一次点击又触发新批注。
        if let editor = activeTextEditor {
            commitTextEditing(editor)
            return
        }
        if isAdjustingSelection {
            handleAdjustMouseDown(at: point)
            return
        }
        // 命中选中元素的手柄：缩放 / 旋转 / 箭头端点。
        if let handle = handleHit(at: point) {
            beginHandleDrag(handle, at: point)
            return
        }
        // 双击文本元素：进入就地编辑。
        if event.clickCount >= 2, let index = elementIndex(at: point),
           case .text = elements[index].kind {
            beginTextEditing(elementIndex: index)
            return
        }
        // 命中元素本体：选中 + 准备拖动移动（原地单击仅选中）。
        if let index = elementIndex(at: point) {
            selectedIndex = index
            isMovingElement = true
            moveStartPoint = point
            moveStartCenter = elements[index].center
            beginGesture()
            needsDisplay = true
            return
        }
        // 空白处：点击 = 取消选中（若随后拖动则照常绘制/编辑，与新批注互不冲突）。
        if selectedIndex != nil {
            selectedIndex = nil
            needsDisplay = true
        }
        switch currentTool {
        case .text:
            beginTextEditing(at: point)
        case .arrow, .rect:
            dragStart = point
            dragCurrent = point
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(fromView: convert(event.locationInWindow, from: nil))
        if isAdjustingSelection {
            if let corner = adjustDraggedCorner {
                updateAdjustSelection(corner: corner, point: point)
            } else if let start = adjustMoveStartPoint, let origin = adjustMoveStartOrigin {
                moveAdjustSelection(
                    by: NSPoint(x: point.x - start.x, y: point.y - start.y),
                    fromOrigin: origin
                )
            }
            needsDisplay = true
            return
        }
        if let handle = activeHandle {
            updateHandleDrag(handle, to: point)
            return
        }
        if isMovingElement {
            updateMove(to: point)
            return
        }
        guard dragStart != nil else { return }
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isAdjustingSelection {
            adjustDraggedCorner = nil
            adjustMoveStartPoint = nil
            adjustMoveStartOrigin = nil
            return
        }
        if activeHandle != nil {
            activeHandle = nil
            endpointDragStart = nil
            endGesture()
            return
        }
        if isMovingElement {
            isMovingElement = false
            moveStartPoint = nil
            moveStartCenter = nil
            endGesture()
            return
        }
        guard let start = dragStart, let current = dragCurrent else {
            dragStart = nil
            dragCurrent = nil
            return
        }
        dragStart = nil
        dragCurrent = nil

        let dx = current.x - start.x
        let dy = current.y - start.y
        guard abs(dx) + abs(dy) >= 2 else { return }   // 误触级拖拽忽略

        switch currentTool {
        case .arrow:
            addElement(Self.makeArrow(
                from: start, to: current, width: currentThickness.strokeWidth, color: currentColor
            ))
        case .rect:
            guard abs(dx) >= 8, abs(dy) >= 8 else { return }   // 过小没有缩放意义
            var element = AnnotationElement(kind: .rect, color: currentColor)
            element.center = NSPoint(x: (start.x + current.x) / 2, y: (start.y + current.y) / 2)
            element.size = NSSize(width: abs(dx), height: abs(dy))
            element.strokeWidth = currentThickness.strokeWidth
            addElement(element)
        case .text:
            break
        }
    }

    // MARK: 调整选区模式（复用选区截图逻辑：角点拖拽 + 框内整体平移）

    /// 进入调整选区模式：提交文本编辑、取消选中、拉回整图、激活选区角点与拖动。
    func beginAdjustingSelection() {
        if let editor = activeTextEditor { commitTextEditing(editor) }
        dragStart = nil
        dragCurrent = nil
        resetSelectionState()
        isAdjustingSelection = true
        onAdjustModeChanged?(true)
        // 拉回整图：cover 铺满全屏，中心对准选区，保证选区完整可见。
        let aspect = bounds.width / max(1, bounds.height)
        let target = Self.coverZoomRect(
            imageRect: imageRect,
            canvasAspect: aspect,
            focus: NSPoint(x: selectionRect.midX, y: selectionRect.midY),
            keepVisible: selectionRect
        )
        animateZoom(to: target, duration: Metrics.presentAnimationDuration)
        needsDisplay = true
    }

    /// 退出调整选区模式，回到批注编辑；批注元素与当前选区都保留，并平滑聚焦回选区铺满
    /// （避免停留在整图视图看到微小批注看不清）。
    func endAdjustingSelection() {
        isAdjustingSelection = false
        adjustDraggedCorner = nil
        adjustMoveStartPoint = nil
        adjustMoveStartOrigin = nil
        onAdjustModeChanged?(false)
        let aspect = bounds.width / max(1, bounds.height)
        let target = Self.fittedZoomRect(selectionRect, canvasAspect: aspect)
        animateZoom(to: target, duration: Metrics.presentAnimationDuration)
        needsDisplay = true
    }

    private func handleAdjustMouseDown(at point: NSPoint) {
        if let corner = adjustCorner(at: point) {
            adjustDraggedCorner = corner
        } else if selectionRect.contains(point) {
            // 点在选区内部：整体平移选区，像拖动一个块。
            adjustDraggedCorner = nil
            adjustMoveStartPoint = point
            adjustMoveStartOrigin = selectionRect.origin
        } else {
            adjustDraggedCorner = nil
            adjustMoveStartPoint = nil
            adjustMoveStartOrigin = nil
        }
    }

    private func adjustCorner(at imagePoint: NSPoint) -> AdjustCorner? {
        let hitRadius = Metrics.adjustHandleHitRadius / max(0.05, scale)   // 视图 pt → 图像坐标
        let corners: [(AdjustCorner, NSPoint)] = [
            (.minXMinY, NSPoint(x: selectionRect.minX, y: selectionRect.minY)),
            (.minXMaxY, NSPoint(x: selectionRect.minX, y: selectionRect.maxY)),
            (.maxXMinY, NSPoint(x: selectionRect.maxX, y: selectionRect.minY)),
            (.maxXMaxY, NSPoint(x: selectionRect.maxX, y: selectionRect.maxY))
        ]
        return corners.first { corner, p in
            hypot(imagePoint.x - p.x, imagePoint.y - p.y) <= hitRadius
        }?.0
    }

    private func adjustCornerPoint(_ corner: AdjustCorner) -> NSPoint {
        switch corner {
        case .minXMinY: return NSPoint(x: selectionRect.minX, y: selectionRect.minY)
        case .minXMaxY: return NSPoint(x: selectionRect.minX, y: selectionRect.maxY)
        case .maxXMinY: return NSPoint(x: selectionRect.maxX, y: selectionRect.minY)
        case .maxXMaxY: return NSPoint(x: selectionRect.maxX, y: selectionRect.maxY)
        }
    }

    private func updateAdjustSelection(corner: AdjustCorner, point: NSPoint) {
        let minSize = Metrics.adjustModeMinSize / max(0.05, scale)   // 视图 pt → 图像坐标
        var minX = selectionRect.minX
        var maxX = selectionRect.maxX
        var minY = selectionRect.minY
        var maxY = selectionRect.maxY

        switch corner {
        case .minXMinY:
            minX = min(point.x, maxX - minSize)
            minY = min(point.y, maxY - minSize)
        case .minXMaxY:
            minX = min(point.x, maxX - minSize)
            maxY = max(point.y, minY + minSize)
        case .maxXMinY:
            maxX = max(point.x, minX + minSize)
            minY = min(point.y, maxY - minSize)
        case .maxXMaxY:
            maxX = max(point.x, minX + minSize)
            maxY = max(point.y, minY + minSize)
        }

        selectionRect = NSRect(
            x: minX, y: minY, width: maxX - minX, height: maxY - minY
        ).intersection(imageRect)
        needsDisplay = true
    }

    /// 整体平移选区（尺寸不变），限制在图像边界内保证选区完整
    /// （选区大于图像时贴图像原点，避免 clamp 区间反转）。
    private func moveAdjustSelection(by delta: NSPoint, fromOrigin origin: NSPoint) {
        let maxX = max(imageRect.minX, imageRect.maxX - selectionRect.width)
        let maxY = max(imageRect.minY, imageRect.maxY - selectionRect.height)
        selectionRect.origin = NSPoint(
            x: min(max(origin.x + delta.x, imageRect.minX), maxX),
            y: min(max(origin.y + delta.y, imageRect.minY), maxY)
        )
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard activeTextEditor == nil else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == kVK_Escape {
            if isAdjustingSelection {
                endAdjustingSelection()   // 调整模式下 Esc 返回批注编辑，不丢批注
            } else if selectedIndex != nil {
                selectedIndex = nil       // 先取消选中，再次 Esc 才退出截图
                needsDisplay = true
            } else {
                onCancel?()
            }
            return
        }
        if !isAdjustingSelection, event.modifierFlags.contains(.command),
           event.keyCode == kVK_ANSI_Z {
            // ⌘Z 撤销 / ⇧⌘Z 重做（与工具栏按钮同一路径）。
            if event.modifierFlags.contains(.shift) { redo() } else { undo() }
            return
        }
        if !isAdjustingSelection, event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete {
            deleteSelected()
            return
        }
        if !isAdjustingSelection, selectedIndex != nil, (123...126).contains(event.keyCode) {
            nudgeSelected(keyCode: event.keyCode, fine: event.modifierFlags.contains(.shift))
            return
        }
        super.keyDown(with: event)
    }

    private func deleteSelected() {
        guard let index = selectedIndex, elements.indices.contains(index) else { return }
        pushHistory()
        elements.remove(at: index)
        selectedIndex = nil
        notifyHistoryAndRedraw()
    }

    /// 方向键微调选中元素（1 图像像素，Shift = 10）。
    /// 连续微调（0.8s 内、同一元素、中间无其他历史操作）只入栈一次快照：
    /// 否则按住方向键每秒产生十几条快照，会把撤销栈刷满单像素移动，
    /// 挤掉微调前的真实编辑。
    private func nudgeSelected(keyCode: UInt16, fine: Bool) {
        guard let index = selectedIndex, elements.indices.contains(index) else { return }
        let step: CGFloat = fine ? 10 : 1
        let now = Date()
        let isBurstContinuation = lastNudgeElementIndex == index
            && lastNudgeAt.map { now.timeIntervalSince($0) < 0.8 } == true
        if !isBurstContinuation {
            pushHistory()
        }
        lastNudgeAt = now
        lastNudgeElementIndex = index
        switch keyCode {
        case 123: elements[index].center.x -= step
        case 124: elements[index].center.x += step
        case 125: elements[index].center.y += step
        case 126: elements[index].center.y -= step
        default: break
        }
        needsDisplay = true
    }

    // MARK: 悬停跟踪（文本四角手柄显示）

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        // 悬停位置决定 cursor rect（手柄/线框/空白）与隐性角点是否浮现，移动时刷新即可。
        let previousCorner = hoveredCornerIndex()
        hoverPoint = imagePoint(fromView: convert(event.locationInWindow, from: nil))
        if hoveredCornerIndex() != previousCorner { needsDisplay = true }
        window?.invalidateCursorRects(for: self)
    }

    override func mouseExited(with event: NSEvent) {
        // 指针离开画布：隐性角点收起，否则会残留在最后悬停的角上。
        if hoveredCornerIndex() != nil { needsDisplay = true }
        hoverPoint = nil
        window?.invalidateCursorRects(for: self)
    }

    // MARK: 命中检测（自顶向下，后画的元素优先）

    /// 元素本体命中（旋转后按本地坐标判断，自顶向下）。
    /// 空心矩形只命中线框环带：框内空白不属于元素，点击穿透到下层。
    private func elementIndex(at p: NSPoint) -> Int? {
        for (index, element) in elements.enumerated().reversed() {
            let local = elementLocalPoint(from: p, element: element)
            switch element.kind {
            case .rect:
                guard isOnRectFrame(local: local, element: element) else { continue }
            case .arrow:
                let hitHeight = max(element.strokeWidth * 3.5, element.strokeWidth + 12)
                guard abs(local.x) <= element.size.width / 2,
                      abs(local.y) <= hitHeight / 2 else { continue }
            case .text:
                let hitWidth = element.size.width + 8
                let hitHeight = element.size.height + 8
                guard abs(local.x) <= hitWidth / 2,
                      abs(local.y) <= hitHeight / 2 else { continue }
            }
            return index
        }
        return nil
    }

    /// 本地坐标点是否落在空心矩形的线框上（线宽 + 视图 10pt 抓取容差）。
    private func isOnRectFrame(local: NSPoint, element: AnnotationElement) -> Bool {
        let band = element.strokeWidth / 2 + 10 / max(0.05, scale)
        let halfW = element.size.width / 2
        let halfH = element.size.height / 2
        let onVerticalEdge = abs(abs(local.x) - halfW) <= band && abs(local.y) <= halfH + band
        let onHorizontalEdge = abs(abs(local.y) - halfH) <= band && abs(local.x) <= halfW + band
        return onVerticalEdge || onHorizontalEdge
    }

    /// 指针当前悬停的角序号（nil = 没靠近任何角）。隐性角点只在被靠近时浮现。
    private func hoveredCornerIndex() -> Int? {
        guard let p = hoverPoint, let index = selectedIndex,
              elements.indices.contains(index) else { return nil }
        let element = elements[index]
        if case .arrow = element.kind { return nil }   // 箭头只有两个端点手柄
        let hit = Metrics.adjustHandleHitRadius / max(0.05, scale)
        for i in 0..<4 {
            let sign = Self.cornerSign(i)
            let corner = elementWorldPoint(
                local: NSPoint(x: sign.x * element.size.width / 2,
                               y: sign.y * element.size.height / 2),
                element: element
            )
            if hypot(p.x - corner.x, p.y - corner.y) <= hit { return i }
        }
        return nil
    }

    /// 旋转柄世界坐标：顶边中点上方伸出 26 视图 pt。
    private func rotationHandleWorld(element: AnnotationElement) -> NSPoint {
        let stem = 26 / max(0.05, scale)
        return elementWorldPoint(local: NSPoint(x: 0, y: -element.size.height / 2 - stem), element: element)
    }

    /// 手柄命中（半径 = 26 视图 pt 换算到图像单位）。
    private func handleHit(at p: NSPoint) -> HandleKind? {
        guard let index = selectedIndex, elements.indices.contains(index) else { return nil }
        let element = elements[index]
        let hit = Metrics.adjustHandleHitRadius / max(0.05, scale)
        if case .arrow = element.kind {
            let start = elementWorldPoint(local: NSPoint(x: -element.size.width / 2, y: 0), element: element)
            let end = elementWorldPoint(local: NSPoint(x: element.size.width / 2, y: 0), element: element)
            if hypot(p.x - start.x, p.y - start.y) <= hit { return .arrowEndpoint(0) }
            if hypot(p.x - end.x, p.y - end.y) <= hit { return .arrowEndpoint(1) }
            return nil
        }
        for i in 0..<4 {
            let sign = Self.cornerSign(i)
            let corner = elementWorldPoint(
                local: NSPoint(x: sign.x * element.size.width / 2, y: sign.y * element.size.height / 2),
                element: element
            )
            if hypot(p.x - corner.x, p.y - corner.y) <= hit { return .corner(i) }
        }
        let rotationHandle = rotationHandleWorld(element: element)
        if hypot(p.x - rotationHandle.x, p.y - rotationHandle.y) <= hit { return .rotation }
        return nil
    }

    // MARK: 手柄拖拽（缩放 / 旋转 / 箭头端点）

    private func beginHandleDrag(_ handle: HandleKind, at point: NSPoint) {
        guard let index = selectedIndex, elements.indices.contains(index) else { return }
        let element = elements[index]
        activeHandle = handle
        beginGesture()
        switch handle {
        case .rotation:
            rotateStartAngle = atan2(point.y - element.center.y, point.x - element.center.x)
            rotateStartRotation = element.rotation
        case let .corner(i):
            resizeStartSize = element.size
            resizeStartFontSize = element.fontSize
            resizeCornerSign = Self.cornerSign(i)
            // 对角锚点：被拖角的对角（世界坐标，拖拽期间保持不动）。
            let anchorLocal = NSPoint(
                x: -resizeCornerSign.x * element.size.width / 2,
                y: -resizeCornerSign.y * element.size.height / 2
            )
            resizeAnchorWorld = elementWorldPoint(local: anchorLocal, element: element)
        case let .arrowEndpoint(i):
            let otherLocal = NSPoint(x: (i == 0 ? 1 : -1) * element.size.width / 2, y: 0)
            endpointDragStart = elementWorldPoint(local: otherLocal, element: element)
        }
    }

    private func updateHandleDrag(_ handle: HandleKind, to point: NSPoint) {
        guard let index = selectedIndex, elements.indices.contains(index) else { return }
        switch handle {
        case .rotation:
            let center = elements[index].center
            let angle = atan2(point.y - center.y, point.x - center.x)
            var newRotation = rotateStartRotation + Self.angleDelta(angle, rotateStartAngle)
            // 吸附：±15° 倍数 ±4° 内吸附（含 0°/90° 等）。
            let step = CGFloat.pi / 12
            let snapped = (newRotation / step).rounded() * step
            if abs(Self.angleDelta(snapped, newRotation)) < 4 * .pi / 180 {
                newRotation = snapped
            }
            elements[index].rotation = newRotation
        case let .corner(i):
            updateResize(cornerIndex: i, to: point)
        case let .arrowEndpoint(i):
            updateArrowEndpoint(i, to: point)
        }
        needsDisplay = true
    }

    /// 拖角缩放：矩形自由宽高，文本等比缩放（字号同步）；对角锚定、带最小尺寸。
    private func updateResize(cornerIndex i: Int, to point: NSPoint) {
        guard let index = selectedIndex, elements.indices.contains(index) else { return }
        let element = elements[index]
        let sign = resizeCornerSign
        // 指针位置转到「锚点为原点、随元素旋转」的本地坐标系，再投影到被拖角方向。
        let d = NSPoint(x: point.x - resizeAnchorWorld.x, y: point.y - resizeAnchorWorld.y)
        let c = cos(element.rotation)
        let s = sin(element.rotation)
        let minSide = 12 / max(0.05, scale)   // 视图 12pt → 图像单位
        let lx = max((d.x * c + d.y * s) * sign.x, minSide)
        let ly = max((-d.x * s + d.y * c) * sign.y, minSide)

        let newSize: NSSize
        var newFontSize = element.fontSize
        if case .text = element.kind {
            // 文本：等比缩放，字号同步变化（clamp 到字号范围后反推实际比例）。
            let factorX = lx / max(resizeStartSize.width, 1)
            let factorY = ly / max(resizeStartSize.height, 1)
            let factor = max(min(factorX, factorY), 0.05)
            let fontSize = min(max(resizeStartFontSize * factor, Metrics.textMinFontSize),
                               Metrics.textMaxFontSize)
            let realFactor = fontSize / resizeStartFontSize
            newFontSize = fontSize
            newSize = NSSize(width: resizeStartSize.width * realFactor,
                             height: resizeStartSize.height * realFactor)
        } else {
            newSize = NSSize(width: lx, height: ly)
        }
        elements[index].size = newSize
        elements[index].fontSize = newFontSize
        // center = 锚点 + R·(sign·newSize/2)，保持对角不动。
        let halfX = sign.x * newSize.width / 2
        let halfY = sign.y * newSize.height / 2
        elements[index].center = NSPoint(
            x: resizeAnchorWorld.x + halfX * c - halfY * s,
            y: resizeAnchorWorld.y + halfX * s + halfY * c
        )
    }

    /// 拖箭头端点：另一端固定，重建箭头（长度/角度自然更新，最小长度防头部反转）。
    private func updateArrowEndpoint(_ i: Int, to point: NSPoint) {
        guard let index = selectedIndex, elements.indices.contains(index),
              let other = endpointDragStart else { return }
        let element = elements[index]
        let start = i == 0 ? point : other
        let end = i == 0 ? other : point
        let rebuilt = Self.makeArrow(from: start, to: end, width: element.strokeWidth, color: element.color)
        elements[index].center = rebuilt.center
        elements[index].size = rebuilt.size
        elements[index].rotation = rebuilt.rotation
    }

    /// 拖动移动：起始 center + 绝对位移（不逐帧累积），center clamp 在图像内。
    private func updateMove(to point: NSPoint) {
        guard let index = selectedIndex, let start = moveStartPoint, let origin = moveStartCenter else { return }
        let clamped = NSPoint(
            x: min(max(origin.x + point.x - start.x, imageRect.minX), imageRect.maxX),
            y: min(max(origin.y + point.y - start.y, imageRect.minY), imageRect.maxY)
        )
        elements[index].center = clamped
        needsDisplay = true
    }

    // MARK: 文本就地编辑（编辑器与元素同位、同角度、同字号）

    /// 开始就地编辑。elementIndex == nil：at 处新建文本；
    /// 非 nil：重编辑已有文本（预填内容，绘制时隐藏原元素，提交后原位替换）。
    private func beginTextEditing(elementIndex index: Int? = nil, at newPoint: NSPoint? = nil) {
        guard activeTextEditor == nil else { return }
        var fontSizeView: CGFloat
        var color: NSColor
        var initialText = ""
        var boxWidthView: CGFloat
        var rotation: CGFloat = 0
        if let index, elements.indices.contains(index), case let .text(text) = elements[index].kind {
            editingElementIndex = index
            let element = elements[index]
            fontSizeView = element.fontSize * scale
            color = element.color
            initialText = text
            boxWidthView = max(element.size.width * scale, 120)
            rotation = element.rotation
            editingTextTopLeftImage = elementWorldPoint(
                local: NSPoint(x: -element.size.width / 2, y: -element.size.height / 2),
                element: element
            )
        } else {
            editingElementIndex = nil
            fontSizeView = Metrics.textFontSize * scale
            color = currentColor
            boxWidthView = max(220 * scale, 160)
            editingTextTopLeftImage = newPoint
                ?? imagePoint(fromView: NSPoint(x: bounds.midX, y: bounds.midY))
        }
        editingTextRotation = rotation
        // 记录图像坐标系的字号/框宽（视图 pt ÷ 当前 scale），缩放时按新 scale 还原。
        editingFontSizeImage = fontSizeView / max(0.05, scale)
        editingBoxWidthImage = boxWidthView / max(0.05, scale)

        let editor = AnnotationTextEditorView()
        editor.configure(text: initialText, fontSize: fontSizeView, color: color, width: boxWidthView)
        editor.onCommit = { [weak self, weak editor] text in
            guard let self, let editor else { return }
            self.commitTextEditing(editor)
        }
        editor.onCancel = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.cancelTextEditing(editor)
        }
        editor.onContentChanged = { [weak self] in
            self?.layoutTextEditor()
        }
        addSubview(editor)
        activeTextEditor = editor
        layoutTextEditor()
        needsDisplay = true   // 绘制跳过编辑中的元素，避免原文本与编辑器叠显
        window?.makeFirstResponder(editor.editorTextView)
    }

    /// 编辑器布局：文本区左上角固定在元素文本左上角（世界位置不变），
    /// 编辑框 = 文本区外扩 padding，整体随元素旋转。
    private func layoutTextEditor() {
        guard let editor = activeTextEditor, let topLeftImage = editingTextTopLeftImage else { return }
        let padX: CGFloat = 8
        let padY: CGFloat = 5
        let textWidth = editor.requiredTextWidth
        let textHeight = editor.requiredTextHeight
        let editorWidth = textWidth + padX * 2
        let editorHeight = textHeight + padY * 2
        let topLeftView = viewPoint(fromImage: topLeftImage)
        let c = cos(editingTextRotation)
        let s = sin(editingTextRotation)
        // 编辑框中心相对文本左上角的本地偏移（y 向下）→ 视图偏移（y 翻转）。
        let lx = editorWidth / 2 - padX
        let ly = editorHeight / 2 - padY
        let offset = NSPoint(x: lx * c - ly * s, y: -(lx * s + ly * c))
        // 已旋转视图的 frame 语义受当前旋转影响：先归零 → 设 frame → 再施加旋转。
        editor.frameCenterRotation = 0
        editor.frame = NSRect(
            x: topLeftView.x + offset.x - editorWidth / 2,
            y: topLeftView.y + offset.y - editorHeight / 2,
            width: editorWidth,
            height: editorHeight
        )
        editor.frameCenterRotation = -editingTextRotation * 180 / .pi
        editor.setTextArea(rect: NSRect(x: padX, y: padY, width: textWidth, height: textHeight))
    }

    /// 缩放时同步编辑框：字号/基础框宽按「图像像素 × 当前 scale」换算，
    /// 保证编辑中的文字与底层图像同比例缩放，缩放不改写最终提交的字号。
    private func refreshTextEditorForZoom() {
        guard let editor = activeTextEditor else { return }
        editor.updateBaseWidth(editingBoxWidthImage * scale)
        editor.updateFontSize(editingFontSizeImage * scale)
        layoutTextEditor()
    }

    private func commitTextEditing(_ editor: AnnotationTextEditorView) {
        guard activeTextEditor === editor else { return }   // 防重复提交（回车+失焦双触发）
        let rawText = editor.string
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        activeTextEditor = nil
        editor.removeFromSuperview()
        defer {
            editingElementIndex = nil
            editingTextTopLeftImage = nil
            needsDisplay = true
            window?.makeFirstResponder(self)
        }

        // 保持文本左上角世界位置与角度不变，按新内容重排尺寸。
        let rotation = editingTextRotation
        let topLeft = editingTextTopLeftImage ?? .zero
        let fontSize = editor.currentFontSize / max(0.05, scale)   // 视图 pt → 图像像素
        let newSize = textSize(for: text, fontSize: fontSize)
        let c = cos(rotation)
        let s = sin(rotation)
        let center = NSPoint(
            x: topLeft.x + newSize.width / 2 * c - newSize.height / 2 * s,
            y: topLeft.y + newSize.width / 2 * s + newSize.height / 2 * c
        )

        if let index = editingElementIndex, elements.indices.contains(index) {
            // 重编辑：空文本 = 删除该元素（主流语义）；否则原位替换（保留颜色）。
            pushHistory()
            if text.isEmpty {
                elements.remove(at: index)
                selectedIndex = nil
            } else {
                var element = elements[index]
                element.kind = .text(text: text)
                element.fontSize = fontSize
                element.size = newSize
                element.center = center
                elements[index] = element
                selectedIndex = index
            }
        } else {
            // 新建：空文本 = 放弃。
            guard !text.isEmpty else { return }
            var element = AnnotationElement(kind: .text(text: text), color: editor.currentColor)
            element.fontSize = fontSize
            element.size = newSize
            element.center = center
            element.rotation = rotation
            pushHistory()
            elements.append(element)
            selectedIndex = elements.count - 1
        }
        notifyHistoryAndRedraw()
    }

    private func cancelTextEditing(_ editor: AnnotationTextEditorView) {
        guard activeTextEditor === editor else { return }
        activeTextEditor = nil
        editingElementIndex = nil
        editingTextTopLeftImage = nil
        editor.removeFromSuperview()
        needsDisplay = true   // 恢复显示被隐藏的原元素
        window?.makeFirstResponder(self)
    }

    /// 文本排版尺寸（图像坐标单位，含显式换行）。
    private func textSize(for text: String, fontSize: CGFloat) -> NSSize {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        return (text as NSString).size(withAttributes: [.font: font])
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image else { return }

        // NSImage.draw(in:from:) 的 from 矩形在非翻转上下文中按「图像底部原点」计算
        // （已实验 A/B/C/D 证实），而 zoomRect 是顶部原点图像坐标，必须镜像 y：
        //   from.y = imageRect.height - zoomRect.maxY  →  与 fittedRect 内 [zoomRect] 一致。
        // drawSelectionOutline / rectInView 等其它绘制已在视图侧镜像 y，单独修正这一处即可。
        let fromRect = NSRect(
            x: zoomRect.minX,
            y: imageRect.height - zoomRect.maxY,
            width: zoomRect.width,
            height: zoomRect.height
        )
        image.draw(in: bounds, from: fromRect, operation: .sourceOver, fraction: 1)

        if isAdjustingSelection {
            // 调整选区模式：整图 + 选区外遮罩 + 虚拟批注层 + 选区边框与角点。
            drawDimOverlay()
            for (index, element) in elements.enumerated() where index != editingElementIndex {
                draw(element)
            }
            drawAdjustBorderAndHandles()
        } else {
            drawDimOverlay()
            drawSelectionOutline()
            for (index, element) in elements.enumerated() where index != editingElementIndex {
                draw(element)
            }
            drawSelectionUI()
            if let start = dragStart, let current = dragCurrent {
                drawInProgress(from: start, to: current)
            }
        }
        // 不在 draw 尾部调 invalidateCursorRects：缩放动画 60fps 重绘时逐帧重建
        // 光标区（遍历全部元素算旋转角）纯属浪费；mouseMoved/Exited 处已按需刷新。
    }

    // MARK: 选中 UI（旋转后的边框 + 四角手柄 + 旋转柄 / 箭头双端点）

    private func drawSelectionUI() {
        guard let index = selectedIndex, elements.indices.contains(index),
              activeTextEditor == nil else { return }
        let element = elements[index]
        let handleRadius = 5.5   // 视图 pt

        func handleCircle(at point: NSPoint) {
            let frame = NSRect(x: point.x - handleRadius, y: point.y - handleRadius,
                               width: handleRadius * 2, height: handleRadius * 2)
            // 柔和投影让白色手柄在任何底色上都清晰浮起。
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.shadowBlurRadius = 2.5
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: frame).fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            let ring = NSBezierPath(ovalIn: frame)
            ring.lineWidth = 1
            ring.stroke()
            NSShadow().set()   // 清除投影，避免影响后续描边
        }

        NSGraphicsContext.saveGraphicsState()
        if case .arrow = element.kind {
            // 箭头：仅两个端点手柄（拖端点改长度与角度）。
            let start = viewPoint(fromImage: elementWorldPoint(
                local: NSPoint(x: -element.size.width / 2, y: 0), element: element))
            let end = viewPoint(fromImage: elementWorldPoint(
                local: NSPoint(x: element.size.width / 2, y: 0), element: element))
            handleCircle(at: start)
            handleCircle(at: end)
        } else {
            // rect / text：旋转后的四边形边框 + 四角手柄 + 顶部旋转柄。
            let corners = (0..<4).map { i -> NSPoint in
                let sign = Self.cornerSign(i)
                let world = elementWorldPoint(
                    local: NSPoint(x: sign.x * element.size.width / 2,
                                   y: sign.y * element.size.height / 2),
                    element: element
                )
                return viewPoint(fromImage: world)
            }
            let border = NSBezierPath()
            border.move(to: corners[0])
            border.line(to: corners[1])
            border.line(to: corners[3])
            border.line(to: corners[2])
            border.close()
            border.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.9).setStroke()
            border.stroke()

            if case .rect = element.kind {
                // 矩形：四角手柄隐性化 —— 默认不画，指针靠近某个角时才浮现，
                // 既保住拖角缩放的交互，又不让四个白点常驻干扰框内画面。
                if let hovered = hoveredCornerIndex() {
                    handleCircle(at: corners[hovered])
                }
            } else {
                for corner in corners {
                    handleCircle(at: corner)
                }
            }
            // 旋转柄：顶边中点上方 26 视图 pt，连接柄用短线。
            let topMid = viewPoint(fromImage: elementWorldPoint(
                local: NSPoint(x: 0, y: -element.size.height / 2), element: element))
            let rotateHandle = viewPoint(fromImage: rotationHandleWorld(element: element))
            let stem = NSBezierPath()
            stem.move(to: topMid)
            stem.line(to: rotateHandle)
            stem.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.9).setStroke()
            stem.stroke()
            handleCircle(at: rotateHandle)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: 鼠标光标

    override func resetCursorRects() {
        super.resetCursorRects()
        discardCursorRects()
        if isAdjustingSelection {
            // 调整模式：选区内 openHand（可整体平移），四角 crosshair（可拖角改大小）。
            let selRect = rectInView(selectionRect).insetBy(dx: -2, dy: -2)
            addCursorRect(selRect, cursor: .openHand)
            let handleSize: CGFloat = 30
            for corner in [AdjustCorner.minXMinY, .minXMaxY, .maxXMinY, .maxXMaxY] {
                let p = viewPoint(fromImage: adjustCornerPoint(corner))
                addCursorRect(
                    NSRect(x: p.x - handleSize / 2, y: p.y - handleSize / 2, width: handleSize, height: handleSize),
                    cursor: .crosshair
                )
            }
            return
        }
        // 编辑模式：默认按工具给光标（文本工具 iBeam，绘制工具 crosshair）。
        let base: NSCursor = (currentTool == .text) ? .iBeam : .crosshair
        addCursorRect(bounds, cursor: base)
        // 主体光标先加（后添加的 cursor rect 优先，手柄要盖在主体之上）。
        // 选中元素：arrow（拖动移动）；未选中：文本 iBeam（可双击编辑），其余 arrow（点击选中）。
        if let index = selectedIndex, elements.indices.contains(index) {
            addBodyCursor(elements[index], cursor: .arrow)
        }
        for (index, element) in elements.enumerated() where index != selectedIndex {
            let bodyCursor: NSCursor
            if case .text = element.kind {
                bodyCursor = .iBeam
            } else {
                bodyCursor = .arrow
            }
            addBodyCursor(element, cursor: bodyCursor)
        }
        // 选中元素的手柄：crosshair（缩放 / 旋转 / 箭头端点）。
        if let index = selectedIndex, elements.indices.contains(index) {
            let element = elements[index]
            let handleSize: CGFloat = 28
            func addHandleCursor(at world: NSPoint) {
                let p = viewPoint(fromImage: world)
                addCursorRect(
                    NSRect(x: p.x - handleSize / 2, y: p.y - handleSize / 2,
                           width: handleSize, height: handleSize),
                    cursor: .crosshair
                )
            }
            if case .arrow = element.kind {
                addHandleCursor(at: elementWorldPoint(
                    local: NSPoint(x: -element.size.width / 2, y: 0), element: element))
                addHandleCursor(at: elementWorldPoint(
                    local: NSPoint(x: element.size.width / 2, y: 0), element: element))
            } else {
                for i in 0..<4 {
                    let sign = Self.cornerSign(i)
                    addHandleCursor(at: elementWorldPoint(
                        local: NSPoint(x: sign.x * element.size.width / 2,
                                       y: sign.y * element.size.height / 2),
                        element: element))
                }
                addHandleCursor(at: rotationHandleWorld(element: element))
            }
        }
    }

    /// 元素可拖拽区域的光标：文本/箭头按整块包围盒，矩形只有线框（框内空白不属于元素）。
    private func addBodyCursor(_ element: AnnotationElement, cursor: NSCursor) {
        guard case .rect = element.kind else {
            addCursorRect(elementBodyRect(element), cursor: cursor)
            return
        }
        // 空心框的可交互区是一条环带，无法用轴对齐 rect 表达，
        // 改为在指针当前位置给一小块提示区（指针落在线框上时才加）。
        guard let p = hoverPoint,
              isOnRectFrame(local: elementLocalPoint(from: p, element: element),
                            element: element) else { return }
        let center = viewPoint(fromImage: p)
        addCursorRect(
            NSRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24),
            cursor: cursor
        )
    }

    /// 元素主体的视图坐标包围盒（旋转四角的轴对齐外包络 + 4pt 余量）。
    private func elementBodyRect(_ element: AnnotationElement) -> NSRect {
        let corners = (0..<4).map { i -> NSPoint in
            let sign = Self.cornerSign(i)
            let world = elementWorldPoint(
                local: NSPoint(x: sign.x * element.size.width / 2,
                               y: sign.y * element.size.height / 2),
                element: element
            )
            return viewPoint(fromImage: world)
        }
        let minX = corners.map(\.x).min() ?? 0
        let maxX = corners.map(\.x).max() ?? 0
        let minY = corners.map(\.y).min() ?? 0
        let maxY = corners.map(\.y).max() ?? 0
        return NSRect(x: minX - 4, y: minY - 4, width: maxX - minX + 8, height: maxY - minY + 8)
    }

    /// 选区外压暗遮罩、选区内透明（调整选区/批注两模式共用同一观感）。
    private func drawDimOverlay() {
        let selRect = rectInView(selectionRect)
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: selRect))
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.42).setFill()
        path.fill()
    }

    /// 调整选区模式边框 + 四角手柄（白色圆点，与选区截图一致）。
    /// 注意：selRect/角点均已是视图坐标，尺寸直接用视图 pt，不能再除以 scale
    /// （Retina 整图 scale≈0.5，除法会让手柄/边框放大一倍）。
    private func drawAdjustBorderAndHandles() {
        let selRect = rectInView(selectionRect)
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: selRect)
        path.lineWidth = 2
        path.stroke()

        let radius = Metrics.adjustHandleRadius
        for corner in [AdjustCorner.minXMinY, .minXMaxY, .maxXMinY, .maxXMaxY] {
            let p = viewPoint(fromImage: adjustCornerPoint(corner))
            let frame = NSRect(
                x: p.x - radius,
                y: p.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            NSColor.white.setFill()
            NSBezierPath(ovalIn: frame).fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            let ring = NSBezierPath(ovalIn: frame)
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    private func drawSelectionOutline() {
        let rect = rectInView(selectionRect)
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        path.setLineDash([6, 5], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.7).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 屏幕绘制：平移到元素中心并旋转 -rotation（视图 y 向上，与图像 y 向下符号相反），
    /// 元素统一以「中心为原点的本地矩形」绘制。
    private func draw(_ element: AnnotationElement) {
        let color = element.color
        let center = viewPoint(fromImage: element.center)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byRadians: -element.rotation)
        transform.concat()
        let width = element.size.width * scale
        let height = element.size.height * scale
        switch element.kind {
        case .rect:
            color.setStroke()
            let path = NSBezierPath(rect: NSRect(x: -width / 2, y: -height / 2, width: width, height: height))
            path.lineWidth = element.strokeWidth * scale
            path.stroke()
        case .arrow:
            drawArrow(
                from: NSPoint(x: -width / 2, y: 0),
                to: NSPoint(x: width / 2, y: 0),
                width: element.strokeWidth * scale,
                color: color
            )
        case let .text(text):
            drawTextLocal(text, fontSize: element.fontSize * scale, color: color)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawInProgress(from start: NSPoint, to end: NSPoint) {
        let color = currentColor.withAlphaComponent(0.85)
        switch currentTool {
        case .arrow:
            drawArrow(
                from: viewPoint(fromImage: start),
                to: viewPoint(fromImage: end),
                width: currentThickness.strokeWidth * scale,
                color: color
            )
        case .rect:
            let frame = NSRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            color.setStroke()
            let path = NSBezierPath(rect: rectInView(frame))
            path.lineWidth = currentThickness.strokeWidth * scale
            path.stroke()
        case .text:
            break
        }
    }

    /// 在已平移旋转的本地坐标系中绘制文本（rect 以原点为中心，随上下文翻转方向自动正确：
    /// 非翻转上下文从矩形 maxY 一侧排版、翻转上下文从 minY 一侧排版，均为「顶部起排」）。
    ///
    /// 排版尺寸必须用「本次绘制的字号」实测，不能沿用 element.size：
    /// element.size 是按图像像素字号量出的，而屏幕绘制发生在视图点字号上，字形步进取整
    /// 随字号变化（实测小字号下所需宽度可比按比例换算值宽 20%），两者并不成比例。直接
    /// 拿存储框宽排版会触发 draw(in:) 自动换行，末尾文字被挤到第二行、落在单行高的框外
    /// 而消失——表现为「缩小文字后末尾丢字，放大又出现」。+1 容差用于吸收浮点误差。
    private func drawTextLocal(_ text: String, fontSize: CGFloat, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: color
        ]
        let fit = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            in: NSRect(x: -(fit.width + 1) / 2, y: -(fit.height + 1) / 2,
                       width: fit.width + 1, height: fit.height + 1),
            withAttributes: attributes
        )
    }

    private func rectInView(_ imageFrame: NSRect) -> NSRect {
        NSRect(
            x: bounds.minX + (imageFrame.minX - zoomRect.minX) * scale,
            y: bounds.maxY - (imageFrame.maxY - zoomRect.minY) * scale,
            width: imageFrame.width * scale,
            height: imageFrame.height * scale
        )
    }

    /// 标准箭头：圆头线杆 + 实心三角头（截图标注工具的通用样式）。
    /// 屏幕绘制与离屏合成共用此实现（纯几何绘制，与坐标系翻转无关）。
    private func drawArrow(from start: NSPoint, to end: NSPoint, width: CGFloat, color: NSColor) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.01, width > 0 else { return }
        let angle = atan2(dy, dx)
        let dir = NSPoint(x: cos(angle), y: sin(angle))       // 沿杆单位向量
        let perp = NSPoint(x: -sin(angle), y: cos(angle))     // 垂直于杆的单位向量

        // 头部长 ≈ 3.5 倍杆宽，且不超过总长的 40%（极短拖拽时头不至于比杆还长）。
        let headLength = min(width * 3.5, length * 0.4)
        let headHalfWidth = width * 1.75   // 底边半宽 ≈ 1.75 倍杆宽，比例接近等边三角形

        // 箭杆：圆头线段，终点伸入头部底边内侧，避免圆头与三角之间出现接缝。
        color.setStroke()
        let shaft = NSBezierPath()
        shaft.lineWidth = width
        shaft.lineCapStyle = .round
        shaft.move(to: start)
        shaft.line(to: NSPoint(
            x: start.x + dir.x * (length - headLength * 0.6),
            y: start.y + dir.y * (length - headLength * 0.6)
        ))
        shaft.stroke()

        // 箭头头部：尖端在 end，底边中点沿杆后退 headLength，底边垂直于杆。
        let base = NSPoint(x: end.x - dir.x * headLength, y: end.y - dir.y * headLength)
        color.setFill()
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: NSPoint(x: base.x + perp.x * headHalfWidth, y: base.y + perp.y * headHalfWidth))
        head.line(to: NSPoint(x: base.x - perp.x * headHalfWidth, y: base.y - perp.y * headHalfWidth))
        head.close()
        head.fill()
    }

    // MARK: 离屏合成（选区原始分辨率 + 批注）

    func renderOutput() -> CGImage? {
        guard let image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let outputSize = CGSize(
            width: max(1, selectionRect.width.rounded()),
            height: max(1, selectionRect.height.rounded())
        )
        // 裁剪到选区原始分辨率；CGImage 像素坐标左上原点 y 向下，与 selectionRect 一致。
        // 取整后保持裁剪与输出尺寸一致，避免边缘半像素导致两者不对齐。
        let cropRect = CGRect(
            x: selectionRect.minX.rounded(),
            y: selectionRect.minY.rounded(),
            width: outputSize.width,
            height: outputSize.height
        )
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }

        // 显式 1:1 位图上下文：输出像素 = 选区源像素，与无批注裁剪路径（crop）
        // 分辨率一致。不用 NSImage + lockFocus：Retina 下 backing scale 2× 会把
        // 1× 源图插值放大一倍再输出（输出体积 ×4、清晰度反降）。
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
            data: nil,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // flipped=true：与原 lockFocusFlipped(true) 坐标系完全一致（y 向下），
        // 元素绘制代码（含 NSString.draw(in:) 的多行行序）无需任何改动。
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

        // 绘制图片：CTM flip × 1 抵消 flipped 上下文带来的方向颠倒（实验 p3 验证）。
        ctx.saveGState()
        ctx.translateBy(x: 0, y: outputSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cropped, in: CGRect(origin: .zero, size: outputSize))
        ctx.restoreGState()

        // 元素：image 坐标 y 向下，与 flipped 坐标系一致，直接绘制无需镜像。
        for element in elements {
            draw(element, forOutputBase: selectionRect)
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// 离屏合成绘制：坐标系与图像一致（y 向下），旋转用 +rotation（与屏幕 -rotation
/// 互为镜像补偿）。元素统一以「中心为原点的本地矩形」绘制，原始分辨率输出。
    private func draw(_ element: AnnotationElement, forOutputBase base: NSRect) {
        let color = element.color
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: element.center.x - base.minX, yBy: element.center.y - base.minY)
        transform.rotate(byRadians: element.rotation)
        transform.concat()
        switch element.kind {
        case .rect:
            color.setStroke()
            let path = NSBezierPath(rect: NSRect(
                x: -element.size.width / 2,
                y: -element.size.height / 2,
                width: element.size.width,
                height: element.size.height
            ))
            path.lineWidth = element.strokeWidth
            path.stroke()
        case .arrow:
            drawArrow(
                from: NSPoint(x: -element.size.width / 2, y: 0),
                to: NSPoint(x: element.size.width / 2, y: 0),
                width: element.strokeWidth,
                color: color
            )
        case let .text(text):
            drawTextLocal(text, fontSize: element.fontSize, color: color)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - 文本就地编辑器（与元素同位、同角度的多行编辑框）

@MainActor
final class AnnotationTextEditorView: NSView, NSTextViewDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onContentChanged: (() -> Void)?

    private let textView = NSTextView()
    private let placeholderLabel = NSTextField(labelWithString: "输入文本")
    /// 基础文本区宽度（视图 pt）：内容不足时保持该宽，超出时随内容扩展。
    private var baseWidth: CGFloat = 200

    /// 当前字号（视图 pt）。提交时由画布除以 scale 换算回图像像素。
    var currentFontSize: CGFloat { textView.font?.pointSize ?? 24 }
    var currentColor: NSColor { textView.textColor ?? .white }
    var string: String { textView.string }
    /// 供画布设置第一响应者（与代理方法 textView(_:doCommandBy:) 同名冲突，显式暴露）。
    var editorTextView: NSTextView { textView }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor

        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude)
        // 容器宽度不随视图、足够大：显式 \n 换行，usedRect 即内容真实宽高。
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = .zero
        textView.delegate = self
        addSubview(textView)

        placeholderLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        placeholderLabel.isEditable = false
        placeholderLabel.isHidden = true
        addSubview(placeholderLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, fontSize: CGFloat, color: NSColor, width: CGFloat) {
        baseWidth = max(width, 120)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        textView.font = font
        textView.textColor = color
        textView.typingAttributes = [.font: font, .foregroundColor: color]
        textView.string = text
        placeholderLabel.font = font
        updatePlaceholder()
        if !text.isEmpty {
            textView.selectAll(nil)   // 重编辑：全选便于整体替换
        }
    }

    /// 画布按布局结果设置文本区位置（编辑框坐标系内）。
    func setTextArea(rect: NSRect) {
        textView.frame = rect
        placeholderLabel.frame = rect
    }

    /// 缩放跟随：按新字号重建字体（非富文本模式下作用于全部文本），保留光标与选区。
    func updateFontSize(_ size: CGFloat) {
        guard abs(currentFontSize - size) > 0.1 else { return }
        let color = textView.textColor ?? .white
        let font = NSFont.systemFont(ofSize: size, weight: .medium)
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: color]
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
        }
        placeholderLabel.font = font
    }

    /// 缩放跟随：更新基础框宽（视图 pt），内容不足时框宽随缩放同步变化。
    func updateBaseWidth(_ width: CGFloat) {
        baseWidth = max(width, 120)
    }

    /// 文本区需要的宽度：max(基础宽, 内容宽)。
    var requiredTextWidth: CGFloat {
        max(baseWidth, ceil(textContentSize.width))
    }

    /// 文本区需要的高度：max(内容高, 单行高)。
    var requiredTextHeight: CGFloat {
        let lineHeight: CGFloat
        if let font = textView.font, let manager = textView.layoutManager {
            lineHeight = manager.defaultLineHeight(for: font)
        } else {
            lineHeight = 24
        }
        return max(ceil(textContentSize.height), lineHeight)
    }

    private var textContentSize: NSSize {
        guard let manager = textView.layoutManager, let container = textView.textContainer else {
            return .zero
        }
        return manager.usedRect(for: container).size
    }

    private func updatePlaceholder() {
        placeholderLabel.isHidden = !textView.string.isEmpty
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        updatePlaceholder()
        onContentChanged?()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Enter 提交（Shift+Enter 换行）；Esc 取消。
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if !shift {
                onCommit?(textView.string)
                return true
            }
            return false
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }

    func textDidEndEditing(_ notification: Notification) {
        onCommit?(textView.string)   // 失焦提交；画布侧有防重入
    }
}

// MARK: - 批注工具栏按钮

@MainActor
final class AnnotationToolbarButton: HoverTrackingButton {
    var isSelected = false {
        didSet { updateBackground() }
    }

    var titleColor: NSColor = LiquidGlassOverlayStyle.primaryTextColor() {
        didSet { refreshDisplay() }
    }

    /// 常态底色（半透明白，按钮在毛玻璃上有清晰的"钮"感）。
    var normalBackgroundColor: CGColor = NSColor.white.withAlphaComponent(0.08).cgColor {
        didSet { updateBackground() }
    }

    /// hover 底色。
    var hoverBackgroundColor: CGColor = NSColor.white.withAlphaComponent(0.24).cgColor {
        didSet { updateBackground() }
    }

    /// 选中底色。
    var selectedBackgroundColor: CGColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor {
        didSet { updateBackground() }
    }

    var onClick: (() -> Void)?

    /// 非 nil 时显示 SF Symbol 图标（title 仅作无障碍回退文本）。
    private var iconName: String?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(title: String) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        setButtonType(.momentaryChange)
        // 点击不抢键盘焦点：⌘Z / Esc / Delete 等快捷键始终作用于画布。
        refusesFirstResponder = true
        target = self
        action = #selector(clicked)
        // 必须把参数写入 NSButton.title，refreshDisplay() 读取的 self.title 才有内容。
        self.title = title
        refreshDisplay()
        updateBackground()
    }

    /// SF Symbol 图标按钮：以图标为主显示，title 仅作辅助信息（tooltip/无障碍）。
    convenience init(icon systemName: String, fallbackTitle: String) {
        self.init(title: fallbackTitle)
        iconName = systemName
        refreshDisplay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hoverStateChanged() {
        updateBackground()
    }

    @objc private func clicked() {
        onClick?()
    }

    /// 运行时改按钮显示内容（调整模式切换 ✓/‹ 等），icon 传 nil 显示文本。
    func setDisplay(title: String, icon: String?) {
        self.title = title
        iconName = icon
        refreshDisplay()
    }

    private func refreshDisplay() {
        if let iconName,
           let base = NSImage(systemSymbolName: iconName, accessibilityDescription: self.title),
           let symbol = base.withSymbolConfiguration(.init(pointSize: 12.5, weight: .medium)) {
            image = symbol
            imagePosition = .imageOnly
            title = ""
            attributedTitle = NSAttributedString()
            attributedAlternateTitle = NSAttributedString()
        } else {
            image = nil
            imagePosition = .noImage
            let attributed = LiquidGlassOverlayStyle.attributedText(
                self.title,
                font: NSFont.systemFont(ofSize: 13, weight: .medium),
                color: titleColor
            )
            attributedTitle = attributed
            attributedAlternateTitle = attributed
        }
        // SF Symbol 是模板图，用 contentTintColor 着色。
        contentTintColor = titleColor
    }

    private func updateBackground() {
        if isSelected {
            layer?.backgroundColor = selectedBackgroundColor
        } else if isHovering {
            layer?.backgroundColor = hoverBackgroundColor
        } else {
            layer?.backgroundColor = normalBackgroundColor
        }
    }
}

/// 当前批注颜色的矩形按钮：背景整块为选中色，文字固定「颜色」二字，
/// 文字颜色按背景亮度自动黑/白（亮底黑字、暗底白字），hover 提亮背景并重算。
@MainActor
final class AnnotationColorButton: HoverTrackingButton {
    var currentColor: NSColor = .systemRed {
        didSet { needsDisplay = true }   // 色点在 draw(_:) 自绘，改色必须显式触发重绘
    }

    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        setButtonType(.momentaryChange)
        refusesFirstResponder = true   // 点击不抢键盘焦点（快捷键始终作用于画布）
        title = ""
        attributedTitle = NSAttributedString()
        attributedAlternateTitle = NSAttributedString()
        target = self
        action = #selector(clicked)
        refreshStyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hoverStateChanged() {
        refreshStyle()
    }

    private func refreshStyle() {
        // 色点样式：按钮本体透明（hover 微亮），圆点自绘。
        layer?.backgroundColor = isHovering
            ? NSColor.white.withAlphaComponent(0.14).cgColor
            : NSColor.clear.cgColor
    }

    /// 自绘色点：16pt 圆 + 白色描边（亮暗截图背景上都清晰）。
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dotSize: CGFloat = 16
        let circle = NSRect(
            x: (bounds.width - dotSize) / 2,
            y: (bounds.height - dotSize) / 2,
            width: dotSize,
            height: dotSize
        )
        let path = NSBezierPath(ovalIn: circle)
        currentColor.setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    @objc private func clicked() {
        onClick?()
    }
}

/// 当前线宽的矩形按钮：自绘一条宽度随档位变化的水平短线作为"粗细"预览，
/// 点击弹出三档选择面板；hover 提亮背景（与 AnnotationColorButton 交互同构）。
@MainActor
final class AnnotationThicknessButton: HoverTrackingButton {
    var currentThickness: AnnotationThickness = .medium {
        didSet { needsDisplay = true }   // 线样在 draw(_:) 自绘，改档必须显式触发重绘
    }

    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        setButtonType(.momentaryChange)
        refusesFirstResponder = true   // 点击不抢键盘焦点（快捷键始终作用于画布）
        title = ""
        attributedTitle = NSAttributedString()
        attributedAlternateTitle = NSAttributedString()
        target = self
        action = #selector(clicked)
        refreshStyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hoverStateChanged() {
        refreshStyle()
    }

    private func refreshStyle() {
        // 按钮本体透明（hover 微亮），线样自绘。
        layer?.backgroundColor = isHovering
            ? NSColor.white.withAlphaComponent(0.14).cgColor
            : NSColor.clear.cgColor
    }

    /// 自绘线样：固定长度的水平短线，线宽 = 当前档位线宽（圆头，亮色在毛玻璃上清晰）。
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let length: CGFloat = 18
        let path = NSBezierPath()
        path.move(to: NSPoint(x: (bounds.width - length) / 2, y: bounds.midY))
        path.line(to: NSPoint(x: (bounds.width + length) / 2, y: bounds.midY))
        path.lineWidth = currentThickness.strokeWidth
        path.lineCapStyle = .round
        LiquidGlassOverlayStyle.primaryTextColor().setStroke()
        path.stroke()
    }

    @objc private func clicked() {
        onClick?()
    }
}

@MainActor
final class AnnotationToolbarView: NSView {
    enum Metrics {
        static let height: CGFloat = 46
        static let padding: CGFloat = 12
        static let gap: CGFloat = 6          // 组内间距
        static let groupGap: CGFloat = 12    // 功能组之间的间距
        static let buttonWidth: CGFloat = 34 // 图标按钮统一宽度
        static let buttonHeight: CGFloat = 30
        static let colorWidth: CGFloat = 36  // 颜色色点按钮
        static let thicknessWidth: CGFloat = 34 // 粗细预览按钮
        static let zoomButtonWidth: CGFloat = 30
        static let percentWidth: CGFloat = 48
        static let adjustButtonWidth: CGFloat = 40
        static let cornerRadius: CGFloat = 16
        static let hintWidth: CGFloat = 280   // 调整模式中间提示区宽度
    }

    var onClose: (() -> Void)?
    var onToolChange: ((AnnotationTool) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onSave: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onColorTap: (() -> Void)?
    var onThicknessTap: (() -> Void)?
    var onAdjustSelection: (() -> Void)?
    var onExitAdjustMode: (() -> Void)?

    private let closeButton = AnnotationToolbarButton(icon: "xmark", fallbackTitle: "关闭")
    private let colorButton = AnnotationColorButton()
    private let thicknessButton = AnnotationThicknessButton()
    private let textButton = AnnotationToolbarButton(icon: "textformat", fallbackTitle: "文本")
    private let arrowButton = AnnotationToolbarButton(icon: "arrow.up.right", fallbackTitle: "箭头")
    private let rectButton = AnnotationToolbarButton(icon: "rectangle", fallbackTitle: "矩形")
    private let undoButton = AnnotationToolbarButton(icon: "arrow.uturn.backward", fallbackTitle: "撤销")
    private let redoButton = AnnotationToolbarButton(icon: "arrow.uturn.forward", fallbackTitle: "还原")
    private let adjustButton = AnnotationToolbarButton(icon: "crop", fallbackTitle: "调整选区")
    private let zoomOutButton = AnnotationToolbarButton(icon: "minus.magnifyingglass", fallbackTitle: "缩小")
    private let zoomPercentLabel = NSTextField(labelWithString: "100%")
    private let zoomInButton = AnnotationToolbarButton(icon: "plus.magnifyingglass", fallbackTitle: "放大")
    private let saveButton = AnnotationToolbarButton(icon: "checkmark", fallbackTitle: "保存")

    /// 调整选区模式提示（占满中间弹性区域）。
    private let hintLabel = NSTextField(labelWithString: "拖动四角或框内移动，调整截图范围")
    private var isAdjustMode = false
    /// 毛玻璃铺底（持有引用以便内容宽度测量时排除自身）。
    private let glassBackground = LiquidGlassEffectView(frame: .zero)

    override var isFlipped: Bool { true }

    var currentTool: AnnotationTool = .arrow {
        didSet { updateToolSelection() }
    }

    var currentColor: NSColor = .systemRed {
        didSet { colorButton.currentColor = currentColor }
    }

    var currentThickness: AnnotationThickness = .medium {
        didSet { thicknessButton.currentThickness = currentThickness }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        // 毛玻璃铺底（替代原来的纯黑半透明，视觉更通透现代）。
        glassBackground.frame = bounds
        glassBackground.autoresizingMask = [.width, .height]
        LiquidGlassOverlayStyle.configureGlass(glassBackground, cornerRadius: Metrics.cornerRadius)
        addSubview(glassBackground, positioned: .below, relativeTo: nil)

        closeButton.titleColor = .systemRed
        closeButton.hoverBackgroundColor = NSColor.systemRed.withAlphaComponent(0.3).cgColor
        saveButton.titleColor = .systemGreen
        saveButton.hoverBackgroundColor = NSColor.systemGreen.withAlphaComponent(0.3).cgColor
        adjustButton.hoverBackgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor

        closeButton.toolTip = "关闭（Esc）"
        colorButton.toolTip = "批注颜色"
        thicknessButton.toolTip = "线条粗细"
        textButton.toolTip = "文本"
        arrowButton.toolTip = "箭头"
        rectButton.toolTip = "矩形"
        undoButton.toolTip = "撤销（⌘Z）"
        redoButton.toolTip = "还原（⇧⌘Z）"
        adjustButton.toolTip = "调整选区"
        zoomOutButton.toolTip = "缩小"
        zoomInButton.toolTip = "放大"
        saveButton.toolTip = "保存"

        closeButton.onClick = { [weak self] in self?.onClose?() }
        colorButton.onClick = { [weak self] in self?.onColorTap?() }
        thicknessButton.onClick = { [weak self] in self?.onThicknessTap?() }
        textButton.onClick = { [weak self] in self?.selectTool(.text) }
        arrowButton.onClick = { [weak self] in self?.selectTool(.arrow) }
        rectButton.onClick = { [weak self] in self?.selectTool(.rect) }
        undoButton.onClick = { [weak self] in self?.onUndo?() }
        redoButton.onClick = { [weak self] in self?.onRedo?() }
        adjustButton.onClick = { [weak self] in self?.onAdjustSelection?() }
        zoomOutButton.onClick = { [weak self] in self?.onZoomOut?() }
        zoomInButton.onClick = { [weak self] in self?.onZoomIn?() }
        // 保存按钮双语义：编辑模式 = 合成保存；调整模式 = 返回编辑（此时标题为「返回」）。
        saveButton.onClick = { [weak self] in
            guard let self else { return }
            self.isAdjustMode ? self.onExitAdjustMode?() : self.onSave?()
        }

        zoomPercentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zoomPercentLabel.textColor = LiquidGlassOverlayStyle.primaryTextColor()
        zoomPercentLabel.alignment = .center
        // 单行模式让文本在 frame 内垂直居中（默认多行排版会贴顶）。
        zoomPercentLabel.cell?.usesSingleLineMode = true

        hintLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        hintLabel.alignment = .center
        hintLabel.cell?.usesSingleLineMode = true
        hintLabel.isHidden = true

        for button in [closeButton, colorButton, thicknessButton, textButton, arrowButton, rectButton,
                       undoButton, redoButton, adjustButton, zoomOutButton, zoomInButton, saveButton] {
            addSubview(button)
        }
        addSubview(zoomPercentLabel)
        addSubview(hintLabel)

        updateToolSelection()
        updateHistory(canUndo: false, canRedo: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func selectTool(_ tool: AnnotationTool) {
        currentTool = tool
        onToolChange?(tool)
    }

    private func updateToolSelection() {
        textButton.isSelected = currentTool == .text
        arrowButton.isSelected = currentTool == .arrow
        rectButton.isSelected = currentTool == .rect
    }

    /// 切换调整选区模式：隐藏批注工具，仅保留居中的提示文本与最右的「返回」按钮
    /// （调整选区阶段不直接保存，返回编辑模式后再用绿色「保存」合成）。
    func setAdjustingSelection(_ adjusting: Bool) {
        isAdjustMode = adjusting
        adjustButton.isSelected = adjusting
        for view in [closeButton, colorButton, thicknessButton, textButton, arrowButton, rectButton,
                     undoButton, redoButton, adjustButton,
                     zoomOutButton, zoomPercentLabel, zoomInButton] {
            view.isHidden = adjusting
        }
        hintLabel.isHidden = !adjusting
        saveButton.setDisplay(title: adjusting ? "返回" : "保存", icon: adjusting ? "chevron.left" : "checkmark")
        saveButton.titleColor = adjusting
            ? LiquidGlassOverlayStyle.primaryTextColor()
            : .systemGreen
        saveButton.hoverBackgroundColor = adjusting
            ? NSColor.white.withAlphaComponent(0.24).cgColor
            : NSColor.systemGreen.withAlphaComponent(0.3).cgColor
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func updateZoomPercent(_ scale: CGFloat) {
        zoomPercentLabel.stringValue = "\(Int((scale * 100).rounded()))%"
    }

    func updateHistory(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        undoButton.alphaValue = canUndo ? 1 : 0.4
        redoButton.alphaValue = canRedo ? 1 : 0.4
    }

    /// 编辑模式内容宽度（与 layoutEditMode 的按钮顺序和间距一一对应）。
    /// 分组：[✕] [色点 粗细] [文本 箭头 矩形] [撤销 还原] [调整选区] [− % +] [✓]
    private static func editModeWidth() -> CGFloat {
        let widths: [CGFloat] = [
            Metrics.buttonWidth,                                        // ✕
            Metrics.colorWidth, Metrics.thicknessWidth,                 // 色点 粗细
            Metrics.buttonWidth, Metrics.buttonWidth, Metrics.buttonWidth,  // 文本 箭头 矩形
            Metrics.buttonWidth, Metrics.buttonWidth,                   // 撤销 还原
            Metrics.adjustButtonWidth,                                  // 调整选区
            Metrics.zoomButtonWidth, Metrics.percentWidth, Metrics.zoomButtonWidth,  // − % +
            Metrics.buttonWidth                                         // ✓ 保存
        ]
        let gaps: [CGFloat] = [
            Metrics.groupGap, Metrics.gap, Metrics.groupGap,    // ✕ | 色点 粗细 | 工具
            Metrics.gap, Metrics.gap,                           // 工具组内
            Metrics.groupGap, Metrics.gap,                      // 撤销还原
            Metrics.groupGap, Metrics.groupGap,                 // 调整 | 缩放
            Metrics.gap, Metrics.gap,                           // 缩放组内
            Metrics.groupGap                                    // 保存
        ]
        return Metrics.padding * 2 + widths.reduce(0, +) + gaps.reduce(0, +)
    }

    /// 调整模式内容宽度：提示区 + 返回按钮（返回位于最右端）。
    private static func adjustModeWidth() -> CGFloat {
        Metrics.padding * 2 + Metrics.hintWidth + Metrics.groupGap + Metrics.buttonWidth
    }

    override func layout() {
        super.layout()
        // 先收缩到内容宽度并水平居中（悬浮于画布之上），再按新尺寸排布按钮。
        let contentWidth = min(
            isAdjustMode ? Self.adjustModeWidth() : Self.editModeWidth(),
            superview?.bounds.width ?? .greatestFiniteMagnitude
        )
        let superWidth = superview?.bounds.width ?? contentWidth
        if abs(frame.width - contentWidth) > 0.5 {
            frame = NSRect(
                x: (superWidth - contentWidth) / 2,
                y: frame.minY,
                width: contentWidth,
                height: frame.height
            )
        }
        if isAdjustMode {
            layoutAdjustMode()
        } else {
            layoutEditMode()
        }
    }

    /// 单行 label 的垂直居中 frame：NSTextField label 在高于文本的 frame 内默认顶对齐
    /// （usesSingleLineMode 不改变垂直对齐），因此把高度收缩为文本自然高，再在工具栏内居中。
    private func verticallyCenteredLabelFrame(
        _ label: NSTextField,
        x: CGFloat,
        width: CGFloat
    ) -> NSRect {
        let textHeight = label.cell?.cellSize.height ?? Metrics.buttonHeight
        return NSRect(
            x: x,
            y: (Metrics.height - textHeight) / 2,
            width: width,
            height: textHeight
        )
    }

    private func layoutEditMode() {
        var x = Metrics.padding
        let y = (Metrics.height - Metrics.buttonHeight) / 2

        // 顺序与间距和 editModeWidth() 一一对应：组内 gap、组间 groupGap。
        closeButton.frame = NSRect(x: x, y: y, width: Metrics.buttonWidth, height: Metrics.buttonHeight)
        x = closeButton.frame.maxX + Metrics.groupGap
        colorButton.frame = NSRect(x: x, y: y, width: Metrics.colorWidth, height: Metrics.buttonHeight)
        x = colorButton.frame.maxX + Metrics.gap
        thicknessButton.frame = NSRect(x: x, y: y, width: Metrics.thicknessWidth, height: Metrics.buttonHeight)
        x = thicknessButton.frame.maxX + Metrics.groupGap
        for button in [textButton, arrowButton, rectButton] {
            button.frame = NSRect(x: x, y: y, width: Metrics.buttonWidth, height: Metrics.buttonHeight)
            x = button.frame.maxX + Metrics.gap
        }
        x += Metrics.groupGap - Metrics.gap
        undoButton.frame = NSRect(x: x, y: y, width: Metrics.buttonWidth, height: Metrics.buttonHeight)
        x = undoButton.frame.maxX + Metrics.gap
        redoButton.frame = NSRect(x: x, y: y, width: Metrics.buttonWidth, height: Metrics.buttonHeight)
        x = redoButton.frame.maxX + Metrics.groupGap
        adjustButton.frame = NSRect(x: x, y: y, width: Metrics.adjustButtonWidth, height: Metrics.buttonHeight)
        x = adjustButton.frame.maxX + Metrics.groupGap

        zoomOutButton.frame = NSRect(x: x, y: y, width: Metrics.zoomButtonWidth, height: Metrics.buttonHeight)
        x = zoomOutButton.frame.maxX + Metrics.gap
        zoomPercentLabel.frame = verticallyCenteredLabelFrame(zoomPercentLabel, x: x, width: Metrics.percentWidth)
        x = zoomPercentLabel.frame.maxX + Metrics.gap
        zoomInButton.frame = NSRect(x: x, y: y, width: Metrics.zoomButtonWidth, height: Metrics.buttonHeight)
        x = zoomInButton.frame.maxX + Metrics.groupGap

        saveButton.frame = NSRect(x: x, y: y, width: Metrics.buttonWidth, height: Metrics.buttonHeight)
    }

    private func layoutAdjustMode() {
        let y = (Metrics.height - Metrics.buttonHeight) / 2
        // 「返回」固定在最右端。
        saveButton.frame = NSRect(
            x: bounds.maxX - Metrics.padding - Metrics.buttonWidth,
            y: y,
            width: Metrics.buttonWidth,
            height: Metrics.buttonHeight
        )
        // 提示文本占据返回按钮左侧的整段区域，水平居中显示（垂直同样居中）。
        hintLabel.frame = verticallyCenteredLabelFrame(
            hintLabel,
            x: Metrics.padding,
            width: saveButton.frame.minX - Metrics.padding - Metrics.groupGap
        )
    }
}

// MARK: - 颜色选择面板

/// 预设色板：8 色圆点，选中即关闭；当前使用色带加粗白环指示。
@MainActor
final class AnnotationColorPanel: FloatingOverlayPanel {
    var onColorSelected: ((NSColor) -> Void)?

    /// 当前使用的批注颜色（打开面板时由窗口设置，用于选中环指示）。
    var selectedColor: NSColor? {
        didSet { refreshSwatchRings() }
    }

    private enum Metrics {
        static let swatchSize: CGFloat = 28
        static let swatchGap: CGFloat = 8
        static let padding: CGFloat = 10
        static let swatches: [NSColor] = [
            .systemRed, .systemOrange, .systemYellow, .systemGreen,
            .systemTeal, .systemBlue, .systemPurple, .white
        ]
        static var width: CGFloat {
            padding * 2 + swatchSize * CGFloat(swatches.count) + swatchGap * CGFloat(swatches.count - 1)
        }
        static var height: CGFloat { padding * 2 + swatchSize }
    }

    private var swatchButtons: [NSButton] = []

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureFloatingOverlay()
        level = ScreenshotWindowLevel.screenshot
        hasShadow = true

        let background = LiquidGlassEffectView(frame: contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        LiquidGlassOverlayStyle.configureGlass(background, cornerRadius: 12)
        contentView = background

        var x = Metrics.padding
        for (index, color) in Metrics.swatches.enumerated() {
            let button = NSButton(frame: NSRect(
                x: x,
                y: Metrics.padding,
                width: Metrics.swatchSize,
                height: Metrics.swatchSize
            ))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = Metrics.swatchSize / 2
            button.layer?.backgroundColor = color.cgColor
            button.layer?.borderWidth = 1
            button.layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
            button.toolTip = "使用该颜色"
            button.setButtonType(.momentaryChange)
            // 清掉 NSButton 默认的 "Button" 文本，否则会叠在色块上显示。
            button.title = ""
            button.attributedTitle = NSAttributedString()
            button.attributedAlternateTitle = NSAttributedString()
            button.target = self
            button.action = #selector(swatchClicked(_:))
            button.tag = index
            background.addSubview(button)
            swatchButtons.append(button)
            x += Metrics.swatchSize + Metrics.swatchGap
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 当前色对应色块：加粗白环；其余恢复细描边。
    private func refreshSwatchRings() {
        for (index, button) in swatchButtons.enumerated() {
            let isSelected = selectedColor.map { color in
                guard let a = color.usingColorSpace(.deviceRGB),
                      let b = Metrics.swatches[index].usingColorSpace(.deviceRGB) else { return false }
                return abs(a.redComponent - b.redComponent) < 0.01
                    && abs(a.greenComponent - b.greenComponent) < 0.01
                    && abs(a.blueComponent - b.blueComponent) < 0.01
            } ?? false
            button.layer?.borderWidth = isSelected ? 2.5 : 1
            button.layer?.borderColor = NSColor.white
                .withAlphaComponent(isSelected ? 1.0 : 0.55).cgColor
        }
    }

    @objc private func swatchClicked(_ sender: NSButton) {
        let index = sender.tag
        guard Metrics.swatches.indices.contains(index) else { return }
        onColorSelected?(Metrics.swatches[index])
    }
}

// MARK: - 粗细选择面板

/// 粗细选择面板的行按钮：左侧自绘该档位线样，右侧显示档位名（细/中/粗）；
/// 悬停微亮、当前档整行高亮。
@MainActor
private final class AnnotationThicknessRowButton: HoverTrackingButton {
    let option: AnnotationThickness
    var isRowSelected = false {
        didSet { needsDisplay = true }
    }
    var onClick: (() -> Void)?

    /// 本视图翻转为 y 向下坐标系，便于文字与图形按"顶部基准"排布。
    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(option: AnnotationThickness) {
        self.option = option
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        setButtonType(.momentaryChange)
        refusesFirstResponder = true
        title = ""
        attributedTitle = NSAttributedString()
        attributedAlternateTitle = NSAttributedString()
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hoverStateChanged() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isRowSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.30).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        } else if isHovering {
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }

        // 线样：固定长度的水平短线，宽度 = 该档位线宽（圆头，亮色在毛玻璃上清晰）。
        let sampleLength: CGFloat = 26
        let samplePath = NSBezierPath()
        samplePath.move(to: NSPoint(x: 14, y: bounds.midY))
        samplePath.line(to: NSPoint(x: 14 + sampleLength, y: bounds.midY))
        samplePath.lineWidth = option.strokeWidth
        samplePath.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.95).setStroke()
        samplePath.stroke()

        // 档位名（细/中/粗）。
        let name = option.displayName as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95)
        ]
        let nameSize = name.size(withAttributes: attributes)
        name.draw(
            at: NSPoint(x: 52, y: (bounds.height - nameSize.height) / 2),
            withAttributes: attributes
        )
    }

    @objc private func clicked() {
        onClick?()
    }
}

/// 粗细选择面板：三档（细/中/粗）行按钮纵向排列，当前档高亮；选中即回调并关闭。
@MainActor
final class AnnotationThicknessPanel: FloatingOverlayPanel {
    var onThicknessSelected: ((AnnotationThickness) -> Void)?

    /// 当前使用的线宽档位（打开面板时由窗口设置，用于行高亮）。
    var selectedThickness: AnnotationThickness? {
        didSet { refreshRowHighlight() }
    }

    private enum Metrics {
        static let padding: CGFloat = 8
        static let rowHeight: CGFloat = 34
        static let rowGap: CGFloat = 4
        static let width: CGFloat = 120
        static var height: CGFloat {
            padding * 2 + rowHeight * CGFloat(AnnotationThickness.allCases.count)
                + rowGap * CGFloat(AnnotationThickness.allCases.count - 1)
        }
    }

    private var rowButtons: [AnnotationThicknessRowButton] = []

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureFloatingOverlay()
        level = ScreenshotWindowLevel.screenshot
        hasShadow = true

        let background = LiquidGlassEffectView(frame: contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        LiquidGlassOverlayStyle.configureGlass(background, cornerRadius: 12)
        contentView = background

        // 面板坐标 y 向上：行自顶部向下逐个排布。
        let topY = Metrics.height - Metrics.padding - Metrics.rowHeight
        for (index, option) in AnnotationThickness.allCases.enumerated() {
            let row = AnnotationThicknessRowButton(option: option)
            row.frame = NSRect(
                x: Metrics.padding,
                y: topY - CGFloat(index) * (Metrics.rowHeight + Metrics.rowGap),
                width: Metrics.width - Metrics.padding * 2,
                height: Metrics.rowHeight
            )
            row.toolTip = "线宽：\(option.displayName)"
            row.onClick = { [weak self] in self?.onThicknessSelected?(option) }
            background.addSubview(row)
            rowButtons.append(row)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func refreshRowHighlight() {
        for row in rowButtons {
            row.isRowSelected = row.option == selectedThickness
        }
    }
}

// MARK: - 批注全屏窗口

@MainActor
final class ScreenshotAnnotationWindow: NSPanel {
    enum Metrics {
        static let toolbarHeight: CGFloat = AnnotationToolbarView.Metrics.height
        static let toolbarMargin: CGFloat = 10
    }

    private let containerView = NSView()
    private let canvasView = AnnotationCanvasView()
    private let toolbarView = AnnotationToolbarView()
    private let colorPanel = AnnotationColorPanel()
    private let thicknessPanel = AnnotationThicknessPanel()

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        level = ScreenshotWindowLevel.screenshot
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        acceptsMouseMovedEvents = true   // 画布悬停跟踪（文本四角手柄）需要 mouse-moved 事件
        contentView = containerView
        containerView.addSubview(canvasView)
        containerView.addSubview(toolbarView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(
        image: CGImage,
        selection: NSRect,
        screenFrame: NSRect,
        onSave: @escaping (CGImage) -> Void,
        onCancel: @escaping () -> Void
    ) {
        setFrame(screenFrame, display: true)

        containerView.frame = NSRect(origin: .zero, size: screenFrame.size)
        // 画布铺满全窗：图像以 cover 模式整屏铺满作为背景（无黑边、无拉伸）。
        canvasView.frame = NSRect(
            x: 0,
            y: 0,
            width: screenFrame.width,
            height: screenFrame.height
        )
        // 工具栏悬浮于画布之上、底部居中（layout() 会自动收缩到内容宽度并居中）。
        toolbarView.frame = NSRect(
            x: 0,
            y: Metrics.toolbarMargin,
            width: screenFrame.width,
            height: Metrics.toolbarHeight
        )

        canvasView.configure(image: image, selection: selection)
        toolbarView.currentTool = canvasView.currentTool
        toolbarView.currentColor = canvasView.currentColor
        toolbarView.currentThickness = canvasView.currentThickness
        toolbarView.setAdjustingSelection(false)   // 复用窗口时确保从编辑模式开始

        toolbarView.onClose = { [weak self] in
            self?.orderOut(nil)
            onCancel()
        }
        toolbarView.onToolChange = { [weak self] tool in
            self?.canvasView.currentTool = tool
        }
        toolbarView.onUndo = { [weak self] in self?.canvasView.undo() }
        toolbarView.onRedo = { [weak self] in self?.canvasView.redo() }
        toolbarView.onSave = { [weak self] in
            guard let self, let output = self.canvasView.renderOutput() else { return }
            self.orderOut(nil)
            onSave(output)
        }
        toolbarView.onZoomIn = { [weak self] in self?.canvasView.zoom(by: 1.25) }
        toolbarView.onZoomOut = { [weak self] in self?.canvasView.zoom(by: 0.8) }
        toolbarView.onColorTap = { [weak self] in self?.toggleColorPanel() }
        toolbarView.onThicknessTap = { [weak self] in self?.toggleThicknessPanel() }
        toolbarView.onAdjustSelection = { [weak self] in
            guard let self else { return }
            self.colorPanel.orderOut(nil)
            self.thicknessPanel.orderOut(nil)
            self.canvasView.beginAdjustingSelection()
        }
        toolbarView.onExitAdjustMode = { [weak self] in
            self?.canvasView.endAdjustingSelection()
        }
        canvasView.onAdjustModeChanged = { [weak self] adjusting in
            self?.toolbarView.setAdjustingSelection(adjusting)
        }
        canvasView.onZoomChanged = { [weak self] scale in
            self?.toolbarView.updateZoomPercent(scale)
        }
        canvasView.onHistoryChanged = { [weak self] canUndo, canRedo in
            self?.toolbarView.updateHistory(canUndo: canUndo, canRedo: canRedo)
        }
        canvasView.onCancel = { [weak self] in
            self?.orderOut(nil)
            onCancel()
        }
        canvasView.onInteraction = { [weak self] in
            guard let self else { return }
            self.colorPanel.orderOut(nil)
            self.thicknessPanel.orderOut(nil)
        }
        colorPanel.onColorSelected = { [weak self] color in
            guard let self else { return }
            self.canvasView.currentColor = color
            self.toolbarView.currentColor = color
            self.colorPanel.orderOut(nil)
        }
        thicknessPanel.onThicknessSelected = { [weak self] thickness in
            guard let self else { return }
            self.canvasView.currentThickness = thickness
            self.toolbarView.currentThickness = thickness
            self.thicknessPanel.orderOut(nil)
        }

        // 全局热键截图时本 App 往往不在前台：不显式激活，首次点击会被「激活窗口」
        // 吞掉（acceptsFirstMouse 缺省 false），表现为进入批注后第一次拖动无效。
        NSApp.activate()
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(canvasView)
        canvasView.startPresentZoomAnimation()
    }

    private func toggleColorPanel() {
        if colorPanel.isVisible {
            colorPanel.orderOut(nil)
            return
        }
        thicknessPanel.orderOut(nil)
        guard let colorButton = toolbarView.subviews.first(where: { $0 is AnnotationColorButton }) else {
            return
        }
        let rectInToolbar = colorButton.convert(colorButton.bounds, to: toolbarView)
        let rectInWindow = toolbarView.convert(rectInToolbar, to: nil)
        let rectInScreen = convertToScreen(rectInWindow)
        colorPanel.selectedColor = canvasView.currentColor   // 打开时同步当前色选中环
        colorPanel.show(at: NSPoint(x: rectInScreen.midX, y: rectInScreen.maxY))
    }

    private func toggleThicknessPanel() {
        if thicknessPanel.isVisible {
            thicknessPanel.orderOut(nil)
            return
        }
        colorPanel.orderOut(nil)
        guard let thicknessButton = toolbarView.subviews.first(where: { $0 is AnnotationThicknessButton }) else {
            return
        }
        let rectInToolbar = thicknessButton.convert(thicknessButton.bounds, to: toolbarView)
        let rectInWindow = toolbarView.convert(rectInToolbar, to: nil)
        let rectInScreen = convertToScreen(rectInWindow)
        thicknessPanel.selectedThickness = canvasView.currentThickness   // 打开时同步当前档位高亮
        thicknessPanel.show(at: NSPoint(x: rectInScreen.midX, y: rectInScreen.maxY))
    }

    override func orderOut(_ sender: Any?) {
        colorPanel.orderOut(nil)
        thicknessPanel.orderOut(nil)
        canvasView.releaseSessionResources()
        super.orderOut(sender)
    }
}

extension FloatingOverlayPanel {
    /// 悬浮面板锚定定位的公共水平计算：面板水平居中于锚点，并 clamp 到屏幕内（左右各留 8pt）。
    func clampedAnchorX(point: NSPoint, screenFrame: NSRect) -> CGFloat {
        min(
            max(point.x - frame.width / 2, screenFrame.minX + 8),
            screenFrame.maxX - frame.width - 8
        )
    }
}

extension AnnotationThicknessPanel {
    func show(at point: NSPoint) {
        let screenFrame = screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        // 水平居中于按钮，clamp 到屏幕内（同色板）；垂直优先置于按钮上方，
        // 上方放不下（如工具栏贴近屏顶）则翻转到下方。
        let x = clampedAnchorX(point: point, screenFrame: screenFrame)
        let aboveY = point.y + 6
        let y = aboveY + frame.height <= screenFrame.maxY
            ? aboveY
            : point.y - 6 - frame.height
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
    }
}

extension AnnotationColorPanel {
    func show(at point: NSPoint) {
        let screenFrame = screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        // 水平居中于按钮，但 clamp 到屏幕内：颜色按钮靠近左缘时防止色板左侧被裁掉。
        let x = clampedAnchorX(point: point, screenFrame: screenFrame)
        setFrameOrigin(NSPoint(x: x, y: point.y + 6))
        orderFrontRegardless()
    }
}

import AppKit

// MARK: - 页码预览（点击翻页栏页码标签弹出的竖排缩略图列表）

private enum PagePreviewMetrics {
    /// 容器到列表视口的内边距（上下左右一致）。页块宽度 = 窗口宽度 − 左右
    /// 内边距；窗口宽度自适应等于翻页栏宽度（show 时由锚 frame 决定）。
    static let padding: CGFloat = 10
    /// 卡片在列表视口内的水平余量：画框描边以路径为中心、外半约 1pt 压出
    /// 卡片矩形，留 2pt 后描边完整落在视口内，不再被 layer 圆角裁剪切边
    /// （此前左右描边被裁、观感比上下细的根因）。
    static let cardHInset: CGFloat = 2
    /// 卡片内容上下端留白 = 水平余量（描边外半 + 抗锯齿），保证滚动到首/尾
    /// 时端头卡片的描边同样不被裁；四边可视边距 = padding + 2 完全一致。
    static let contentTopPad: CGFloat = 2
    static let contentBottomPad: CGFloat = 2
    /// 相邻卡片间距。
    static let spacing: CGFloat = 10
    /// 图栏容器外圆角；列表视口圆角 = 容器圆角 − 内边距（与容器弧线同心）。
    static let cornerRadius: CGFloat = 20
    /// 卡片画框圆角。
    static let cardCornerRadius: CGFloat = 10
    /// 以当前页为锚上下各预取的页数：打开预览即请求「当前页 ± 8」邻域
    /// （交错顺序、可见页优先），滚动临近按需追加，翻页等待几乎无感。
    static let prefetchMargin = 8
    static let minHeight: CGFloat = 220
    static let maxHeight: CGFloat = 560
}

/// 页码缩略图预览窗口：竖排展示放映文稿各页缩略图，轻点某页跳转。
///
/// 结构与规格：
/// - **卡片**：内部从上到下排列的预览卡片 = 画框（圆角边框 + 右上角页码角标）
///   + 实际图片。卡片**宽度对齐图栏内宽，高度按该页图片的真实宽高比自适应**
///   （无图页暂以最近已知比例占位，页图到位即校正重排——不用全局默认比例）。
///   图片裁剪在画框内绘制，永不超出边框。
/// - **滚动**：滚轮/触控板走系统原生滚动增量；也可按住拖移平移上下滚动。
/// - **点按**：轻点某卡片（位移 < 4pt）跳转对应页码，预览图栏保持打开并
///   跟随新页码。
/// - **关闭**：本应用其他部分响应到点击（工具栏/翻页栏/画布/计时器等，local
///   监听）或点击落到外部进程时由兜底全屏透明遮罩（`SlideshowPreviewShieldWindow`）
///   拦截，两者都收起图栏。
/// - **裁剪**：图栏圆角裁剪自身外边角；列表视口同心圆角裁剪，上下滚动的
///   卡片在视口边缘被裁掉，不溢出容器。
///
/// 数据链路（当前页邻域按需懒加载，保证流畅）：
/// 1. 以视口/当前页为锚，按「当前 → 下一 → 上一 → 下二 → 上二…」的交错顺序
///    请求「锚点 ± 预取页数」内缺失的页（`onRequestPages`），可见页一批先发、
///    预取页随后一批——加载项串行处理，可见页永远优先到位；
/// 2. 控制器去重后经 WebSocket 下发 `export` 指令，WPS 加载项逐页导出 PNG，
///    逐页回报 `exported`（base64），控制器解码后经 `onPageImageReady` 交付；
/// 3. 页图真源是控制器侧的会话级内存库（上限 150 页 + 锚点保护带淘汰），
///    本窗口只持显示镜像，重开预览命中页即时回放（零请求、零解码）。
@MainActor
final class SlideshowPagePreviewWindow: NSPanel {
    /// 可视/预取范围内的页图请求（携带视口中心锚点页；控制器库内命中即时
    /// 交付、未命中才下发导出）。
    var onRequestPages: (([Int], Int) -> Void)?
    /// 轻点某页：跳转到该页（列表保持打开并跟随新页码）。
    var onJumpToPage: ((Int) -> Void)?

    private let listView = PageListView()
    /// 防穿透透明遮罩：预览显示期间覆盖放映整屏，拦截「落到外部进程」的
    /// 点击用于收起图栏（不依赖系统辅助功能 global 监听，见类型注释）。
    private let shieldWindow = SlideshowPreviewShieldWindow()
    /// 窗口宽度自适应等于翻页栏宽度（show 时由锚 frame 决定），init 兜底 140。
    private var windowWidth: CGFloat = 140
    /// 点外收起监听（local 收本应用点击；外部进程点击由遮罩拦截，见下）。
    private let outsideClickMonitor = OutsideClickDismissMonitor()
    private var isHiding = false

    /// 显隐意图（不受进出场动画窗口期影响）：show() 置 true、hide() 立即置 false。
    /// 外部 toggle / 收起判断一律用它——用 isVisible 判定会把「退场动画中仍可见」
    /// 的窗口误判成已展开，导致动画窗口期点击无任何反馈（同 SlideshowToolMenuWindow）。
    private(set) var isOpen = false

    /// 退场动画期间收到的进场请求（动画无法安全中途打断）：hide() 收尾完成后
    /// 自动补进，状态始终收敛到确定终态（同 SlideshowToolMenuWindow.pendingAnchor）。
    private var pendingShowAbove: NSRect?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        // 强制深色外观：与二级菜单/工具栏同一套深底白字观感。
        appearance = NSAppearance(named: .darkAqua)
        level = SlideshowFloatingLevel.chrome
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        backgroundColor = .clear
        isOpaque = false
        // 系统阴影已全家族禁用（残影根因，见 SlideshowToolMenuWindow 注释）。
        hasShadow = false
        ignoresMouseEvents = false

        shieldWindow.onIntercept = { [weak self] in self?.hide() }

        // 深色圆角底容器（layer 圆角裁剪自身外边角）+ 内嵌滚动列表视口
        // （列表 layer 同心圆角裁剪：上下滚动的卡片在视口边缘被裁掉）。
        let container = PreviewContainerView(frame: NSRect(origin: .zero, size: NSSize(width: windowWidth, height: 400)))
        container.autoresizingMask = [.width, .height]
        listView.frame = NSRect(
            x: PagePreviewMetrics.padding,
            y: PagePreviewMetrics.padding,
            width: windowWidth - PagePreviewMetrics.padding * 2,
            height: 400 - PagePreviewMetrics.padding * 2
        )
        listView.autoresizingMask = [.width, .height]
        listView.onRequestPages = { [weak self] pages, anchor in
            self?.onRequestPages?(pages, anchor)
        }
        listView.onJumpToPage = { [weak self] page in self?.onJumpToPage?(page) }
        container.addSubview(listView)
        contentView = container
    }

    required init?(coder: NSCoder) {
        fatalError("init?(coder:) has not been implemented")
    }

    // MARK: - 数据与显示

    /// 设置会话数据（打开前调用）。总页数未知（≤0）时由控制器守卫不弹预览。
    /// **不清任何页图状态**：显示镜像与会话级内存库跨开关复用，重开秒出。
    func configure(currentPage: Int, total: Int) {
        listView.configure(currentPage: currentPage, total: total)
    }

    /// 放映中翻页：列表跟随新当前页重新定位 + 按需请求。
    func updateCurrentPage(_ page: Int) {
        guard isOpen else { return }
        listView.updateCurrentPage(page)
    }

    /// 单页交付（控制器内存库已解码的成品图）：image 为空表示导出失败
    /// （保留占位、会话内不再重试）。
    func onPageImageReady(page: Int, image: NSImage?) {
        listView.onPageImageReady(page: page, image: image)
    }

    /// 锚定翻页面板正上方竖排显示：宽度自适应等于面板宽度（水平居中对齐
    /// 面板、夹屏内），高度自适应面板上方可用空间；打开时当前页垂直居中。
    /// 列表位置遵循列表边界：当前页尽量居中，第一页贴顶、最后一页贴底
    /// （clamp 自然保证）。
    func show(above navPanelScreenFrame: NSRect) {
        guard !isHiding, listView.totalPages > 0 else {
            // 退场动画中无法立刻进场：记录锚 frame，hide() 收尾自动补进。
            if isHiding { pendingShowAbove = navPanelScreenFrame }
            return
        }

        let screen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: navPanelScreenFrame.midX, y: navPanelScreenFrame.midY))
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        // 预览显示期间先铺全屏透明遮罩（层级在画布之下、外部应用之上），
        // 拦截落到外部进程的点击用于收起图栏；覆盖全部显示器。
        shieldWindow.coverAllScreens()

        let width = max(120, navPanelScreenFrame.width)
        windowWidth = width
        listView.tileWidth = width - PagePreviewMetrics.padding * 2

        // 翻页栏正上方：窗口底边 = 面板顶边 + 14pt 间距，向上取可用高度。
        let y = navPanelScreenFrame.maxY + 14
        let height = min(
            PagePreviewMetrics.maxHeight,
            max(PagePreviewMetrics.minHeight, visible.maxY - y - 8)
        )
        let x = min(max(navPanelScreenFrame.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)

        listView.scrollToCurrentPage()
        listView.requestVisiblePages()
        isOpen = true
        fadeIn()
        installOutsideClickMonitor()
    }

    func hide() {
        guard !isHiding else { return }
        isHiding = true
        isOpen = false
        removeOutsideClickMonitor()
        shieldWindow.lift()
        // 只收窗口：显示镜像保留（同批 NSImage 引用与会话级内存库共享），
        // 重开预览命中即达；内存库随放映会话结束才整体释放。
        guard isVisible else {
            isHiding = false
            if listView.totalPages > 0, let frame = pendingShowAbove {
                pendingShowAbove = nil
                show(above: frame)
            }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        } completionHandler: {
            self.orderOut(nil)
            self.alphaValue = 1
            self.isHiding = false
            if self.listView.totalPages > 0, let frame = self.pendingShowAbove {
                self.pendingShowAbove = nil
                self.show(above: frame)
            }
        }
    }

    private func fadeIn() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    /// 点外收起监听（**仅 local，不依赖系统辅助功能**）：
    ///
    /// - 点本软件内的窗口（工具栏/翻页栏/画布/计时器……）：层级都在遮罩与
    ///   预览之上，事件照常直达原窗口（原响应照常发生，如画布上画一笔），
    ///   本监听只补一刀收起图栏；
    /// - 点外部进程（幻灯片）：鼠标模式下画布穿透，事件落到全屏透明遮罩
    ///   （`SlideshowPreviewShieldWindow`，随 show 铺设、随 hide 撤除）被
    ///   拦截 → 回调 hide；画笔/橡皮模式下画布本身拦截 → 走上面 local 分支。
    private func installOutsideClickMonitor() {
        outsideClickMonitor.install(
            isExempt: { [weak self] event in
                // 自身已释放 / 不可见时不动作；点浮层自身窗口放行。
                guard let self, self.isVisible else { return true }
                return event.window === self
            },
            onDismiss: { [weak self] in self?.hide() }
        )
    }

    private func removeOutsideClickMonitor() {
        outsideClickMonitor.remove()
    }
}

/// 深色圆角底容器：layer 圆角裁剪**自身外边角**（窗口四角），子视图（列表
/// 视口）超出圆角的部分一并裁掉。
private final class PreviewContainerView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsLayer == false else { return }
        wantsLayer = true
        layer?.cornerRadius = PagePreviewMetrics.cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
    }
}

// MARK: - 竖排缩略图滚动列表（自绘）

/// 滚动列表视图：只绘制可视范围内的卡片（大文稿也不卡），状态（页图镜像/
/// 每页比例/当前页/偏移）集中在此，窗口只做定位与转发。
/// 自身 layer 同心圆角裁剪（cornerRadius = 容器圆角 − 内边距）：卡片滚出
/// 视口上下边缘即被裁掉，不溢出容器圆角卡。
@MainActor
private final class PageListView: NSView {
    var onRequestPages: (([Int], Int) -> Void)?
    var onJumpToPage: ((Int) -> Void)?

    private(set) var totalPages = 0
    private(set) var currentPage = 1
    /// 卡片宽度：show 时由窗口按「窗口宽 − 左右内边距」设定（= 翻页栏内容宽）。
    var tileWidth: CGFloat = 120 {
        didSet {
            guard oldValue != tileWidth else { return }
            relayout()
        }
    }
    /// 显示镜像：控制器内存库交付的成品图引用，按可视邻域裁剪（pruneMirror）。
    private var images: [Int: NSImage] = [:]
    /// 每页真实宽高比（宽/高），页图到位时校准该页并重排其后卡片。
    private var aspects: [Int: CGFloat] = [:]
    /// 最近已知真实比例：未加载页的占位高度依据（首图前兜底 16:9，任何一页
    /// 图到达后即跟随该文稿真实比例——不锁死默认比例）。
    private var knownAspect: CGFloat = 16.0 / 9.0
    /// 前缀高度：prefix[i] = 页 1..i 自顶部起的累计内容 y（含 spacing）。
    /// 高度逐页独立（比例自适应），页图到达只影响其后页的 y。
    private var prefix: [CGFloat] = []
    /// 滚动偏移（内容顶部到视口顶部的距离，isFlipped 坐标系）。
    private var offset: CGFloat = 0

    // 拖拽平移状态
    private var dragStartLocation: NSPoint?
    private var dragStartOffset: CGFloat = 0
    private var dragAccumulated: CGFloat = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsLayer == false else { return }
        wantsLayer = true
        layer?.cornerRadius = PagePreviewMetrics.cornerRadius - PagePreviewMetrics.padding
        layer?.masksToBounds = true
    }

    // MARK: - 几何（宽度对齐、高度按每页真实比例自适应）

    private func aspect(for page: Int) -> CGFloat {
        aspects[page] ?? knownAspect
    }

    private func pageHeight(_ page: Int) -> CGFloat {
        tileWidth / aspect(for: page)
    }

    private func relayout() {
        guard totalPages > 0 else {
            prefix = []
            return
        }
        var acc = PagePreviewMetrics.contentTopPad
        prefix = [acc]
        for page in 1...totalPages {
            acc += pageHeight(page) + PagePreviewMetrics.spacing
            prefix.append(acc)
        }
    }

    /// 卡片顶部在内容坐标系下的 y（顶部起）。
    private func cardTop(_ page: Int) -> CGFloat {
        guard page >= 1, page <= totalPages else { return 0 }
        return prefix[page - 1]
    }

    private var contentHeight: CGFloat {
        guard totalPages > 0 else { return 0 }
        return prefix[totalPages] - PagePreviewMetrics.spacing + PagePreviewMetrics.contentBottomPad
    }

    private var maxOffset: CGFloat { max(0, contentHeight - bounds.height) }

    // MARK: - 数据

    func configure(currentPage: Int, total: Int) {
        self.currentPage = max(currentPage, 1)
        totalPages = max(total, 0)
        relayout()
        offset = 0
        needsDisplay = true
    }

    func updateCurrentPage(_ page: Int) {
        guard page >= 1, page != currentPage else { return }
        currentPage = page
        needsDisplay = true
        if window?.isVisible == true { scrollToCurrentPage() }
        requestVisiblePages()
    }

    func scrollToCurrentPage() {
        let center = cardTop(currentPage) + pageHeight(currentPage) / 2
        offset = min(max(center - bounds.height / 2, 0), maxOffset)
        needsDisplay = true
    }

    /// 单页交付（控制器已解码的成品图）：存入显示镜像、校准该页真实比例、
    /// 重排其后卡片、重绘。
    func onPageImageReady(page: Int, image: NSImage?) {
        guard page >= 1 else { return }
        guard let image, image.size.width > 0, image.size.height > 0 else { return } // 失败：保留占位（控制器已记 failed，不重试）
        // 校准前记录当前可视首页顶部，重排后对齐回去，避免已滚位置跳动。
        let stablePage = visibleRange().lowerBound
        let stableTop = cardTop(stablePage) - offset

        images[page] = image
        let imageAspect = image.size.width / image.size.height
        let changed = abs(imageAspect - aspect(for: page)) > 0.001
        aspects[page] = imageAspect
        if changed {
            knownAspect = imageAspect
            relayout()
            // 保持刚才的首可视页在视口中的相对位置不动。
            offset = min(max(cardTop(stablePage) - stableTop, 0), maxOffset)
        }
        pruneMirror()
        needsDisplay = true
        requestVisiblePages()
    }

    /// 显示镜像裁剪：只保留可视 ±（2×预取 + 4）邻域内的引用。镜像被裁掉的
    /// 页不丢数据——控制器内存库仍在，滚回时请求即时回放。
    private func pruneMirror() {
        guard totalPages > 0, !images.isEmpty, bounds.height > 0 else { return }
        let range = visibleRange()
        let keep = range.upperBound - range.lowerBound + 1 + PagePreviewMetrics.prefetchMargin * 2 + 4
        guard images.count > keep * 2 + 8 else { return }
        let lo = range.lowerBound - keep
        let hi = range.upperBound + keep
        images = images.filter { lo...hi ~= $0.key }
    }

    // MARK: - 可视范围

    /// 当前视口覆盖的页范围（页高逐页独立，线性扫描即可，页数 ≤ 数百）。
    private func visibleRange() -> ClosedRange<Int> {
        guard totalPages > 0 else { return 1...1 }
        let viewTop = offset
        let viewBottom = offset + bounds.height
        var lower = totalPages
        var upper = 1
        for page in 1...totalPages {
            let top = cardTop(page)
            let bottom = top + pageHeight(page)
            if bottom > viewTop, top < viewBottom {
                lower = min(lower, page)
                upper = max(upper, page)
            }
        }
        guard lower <= upper else { return 1...1 }
        return lower...upper
    }

    // MARK: - 懒加载请求

    /// 请求「锚点 ± 预取页数」内缺失的页图，主流预览加载策略：
    /// - 锚点 = 视口中心页（随滚动实时更新，同步给控制器作淘汰基准）；
    /// - 缺失页按「锚 → 下 → 上 → 下二 → 上二…」交错排序，近页先到位，
    ///   不做从第一页起的顺序死等；
    /// - 可见页一批先发、预取页随后一批：加载项逐批串行导出，可见页永远
    ///   优先到位（在途/失败/已缓存页由控制器统一去重）。
    func requestVisiblePages() {
        guard totalPages > 0, bounds.height > 0, let onRequestPages else { return }
        pruneMirror()
        let visible = visibleRange()
        let anchor = min(max((visible.lowerBound + visible.upperBound) / 2, 1), totalPages)
        let first = max(1, visible.lowerBound - PagePreviewMetrics.prefetchMargin)
        let last = min(totalPages, visible.upperBound + PagePreviewMetrics.prefetchMargin)
        guard first <= last else { return }
        let missing = (first...last).filter { images[$0] == nil }
        guard !missing.isEmpty else { return }
        let visibleMissing = missing.filter { visible.contains($0) }
        if !visibleMissing.isEmpty {
            onRequestPages(orderByDistance(visibleMissing, from: anchor), anchor)
        }
        let prefetchMissing = missing.filter { !visibleMissing.contains($0) }
        if !prefetchMissing.isEmpty {
            onRequestPages(orderByDistance(prefetchMissing, from: anchor), anchor)
        }
    }

    /// 交错距离排序：锚点 0 → +1 → −1 → +2 → −2…（同距时靠后页优先，与
    /// 「当前页 → 下一页 → 上一页」的浏览习惯一致）。
    private func orderByDistance(_ pages: [Int], from anchor: Int) -> [Int] {
        pages.sorted {
            let da = abs($0 - anchor) * 2 + ($0 > anchor ? 0 : 1)
            let db = abs($1 - anchor) * 2 + ($1 > anchor ? 0 : 1)
            return da < db
        }
    }

    // MARK: - 滚动（滚轮/触控板按系统原生增量 + 拖拽平移）

    override func scrollWheel(with event: NSEvent) {
        guard contentHeight > bounds.height else { return }
        // 触摸板（精确滚动）：系统原生像素级 delta，取负 = 内容跟手；
        // 鼠标滚轮（非精确滚动）：scrollingDeltaY 不可用（为 0 或每格 ±1、
        // 体感滚不动），改用 deltaY（每格一格）×12 放大到合适体感。
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.deltaY * 12
        offset = min(max(offset - delta, 0), maxOffset)
        needsDisplay = true
        requestVisiblePages()
    }

    override func mouseDown(with event: NSEvent) {
        dragStartLocation = convert(event.locationInWindow, from: nil)
        dragStartOffset = offset
        dragAccumulated = 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartLocation else { return }
        let current = convert(event.locationInWindow, from: nil)
        let delta = start.y - current.y  // 翻转坐标：手指上移 → 内容下移
        dragAccumulated = max(dragAccumulated, abs(delta))
        offset = min(max(dragStartOffset + delta, 0), maxOffset)
        needsDisplay = true
        requestVisiblePages()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStartLocation = nil }
        // 位移极小视为轻点：命中卡片 → 跳转（预览图栏保持打开）。
        guard dragAccumulated < 4, dragStartLocation != nil, totalPages > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let contentY = point.y + offset
        guard let page = page(atContentY: contentY) else { return }
        onJumpToPage?(page)
    }

    /// 命中测试：内容 y → 页码（逐页边界判定，覆盖比例不一的卡片高度）。
    private func page(atContentY contentY: CGFloat) -> Int? {
        for page in 1...totalPages {
            let top = cardTop(page)
            let bottom = top + pageHeight(page) + PagePreviewMetrics.spacing / 2
            if contentY >= top, contentY < bottom {
                return page
            }
        }
        return nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - 绘制（只画可视卡片）

    override func draw(_ dirtyRect: NSRect) {
        guard totalPages > 0 else { return }
        for page in 1...totalPages {
            let rect = NSRect(
                x: PagePreviewMetrics.cardHInset,
                y: cardTop(page) - offset,
                width: tileWidth - PagePreviewMetrics.cardHInset * 2,
                height: pageHeight(page)
            )
            guard rect.maxY >= dirtyRect.minY, rect.minY <= dirtyRect.maxY else { continue }
            drawCard(page: page, rect: rect)
        }
    }

    /// 单张卡片 = 画框（圆角边框 + 右上角页码角标）+ 图片。图片裁剪在画框
    /// 圆角路径内绘制，永不超出边框；未加载页画同族深色占位 + 居中页码。
    private func drawCard(page: Int, rect: NSRect) {
        let isCurrent = page == currentPage
        let accent = NSColor(red: 0.25, green: 0.51, blue: 1.0, alpha: 1)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: PagePreviewMetrics.cardCornerRadius,
            yRadius: PagePreviewMetrics.cardCornerRadius
        )

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let image = images[page] {
            image.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.medium.rawValue]
            )
        } else {
            // 占位：与容器同族的深色底 + 居中页码。
            NSColor.white.withAlphaComponent(0.08).setFill()
            rect.fill()
            let text = "\(page)" as NSString
            let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            let size = text.size(withAttributes: [.font: font])
            text.draw(
                at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.40)]
            )
        }

        // 页码角标：贴右上角的**真角标**——缎带式平行四边形，斜边左上→右下
        // 倾斜（陡角：水平投影 ≈ 高度一半），仅斜边末端与底边交接处一个大圆角、
        // 其余三角保持直角——**容器角不自我圆角化**，画在卡片圆角裁剪区内由
        // 外部裁出圆角，与边框同色无缝贴合（未选中白底黑字、选中蓝底白字）。
        let label = "\(page)" as NSString
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        let labelSize = label.size(withAttributes: [.font: labelFont])
        let badgeHeight: CGFloat = 16
        let slantDX = badgeHeight * 0.5   // 斜边水平投影（陡角缎带样式）
        let slantRadius = badgeHeight * 0.4
        let badgeWidth = labelSize.width + 12 + slantDX
        let badgeLeft = rect.maxX - badgeWidth
        let badgeBottom = rect.minY + badgeHeight
        let slantEndX = badgeLeft + slantDX
        let slantLength = hypot(slantDX, badgeHeight)
        let badge = NSBezierPath()
        badge.move(to: NSPoint(x: badgeLeft, y: rect.minY))
        badge.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        badge.line(to: NSPoint(x: rect.maxX, y: badgeBottom))
        badge.line(to: NSPoint(x: slantEndX + slantRadius, y: badgeBottom))
        badge.curve(
            to: NSPoint(
                x: slantEndX - slantRadius * slantDX / slantLength,
                y: badgeBottom - slantRadius * badgeHeight / slantLength
            ),
            controlPoint1: NSPoint(x: slantEndX, y: badgeBottom),
            controlPoint2: NSPoint(x: slantEndX, y: badgeBottom)
        )
        badge.close()
        // 角标左下两边阴影：阴影只渲染在填充路径**外侧**——斜边/底边外
        // 侧是图片区，柔影可见；顶边/右边外侧在卡片外，被卡片圆角裁剪
        // 裁掉，不产生杂影。阴影仅作用于角标填充，随后的文字不带阴影。
        NSGraphicsContext.saveGraphicsState()
        let badgeShadow = NSShadow()
        badgeShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        badgeShadow.shadowBlurRadius = 4
        badgeShadow.shadowOffset = NSSize(width: 0, height: 0)
        badgeShadow.set()
        (isCurrent ? accent : NSColor.white.withAlphaComponent(0.92)).setFill()
        badge.fill()
        NSGraphicsContext.restoreGraphicsState()

        // 角标文字：斜边以右的可用区居中（中高度处斜边 x = badgeLeft + slantDX/2）。
        let textCenterX = rect.maxX - badgeWidth / 2 + slantDX / 4
        let textCenterY = rect.minY + badgeHeight / 2
        label.draw(
            at: NSPoint(x: textCenterX - labelSize.width / 2, y: textCenterY - labelSize.height / 2),
            withAttributes: [
                .font: labelFont,
                .foregroundColor: isCurrent
                    ? NSColor.white.withAlphaComponent(0.98)
                    : NSColor.black.withAlphaComponent(0.85)
            ]
        )
        NSGraphicsContext.restoreGraphicsState()

        // 画框：未选中页白边框；当前页蓝色边框（与角标同色，压在角标上无缝）。
        let lineWidth: CGFloat = isCurrent ? 2.0 : 1.2
        path.lineWidth = lineWidth
        (isCurrent ? accent : NSColor.white.withAlphaComponent(0.92)).setStroke()
        path.stroke()
    }
}

// MARK: - 预览防穿透遮罩（透明拦截层，替代辅助功能 global 监听）

/// 完全透明遮罩窗口：预览图栏显示期间覆盖放映整屏，层级在批注画布**之下**、
/// 全部外部应用**之上**（`SlideshowFloatingLevel.shield`）。
///
/// 事件分发逻辑：
/// - 本软件各窗口（画布/工具栏/翻页栏/计时器/草稿纸……）层级都在遮罩之上，
///   点击照常直达原窗口、原响应照常发生；预览由 local 监听负责收起；
/// - 鼠标模式下画布穿透，落到幻灯片（外部进程）的点击被遮罩拦下 → 回调
///   `onIntercept` 收起图栏（该次点击被遮罩消费，不再下传）；
/// - 画笔/橡皮模式画布本身拦截事件，遮罩只兜住画布不覆盖的缝隙区域。
///
/// 透明可命中：自绘 buffer 铺 1/255 黑填充——8-bit 缓冲的最小非零 alpha，
/// 肉眼不可见，但满足 WindowServer「非零 alpha 即命中」的判定。
private final class ShieldInterceptView: NSView {
    /// 遮罩被点击：桥接到窗口的 onIntercept。
    var onClick: (() -> Void)?

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(1.0 / 255.0).setFill()
        dirtyRect.fill()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

@MainActor
final class SlideshowPreviewShieldWindow: NSPanel {
    /// 遮罩被点击（拦截到落向外部进程的点击）：调用方据此收起预览图栏。
    var onIntercept: (() -> Void)? {
        didSet { (contentView as? ShieldInterceptView)?.onClick = onIntercept }
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        level = SlideshowFloatingLevel.shield
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        contentView = ShieldInterceptView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    required init?(coder: NSCoder) {
        fatalError("init?(coder:) has not been implemented")
    }

    /// 覆盖全部显示器：预览显示期间点击任何屏上的外部应用都由遮罩拦截
    /// （只盖放映屏时，点击另一台显示器的外部应用收不到事件，图栏无法收起）。
    /// 遮罩全透明、无边框，跨屏 setFrame 成本可忽略。
    func coverAllScreens() {
        let screens = NSScreen.screens
        guard let first = screens.first else { return }
        let union = screens.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        contentView?.setFrameSize(union.size)
        setFrame(union, display: false)
        alphaValue = 1
        orderFrontRegardless()
    }

    func lift() {
        orderOut(nil)
    }
}

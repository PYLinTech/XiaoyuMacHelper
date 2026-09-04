import AppKit

/// 幻灯片批注控制器：由 WPS 桥接加载项驱动生命周期（不使用进程/窗口探测）。
///
/// 工作机制：
/// - 勾选切换功能开关时才安装/卸载 WPS 加载项（程序启动不写盘，只按开关起停服务）；
/// - MacHelper 在 127.0.0.1 起本机 WebSocket 服务与加载项保持长连接；
/// - 加载项在 WPS 内监听放映事件，上报放映窗口的精确位置（VBA 语义：主屏左上原点、
///   y 向下、单位 pt）与当前页码（1 起，与 SlideIndex 一致）；
/// - 开始放映时按上报位置叠加批注层与三段式工具栏，翻页时按上报页码切换对应页批注；
/// - 左下 / 右下各一套翻页面板：左、当前页码/总页码、右；
/// - 翻页/退出通过 WebSocket 下发命令（加载项调用 View.Next/Previous/GotoSlide/Exit），
///   不再向系统投递按键；页码由加载项上报回传对齐；
/// - 加载项连接断开或心跳超时（WPS 被强退等异常）自动收起批注层。
@MainActor
final class SlideshowAnnotationController {
    private enum Metrics {
        /// 心跳超时阈值：加载项约 3 秒上报一次，超过该时长（约两拍）未收到视为放映已异常结束。
        static let heartbeatTimeout: TimeInterval = 8
        static let watchdogInterval: TimeInterval = 2
        /// 断线重连宽限：断开后保留批注数据等加载项重连补发 begin 的时长。
        /// 需覆盖休眠唤醒后的重连耗时（插件重连间隔 1~10s），取 30s。
        static let reconnectGraceInterval: TimeInterval = 30
    }

    private var currentSettings: AppSettings

    private var bridgeServer: SlideshowAnnotationBridgeServer?

    private var overlayWindow: SlideshowAnnotationOverlayWindow?
    private var toolsWindow: SlideshowAnnotationToolsWindow?
    private var leftNavWindow: SlideshowAnnotationNavigationWindow?
    private var rightNavWindow: SlideshowAnnotationNavigationWindow?

    private var isPresenting = false
    /// 当前页码（从 1 起，与 WPS SlideIndex 一致），用于按页存储批注。
    private var currentPageIndex = 1
    /// 演示文稿总页数；加载项取不到时保持 0（页码只显示当前页）。
    private var totalPageCount = 0
    /// 内存级批注数据：页码 → 该页批注。
    private var pageAnnotations: [Int: SlideshowSlideAnnotations] = [:]

    // MARK: 分源撤销链（按页 / 草稿纸各自独立成栈）

    /// 撤销链条目的作用目标：演示画布的某一页 / 草稿纸画布。
    private enum UndoTarget: Equatable, Hashable {
        case slidePage(page: Int)
        case scratchpad
    }

    /// 一次批注动作（画笔落盘 / 橡皮擦除 / 清空）的前后笔迹快照。
    /// `sequence` 为全会话单调递增序号：撤销时在当前页栈顶与草稿纸栈顶之间
    /// 取序号较大（最后发生）者；还原取序号较小（最早被撤销）者，
    /// 保证还原顺序与撤销顺序严格互逆。
    private struct UndoAction {
        let target: UndoTarget
        let sequence: Int
        let before: [SlideshowStroke]
        let after: [SlideshowStroke]
    }

    private enum UndoChainMetrics {
        /// 每个来源栈各自的上限（页与草稿纸互不挤占）。
        static let maxDepth = 100
    }

    /// 分源撤销/还原栈：每页一个栈 + 草稿纸一个栈，来源之间历史独立。
    /// 撤销/还原只在「当前页栈」与「草稿纸栈」之间按时间先后合并进行——
    /// 不跨页：其他页的栈顶不可达，翻回该页后继续其自身历史；
    /// 草稿纸栈跨页共享，任何时候都参与合并（逻辑独立、可跨页撤销还原）。
    private var undoStacks: [UndoTarget: [UndoAction]] = [:]
    private var redoStacks: [UndoTarget: [UndoAction]] = [:]
    /// 动作序号发生器（提交时递增，会话结束复位）。
    /// Int 在 Apple 平台为 64 位（上限 ~9.2e18）：序号每动作 +1，与万级笔迹
    /// 相差 14 个数量级，无溢出风险；且各来源栈受 maxDepth 截断，
    /// 序号仅作栈顶合并排序键，不参与存储规模。
    private var undoSequence = 0

    private var lastHeartbeatAt: Date?
    private var watchdogTimer: Timer?

    /// 自绘「退出放映」确认弹窗（当前展示中的实例，nil 表示未弹出）。
    private var exitConfirmWindow: SlideshowExitConfirmWindow?

    /// 自建工具（briefcase 二级菜单）窗口：当前放映会话内的实例。
    /// 放大镜在画布之下层（magnifier）；计时器/草稿纸为工具层（tool）。
    private var magnifierWindow: SlideshowMagnifierWindow?
    private var timerWindow: SlideshowTimerWindow?
    private var scratchpadWindow: SlideshowScratchpadWindow?

    /// 页码预览窗口（点击翻页栏页码标签弹出，会话内单例）。
    private var pagePreviewWindow: SlideshowPagePreviewWindow?

    // MARK: 页图内存库（会话级，预览开关不释放）

    /// 解码后的页图内存库：**存活于整个放映会话**——预览关闭只收窗口、不清
    /// 数据，重开预览/滚回已看区域命中即达（零请求、零解码）。上限
    /// `pageImageLimit` 页，超限按「距锚点页从远到近」淘汰；锚点 ± 保护带内
    /// 永不淘汰（可视区 + 预取的活跃邻域约 ±17 页，保护带大于它，滚动/跳页中
    /// 刚请求的页绝不会被淘汰——旧实现以“当前页”为基准且滚动不更新基准，
    /// 滚过 100 页后新图到达即被淘汰再重请求，形成“停止加载”死循环的根因）。
    private struct PageImageStore {
        var images: [Int: NSImage] = [:]
        /// 已请求未回执的页（去重，防止重复下发导出）。
        var inFlight: Set<Int> = []
        /// 导出/解码失败的页（会话内不重试，避免失败循环）。
        var failed: Set<Int> = []
        /// 距离淘汰基准：最近一次预览访问的视口中心页。
        var anchorPage = 1
    }
    private var pageImageStore = PageImageStore()
    /// 内存库上限（页）。
    private let pageImageLimit = 150
    /// 锚点保护带半径（页）：该范围内的页永不淘汰。
    private let pageImageProtectedRadius = 24
    /// 页图回执分块重组缓冲：page → (总块数, 已收分块 seq→base64 片段)。
    /// 页图到位或会话结束时清空。
    private var pendingPageExports: [Int: (total: Int, parts: [Int: String])] = [:]
    /// 截图工具复用的选区截图控制器（由 App 层注入）；截图链路完全同源。
    weak var screenshotToolbar: SelectionToolbarController?

    private var isEnabled: Bool {
        currentSettings.isSlideshowAnnotationEnabled
    }

    /// 请求启用提示（App 层先弹窗告知；用户确认后才由 performEnableInstall()
    /// 写 WPS 目录——跨容器访问会触发系统授权弹窗，顺序必须「先告知后请求」）。
    var onEnableNoticeRequested: (() -> Void)?
    /// 启用失败（插件写盘失败等）：携带原因，由 App 层回滚开关并告警。
    var onEnableFailed: ((String) -> Void)?

    init(settings: AppSettings) {
        currentSettings = settings
    }

    /// 程序启动：**仅开关开启时**起桥接服务。脚本更新检查不在启动时做——
    /// 由 App 层在自更新检查链路结束后走两步流程（先比对 isScriptUpdatePending()，
    /// 弹窗确认后 performScriptUpdate()）。
    func start() {
        guard isEnabled else { return }
        startBridgeServer()
    }

    /// 脚本更新检查分两步（均仅开关开启时执行）：
    /// ① `isScriptUpdatePending()` 只比对版本记录，零权限请求；
    /// ② `performScriptUpdate()` 由 App 层在用户确认弹窗后调用，才写 WPS 目录。
    func isScriptUpdatePending() -> Bool {
        guard isEnabled else { return false }
        return SlideshowAnnotationAddin.needsScriptRefresh
    }

    /// 脚本更新第二步（用户在提示弹窗点「知道了」后调用）：重装脚本并补写版本
    /// 记录。返回是否发生了更新（写盘失败返回 false，下次启动检查会自动重试）。
    @discardableResult
    func performScriptUpdate() -> Bool {
        guard isEnabled else { return false }
        return SlideshowAnnotationAddin.refreshInstalledIfNeeded()
    }

    /// 设置变更：仅在幻灯片批注开关位变化时起停服务/卸载插件，
    /// 其他设置字段变化不影响加载项（避免重复写盘）。
    /// 启用顺序：先由 App 层弹窗告知（onEnableNoticeRequested），用户确认后才
    /// 由 performEnableInstall() 写 WPS 目录——避免授权弹窗出现在说明之前。
    func update(settings: AppSettings) {
        let wasEnabled = currentSettings.isSlideshowAnnotationEnabled
        currentSettings = settings
        guard isEnabled != wasEnabled else { return }

        if isEnabled {
            onEnableNoticeRequested?()
        } else {
            stopBridgeServer()
            SlideshowAnnotationAddin.uninstall()
            teardownPresentation(reason: "功能已关闭")
        }
    }

    /// 启用第二步（用户在提示弹窗点「知道了」后调用）：写 WPS jsaddons（触发
    /// 系统授权请求），成功起服务；失败回滚开关状态并回调告警。
    func performEnableInstall() {
        guard isEnabled else { return }
        do {
            try SlideshowAnnotationAddin.install()
            SlideshowAnnotationLog.info("幻灯片批注已启用：加载项已写入 WPS jsaddons，需重启 WPS 生效")
            startBridgeServer()
        } catch {
            SlideshowAnnotationLog.info("幻灯片批注启用失败：加载项安装失败：\(error)")
            stopBridgeServer()
            // 回滚自身状态，与 App 层的开关回滚保持一致，避免下次 update 误判为已启用。
            currentSettings.isSlideshowAnnotationEnabled = false
            onEnableFailed?(error.localizedDescription)
        }
    }

    /// 停止闸门：stop() 后拒绝迟到的路由上报（已在队列中的 Task 仍会执行
    /// handleReport），防止把刚收起的批注层重新弹起；重启服务时复位。
    private var isStopped = false

    func stop() {
        // 仅停服务并收起界面，加载项保持安装状态（下次启动 WPS 仍可用）；
        // 卸载只发生在用户取消勾选时（update 内处理）。
        isStopped = true
        stopBridgeServer()
        teardownPresentation(reason: "控制器停止")
    }

    // MARK: - 桥接服务

    private func startBridgeServer() {
        guard bridgeServer == nil else { return }
        isStopped = false
        let server = SlideshowAnnotationBridgeServer { [weak self] endpoint in
            Task { @MainActor [weak self] in
                self?.handleReport(endpoint)
            }
        }
        server.start()
        bridgeServer = server
    }

    private func stopBridgeServer() {
        bridgeServer?.stop()
        bridgeServer = nil
    }

    // MARK: - 加载项上报处理

    private func handleReport(_ endpoint: SlideshowReportEndpoint) {
        guard isEnabled, !isStopped else { return }
        switch endpoint {
        case .begin(let report):
            beginPresentation(with: report)
        case .page(let index, let total):
            lastHeartbeatAt = Date()
            if let total { totalPageCount = total }
            switchToPage(index)
        case .end:
            // 加载项主动上报 = 真实放映结束：立即整体收层并清数据。
            teardownPresentation(reason: "放映结束(加载项上报)")
        case .connectionClosed:
            // 连接断开 ≠ 放映结束：可能是瞬断（休眠唤醒/网络抖动），加载项
            // 会重连并补发 begin 自愈。进入宽限挂起态，超时才收层清数据。
            suspendPresentationForReconnect()
        case .heartbeat:
            lastHeartbeatAt = Date()
        case .log(let message):
            SlideshowAnnotationLog.info("加载项: \(message)")
        case .exported(let page, let ok, let seq, let total, let data):
            // 大批量导出期间 WPS JS 上下文被导出长任务占住、心跳可能迟到：
            // exported 回执即活跃证据，顺带刷新看门狗时钟防误判收层。
            lastHeartbeatAt = Date()
            handlePageExported(page: page, ok: ok, seq: seq, total: total, chunk: data)
        }
    }

    // MARK: - 放映生命周期

    private func beginPresentation(with report: SlideshowBeginReport) {
        // 断线重连：挂起态下收到 begin = 加载项自愈补发。保留批注数据与
        // 撤销栈，仅重建 UI 并恢复当前页批注（页图内存库同文稿仍有效）。
        // 分块重组缓冲不跨连接复用，仍然清空。
        let isReconnect = isAwaitingReconnect
        if isReconnect {
            cancelReconnectGrace()
        } else if isPresenting {
            teardownPresentation(reason: "重复收到 begin")
        }
        isPresenting = true
        currentPageIndex = max(report.pageIndex ?? 1, 1)
        totalPageCount = max(report.totalPages ?? 0, 0)
        lastHeartbeatAt = Date()
        startWatchdog()
        // 页图导出目录由插件退出放映时自行清空（主程序不碰该目录）；
        // 页图内存库与分块重组状态随新会话复位（新文稿，旧图不可复用）。
        if isReconnect {
            pendingPageExports.removeAll()
        } else {
            pageImageStore = PageImageStore()
            pendingPageExports.removeAll()
        }

        let frame = Self.annotationFrame(for: report)
        let toolbarScreenFrame = Self.toolbarScreenFrame(containing: frame)
        SlideshowAnnotationLog.info(
            "放映开始 page=\(currentPageIndex)/\(totalPageCount) 上报(左上原点pt)=(\(report.x ?? 0),\(report.y ?? 0),\(report.width ?? 0),\(report.height ?? 0)) 叠加矩形=\(frame)"
        )

        let overlay = SlideshowAnnotationOverlayWindow(contentFrame: frame)
        let tools = SlideshowAnnotationToolsWindow()
        let leftNav = SlideshowAnnotationNavigationWindow()
        let rightNav = SlideshowAnnotationNavigationWindow()

        tools.onToolSelected = { [weak self] tool in self?.setTool(tool) }
        tools.onColorSelected = { [weak self] color in self?.setPenColor(color) }
        tools.onWidthSelected = { [weak self] index in self?.setPenWidth(index) }
        tools.onUndo = { [weak self] in self?.undo() }
        tools.onRedo = { [weak self] in self?.redo() }
        tools.onExit = { [weak self] in self?.exitPresentation() }
        tools.onClearScratchpad = { [weak self] in self?.clearScratchpad() }
        tools.onClearPage = { [weak self] in self?.clearCurrentPage() }
        tools.onToolItemSelected = { [weak self] item in self?.handleToolkitItem(item) }
        leftNav.onPrevious = { [weak self] in self?.previousPage() }
        leftNav.onNext = { [weak self] in self?.nextPage() }
        rightNav.onPrevious = { [weak self] in self?.previousPage() }
        rightNav.onNext = { [weak self] in self?.nextPage() }
        // 点击页码标签 → 页码预览（锚点 = 被点标签的屏幕 frame）。
        leftNav.onPageLabelClick = { [weak self] frame in self?.togglePagePreview(labelScreenFrame: frame) }
        rightNav.onPageLabelClick = { [weak self] frame in self?.togglePagePreview(labelScreenFrame: frame) }

        overlayWindow = overlay
        toolsWindow = tools
        leftNavWindow = leftNav
        rightNavWindow = rightNav

        // 画布一笔结束（画笔落盘 / 橡皮擦除 / 清空）时，把当前页批注写回内存映射。
        overlay.canvas.onStrokeEnded = { [weak self] in
            self?.saveCurrentPageAnnotations()
        }
        // 演示画布动作提交分源撤销栈：目标记录提交时的页码，该页历史独立，
        // 撤销/还原只作用于当前页（不跨页），草稿纸栈跨页共享。
        overlay.canvas.onActionCommitted = { [weak self] before, after in
            self?.commitUndoAction(.slidePage(page: self?.currentPageIndex ?? 1), before: before, after: after)
        }

        loadCurrentPageAnnotations()
        updatePageIndicator()

        overlay.show()
        tools.positionAtBottom(of: toolbarScreenFrame, anchor: .center)
        tools.show()
        leftNav.positionAtBottom(of: toolbarScreenFrame, anchor: .leading, horizontalMargin: 8)
        leftNav.show()
        rightNav.positionAtBottom(of: toolbarScreenFrame, anchor: .trailing, horizontalMargin: 8)
        rightNav.show()
    }

    // MARK: - 重连宽限

    /// 断线挂起态：true = 连接断开后正在等待加载项重连补发 begin（UI 已收起、
    /// 批注数据与撤销栈保留）。宽限超时或任何整体收层路径都会复位。
    private var isAwaitingReconnect = false
    private var reconnectGraceWork: DispatchWorkItem?

    /// 连接断开时的挂起：收起批注 UI 与看门狗，但保留批注数据、撤销栈与
    /// 页图内存库，等待加载项重连补发 begin 后无缝恢复。宽限超时才整体
    /// 收层清数据——否则任何瞬断都会把用户放映中途的批注全部抹掉，
    /// 加载项的「重连自愈」形同虚设。
    private func suspendPresentationForReconnect() {
        guard isPresenting else { return }
        SlideshowAnnotationLog.info("批注层挂起等待重连(连接断开，宽限 \(Int(Metrics.reconnectGraceInterval))s)")
        isPresenting = false
        isAwaitingReconnect = true
        dismissPresentationUI()
        stopWatchdog()
        lastHeartbeatAt = nil
        startReconnectGraceTimer()
    }

    /// 收起批注层全部 UI（teardown 与挂起共用；不碰任何会话数据）。
    private func dismissPresentationUI() {
        // 工具胶囊若仍挂着（心跳超时/放映结束等路径），一并收起避免残留浮窗。
        toolsWindow?.hideToolMenus()
        // 自建工具（放大镜/计时器/草稿纸）随会话一起收起；计时器需真正停止并复位。
        dismissToolkitTools()
        overlayWindow?.orderOut(nil)
        // 工具栏与左右翻页栏带轻微退场动画（淡出下沉），动画结束自行 orderOut。
        toolsWindow?.dismissAnimated()
        leftNavWindow?.dismissAnimated()
        rightNavWindow?.dismissAnimated()
        // 退出确认弹窗若仍挂着（经功能关闭/放映结束/心跳超时等路径收起）一并关闭。
        exitConfirmWindow?.hide()
        exitConfirmWindow = nil
        // 页码预览一并收起（会话结束：窗口与其显示镜像一并释放）。
        pagePreviewWindow?.hide()
        pagePreviewWindow = nil
        overlayWindow = nil
        toolsWindow = nil
        leftNavWindow = nil
        rightNavWindow = nil
    }

    private func startReconnectGraceTimer() {
        cancelReconnectGraceTimer()
        let work = DispatchWorkItem { [weak self] in
            // 宽限期内未等到重连补发 begin：按放映异常结束整体收层清数据。
            self?.teardownPresentation(reason: "重连宽限超时未收到 begin")
        }
        reconnectGraceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.reconnectGraceInterval, execute: work)
    }

    private func cancelReconnectGraceTimer() {
        reconnectGraceWork?.cancel()
        reconnectGraceWork = nil
    }

    /// 退出挂起态（重连成功 / 整体收层）。只复位标志，不动数据。
    private func cancelReconnectGrace() {
        cancelReconnectGraceTimer()
        isAwaitingReconnect = false
    }

    private func teardownPresentation(reason: String) {
        guard isPresenting || isAwaitingReconnect else { return }
        cancelReconnectGrace()
        SlideshowAnnotationLog.info("收起批注层: \(reason)")
        dismissPresentationUI()
        stopWatchdog()
        lastHeartbeatAt = nil
        isPresenting = false
        totalPageCount = 0
        currentPageIndex = 1
        // 批注数据仅存活于一次放映会话：关闭（退出放映/功能关闭/心跳超时等）
        // 即整体清空，下次放映从头开始，不残留上一场痕迹。
        if !pageAnnotations.isEmpty {
            pageAnnotations.removeAll()
            SlideshowAnnotationLog.info("批注数据已清空(共清理会话内全部页码)")
        }
        // 撤销/还原各来源栈随会话一起复位。
        undoStacks.removeAll()
        redoStacks.removeAll()
        undoSequence = 0
        // 页图内存库与分块重组缓冲随会话整体释放（批注数据同寿命）。
        pageImageStore = PageImageStore()
        pendingPageExports.removeAll()
    }

    private func exitPresentation() {
        guard isPresenting, exitConfirmWindow?.isVisible != true else { return }
        SlideshowAnnotationLog.info("退出放映: 弹出确认")
        // 自绘确认弹窗（不用系统 NSAlert——放映时后台 app 的 runModal 弹窗
        // 无法成为 key window，实测点不到）。居中于画布所在区域，浮在画布之上。
        let window = SlideshowExitConfirmWindow()
        window.onConfirm = { [weak self] in
            guard let self else { return }
            self.exitConfirmWindow = nil
            // 向加载项下发 exit 命令（调用 View.Exit() 退出放映），
            // 随后加载项的 SlideShowEnd 上报会再次确认收起（幂等）。
            self.bridgeServer?.send(.exit)
            self.teardownPresentation(reason: "点击退出按钮")
        }
        window.onCancel = { [weak self] in
            self?.exitConfirmWindow = nil
            SlideshowAnnotationLog.info("退出放映已取消(用户点击返回)")
        }
        exitConfirmWindow = window
        let anchorFrame = overlayWindow?.frame ?? toolsWindow?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        window.show(centeredIn: anchorFrame)
    }

    // MARK: - 翻页

    private func previousPage() {
        // 翻页由加载项调用 View.Previous() 完成，页码经事件上报回传对齐。
        bridgeServer?.send(.previous)
    }

    private func nextPage() {
        bridgeServer?.send(.next)
    }

    private func switchToPage(_ index: Int?) {
        guard isPresenting, let index, index >= 1, index != currentPageIndex else { return }
        // 先丢弃进行中的笔画/橡皮状态（属于旧页，翻页后松笔不得落进新页）。
        overlayWindow?.canvas.discardActiveStroke()
        saveCurrentPageAnnotations()
        currentPageIndex = index
        loadCurrentPageAnnotations()
        updatePageIndicator()
    }

    /// 把当前页码与总页数同步到左下 / 右下两套翻页面板。
    private func updatePageIndicator() {
        leftNavWindow?.setPage(currentPageIndex, total: totalPageCount)
        rightNavWindow?.setPage(currentPageIndex, total: totalPageCount)
        // 页码预览打开中：跟随新当前页重新定位（垂直居中）+ 预取新邻域。
        pagePreviewWindow?.updateCurrentPage(currentPageIndex)
    }

    // MARK: - 页码预览（按需页图导出）

    /// 页码标签点击：开关页码预览。总页数未知（≤0）时无列表可看，不弹。
    private func togglePagePreview(labelScreenFrame: NSRect) {
        guard isPresenting, totalPageCount > 0 else { return }
        // 用 isOpen 意图标志而非 isVisible：退场动画窗口期（0.12s）内窗口
        // 仍 isVisible，isVisible 判定会把「点了想关」误判成「再开一次」，
        // 与 show 的 isHiding 防重入互锁导致一次点击无任何反馈。
        if let window = pagePreviewWindow, window.isOpen {
            window.hide()
            SlideshowAnnotationLog.info("页码预览已收起")
            return
        }
        let window = pagePreviewWindow ?? SlideshowPagePreviewWindow()
        pagePreviewWindow = window
        // 可视/预取请求（携带视口中心锚点）：库内命中即时交付，未命中才下发导出。
        window.onRequestPages = { [weak self] pages, anchor in
            self?.handlePreviewPageRequest(pages: pages, anchor: anchor)
        }
        window.onJumpToPage = { [weak self] page in
            guard let self else { return }
            // 下发 goto 由加载项执行 View.GotoSlide() 翻页；随后加载项上报
            // 新页码，翻页链路（批注切换/指示器/预览跟随）经 .page 上报自动对齐。
            // 此处不直接改本地状态：WPS 是页码的唯一事实来源，回程 ~120ms。
            self.bridgeServer?.send(.goto(page))
        }
        window.configure(currentPage: currentPageIndex, total: totalPageCount)
        window.show(above: labelScreenFrame)
        SlideshowAnnotationLog.info("页码预览已打开 page=\(currentPageIndex)/\(totalPageCount)")
    }

    /// 预览页请求管线（窗口可视/预取范围，携带视口中心锚点）：
    /// - 库内命中 → **即时交付**（重开预览/滚回已看区域零请求零解码，秒出）；
    /// - 未命中且不在途/未失败 → 记入在途并整批下发导出（在途/失败页去重）。
    /// 锚点同步更新内存库的淘汰基准（滚动与跳页都会经过这里）。
    private func handlePreviewPageRequest(pages: [Int], anchor: Int) {
        guard isPresenting, !pages.isEmpty else { return }
        if anchor >= 1 { pageImageStore.anchorPage = anchor }
        var toRequest: [Int] = []
        for page in pages {
            if let image = pageImageStore.images[page] {
                pagePreviewWindow?.onPageImageReady(page: page, image: image)
            } else if !pageImageStore.inFlight.contains(page), !pageImageStore.failed.contains(page) {
                pageImageStore.inFlight.insert(page)
                toRequest.append(page)
            }
        }
        guard !toRequest.isEmpty else { return }
        bridgeServer?.send(.exportPages(toRequest))
    }

    /// 加载项单页导出回执：分块重组 → 后台解码 → 入库淘汰 → 交付显示。图片
    /// 经 WebSocket 私有端口 base64 分块直传（WPS 的 WS 发 ~0.9MB 大帧会断链），
    /// 主程序不读导出文件。
    private func handlePageExported(page: Int, ok: Bool, seq: Int, total: Int, chunk: String) {
        guard page >= 1 else { return }
        guard ok, total >= 1, seq >= 0, seq < total, !chunk.isEmpty else {
            SlideshowAnnotationLog.info("第 \(page) 页导出失败(占位保留，不重试)")
            pendingPageExports.removeValue(forKey: page)
            pageImageStore.inFlight.remove(page)
            pageImageStore.failed.insert(page)
            pagePreviewWindow?.onPageImageReady(page: page, image: nil)
            return
        }
        // 始终按分片协议重组（插件侧 1 片也报 total=1），无单块直传旁路：
        // 收齐 total 片后按 seq 拼接。
        var entry = pendingPageExports[page] ?? (total: total, parts: [:])
        if entry.total != total {
            // total 不一致（异常/重发）：丢弃已收分块，从当前块重新收。
            entry = (total: total, parts: [:])
        }
        entry.parts[seq] = chunk
        guard entry.parts.count == total else {
            pendingPageExports[page] = entry
            return
        }
        pendingPageExports.removeValue(forKey: page)
        let base64 = (0..<total).compactMap { entry.parts[$0] }.joined()
        // inFlight 保持占用直到 finishPageImage（入库/失败）再释放：
        // 解码期间预览再次请求该页会被去重，避免重复下发 export 与双份交付。
        // 解码较重（PNG → NSImage），放后台不占主线程；解出后回主线程入库交付。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = Data(base64Encoded: base64).flatMap(NSImage.init(data:))
            Task { @MainActor [weak self] in
                self?.finishPageImage(page: page, image: image)
            }
        }
    }

    /// 页图解码完成：入库（触发距离淘汰）→ 交付给打开中的预览窗口。
    private func finishPageImage(page: Int, image: NSImage?) {
        // 无论成败都释放该页的导出占用（见 handlePageExported 的去重说明）。
        pageImageStore.inFlight.remove(page)
        guard let image, image.size.width > 0 else {
            pageImageStore.failed.insert(page)
            pagePreviewWindow?.onPageImageReady(page: page, image: nil)
            return
        }
        pageImageStore.images[page] = image
        trimPageImageStore()
        pagePreviewWindow?.onPageImageReady(page: page, image: image)
    }

    /// 内存库淘汰：超限时按「距锚点页从远到近」逐页丢弃（同距丢页码大的一侧）；
    /// 锚点 ± 保护带内永不淘汰——活跃邻域（可视 + 预取）始终完整保留。
    private func trimPageImageStore() {
        guard pageImageStore.images.count > pageImageLimit else { return }
        let anchor = pageImageStore.anchorPage
        while pageImageStore.images.count > pageImageLimit {
            guard let farthest = pageImageStore.images.keys
                .filter({ abs($0 - anchor) > pageImageProtectedRadius })
                .max(by: {
                    let l = abs($0 - anchor), r = abs($1 - anchor)
                    if l != r { return l < r }
                    return $0 < $1
                })
            else { break }
            pageImageStore.images.removeValue(forKey: farthest)
        }
    }

    private func saveCurrentPageAnnotations() {
        guard let overlayWindow else { return }
        pageAnnotations[currentPageIndex] = overlayWindow.canvas.slideAnnotations
    }

    private func loadCurrentPageAnnotations() {
        guard let overlayWindow else { return }
        let annotations = pageAnnotations[currentPageIndex] ?? SlideshowSlideAnnotations()
        overlayWindow.canvas.slideAnnotations = annotations
    }

    // MARK: - 心跳守护

    private func startWatchdog() {
        stopWatchdog()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: Metrics.watchdogInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkHeartbeat()
            }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func checkHeartbeat() {
        guard isPresenting, let lastHeartbeatAt else { return }
        let elapsed = Date().timeIntervalSince(lastHeartbeatAt)
        if elapsed > Metrics.heartbeatTimeout {
            // 加载项心跳中断（WPS 被强制退出等）：收起批注层。
            teardownPresentation(reason: String(format: "心跳超时 %.1fs 未收到上报", elapsed))
        }
    }

    // MARK: - 工具

    private func setTool(_ tool: SlideshowAnnotationTool) {
        overlayWindow?.canvas.tool = tool
        // 鼠标模式：事件穿透到 WPS；画笔/橡皮模式：事件被画布拦截用于绘制。
        overlayWindow?.setMousePassthrough(tool == .mouse)
        // 草稿纸画布跟随工具栏同一工具：笔触/橡皮逻辑依赖底部工具栏。
        scratchpadWindow?.canvas.tool = tool
    }

    /// 应用画笔颜色（颜色胶囊点选）：作用于画布后续笔迹。
    private func setPenColor(_ color: NSColor) {
        overlayWindow?.canvas.penColor = color
        // 草稿纸随笔色实时同步，纸上笔迹与放映批注同色。
        scratchpadWindow?.canvas.penColor = color
    }

    /// 应用画笔粗细预设（粗细胶囊行点选）：作用于画布后续笔迹。
    private func setPenWidth(_ index: Int) {
        guard SlideshowPenWidthPreset.ordered.indices.contains(index) else { return }
        let preset = SlideshowPenWidthPreset.ordered[index]
        overlayWindow?.canvas.penWidthPreset = preset
        scratchpadWindow?.canvas.penWidthPreset = preset
        SlideshowAnnotationLog.info("画笔粗细: \(preset.name)(宽 \(preset.minWidth)~\(preset.maxWidth), 起笔 \(preset.startWidth))")
    }

    /// 撤销：在「当前页栈」与「草稿纸栈」的栈顶之间取最后发生的一个动作撤销；
    /// 不跨页（其他页的历史翻回该页后继续）。
    private func undo() {
        guard let action = mergedStackTopAction(from: undoStacks, preferNewer: true) else { return }
        undoStacks[action.target]?.removeLast()
        applyStrokes(action.before, to: action.target)
        redoStacks[action.target, default: []].append(action)
    }

    /// 还原：在「当前页栈」与「草稿纸栈」的还原栈顶之间取最早被撤销的一个动作还原；
    /// 与撤销严格互逆，其他页的还原历史翻回该页后继续。
    private func redo() {
        guard let action = mergedStackTopAction(from: redoStacks, preferNewer: false) else { return }
        redoStacks[action.target]?.removeLast()
        applyStrokes(action.after, to: action.target)
        undoStacks[action.target, default: []].append(action)
    }

    /// 在当前页栈与草稿纸栈的栈顶之间挑选待弹出动作：
    /// - 撤销（preferNewer=true）取序号较大者 = 最后发生的动作；
    /// - 还原（preferNewer=false）取序号较小者 = 最早被撤销的动作
    ///   （各还原栈按撤销先后入栈、栈顶即本栈最早者，取较小序号即全局互逆序）。
    private func mergedStackTopAction(from stacks: [UndoTarget: [UndoAction]], preferNewer: Bool) -> UndoAction? {
        let pageAction = stacks[.slidePage(page: currentPageIndex)]?.last
        let scratchAction = stacks[.scratchpad]?.last
        switch (pageAction, scratchAction) {
        case let (page?, scratch?):
            let takePage = preferNewer ? page.sequence > scratch.sequence : page.sequence < scratch.sequence
            return takePage ? page : scratch
        case let (page?, nil):
            return page
        case let (nil, scratch?):
            return scratch
        case (nil, nil):
            return nil
        }
    }

    /// 清空当页批注（可撤销，经统一撤销链）；落盘由画布的 onStrokeEnded 回调完成。
    private func clearCurrentPage() {
        overlayWindow?.canvas.clearCurrentPage()
    }

    /// 清空草稿纸（可撤销，经统一撤销链）。
    private func clearScratchpad() {
        scratchpadWindow?.canvas.clearCurrentPage()
        SlideshowAnnotationLog.info("橡皮菜单: 已清空草稿纸")
    }

    /// 画布动作提交（画笔落盘/橡皮擦除/清空）：压入目标来源自己的撤销栈并作废
    /// 该来源的还原栈（新动作只切断同来源的还原历史，其他来源还原历史独立保留）。
    private func commitUndoAction(_ target: UndoTarget, before: [SlideshowStroke], after: [SlideshowStroke]) {
        undoSequence += 1
        var stack = undoStacks[target, default: []]
        stack.append(UndoAction(target: target, sequence: undoSequence, before: before, after: after))
        if stack.count > UndoChainMetrics.maxDepth {
            stack.removeFirst(stack.count - UndoChainMetrics.maxDepth)
        }
        undoStacks[target] = stack
        redoStacks[target] = nil
    }

    /// 把笔迹快照写回目标：
    /// - 演示画布当前页 → 写画布并同步页内存（撤销/还原只作用于当前页，
    ///   非当前页动作不可达，此处兜底忽略）；
    /// - 草稿纸 → 写纸面画布。
    private func applyStrokes(_ strokes: [SlideshowStroke], to target: UndoTarget) {
        switch target {
        case .slidePage(let page):
            guard page == currentPageIndex, let overlayWindow else {
                // 正常路径不可达（undo 全同步且只选当前页栈）；出现即说明
                // 选栈与应用之间被引入了异步/翻页重入，必须暴露而非静默。
                SlideshowAnnotationLog.info("撤销目标页 \(page) 非当前页 \(currentPageIndex)，动作被忽略")
                return
            }
            overlayWindow.canvas.slideAnnotations.strokes = strokes
            pageAnnotations[page] = overlayWindow.canvas.slideAnnotations
        case .scratchpad:
            scratchpadWindow?.canvas.slideAnnotations.strokes = strokes
        }
    }

    // MARK: - 自建工具（截图 / 计时器 / 放大镜 / 草稿纸）

    /// 底部工具栏「工具」二级菜单选中项的统一入口：菜单已自行收起，按条目分流。
    /// 工具菜单始终只负责呼出；关闭由各工具自身的关闭按钮完成，
    /// 关闭只隐藏窗口不清数据，临时数据仅在退出放映时统一清空。
    private func handleToolkitItem(_ item: SlideshowToolkitItem) {
        switch item {
        case .screenshot:
            captureScreenshotTool()
        case .timer:
            showTimerTool()
        case .magnifier:
            showMagnifierTool()
        case .scratchpad:
            showScratchpadTool()
        }
    }

    /// 计时器：呼出（已可见时仅置前，不重置位置）。关闭由计时器右上角
    /// 关闭按钮完成——隐藏后计时继续走，计时/插旗状态全部保留。
    private func showTimerTool() {
        if let window = timerWindow, window.isVisible {
            window.orderFrontRegardless()
            return
        }
        let window = timerWindow ?? SlideshowTimerWindow()
        timerWindow = window
        window.onClose = { SlideshowAnnotationLog.info("计时器已关闭(计时状态保留)") }
        window.show(centeredIn: presentationScreenFrame)
        SlideshowAnnotationLog.info("计时器已打开")
    }

    /// 放大镜：呼出（已可见时仅置前，不重置位置/倍率）。关闭由控制条上的
    /// 关闭按钮完成。打开即把工具栏切到鼠标模式（画布穿透），
    /// 用户才能点控制条按钮、按住镜头拖动到想看的放映区域。
    private func showMagnifierTool() {
        if let window = magnifierWindow, window.isVisible {
            window.orderFrontRegardless()
            return
        }
        let window = magnifierWindow ?? SlideshowMagnifierWindow()
        magnifierWindow = window
        window.onClose = { SlideshowAnnotationLog.info("放大镜已关闭(倍率保留)") }
        // 每次呼出取屏幕居中默认位（重开回默认位是有意设计，区别于草稿纸
        // 的原位恢复）；倍率在镜头视图内保留。
        window.show(centeredIn: presentationScreenFrame)
        toolsWindow?.applyToolExternally(.mouse)
        SlideshowAnnotationLog.info("放大镜已开启(工具栏切鼠标模式,可拖动镜头)")
    }

    /// 草稿纸：呼出（已可见时仅置前，不重设纸面尺寸/位置）。关闭由纸面顶边
    /// 的关闭按钮完成——纸上笔迹、漫游位置与窗口 frame 保留，重开原位原尺寸
    /// 可见（放大镜为有意回默认位，草稿纸不同）。
    /// 打开时把当前笔/橡皮与笔色粗细同步到纸面画布（笔触橡皮逻辑依赖底部工具栏）；
    /// 纸面画布开启漫游：鼠标态拖动/滚轮平移纸面内容而非移动窗口。
    private func showScratchpadTool() {
        if let window = scratchpadWindow, window.isVisible {
            window.orderFrontRegardless()
            return
        }
        if scratchpadWindow == nil {
            let window = SlideshowScratchpadWindow()
            // 草稿纸动作提交进统一撤销链（与演示画布互通，单链撤销）。
            window.canvas.onActionCommitted = { [weak self] before, after in
                self?.commitUndoAction(.scratchpad, before: before, after: after)
            }
            scratchpadWindow = window
        }
        guard let window = scratchpadWindow else { return }
        window.onClose = { SlideshowAnnotationLog.info("草稿纸已关闭(纸上内容保留)") }
        syncToolStateToScratchpad()
        window.show(in: presentationScreenFrame)
        SlideshowAnnotationLog.info("草稿纸已打开(边框拖动移动,四角裁切式改大小,鼠标态拖动漫游画布)")
    }

    /// 把主画布当前工具/笔色/粗细同步给草稿纸画布。
    private func syncToolStateToScratchpad() {
        guard let mainCanvas = overlayWindow?.canvas, let pad = scratchpadWindow else { return }
        pad.canvas.tool = mainCanvas.tool
        pad.canvas.penColor = mainCanvas.penColor
        pad.canvas.penWidthPreset = mainCanvas.penWidthPreset
    }

    /// 截图工具：复用选区截图的完整链路。不传初始区域，由截图链路按默认
    /// 选区（屏宽高 60% 居中）框选；选区窗口位于高于 chrome 的顶层
    /// （ScreenshotWindowLevel），天然盖过放映浮层。
    ///
    /// 工具栏、左右翻页栏、三个二级菜单**始终**从捕获中确定性排除（捕获
    /// API 可能返回早于窗口移除一帧的最近合成帧，时序手段无法根治；按
    /// 窗口列表在内容层剔除后，这些窗口无论是否在屏都不入镜）——因此
    /// 截图无需先收起浮层、会话结束后也无需恢复，交互浮层保持原状。
    private func captureScreenshotTool() {
        guard let screenshotToolbar else { return }
        // 点击截图 → 立即隐藏全部常驻浮层（无退出动画）→ 内置截图 →
        // 会话终态回调恢复工具栏与翻页栏（工具菜单不拉起，交互时再弹出）。
        hideSlideshowChromeForScreenshot()
        screenshotToolbar.captureScreenshot(appKitRect: nil) { [weak self] in
            self?.restoreSlideshowChromeAfterScreenshot()
        }
    }

    /// 截图前隐藏常驻浮层：三个二级菜单立即关闭（复位展开状态）、工具栏与
    /// 两侧翻页栏立即 orderOut（不走退场动画）。
    private func hideSlideshowChromeForScreenshot() {
        toolsWindow?.hideToolMenusImmediately()
        toolsWindow?.orderOut(nil)
        leftNavWindow?.orderOut(nil)
        rightNavWindow?.orderOut(nil)
    }

    /// 截图会话终态恢复：工具栏与两侧翻页栏直接置前（隐藏走 orderOut，
    /// frame/alpha 未动过，无需动画）；工具菜单不恢复，由用户交互时再弹出。
    private func restoreSlideshowChromeAfterScreenshot() {
        toolsWindow?.orderFrontRegardless()
        leftNavWindow?.orderFrontRegardless()
        rightNavWindow?.orderFrontRegardless()
    }

    /// 收起全部自建工具窗口（仅退出放映等会话收尾路径调用，工具自身的关闭
    /// 按钮不会走到这里）；计时器真正停止并复位——会话结束不残留任何临时数据。
    private func dismissToolkitTools() {
        magnifierWindow?.orderOut(nil)
        timerWindow?.shutdown()
        scratchpadWindow?.orderOut(nil)
        magnifierWindow = nil
        timerWindow = nil
        scratchpadWindow = nil
    }

    /// 当前放映所在的屏幕 frame（工具栏/工具浮窗定位用）。
    private var presentationScreenFrame: NSRect {
        if let overlayWindow,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(overlayWindow.frame) }) {
            return screen.frame
        }
        return Self.mouseScreen()?.frame ?? NSScreen.main?.frame ?? .zero
    }

    // MARK: - 坐标换算

    /// 把加载项上报的放映窗口矩形（VBA 语义：主屏左上原点、y 向下、单位 pt）
    /// 换算为 AppKit 全局坐标（主屏左下原点、y 向上）。
    /// 放映窗口近全屏（覆盖某屏 90% 以上）时直接吸附该屏整屏 frame，
    /// 取不到有效矩形时回退到鼠标所在屏幕。
    private static func annotationFrame(for report: SlideshowBeginReport) -> NSRect {
        guard let primary = NSScreen.screens.first else { return NSRect.zero }
        if let width = report.width, let height = report.height, width > 1, height > 1 {
            let x = report.x ?? primary.frame.minX
            let y = primary.frame.maxY - (report.y ?? 0) - height
            let rect = NSRect(x: x, y: y, width: width, height: height)
            if let covered = screenCoveredBy(rect) {
                return covered.frame
            }
            if NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) {
                return rect
            }
        }
        return mouseScreen()?.frame ?? primary.frame
    }

    private static func screenCoveredBy(_ rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { screen in
            let intersection = screen.frame.intersection(rect)
            guard !intersection.isNull else { return false }
            let screenArea = screen.frame.width * screen.frame.height
            return intersection.width * intersection.height >= screenArea * 0.9
        }
    }

    /// 工具栏定位用的屏幕 frame：优先矩形所在屏，回退鼠标所在屏，最后退回矩形本身。
    private static func toolbarScreenFrame(containing rect: NSRect) -> NSRect {
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
            return screen.frame
        }
        return mouseScreen()?.frame ?? rect
    }

    private static func mouseScreen() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}

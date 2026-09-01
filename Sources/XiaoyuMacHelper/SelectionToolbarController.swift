import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin

@MainActor
final class SelectionToolbarController {
    private enum Metrics {
        static let dragThresholdSquared: CGFloat = 36
        static let showDelay: TimeInterval = 0.08
        static let searchReadDelay: TimeInterval = 0.22
    }

    private static var unsupportedSearchPasteboardTypes: [NSPasteboard.PasteboardType] {
        [
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            NSPasteboard.PasteboardType("public.tiff"),
            NSPasteboard.PasteboardType("public.png"),
            NSPasteboard.PasteboardType("com.adobe.pdf")
        ]
    }

    private let toolbarWindow = SelectionToolbarWindow()
    private let toastWindow = ToastWindow()
    private lazy var screenshotSelectionWindow = ScreenshotSelectionWindow()
    private var eventMonitor: Any?
    private var keyDownMonitor: Any?
    private var localClickMonitor: Any?
    private var currentSettings: AppSettings
    private var mouseDownLocation: NSPoint?
    private var selectionRect: CGRect?
    private var selectionTargetPID: pid_t?
    private var pendingShow: DispatchWorkItem?

    private var isEnabled: Bool {
        currentSettings.isSelectionToolbarEnabled && !currentSettings.visibleSelectionToolbarActions.isEmpty
    }

    init(settings: AppSettings) {
        currentSettings = settings
        toolbarWindow.onAction = { [weak self] action in
            self?.perform(action)
        }
    }

    func start() {
        syncEventMonitor()
    }

    func update(settings: AppSettings) {
        currentSettings = settings
        syncEventMonitor()
        if !isEnabled {
            reset(shouldHideToolbar: true, clearTarget: true)
        }
    }

    func stop() {
        reset(shouldHideToolbar: true, clearTarget: true)
        removeEventMonitor(&eventMonitor)
        removeEventMonitor(&keyDownMonitor)
        removeEventMonitor(&localClickMonitor)
    }

    private func syncEventMonitor() {
        guard isEnabled else {
            removeEventMonitor(&eventMonitor)
            removeEventMonitor(&keyDownMonitor)
            removeEventMonitor(&localClickMonitor)
            return
        }

        // 全局鼠标：只监听其他 app 的点击/拖拽，驱动选区工具栏的显示与跨应用点击隐藏。
        if eventMonitor == nil {
            eventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]
            ) { [weak self] event in
                DispatchQueue.main.async { self?.handle(event) }
            }
        }

        // 全局键盘：用户在任意 app 开始打字/按键时收起工具栏。全局 monitor 收不到
        // 本 app 的事件，所以工具栏自身的注入快捷键（Cmd+C 等）只会幂等地重复隐藏
        // 已经收起的工具栏，不会造成意外。
        if keyDownMonitor == nil {
            keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
                DispatchQueue.main.async { self?.hideForExternalInput() }
            }
        }

        // 局部鼠标：本 app 窗口（如控制面板）的点击全局 monitor 看不到，补一个局部
        // monitor。通过 windowNumber 排除工具栏自身的按钮点击——点按钮是操作，不是
        // "点击其他地方"。
        if localClickMonitor == nil {
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                DispatchQueue.main.async { self?.handleLocalClick(event) }
                return event
            }
        }
    }

    /// 点击了本 app 的其他窗口（控制面板等）→ 收起工具栏。工具栏自身的按钮点击
    /// （windowNumber 相同）不处理，保持按钮可用。
    private func handleLocalClick(_ event: NSEvent) {
        guard event.windowNumber != toolbarWindow.windowNumber else { return }
        hideForExternalInput()
    }

    /// 任意键盘输入或点击本 app 其他窗口 → 收起工具栏并清空选区状态。
    private func hideForExternalInput() {
        guard isEnabled, toolbarWindow.isVisible else { return }
        reset(shouldHideToolbar: true, clearTarget: true)
    }

    private func handle(_ event: NSEvent) {
        guard isEnabled else {
            reset(shouldHideToolbar: true, clearTarget: true)
            return
        }

        switch event.type {
        case .leftMouseDown:
            startSelectionTracking()
        case .leftMouseUp:
            finishSelectionTracking()
        case .rightMouseDown:
            reset(shouldHideToolbar: true, clearTarget: true)
        default:
            break
        }
    }

    private func startSelectionTracking() {
        reset(shouldHideToolbar: true, clearTarget: false)
        mouseDownLocation = NSEvent.mouseLocation
        selectionTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func finishSelectionTracking() {
        let point = NSEvent.mouseLocation
        guard let rect = dragSelectionRect(endingAt: point) else {
            reset(shouldHideToolbar: true, clearTarget: true)
            return
        }

        selectionRect = rect
        mouseDownLocation = nil
        showToolbarSoon(near: point)
    }

    private func dragSelectionRect(endingAt point: NSPoint) -> CGRect? {
        guard let start = mouseDownLocation else {
            return nil
        }

        let dx = point.x - start.x
        let dy = point.y - start.y
        guard dx * dx + dy * dy >= Metrics.dragThresholdSquared else {
            return nil
        }

        return CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(dx),
            height: abs(dy)
        )
    }

    private func showToolbarSoon(near point: NSPoint) {
        pendingShow?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.showToolbar(near: point)
        }
        pendingShow = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.showDelay, execute: workItem)
    }

    private func showToolbar(near point: NSPoint) {
        pendingShow = nil
        guard isEnabled else {
            hideToolbar()
            return
        }

        toolbarWindow.show(actions: currentSettings.visibleSelectionToolbarActions, near: point)
    }

    private func perform(_ action: ToolbarAction) {
        let pid = selectionTargetPID
        let rect = selectionRect
        reset(shouldHideToolbar: true, hidesToolbarImmediately: action == .screenshot, clearTarget: true)

        switch action {
        case .copy, .paste, .selectAll:
            guard let keyCode = action.shortcutKeyCode else { return }
            injectShortcut(keyCode, targetPID: pid)
        case .search:
            copySelectionAndSearch(targetPID: pid)
        case .screenshot:
            captureSelection(rect)
        }
    }

    /// 等待目标 app 真正成为前台后注入硬件级快捷键，注入失败（如辅助功能权限被撤）时提示用户。
    private func injectShortcut(_ keyCode: CGKeyCode, targetPID pid: pid_t?) {
        Task { [weak self] in
            guard let self else { return }
            await self.activateTarget(pid)
            let posted = await Self.postCommandShortcut(keyCode)
            if !posted {
                self.showToast("快捷键发送失败，请检查辅助功能权限")
            }
        }
    }

    private func captureSelection(_ rect: CGRect?) {
        guard let rect, rect.width >= 1, rect.height >= 1 else {
            showToast("截图区域无效")
            return
        }

        if currentSettings.screenshotSelectsRegion {
            captureFullScreenForRegionSelection(initialRect: rect)
            return
        }

        guard let captureRect = Self.screenCaptureRect(fromAppKitRect: rect) else {
            showToast("截图区域无效")
            return
        }

        captureImage(in: captureRect) { [weak self] image in
            self?.finishScreenshot(image)
        }
    }

    private func captureFullScreenForRegionSelection(initialRect rect: CGRect) {
        let appKitRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        guard let screen = Self.screen(containing: appKitRect),
              let fullScreenCaptureRect = Self.screenCaptureRect(fromAppKitRect: screen.frame) else {
            showToast("截图区域无效")
            return
        }
        let screenFrame = screen.frame

        captureImage(in: fullScreenCaptureRect) { [weak self] image in
            guard let self else { return }
            let clippedSelection = appKitRect.intersection(screenFrame)
            let localSelection = NSRect(
                x: clippedSelection.minX - screenFrame.minX,
                y: clippedSelection.minY - screenFrame.minY,
                width: clippedSelection.width,
                height: clippedSelection.height
            )

            self.screenshotSelectionWindow.show(
                image: image,
                screenFrame: screenFrame,
                initialSelection: localSelection,
                onConfirm: { [weak self] croppedImage in
                    self?.finishScreenshot(croppedImage)
                },
                onFailure: { [weak self] in
                    self?.showToast("截图失败")
                },
                onCancel: {}
            )
        }
    }

    private func captureImage(in rect: CGRect, completion: @MainActor @Sendable @escaping (CGImage) -> Void) {
        guard Self.hasScreenCapturePermission() else {
            CGRequestScreenCaptureAccess()
            showToast("请在系统设置中允许屏幕录制权限后重试")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // 通用兼容方案：CGWindowListCreateImage（macOS 10.5+ 全版本可用），
            // 直接捕获屏幕指定区域（CGDisplay 全局坐标空间，左上原点）。
            let image = ScreenCaptureShim.captureWindowListImage(in: rect)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let image else {
                    self.showToast("截图失败")
                    return
                }
                completion(image)
            }
        }
    }

    private static func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private func finishScreenshot(_ image: CGImage) {
        if currentSettings.screenshotCopiesToClipboard {
            Self.copyScreenshotToPasteboard(image)
        }

        let saveDirectory = currentSettings.screenshotSaveDirectory
        DispatchQueue.global(qos: .userInitiated).async { [image, saveDirectory, weak self] in
            let result = Result {
                try SelectionToolbarController.saveScreenshot(image, toDirectoryAt: saveDirectory)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.showToast("已保存截图：\(url.lastPathComponent)")
                case .failure:
                    self.showToast("截图失败")
                }
            }
        }
    }

    private static func screenCaptureRect(fromAppKitRect rect: CGRect) -> CGRect? {
        let appKitRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        guard let screen = screen(containing: appKitRect),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }

        let clippedRect = appKitRect.intersection(screen.frame)
        guard clippedRect.width >= 1, clippedRect.height >= 1 else {
            return nil
        }

        let displayBounds = CGDisplayBounds(displayID)
        return CGRect(
            x: displayBounds.minX + clippedRect.minX - screen.frame.minX,
            y: displayBounds.minY + screen.frame.maxY - clippedRect.maxY,
            width: clippedRect.width,
            height: clippedRect.height
        )
    }

    private static func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens
            .filter { $0.frame.intersects(rect) }
            .max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
    }

    private static func copyScreenshotToPasteboard(_ image: CGImage) {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }

    nonisolated private static func saveScreenshot(_ image: CGImage, toDirectoryAt path: String) throws -> URL {
        let directoryURL = path.isEmpty ? defaultScreenshotDirectoryURL() : URL(fileURLWithPath: path, isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let fileURL = uniqueScreenshotURL(in: directoryURL, timestamp: formatter.string(from: Date()))

        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    nonisolated private static func uniqueScreenshotURL(in directory: URL, timestamp: String) -> URL {
        let baseName = "截图\(timestamp)"
        var candidate = directory.appendingPathComponent("\(baseName).png")
        var index = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(index).png")
            index += 1
        }

        return candidate
    }

    private func copySelectionAndSearch(targetPID pid: pid_t?) {
        Task { [weak self] in
            guard let self else { return }
            await self.activateTarget(pid)

            let pasteboard = NSPasteboard.general
            let beforeChangeCount = pasteboard.changeCount
            _ = await Self.postCommandShortcut(CGKeyCode(kVK_ANSI_C))

            DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.searchReadDelay) { [weak self] in
                guard let self else { return }
                let text = pasteboard.changeCount == beforeChangeCount
                    ? nil
                    : Self.searchableText(from: pasteboard)

                guard let text, !text.isEmpty else {
                    self.showToast("请选中文本进行搜索")
                    return
                }

                self.openSearch(for: text)
            }
        }
    }

    private func openSearch(for text: String) {
        let template = currentSettings.searchURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard template.contains("%s") else {
            showToast("搜索链接需要包含 %s")
            return
        }

        guard let encodedText = Self.encodedSearchQuery(text),
              let url = URL(string: template.replacingOccurrences(of: "%s", with: encodedText)) else {
            showToast("搜索链接无效")
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func showToast(_ message: String) {
        toastWindow.show(message: message)
    }

    /// 激活目标 app 并等待其成为前台（12ms 轮询、最长 800ms）。
    /// 确保后续注入的硬件快捷键落在目标 app 上，而不是工具栏窗口或残留焦点。
    private func activateTarget(_ pid: pid_t?) async {
        guard let pid, let app = NSRunningApplication(processIdentifier: pid), !app.isActive else {
            return
        }

        app.activate(options: [])
        let deadline = Date().addingTimeInterval(0.8)
        while !app.isActive
            && NSWorkspace.shared.frontmostApplication?.processIdentifier != pid
            && Date() < deadline {
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
    }

    private func reset(shouldHideToolbar: Bool, hidesToolbarImmediately: Bool = false, clearTarget: Bool) {
        pendingShow?.cancel()
        pendingShow = nil
        mouseDownLocation = nil
        selectionRect = nil
        if clearTarget {
            selectionTargetPID = nil
        }
        if shouldHideToolbar {
            hideToolbar(immediately: hidesToolbarImmediately)
        }
    }

    private func hideToolbar(immediately: Bool = false) {
        toolbarWindow.hide(immediately: immediately)
    }

    private static func searchableText(from pasteboard: NSPasteboard) -> String? {
        guard pasteboard.availableType(from: unsupportedSearchPasteboardTypes) == nil else {
            return nil
        }

        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private static func encodedSearchQuery(_ text: String) -> String? {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text
            .addingPercentEncoding(withAllowedCharacters: unreserved)?
            .replacingOccurrences(of: "%20", with: "+")
    }

    /// 注入 Cmd+快捷键的完整硬件事件序列：Cmd down → key down → key up → Cmd up。
    /// 事件间保留真实按键的微小时序间隔，避免 down/up 同毫秒触发导致部分应用
    /// （Electron、远程桌面、旧 AppKit）丢弃按键。
    /// 硬件事件合成需要辅助功能或输入监控权限，权限不足时提前返回 false。
    @discardableResult
    private static func postCommandShortcut(_ keyCode: CGKeyCode) async -> Bool {
        guard canSynthesizeEvents() else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        let commandKeyCode = CGKeyCode(kVK_Command)

        postKey(commandKeyCode, isDown: true, flags: .maskCommand, source: source)
        try? await Task.sleep(nanoseconds: 12_000_000)
        postKey(keyCode, isDown: true, flags: .maskCommand, source: source)
        try? await Task.sleep(nanoseconds: 25_000_000)
        postKey(keyCode, isDown: false, flags: .maskCommand, source: source)
        try? await Task.sleep(nanoseconds: 12_000_000)
        postKey(commandKeyCode, isDown: false, flags: [], source: source)
        return true
    }

    /// 硬件事件合成（CGEventPost 到 HID 层）所需权限：辅助功能或输入监控任一满足即可。
    private static func canSynthesizeEvents() -> Bool {
        AXIsProcessTrusted() || CGPreflightPostEventAccess()
    }

    private static func postKey(
        _ keyCode: CGKeyCode,
        isDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource?
    ) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else {
            return
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}

/// 通用截图 shim：CGWindowListCreateImage 自 macOS 10.5 起存在，
/// 但 macOS 15 SDK 将其标记为 obsoleted，编译期不可直接调用。
/// 运行时符号始终存在，通过 dlsym 动态解析，获得跨系统版本的通用截图能力。
private enum ScreenCaptureShim {
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
            CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue
        )
        return image?.takeRetainedValue()
    }
}


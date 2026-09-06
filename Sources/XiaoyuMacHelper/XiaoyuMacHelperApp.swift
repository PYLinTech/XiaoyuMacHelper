import AppKit
import Carbon
import Darwin
import IOKit
import IOKit.hidsystem

@MainActor
final class XiaoyuMacHelperApp: NSObject, NSApplicationDelegate {
    private enum Metrics {
        static let capsLockPollInterval: TimeInterval = 0.5
        static let focusedStatusPollInterval: TimeInterval = 0.2
        static let unfocusedStatusPollInterval: TimeInterval = 1.0
    }

    private let launchMode: LaunchMode
    private let instanceLock: SingleInstanceLock
    private let settingsStore = SettingsStore()
    private lazy var currentSettings = settingsStore.read()
    private let capsLockWindow = CapsLockWindow()
    private lazy var selectionToolbarController = SelectionToolbarController(settings: currentSettings)
    private lazy var activeVisionController = ActiveVisionController(settings: currentSettings)
    private lazy var desktopLyricsController = DesktopLyricsController(settings: currentSettings)
    private lazy var slideshowAnnotationController = SlideshowAnnotationController(settings: currentSettings)
    private lazy var miscController = MiscController(settings: currentSettings)
    private lazy var controlWindow = ControlWindow()
    private var pollTimer: Timer?
    private var statusPollTimer: Timer?
    private var statusPollInterval: TimeInterval?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var appleMusicTokenLoginWindow: AppleMusicTokenLoginWindow?
    private var lastRenderedControlState: ControlState?
    /// 登录项状态缓存：SMAppService.status 每次查询可能走 launchd XPC，
    /// 控制窗聚焦时 0.2s 轮询一次纯属浪费。仅在勾选切换、显示窗口、窗口
    /// 获得焦点等状态变化点刷新（见 refreshLoginItemStatus）。
    private var cachedIsLoginItemEnabled = false
    private var previousCapsLockState: Bool?
    private var isUpdateCheckInProgress = false
    private var updateAlertWindow: UpdateAlertWindow?

    init(instanceLock: SingleInstanceLock, launchMode: LaunchMode) {
        self.instanceLock = instanceLock
        self.launchMode = launchMode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        refreshLoginItemStatus()
        bindCallbacks()
        setupObservers()
        selectionToolbarController.start()
        // 放映批注的截图工具复用选区截图的完整链路（同一实例）。
        slideshowAnnotationController.screenshotToolbar = selectionToolbarController
        activeVisionController.start()
        desktopLyricsController.start()
        slideshowAnnotationController.start()
        miscController.start()
        updateCapsLockPolling()
        updateCapsLockWindow(force: true)
        if launchMode.isUserInitiatedLaunch {
            showControlWindow()
        }
        scheduleAutoUpdateCheck()
    }

    private func bindCallbacks() {
        capsLockWindow.onClick = { [weak self] in self?.handleCapsLockIndicatorClick() }
        controlWindow.controlView.onCapsLockIndicatorChanged = { [weak self] isEnabled in self?.setCapsLockIndicatorEnabled(isEnabled) }
        controlWindow.controlView.onClickToDisableChanged = { [weak self] isEnabled in self?.setClickToDisableEnabled(isEnabled) }
        controlWindow.controlView.onSelectionToolbarChanged = { [weak self] isEnabled in self?.setSelectionToolbarEnabled(isEnabled) }
        controlWindow.controlView.onSelectionToolbarHideInFullscreenChanged = { [weak self] isEnabled in self?.setSelectionToolbarHideInFullscreen(isEnabled) }
        controlWindow.controlView.onActiveVisionChanged = { [weak self] isEnabled in self?.setActiveVisionEnabled(isEnabled) }
        controlWindow.controlView.onDesktopLyricsChanged = { [weak self] isEnabled in self?.setDesktopLyricsEnabled(isEnabled) }
        controlWindow.controlView.onSlideshowAnnotationChanged = { [weak self] isEnabled in self?.setSlideshowAnnotationEnabled(isEnabled) }
        controlWindow.controlView.onMouseWheelInvertChanged = { [weak self] isInverted in self?.setMiscMouseWheelInverted(isInverted) }
        controlWindow.controlView.onMiscMouseSideButtonsForwardBackChanged = { [weak self] isEnabled in self?.setMiscMouseSideButtonsForwardBackEnabled(isEnabled) }
        controlWindow.controlView.onSelectionToolbarActionChanged = { [weak self] action, isEnabled in self?.setSelectionToolbarAction(action, enabled: isEnabled) }
        controlWindow.controlView.onSelectionToolbarActionMoved = { [weak self] action, direction in self?.moveSelectionToolbarAction(action, direction: direction) }
        controlWindow.controlView.onDesktopLyricsSourceMoved = { [weak self] source, direction in self?.moveDesktopLyricsSource(source, direction: direction) }
        controlWindow.controlView.onDesktopLyricsSourceEnabledChanged = { [weak self] source, isEnabled in self?.setDesktopLyricsSource(source, enabled: isEnabled) }
        controlWindow.controlView.onDesktopLyricsPreferredLanguageChanged = { [weak self] language in self?.setDesktopLyricsPreferredLanguage(language) }
        controlWindow.controlView.onDesktopLyricsSurfaceChanged = { [weak self] isEnabled in self?.setDesktopLyricsSurfaceEnabled(isEnabled) }
        controlWindow.controlView.onDynamicIslandLyricsChanged = { [weak self] isEnabled in self?.setDynamicIslandLyricsEnabled(isEnabled) }
        controlWindow.controlView.onDynamicIslandLyricsSpectrumChanged = { [weak self] isEnabled in self?.setDynamicIslandLyricsSpectrumEnabled(isEnabled) }
        controlWindow.controlView.onDynamicIslandLyricsHideOnHoverChanged = { [weak self] isEnabled in self?.setDynamicIslandLyricsHideOnHover(isEnabled) }
        controlWindow.controlView.onDesktopLyricsWidthChanged = { [weak self] width in self?.setDesktopLyricsWidth(width) }
        controlWindow.controlView.onDesktopLyricsAlignmentChanged = { [weak self] alignment in self?.setDesktopLyricsAlignment(alignment) }
        controlWindow.controlView.onDynamicIslandLyricsWidthChanged = { [weak self] width in self?.setDynamicIslandLyricsWidth(width) }
        controlWindow.controlView.onDynamicIslandLyricsBlankWidthChanged = { [weak self] width in self?.setDynamicIslandLyricsBlankWidth(width) }
        controlWindow.controlView.onDynamicIslandLyricsHeightChanged = { [weak self] height in self?.setDynamicIslandLyricsHeight(height) }
        controlWindow.controlView.onDynamicIslandLyricsSlantRatioChanged = { [weak self] ratio in self?.setDynamicIslandLyricsSlantRatio(ratio) }
        controlWindow.controlView.onDynamicIslandLyricsCornerRatioChanged = { [weak self] ratio in self?.setDynamicIslandLyricsCornerRatio(ratio) }
        controlWindow.controlView.onDynamicIslandLyricsFontSizeChanged = { [weak self] fontSize in self?.setDynamicIslandLyricsFontSize(fontSize) }
        controlWindow.controlView.onDynamicIslandLyricsFontNameChanged = { [weak self] fontName in self?.setDynamicIslandLyricsFontName(fontName) }
        controlWindow.controlView.onDynamicIslandLyricsAlignmentChanged = { [weak self] alignment in self?.setDynamicIslandLyricsAlignment(alignment) }
        controlWindow.controlView.onMenuBarLyricsChanged = { [weak self] isEnabled in self?.setMenuBarLyricsEnabled(isEnabled) }
        controlWindow.controlView.onMenuBarLyricsWidthChanged = { [weak self] width in self?.setMenuBarLyricsWidth(width) }
        controlWindow.controlView.onMenuBarLyricsAlignmentChanged = { [weak self] alignment in self?.setMenuBarLyricsAlignment(alignment) }
        controlWindow.controlView.onDesktopLyricsShowsTranslationChanged = { [weak self] isEnabled in self?.setDesktopLyricsShowsTranslation(isEnabled) }
        controlWindow.controlView.onDesktopLyricsFontSizeChanged = { [weak self] fontSize in self?.setDesktopLyricsFontSize(fontSize) }
        controlWindow.controlView.onDesktopLyricsLockedChanged = { [weak self] isLocked in self?.setDesktopLyricsLocked(isLocked) }
        controlWindow.controlView.onDesktopLyricsStylePresetChanged = { [weak self] preset in self?.setDesktopLyricsStylePreset(preset) }
        controlWindow.controlView.onDesktopLyricsFontNameChanged = { [weak self] fontName in self?.setDesktopLyricsFontName(fontName) }
        controlWindow.controlView.onDesktopLyricsTextColorChanged = { [weak self] value in self?.setDesktopLyricsTextColor(value) }
        controlWindow.controlView.onDesktopLyricsStrokeColorChanged = { [weak self] value in self?.setDesktopLyricsStrokeColor(value) }
        controlWindow.controlView.onDesktopLyricsStrokeWidthChanged = { [weak self] value in self?.setDesktopLyricsStrokeWidth(value) }
        controlWindow.controlView.onMusicLyricsAppWhitelistChanged = { [weak self] value in self?.setMusicLyricsAppWhitelist(value) }
        controlWindow.controlView.onSearchTemplateChanged = { [weak self] template in self?.setSearchURLTemplate(template) }
        controlWindow.controlView.onScreenshotSaveDirectoryChanged = { [weak self] path in self?.setScreenshotSaveDirectory(path) }
        controlWindow.controlView.onScreenshotCopiesToClipboardChanged = { [weak self] isEnabled in self?.setScreenshotCopiesToClipboard(isEnabled) }
        controlWindow.controlView.onScreenshotSelectsRegionChanged = { [weak self] isEnabled in self?.setScreenshotSelectsRegion(isEnabled) }
        controlWindow.controlView.onActiveVisionGazeChanged = { [weak self] isEnabled in self?.setActiveVisionPreventsDisplaySleepOnGaze(isEnabled) }
        controlWindow.controlView.onActiveVisionFacingChanged = { [weak self] isEnabled in self?.setActiveVisionPreventsDisplaySleepOnFacing(isEnabled) }
        controlWindow.controlView.onActiveVisionNotifyChanged = { [weak self] isEnabled in self?.setActiveVisionNotifyWhenExtendingDisplaySleep(isEnabled) }
        controlWindow.controlView.onAppleMusicLoginRequested = { [weak self] in self?.openAppleMusicLogin() }
        controlWindow.controlView.onAppleMusicTokenCleared = { [weak self] in self?.clearAppleMusicToken() }
        controlWindow.controlView.onLoginItemChanged = { [weak self] isEnabled in self?.setLoginItemEnabled(isEnabled) }
        controlWindow.controlView.onLoginItemGuide = { [weak self] in self?.openLoginItemSettings() }
        controlWindow.controlView.onAccessibilityEnableRequested = { [weak self] in self?.enableAccessibilityGuide() }
        controlWindow.controlView.onAccessibilityDisableRequested = { [weak self] in self?.disableAccessibilityGuide() }
        controlWindow.controlView.onAccessibilityGuide = { [weak self] in self?.openAccessibilitySettings() }
        controlWindow.onRefreshRequested = { [weak self] in
            // 窗口获得焦点：先刷新登录项缓存（用户可能在系统设置里改过），再渲染。
            self?.refreshLoginItemStatus()
            self?.renderControlWindow()
        }
        controlWindow.onFocusChanged = { [weak self] isFocused in self?.updateStatusPolling(isFocused: isFocused) }
        controlWindow.onHidden = { [weak self] in self?.stopStatusPolling() }
        controlWindow.controlView.onClearDataAndQuit = { [weak self] in self?.clearDataAndQuit() }
        controlWindow.controlView.onQuit = { NSApp.terminate(nil) }
        controlWindow.controlView.onCheckUpdateRequested = { [weak self] in self?.checkForUpdates(userInitiated: true) }
        desktopLyricsController.onPositionChanged = { [weak self] origin in self?.setDesktopLyricsPosition(origin) }
        // 幻灯片批注（WPS 加载项）仅在勾选切换时安装/卸载。顺序：先弹窗告知
        // （用户点「知道了」确认）才写 WPS 目录——跨容器访问会触发系统授权
        // 弹窗，必须让用户先知道会发生什么；安装失败回滚开关并告警。
        slideshowAnnotationController.onEnableNoticeRequested = { [weak self] in
            self?.requestSlideshowAnnotationEnable()
        }
        slideshowAnnotationController.onEnableFailed = { [weak self] reason in
            self?.revertSlideshowAnnotationEnableFailure(reason)
        }
    }

    /// 幻灯片插件提示语（单一来源）：勾选启用与启动脚本更新共用，不重复维护。
    private static let slideshowAddinNoticeMessage =
        "当前仅支持 WPS：请点击允许访问其他APP的数据，并在重启 WPS 后信任插件。"

    /// 启用第一步：弹窗告知（模态，点「知道了」返回后）才执行第二步写 WPS 目录。
    private func requestSlideshowAnnotationEnable() {
        AlertPresenter.show(title: "启用幻灯片批注", message: Self.slideshowAddinNoticeMessage)
        slideshowAnnotationController.performEnableInstall()
    }

    /// 脚本更新检查 + 提示（整体在自更新检查链路结束后执行）：
    /// 仅勾选开启才检查（控制器内守卫）；先只比对版本记录（零权限请求），
    /// 检出更新先弹窗告知，用户确认后才重装脚本（写 WPS 目录触发授权请求）。
    private func checkSlideshowAddinScriptUpdate() {
        guard slideshowAnnotationController.isScriptUpdatePending() else { return }
        AlertPresenter.show(title: "幻灯片插件需要更新", message: Self.slideshowAddinNoticeMessage)
        slideshowAnnotationController.performScriptUpdate()
    }

    /// 幻灯片批注启用失败（插件写盘失败等）：回滚勾选并提示原因。
    private func revertSlideshowAnnotationEnableFailure(_ reason: String) {
        settingsStore.setSlideshowAnnotationEnabled(false)
        currentSettings.isSlideshowAnnotationEnabled = false
        renderControlWindow(force: true)
        AlertPresenter.show(
            title: "无法启用幻灯片批注",
            message: "WPS 加载项安装失败：\(reason)",
            style: .warning
        )
    }

    private func clearDataAndQuit() {
        settingsStore.clearPersistentData()
        NSApp.terminate(nil)
    }

    // MARK: - 自更新

    /// 每次启动都检查更新，无节流。检查失败静默（无网络等），不打扰用户。
    private func scheduleAutoUpdateCheck() {
        Task { @MainActor [weak self] in
            self?.checkForUpdates(userInitiated: false)
        }
    }

    private func checkForUpdates(userInitiated: Bool) {
        guard !isUpdateCheckInProgress else { return }
        isUpdateCheckInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performUpdateCheck(userInitiated: userInitiated)
            self.isUpdateCheckInProgress = false
        }
    }

    private func performUpdateCheck(userInitiated: Bool) async {
        let payload: UpdatePayload
        do {
            payload = try await UpdateChecker.checkLatest()
        } catch {
            // 自动检查失败静默（无网络等），不打扰用户；手动点击"检查更新"失败
            // 才走网页兜底。失败同样视为自更新检查结束，继续插件脚本检查。
            if userInitiated {
                presentUpdateFailure(pageURL: UpdateChannel.fallbackReleaseURL, reason: error.localizedDescription)
            }
            checkSlideshowAddinScriptUpdate()
            return
        }

        guard let remote = payload.latestVersion,
              let local = UpdateChecker.localVersion,
              remote > local
        else {
            if userInitiated {
                AlertPresenter.show(
                    title: "已是最新版本",
                    message: "当前 v\(UpdateChecker.localVersion?.description ?? "") 已是最新版本。"
                )
            }
            // 自更新为最新：立即执行插件脚本检查。
            checkSlideshowAddinScriptUpdate()
            return
        }

        presentUpdatePrompt(payload: payload, local: local, remote: remote)
    }

    /// 弹出自绘更新确认窗（图标 + 更新日志 + 版本对比 + 立即更新/稍后）。
    private func presentUpdatePrompt(payload: UpdatePayload, local: Version, remote: Version) {
        // 关旧窗不能走 close()：那会触发旧窗 onLater 的脚本检查，造成重复执行。
        updateAlertWindow?.forceClose()
        updateAlertWindow = nil

        let notes = payload.body.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "暂无更新说明。"
        let window = UpdateAlertWindow(currentVersion: local, latestVersion: remote, notes: notes)
        window.onInstall = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.installUpdate(payload: payload)
            }
        }
        window.onLater = { [weak self] in
            self?.updateAlertWindow = nil
            // 自更新弹窗结束（用户选择稍后）：执行插件脚本检查。
            self?.checkSlideshowAddinScriptUpdate()
        }
        updateAlertWindow = window
        window.show()
    }

    /// 下载 → 解包 → 三层校验 → 拉起更新辅助进程 → 退出本进程。
    /// 弹窗进入安装模式，下载进度实时回填进度条。
    private func installUpdate(payload: UpdatePayload) async {
        guard let alertWindow = updateAlertWindow else { return }
        alertWindow.enterInstallingMode()

        do {
            guard let assetURL = payload.primaryAssetURL else { throw UpdateError.invalidPayload }
            alertWindow.setStatus("正在下载更新包…")
            let dmgURL = try await UpdateInstaller.download(assetURL: assetURL) { [weak alertWindow] fraction in
                Task { @MainActor in
                    alertWindow?.setProgress(fraction)
                }
            }
            alertWindow.setProgress(1)
            alertWindow.setStatus("正在校验并安装更新包…")
            try await Task.detached(priority: .userInitiated) {
                let staged = try UpdateInstaller.extractApp(fromDMG: dmgURL)
                let targetApp = Bundle.main.bundleURL
                guard UpdateInstaller.verify(newApp: staged, targetApp: targetApp) else {
                    throw UpdateError.verificationFailed
                }
                try UpdateInstaller.launchUpdater(newApp: staged, targetApp: targetApp)
            }.value
            NSApp.terminate(nil)
        } catch {
            updateAlertWindow?.forceClose()
            updateAlertWindow = nil
            presentUpdateFailure(pageURL: payload.fallbackHTMLURL, reason: error.localizedDescription)
            // 安装失败仍停留在旧版本：视为自更新链路结束，继续插件脚本检查
            // （检查自身有 isScriptUpdatePending 闸门，与其它路径重复调用安全）。
            checkSlideshowAddinScriptUpdate()
        }
    }

    /// 失败兜底：打开下载页 + 提示手动下载覆盖。
    private func presentUpdateFailure(pageURL: URL, reason: String) {
        NSWorkspace.shared.open(pageURL)
        AlertPresenter.show(
            title: "自更新失败",
            message: "\(reason)\n\n已为你打开下载页面，建议手动下载后覆盖安装。",
            style: .warning
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeEventMonitor(&globalFlagsMonitor)
        removeEventMonitor(&localFlagsMonitor)
        if let didBecomeActiveObserver { NotificationCenter.default.removeObserver(didBecomeActiveObserver) }
        DistributedNotificationCenter.default().removeObserver(self)
        pollTimer?.invalidate()
        pollTimer = nil
        stopStatusPolling()
        selectionToolbarController.stop()
        activeVisionController.stop()
        desktopLyricsController.stop()
        slideshowAnnotationController.stop()
        miscController.stop()
        instanceLock.releaseLock()
    }

    private func enableAccessibilityGuide() {
        handleAccessibilityAction(
            title: "需要手动授权",
            message: "若授权后仍显示未开启，请先选中本应用项，然后点击减号删除，再重新请求授权。",
            action: AccessibilityPermission.request
        )
    }

    private func disableAccessibilityGuide() {
        handleAccessibilityAction(
            title: "需要手动删除",
            message: "受 macOS 限制，需要您按以下步骤手动取消授权：先点击本应用项右侧的滑块来禁用，再点击减号删除。",
            action: AccessibilityPermission.openSettings
        )
    }

    private func handleAccessibilityAction(title: String, message: String, action: () -> Void) {
        renderControlWindow(force: true)
        guard AlertPresenter.confirm(title: title, message: message) else {
            renderControlWindow(force: true)
            return
        }
        action()
        renderControlWindow(force: true)
    }

    private func openAccessibilitySettings() {
        AccessibilityPermission.openSettings()
    }

    private func openLoginItemSettings() {
        LoginItemManager.openLoginItemsSettings()
    }

    private func setLoginItemEnabled(_ isEnabled: Bool) {
        do {
            if isEnabled { try LoginItemManager.install() } else { try LoginItemManager.uninstall() }
        } catch {
            AlertPresenter.show(
                title: isEnabled ? "无法添加启动项" : "无法关闭启动项",
                message: error.localizedDescription,
                style: .warning
            )
        }

        refreshLoginItemStatus()
        openLoginItemSettings()
        renderControlWindow(force: true)
    }

    private func setupObservers() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showControlWindow),
            name: showControlWindowNotification,
            object: nil
        )

        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.controlWindow.isVisible else {
                    return
                }

                self.renderControlWindow()
                self.updateStatusPolling(isFocused: self.controlWindow.isKeyWindow)
            }
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.currentSettings.isCapsLockIndicatorEnabled else {
                    return
                }

                self.updateCapsLockWindow(force: false)
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.currentSettings.isCapsLockIndicatorEnabled else {
                return event
            }

            self.updateCapsLockWindow(force: false)
            return event
        }
    }

    @objc private func showControlWindow() {
        refreshLoginItemStatus()
        renderControlWindow(force: true)
        controlWindow.show()
        updateStatusPolling(isFocused: controlWindow.isKeyWindow)
    }

    /// 登录项状态变化点统一走这里刷新缓存（勾选切换 / 显示窗口 / 窗口获焦）。
    private func refreshLoginItemStatus() {
        cachedIsLoginItemEnabled = LoginItemManager.isInstalled()
    }

    private func renderControlWindow(force: Bool = false) {
        let state = ControlState(
            settings: currentSettings,
            isLoginItemEnabled: cachedIsLoginItemEnabled,
            isAccessibilityEnabled: AccessibilityPermission.isTrusted()
        )

        guard force || state != lastRenderedControlState else {
            return
        }

        lastRenderedControlState = state
        controlWindow.render(
            settings: state.settings,
            isLoginItemEnabled: state.isLoginItemEnabled,
            isAccessibilityEnabled: state.isAccessibilityEnabled
        )
    }

    private func updateStatusPolling(isFocused: Bool) {
        guard controlWindow.isVisible else {
            stopStatusPolling()
            return
        }

        let interval = isFocused ? Metrics.focusedStatusPollInterval : Metrics.unfocusedStatusPollInterval
        guard statusPollInterval != interval else {
            return
        }

        stopStatusPolling()
        statusPollInterval = interval
        statusPollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.controlWindow.isVisible else {
                    self?.stopStatusPolling()
                    return
                }

                self.renderControlWindow()
            }
        }
    }

    private func stopStatusPolling() {
        statusPollTimer?.invalidate()
        statusPollTimer = nil
        statusPollInterval = nil
    }

    private func setCapsLockIndicatorEnabled(_ isEnabled: Bool) {
        settingsStore.setCapsLockIndicatorEnabled(isEnabled)
        currentSettings.isCapsLockIndicatorEnabled = isEnabled
        renderControlWindow(force: true)

        if isEnabled {
            updateCapsLockPolling()
            updateCapsLockWindow(force: true)
        } else {
            updateCapsLockPolling()
            previousCapsLockState = nil
            capsLockWindow.orderOut(nil)
        }
    }

    private func setClickToDisableEnabled(_ isEnabled: Bool) {
        settingsStore.setClickToDisableEnabled(isEnabled)
        currentSettings.isClickToDisableEnabled = isEnabled
        renderControlWindow(force: true)
    }

    private func setSelectionToolbarEnabled(_ isEnabled: Bool) {
        guard !isEnabled || AccessibilityPermission.isTrusted() else {
            settingsStore.setSelectionToolbarEnabled(false)
            currentSettings.isSelectionToolbarEnabled = false
            refreshSelectionToolbarSettings()
            AlertPresenter.show(
                title: "请先授权辅助功能",
                message: "本功能需要使用辅助功能权限，请先在工具选项开启辅助功能。",
                style: .warning
            )
            return
        }

        settingsStore.setSelectionToolbarEnabled(isEnabled)
        currentSettings.isSelectionToolbarEnabled = isEnabled
        refreshSelectionToolbarSettings()
    }

    private func setSelectionToolbarHideInFullscreen(_ isEnabled: Bool) {
        settingsStore.setSelectionToolbarHideInFullscreen(isEnabled)
        currentSettings.isSelectionToolbarHideInFullscreen = isEnabled
        refreshSelectionToolbarSettings()
    }

    private func setActiveVisionEnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            applyActiveVisionEnabled(false)
            return
        }

        guard CameraPermission.isAuthorized else {
            applyActiveVisionEnabled(false)
            AlertPresenter.show(
                title: "需要摄像头权限",
                message: "主动视觉感知将在您息屏前使用摄像头进行本地分析，不会存储任何您的信息。\n\n点击“知道了”后将向系统申请摄像头权限。",
                style: .warning
            )

            CameraPermission.request { [weak self] isGranted in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    if isGranted {
                        self.applyActiveVisionEnabled(true)
                    } else {
                        self.applyActiveVisionEnabled(false)
                        AlertPresenter.show(
                            title: "无法开启主动视觉感知",
                            message: "请您在设置页面手动重新授权",
                            style: .warning
                        )
                        SystemSettingsOpener.openCameraPrivacy()
                    }
                }
            }
            return
        }

        applyActiveVisionEnabled(true)
    }

    private func applyActiveVisionEnabled(_ isEnabled: Bool) {
        settingsStore.setActiveVisionEnabled(isEnabled)
        currentSettings.isActiveVisionEnabled = isEnabled
        refreshActiveVisionSettings()
    }

    private func setActiveVisionPreventsDisplaySleepOnGaze(_ isEnabled: Bool) {
        settingsStore.setActiveVisionPreventsDisplaySleepOnGaze(isEnabled)
        currentSettings.activeVisionPreventsDisplaySleepOnGaze = isEnabled
        refreshActiveVisionSettings()
    }

    private func setActiveVisionPreventsDisplaySleepOnFacing(_ isEnabled: Bool) {
        settingsStore.setActiveVisionPreventsDisplaySleepOnFacing(isEnabled)
        currentSettings.activeVisionPreventsDisplaySleepOnFacing = isEnabled
        refreshActiveVisionSettings()
    }

    private func setActiveVisionNotifyWhenExtendingDisplaySleep(_ isEnabled: Bool) {
        settingsStore.setActiveVisionNotifiesWhenExtendingDisplaySleep(isEnabled)
        currentSettings.activeVisionNotifiesWhenExtendingDisplaySleep = isEnabled
        refreshActiveVisionSettings()
    }

    private func refreshActiveVisionSettings() {
        renderControlWindow(force: true)
        activeVisionController.update(settings: currentSettings)
    }

    private func setDesktopLyricsEnabled(_ isEnabled: Bool) {
        settingsStore.setDesktopLyricsEnabled(isEnabled)
        currentSettings.isDesktopLyricsEnabled = isEnabled
        refreshDesktopLyricsSettings()
    }

    private func setSlideshowAnnotationEnabled(_ isEnabled: Bool) {
        settingsStore.setSlideshowAnnotationEnabled(isEnabled)
        currentSettings.isSlideshowAnnotationEnabled = isEnabled
        renderControlWindow(force: true)
        slideshowAnnotationController.update(settings: currentSettings)
    }

    private func setMiscMouseWheelInverted(_ isInverted: Bool) {
        settingsStore.setMiscMouseWheelInverted(isInverted)
        currentSettings.isMiscMouseWheelInverted = isInverted
        applyMiscMouseSettings()
    }

    private func setMiscMouseSideButtonsForwardBackEnabled(_ isEnabled: Bool) {
        settingsStore.setMiscMouseSideButtonsForwardBackEnabled(isEnabled)
        currentSettings.isMiscMouseSideButtonsForwardBackEnabled = isEnabled
        applyMiscMouseSettings()
    }

    /// 鼠标组共用刷新：事件拦截与键盘模拟依赖辅助功能权限，开启任一开关时
    /// 守卫权限——未授权则回滚该开关并弹窗引导（与选区工具栏同一模式）。
    private func applyMiscMouseSettings() {
        if currentSettings.isMiscMouseWheelInverted || currentSettings.isMiscMouseSideButtonsForwardBackEnabled {
            guard AccessibilityPermission.isTrusted() else {
                if currentSettings.isMiscMouseWheelInverted {
                    settingsStore.setMiscMouseWheelInverted(false)
                    currentSettings.isMiscMouseWheelInverted = false
                }
                if currentSettings.isMiscMouseSideButtonsForwardBackEnabled {
                    settingsStore.setMiscMouseSideButtonsForwardBackEnabled(false)
                    currentSettings.isMiscMouseSideButtonsForwardBackEnabled = false
                }
                renderControlWindow(force: true)
                AlertPresenter.show(
                    title: "请先授权辅助功能",
                    message: "鼠标功能需要使用辅助功能权限拦截事件，请先在工具选项开启辅助功能。",
                    style: .warning
                )
                return
            }
        }

        renderControlWindow(force: true)
        miscController.update(settings: currentSettings)
    }

    private func openAppleMusicLogin() {
        // 防重入：已有登录窗口时直接前置，避免覆盖唯一引用导致新旧窗口状态互踩。
        if let existingWindow = appleMusicTokenLoginWindow {
            if existingWindow.isVisible {
                existingWindow.makeKeyAndOrderFront(nil)
                NSApp.activate()
                return
            }
            appleMusicTokenLoginWindow = nil
        }

        let loginWindow = AppleMusicTokenLoginWindow()
        loginWindow.onTokenCaptured = { [weak self] token in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.settingsStore.setAppleMusicMediaUserToken(token)
                self.currentSettings.appleMusicMediaUserToken = token
                self.appleMusicTokenLoginWindow = nil
                self.refreshDesktopLyricsSettings()
                AlertPresenter.show(
                    title: "Apple Music 已登录",
                    message: "已保存网页登录凭据，桌面歌词会按您设置的来源顺序尝试获取 Apple Music 歌词。"
                )
            }
        }
        appleMusicTokenLoginWindow = loginWindow
        loginWindow.show()
    }

    private func clearAppleMusicToken() {
        settingsStore.setAppleMusicMediaUserToken("")
        currentSettings.appleMusicMediaUserToken = ""
        refreshDesktopLyricsSettings()
    }

    private func setDesktopLyricsPreferredLanguage(_ language: DesktopLyricsPreferredLanguage) {
        settingsStore.setDesktopLyricsPreferredLanguage(language)
        currentSettings.desktopLyricsPreferredLanguage = language
        refreshDesktopLyricsSettings()
    }

    private func setDesktopLyricsSurfaceEnabled(_ isEnabled: Bool) {
        settingsStore.setDesktopLyricsSurfaceEnabled(isEnabled)
        currentSettings.isDesktopLyricsSurfaceEnabled = isEnabled
        refreshDesktopLyricsSettings()
    }

    private func setDynamicIslandLyricsEnabled(_ isEnabled: Bool) {
        settingsStore.setDynamicIslandLyricsEnabled(isEnabled)
        currentSettings.isDynamicIslandLyricsEnabled = isEnabled
        if !isEnabled {
            settingsStore.setDynamicIslandLyricsSpectrumEnabled(false)
            currentSettings.isDynamicIslandLyricsSpectrumEnabled = false
        }
        refreshDesktopLyricsSettings()
    }

    private func setDynamicIslandLyricsSpectrumEnabled(_ isEnabled: Bool) {
        if isEnabled {
            let hasPermission = ScreenRecordingPermission.isAuthorized || ScreenRecordingPermission.request()
            guard hasPermission else {
                settingsStore.setDynamicIslandLyricsSpectrumEnabled(false)
                currentSettings.isDynamicIslandLyricsSpectrumEnabled = false
                refreshDesktopLyricsSettings()
                showAudioCapturePermissionAlert()
                return
            }
        }
        settingsStore.setDynamicIslandLyricsSpectrumEnabled(isEnabled)
        currentSettings.isDynamicIslandLyricsSpectrumEnabled = isEnabled
        refreshDesktopLyricsSettings()
    }

    private func setDynamicIslandLyricsHideOnHover(_ isEnabled: Bool) {
        settingsStore.setDynamicIslandLyricsHidesOnHover(isEnabled)
        currentSettings.isDynamicIslandLyricsHidesOnHover = isEnabled
        refreshDesktopLyricsSettings()
    }

    private func showAudioCapturePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要允许屏幕与系统音频录制"
        alert.informativeText = "灵动大陆可视化频谱需要 macOS 的录音/屏幕与系统音频录制权限。请在系统设置中允许 Xiaoyu MacHelper 后重新勾选。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            SystemSettingsOpener.openScreenRecordingPrivacy()
        }
    }

    // 以下数值 setter 统一模式：写 store 后 read() 回读（clamp/默认值单一来源
    // 在 SettingsStore），不再手写 min/max 双份边界。

    private func setDesktopLyricsWidth(_ width: Double) {
        settingsStore.setDesktopLyricsWidth(width)
        currentSettings = settingsStore.read()
        refreshDesktopLyricsSettings()
    }

    private func setDesktopLyricsAlignment(_ alignment: LyricsTextAlignment) {
        settingsStore.setDesktopLyricsAlignment(alignment)
        currentSettings.desktopLyricsAlignment = alignment
        refreshDesktopLyricsSettings()
    }

    private func setDynamicIslandLyricsWidth(_ width: Double) {
        settingsStore.setDynamicIslandLyricsWidth(width)
        currentSettings = settingsStore.read()
        refreshDesktopLyricsSettings()
    }

    private func setDynamicIslandLyricsBlankWidth(_ width: Double) {
        settingsStore.setDynamicIslandLyricsBlankWidth(width)
        currentSettings = settingsStore.read()
        refreshDesktopLyricsSettings()
    }

    private func setDynamicIslandLyricsHeight(_ height: Double) {
        settingsStore.setDynamicIslandLyricsHeight(height)
        currentSettings = settingsStore.read()
        refreshDesktopLyricsSettings()
    }

    private func setDynamicIslandLyricsSlantRatio(_ ratio: Double) {
        settingsStore.setDynamicIslandLyricsSlantRatio(ratio)
        currentSettings = settingsStore.read()
        refreshDesktopLyricsSettings()
    }

    private func setDynamicIslandLyricsCornerRatio(_ ratio: Double) {
        settingsStore.setDynamicIslandLyricsCornerRatio(ratio)
        currentSettings = settingsStore.read()
        refreshDesktopLyricsSettings()
    }

    private func setDynamicIslandLyricsFontSize(_ fontSize: Double) {
        let previousFontSize = currentSettings.dynamicIslandLyricsFontSize
        let clampedFontSize = SettingsStore.clampedDynamicIslandLyricsFontSize(fontSize)
        settingsStore.setDynamicIslandLyricsFontSize(clampedFontSize)
        currentSettings.dynamicIslandLyricsFontSize = clampedFontSize

        // When the user makes 灵动大陆 text much larger, lift the saved height once so the
        // enlarged text has enough room immediately.  This is intentionally not a hard clamp:
        // changing the height slider afterwards still stores the smaller height and will not be
        // pushed back up until the font size is increased again.
        if clampedFontSize > previousFontSize + 0.25 {
            let suggestedHeight = Self.suggestedDynamicIslandLyricsHeight(forFontSize: clampedFontSize)
            if currentSettings.dynamicIslandLyricsHeight + 0.5 < suggestedHeight {
                settingsStore.setDynamicIslandLyricsHeight(suggestedHeight)
                currentSettings.dynamicIslandLyricsHeight = suggestedHeight
            }
        }

        refreshDesktopLyricsSettings()
    }

    private static func suggestedDynamicIslandLyricsHeight(forFontSize fontSize: Double) -> Double {
        let clampedFontSize = SettingsStore.clampedDynamicIslandLyricsFontSize(fontSize)
        guard clampedFontSize > 24.0 else { return 58.0 }
        return min(180.0, max(58.0, ceil(58.0 + (clampedFontSize - 24.0) * 1.55)))
    }

    private func setDynamicIslandLyricsFontName(_ fontName: String) {
        settingsStore.setDynamicIslandLyricsFontName(fontName)
        currentSettings.dynamicIslandLyricsFontName = fontName
        refreshDesktopLyricsSettings()
    }

    private func setDynamicIslandLyricsAlignment(_ alignment: LyricsTextAlignment) {
        settingsStore.setDynamicIslandLyricsAlignment(alignment)
        currentSettings.dynamicIslandLyricsAlignment = alignment
        refreshDesktopLyricsSettings()
    }

    private func setMenuBarLyricsEnabled(_ isEnabled: Bool) {
        settingsStore.setMenuBarLyricsEnabled(isEnabled)
        currentSettings.isMenuBarLyricsEnabled = isEnabled
        refreshDesktopLyricsSettings()
    }

    private func setMenuBarLyricsWidth(_ width: Double) {
        settingsStore.setMenuBarLyricsWidth(width)
        currentSettings = settingsStore.read()
        refreshDesktopLyricsSettings()
    }

    private func setMenuBarLyricsAlignment(_ alignment: LyricsTextAlignment) {
        settingsStore.setMenuBarLyricsAlignment(alignment)
        currentSettings.menuBarLyricsAlignment = alignment
        refreshDesktopLyricsSettings()
    }

    private func setDesktopLyricsShowsTranslation(_ isEnabled: Bool) {
        settingsStore.setDesktopLyricsShowsTranslation(isEnabled)
        currentSettings.desktopLyricsShowsTranslation = isEnabled
        refreshDesktopLyricsSettings()
    }

    private func setDesktopLyricsFontSize(_ fontSize: Double) {
        settingsStore.setDesktopLyricsFontSize(fontSize)
        currentSettings = settingsStore.read()
        refreshDesktopLyricsSettings()
    }

    private func setDesktopLyricsLocked(_ isLocked: Bool) {
        settingsStore.setDesktopLyricsLocked(isLocked)
        currentSettings.desktopLyricsLocked = isLocked
        refreshDesktopLyricsSettings()
    }

    private func setDesktopLyricsStylePreset(_ preset: DesktopLyricsStylePreset) {
        // 预设重置（清空自定义色/描边）由 store 单侧完成，回读即可，不再双写。
        settingsStore.setDesktopLyricsStylePreset(preset)
        currentSettings = settingsStore.read()
        refreshDesktopLyricsSettings()
    }

    private func setDesktopLyricsFontName(_ fontName: String) {
        settingsStore.setDesktopLyricsFontName(fontName)
        currentSettings.desktopLyricsFontName = fontName
        refreshDesktopLyricsSettings()
    }

    private func setDesktopLyricsTextColor(_ value: String) {
        settingsStore.setDesktopLyricsTextColor(value)
        currentSettings.desktopLyricsTextColor = value
        refreshDesktopLyricsSettings()
    }

    private func setDesktopLyricsStrokeColor(_ value: String) {
        settingsStore.setDesktopLyricsStrokeColor(value)
        currentSettings.desktopLyricsStrokeColor = value
        refreshDesktopLyricsSettings()
    }

    private func setDesktopLyricsStrokeWidth(_ value: Double) {
        settingsStore.setDesktopLyricsStrokeWidth(value)
        currentSettings.desktopLyricsStrokeWidth = max(0.0, min(6.0, value))
        refreshDesktopLyricsSettings()
    }

    private func setMusicLyricsAppWhitelist(_ value: String) {
        settingsStore.setMusicLyricsAppWhitelist(value)
        currentSettings.musicLyricsAppWhitelist = value
        refreshDesktopLyricsSettings()
    }

    private func setDesktopLyricsPosition(_ origin: NSPoint) {
        settingsStore.setDesktopLyricsPosition(x: Double(origin.x), y: Double(origin.y))
        currentSettings.desktopLyricsPositionX = Double(origin.x)
        currentSettings.desktopLyricsPositionY = Double(origin.y)
    }

    private func refreshDesktopLyricsSettings() {
        renderControlWindow(force: true)
        desktopLyricsController.update(settings: currentSettings)
    }

    private func setSelectionToolbarAction(_ action: ToolbarAction, enabled isEnabled: Bool) {
        guard action == .screenshot else {
            applySelectionToolbarAction(action, enabled: isEnabled)
            return
        }

        setScreenshotActionEnabled(isEnabled)
    }

    private func setScreenshotActionEnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            applySelectionToolbarAction(.screenshot, enabled: false)
            return
        }

        guard ScreenRecordingPermission.isAuthorized else {
            applySelectionToolbarAction(.screenshot, enabled: false)
            // 注意：首次 request() 只会弹出系统授权框并立即同步返回 false，
            // 并不代表被拒。因此这里不依据返回值二次判定，仅弹系统授权框 +
            // 给出指引，用户授权后重新勾选即可生效。
            ScreenRecordingPermission.request()
            let response = AlertPresenter.show(
                title: "需要录屏权限",
                message: "截图功能需要屏幕录制权限。请在系统弹窗中允许；若此前已拒绝，请在系统设置的“隐私与安全性 > 屏幕录制”中允许后重新勾选截图。",
                style: .warning,
                buttons: ["打开设置", "取消"]
            )

            if response == .alertFirstButtonReturn {
                ScreenRecordingPermission.openSettings()
            }
            return
        }

        applySelectionToolbarAction(.screenshot, enabled: true)
    }

    private func applySelectionToolbarAction(_ action: ToolbarAction, enabled isEnabled: Bool) {
        settingsStore.setSelectionToolbarAction(action, enabled: isEnabled)
        currentSettings.setSelectionToolbarAction(action, enabled: isEnabled)
        refreshSelectionToolbarSettings()
    }

    private func moveSelectionToolbarAction(_ action: ToolbarAction, direction: Int) {
        settingsStore.moveSelectionToolbarAction(action, direction: direction)
        currentSettings = settingsStore.read()
        refreshSelectionToolbarSettings()
    }

    private func moveDesktopLyricsSource(_ source: DesktopLyricsSource, direction: Int) {
        settingsStore.moveDesktopLyricsSource(source, direction: direction)
        currentSettings = settingsStore.read()
        refreshDesktopLyricsSettings()
    }

    private func setDesktopLyricsSource(_ source: DesktopLyricsSource, enabled isEnabled: Bool) {
        settingsStore.setDesktopLyricsSource(source, enabled: isEnabled)
        currentSettings = settingsStore.read()
        refreshDesktopLyricsSettings()
    }

    private func setSearchURLTemplate(_ template: String) {
        settingsStore.setSearchURLTemplate(template)
        currentSettings.searchURLTemplate = template
        selectionToolbarController.update(settings: currentSettings)
    }

    private func setScreenshotSaveDirectory(_ path: String) {
        settingsStore.setScreenshotSaveDirectory(path)
        currentSettings.screenshotSaveDirectory = path
        refreshSelectionToolbarSettings()
    }

    private func setScreenshotCopiesToClipboard(_ isEnabled: Bool) {
        settingsStore.setScreenshotCopiesToClipboard(isEnabled)
        currentSettings.screenshotCopiesToClipboard = isEnabled
        refreshSelectionToolbarSettings()
    }

    private func setScreenshotSelectsRegion(_ isEnabled: Bool) {
        settingsStore.setScreenshotSelectsRegion(isEnabled)
        currentSettings.screenshotSelectsRegion = isEnabled
        refreshSelectionToolbarSettings()
    }

    private func refreshSelectionToolbarSettings() {
        renderControlWindow(force: true)
        selectionToolbarController.update(settings: currentSettings)
    }

    private func handleCapsLockIndicatorClick() {
        guard currentSettings.isClickToDisableEnabled else {
            return
        }

        turnOffCapsLock()
    }

    private func updateCapsLockPolling() {
        guard currentSettings.isCapsLockIndicatorEnabled else {
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }

        guard pollTimer == nil else {
            return
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: Metrics.capsLockPollInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.updateCapsLockWindow(force: false) }
        }
    }

    private func updateCapsLockWindow(force: Bool) {
        guard currentSettings.isCapsLockIndicatorEnabled else {
            capsLockWindow.orderOut(nil)
            return
        }

        let isCapsLockOn = capsLockIsOn()
        guard force || isCapsLockOn != previousCapsLockState else {
            return
        }

        previousCapsLockState = isCapsLockOn

        if isCapsLockOn {
            capsLockWindow.showAtBottomCenter()
        } else {
            capsLockWindow.orderOut(nil)
        }
    }

    private func turnOffCapsLock() {
        guard capsLockIsOn() else {
            return
        }

        guard let hidSystem = openHIDSystem() else {
            return
        }

        let result = IOHIDSetModifierLockState(hidSystem, Int32(kIOHIDCapsLockState), false)
        IOServiceClose(hidSystem)

        guard result == KERN_SUCCESS else {
            return
        }

        previousCapsLockState = false
        capsLockWindow.orderOut(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.updateCapsLockWindow(force: true)
        }
    }

    private func capsLockIsOn() -> Bool {
        guard let hidSystem = openHIDSystem() else {
            return CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        }

        defer {
            IOServiceClose(hidSystem)
        }

        var state = false
        let result = IOHIDGetModifierLockState(hidSystem, Int32(kIOHIDCapsLockState), &state)
        guard result == KERN_SUCCESS else {
            return CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        }

        return state
    }

    private func openHIDSystem() -> io_connect_t? {
        let matching = IOServiceMatching(kIOHIDSystemClass)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else {
            return nil
        }

        defer {
            IOObjectRelease(service)
        }

        var connection = io_connect_t()
        let result = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection)
        guard result == KERN_SUCCESS else {
            return nil
        }

        return connection
    }
}

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
    private lazy var controlWindow = ControlWindow()
    private var pollTimer: Timer?
    private var statusPollTimer: Timer?
    private var statusPollInterval: TimeInterval?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var appleMusicTokenLoginWindow: AppleMusicTokenLoginWindow?
    private var lastRenderedControlState: ControlState?
    private var previousCapsLockState: Bool?

    init(instanceLock: SingleInstanceLock, launchMode: LaunchMode) {
        self.instanceLock = instanceLock
        self.launchMode = launchMode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        bindCallbacks()
        setupObservers()
        selectionToolbarController.start()
        activeVisionController.start()
        desktopLyricsController.start()
        updateCapsLockPolling()
        updateCapsLockWindow(force: true)
        if launchMode.showsControlWindowOnLaunch {
            showControlWindow()
        }
    }

    private func bindCallbacks() {
        capsLockWindow.onClick = { [weak self] in self?.handleCapsLockIndicatorClick() }
        controlWindow.onCapsLockIndicatorChanged = { [weak self] isEnabled in self?.setCapsLockIndicatorEnabled(isEnabled) }
        controlWindow.onClickToDisableChanged = { [weak self] isEnabled in self?.setClickToDisableEnabled(isEnabled) }
        controlWindow.onSelectionToolbarChanged = { [weak self] isEnabled in self?.setSelectionToolbarEnabled(isEnabled) }
        controlWindow.onActiveVisionChanged = { [weak self] isEnabled in self?.setActiveVisionEnabled(isEnabled) }
        controlWindow.onDesktopLyricsChanged = { [weak self] isEnabled in self?.setDesktopLyricsEnabled(isEnabled) }
        controlWindow.onSelectionToolbarActionChanged = { [weak self] action, isEnabled in self?.setSelectionToolbarAction(action, enabled: isEnabled) }
        controlWindow.onSelectionToolbarActionMoved = { [weak self] action, direction in self?.moveSelectionToolbarAction(action, direction: direction) }
        controlWindow.onDesktopLyricsSourceMoved = { [weak self] source, direction in self?.moveDesktopLyricsSource(source, direction: direction) }
        controlWindow.onDesktopLyricsSourceEnabledChanged = { [weak self] source, isEnabled in self?.setDesktopLyricsSource(source, enabled: isEnabled) }
        controlWindow.onDesktopLyricsPreferredLanguageChanged = { [weak self] language in self?.setDesktopLyricsPreferredLanguage(language) }
        controlWindow.onDesktopLyricsSurfaceChanged = { [weak self] isEnabled in self?.setDesktopLyricsSurfaceEnabled(isEnabled) }
        controlWindow.onDynamicIslandLyricsChanged = { [weak self] isEnabled in self?.setDynamicIslandLyricsEnabled(isEnabled) }
        controlWindow.onDynamicIslandLyricsSpectrumChanged = { [weak self] isEnabled in self?.setDynamicIslandLyricsSpectrumEnabled(isEnabled) }
        controlWindow.onDynamicIslandLyricsHideOnHoverChanged = { [weak self] isEnabled in self?.setDynamicIslandLyricsHideOnHover(isEnabled) }
        controlWindow.onDesktopLyricsWidthChanged = { [weak self] width in self?.setDesktopLyricsWidth(width) }
        controlWindow.onDesktopLyricsAlignmentChanged = { [weak self] alignment in self?.setDesktopLyricsAlignment(alignment) }
        controlWindow.onDynamicIslandLyricsWidthChanged = { [weak self] width in self?.setDynamicIslandLyricsWidth(width) }
        controlWindow.onDynamicIslandLyricsBlankWidthChanged = { [weak self] width in self?.setDynamicIslandLyricsBlankWidth(width) }
        controlWindow.onDynamicIslandLyricsHeightChanged = { [weak self] height in self?.setDynamicIslandLyricsHeight(height) }
        controlWindow.onDynamicIslandLyricsSlantRatioChanged = { [weak self] ratio in self?.setDynamicIslandLyricsSlantRatio(ratio) }
        controlWindow.onDynamicIslandLyricsCornerRatioChanged = { [weak self] ratio in self?.setDynamicIslandLyricsCornerRatio(ratio) }
        controlWindow.onDynamicIslandLyricsFontSizeChanged = { [weak self] fontSize in self?.setDynamicIslandLyricsFontSize(fontSize) }
        controlWindow.onDynamicIslandLyricsFontNameChanged = { [weak self] fontName in self?.setDynamicIslandLyricsFontName(fontName) }
        controlWindow.onMenuBarLyricsChanged = { [weak self] isEnabled in self?.setMenuBarLyricsEnabled(isEnabled) }
        controlWindow.onMenuBarLyricsWidthChanged = { [weak self] width in self?.setMenuBarLyricsWidth(width) }
        controlWindow.onMenuBarLyricsAlignmentChanged = { [weak self] alignment in self?.setMenuBarLyricsAlignment(alignment) }
        controlWindow.onDesktopLyricsShowsTranslationChanged = { [weak self] isEnabled in self?.setDesktopLyricsShowsTranslation(isEnabled) }
        controlWindow.onDesktopLyricsFontSizeChanged = { [weak self] fontSize in self?.setDesktopLyricsFontSize(fontSize) }
        controlWindow.onDesktopLyricsLockedChanged = { [weak self] isLocked in self?.setDesktopLyricsLocked(isLocked) }
        controlWindow.onDesktopLyricsStylePresetChanged = { [weak self] preset in self?.setDesktopLyricsStylePreset(preset) }
        controlWindow.onDesktopLyricsFontNameChanged = { [weak self] fontName in self?.setDesktopLyricsFontName(fontName) }
        controlWindow.onDesktopLyricsTextColorChanged = { [weak self] value in self?.setDesktopLyricsTextColor(value) }
        controlWindow.onDesktopLyricsStrokeColorChanged = { [weak self] value in self?.setDesktopLyricsStrokeColor(value) }
        controlWindow.onDesktopLyricsStrokeWidthChanged = { [weak self] value in self?.setDesktopLyricsStrokeWidth(value) }
        controlWindow.onMusicLyricsAppWhitelistChanged = { [weak self] value in self?.setMusicLyricsAppWhitelist(value) }
        controlWindow.onSearchTemplateChanged = { [weak self] template in self?.setSearchURLTemplate(template) }
        controlWindow.onScreenshotSaveDirectoryChanged = { [weak self] path in self?.setScreenshotSaveDirectory(path) }
        controlWindow.onScreenshotCopiesToClipboardChanged = { [weak self] isEnabled in self?.setScreenshotCopiesToClipboard(isEnabled) }
        controlWindow.onScreenshotSelectsRegionChanged = { [weak self] isEnabled in self?.setScreenshotSelectsRegion(isEnabled) }
        controlWindow.onActiveVisionGazeChanged = { [weak self] isEnabled in self?.setActiveVisionPreventsDisplaySleepOnGaze(isEnabled) }
        controlWindow.onActiveVisionFacingChanged = { [weak self] isEnabled in self?.setActiveVisionPreventsDisplaySleepOnFacing(isEnabled) }
        controlWindow.onActiveVisionNotifyChanged = { [weak self] isEnabled in self?.setActiveVisionNotifyWhenExtendingDisplaySleep(isEnabled) }
        controlWindow.onAppleMusicLoginRequested = { [weak self] in self?.openAppleMusicLogin() }
        controlWindow.onAppleMusicTokenCleared = { [weak self] in self?.clearAppleMusicToken() }
        controlWindow.onLoginItemChanged = { [weak self] isEnabled in self?.setLoginItemEnabled(isEnabled) }
        controlWindow.onLoginItemGuide = { [weak self] in self?.openLoginItemSettings() }
        controlWindow.onAccessibilityEnableRequested = { [weak self] in self?.enableAccessibilityGuide() }
        controlWindow.onAccessibilityDisableRequested = { [weak self] in self?.disableAccessibilityGuide() }
        controlWindow.onAccessibilityGuide = { [weak self] in self?.openAccessibilitySettings() }
        controlWindow.onRefreshRequested = { [weak self] in self?.renderControlWindow() }
        controlWindow.onFocusChanged = { [weak self] isFocused in self?.updateStatusPolling(isFocused: isFocused) }
        controlWindow.onHidden = { [weak self] in self?.stopStatusPolling() }
        controlWindow.onClearDataAndQuit = { [weak self] in self?.clearDataAndQuit() }
        controlWindow.onQuit = { NSApp.terminate(nil) }
        desktopLyricsController.onPositionChanged = { [weak self] origin in self?.setDesktopLyricsPosition(origin) }
    }

    private func clearDataAndQuit() {
        settingsStore.clearPersistentData()
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeEventMonitor(&globalFlagsMonitor)
        removeEventMonitor(&localFlagsMonitor)
        if let didBecomeActiveObserver { NotificationCenter.default.removeObserver(didBecomeActiveObserver) }
        pollTimer?.invalidate()
        pollTimer = nil
        stopStatusPolling()
        selectionToolbarController.stop()
        activeVisionController.stop()
        desktopLyricsController.stop()
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
        guard AlertPresenter.confirm(title: title, message: message) else { return renderControlWindow(force: true) }
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
        renderControlWindow(force: true)
        controlWindow.show()
        updateStatusPolling(isFocused: controlWindow.isKeyWindow)
    }

    private func renderControlWindow(force: Bool = false) {
        let state = ControlState(
            settings: currentSettings,
            isLoginItemEnabled: LoginItemManager.isInstalled(),
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

    private func openAppleMusicLogin() {
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
            let hasPermission = SystemAudioSpectrumMonitor.hasCapturePermission() || SystemAudioSpectrumMonitor.requestCapturePermission()
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
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setDesktopLyricsWidth(_ width: Double) {
        settingsStore.setDesktopLyricsWidth(width)
        currentSettings.desktopLyricsWidth = min(2200.0, max(260.0, width))
        refreshDesktopLyricsSettings()
    }

    private func setDesktopLyricsAlignment(_ alignment: LyricsTextAlignment) {
        settingsStore.setDesktopLyricsAlignment(alignment)
        currentSettings.desktopLyricsAlignment = alignment
        refreshDesktopLyricsSettings()
    }

    private func setDynamicIslandLyricsWidth(_ width: Double) {
        settingsStore.setDynamicIslandLyricsWidth(width)
        currentSettings.dynamicIslandLyricsWidth = min(1700.0, max(360.0, width))
        refreshDesktopLyricsSettings()
    }

    private func setDynamicIslandLyricsBlankWidth(_ width: Double) {
        settingsStore.setDynamicIslandLyricsBlankWidth(width)
        currentSettings.dynamicIslandLyricsBlankWidth = min(900.0, max(60.0, width))
        refreshDesktopLyricsSettings()
    }

    private func setDynamicIslandLyricsHeight(_ height: Double) {
        settingsStore.setDynamicIslandLyricsHeight(height)
        currentSettings.dynamicIslandLyricsHeight = min(180.0, max(32.0, height))
        refreshDesktopLyricsSettings()
    }

    private func setDynamicIslandLyricsSlantRatio(_ ratio: Double) {
        settingsStore.setDynamicIslandLyricsSlantRatio(ratio)
        currentSettings.dynamicIslandLyricsSlantRatio = min(1.0, max(0.01, ratio))
        refreshDesktopLyricsSettings()
    }

    private func setDynamicIslandLyricsCornerRatio(_ ratio: Double) {
        settingsStore.setDynamicIslandLyricsCornerRatio(ratio)
        currentSettings.dynamicIslandLyricsCornerRatio = min(1.0, max(0.01, ratio))
        refreshDesktopLyricsSettings()
    }

    private func setDynamicIslandLyricsFontSize(_ fontSize: Double) {
        let previousFontSize = currentSettings.dynamicIslandLyricsFontSize
        let clampedFontSize = min(64.0, max(11.0, fontSize))
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
        let clampedFontSize = min(64.0, max(11.0, fontSize))
        guard clampedFontSize > 24.0 else { return 58.0 }
        return min(180.0, max(58.0, ceil(58.0 + (clampedFontSize - 24.0) * 1.55)))
    }

    private func setDynamicIslandLyricsFontName(_ fontName: String) {
        settingsStore.setDynamicIslandLyricsFontName(fontName)
        currentSettings.dynamicIslandLyricsFontName = fontName
        refreshDesktopLyricsSettings()
    }

    private func setMenuBarLyricsEnabled(_ isEnabled: Bool) {
        settingsStore.setMenuBarLyricsEnabled(isEnabled)
        currentSettings.isMenuBarLyricsEnabled = isEnabled
        refreshDesktopLyricsSettings()
    }

    private func setMenuBarLyricsWidth(_ width: Double) {
        settingsStore.setMenuBarLyricsWidth(width)
        currentSettings.menuBarLyricsWidth = min(760.0, max(40.0, width))
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
        currentSettings.desktopLyricsFontSize = min(48.0, max(18.0, fontSize))
        refreshDesktopLyricsSettings()
    }

    private func setDesktopLyricsLocked(_ isLocked: Bool) {
        settingsStore.setDesktopLyricsLocked(isLocked)
        currentSettings.desktopLyricsLocked = isLocked
        refreshDesktopLyricsSettings()
    }

    private func setDesktopLyricsStylePreset(_ preset: DesktopLyricsStylePreset) {
        settingsStore.setDesktopLyricsStylePreset(preset)
        currentSettings.desktopLyricsStylePreset = preset
        currentSettings.desktopLyricsTextColor = ""
        currentSettings.desktopLyricsStrokeColor = ""
        currentSettings.desktopLyricsStrokeWidth = -1.0
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
            AlertPresenter.show(
                title: "需要录屏权限",
                message: "截图功能需要屏幕录制权限才能读取屏幕内容。点击“知道了”后将向系统申请权限。",
                style: .warning
            )

            if ScreenRecordingPermission.request() {
                applySelectionToolbarAction(.screenshot, enabled: true)
            } else {
                applySelectionToolbarAction(.screenshot, enabled: false)
                let response = AlertPresenter.show(
                    title: "无法开启截图",
                    message: "请在系统设置的“隐私与安全性 > 屏幕录制”中允许 Xiaoyu MacHelper，然后重新勾选截图。",
                    style: .warning,
                    buttons: ["打开设置", "取消"]
                )

                if response == .alertFirstButtonReturn {
                    ScreenRecordingPermission.openSettings()
                }
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

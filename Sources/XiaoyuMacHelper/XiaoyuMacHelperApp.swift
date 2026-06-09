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
    private lazy var controlWindow = ControlWindow()
    private var pollTimer: Timer?
    private var statusPollTimer: Timer?
    private var statusPollInterval: TimeInterval?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var didBecomeActiveObserver: NSObjectProtocol?
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
        controlWindow.onSelectionToolbarActionChanged = { [weak self] action, isEnabled in self?.setSelectionToolbarAction(action, enabled: isEnabled) }
        controlWindow.onSelectionToolbarActionMoved = { [weak self] action, direction in self?.moveSelectionToolbarAction(action, direction: direction) }
        controlWindow.onSearchTemplateChanged = { [weak self] template in self?.setSearchURLTemplate(template) }
        controlWindow.onScreenshotSaveDirectoryChanged = { [weak self] path in self?.setScreenshotSaveDirectory(path) }
        controlWindow.onScreenshotCopiesToClipboardChanged = { [weak self] isEnabled in self?.setScreenshotCopiesToClipboard(isEnabled) }
        controlWindow.onScreenshotSelectsRegionChanged = { [weak self] isEnabled in self?.setScreenshotSelectsRegion(isEnabled) }
        controlWindow.onActiveVisionGazeChanged = { [weak self] isEnabled in self?.setActiveVisionPreventsDisplaySleepOnGaze(isEnabled) }
        controlWindow.onActiveVisionFacingChanged = { [weak self] isEnabled in self?.setActiveVisionPreventsDisplaySleepOnFacing(isEnabled) }
        controlWindow.onActiveVisionNotifyChanged = { [weak self] isEnabled in self?.setActiveVisionNotifyWhenExtendingDisplaySleep(isEnabled) }
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

    private func setSelectionToolbarAction(_ action: ToolbarAction, enabled isEnabled: Bool) {
        settingsStore.setSelectionToolbarAction(action, enabled: isEnabled)
        currentSettings.setSelectionToolbarAction(action, enabled: isEnabled)
        refreshSelectionToolbarSettings()
    }

    private func moveSelectionToolbarAction(_ action: ToolbarAction, direction: Int) {
        settingsStore.moveSelectionToolbarAction(action, direction: direction)
        currentSettings = settingsStore.read()
        refreshSelectionToolbarSettings()
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


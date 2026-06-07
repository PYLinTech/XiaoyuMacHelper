import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Darwin
import IOKit
import IOKit.hidsystem
import ScreenCaptureKit
import ServiceManagement

private let appIdentifier = "local.xiaoyu-mac-helper"
private let loginItemArgument = "--login-item"
private let showControlWindowNotification = Notification.Name("\(appIdentifier).show-control-window")
private let capsLockIndicatorEnabledKey = "CapsLockIndicatorEnabled"
private let capsLockIndicatorClickToDisableEnabledKey = "CapsLockIndicatorClickToDisableEnabled"
private let selectionToolbarEnabledKey = "SelectionToolbarEnabled"
private let selectionToolbarCopyEnabledKey = "SelectionToolbarCopyEnabled"
private let selectionToolbarPasteEnabledKey = "SelectionToolbarPasteEnabled"
private let selectionToolbarSearchEnabledKey = "SelectionToolbarSearchEnabled"
private let selectionToolbarScreenshotEnabledKey = "SelectionToolbarScreenshotEnabled"
private let selectionToolbarOrderKey = "SelectionToolbarOrder"
private let searchURLTemplateKey = "SearchURLTemplate"
private let screenshotSaveDirectoryKey = "ScreenshotSaveDirectory"
private let screenshotCopiesToClipboardKey = "ScreenshotCopiesToClipboard"
private let screenshotSelectsRegionKey = "ScreenshotSelectsRegion"
private let selectionToolbarDefaultOffMigrationKey = "SelectionToolbarDefaultOffMigrationDone"

private func defaultScreenshotDirectoryURL() -> URL {
    FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
}

enum ToolbarAction: String, Sendable {
    case copy
    case paste
    case search
    case screenshot

    static let configurableCases: [ToolbarAction] = [.copy, .paste, .search, .screenshot]

    var title: String {
        switch self {
        case .copy: return "复制"
        case .paste: return "粘贴"
        case .search: return "搜索"
        case .screenshot: return "截图"
        }
    }

    var shortcutKeyCode: CGKeyCode? {
        switch self {
        case .copy: return CGKeyCode(kVK_ANSI_C)
        case .paste: return CGKeyCode(kVK_ANSI_V)
        case .search, .screenshot: return nil
        }
    }

    var defaultsKey: String? {
        switch self {
        case .copy: return selectionToolbarCopyEnabledKey
        case .paste: return selectionToolbarPasteEnabledKey
        case .search: return selectionToolbarSearchEnabledKey
        case .screenshot: return selectionToolbarScreenshotEnabledKey
        }
    }
}

struct SearchEnginePreset: Equatable {
    let title: String
    let template: String

    static let all: [SearchEnginePreset] = [
        SearchEnginePreset(title: "谷歌", template: "https://www.google.com/search?q=%s"),
        SearchEnginePreset(title: "必应", template: "https://www.bing.com/search?q=%s"),
        SearchEnginePreset(title: "必应中国", template: "https://cn.bing.com/search?q=%s"),
        SearchEnginePreset(title: "百度", template: "https://www.baidu.com/s?wd=%s")
    ]

    static let defaultTemplate = all[0].template
    static let customTitle = "自定义"

    static func presetIndex(for template: String) -> Int? {
        all.firstIndex { $0.template == template }
    }
}

struct AppSettings: Equatable, Sendable {
    var isCapsLockIndicatorEnabled: Bool
    var isClickToDisableEnabled: Bool
    var isSelectionToolbarEnabled: Bool
    var isSelectionToolbarCopyEnabled: Bool
    var isSelectionToolbarPasteEnabled: Bool
    var isSelectionToolbarSearchEnabled: Bool
    var isSelectionToolbarScreenshotEnabled: Bool
    var selectionToolbarOrder: [ToolbarAction]
    var searchURLTemplate: String
    var screenshotSaveDirectory: String
    var screenshotCopiesToClipboard: Bool
    var screenshotSelectsRegion: Bool

    var visibleSelectionToolbarActions: [ToolbarAction] {
        selectionToolbarOrder.filter(isSelectionToolbarActionEnabled)
    }

    func isSelectionToolbarActionEnabled(_ action: ToolbarAction) -> Bool {
        switch action {
        case .copy: return isSelectionToolbarCopyEnabled
        case .paste: return isSelectionToolbarPasteEnabled
        case .search: return isSelectionToolbarSearchEnabled
        case .screenshot: return isSelectionToolbarScreenshotEnabled
        }
    }

    mutating func setSelectionToolbarAction(_ action: ToolbarAction, enabled isEnabled: Bool) {
        switch action {
        case .copy: isSelectionToolbarCopyEnabled = isEnabled
        case .paste: isSelectionToolbarPasteEnabled = isEnabled
        case .search: isSelectionToolbarSearchEnabled = isEnabled
        case .screenshot: isSelectionToolbarScreenshotEnabled = isEnabled
        }
    }
}

struct ControlState: Equatable {
    var settings: AppSettings
    var isLoginItemEnabled: Bool
    var isAccessibilityEnabled: Bool
}

struct LaunchMode {
    let showsControlWindowOnLaunch: Bool
    let notifiesRunningInstance: Bool

    static func current(arguments: [String] = CommandLine.arguments) -> LaunchMode {
        let isLoginItemLaunch = arguments.contains(loginItemArgument)

        return LaunchMode(
            showsControlWindowOnLaunch: !isLoginItemLaunch,
            notifiesRunningInstance: !isLoginItemLaunch
        )
    }
}

final class SettingsStore {
    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            capsLockIndicatorEnabledKey: true,
            capsLockIndicatorClickToDisableEnabledKey: true,
            selectionToolbarEnabledKey: false,
            selectionToolbarCopyEnabledKey: true,
            selectionToolbarPasteEnabledKey: true,
            selectionToolbarSearchEnabledKey: true,
            selectionToolbarScreenshotEnabledKey: true,
            selectionToolbarOrderKey: ToolbarAction.configurableCases.map(\.rawValue),
            searchURLTemplateKey: SearchEnginePreset.defaultTemplate,
            screenshotSaveDirectoryKey: defaultScreenshotDirectoryURL().path,
            screenshotCopiesToClipboardKey: true,
            screenshotSelectsRegionKey: false
        ])

        if !defaults.bool(forKey: selectionToolbarDefaultOffMigrationKey) {
            defaults.set(false, forKey: selectionToolbarEnabledKey)
            defaults.set(true, forKey: selectionToolbarDefaultOffMigrationKey)
        }
    }

    func read() -> AppSettings {
        let savedOrder = defaults.stringArray(forKey: selectionToolbarOrderKey) ?? []
        let order = normalizedOrder(savedOrder.compactMap(ToolbarAction.init(rawValue:)))

        return AppSettings(
            isCapsLockIndicatorEnabled: defaults.bool(forKey: capsLockIndicatorEnabledKey),
            isClickToDisableEnabled: defaults.bool(forKey: capsLockIndicatorClickToDisableEnabledKey),
            isSelectionToolbarEnabled: defaults.bool(forKey: selectionToolbarEnabledKey),
            isSelectionToolbarCopyEnabled: defaults.bool(forKey: selectionToolbarCopyEnabledKey),
            isSelectionToolbarPasteEnabled: defaults.bool(forKey: selectionToolbarPasteEnabledKey),
            isSelectionToolbarSearchEnabled: defaults.bool(forKey: selectionToolbarSearchEnabledKey),
            isSelectionToolbarScreenshotEnabled: defaults.bool(forKey: selectionToolbarScreenshotEnabledKey),
            selectionToolbarOrder: order,
            searchURLTemplate: defaults.string(forKey: searchURLTemplateKey) ?? SearchEnginePreset.defaultTemplate,
            screenshotSaveDirectory: defaults.string(forKey: screenshotSaveDirectoryKey) ?? defaultScreenshotDirectoryURL().path,
            screenshotCopiesToClipboard: defaults.bool(forKey: screenshotCopiesToClipboardKey),
            screenshotSelectsRegion: defaults.bool(forKey: screenshotSelectsRegionKey)
        )
    }

    func setCapsLockIndicatorEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: capsLockIndicatorEnabledKey)
    }

    func setClickToDisableEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: capsLockIndicatorClickToDisableEnabledKey)
    }

    func setSelectionToolbarEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: selectionToolbarEnabledKey)
    }

    func setSelectionToolbarAction(_ action: ToolbarAction, enabled isEnabled: Bool) {
        guard let defaultsKey = action.defaultsKey else {
            return
        }

        defaults.set(isEnabled, forKey: defaultsKey)
    }

    func setSearchURLTemplate(_ template: String) {
        defaults.set(template, forKey: searchURLTemplateKey)
    }

    func setScreenshotSaveDirectory(_ path: String) {
        defaults.set(path, forKey: screenshotSaveDirectoryKey)
    }

    func setScreenshotCopiesToClipboard(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: screenshotCopiesToClipboardKey)
    }

    func setScreenshotSelectsRegion(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: screenshotSelectsRegionKey)
    }

    func clearPersistentData() {
        let domain = Bundle.main.bundleIdentifier ?? appIdentifier
        defaults.removePersistentDomain(forName: domain)
        defaults.synchronize()
    }

    func moveSelectionToolbarAction(_ action: ToolbarAction, direction: Int) {
        var order = read().selectionToolbarOrder
        guard let index = order.firstIndex(of: action) else {
            return
        }

        let newIndex = max(0, min(order.count - 1, index + direction))
        guard newIndex != index else {
            return
        }

        order.remove(at: index)
        order.insert(action, at: newIndex)
        defaults.set(order.map(\.rawValue), forKey: selectionToolbarOrderKey)
    }

    private func normalizedOrder(_ savedOrder: [ToolbarAction]) -> [ToolbarAction] {
        var result: [ToolbarAction] = []

        for action in savedOrder where !result.contains(action) {
            result.append(action)
        }

        for action in ToolbarAction.configurableCases where !result.contains(action) {
            result.append(action)
        }

        return result
    }
}

final class SingleInstanceLock {
    private let lockURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(appIdentifier).lock")
    private var lockDescriptor: Int32 = -1

    func acquireOrNotifyRunningInstance(shouldNotifyRunningInstance: Bool) -> Bool {
        lockDescriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0 else {
            return true
        }

        if flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 {
            ftruncate(lockDescriptor, 0)
            let pidText = "\(getpid())\n"
            pidText.withCString { pointer in
                _ = write(lockDescriptor, pointer, strlen(pointer))
            }
            return true
        }

        if shouldNotifyRunningInstance {
            DistributedNotificationCenter.default().postNotificationName(
                showControlWindowNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
        return false
    }

    func releaseLock() {
        guard lockDescriptor >= 0 else {
            return
        }

        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }
}

enum LoginItemManager {
    static func install() throws {
        try register(SMAppService.mainApp)
    }

    static func uninstall() throws {
        try unregister(SMAppService.mainApp)
    }

    static func isInstalled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func openLoginItemsSettings() {
        SystemSettingsOpener.openLoginItems()
    }

    private static func register(_ service: SMAppService) throws {
        guard service.status != .enabled else {
            return
        }

        do {
            try service.register()
        } catch {
            guard !isServiceManagementError(error, code: kSMErrorAlreadyRegistered) else {
                return
            }

            throw error
        }
    }

    private static func unregister(_ service: SMAppService) throws {
        do {
            try service.unregister()
        } catch {
            guard !isServiceManagementError(error, code: kSMErrorJobNotFound) else {
                return
            }

            throw error
        }
    }

    private static func isServiceManagementError(_ error: Error, code: Int) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SMAppServiceErrorDomain && nsError.code == code
    }
}

enum SystemSettingsOpener {
    static func openLoginItems() {
        open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

enum AccessibilityPermission {
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        SystemSettingsOpener.openAccessibility()
    }
}

@MainActor
enum AlertPresenter {
    @discardableResult
    static func show(
        title: String,
        message: String,
        style: NSAlert.Style = .informational,
        buttons: [String] = ["知道了"]
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }

    static func confirm(title: String, message: String) -> Bool {
        show(title: title, message: message, buttons: ["知道了", "取消"]) == .alertFirstButtonReturn
    }
}

@MainActor
private func removeEventMonitor(_ monitor: inout Any?) {
    if let eventMonitor = monitor { NSEvent.removeMonitor(eventMonitor) }
    monitor = nil
}

private extension NSRect {
    var area: CGFloat {
        width * height
    }
}

@MainActor
enum LiquidGlassOverlayStyle {
    private static let overlayTextShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.74)
        shadow.shadowBlurRadius = 2.8
        shadow.shadowOffset = NSSize(width: 0, height: -1.0)
        return shadow
    }()

    static func configureGlass(_ view: NSGlassEffectView, cornerRadius: CGFloat) {
        view.style = .clear
        view.tintColor = nil
        view.cornerRadius = cornerRadius
    }

    static func primaryTextColor() -> NSColor {
        NSColor.white.withAlphaComponent(0.96)
    }

    static func hoverBackgroundColor() -> CGColor {
        NSColor.controlAccentColor.cgColor
    }

    static func textShadow() -> NSShadow {
        overlayTextShadow
    }

    static func attributedText(_ text: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: primaryTextColor(),
                .font: font,
                .shadow: textShadow()
            ]
        )
    }
}

@MainActor
final class ClickableView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = false
    }
}

@MainActor
final class ToolbarButton: NSButton {
    private enum Style {
        @MainActor
        static func hoverBackground() -> CGColor {
            LiquidGlassOverlayStyle.hoverBackgroundColor()
        }
    }

    let actionType: ToolbarAction
    var onAction: ((ToolbarAction) -> Void)?

    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false

    init(action: ToolbarAction) {
        self.actionType = action
        super.init(frame: .zero)

        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        setButtonType(.momentaryChange)
        refreshAppearanceColors()
        target = self
        self.action = #selector(clicked)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateHoverBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateHoverBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHoverBackground()
    }

    @objc private func clicked() {
        onAction?(actionType)
    }

    func refreshAppearanceColors() {
        let title = Self.title(actionType.title)
        attributedTitle = title
        attributedAlternateTitle = title
        updateHoverBackground()
    }

    private func updateHoverBackground() {
        guard let layer else { return }

        layer.backgroundColor = isHovering ? Style.hoverBackground() : nil
        layer.borderColor = nil
        layer.borderWidth = 0
    }

    private static func title(_ text: String) -> NSAttributedString {
        LiquidGlassOverlayStyle.attributedText(
            text,
            font: NSFont.systemFont(ofSize: 13, weight: .medium)
        )
    }
}

@MainActor
final class ScreenshotToolbarButton: NSButton {
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false
    var onClick: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)

        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        setButtonType(.momentaryChange)
        target = self
        action = #selector(clicked)
        setTitle(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateHoverBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateHoverBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHoverBackground()
    }

    func setTitle(_ title: String) {
        let attributed = LiquidGlassOverlayStyle.attributedText(
            title,
            font: NSFont.systemFont(ofSize: 13, weight: .medium)
        )
        attributedTitle = attributed
        attributedAlternateTitle = attributed
    }

    @objc private func clicked() {
        onClick?()
    }

    private func updateHoverBackground() {
        layer?.backgroundColor = isHovering ? LiquidGlassOverlayStyle.hoverBackgroundColor() : nil
    }
}

@MainActor
final class ScreenshotActionToolbarWindow: FloatingOverlayPanel {
    private enum Metrics {
        static let height: CGFloat = 38
        static let horizontalPadding: CGFloat = 6
        static let buttonWidth: CGFloat = 58
        static let buttonHeight: CGFloat = 28
        static let buttonGap: CGFloat = 6
        static let cornerRadius: CGFloat = 10

        static var width: CGFloat {
            horizontalPadding * 2 + buttonWidth * 2 + buttonGap
        }
    }

    private let fullScreenButton = ScreenshotToolbarButton(title: "全屏")
    private let confirmButton = ScreenshotToolbarButton(title: "✓")
    private let buttonContainer = NSView()
    var onFullScreen: (() -> Void)?
    var onConfirm: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configureFloatingOverlay()
        level = .screenSaver

        let background = NSGlassEffectView(frame: contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        LiquidGlassOverlayStyle.configureGlass(background, cornerRadius: Metrics.cornerRadius)
        buttonContainer.frame = background.bounds
        buttonContainer.autoresizingMask = [.width, .height]
        background.contentView = buttonContainer
        contentView = background

        fullScreenButton.onClick = { [weak self] in self?.onFullScreen?() }
        confirmButton.onClick = { [weak self] in self?.onConfirm?() }
        buttonContainer.addSubview(fullScreenButton)
        buttonContainer.addSubview(confirmButton)
        layoutButtons()
    }

    func show(at frame: NSRect) {
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    private func layoutButtons() {
        fullScreenButton.frame = NSRect(
            x: Metrics.horizontalPadding,
            y: (Metrics.height - Metrics.buttonHeight) / 2,
            width: Metrics.buttonWidth,
            height: Metrics.buttonHeight
        )
        confirmButton.frame = NSRect(
            x: fullScreenButton.frame.maxX + Metrics.buttonGap,
            y: fullScreenButton.frame.minY,
            width: Metrics.buttonWidth,
            height: Metrics.buttonHeight
        )
    }
}

@MainActor
final class SelectionToolbarWindow: FloatingOverlayPanel {
    private enum Metrics {
        static let height: CGFloat = 38
        static let horizontalPadding: CGFloat = 6
        static let buttonWidth: CGFloat = 58
        static let buttonHeight: CGFloat = 28
        static let buttonGap: CGFloat = 6
        static let cornerRadius: CGFloat = 10
        static let edgePadding: CGFloat = 8
        static let verticalOffset: CGFloat = 12

        static func width(for actionCount: Int) -> CGFloat {
            horizontalPadding * 2 + CGFloat(actionCount) * buttonWidth + CGFloat(max(0, actionCount - 1)) * buttonGap
        }
    }

    private var buttons: [ToolbarButton] = []
    private let buttonContainer = NSView()
    var onAction: ((ToolbarAction) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: Metrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configureFloatingOverlay()

        let background = NSGlassEffectView(frame: contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        LiquidGlassOverlayStyle.configureGlass(background, cornerRadius: Metrics.cornerRadius)
        buttonContainer.frame = background.bounds
        buttonContainer.autoresizingMask = [.width, .height]
        background.contentView = buttonContainer
        contentView = background
    }

    func show(actions: [ToolbarAction], near point: NSPoint) {
        guard !actions.isEmpty else { return orderOut(nil) }

        animationBehavior = .default
        alphaValue = 1
        rebuildButtons(actions: actions)
        let size = NSSize(width: Metrics.width(for: actions.count), height: Metrics.height)
        setFrame(NSRect(origin: .zero, size: size), display: false)
        layoutButtons()
        setFrameOrigin(clampedOrigin(near: point, size: size))
        orderFrontRegardless()
    }

    func hide(immediately: Bool) {
        guard isVisible else { return }
        guard immediately else {
            orderOut(nil)
            return
        }

        let originalAnimationBehavior = animationBehavior
        animationBehavior = .none
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            orderOut(nil)
        }
        animationBehavior = originalAnimationBehavior
    }

    private func rebuildButtons(actions: [ToolbarAction]) {
        guard actions != buttons.map(\.actionType) else {
            return
        }

        buttons.forEach { $0.removeFromSuperview() }
        buttons = actions.map { action in
            let button = ToolbarButton(action: action)
            button.onAction = { [weak self] action in
                self?.onAction?(action)
            }
            buttonContainer.addSubview(button)
            return button
        }
    }

    private func layoutButtons() {
        for (index, button) in buttons.enumerated() {
            let x = Metrics.horizontalPadding + CGFloat(index) * (Metrics.buttonWidth + Metrics.buttonGap)
            button.frame = NSRect(
                x: x,
                y: (Metrics.height - Metrics.buttonHeight) / 2,
                width: Metrics.buttonWidth,
                height: Metrics.buttonHeight
            )
        }
    }

    private func clampedOrigin(near point: NSPoint, size: NSSize) -> NSPoint {
        let preferred = NSPoint(
            x: point.x - size.width / 2,
            y: point.y - size.height - Metrics.verticalOffset
        )
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        return NSPoint(
            x: min(max(preferred.x, visible.minX + Metrics.edgePadding), visible.maxX - size.width - Metrics.edgePadding),
            y: min(max(preferred.y, visible.minY + Metrics.edgePadding), visible.maxY - size.height - Metrics.edgePadding)
        )
    }
}

@MainActor
final class CenteredGlassTextView: NSView {
    var text: String = "" {
        didSet { invalidateTextLayout() }
    }

    var font: NSFont = NSFont.systemFont(ofSize: 13, weight: .medium) {
        didSet { invalidateTextLayout() }
    }

    private var cachedText: NSAttributedString?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let attributedText = styledText()
        let textSize = measuredSize()
        let drawRect = NSRect(
            x: 0,
            y: floor((bounds.height - textSize.height) / 2),
            width: bounds.width,
            height: ceil(textSize.height)
        )
        attributedText.draw(
            with: drawRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            context: nil
        )
    }

    func measuredWidth(for text: String) -> CGFloat {
        ceil(styledText(for: text).boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).width)
    }

    private func measuredSize() -> NSSize {
        styledText().boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
    }

    private func styledText() -> NSAttributedString {
        if let cachedText {
            return cachedText
        }

        let attributedText = styledText(for: text)
        cachedText = attributedText
        return attributedText
    }

    private func styledText(for text: String) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let attributedText = NSMutableAttributedString(attributedString: LiquidGlassOverlayStyle.attributedText(text, font: font))
        attributedText.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: attributedText.length))
        return attributedText
    }

    private func invalidateTextLayout() {
        cachedText = nil
        needsDisplay = true
    }
}

@MainActor
class GlassTextWindow: FloatingOverlayPanel {
    struct Configuration {
        let height: CGFloat
        let horizontalPadding: CGFloat
        let minWidth: CGFloat
        let maxWidth: CGFloat?
        let font: NSFont
        let cornerRadius: CGFloat
    }

    private let configuration: Configuration
    private let textView = CenteredGlassTextView()
    let content = ClickableView()

    init(configuration: Configuration, initialMessage: String = "") {
        self.configuration = configuration
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: configuration.minWidth, height: configuration.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configureFloatingOverlay()

        let background = NSGlassEffectView(frame: contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        LiquidGlassOverlayStyle.configureGlass(background, cornerRadius: configuration.cornerRadius)
        content.frame = background.bounds
        content.autoresizingMask = [.width, .height]
        background.contentView = content

        textView.frame = content.bounds.insetBy(dx: configuration.horizontalPadding, dy: 0)
        textView.autoresizingMask = [.width, .height]
        textView.font = configuration.font
        textView.text = initialMessage
        content.addSubview(textView)

        contentView = background
    }

    func setMessage(_ message: String) {
        textView.text = message
    }

    func fittingSize(for message: String) -> NSSize {
        let textWidth = textView.measuredWidth(for: message)
        let rawWidth = max(ceil(textWidth + configuration.horizontalPadding * 2), configuration.minWidth)
        let width = configuration.maxWidth.map { min(rawWidth, $0) } ?? rawWidth
        return NSSize(width: width, height: configuration.height)
    }

    func bottomCenterOrigin(size: NSSize, bottomInset: CGFloat) -> NSPoint {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.midX - size.width / 2, y: visible.minY + bottomInset)
    }
}

@MainActor
final class ToastWindow: GlassTextWindow {
    private enum Metrics {
        static let bottomInset: CGFloat = 82
    }

    private var dismissWorkItem: DispatchWorkItem?

    init() {
        super.init(
            configuration: Configuration(
                height: 36,
                horizontalPadding: 22,
                minWidth: 150,
                maxWidth: 360,
                font: NSFont.systemFont(ofSize: 13, weight: .medium),
                cornerRadius: 18
            )
        )
    }

    func show(message: String, duration: TimeInterval = 1.6) {
        dismissWorkItem?.cancel()
        let size = fittingSize(for: message)
        setFrame(NSRect(origin: bottomCenterOrigin(size: size, bottomInset: Metrics.bottomInset), size: size), display: true)
        setMessage(message)
        orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in
            self?.orderOut(nil)
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }
}

@MainActor
final class ScreenshotSelectionWindow: NSPanel {
    private let selectionView = ScreenshotSelectionView()
    private let actionToolbarWindow = ScreenshotActionToolbarWindow()

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
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        contentView = selectionView
    }

    override func orderOut(_ sender: Any?) {
        actionToolbarWindow.orderOut(nil)
        super.orderOut(sender)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show(
        image: CGImage,
        screenFrame: NSRect,
        initialSelection: NSRect,
        onConfirm: @escaping (CGImage) -> Void,
        onFailure: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        setFrame(screenFrame, display: true)
        attachActionToolbarIfNeeded()
        actionToolbarWindow.onFullScreen = { [weak self] in
            guard let self else { return }
            self.dismissSelectionOverlay()
            onConfirm(image)
        }
        actionToolbarWindow.onConfirm = { [weak self] in
            self?.selectionView.confirm()
        }
        selectionView.configure(
            image: image,
            initialSelection: initialSelection,
            onConfirm: { [weak self] selection in
                guard let self else { return }
                self.dismissSelectionOverlay()
                guard let croppedImage = Self.crop(image, selection: selection, screenSize: screenFrame.size) else {
                    onFailure()
                    return
                }
                onConfirm(croppedImage)
            },
            onCancel: { [weak self] in
                self?.dismissSelectionOverlay()
                onCancel()
            },
            onActionBarFrameChanged: { [weak self] frame in
                self?.positionActionToolbar(frame, screenFrame: screenFrame)
            }
        )
        orderFrontRegardless()
        positionActionToolbar(selectionView.actionBarFrame, screenFrame: screenFrame)
        makeKey()
    }

    private func attachActionToolbarIfNeeded() {
        guard actionToolbarWindow.parent !== self else { return }
        actionToolbarWindow.parent?.removeChildWindow(actionToolbarWindow)
        addChildWindow(actionToolbarWindow, ordered: .above)
    }

    private func dismissSelectionOverlay() {
        actionToolbarWindow.orderOut(nil)
        orderOut(nil)
    }

    private func positionActionToolbar(_ frame: NSRect, screenFrame: NSRect) {
        attachActionToolbarIfNeeded()
        actionToolbarWindow.show(at: NSRect(
            x: screenFrame.minX + frame.minX,
            y: screenFrame.minY + frame.minY,
            width: frame.width,
            height: frame.height
        ))
    }

    private static func crop(_ image: CGImage, selection: NSRect, screenSize: NSSize) -> CGImage? {
        guard selection.width >= 1, selection.height >= 1, screenSize.width > 0, screenSize.height > 0 else {
            return nil
        }

        let scaleX = CGFloat(image.width) / screenSize.width
        let scaleY = CGFloat(image.height) / screenSize.height
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let cropRect = CGRect(
            x: selection.minX * scaleX,
            y: (screenSize.height - selection.maxY) * scaleY,
            width: selection.width * scaleX,
            height: selection.height * scaleY
        ).integral.intersection(imageBounds)

        guard cropRect.width >= 1, cropRect.height >= 1 else {
            return nil
        }

        return image.cropping(to: cropRect)
    }
}

@MainActor
final class ScreenshotSelectionView: NSView {
    private enum Corner {
        case minXMinY
        case minXMaxY
        case maxXMinY
        case maxXMaxY
    }

    private enum Metrics {
        static let minSelectionSize: CGFloat = 18
        static let handleRadius: CGFloat = 10
        static let handleHitRadius: CGFloat = 28
        static let actionBarHeight: CGFloat = 38
        static let actionBarPadding: CGFloat = 6
        static let actionBarGap: CGFloat = 6
        static let actionBarCornerRadius: CGFloat = 10
        static let actionButtonHeight: CGFloat = 28
        static let actionButtonWidth: CGFloat = 58
        static let confirmGap: CGFloat = 12

        static var actionBarWidth: CGFloat {
            actionBarPadding * 2 + actionButtonWidth * 2 + actionBarGap
        }
    }

    private var previewImage: NSImage?
    private var selection = NSRect.zero
    private var draggedCorner: Corner?
    private var onConfirm: ((NSRect) -> Void)?
    private var onCancel: (() -> Void)?
    private var onActionBarFrameChanged: ((NSRect) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    func configure(
        image: CGImage,
        initialSelection: NSRect,
        onConfirm: @escaping (NSRect) -> Void,
        onCancel: @escaping () -> Void,
        onActionBarFrameChanged: @escaping (NSRect) -> Void
    ) {
        previewImage = NSImage(cgImage: image, size: bounds.size)
        selection = Self.normalized(initialSelection).intersection(bounds)
        if selection.width < Metrics.minSelectionSize || selection.height < Metrics.minSelectionSize {
            selection = bounds.insetBy(dx: bounds.width * 0.25, dy: bounds.height * 0.25)
        }
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onActionBarFrameChanged = onActionBarFrameChanged
        onActionBarFrameChanged(actionBarFrame)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let previewImage else { return }

        previewImage.draw(in: bounds)

        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).setClip()
        previewImage.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()

        drawSelectionBorder()
        drawHandles()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        draggedCorner = corner(at: point)

        // 点击选区外时不要让独立的确认工具栏被截图窗口压到后面。
        // 这里重新通知外层定位/置顶一次，保证工具栏仍停留在当前选区附近。
        onActionBarFrameChanged?(actionBarFrame)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let draggedCorner else { return }
        let previousDirtyRect = redrawRectForCurrentSelection()
        let point = clamped(convert(event.locationInWindow, from: nil))
        updateSelection(corner: draggedCorner, point: point)
        onActionBarFrameChanged?(actionBarFrame)
        setNeedsDisplay(previousDirtyRect.union(redrawRectForCurrentSelection()))
    }

    override func mouseUp(with event: NSEvent) {
        draggedCorner = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == kVK_Escape {
            cancel()
        } else if event.keyCode == kVK_Return {
            confirm()
        } else {
            super.keyDown(with: event)
        }
    }

    var actionBarFrame: NSRect {
        let preferredX = selection.maxX - Metrics.actionBarWidth
        let preferredY = selection.minY - Metrics.confirmGap - Metrics.actionBarHeight
        let x = min(max(preferredX, bounds.minX + 8), bounds.maxX - Metrics.actionBarWidth - 8)
        let y = preferredY >= bounds.minY + 8
            ? preferredY
            : min(selection.maxY + Metrics.confirmGap, bounds.maxY - Metrics.actionBarHeight - 8)
        return NSRect(
            origin: NSPoint(x: x, y: y),
            size: NSSize(width: Metrics.actionBarWidth, height: Metrics.actionBarHeight)
        )
    }

    private func drawSelectionBorder() {
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: selection)
        path.lineWidth = 2
        path.stroke()
    }

    private func drawHandles() {
        for point in handlePoints {
            let frame = handleFrame(centeredAt: point)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: frame).fill()

            NSColor.black.withAlphaComponent(0.45).setStroke()
            let ring = NSBezierPath(ovalIn: frame)
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    private var handlePoints: [NSPoint] {
        [
            NSPoint(x: selection.minX, y: selection.minY),
            NSPoint(x: selection.minX, y: selection.maxY),
            NSPoint(x: selection.maxX, y: selection.minY),
            NSPoint(x: selection.maxX, y: selection.maxY)
        ]
    }

    private func corner(at point: NSPoint) -> Corner? {
        let corners: [(Corner, NSPoint)] = [
            (.minXMinY, NSPoint(x: selection.minX, y: selection.minY)),
            (.minXMaxY, NSPoint(x: selection.minX, y: selection.maxY)),
            (.maxXMinY, NSPoint(x: selection.maxX, y: selection.minY)),
            (.maxXMaxY, NSPoint(x: selection.maxX, y: selection.maxY))
        ]

        return corners.first { _, cornerPoint in
            hypot(point.x - cornerPoint.x, point.y - cornerPoint.y) <= Metrics.handleHitRadius
        }?.0
    }

    private func handleFrame(centeredAt point: NSPoint) -> NSRect {
        NSRect(
            x: point.x - Metrics.handleRadius,
            y: point.y - Metrics.handleRadius,
            width: Metrics.handleRadius * 2,
            height: Metrics.handleRadius * 2
        )
    }

    private func redrawRectForCurrentSelection() -> NSRect {
        let handleBounds = handlePoints
            .map { handleFrame(centeredAt: $0).insetBy(dx: -2, dy: -2) }
            .reduce(selection.insetBy(dx: -3, dy: -3)) { $0.union($1) }
        return handleBounds.union(actionBarFrame.insetBy(dx: -3, dy: -3)).intersection(bounds)
    }

    private func updateSelection(corner: Corner, point: NSPoint) {
        var minX = selection.minX
        var maxX = selection.maxX
        var minY = selection.minY
        var maxY = selection.maxY

        switch corner {
        case .minXMinY:
            minX = min(point.x, maxX - Metrics.minSelectionSize)
            minY = min(point.y, maxY - Metrics.minSelectionSize)
        case .minXMaxY:
            minX = min(point.x, maxX - Metrics.minSelectionSize)
            maxY = max(point.y, minY + Metrics.minSelectionSize)
        case .maxXMinY:
            maxX = max(point.x, minX + Metrics.minSelectionSize)
            minY = min(point.y, maxY - Metrics.minSelectionSize)
        case .maxXMaxY:
            maxX = max(point.x, minX + Metrics.minSelectionSize)
            maxY = max(point.y, minY + Metrics.minSelectionSize)
        }

        selection = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds)
    }

    private func clamped(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private static func normalized(_ rect: NSRect) -> NSRect {
        NSRect(
            x: min(rect.minX, rect.maxX),
            y: min(rect.minY, rect.maxY),
            width: abs(rect.width),
            height: abs(rect.height)
        )
    }

    func confirm() {
        confirm(selection: selection)
    }

    private func confirm(selection selectedRect: NSRect) {
        clearImage()
        onConfirm?(selectedRect)
    }

    private func cancel() {
        clearImage()
        onCancel?()
    }

    private func clearImage() {
        previewImage = nil
        onActionBarFrameChanged = nil
    }
}

@MainActor
final class SelectionToolbarController {
    private enum Metrics {
        static let dragThresholdSquared: CGFloat = 36
        static let showDelay: TimeInterval = 0.08
        static let shortcutDelay: TimeInterval = 0.06
        static let searchReadDelay: TimeInterval = 0.22
    }

    private static let unsupportedSearchPasteboardTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("public.file-url"),
        NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        NSPasteboard.PasteboardType("public.tiff"),
        NSPasteboard.PasteboardType("public.png"),
        NSPasteboard.PasteboardType("com.adobe.pdf")
    ]

    private let toolbarWindow = SelectionToolbarWindow()
    private let toastWindow = ToastWindow()
    private lazy var screenshotSelectionWindow = ScreenshotSelectionWindow()
    private var eventMonitor: Any?
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
    }

    private func syncEventMonitor() {
        if isEnabled, eventMonitor == nil {
            eventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]
            ) { [weak self] event in
                DispatchQueue.main.async { self?.handle(event) }
            }
        } else if !isEnabled {
            removeEventMonitor(&eventMonitor)
        }
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
        restoreTarget(pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.shortcutDelay) { [weak self] in
            switch action {
            case .copy, .paste:
                guard let keyCode = action.shortcutKeyCode else { return }
                Self.postCommandShortcut(keyCode)
            case .search:
                self?.copySelectionAndSearch()
            case .screenshot:
                self?.captureSelection(rect)
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
        SCScreenshotManager.captureImage(in: rect) { [weak self] image, error in
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

    private func finishScreenshot(_ image: CGImage) {
        if currentSettings.screenshotCopiesToClipboard {
            Self.copyScreenshotToPasteboard(image)
        }

        let saveDirectory = currentSettings.screenshotSaveDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.saveScreenshot(image, toDirectoryAt: saveDirectory) }
            DispatchQueue.main.async { [weak self] in
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

    private func copySelectionAndSearch() {
        let pasteboard = NSPasteboard.general
        let beforeChangeCount = pasteboard.changeCount
        Self.postCommandShortcut(CGKeyCode(kVK_ANSI_C))

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

    private func restoreTarget(_ pid: pid_t?) {
        guard let pid, let app = NSRunningApplication(processIdentifier: pid), !app.isActive else {
            return
        }
        app.activate(options: [])
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

    private static func postCommandShortcut(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let commandKeyCode = CGKeyCode(kVK_Command)

        [
            (commandKeyCode, true, CGEventFlags.maskCommand),
            (keyCode, true, CGEventFlags.maskCommand),
            (keyCode, false, CGEventFlags.maskCommand),
            (commandKeyCode, false, CGEventFlags(rawValue: 0))
        ].forEach { step in
            postKey(step.0, isDown: step.1, flags: step.2, source: source)
        }
    }

    private static func postKey(
        _ keyCode: CGKeyCode,
        isDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource?
    ) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}

@MainActor
final class ControlWindow: NSWindow, NSWindowDelegate {
    private let controlView = ControlView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))

    var onCapsLockIndicatorChanged: ((Bool) -> Void)?
    var onClickToDisableChanged: ((Bool) -> Void)?
    var onSelectionToolbarChanged: ((Bool) -> Void)?
    var onSelectionToolbarActionChanged: ((ToolbarAction, Bool) -> Void)?
    var onSelectionToolbarActionMoved: ((ToolbarAction, Int) -> Void)?
    var onSearchTemplateChanged: ((String) -> Void)?
    var onScreenshotSaveDirectoryChanged: ((String) -> Void)?
    var onScreenshotCopiesToClipboardChanged: ((Bool) -> Void)?
    var onScreenshotSelectsRegionChanged: ((Bool) -> Void)?
    var onLoginItemChanged: ((Bool) -> Void)?
    var onLoginItemGuide: (() -> Void)?
    var onAccessibilityEnableRequested: (() -> Void)?
    var onAccessibilityDisableRequested: (() -> Void)?
    var onAccessibilityGuide: (() -> Void)?
    var onRefreshRequested: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var onHidden: (() -> Void)?
    var onClearDataAndQuit: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        title = "Xiaoyu MacHelper"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        delegate = self
        center()

        controlView.autoresizingMask = [.width, .height]
        bindCallbacks()
        contentView = controlView
    }

    private func bindCallbacks() {
        controlView.onCapsLockIndicatorChanged = { [weak self] isEnabled in self?.onCapsLockIndicatorChanged?(isEnabled) }
        controlView.onClickToDisableChanged = { [weak self] isEnabled in self?.onClickToDisableChanged?(isEnabled) }
        controlView.onSelectionToolbarChanged = { [weak self] isEnabled in self?.onSelectionToolbarChanged?(isEnabled) }
        controlView.onSelectionToolbarActionChanged = { [weak self] action, isEnabled in self?.onSelectionToolbarActionChanged?(action, isEnabled) }
        controlView.onSelectionToolbarActionMoved = { [weak self] action, direction in self?.onSelectionToolbarActionMoved?(action, direction) }
        controlView.onSearchTemplateChanged = { [weak self] template in self?.onSearchTemplateChanged?(template) }
        controlView.onScreenshotSaveDirectoryChanged = { [weak self] path in self?.onScreenshotSaveDirectoryChanged?(path) }
        controlView.onScreenshotCopiesToClipboardChanged = { [weak self] isEnabled in self?.onScreenshotCopiesToClipboardChanged?(isEnabled) }
        controlView.onScreenshotSelectsRegionChanged = { [weak self] isEnabled in self?.onScreenshotSelectsRegionChanged?(isEnabled) }
        controlView.onLoginItemChanged = { [weak self] isEnabled in self?.onLoginItemChanged?(isEnabled) }
        controlView.onLoginItemGuide = { [weak self] in self?.onLoginItemGuide?() }
        controlView.onAccessibilityEnableRequested = { [weak self] in self?.onAccessibilityEnableRequested?() }
        controlView.onAccessibilityDisableRequested = { [weak self] in self?.onAccessibilityDisableRequested?() }
        controlView.onAccessibilityGuide = { [weak self] in self?.onAccessibilityGuide?() }
        controlView.onClearDataAndQuit = { [weak self] in self?.onClearDataAndQuit?() }
        controlView.onQuit = { [weak self] in self?.onQuit?() }
    }

    func show() {
        center()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func render(settings: AppSettings, isLoginItemEnabled: Bool, isAccessibilityEnabled: Bool) {
        controlView.render(
            settings: settings,
            isLoginItemEnabled: isLoginItemEnabled,
            isAccessibilityEnabled: isAccessibilityEnabled
        )
    }

    func windowDidBecomeKey(_ notification: Notification) {
        controlView.refreshGlassSurfaces()
        onRefreshRequested?()
        onFocusChanged?(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        onFocusChanged?(false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        orderOut(nil)
        onHidden?()
        return false
    }
}

@MainActor
final class IconButtonView: NSButton {
    enum BackgroundStyle {
        case glass
        case plain
    }

    var onClick: (() -> Void)?

    init(
        systemSymbolName: String,
        accessibilityDescription: String,
        backgroundStyle: BackgroundStyle,
        tintColor: NSColor = .labelColor
    ) {
        super.init(frame: .zero)

        let symbol = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: accessibilityDescription) ?? NSImage()
        symbol.isTemplate = true
        image = symbol
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        contentTintColor = tintColor
        setButtonType(.momentaryChange)
        target = self
        action = #selector(clicked)

        switch backgroundStyle {
        case .glass:
            isBordered = true
            bezelStyle = .glass
        case .plain:
            isBordered = false
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func clicked() {
        onClick?()
    }
}

final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredTextRect(forBounds: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        centeredTextRect(forBounds: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: centeredTextRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: centeredTextRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }

    private func centeredTextRect(forBounds rect: NSRect) -> NSRect {
        let baseRect = super.drawingRect(forBounds: rect)
        let font = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        var textRect = baseRect
        textRect.origin.y = rect.midY - lineHeight / 2
        textRect.size.height = min(lineHeight, rect.height)
        return textRect
    }
}

@MainActor
final class ControlView: NSView, NSTextFieldDelegate {
    private enum Page {
        case modules
        case capsLockSettings
        case selectionToolbarSettings
        case searchSettings
        case screenshotSettings
    }

    private enum Metrics {
        static let outerPadding: CGFloat = 24
        static let titleTopInset: CGFloat = 34
        static let sectionGap: CGFloat = 18
        static let rowHeight: CGFloat = 44
        static let sectionInset: CGFloat = 16
        static let footerHeight: CGFloat = 32
        static let cornerRadius: CGFloat = 20
    }

    private var page: Page = .modules
    private var selectionToolbarOrder = ToolbarAction.configurableCases
    private var isAccessibilityEnabledForDisplay = false
    private var isSearchTemplateCustom = false

    private let glassContainer = NSGlassEffectContainerView()
    private let glassContentView = NSView()
    private let titleLabel = NSTextField(labelWithString: "Xiaoyu MacHelper")
    private let toolOptionsTitle = NSTextField(labelWithString: "工具选项")
    private let moduleTitle = NSTextField(labelWithString: "功能模块")
    private let settingsTitle = NSTextField(labelWithString: "")
    private let toolOptionsCard = NSGlassEffectView()
    private let moduleCard = NSGlassEffectView()
    private let settingsCard = NSGlassEffectView()
    private let loginItemCheckbox = NSButton(checkboxWithTitle: "开启自启动", target: nil, action: nil)
    private let accessibilityCheckbox = NSButton(checkboxWithTitle: "开启辅助功能", target: nil, action: nil)
    private let capsLockCheckbox = NSButton(checkboxWithTitle: "大写指示器", target: nil, action: nil)
    private let selectionToolbarCheckbox = NSButton(checkboxWithTitle: "选区工具栏", target: nil, action: nil)
    private let clickToDisableCheckbox = NSButton(checkboxWithTitle: "点击指示器取消大写", target: nil, action: nil)
    private let capsLockSettingsButton = IconButtonView(systemSymbolName: "gearshape", accessibilityDescription: "设置", backgroundStyle: .plain, tintColor: .secondaryLabelColor)
    private let selectionToolbarSettingsButton = IconButtonView(systemSymbolName: "gearshape", accessibilityDescription: "设置", backgroundStyle: .plain, tintColor: .secondaryLabelColor)
    private let backButton = IconButtonView(systemSymbolName: "chevron.left", accessibilityDescription: "返回", backgroundStyle: .glass)
    private let loginItemButton = NSButton(title: "前往设置启动项", target: nil, action: nil)
    private let accessibilityButton = NSButton(title: "前往设置辅助功能", target: nil, action: nil)
    private let clearDataAndQuitButton = NSButton(title: "清空应用数据并退出", target: nil, action: nil)
    private let quitButton = NSButton(title: "退出", target: nil, action: nil)
    private let copyRow = ActionSettingRow(action: .copy)
    private let pasteRow = ActionSettingRow(action: .paste)
    private let searchRow = ActionSettingRow(action: .search, showsSettingsButton: true)
    private let screenshotRow = ActionSettingRow(action: .screenshot, showsSettingsButton: true)
    private let searchEnginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchTemplateField = NSTextField(string: "")
    private let screenshotSaveLabel = NSTextField(labelWithString: "截图后保存到：")
    private let screenshotSaveButton = NSButton(title: "", target: nil, action: nil)
    private let screenshotCopyCheckbox = NSButton(checkboxWithTitle: "截图后复制到剪贴板", target: nil, action: nil)
    private let screenshotRegionCheckbox = NSButton(checkboxWithTitle: "截图时框选区域", target: nil, action: nil)

    var onCapsLockIndicatorChanged: ((Bool) -> Void)?
    var onClickToDisableChanged: ((Bool) -> Void)?
    var onSelectionToolbarChanged: ((Bool) -> Void)?
    var onSelectionToolbarActionChanged: ((ToolbarAction, Bool) -> Void)?
    var onSelectionToolbarActionMoved: ((ToolbarAction, Int) -> Void)?
    var onSearchTemplateChanged: ((String) -> Void)?
    var onScreenshotSaveDirectoryChanged: ((String) -> Void)?
    var onScreenshotCopiesToClipboardChanged: ((Bool) -> Void)?
    var onScreenshotSelectsRegionChanged: ((Bool) -> Void)?
    var onLoginItemChanged: ((Bool) -> Void)?
    var onLoginItemGuide: (() -> Void)?
    var onAccessibilityEnableRequested: (() -> Void)?
    var onAccessibilityDisableRequested: (() -> Void)?
    var onAccessibilityGuide: (() -> Void)?
    var onClearDataAndQuit: (() -> Void)?
    var onQuit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func render(settings: AppSettings, isLoginItemEnabled: Bool, isAccessibilityEnabled: Bool) {
        selectionToolbarOrder = settings.selectionToolbarOrder
        isAccessibilityEnabledForDisplay = isAccessibilityEnabled
        loginItemCheckbox.state = isLoginItemEnabled ? .on : .off
        accessibilityCheckbox.state = isAccessibilityEnabled ? .on : .off
        capsLockCheckbox.state = settings.isCapsLockIndicatorEnabled ? .on : .off
        selectionToolbarCheckbox.state = settings.isSelectionToolbarEnabled ? .on : .off
        clickToDisableCheckbox.state = settings.isClickToDisableEnabled ? .on : .off
        copyRow.setEnabled(settings.isSelectionToolbarCopyEnabled)
        pasteRow.setEnabled(settings.isSelectionToolbarPasteEnabled)
        searchRow.setEnabled(settings.isSelectionToolbarSearchEnabled)
        screenshotRow.setEnabled(settings.isSelectionToolbarScreenshotEnabled)
        renderSearchSettings(settings)
        renderScreenshotSettings(settings)
        layoutForCurrentPage()
    }

    override func layout() {
        super.layout()
        layoutForCurrentPage()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        glassContainer.spacing = 12
        glassContainer.contentView = glassContentView
        addSubview(glassContainer)

        [toolOptionsCard, moduleCard, settingsCard].forEach {
            $0.style = .regular
            $0.cornerRadius = Metrics.cornerRadius
            $0.wantsLayer = true
            $0.layer?.cornerRadius = Metrics.cornerRadius
            $0.layer?.masksToBounds = true
            glassContentView.addSubview($0)
        }

        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .labelColor
        addSubview(titleLabel)

        [toolOptionsTitle, moduleTitle].forEach {
            $0.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            $0.textColor = .secondaryLabelColor
            addSubview($0)
        }

        settingsTitle.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        settingsTitle.textColor = .labelColor
        addSubview(settingsTitle)

        configureCheckbox(loginItemCheckbox, size: 14, weight: .medium, action: #selector(loginItemCheckboxChanged))
        configureCheckbox(accessibilityCheckbox, size: 14, weight: .medium, action: #selector(accessibilityCheckboxChanged))
        accessibilityCheckbox.allowsMixedState = false
        configureCheckbox(capsLockCheckbox, size: 14, weight: .medium, action: #selector(capsLockCheckboxChanged))
        configureCheckbox(selectionToolbarCheckbox, size: 14, weight: .medium, action: #selector(selectionToolbarCheckboxChanged))
        configureCheckbox(clickToDisableCheckbox, size: 14, weight: .regular, action: #selector(clickToDisableCheckboxChanged))

        [capsLockSettingsButton, selectionToolbarSettingsButton, backButton].forEach { addSubview($0) }
        capsLockSettingsButton.onClick = { [weak self] in self?.showCapsLockSettingsPage() }
        selectionToolbarSettingsButton.onClick = { [weak self] in self?.showSelectionToolbarSettingsPage() }
        backButton.onClick = { [weak self] in self?.backButtonClicked() }

        [loginItemButton, accessibilityButton, clearDataAndQuitButton, quitButton].forEach {
            $0.bezelStyle = .glass
            $0.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            addSubview($0)
        }
        loginItemButton.target = self
        loginItemButton.action = #selector(loginItemClicked)
        accessibilityButton.target = self
        accessibilityButton.action = #selector(accessibilityClicked)
        clearDataAndQuitButton.target = self
        clearDataAndQuitButton.action = #selector(clearDataAndQuitClicked)
        quitButton.target = self
        quitButton.action = #selector(quitClicked)

        [copyRow, pasteRow, searchRow, screenshotRow].forEach { row in
            row.onToggle = { [weak self] action, isEnabled in self?.onSelectionToolbarActionChanged?(action, isEnabled) }
            row.onMove = { [weak self] action, direction in self?.onSelectionToolbarActionMoved?(action, direction) }
            addSubview(row)
        }
        searchRow.onSettings = { [weak self] _ in self?.showSearchSettingsPage() }
        screenshotRow.onSettings = { [weak self] _ in self?.showScreenshotSettingsPage() }

        searchEnginePopup.addItems(withTitles: SearchEnginePreset.all.map(\.title) + [SearchEnginePreset.customTitle])
        searchEnginePopup.bezelStyle = .glass
        searchEnginePopup.target = self
        searchEnginePopup.action = #selector(searchEngineSelected)
        addSubview(searchEnginePopup)

        searchTemplateField.cell = VerticallyCenteredTextFieldCell(textCell: "")
        searchTemplateField.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        searchTemplateField.placeholderString = "请以 %s 代表搜索词"
        searchTemplateField.cell?.usesSingleLineMode = true
        searchTemplateField.cell?.lineBreakMode = .byTruncatingTail
        searchTemplateField.isEditable = true
        searchTemplateField.isSelectable = true
        searchTemplateField.isBezeled = true
        searchTemplateField.bezelStyle = .roundedBezel
        searchTemplateField.drawsBackground = true
        searchTemplateField.backgroundColor = .controlBackgroundColor
        searchTemplateField.delegate = self
        searchTemplateField.target = self
        searchTemplateField.action = #selector(searchTemplateCommitted)
        addSubview(searchTemplateField)

        screenshotSaveLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        screenshotSaveLabel.textColor = .labelColor
        addSubview(screenshotSaveLabel)

        screenshotSaveButton.bezelStyle = .glass
        screenshotSaveButton.alignment = .left
        screenshotSaveButton.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        screenshotSaveButton.target = self
        screenshotSaveButton.action = #selector(screenshotSaveDirectoryClicked)
        addSubview(screenshotSaveButton)

        configureCheckbox(screenshotCopyCheckbox, size: 13, weight: .regular, action: #selector(screenshotCopyCheckboxChanged))
        configureCheckbox(screenshotRegionCheckbox, size: 13, weight: .regular, action: #selector(screenshotRegionCheckboxChanged))

        showModulesPage()
    }

    private func configureCheckbox(_ checkbox: NSButton, size: CGFloat, weight: NSFont.Weight, action: Selector) {
        checkbox.font = NSFont.systemFont(ofSize: size, weight: weight)
        checkbox.target = self
        checkbox.action = action
        addSubview(checkbox)
    }

    func refreshGlassSurfaces() {
        [toolOptionsCard, moduleCard, settingsCard].forEach {
            $0.layer?.cornerRadius = Metrics.cornerRadius
            $0.layer?.masksToBounds = true
            $0.needsDisplay = true
        }
        glassContainer.needsDisplay = true
        glassContentView.needsDisplay = true
    }

    @objc private func capsLockCheckboxChanged() {
        onCapsLockIndicatorChanged?(capsLockCheckbox.state == .on)
    }

    @objc private func clickToDisableCheckboxChanged() {
        onClickToDisableChanged?(clickToDisableCheckbox.state == .on)
    }

    @objc private func selectionToolbarCheckboxChanged() {
        onSelectionToolbarChanged?(selectionToolbarCheckbox.state == .on)
    }

    @objc private func loginItemCheckboxChanged() {
        onLoginItemChanged?(loginItemCheckbox.state == .on)
    }

    @objc private func accessibilityCheckboxChanged() {
        let wantsEnable = accessibilityCheckbox.state == .on
        accessibilityCheckbox.state = isAccessibilityEnabledForDisplay ? .on : .off
        if wantsEnable { onAccessibilityEnableRequested?() } else { onAccessibilityDisableRequested?() }
    }

    @objc private func loginItemClicked() {
        onLoginItemGuide?()
    }

    @objc private func accessibilityClicked() {
        onAccessibilityGuide?()
    }

    @objc private func clearDataAndQuitClicked() {
        onClearDataAndQuit?()
    }

    @objc private func quitClicked() {
        onQuit?()
    }

    @objc private func backButtonClicked() {
        if page == .searchSettings || page == .screenshotSettings {
            showSelectionToolbarSettingsPage()
        } else {
            showModulesPage()
        }
    }

    @objc private func showModulesPage() {
        page = .modules
        layoutForCurrentPage()
    }

    @objc private func showCapsLockSettingsPage() {
        page = .capsLockSettings
        layoutForCurrentPage()
    }

    @objc private func showSelectionToolbarSettingsPage() {
        page = .selectionToolbarSettings
        layoutForCurrentPage()
    }

    private func showSearchSettingsPage() {
        page = .searchSettings
        layoutForCurrentPage()
    }

    private func showScreenshotSettingsPage() {
        page = .screenshotSettings
        layoutForCurrentPage()
    }

    @objc private func searchEngineSelected() {
        let index = searchEnginePopup.indexOfSelectedItem
        guard index != SearchEnginePreset.all.count else {
            isSearchTemplateCustom = true
            updateSearchTemplateFieldLock(isCustom: true)
            return
        }

        guard SearchEnginePreset.all.indices.contains(index) else { return }
        isSearchTemplateCustom = false
        searchTemplateField.stringValue = SearchEnginePreset.all[index].template
        updateSearchTemplateFieldLock(isCustom: false)
        commitSearchTemplate()
    }

    @objc private func searchTemplateCommitted() {
        commitSearchTemplate()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === searchTemplateField else { return }
        commitSearchTemplate()
    }

    private func commitSearchTemplate() {
        onSearchTemplateChanged?(searchTemplateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func screenshotSaveDirectoryClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: screenshotSaveButton.toolTip ?? screenshotSaveButton.title, isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        screenshotSaveButton.title = Self.displayName(forDirectoryAt: url.path)
        onScreenshotSaveDirectoryChanged?(url.path)
    }

    @objc private func screenshotCopyCheckboxChanged() {
        onScreenshotCopiesToClipboardChanged?(screenshotCopyCheckbox.state == .on)
    }

    @objc private func screenshotRegionCheckboxChanged() {
        onScreenshotSelectsRegionChanged?(screenshotRegionCheckbox.state == .on)
    }

    private func layoutForCurrentPage() {
        glassContainer.frame = bounds
        glassContentView.frame = bounds

        switch page {
        case .modules:
            layoutModulesPage()
        case .capsLockSettings:
            layoutSettingsBase(title: "大写指示器")
            clickToDisableCheckbox.isHidden = false
            clickToDisableCheckbox.sizeToFit()
            clickToDisableCheckbox.frame.origin = NSPoint(
                x: settingsCard.frame.minX + Metrics.sectionInset,
                y: settingsCard.frame.maxY - Metrics.sectionInset - clickToDisableCheckbox.frame.height
            )
        case .selectionToolbarSettings:
            layoutSettingsBase(title: "选区工具栏")
            let rows = selectionToolbarOrder.map { row(for: $0) }
            for (index, row) in rows.enumerated() {
                row.isHidden = false
                row.frame = NSRect(
                    x: settingsCard.frame.minX + Metrics.sectionInset,
                    y: settingsCard.frame.maxY - Metrics.sectionInset - Metrics.rowHeight - CGFloat(index) * Metrics.rowHeight,
                    width: settingsCard.frame.width - Metrics.sectionInset * 2,
                    height: Metrics.rowHeight
                )
            }
        case .searchSettings:
            layoutSearchSettingsPage()
        case .screenshotSettings:
            layoutScreenshotSettingsPage()
        }
    }

    private func layoutModulesPage() {
        let width = bounds.width
        let height = bounds.height
        let contentX = Metrics.outerPadding
        let contentWidth = width - Metrics.outerPadding * 2
        let footerY = Metrics.outerPadding
        let toolCardFrame = NSRect(x: contentX, y: height - 174, width: contentWidth, height: 86)
        let moduleCardFrame = NSRect(
            x: contentX,
            y: footerY + Metrics.footerHeight + Metrics.sectionGap,
            width: contentWidth,
            height: toolCardFrame.minY - footerY - Metrics.footerHeight - Metrics.sectionGap * 2 - 20
        )

        hideAllControls()
        show(
            titleLabel, toolOptionsTitle, toolOptionsCard, loginItemCheckbox, accessibilityCheckbox,
            moduleTitle, moduleCard, capsLockCheckbox, selectionToolbarCheckbox,
            capsLockSettingsButton, selectionToolbarSettingsButton, loginItemButton, accessibilityButton,
            clearDataAndQuitButton, quitButton
        )

        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(
            x: contentX,
            y: height - Metrics.titleTopInset - titleLabel.frame.height
        )

        toolOptionsTitle.sizeToFit()
        toolOptionsTitle.frame.origin = NSPoint(x: contentX + 2, y: toolCardFrame.maxY + 8)
        toolOptionsCard.frame = toolCardFrame

        loginItemCheckbox.sizeToFit()
        loginItemCheckbox.frame.origin = NSPoint(
            x: toolCardFrame.minX + Metrics.sectionInset,
            y: toolCardFrame.maxY - Metrics.sectionInset - loginItemCheckbox.frame.height
        )

        accessibilityCheckbox.sizeToFit()
        accessibilityCheckbox.frame.origin = NSPoint(
            x: toolCardFrame.minX + Metrics.sectionInset,
            y: toolCardFrame.minY + Metrics.sectionInset
        )

        moduleTitle.sizeToFit()
        moduleTitle.frame.origin = NSPoint(x: contentX + 2, y: moduleCardFrame.maxY + 8)
        moduleCard.frame = moduleCardFrame

        let capsRowY = moduleCardFrame.maxY - Metrics.sectionInset - Metrics.rowHeight
        layoutModuleRow(
            checkbox: capsLockCheckbox,
            settingsButton: capsLockSettingsButton,
            rowY: capsRowY,
            cardFrame: moduleCardFrame
        )

        layoutModuleRow(
            checkbox: selectionToolbarCheckbox,
            settingsButton: selectionToolbarSettingsButton,
            rowY: capsRowY - Metrics.rowHeight,
            cardFrame: moduleCardFrame
        )

        let gap: CGFloat = 10
        quitButton.frame = NSRect(x: width - Metrics.outerPadding - 54, y: footerY, width: 54, height: Metrics.footerHeight)
        clearDataAndQuitButton.frame = NSRect(x: quitButton.frame.minX - gap - 134, y: footerY, width: 134, height: Metrics.footerHeight)
        accessibilityButton.frame = NSRect(x: clearDataAndQuitButton.frame.minX - gap - 132, y: footerY, width: 132, height: Metrics.footerHeight)
        loginItemButton.frame = NSRect(x: accessibilityButton.frame.minX - gap - 122, y: footerY, width: 122, height: Metrics.footerHeight)
    }

    private func layoutModuleRow(checkbox: NSButton, settingsButton: IconButtonView, rowY: CGFloat, cardFrame: NSRect) {
        let rowMidY = rowY + Metrics.rowHeight / 2

        checkbox.sizeToFit()
        checkbox.frame.origin = NSPoint(
            x: cardFrame.minX + Metrics.sectionInset,
            y: rowMidY - checkbox.frame.height / 2
        )

        let settingsHitSize: CGFloat = 30
        settingsButton.frame = NSRect(
            x: checkbox.frame.maxX + 6,
            y: rowMidY - settingsHitSize / 2,
            width: settingsHitSize,
            height: settingsHitSize
        )
    }

    private func row(for action: ToolbarAction) -> ActionSettingRow {
        switch action {
        case .copy: return copyRow
        case .paste: return pasteRow
        case .search: return searchRow
        case .screenshot: return screenshotRow
        }
    }

    private func layoutSearchSettingsPage() {
        layoutSettingsBase(title: "搜索")
        show(searchEnginePopup, searchTemplateField)

        let contentX = settingsCard.frame.minX + Metrics.sectionInset
        let contentWidth = settingsCard.frame.width - Metrics.sectionInset * 2
        searchEnginePopup.frame = NSRect(
            x: contentX,
            y: settingsCard.frame.maxY - Metrics.sectionInset - 34,
            width: 150,
            height: 32
        )
        searchTemplateField.frame = NSRect(
            x: contentX,
            y: searchEnginePopup.frame.minY - 52,
            width: contentWidth,
            height: 34
        )
    }

    private func layoutScreenshotSettingsPage() {
        layoutSettingsBase(title: "截图")
        show(screenshotSaveLabel, screenshotSaveButton, screenshotCopyCheckbox, screenshotRegionCheckbox)

        let contentX = settingsCard.frame.minX + Metrics.sectionInset
        let contentWidth = settingsCard.frame.width - Metrics.sectionInset * 2
        screenshotSaveLabel.sizeToFit()
        screenshotSaveLabel.frame.origin = NSPoint(
            x: contentX,
            y: settingsCard.frame.maxY - Metrics.sectionInset - screenshotSaveLabel.frame.height
        )
        screenshotSaveButton.frame = NSRect(
            x: contentX,
            y: screenshotSaveLabel.frame.minY - 42,
            width: contentWidth,
            height: 32
        )

        layoutCheckbox(screenshotCopyCheckbox, below: screenshotSaveButton.frame, gap: 42, contentX: contentX)
        layoutCheckbox(screenshotRegionCheckbox, below: screenshotCopyCheckbox.frame, gap: 34, contentX: contentX)
    }

    private func layoutCheckbox(_ checkbox: NSButton, below frame: NSRect, gap: CGFloat, contentX: CGFloat) {
        checkbox.sizeToFit()
        checkbox.frame.origin = NSPoint(x: contentX, y: frame.minY - gap)
    }

    private func layoutSettingsBase(title: String) {
        let width = bounds.width
        let height = bounds.height
        let contentX = Metrics.outerPadding
        let headerY = height - 86
        let cardFrame = NSRect(
            x: contentX,
            y: Metrics.outerPadding,
            width: width - Metrics.outerPadding * 2,
            height: headerY - Metrics.sectionGap - Metrics.outerPadding
        )

        hideAllControls()
        show(settingsTitle, settingsCard, backButton)

        backButton.frame = NSRect(x: contentX, y: headerY, width: 34, height: 34)
        settingsTitle.stringValue = title
        settingsTitle.sizeToFit()
        settingsTitle.frame.origin = NSPoint(x: backButton.frame.maxX + 14, y: backButton.frame.midY - settingsTitle.frame.height / 2)
        settingsCard.frame = cardFrame
    }

    private func hideAllControls() {
        allControls.forEach { $0.isHidden = true }
    }

    private func show(_ views: NSView...) {
        views.forEach { $0.isHidden = false }
    }

    private lazy var allControls: [NSView] = [
        titleLabel, toolOptionsTitle, moduleTitle, settingsTitle, toolOptionsCard, moduleCard, settingsCard,
        loginItemCheckbox, accessibilityCheckbox, capsLockCheckbox, selectionToolbarCheckbox, clickToDisableCheckbox,
        capsLockSettingsButton, selectionToolbarSettingsButton, backButton,
        loginItemButton, accessibilityButton, clearDataAndQuitButton, quitButton, copyRow, pasteRow, searchRow, screenshotRow,
        searchEnginePopup, searchTemplateField, screenshotSaveLabel, screenshotSaveButton, screenshotCopyCheckbox,
        screenshotRegionCheckbox
    ]

    private static func displayName(forDirectoryAt path: String) -> String {
        let directoryURL = path.isEmpty ? defaultScreenshotDirectoryURL() : URL(fileURLWithPath: path, isDirectory: true)
        return directoryURL.path
    }

    private func renderSearchSettings(_ settings: AppSettings) {
        let presetIndex = SearchEnginePreset.presetIndex(for: settings.searchURLTemplate)
        let shouldUseCustom = isSearchTemplateCustom || presetIndex == nil

        if searchTemplateField.currentEditor() == nil && searchTemplateField.stringValue != settings.searchURLTemplate {
            searchTemplateField.stringValue = settings.searchURLTemplate
        }

        isSearchTemplateCustom = shouldUseCustom
        searchEnginePopup.selectItem(at: shouldUseCustom ? SearchEnginePreset.all.count : (presetIndex ?? 0))
        updateSearchTemplateFieldLock(isCustom: isSearchTemplateCustom)
    }

    private func updateSearchTemplateFieldLock(isCustom: Bool) {
        searchTemplateField.isEditable = isCustom
        searchTemplateField.isSelectable = isCustom
        searchTemplateField.textColor = isCustom ? .labelColor : .secondaryLabelColor
        searchTemplateField.backgroundColor = isCustom
            ? .controlBackgroundColor
            : .unemphasizedSelectedContentBackgroundColor
    }

    private func renderScreenshotSettings(_ settings: AppSettings) {
        screenshotSaveButton.title = Self.displayName(forDirectoryAt: settings.screenshotSaveDirectory)
        screenshotSaveButton.toolTip = settings.screenshotSaveDirectory
        screenshotCopyCheckbox.state = settings.screenshotCopiesToClipboard ? .on : .off
        screenshotRegionCheckbox.state = settings.screenshotSelectsRegion ? .on : .off
    }
}

@MainActor
final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class ActionSettingRow: NSView {
    private enum Metrics {
        static let settingsHitSize: CGFloat = 30
        static let settingsGap: CGFloat = 6
        static let dragIconSize: CGFloat = 18
        static let dragRightInset: CGFloat = 24
        static let dragHitInsetX: CGFloat = 8
        static let dragHitInsetY: CGFloat = 13
        static let dragThreshold: CGFloat = 16
    }

    let action: ToolbarAction
    private let checkbox: NSButton
    private let settingsButton: IconButtonView?
    private let dragHandle = PassthroughImageView()
    private var dragStartWindowY: CGFloat?

    var onToggle: ((ToolbarAction, Bool) -> Void)?
    var onMove: ((ToolbarAction, Int) -> Void)?
    var onSettings: ((ToolbarAction) -> Void)?

    private var dragHitFrame: NSRect {
        dragHandle.frame.insetBy(dx: -Metrics.dragHitInsetX, dy: -Metrics.dragHitInsetY)
    }

    init(action: ToolbarAction, showsSettingsButton: Bool = false) {
        self.action = action
        self.checkbox = NSButton(checkboxWithTitle: action.title, target: nil, action: nil)
        self.settingsButton = showsSettingsButton
            ? IconButtonView(systemSymbolName: "gearshape", accessibilityDescription: "设置", backgroundStyle: .plain, tintColor: .secondaryLabelColor)
            : nil
        super.init(frame: .zero)

        checkbox.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        checkbox.target = self
        checkbox.action = #selector(toggled)
        addSubview(checkbox)

        if let settingsButton {
            settingsButton.onClick = { [weak self] in self?.settingsClicked() }
            addSubview(settingsButton)
        }

        let dragImage = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动") ?? NSImage()
        dragImage.isTemplate = true
        dragHandle.image = dragImage
        dragHandle.imageScaling = .scaleProportionallyDown
        dragHandle.contentTintColor = .secondaryLabelColor
        addSubview(dragHandle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setEnabled(_ isEnabled: Bool) {
        checkbox.state = isEnabled ? .on : .off
    }

    override func layout() {
        super.layout()
        checkbox.sizeToFit()
        checkbox.frame.origin = NSPoint(x: 0, y: bounds.midY - checkbox.frame.height / 2)

        if let settingsButton {
            settingsButton.frame = NSRect(
                x: checkbox.frame.maxX + Metrics.settingsGap,
                y: bounds.midY - Metrics.settingsHitSize / 2,
                width: Metrics.settingsHitSize,
                height: Metrics.settingsHitSize
            )
        }

        dragHandle.frame = NSRect(
            x: bounds.maxX - Metrics.dragRightInset,
            y: bounds.midY - Metrics.dragIconSize / 2,
            width: Metrics.dragIconSize,
            height: Metrics.dragIconSize
        )
    }

    override func resetCursorRects() {
        addCursorRect(dragHitFrame, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        guard dragHitFrame.contains(localPoint) else {
            super.mouseDown(with: event)
            return
        }

        dragStartWindowY = event.locationInWindow.y
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStartWindowY else { return }
        defer {
            self.dragStartWindowY = nil
            NSCursor.openHand.set()
        }

        let delta = event.locationInWindow.y - dragStartWindowY
        guard abs(delta) > Metrics.dragThreshold else { return }
        onMove?(action, delta > 0 ? -1 : 1)
    }

    @objc private func toggled() {
        onToggle?(action, checkbox.state == .on)
    }

    @objc private func settingsClicked() {
        onSettings?(action)
    }
}

@MainActor
final class CapsLockWindow: GlassTextWindow {
    private enum Metrics {
        static let bottomInset: CGFloat = 36
    }

    var onClick: (() -> Void)?

    init() {
        super.init(
            configuration: Configuration(
                height: 36,
                horizontalPadding: 22,
                minWidth: 92,
                maxWidth: nil,
                font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                cornerRadius: 18
            ),
            initialMessage: "大写"
        )

        content.onClick = { [weak self] in
            self?.onClick?()
        }
    }

    func showAtBottomCenter() {
        let size = fittingSize(for: "大写")
        setFrame(NSRect(origin: .zero, size: size), display: false)
        setFrameOrigin(bottomCenterOrigin(size: size, bottomInset: Metrics.bottomInset))
        orderFrontRegardless()
    }
}

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
        controlWindow.onSelectionToolbarActionChanged = { [weak self] action, isEnabled in self?.setSelectionToolbarAction(action, enabled: isEnabled) }
        controlWindow.onSelectionToolbarActionMoved = { [weak self] action, direction in self?.moveSelectionToolbarAction(action, direction: direction) }
        controlWindow.onSearchTemplateChanged = { [weak self] template in self?.setSearchURLTemplate(template) }
        controlWindow.onScreenshotSaveDirectoryChanged = { [weak self] path in self?.setScreenshotSaveDirectory(path) }
        controlWindow.onScreenshotCopiesToClipboardChanged = { [weak self] isEnabled in self?.setScreenshotCopiesToClipboard(isEnabled) }
        controlWindow.onScreenshotSelectsRegionChanged = { [weak self] isEnabled in self?.setScreenshotSelectsRegion(isEnabled) }
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

let launchMode = LaunchMode.current()
let instanceLock = SingleInstanceLock()
guard instanceLock.acquireOrNotifyRunningInstance(shouldNotifyRunningInstance: launchMode.notifiesRunningInstance) else {
    exit(0)
}

let app = NSApplication.shared
let delegate = XiaoyuMacHelperApp(instanceLock: instanceLock, launchMode: launchMode)
app.delegate = delegate
app.run()

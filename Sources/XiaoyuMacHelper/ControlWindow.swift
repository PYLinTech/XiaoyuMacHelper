import AppKit

@MainActor
final class ControlWindow: NSWindow, NSWindowDelegate {
    private let controlView = ControlView(frame: NSRect(x: 0, y: 0, width: 520, height: 450))

    var onCapsLockIndicatorChanged: ((Bool) -> Void)?
    var onClickToDisableChanged: ((Bool) -> Void)?
    var onSelectionToolbarChanged: ((Bool) -> Void)?
    var onActiveVisionChanged: ((Bool) -> Void)?
    var onSelectionToolbarActionChanged: ((ToolbarAction, Bool) -> Void)?
    var onSelectionToolbarActionMoved: ((ToolbarAction, Int) -> Void)?
    var onSearchTemplateChanged: ((String) -> Void)?
    var onScreenshotSaveDirectoryChanged: ((String) -> Void)?
    var onScreenshotCopiesToClipboardChanged: ((Bool) -> Void)?
    var onScreenshotSelectsRegionChanged: ((Bool) -> Void)?
    var onActiveVisionGazeChanged: ((Bool) -> Void)?
    var onActiveVisionFacingChanged: ((Bool) -> Void)?
    var onActiveVisionNotifyChanged: ((Bool) -> Void)?
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 450),
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
        controlView.onActiveVisionChanged = { [weak self] isEnabled in self?.onActiveVisionChanged?(isEnabled) }
        controlView.onSelectionToolbarActionChanged = { [weak self] action, isEnabled in self?.onSelectionToolbarActionChanged?(action, isEnabled) }
        controlView.onSelectionToolbarActionMoved = { [weak self] action, direction in self?.onSelectionToolbarActionMoved?(action, direction) }
        controlView.onSearchTemplateChanged = { [weak self] template in self?.onSearchTemplateChanged?(template) }
        controlView.onScreenshotSaveDirectoryChanged = { [weak self] path in self?.onScreenshotSaveDirectoryChanged?(path) }
        controlView.onScreenshotCopiesToClipboardChanged = { [weak self] isEnabled in self?.onScreenshotCopiesToClipboardChanged?(isEnabled) }
        controlView.onScreenshotSelectsRegionChanged = { [weak self] isEnabled in self?.onScreenshotSelectsRegionChanged?(isEnabled) }
        controlView.onActiveVisionGazeChanged = { [weak self] isEnabled in self?.onActiveVisionGazeChanged?(isEnabled) }
        controlView.onActiveVisionFacingChanged = { [weak self] isEnabled in self?.onActiveVisionFacingChanged?(isEnabled) }
        controlView.onActiveVisionNotifyChanged = { [weak self] isEnabled in self?.onActiveVisionNotifyChanged?(isEnabled) }
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


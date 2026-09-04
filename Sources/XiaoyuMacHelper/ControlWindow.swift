import AppKit

@MainActor
final class ControlWindow: NSWindow, NSWindowDelegate {
    private static let defaultContentSize = NSSize(width: 520, height: 700)

    /// 设置视图本体：App 层直接在其上绑定操作回调（设置项回调由 View 一层
    /// 直达 App，不再经窗口逐条转发——三层转发 250+ 行纯样板，漏绑即失效）。
    let controlView = ControlView(frame: NSRect(origin: .zero, size: ControlWindow.defaultContentSize))

    /// 窗口自有事件（window delegate 驱动，非设置项转发）。
    var onRefreshRequested: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var onHidden: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: ControlWindow.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        title = "Xiaoyu MacHelper"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 520, height: 560)
        delegate = self
        center()

        controlView.autoresizingMask = [.width, .height]
        contentView = controlView
    }

    func show() {
        center()
        makeKeyAndOrderFront(nil)
        NSApp.activate()
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
            bezelStyle = .liquidGlass
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

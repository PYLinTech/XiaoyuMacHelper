import AppKit

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
final class DesktopLyricsSourceRow: NSView {
    private enum Metrics {
        static let settingsHitSize: CGFloat = 30
        static let dragIconSize: CGFloat = 18
        static let dragRightInset: CGFloat = 24
        static let dragHitInsetX: CGFloat = 8
        static let dragHitInsetY: CGFloat = 13
        static let dragThreshold: CGFloat = 16
    }

    let source: DesktopLyricsSource
    private let checkbox: NSButton
    private let titleLabel = NSTextField(labelWithString: "")
    private let settingsButton: IconButtonView?
    private let dragHandle = PassthroughImageView()
    private var dragStartWindowY: CGFloat?

    var onMove: ((DesktopLyricsSource, Int) -> Void)?
    var onSettings: ((DesktopLyricsSource) -> Void)?
    var onToggle: ((DesktopLyricsSource, Bool) -> Void)?

    private var dragHitFrame: NSRect {
        dragHandle.frame.insetBy(dx: -Metrics.dragHitInsetX, dy: -Metrics.dragHitInsetY)
    }

    init(source: DesktopLyricsSource) {
        self.source = source
        self.checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        self.settingsButton = source == .appleMusic
            ? IconButtonView(systemSymbolName: "gearshape", accessibilityDescription: "设置", backgroundStyle: .plain, tintColor: .secondaryLabelColor)
            : nil
        super.init(frame: .zero)

        checkbox.target = self
        checkbox.action = #selector(toggled)
        addSubview(checkbox)
        titleLabel.stringValue = source.title
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        titleLabel.textColor = .labelColor
        addSubview(titleLabel)
        if let settingsButton {
            settingsButton.onClick = { [weak self] in
                guard let self else { return }
                self.onSettings?(self.source)
            }
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
        checkbox.frame = NSRect(x: 0, y: bounds.midY - 11, width: 22, height: 22)
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: checkbox.frame.maxX + 8, y: bounds.midY - titleLabel.frame.height / 2)
        if let settingsButton {
            settingsButton.frame = NSRect(
                x: titleLabel.frame.maxX + 8,
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
        onMove?(source, delta > 0 ? -1 : 1)
    }

    @objc private func toggled() {
        onToggle?(source, checkbox.state == .on)
    }
}

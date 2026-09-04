import AppKit

/// hover 状态按钮基类：统一 tracking area 注册与 hover 状态切换，
/// 子类只需覆写 `hoverStateChanged()` 响应进入/离开（读取 isHovering 区分）。
@MainActor
class HoverTrackingButton: NSButton {
    private var trackingAreaRef: NSTrackingArea?
    private(set) var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// hover 状态变化钩子（进入/离开均触发）。
    func hoverStateChanged() {}

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
        hoverStateChanged()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        hoverStateChanged()
    }
}

/// 玻璃质感 hover 按钮基类：统一 tracking area、hover 背景与深浅色联动，
/// 子类只需提供 hover 背景色、点击行为与外观刷新。
@MainActor
class LiquidGlassHoverButton: HoverTrackingButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 子类 init 中调用：统一按钮基础配置。
    func configureGlassButton() {
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        setButtonType(.momentaryChange)
        target = self
        action = #selector(glassButtonClicked)
    }

    /// hover 背景色（nil 表示无背景）。
    func hoverBackgroundColor() -> CGColor? { nil }

    /// 点击行为。
    func performClickAction() {}

    /// 深浅色变化时的联动刷新钩子。
    func appearanceDidChange() {}

    func refreshHoverBackground() {
        guard let layer else { return }
        layer.backgroundColor = isHovering ? hoverBackgroundColor() : nil
    }

    override func hoverStateChanged() {
        refreshHoverBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceDidChange()
    }

    @objc private func glassButtonClicked() {
        performClickAction()
    }
}

@MainActor
final class ToolbarButton: LiquidGlassHoverButton {
    let actionType: ToolbarAction
    var onAction: ((ToolbarAction) -> Void)?

    init(action: ToolbarAction) {
        self.actionType = action
        super.init(frame: .zero)

        configureGlassButton()
        refreshAppearanceColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func performClickAction() {
        onAction?(actionType)
    }

    override func hoverBackgroundColor() -> CGColor? {
        LiquidGlassOverlayStyle.hoverBackgroundColor()
    }

    override func appearanceDidChange() {
        // 标题颜色随深浅色联动（refreshAppearanceColors 内含 hover 背景刷新）。
        refreshAppearanceColors()
    }

    func refreshAppearanceColors() {
        let title = Self.title(actionType.title)
        attributedTitle = title
        attributedAlternateTitle = title
        refreshHoverBackground()
    }

    private static func title(_ text: String) -> NSAttributedString {
        LiquidGlassOverlayStyle.attributedText(
            text,
            font: NSFont.systemFont(ofSize: 13, weight: .medium)
        )
    }
}

@MainActor
final class ScreenshotToolbarButton: LiquidGlassHoverButton {
    var onClick: (() -> Void)?
    private var lastTitle = ""
    var titleColor: NSColor = LiquidGlassOverlayStyle.primaryTextColor() {
        didSet { setTitle(title) }
    }

    init(title: String) {
        super.init(frame: .zero)

        configureGlassButton()
        setTitle(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func performClickAction() {
        onClick?()
    }

    override func hoverBackgroundColor() -> CGColor? {
        // 与 AnnotationToolbarButton 统一：白色 0.24 hover（毛玻璃上的"钮感"反馈）。
        NSColor.white.withAlphaComponent(0.24).cgColor
    }

    override func appearanceDidChange() {
        // 标题颜色随深浅色联动（含 hover 背景刷新）。
        setTitle(lastTitle)
    }

    func setTitle(_ title: String) {
        lastTitle = title
        let attributed = LiquidGlassOverlayStyle.attributedText(
            title,
            font: NSFont.systemFont(ofSize: 13, weight: .medium),
            color: titleColor
        )
        attributedTitle = attributed
        attributedAlternateTitle = attributed
    }
}

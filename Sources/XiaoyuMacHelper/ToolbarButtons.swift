import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Darwin
import IOKit
import IOKit.hidsystem
import ScreenCaptureKit
import ServiceManagement

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


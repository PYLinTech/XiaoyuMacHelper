import AppKit

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


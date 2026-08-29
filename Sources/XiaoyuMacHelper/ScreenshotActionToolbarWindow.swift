import AppKit

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

        let background = LiquidGlassEffectView(frame: contentView?.bounds ?? .zero)
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


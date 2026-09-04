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
            horizontalPadding * 2 + buttonWidth * 4 + buttonGap * 3
        }
    }

    private let cancelButton = ScreenshotToolbarButton(title: "✕")
    private let fullScreenButton = ScreenshotToolbarButton(title: "全屏")
    private let annotateButton = ScreenshotToolbarButton(title: "批注")
    private let confirmButton = ScreenshotToolbarButton(title: "✓")
    private let buttonContainer = NSView()
    var onFullScreen: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    /// 工具栏窗口的实际宽度（供选区视图定位工具栏用）。
    nonisolated static var preferredWidth: CGFloat { Metrics.width }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configureFloatingOverlay()
        level = ScreenshotWindowLevel.screenshot

        let background = LiquidGlassEffectView(frame: contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        LiquidGlassOverlayStyle.configureGlass(background, cornerRadius: Metrics.cornerRadius)
        buttonContainer.frame = background.bounds
        buttonContainer.autoresizingMask = [.width, .height]
        background.contentView = buttonContainer
        contentView = background

        fullScreenButton.onClick = { [weak self] in self?.onFullScreen?() }
        annotateButton.onClick = { [weak self] in self?.onAnnotate?() }
        confirmButton.onClick = { [weak self] in self?.onConfirm?() }
        cancelButton.onClick = { [weak self] in self?.onCancel?() }
        cancelButton.titleColor = .systemRed
        confirmButton.titleColor = .systemGreen
        buttonContainer.addSubview(fullScreenButton)
        buttonContainer.addSubview(annotateButton)
        buttonContainer.addSubview(confirmButton)
        buttonContainer.addSubview(cancelButton)
        layoutButtons()
    }

    func show(at frame: NSRect) {
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    private func layoutButtons() {
        cancelButton.frame = NSRect(
            x: Metrics.horizontalPadding,
            y: (Metrics.height - Metrics.buttonHeight) / 2,
            width: Metrics.buttonWidth,
            height: Metrics.buttonHeight
        )
        fullScreenButton.frame = NSRect(
            x: cancelButton.frame.maxX + Metrics.buttonGap,
            y: cancelButton.frame.minY,
            width: Metrics.buttonWidth,
            height: Metrics.buttonHeight
        )
        annotateButton.frame = NSRect(
            x: fullScreenButton.frame.maxX + Metrics.buttonGap,
            y: fullScreenButton.frame.minY,
            width: Metrics.buttonWidth,
            height: Metrics.buttonHeight
        )
        confirmButton.frame = NSRect(
            x: annotateButton.frame.maxX + Metrics.buttonGap,
            y: fullScreenButton.frame.minY,
            width: Metrics.buttonWidth,
            height: Metrics.buttonHeight
        )
    }
}


import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Darwin
import IOKit
import IOKit.hidsystem
import ScreenCaptureKit
import ServiceManagement

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


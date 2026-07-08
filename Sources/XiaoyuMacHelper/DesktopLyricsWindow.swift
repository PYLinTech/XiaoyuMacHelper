import AppKit

@MainActor
final class DesktopLyricsWindow: FloatingOverlayPanel {
    private enum Metrics {
        static let defaultWidth: CGFloat = 980
        static let minWidth: CGFloat = 260
        static let maxWidth: CGFloat = 2200
        static let horizontalInset: CGFloat = 24
        static let verticalInset: CGFloat = 12
        static let bottomInset: CGFloat = 128
    }

    private let lyricsView = DesktopLyricsView()
    private var settings: AppSettings
    private var currentWidth: CGFloat
    private var dragStartLocation: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isDragging = false

    var onPositionChanged: ((NSPoint) -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        self.currentWidth = Self.clampedWidth(CGFloat(settings.desktopLyricsWidth))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: currentWidth, height: 88),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configureFloatingOverlay()
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior.insert(.canJoinAllSpaces)

        lyricsView.autoresizingMask = [.width, .height]
        contentView = lyricsView
        apply(settings: settings)
    }

    func apply(settings: AppSettings) {
        self.settings = settings
        lyricsView.fontSize = CGFloat(settings.desktopLyricsFontSize)
        lyricsView.fontName = settings.desktopLyricsFontName
        lyricsView.style = DesktopLyricsVisualStyle(settings: settings)
        lyricsView.alignment = settings.desktopLyricsAlignment.nsTextAlignment
        currentWidth = Self.clampedWidth(CGFloat(settings.desktopLyricsWidth))
        ignoresMouseEvents = settings.desktopLyricsLocked
        if !isDragging {
            updateFrameForCurrentContent(keepsStoredPosition: true)
        }
    }

    func show(message: String) {
        show(primary: message, translation: nil, showsTranslation: false)
    }

    func show(
        primary: String,
        translation: String?,
        showsTranslation: Bool,
        lineStartTime: TimeInterval? = nil,
        lineDuration: TimeInterval? = nil,
        lineElapsed: TimeInterval = 0,
        previousLineDuration: TimeInterval? = nil,
        nextLineDuration: TimeInterval? = nil,
        isPlaying: Bool = true
    ) {
        let cleanPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayPrimary = cleanPrimary.isEmpty ? "等待正在播放的歌曲..." : cleanPrimary
        let cleanTranslation = translation?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTranslation = showsTranslation ? cleanTranslation : nil
        let contentChanged = lyricsView.primaryText != displayPrimary || lyricsView.translationText != displayTranslation
        let widthChanged = abs(frame.width - currentWidth) > 0.5

        lyricsView.primaryText = displayPrimary
        lyricsView.translationText = displayTranslation
        lyricsView.syncLineTiming(
            identity: lineStartTime,
            duration: lineDuration,
            elapsed: lineElapsed,
            previousDuration: previousLineDuration,
            nextDuration: nextLineDuration,
            isPlaying: isPlaying
        )

        // The controller refreshes playback progress frequently. Avoid resizing/redrawing the
        // whole overlay window on every progress tick; otherwise the text animation stutters
        // even if the marquee itself is display-link driven.
        if !isDragging, contentChanged || widthChanged {
            updateFrameForCurrentContent(keepsStoredPosition: true)
        }
        if !isVisible {
            orderFrontRegardless()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !settings.desktopLyricsLocked else { return }
        dragStartLocation = NSEvent.mouseLocation
        dragStartOrigin = frame.origin
        isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !settings.desktopLyricsLocked,
              let dragStartLocation,
              let dragStartOrigin else {
            return
        }

        let currentLocation = NSEvent.mouseLocation
        let newOrigin = NSPoint(
            x: dragStartOrigin.x + currentLocation.x - dragStartLocation.x,
            y: dragStartOrigin.y + currentLocation.y - dragStartLocation.y
        )
        setFrameOrigin(clampedOrigin(newOrigin, size: frame.size))
    }

    override func mouseUp(with event: NSEvent) {
        guard !settings.desktopLyricsLocked else { return }
        dragStartLocation = nil
        dragStartOrigin = nil
        isDragging = false
        settings.desktopLyricsPositionX = Double(frame.origin.x)
        settings.desktopLyricsPositionY = Double(frame.origin.y)
        onPositionChanged?(frame.origin)
    }

    private func updateFrameForCurrentContent(keepsStoredPosition: Bool) {
        let size = fittingSize()
        let origin = keepsStoredPosition ? storedOrDefaultOrigin(size: size) : defaultOrigin(size: size)
        setFrame(NSRect(origin: clampedOrigin(origin, size: size), size: size), display: true)
    }

    private func fittingSize() -> NSSize {
        let textHeight = lyricsView.fittingHeight(width: currentWidth - Metrics.horizontalInset * 2)
        return NSSize(width: currentWidth, height: ceil(textHeight + Metrics.verticalInset * 2))
    }

    private static func clampedWidth(_ value: CGFloat) -> CGFloat {
        min(Metrics.maxWidth, max(Metrics.minWidth, value == 0 ? Metrics.defaultWidth : value))
    }

    private func storedOrDefaultOrigin(size: NSSize) -> NSPoint {
        guard settings.desktopLyricsPositionX >= 0, settings.desktopLyricsPositionY >= 0 else {
            return defaultOrigin(size: size)
        }

        return NSPoint(x: settings.desktopLyricsPositionX, y: settings.desktopLyricsPositionY)
    }

    private func defaultOrigin(size: NSSize) -> NSPoint {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.midX - size.width / 2, y: visible.minY + Metrics.bottomInset)
    }

    private func clampedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: min(max(origin.x, visible.minX), visible.maxX - size.width),
            y: min(max(origin.y, visible.minY), visible.maxY - size.height)
        )
    }
}

@MainActor
private final class DesktopLyricsView: NSView {
    private enum Metrics {
        static let horizontalInset: CGFloat = 30
        static let verticalInset: CGFloat = 14
        static let lineGap: CGFloat = 4
    }

    private let primaryLabel = DesktopLyricsLineView(frame: .zero)
    private let translationLabel = DesktopLyricsLineView(frame: .zero)

    var primaryText: String = "" {
        didSet {
            guard oldValue != primaryText else { return }
            primaryLabel.stringValue = primaryText
            needsLayout = true
            needsDisplay = true
        }
    }

    var translationText: String? {
        didSet {
            guard oldValue != translationText else { return }
            translationLabel.stringValue = translationText ?? ""
            needsLayout = true
            needsDisplay = true
        }
    }

    var fontSize: CGFloat = 28 {
        didSet {
            configureLabels()
            needsLayout = true
            needsDisplay = true
        }
    }

    var fontName: String = "" {
        didSet {
            configureLabels()
            needsLayout = true
            needsDisplay = true
        }
    }

    var style = DesktopLyricsVisualStyle(preset: .classic) {
        didSet {
            configureLabels()
            needsDisplay = true
        }
    }

    var alignment: NSTextAlignment = .center {
        didSet {
            guard oldValue != alignment else { return }
            primaryLabel.alignment = alignment
            translationLabel.alignment = alignment
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        primaryLabel.alignment = alignment
        primaryLabel.fallbackScrollSpeed = 46
        primaryLabel.fadeEdgeWidth = 30
        primaryLabel.contentInsetX = 38
        translationLabel.alignment = alignment
        translationLabel.fallbackScrollSpeed = 38
        translationLabel.fadeEdgeWidth = 26
        translationLabel.contentInsetX = 34
        addSubview(primaryLabel)
        addSubview(translationLabel)
        configureLabels()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill()
        drawBackgroundIfNeeded(in: bounds.insetBy(dx: Metrics.horizontalInset, dy: Metrics.verticalInset))
    }

    override func layout() {
        super.layout()
        let insetBounds = bounds.insetBy(dx: Metrics.horizontalInset, dy: Metrics.verticalInset)
        let primaryHeight = lineHeight(size: fontSize, weight: .semibold)
        let hasTranslation = !(translationText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let translationHeight = hasTranslation ? lineHeight(size: max(16, fontSize * 0.68), weight: .medium) : 0
        let totalHeight = primaryHeight + (hasTranslation ? Metrics.lineGap + translationHeight : 0)
        var y = floor(insetBounds.midY - totalHeight / 2)

        primaryLabel.frame = NSRect(x: insetBounds.minX, y: y, width: insetBounds.width, height: primaryHeight)
        y += primaryHeight + Metrics.lineGap
        translationLabel.isHidden = !hasTranslation
        translationLabel.frame = NSRect(x: insetBounds.minX, y: y, width: insetBounds.width, height: translationHeight)
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        let primaryHeight = lineHeight(size: fontSize, weight: .semibold)
        guard let translationText, !translationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return primaryHeight
        }
        return primaryHeight + Metrics.lineGap + lineHeight(size: max(16, fontSize * 0.68), weight: .medium)
    }

    func syncLineTiming(
        identity: TimeInterval?,
        duration: TimeInterval?,
        elapsed: TimeInterval,
        previousDuration: TimeInterval?,
        nextDuration: TimeInterval?,
        isPlaying: Bool = true
    ) {
        primaryLabel.syncLineTiming(
            identity: identity,
            duration: duration,
            elapsed: elapsed,
            previousDuration: previousDuration,
            nextDuration: nextDuration,
            isPlaying: isPlaying
        )
        translationLabel.syncLineTiming(
            identity: identity,
            duration: duration,
            elapsed: elapsed,
            previousDuration: previousDuration,
            nextDuration: nextDuration,
            isPlaying: isPlaying
        )
    }

    private func configureLabels() {
        let primaryFont = resolvedFont(size: fontSize, weight: .semibold)
        let secondaryFont = resolvedFont(size: max(16, fontSize * 0.68), weight: .medium)
        let shadow = resolvedShadow()

        primaryLabel.font = primaryFont
        primaryLabel.textColor = style.textColor.withAlphaComponent(1.0)
        primaryLabel.strokeColor = style.strokeColor.withAlphaComponent(1.0)
        primaryLabel.strokeWidth = style.strokeWidth
        primaryLabel.textShadow = shadow
        primaryLabel.stringValue = primaryText

        translationLabel.font = secondaryFont
        translationLabel.textColor = style.textColor.withAlphaComponent(0.82)
        translationLabel.strokeColor = style.strokeColor.withAlphaComponent(0.82)
        translationLabel.strokeWidth = style.strokeWidth
        translationLabel.textShadow = shadow
        translationLabel.stringValue = translationText ?? ""
    }

    private func resolvedShadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = style.shadowColor
        shadow.shadowBlurRadius = style.shadowBlurRadius
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }

    private func resolvedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let fallback = NSFont.systemFont(ofSize: size, weight: weight)
        guard !fontName.isEmpty else { return fallback }
        return NSFontManager.shared.font(
            withFamily: fontName,
            traits: [],
            weight: fontManagerWeight(for: weight),
            size: size
        ) ?? NSFont(name: fontName, size: size) ?? fallback
    }

    private func fontManagerWeight(for weight: NSFont.Weight) -> Int {
        switch weight {
        case ..<NSFont.Weight.medium:
            return 5
        case ..<NSFont.Weight.semibold:
            return 7
        default:
            return 9
        }
    }

    private func drawBackgroundIfNeeded(in textBounds: NSRect) {
        guard let backgroundColor = style.backgroundColor else { return }
        let rect = textBounds.insetBy(dx: -22, dy: -9)
        let radius = min(18, rect.height / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        backgroundColor.setFill()
        path.fill()

        let highlightRect = rect.insetBy(dx: 1.0, dy: 1.0)
        let highlight = NSBezierPath(roundedRect: highlightRect, xRadius: max(0, radius - 1), yRadius: max(0, radius - 1))
        NSColor.white.withAlphaComponent(0.08).setStroke()
        highlight.lineWidth = 0.7
        highlight.stroke()

        if let borderColor = style.borderColor {
            borderColor.setStroke()
            path.lineWidth = 0.9
            path.stroke()
        }
    }

    private func lineHeight(size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let font = resolvedFont(size: size, weight: weight)
        return ceil(font.ascender - font.descender + font.leading + 2)
    }
}

private struct DesktopLyricsVisualStyle {
    var textColor: NSColor
    var strokeColor: NSColor
    var strokeWidth: CGFloat
    var shadowColor: NSColor
    var shadowBlurRadius: CGFloat
    var backgroundColor: NSColor?
    var borderColor: NSColor?

    init(settings: AppSettings) {
        self.init(preset: settings.desktopLyricsStylePreset)

        if let customTextColor = NSColor(hexString: settings.desktopLyricsTextColor) {
            textColor = customTextColor
        }
        if let customStrokeColor = NSColor(hexString: settings.desktopLyricsStrokeColor) {
            strokeColor = customStrokeColor
        }
        if settings.desktopLyricsStrokeWidth >= 0 {
            strokeWidth = CGFloat(settings.desktopLyricsStrokeWidth)
        }
    }

    init(preset: DesktopLyricsStylePreset) {
        switch preset {
        case .classic:
            textColor = .white
            strokeColor = NSColor.black.withAlphaComponent(0.55)
            strokeWidth = 0.8
            shadowColor = NSColor.black.withAlphaComponent(0.72)
            shadowBlurRadius = 4
            backgroundColor = nil
            borderColor = nil
        case .softShadow:
            textColor = NSColor(calibratedWhite: 0.98, alpha: 1)
            strokeColor = NSColor.black.withAlphaComponent(0.36)
            strokeWidth = 0.35
            shadowColor = NSColor.black.withAlphaComponent(0.82)
            shadowBlurRadius = 8
            backgroundColor = nil
            borderColor = nil
        case .darkPanel:
            textColor = NSColor(calibratedWhite: 0.98, alpha: 1)
            strokeColor = NSColor.black.withAlphaComponent(0.24)
            strokeWidth = 0
            shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadowBlurRadius = 3
            backgroundColor = NSColor.black.withAlphaComponent(0.34)
            borderColor = NSColor.white.withAlphaComponent(0.16)
        case .lightPanel:
            textColor = NSColor(calibratedWhite: 0.1, alpha: 1)
            strokeColor = NSColor.white.withAlphaComponent(0.4)
            strokeWidth = 0
            shadowColor = NSColor.white.withAlphaComponent(0.35)
            shadowBlurRadius = 2
            backgroundColor = NSColor.white.withAlphaComponent(0.78)
            borderColor = NSColor.black.withAlphaComponent(0.1)
        case .neon:
            textColor = NSColor(calibratedRed: 0.78, green: 0.96, blue: 1.0, alpha: 1)
            strokeColor = NSColor.black.withAlphaComponent(0.5)
            strokeWidth = 0.6
            shadowColor = NSColor(calibratedRed: 0.2, green: 0.75, blue: 1.0, alpha: 0.55)
            shadowBlurRadius = 9
            backgroundColor = nil
            borderColor = nil
        }
    }
}

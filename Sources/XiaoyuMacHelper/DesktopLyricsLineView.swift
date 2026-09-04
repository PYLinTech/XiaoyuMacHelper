import AppKit
import QuartzCore

/// Desktop-lyrics-only renderer.
///
/// The scroll position is derived from the lyric timeline every frame. It does not accumulate
/// pixels and it does not restart when the controller refreshes the same lyric line. The planner
/// also looks at the previous/current/next lyric durations so dense lyric sections scroll with a
/// tighter rhythm while slow sections keep more reading space.
@MainActor
final class DesktopLyricsLineView: NSView, DisplayLinkResponding {
    /// 滚动时序与采样引擎（单实现，与菜单栏歌词视图共用；行为基准为灵动大陆调优版本）。
    private let engine = LyricsScrollEngine()

    var stringValue: String = "" {
        didSet {
            guard oldValue != stringValue else { return }
            // 先在引擎仍持有旧文本状态时捕获退场行，再切换引擎文本。
            captureOutgoingLineIfNeeded(oldValue: oldValue, newValue: stringValue)
            engine.text = stringValue
            engine.invalidateTextCaches()
            engine.resetLineState(keepsTiming: false)
            // 视图级富文本/尺寸缓存必须一并失效，否则 draw() 永远命中首句缓存。
            attributedCache = nil
            measuredTextSize = .zero
            measuredTypographicBounds = .zero
            updateAnimationState()
        }
    }

    var font: NSFont = NSFont.systemFont(ofSize: 28, weight: .semibold) {
        didSet {
            guard oldValue != font else { return }
            resetTextCaches()
        }
    }

    var textColor: NSColor = .labelColor {
        didSet {
            attributedCache = nil
            needsDisplay = true
        }
    }

    var strokeColor: NSColor = .clear {
        didSet {
            attributedCache = nil
            needsDisplay = true
        }
    }

    var strokeWidth: CGFloat = 0 {
        didSet {
            attributedCache = nil
            needsDisplay = true
        }
    }

    var textShadow: NSShadow? {
        didSet {
            attributedCache = nil
            needsDisplay = true
        }
    }

    var alignment: NSTextAlignment = .center {
        didSet {
            guard oldValue != alignment else { return }
            engine.alignment = alignment
            engine.invalidateScrollPlan()
            needsDisplay = true
        }
    }

    var fadeEdgeWidth: CGFloat = 22 {
        didSet { needsDisplay = true }
    }

    var contentInsetX: CGFloat = 0 {
        didSet {
            guard oldValue != contentInsetX else { return }
            engine.invalidateScrollPlan()
            updateAnimationState()
        }
    }

    /// Uses font ascender/descender metrics instead of attributed-string bounds when vertically
    /// positioning the rendered line. This keeps compact surfaces such as 灵动大陆 visually centered
    /// while their font size changes.
    var usesTypographicVerticalCentering: Bool = false {
        didSet {
            guard oldValue != usesTypographicVerticalCentering else { return }
            needsDisplay = true
        }
    }

    /// Untimed fallback speed. Timed lines use the adaptive cross-line planner instead.
    var fallbackScrollSpeed: CGFloat = 48 {
        didSet { engine.fallbackScrollSpeed = fallbackScrollSpeed }
    }

    private var attributedCache: NSAttributedString?
    private var measuredTextSize: NSSize = .zero
    private var measuredTypographicBounds: NSRect = .zero
    private var activeDisplayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget<DesktopLyricsLineView>?
    private var displayTimestamp: CFTimeInterval = CACurrentMediaTime()
    private var outgoingLine: OutgoingLine?
    private let lineCrossfadeDuration: CFTimeInterval = 0.24
    private var edgeFadeGradients: (left: CGGradient, right: CGGradient)?

    private struct OutgoingLine {
        var attributed: NSAttributedString
        var textSize: NSSize
        var typographicBounds: NSRect
        var textRect: NSRect
        var alignment: NSTextAlignment
        var usesTypographicVerticalCentering: Bool
        var offset: CGFloat
        var alpha: CGFloat
        var repeatCount: Int
        var repeatStride: CGFloat
        var startedAt: CFTimeInterval
        var duration: CFTimeInterval
    }

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        canDrawConcurrently = false
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        engine.onRequestRedraw = { [weak self] in self?.needsDisplay = true }
        engine.measureInlineWidth = { [weak self] text in
            guard let self else { return 0 }
            return self.makeAttributedString(for: text).size().width
        }
        engine.currentMaxOffset = { [weak self] in
            guard let self, !self.stringValue.isEmpty else { return 0 }
            let textSize = self.measuredSize(for: self.attributedString())
            return max(0, textSize.width - self.protectedTextRect().width)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopDisplayDriver()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayerScale()
        updateAnimationState()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayerScale()
        needsDisplay = true
    }

    override func removeFromSuperview() {
        stopDisplayDriver()
        super.removeFromSuperview()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if abs(oldSize.width - newSize.width) > 0.5 || abs(oldSize.height - newSize.height) > 0.5 {
            engine.invalidateScrollPlan()
            updateAnimationState()
        }
    }

    func syncLineTiming(
        identity: TimeInterval?,
        duration: TimeInterval?,
        elapsed: TimeInterval,
        previousDuration: TimeInterval?,
        nextDuration: TimeInterval?,
        wordTimings: [DesktopLyricWordTiming] = [],
        isPlaying: Bool = true
    ) {
        engine.syncLineTiming(
            identity: identity,
            duration: duration,
            elapsed: elapsed,
            previousDuration: previousDuration,
            nextDuration: nextDuration,
            wordTimings: wordTimings,
            isPlaying: isPlaying
        )
        updateAnimationState()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !stringValue.isEmpty, bounds.width > 2, bounds.height > 2 else { return }

        let now = renderTimestamp()
        let attributed = attributedString()
        let textSize = measuredSize(for: attributed)
        let textRect = protectedTextRect()
        let maxOffset = max(0, textSize.width - textRect.width)
        let shouldScroll = maxOffset > 8
        let sample = engine.renderSample(maxOffset: maxOffset, shouldScroll: shouldScroll, viewportWidth: textRect.width, now: now)
        let x = drawingOriginX(textWidth: textSize.width, shouldScroll: shouldScroll, offset: sample.offset, textRect: textRect)
        let y = drawingOriginY(for: attributed, measuredSize: textSize)
        let transition = activeOutgoingLine(at: now)
        // 同一 now/transition 的淡入进度只算一次：234 行取 incoming，241 行附近取 1 - progress 给 outgoing。
        let crossfade = transition.map { CGFloat(crossfadeProgress(now: now, transition: $0)) }
        let incomingAlpha = crossfade ?? 1

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()

        if let context = NSGraphicsContext.current?.cgContext {
            if let transition {
                let outgoingAlpha = transition.alpha * (1 - (crossfade ?? 0))
                let outgoingX = drawingOriginX(
                    textWidth: transition.textSize.width,
                    shouldScroll: transition.textSize.width > transition.textRect.width + 8,
                    offset: transition.offset,
                    textRect: transition.textRect,
                    alignment: transition.alignment
                )
                let outgoingY = drawingOriginY(
                    for: transition.attributed,
                    measuredSize: transition.textSize,
                    typographicBounds: transition.typographicBounds,
                    usesTypographicVerticalCentering: transition.usesTypographicVerticalCentering
                )
                drawAttributedLine(
                    transition.attributed,
                    at: NSPoint(x: outgoingX, y: outgoingY),
                    alpha: outgoingAlpha,
                    shouldApplyEdgeFade: transition.textSize.width > transition.textRect.width + 8,
                    repeatCount: transition.repeatCount,
                    repeatStride: transition.repeatStride,
                    in: context
                )
            }
            drawAttributedLine(
                attributed,
                at: NSPoint(x: x, y: y),
                alpha: sample.alpha * incomingAlpha,
                shouldApplyEdgeFade: shouldScroll,
                repeatCount: sample.repeatCount,
                repeatStride: sample.repeatStride,
                in: context
            )
        } else {
            attributed.draw(at: NSPoint(x: x, y: y))
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawingOriginY(for attributed: NSAttributedString, measuredSize: NSSize) -> CGFloat {
        drawingOriginY(
            for: attributed,
            measuredSize: measuredSize,
            typographicBounds: typographicBounds(for: attributed),
            usesTypographicVerticalCentering: usesTypographicVerticalCentering
        )
    }

    private func drawingOriginY(
        for attributed: NSAttributedString,
        measuredSize: NSSize,
        typographicBounds: NSRect,
        usesTypographicVerticalCentering: Bool
    ) -> CGFloat {
        guard usesTypographicVerticalCentering,
              attributed.length > 0,
              let effectiveFont = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        else {
            return pixelAligned(floor((bounds.height - measuredSize.height) / 2))
        }

        // attributed.size() discards the vertical origin of the glyph box. When the font-size
        // slider changes, different fonts report different ascender/descender offsets, so only
        // centering by height makes the lyric look high or low. Center the actual typographic box.
        let textBounds = typographicBounds
        let fontBounds = effectiveFont.boundingRectForFont
        let sourceBounds = textBounds.height > 0 ? textBounds : fontBounds
        return pixelAligned(floor(bounds.midY - sourceBounds.midY))
    }

    private func renderSample(maxOffset: CGFloat, shouldScroll: Bool) -> LyricsScrollEngine.RenderSample {
        engine.renderSample(
            maxOffset: maxOffset,
            shouldScroll: shouldScroll,
            viewportWidth: protectedTextRect().width,
            now: renderTimestamp()
        )
    }

    private func updateLayerScale() {
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func attributedString() -> NSAttributedString {
        if let attributedCache { return attributedCache }

        let attributed = makeAttributedString(for: stringValue)
        attributedCache = attributed
        return attributed
    }

    private func makeAttributedString(for text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
            .kern: 0.1
        ]
        if strokeWidth > 0 {
            attributes[.strokeColor] = strokeColor
            attributes[.strokeWidth] = -strokeWidth
        }
        if let textShadow {
            attributes[.shadow] = textShadow
        }

        return NSAttributedString(string: text, attributes: attributes)
    }

    private func measuredSize(for attributed: NSAttributedString) -> NSSize {
        if measuredTextSize == .zero {
            let size = attributed.size()
            measuredTextSize = NSSize(width: ceil(size.width + 1), height: ceil(size.height))
        }
        return measuredTextSize
    }

    private func typographicBounds(for attributed: NSAttributedString) -> NSRect {
        if measuredTypographicBounds != .zero { return measuredTypographicBounds }
        measuredTypographicBounds = attributed.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return measuredTypographicBounds
    }

    private func resetTextCaches() {
        engine.fontPointSize = font.pointSize
        engine.invalidateTextCaches()
        attributedCache = nil
        measuredTextSize = .zero
        measuredTypographicBounds = .zero
    }

    private func captureOutgoingLineIfNeeded(oldValue: String, newValue: String) {
        let oldText = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldText.isEmpty, !newText.isEmpty, bounds.width > 2, bounds.height > 2 else {
            outgoingLine = nil
            return
        }
        if DesktopLyricsParser.isSilencePlaceholderText(oldText),
           DesktopLyricsParser.isSilencePlaceholderText(newText) {
            outgoingLine = nil
            return
        }

        let now = CACurrentMediaTime()
        let attributed = attributedCache ?? makeAttributedString(for: oldValue)
        let measured = measuredTextSize == .zero ? measuredSize(for: attributed) : measuredTextSize
        let typographic = measuredTypographicBounds == .zero ? typographicBounds(for: attributed) : measuredTypographicBounds
        let textRect = protectedTextRect()
        let maxOffset = max(0, measured.width - textRect.width)
        let shouldScroll = maxOffset > 8
        let sample = renderSample(maxOffset: maxOffset, shouldScroll: shouldScroll)

        outgoingLine = OutgoingLine(
            attributed: attributed,
            textSize: measured,
            typographicBounds: typographic,
            textRect: textRect,
            alignment: alignment,
            usesTypographicVerticalCentering: usesTypographicVerticalCentering,
            offset: sample.offset,
            alpha: sample.alpha,
            repeatCount: sample.repeatCount,
            repeatStride: sample.repeatStride,
            startedAt: now,
            duration: lineCrossfadeDuration
        )
    }

    private func activeOutgoingLine(at timestamp: CFTimeInterval) -> OutgoingLine? {
        guard let outgoingLine else { return nil }
        if timestamp - outgoingLine.startedAt >= outgoingLine.duration {
            self.outgoingLine = nil
            return nil
        }
        return outgoingLine
    }

    private func crossfadeProgress(now: CFTimeInterval, transition: OutgoingLine) -> CFTimeInterval {
        let linear = clamp((now - transition.startedAt) / max(0.001, transition.duration), 0, 1)
        return smootherStep(linear)
    }

    private func updateAnimationState() {
        guard window?.isVisible == true else {
            stopDisplayDriver()
            return
        }
        let textWidth = measuredSize(for: attributedString()).width
        let textWidthLimit = protectedTextRect().width
        let needsTransitionFrames = outgoingLine != nil
        let isStablePlaceholder = DesktopLyricsParser.isSilencePlaceholderText(stringValue)
        if !engine.timingIsPaused, !stringValue.isEmpty, bounds.width > 2, (needsTransitionFrames || (!isStablePlaceholder && textWidth > textWidthLimit + 8)) {
            startDisplayDriverIfNeeded()
        } else {
            stopDisplayDriver()
        }
        needsDisplay = true
    }

    private func startDisplayDriverIfNeeded() {
        guard activeDisplayLink == nil else { return }
        displayTimestamp = CACurrentMediaTime()
        let target = DisplayLinkTarget(view: self)
        let link = displayLink(target: target, selector: #selector(DisplayLinkTarget<DesktopLyricsLineView>.displayLinkDidFire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        link.isPaused = false
        displayLinkTarget = target
        activeDisplayLink = link
    }

    private func stopDisplayDriver() {
        activeDisplayLink?.invalidate()
        activeDisplayLink = nil
        displayLinkTarget = nil
    }

    func displayLinkDidFire(_ link: CADisplayLink) {
        // 自愈：窗口 orderOut 后 window 属性仍非 nil（viewWillMove(toWindow: nil) 不会触发），
        // 靠每帧检查可见性停掉驱动，避免 60fps 在不可见窗口上永久空转。
        guard window?.isVisible == true else {
            stopDisplayDriver()
            return
        }
        // Use the actual display-link timestamp, not the predicted target timestamp.
        // The target timestamp can wobble slightly when the system changes refresh pacing, which
        // is especially visible as tiny acceleration/deceleration in very slow lyric scrolling.
        displayTimestamp = link.timestamp > 0 ? link.timestamp : CACurrentMediaTime()
        if let outgoingLine, displayTimestamp - outgoingLine.startedAt >= outgoingLine.duration {
            self.outgoingLine = nil
            updateAnimationState()
        }
        needsDisplay = true
    }

    private func renderTimestamp() -> CFTimeInterval {
        activeDisplayLink == nil ? CACurrentMediaTime() : displayTimestamp
    }

    private func protectedTextRect() -> NSRect {
        let inset = min(max(0, contentInsetX), max(0, bounds.width * 0.30))
        return bounds.insetBy(dx: inset, dy: 0)
    }

    private func drawingOriginX(textWidth: CGFloat, shouldScroll: Bool, offset: CGFloat, textRect: NSRect) -> CGFloat {
        drawingOriginX(textWidth: textWidth, shouldScroll: shouldScroll, offset: offset, textRect: textRect, alignment: alignment)
    }

    private func drawingOriginX(
        textWidth: CGFloat,
        shouldScroll: Bool,
        offset: CGFloat,
        textRect: NSRect,
        alignment: NSTextAlignment
    ) -> CGFloat {
        guard shouldScroll else {
            switch alignment {
            case .left, .natural, .justified:
                return pixelAligned(textRect.minX)
            case .right:
                return pixelAligned(max(textRect.minX, textRect.maxX - textWidth))
            default:
                return pixelAligned(max(textRect.minX, floor(textRect.midX - textWidth / 2)))
            }
        }
        // Do not pixel-snap moving lyrics. At slow word-by-word speeds the offset advances by
        // less than one physical pixel per frame; rounding that value produces a visible
        // stop/jump cadence. Keep static text pixel-aligned, but let scrolling text move on
        // sub-pixels so Core Graphics can anti-alias the motion smoothly.
        return textRect.minX - offset
    }

    private func drawAttributedLine(
        _ attributed: NSAttributedString,
        at origin: NSPoint,
        alpha: CGFloat,
        shouldApplyEdgeFade: Bool,
        repeatCount: Int,
        repeatStride: CGFloat,
        in context: CGContext
    ) {
        guard alpha > 0.001 else { return }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        if alpha < 0.999 {
            context.setAlpha(alpha)
        }

        let copies = max(1, repeatCount)
        let stride = repeatStride > 1 ? repeatStride : 0
        for index in 0..<copies {
            let repeatedX = origin.x + CGFloat(index) * stride
            attributed.draw(at: NSPoint(x: repeatedX, y: origin.y))
        }

        if shouldApplyEdgeFade {
            applyEdgeFade(in: context)
        }
        context.endTransparencyLayer()
    }

    private func applyEdgeFade(in context: CGContext) {
        let fade = min(max(0, fadeEdgeWidth), bounds.width / 3)
        guard fade > 1 else { return }

        if edgeFadeGradients == nil {
            edgeFadeGradients = EdgeFadeRenderer.makeGradients(peakAlpha: 0.88)
        }
        guard let gradients = edgeFadeGradients else { return }
        EdgeFadeRenderer.apply(in: context, bounds: bounds, fade: fade, gradients: gradients)
    }

    private func clamp(_ value: CFTimeInterval, _ lower: CFTimeInterval, _ upper: CFTimeInterval) -> CFTimeInterval {
        min(max(value, lower), upper)
    }

    private func pixelAligned(_ value: CGFloat) -> CGFloat {
        let scale = max(1, layer?.contentsScale ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        return (value * scale).rounded() / scale
    }

    private func smootherStep(_ value: CFTimeInterval) -> CFTimeInterval {
        let t = clamp(value, 0, 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}

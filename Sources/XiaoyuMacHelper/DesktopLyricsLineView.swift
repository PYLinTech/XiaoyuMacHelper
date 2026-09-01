import AppKit
import QuartzCore

@MainActor
private final class DesktopLyricsDisplayLinkTarget: NSObject {
    weak var view: DesktopLyricsLineView?

    init(view: DesktopLyricsLineView) {
        self.view = view
    }

    @objc func displayLinkDidFire(_ link: CADisplayLink) {
        view?.displayLinkDidFire(link)
    }
}

/// Desktop-lyrics-only renderer.
///
/// The scroll position is derived from the lyric timeline every frame. It does not accumulate
/// pixels and it does not restart when the controller refreshes the same lyric line. The planner
/// also looks at the previous/current/next lyric durations so dense lyric sections scroll with a
/// tighter rhythm while slow sections keep more reading space.
@MainActor
final class DesktopLyricsLineView: NSView {
    var stringValue: String = "" {
        didSet {
            guard oldValue != stringValue else { return }
            captureOutgoingLineIfNeeded(oldValue: oldValue, newValue: stringValue)
            resetTextCaches()
            resetLineState(keepsTiming: false)
        }
    }

    var font: NSFont = NSFont.systemFont(ofSize: 28, weight: .semibold) {
        didSet {
            guard oldValue != font else { return }
            resetTextCaches()
            invalidateScrollPlan()
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
            attributedCache = nil
            invalidateScrollPlan()
            needsDisplay = true
        }
    }

    var fadeEdgeWidth: CGFloat = 22 {
        didSet { needsDisplay = true }
    }

    var contentInsetX: CGFloat = 0 {
        didSet {
            guard oldValue != contentInsetX else { return }
            invalidateScrollPlan()
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
    var fallbackScrollSpeed: CGFloat = 48

    private struct LineTiming {
        var identity: TimeInterval?
        var duration: CFTimeInterval?
        var previousDuration: CFTimeInterval?
        var nextDuration: CFTimeInterval?
        var elapsedAtSync: CFTimeInterval
        var syncedAt: CFTimeInterval
        /// Visual timeline speed. Normally 1.0; after pause/resume it is nudged slightly
        /// above/below 1.0 so the text catches up without a visible position jump.
        var rate: CFTimeInterval

        func elapsed(at now: CFTimeInterval, isPaused: Bool) -> CFTimeInterval {
            let raw = isPaused ? elapsedAtSync : elapsedAtSync + (now - syncedAt) * rate
            guard let duration else { return max(0, raw) }
            return min(max(0, raw), duration)
        }
    }

    private struct ScrollPlanSignature: Equatable {
        var textVersion: Int
        var widthBucket: Int
        var textWidthBucket: Int
        var fontBucket: Int
        var durationBucket: Int
        var wordTimingBucket: Int
    }

    private struct WordScrollAnchor {
        var time: CFTimeInterval
        var offset: CGFloat
    }

    private struct TimedScrollPlan {
        var signature: ScrollPlanSignature
        var travelDuration: CFTimeInterval
        var targetOffset: CGFloat
        var rampFraction: CFTimeInterval
        var repeatCount: Int
        var repeatStride: CGFloat
        var wordAnchors: [WordScrollAnchor]
    }

    private struct RenderSample {
        var offset: CGFloat
        var alpha: CGFloat
        var repeatCount: Int
        var repeatStride: CGFloat
    }

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

    private struct UntimedState {
        enum Phase {
            case headHold
            case moving
            case tailHold
            case resetFade
        }

        var phase: Phase = .headHold
        var phaseStartedAt: CFTimeInterval = CACurrentMediaTime()
        var resetSwapped = false
        var offset: CGFloat = 0
        var alpha: CGFloat = 1
    }

    private var timing = LineTiming(
        identity: nil,
        duration: nil,
        previousDuration: nil,
        nextDuration: nil,
        elapsedAtSync: 0,
        syncedAt: CACurrentMediaTime(),
        rate: 1.0
    )
    private var timingIsFresh = false
    private var timingIsPaused = false
    private var textVersion = 0
    private var attributedCache: NSAttributedString?
    private var measuredTextSize: NSSize = .zero
    private var measuredTypographicBounds: NSRect = .zero
    private var activeDisplayLink: CADisplayLink?
    private var displayLinkTarget: DesktopLyricsDisplayLinkTarget?
    private var displayTimestamp: CFTimeInterval = CACurrentMediaTime()
    private var cachedPlan: TimedScrollPlan?
    private var timedOffsetMemory: (identity: TimeInterval?, maxOffset: CGFloat, offset: CGFloat, timestamp: CFTimeInterval)?
    private var wordTimings: [DesktopLyricWordTiming] = []
    private var untimedState = UntimedState()
    private var untimedPausedAt: CFTimeInterval?
    private var outgoingLine: OutgoingLine?
    private let lineCrossfadeDuration: CFTimeInterval = 0.24
    private var edgeFadeGradients: (left: CGGradient, right: CGGradient)?

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
            invalidateScrollPlan()
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
        let now = CACurrentMediaTime()
        let normalizedIdentity = normalizedIdentity(identity)
        let normalizedDuration = normalizedDuration(duration)
        let normalizedPrevious = normalizedNeighborDuration(previousDuration)
        let normalizedNext = normalizedNeighborDuration(nextDuration)
        let normalizedWords = normalizedWordTimings(wordTimings, duration: normalizedDuration)
        let wordsChanged = normalizedWords != self.wordTimings
        if wordsChanged {
            self.wordTimings = normalizedWords
            timedOffsetMemory = nil
            invalidateScrollPlan()
        }
        let normalizedElapsed = normalizedDuration.map { min(max(0, elapsed), $0) } ?? max(0, elapsed)
        let shouldFreezeTiming = !isPlaying
        let visualElapsedBeforeUpdate = timing.elapsed(at: now, isPaused: timingIsPaused)

        let identityChanged = didLineIdentityChange(from: timing.identity, to: normalizedIdentity)
        if identityChanged {
            resetLineState(keepsTiming: true)
            timing.identity = normalizedIdentity
            timing.duration = normalizedDuration
            timing.previousDuration = normalizedPrevious
            timing.nextDuration = normalizedNext
            timing.elapsedAtSync = normalizedElapsed
            timing.syncedAt = now
            timing.rate = 1.0
            timingIsFresh = normalizedDuration != nil
            timingIsPaused = shouldFreezeTiming
            invalidateScrollPlan()
            updateAnimationState()
            return
        }

        let oldDuration = timing.duration
        let oldPrevious = timing.previousDuration
        let oldNext = timing.nextDuration
        let wasPaused = timingIsPaused
        timing.identity = normalizedIdentity
        timing.duration = normalizedDuration
        timing.previousDuration = normalizedPrevious
        timing.nextDuration = normalizedNext
        timingIsFresh = normalizedDuration != nil
        timingIsPaused = shouldFreezeTiming

        if shouldFreezeTiming {
            // Pause must freeze the exact visual frame. Do not rebase to MediaRemote's elapsed
            // time, because that value can be one polling tick ahead/behind the text currently on
            // screen and causes the visible jump/"twitch".
            if !wasPaused {
                if oldDuration == nil || !timingIsFresh {
                    freezeUntimedMotion(at: now)
                    untimedPausedAt = now
                }
                timing.elapsedAtSync = normalizedDuration.map { min(max(0, visualElapsedBeforeUpdate), $0) } ?? max(0, visualElapsedBeforeUpdate)
                timing.syncedAt = now
                timing.rate = 1.0
            }
        } else if wasPaused {
            if let pausedAt = untimedPausedAt {
                untimedState.phaseStartedAt += now - pausedAt
                untimedPausedAt = nil
            }
            // Resume from the frozen visual timeline, then gently drift toward the real playback
            // clock by changing speed a little. This keeps the scroll continuous instead of
            // jumping to the system-reported position on the first playing tick.
            let frozenElapsed = normalizedDuration.map { min(max(0, visualElapsedBeforeUpdate), $0) } ?? max(0, visualElapsedBeforeUpdate)
            timing.elapsedAtSync = frozenElapsed
            timing.syncedAt = now
            timing.rate = correctionRate(forDrift: normalizedElapsed - frozenElapsed, duration: normalizedDuration)
        } else if oldDuration == nil, normalizedDuration != nil {
            timing.elapsedAtSync = normalizedElapsed
            timing.syncedAt = now
            timing.rate = 1.0
        } else if let duration = normalizedDuration {
            let predicted = timing.elapsed(at: now, isPaused: timingIsPaused)
            let drift = normalizedElapsed - predicted
            if isLikelySeek(drift: drift, predicted: predicted, reported: normalizedElapsed, duration: duration) {
                timing.elapsedAtSync = normalizedElapsed
                timing.syncedAt = now
                timing.rate = 1.0
                timedOffsetMemory = nil
                invalidateScrollPlan()
            } else if abs(drift) < 0.24 {
                // Ordinary polling jitter should not keep changing the velocity bias.  Rebase to
                // the current visual frame and run at normal speed; pixel alignment handles the
                // remaining sub-pixel noise at draw time.
                timing.elapsedAtSync = predicted
                timing.syncedAt = now
                timing.rate = 1.0
            } else {
                // Never correct ordinary polling drift by moving the offset immediately. Keep the
                // current position as the base and use a small speed bias to catch up or slow down.
                timing.elapsedAtSync = predicted
                timing.syncedAt = now
                timing.rate = correctionRate(forDrift: drift, duration: normalizedDuration)
            }
        } else {
            timing.elapsedAtSync = normalizedElapsed
            timing.syncedAt = now
            timing.rate = 1.0
        }

        if durationChanged(oldDuration, normalizedDuration)
            || neighborDurationChanged(oldPrevious, normalizedPrevious)
            || neighborDurationChanged(oldNext, normalizedNext) {
            invalidateScrollPlan()
        }
        updateAnimationState()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !stringValue.isEmpty, bounds.width > 2, bounds.height > 2 else { return }

        let now = CACurrentMediaTime()
        let attributed = attributedString()
        let textSize = measuredSize(for: attributed)
        let textRect = protectedTextRect()
        let maxOffset = max(0, textSize.width - textRect.width)
        let shouldScroll = maxOffset > 8
        let sample = renderSample(maxOffset: maxOffset, shouldScroll: shouldScroll)
        let x = drawingOriginX(textWidth: textSize.width, shouldScroll: shouldScroll, offset: sample.offset, textRect: textRect)
        let y = drawingOriginY(for: attributed, measuredSize: textSize)
        let transition = activeOutgoingLine(at: now)
        let incomingAlpha = transition.map { CGFloat(crossfadeProgress(now: now, transition: $0)) } ?? 1

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()

        if let context = NSGraphicsContext.current?.cgContext {
            if let transition {
                let progress = CGFloat(crossfadeProgress(now: now, transition: transition))
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
                    alpha: transition.alpha * (1 - progress),
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

    private func renderSample(maxOffset: CGFloat, shouldScroll: Bool) -> RenderSample {
        if isSilencePlaceholderText(stringValue) {
            return RenderSample(offset: 0, alpha: 1, repeatCount: 1, repeatStride: 0)
        }
        guard shouldScroll else { return RenderSample(offset: 0, alpha: 1, repeatCount: 1, repeatStride: 0) }
        let now = renderTimestamp()
        if let duration = timing.duration, timingIsFresh {
            let plan = scrollPlan(duration: duration, maxOffset: maxOffset)
            return RenderSample(
                offset: timedOffset(at: now, plan: plan),
                alpha: 1,
                repeatCount: plan.repeatCount,
                repeatStride: plan.repeatStride
            )
        }
        if timingIsPaused {
            return RenderSample(offset: untimedState.offset, alpha: untimedState.alpha, repeatCount: 1, repeatStride: 0)
        }
        return untimedSample(at: now, maxOffset: maxOffset)
    }

    private func freezeUntimedMotion(at timestamp: CFTimeInterval) {
        guard !stringValue.isEmpty, bounds.width > 2, bounds.height > 2 else { return }
        let attributed = attributedString()
        let textSize = measuredSize(for: attributed)
        let textRect = protectedTextRect()
        let maxOffset = max(0, textSize.width - textRect.width)
        guard maxOffset > 8 else { return }
        _ = untimedSample(at: timestamp, maxOffset: maxOffset)
    }

    private func updateLayerScale() {
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func normalizedIdentity(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else { return nil }
        return (value * 1000).rounded() / 1000
    }

    private func normalizedDuration(_ value: TimeInterval?) -> CFTimeInterval? {
        guard let value, value.isFinite, value > 0.12 else { return nil }
        return min(42.0, max(0.14, value))
    }

    private func normalizedNeighborDuration(_ value: TimeInterval?) -> CFTimeInterval? {
        guard let value, value.isFinite, value > 0.12 else { return nil }
        return min(42.0, max(0.14, value))
    }

    private func didLineIdentityChange(from old: TimeInterval?, to new: TimeInterval?) -> Bool {
        switch (old, new) {
        case (.none, .none):
            return false
        case let (.some(lhs), .some(rhs)):
            return abs(lhs - rhs) > 0.012
        default:
            return true
        }
    }

    private func durationChanged(_ lhs: CFTimeInterval?, _ rhs: CFTimeInterval?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return false
        case let (.some(a), .some(b)):
            return abs(a - b) > 0.16
        default:
            return true
        }
    }

    private func neighborDurationChanged(_ lhs: CFTimeInterval?, _ rhs: CFTimeInterval?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return false
        case let (.some(a), .some(b)):
            return abs(a - b) > 0.28
        default:
            return false
        }
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
        textVersion &+= 1
        attributedCache = nil
        measuredTextSize = .zero
        measuredTypographicBounds = .zero
        invalidateScrollPlan()
    }

    private func captureOutgoingLineIfNeeded(oldValue: String, newValue: String) {
        let oldText = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldText.isEmpty, !newText.isEmpty, bounds.width > 2, bounds.height > 2 else {
            outgoingLine = nil
            return
        }
        if isSilencePlaceholderText(oldText), isSilencePlaceholderText(newText) {
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

    private func resetLineState(keepsTiming: Bool) {
        untimedState = UntimedState(phase: .headHold, phaseStartedAt: CACurrentMediaTime(), resetSwapped: false, offset: 0, alpha: 1)
        cachedPlan = nil
        timedOffsetMemory = nil
        if !keepsTiming {
            wordTimings = []
            timing = LineTiming(identity: nil, duration: nil, previousDuration: nil, nextDuration: nil, elapsedAtSync: 0, syncedAt: CACurrentMediaTime(), rate: 1.0)
            timingIsFresh = false
            timingIsPaused = false
            untimedPausedAt = nil
        }
        needsDisplay = true
        updateAnimationState()
    }

    private func invalidateScrollPlan() {
        cachedPlan = nil
        needsDisplay = true
    }

    private func updateAnimationState() {
        guard window != nil else {
            stopDisplayDriver()
            return
        }
        let textWidth = measuredSize(for: attributedString()).width
        let textWidthLimit = protectedTextRect().width
        let needsTransitionFrames = outgoingLine != nil
        let isStablePlaceholder = isSilencePlaceholderText(stringValue)
        if !timingIsPaused, !stringValue.isEmpty, bounds.width > 2, (needsTransitionFrames || (!isStablePlaceholder && textWidth > textWidthLimit + 8)) {
            startDisplayDriverIfNeeded()
        } else {
            stopDisplayDriver()
        }
        needsDisplay = true
    }

    private func startDisplayDriverIfNeeded() {
        guard activeDisplayLink == nil else { return }
        displayTimestamp = CACurrentMediaTime()
        let target = DesktopLyricsDisplayLinkTarget(view: self)
        let link = displayLink(target: target, selector: #selector(DesktopLyricsDisplayLinkTarget.displayLinkDidFire(_:)))
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

    fileprivate func displayLinkDidFire(_ link: CADisplayLink) {
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

    private func scrollPlan(duration: CFTimeInterval, maxOffset: CGFloat) -> TimedScrollPlan {
        let signature = currentSignature(duration: duration, maxOffset: maxOffset)
        if let cachedPlan, cachedPlan.signature == signature {
            return cachedPlan
        }

        let visibleWidth = max(1, protectedTextRect().width)
        let textWidth = visibleWidth + maxOffset
        // `duration` is already normalized to [0.14, 42.0] by syncLineTiming; no extra clamp.
        let repeatCount = timedRepeatCount(
            duration: duration,
            viewportWidth: visibleWidth,
            textWidth: textWidth,
            maxOffset: maxOffset
        )
        let repeatGap = repeatGapWidth(viewportWidth: visibleWidth)
        let repeatStride = repeatCount > 1 ? ceil(textWidth + repeatGap) : 0
        let effectiveTargetOffset = maxOffset + CGFloat(max(0, repeatCount - 1)) * repeatStride
        let wordAnchors = wordScrollAnchors(duration: duration, viewportWidth: visibleWidth, maxOffset: effectiveTargetOffset)
        let rampFraction = formulaRampFraction(
            lineDuration: duration,
            viewportWidth: visibleWidth,
            textWidth: textWidth,
            maxOffset: effectiveTargetOffset
        )

        // Timed lyrics now use a direct visual-time formula.  There is no separate head hold,
        // travel phase, or tail hold: every rendered frame maps the current line's elapsed time to
        // a deterministic offset.  This is the actual marquee model:
        //   offsetPx = scrollablePx * progress(lineElapsedMs / lineDurationMs,
        //                                      viewportWidthPx,
        //                                      textWidthPx)
        // Keeping the whole line duration in the formula prevents the old behavior where long
        // lyrics scrolled quickly to the end and then waited for the next line.
        let plan = TimedScrollPlan(
            signature: signature,
            travelDuration: duration,
            targetOffset: effectiveTargetOffset,
            rampFraction: rampFraction,
            repeatCount: repeatCount,
            repeatStride: repeatStride,
            wordAnchors: wordAnchors
        )
        cachedPlan = plan
        return plan
    }

    private func currentSignature(duration: CFTimeInterval, maxOffset: CGFloat) -> ScrollPlanSignature {
        ScrollPlanSignature(
            textVersion: textVersion,
            widthBucket: Int((protectedTextRect().width / 2).rounded()),
            textWidthBucket: Int((maxOffset / 2).rounded()),
            fontBucket: Int((font.pointSize * 10).rounded()),
            durationBucket: bucket(timing.duration ?? duration),
            wordTimingBucket: wordTimingBucket()
        )
    }

    private func bucket(_ value: CFTimeInterval) -> Int {
        Int((value * 5).rounded())
    }

    private func timedOffset(at timestamp: CFTimeInterval, plan: TimedScrollPlan) -> CGFloat {
        let elapsed = timing.elapsed(at: timestamp, isPaused: timingIsPaused)
        let rawOffset: CGFloat
        if !plan.wordAnchors.isEmpty {
            rawOffset = fluidWordTimedOffset(elapsed: elapsed, plan: plan)
        } else {
            let progress = clamp(elapsed / max(0.001, plan.travelDuration), 0, 1)
            let curve = CGFloat(lineTimelineProgress(progress, rampFraction: plan.rampFraction))
            rawOffset = plan.targetOffset * curve
        }
        return continuousTimedOffset(rawOffset, maxOffset: plan.targetOffset, at: timestamp)
    }

    private func continuousTimedOffset(_ rawOffset: CGFloat, maxOffset: CGFloat, at timestamp: CFTimeInterval) -> CGFloat {
        let clampedOffset = min(max(0, rawOffset), maxOffset)
        guard !timingIsPaused else {
            timedOffsetMemory = (timing.identity, maxOffset, clampedOffset, timestamp)
            return clampedOffset
        }

        guard let memory = timedOffsetMemory else {
            timedOffsetMemory = (timing.identity, maxOffset, clampedOffset, timestamp)
            return clampedOffset
        }

        let sameIdentity = !didLineIdentityChange(from: memory.identity, to: timing.identity)
        let sameDistance = abs(memory.maxOffset - maxOffset) <= 2.0
        let deltaTime = timestamp - memory.timestamp
        guard sameIdentity, sameDistance, deltaTime >= 0, deltaTime <= 0.24 else {
            timedOffsetMemory = (timing.identity, maxOffset, clampedOffset, timestamp)
            return clampedOffset
        }

        // Keep normal playback monotonic, but do not snap tiny word-lyric movements to the
        // target. Snapping a 0.03~0.06 px delta is exactly what makes slow scrolling look like
        // stop-start motion. Word mode now uses a lighter one-frame damper and only hard-snaps
        // at the very end of the line.
        let monotonicTarget = max(memory.offset, clampedOffset)
        let hasWordTiming = !wordTimings.isEmpty
        let smoothingTime = hasWordTiming ? 0.040 : 0.026
        let factor = 1 - exp(-clamp(deltaTime, 0.001, 0.050) / smoothingTime)
        var stabilized = memory.offset + (monotonicTarget - memory.offset) * CGFloat(factor)
        if hasWordTiming {
            if maxOffset - monotonicTarget < 0.30 {
                stabilized = monotonicTarget
            }
        } else {
            let snapDistance: CGFloat = 0.14
            if monotonicTarget - stabilized < snapDistance {
                stabilized = monotonicTarget
            }
        }
        timedOffsetMemory = (timing.identity, maxOffset, stabilized, timestamp)
        return stabilized
    }

    private func untimedSample(at timestamp: CFTimeInterval, maxOffset: CGFloat) -> RenderSample {
        let elapsed = timestamp - untimedState.phaseStartedAt
        let travelDuration = max(1.25, CFTimeInterval(maxOffset / max(18, fallbackScrollSpeed)))

        switch untimedState.phase {
        case .headHold:
            untimedState.offset = 0
            untimedState.alpha = 1
            if elapsed >= 0.75 {
                untimedState.phase = .moving
                untimedState.phaseStartedAt = timestamp
            }
        case .moving:
            let progress = clamp(elapsed / travelDuration, 0, 1)
            untimedState.offset = maxOffset * CGFloat(lineTimelineProgress(progress, rampFraction: 0.155))
            untimedState.alpha = 1
            if progress >= 1 {
                untimedState.offset = maxOffset
                untimedState.phase = .tailHold
                untimedState.phaseStartedAt = timestamp
            }
        case .tailHold:
            untimedState.offset = maxOffset
            untimedState.alpha = 1
            if elapsed >= 0.80 {
                untimedState.phase = .resetFade
                untimedState.phaseStartedAt = timestamp
                untimedState.resetSwapped = false
            }
        case .resetFade:
            let progress = clamp(elapsed / 0.24, 0, 1)
            if progress >= 0.50, !untimedState.resetSwapped {
                untimedState.offset = 0
                untimedState.resetSwapped = true
            }
            if progress < 0.50 {
                untimedState.alpha = CGFloat(1 - easeOutCubic(progress * 2))
            } else {
                untimedState.alpha = CGFloat(easeOutCubic((progress - 0.5) * 2))
            }
            if progress >= 1 {
                untimedState.offset = 0
                untimedState.alpha = 1
                untimedState.phase = .headHold
                untimedState.phaseStartedAt = timestamp
                untimedState.resetSwapped = false
            }
        }
        return RenderSample(offset: untimedState.offset, alpha: untimedState.alpha, repeatCount: 1, repeatStride: 0)
    }


    private func correctionRate(forDrift drift: CFTimeInterval, duration: CFTimeInterval?) -> CFTimeInterval {
        let lineDuration = duration ?? 3.0
        let recoveryWindow = clamp(lineDuration * 0.42, 0.85, 2.80)
        let maxSlowdown = lineDuration < 1.45 ? 0.16 : 0.115
        let maxSpeedup = lineDuration < 1.45 ? 0.24 : 0.165
        let requestedBias = drift / max(0.20, recoveryWindow)
        return 1.0 + clamp(requestedBias, -maxSlowdown, maxSpeedup)
    }

    private func isLikelySeek(
        drift: CFTimeInterval,
        predicted: CFTimeInterval,
        reported: CFTimeInterval,
        duration: CFTimeInterval
    ) -> Bool {
        let backwardTolerance = duration < 1.55 ? 0.18 : 0.30
        if reported + backwardTolerance < predicted { return true }
        let seekThreshold = max(1.85, min(5.0, duration * 0.62))
        return abs(drift) > seekThreshold
    }

    private func weightedRhythm(previous: CFTimeInterval, current: CFTimeInterval, next: CFTimeInterval) -> CFTimeInterval {
        let clampedPrevious = clamp(previous, 0.70, 8.5)
        let clampedCurrent = clamp(current, 0.70, 8.5)
        let clampedNext = clamp(next, 0.70, 8.5)
        return clampedPrevious * 0.22 + clampedCurrent * 0.56 + clampedNext * 0.22
    }

    private func timedRepeatCount(
        duration: CFTimeInterval,
        viewportWidth: CGFloat,
        textWidth: CGFloat,
        maxOffset: CGFloat
    ) -> Int {
        if isSilencePlaceholderText(stringValue) || !wordTimings.isEmpty { return 1 }
        let visible = max(1, CFTimeInterval(viewportWidth))
        let total = max(visible, CFTimeInterval(textWidth))
        let scrollable = max(0, CFTimeInterval(maxOffset))
        guard scrollable > 8 else { return 1 }

        // Repeat-count planning is intentionally based on the two stable dimensions of a timed
        // lyric line:
        //   1. the line's total duration;
        //   2. the full text length / visible viewport length.
        // It no longer uses raw pixel speed as the primary trigger.  That keeps the decision tied
        // to the lyric itself and avoids tiny width/timing jitter flipping the copy count.
        let lengthRatio = clamp(total / visible, 1.0, 7.5)
        let overflowRatio = max(0.0, lengthRatio - 1.0)

        // Do not enter repeated mode for ordinary short lines.  Wider text is already visually
        // moving across more content, so it needs a little more time before we allow repetition.
        let minimumRepeatDuration = 5.55 + min(1.65, overflowRatio) * 0.72
        guard duration >= minimumRepeatDuration else { return 1 }

        let gapRatio = CFTimeInterval(repeatGapWidth(viewportWidth: viewportWidth)) / visible
        let strideUnits = max(1.0, lengthRatio + gapRatio)

        // The maximum grows slowly with total line time.  This makes repetition an n-copy model
        // instead of a hard-coded 2/3-copy model, while still preventing sudden high-copy jumps.
        let durationHeadroom = max(0, duration - minimumRepeatDuration)
        let maxRepeatsByDuration = min(8, max(1, 2 + Int(floor(durationHeadroom / 3.15))))

        var repeats = 1
        while repeats < maxRepeatsByDuration {
            let currentUnits = max(0.12, overflowRatio + CFTimeInterval(repeats - 1) * strideUnits)
            let secondsPerViewportUnit = duration / currentUnits

            // Higher repeat levels require stronger evidence.  This small progressive threshold is
            // the anti-sensitivity buffer: hovering near a boundary should stay at the lower count.
            let levelPenalty = CFTimeInterval(repeats - 1) * 0.34
            let widthRelief = min(0.92, overflowRatio * 0.34)
            let entryThreshold = 4.25 + levelPenalty + widthRelief

            guard secondsPerViewportUnit > entryThreshold else { break }
            repeats += 1
        }

        return repeats
    }

    private func repeatGapWidth(viewportWidth: CGFloat) -> CGFloat {
        let fontScaled = font.pointSize * 2.35
        let viewportScaled = viewportWidth * 0.075
        return ceil(min(max(fontScaled, 42), max(58, viewportScaled)))
    }

    private func formulaRampFraction(
        lineDuration: CFTimeInterval,
        viewportWidth: CGFloat,
        textWidth: CGFloat,
        maxOffset: CGFloat
    ) -> CFTimeInterval {
        let visible = max(1, CFTimeInterval(viewportWidth))
        let total = max(visible, CFTimeInterval(textWidth))
        let scrollable = max(0, CFTimeInterval(maxOffset))
        let overflowRatio = clamp(scrollable / visible, 0, 6.0)
        let coverageRatio = clamp(scrollable / total, 0, 0.96)
        let shortLinePressure = clamp((1.25 - lineDuration) / 0.95, 0, 1)
        let longLineEase = clamp((lineDuration - 4.0) / 8.0, 0, 1)

        // The ramp is part of the formula, not a separate delay.  It only shapes velocity at the
        // two ends while the offset still progresses across the full lyric duration.
        return clamp(
            0.055
                + longLineEase * 0.070
                + coverageRatio * 0.040
                - overflowRatio * 0.012
                - shortLinePressure * 0.030,
            0.018,
            0.155
        )
    }

    /// Maps line progress (0...1) to scroll progress with smooth, asymmetric acceleration and
    /// deceleration ramps. The result starts at 0 and lands exactly on 1, so the text reaches its
    /// final offset precisely when the line duration elapses.
    ///
    /// Invariants: velocity is 0 at both ends (C2-smooth smootherstep ramps) and exactly
    /// 1/totalArea in the middle span, so the scroll reaches maxOffset exactly at t = 1.
    /// The lower clamps are pure zero-division guards — formulaRampFraction already keeps
    /// the fraction in [0.018, 0.155], so every value it produces changes the curve shape.
    private func lineTimelineProgress(_ value: CFTimeInterval, rampFraction: CFTimeInterval) -> CFTimeInterval {
        let t = clamp(value, 0, 1)
        let start = clamp(rampFraction * 1.42 + 0.010, 0.001, 0.190)
        let end = clamp(rampFraction * 0.92 + 0.006, 0.001, 0.145)
        let totalArea = max(0.001, 1 - (start + end) / 2)
        if t < start {
            let u = t / start
            return start * smoothstepIntegral(u) / totalArea
        }
        if t > 1 - end {
            let u = (t - (1 - end)) / end
            let beforeTail = 0.5 * start + (1 - start - end)
            let tailArea = end * (u - smoothstepIntegral(u))
            return (beforeTail + tailArea) / totalArea
        }
        return (0.5 * start + (t - start)) / totalArea
    }

    private func normalizedWordTimings(_ timings: [DesktopLyricWordTiming], duration: CFTimeInterval?) -> [DesktopLyricWordTiming] {
        let textLength = stringValue.utf16.count
        guard textLength > 0, !timings.isEmpty else { return [] }
        let maxEnd = duration ?? timings.map(\.end).max() ?? 0
        return timings.filter { timing in
            timing.start.isFinite
                && timing.end.isFinite
                && timing.end > timing.start + 0.015
                && timing.start >= -0.020
                && timing.end <= maxEnd + 0.75
                && timing.utf16Location >= 0
                && timing.utf16Length > 0
                && timing.utf16End <= textLength
        }
        .map { timing in
            DesktopLyricWordTiming(start: max(0, timing.start), end: min(maxEnd, timing.end), utf16Location: timing.utf16Location, utf16Length: timing.utf16Length)
        }
        .sorted { lhs, rhs in
            if abs(lhs.start - rhs.start) > 0.0005 { return lhs.start < rhs.start }
            return lhs.utf16Location < rhs.utf16Location
        }
    }

    private func wordTimingBucket() -> Int {
        guard !wordTimings.isEmpty else { return 0 }
        var hash = wordTimings.count &* 31
        for timing in wordTimings.prefix(10) {
            hash = hash &* 31 &+ Int((timing.start * 20).rounded())
            hash = hash &* 31 &+ Int((timing.end * 20).rounded())
            hash = hash &* 31 &+ timing.utf16Location
            hash = hash &* 31 &+ timing.utf16Length
        }
        if let last = wordTimings.last {
            hash = hash &* 31 &+ Int((last.end * 20).rounded())
            hash = hash &* 31 &+ last.utf16End
        }
        return hash
    }

    /// Where in the visible viewport the currently sung word should rest while it scrolls.
    /// Follows the lyric alignment: left-aligned text parks the active word on the left edge,
    /// right-aligned parks it on the right edge, centered keeps it at the visual center.
    private func preferredAnchorCenter(viewportWidth: CGFloat) -> CGFloat {
        switch alignment {
        case .left, .natural, .justified:
            return viewportWidth * 0.12
        case .right:
            return viewportWidth * 0.88
        default:
            return viewportWidth * 0.48
        }
    }

    private func wordScrollAnchors(duration: CFTimeInterval, viewportWidth: CGFloat, maxOffset: CGFloat) -> [WordScrollAnchor] {
        guard !wordTimings.isEmpty, maxOffset > 8, viewportWidth > 8 else { return [] }
        let nsText = stringValue as NSString
        let preferredCenter = preferredAnchorCenter(viewportWidth: viewportWidth)
        var anchors: [WordScrollAnchor] = [WordScrollAnchor(time: 0, offset: 0)]
        var lastOffset: CGFloat = 0
        for timing in wordTimings {
            guard timing.utf16End <= nsText.length else { continue }
            let prefix = nsText.substring(with: NSRange(location: 0, length: timing.utf16Location))
            let segment = nsText.substring(with: NSRange(location: timing.utf16Location, length: timing.utf16Length))
            let segmentCenter = measuredInlineWidth(prefix) + measuredInlineWidth(segment) / 2
            let rawTarget = min(maxOffset, max(lastOffset, segmentCenter - preferredCenter))
            let target = max(lastOffset, rawTarget)
            let anchorTime = clamp(mix(timing.start, timing.end, 0.35), 0, duration)
            let minimumVisualStep = max(3.5, min(7.0, font.pointSize * 0.16))
            if let previous = anchors.last, anchorTime - previous.time < 0.018 {
                anchors[anchors.count - 1] = WordScrollAnchor(time: previous.time, offset: max(previous.offset, target))
            } else if target - (anchors.last?.offset ?? 0) >= minimumVisualStep || target >= maxOffset - 1.0 {
                anchors.append(WordScrollAnchor(time: anchorTime, offset: target))
            }
            lastOffset = max(lastOffset, target)
        }
        if let last = anchors.last, duration - last.time > 0.050, maxOffset - last.offset > 1.5 {
            anchors.append(WordScrollAnchor(time: duration, offset: maxOffset))
        }
        return anchors.count > 1 ? anchors : []
    }

    private func measuredInlineWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return makeAttributedString(for: text).size().width
    }

    private func fluidWordTimedOffset(elapsed: CFTimeInterval, plan: TimedScrollPlan) -> CGFloat {
        let progress = clamp(elapsed / max(0.001, plan.travelDuration), 0, 1)

        // Word anchors are useful for keeping the currently sung word in a readable area, but using
        // them as the full scroll path creates small acceleration pockets between words. Make the
        // line-duration formula the main motion, then let the word anchors only guide it softly.
        let continuousCurve = lineTimelineProgress(
            progress,
            rampFraction: min(plan.rampFraction, 0.050)
        )
        let continuousOffset = plan.targetOffset * CGFloat(continuousCurve)
        let guidedOffset = wordTimedOffset(elapsed: elapsed, plan: plan)
        let durationPressure = clamp((plan.travelDuration - 2.2) / 7.0, 0, 1)
        let guideWeight = CGFloat(0.34 - durationPressure * 0.14)
        let blended = continuousOffset * (1 - guideWeight) + guidedOffset * guideWeight

        // Preserve forward-only motion without letting a single late word anchor force a visible
        // jump. The damper in continuousTimedOffset will finish the small catch-up smoothly.
        return min(max(0, blended), plan.targetOffset)
    }

    private func wordTimedOffset(elapsed: CFTimeInterval, plan: TimedScrollPlan) -> CGFloat {
        let anchors = plan.wordAnchors
        guard let first = anchors.first else { return 0 }
        let safeElapsed = clamp(elapsed, 0, plan.travelDuration)
        if safeElapsed <= first.time { return first.offset }

        for index in 1..<anchors.count {
            let next = anchors[index]
            if safeElapsed <= next.time {
                return monotoneHermiteOffset(
                    at: safeElapsed,
                    anchors: anchors,
                    segmentEndIndex: index
                )
            }
        }
        return anchors.last?.offset ?? 0
    }

    private func monotoneHermiteOffset(
        at time: CFTimeInterval,
        anchors: [WordScrollAnchor],
        segmentEndIndex index: Int
    ) -> CGFloat {
        let previous = anchors[index - 1]
        let next = anchors[index]
        let span = max(0.001, next.time - previous.time)
        let distance = next.offset - previous.offset
        guard distance > 0.10 else { return previous.offset }

        let currentSlope = CGFloat(distance) / CGFloat(span)
        let incomingSlope: CGFloat
        if index >= 2 {
            let incoming = anchors[index - 1].offset - anchors[index - 2].offset
            let incomingTime = max(0.001, anchors[index - 1].time - anchors[index - 2].time)
            incomingSlope = max(0, CGFloat(incoming) / CGFloat(incomingTime))
        } else {
            incomingSlope = currentSlope
        }

        let outgoingSlope: CGFloat
        if index + 1 < anchors.count {
            let outgoing = anchors[index + 1].offset - anchors[index].offset
            let outgoingTime = max(0.001, anchors[index + 1].time - anchors[index].time)
            outgoingSlope = max(0, CGFloat(outgoing) / CGFloat(outgoingTime))
        } else {
            outgoingSlope = currentSlope
        }

        let maxSlope = currentSlope * 2.85
        let slope0 = min(maxSlope, max(0, (incomingSlope + currentSlope) * 0.5))
        let slope1 = min(maxSlope, max(0, (currentSlope + outgoingSlope) * 0.5))
        let u = CGFloat(clamp((time - previous.time) / span, 0, 1))
        let u2 = u * u
        let u3 = u2 * u
        let h00 = 2 * u3 - 3 * u2 + 1
        let h10 = u3 - 2 * u2 + u
        let h01 = -2 * u3 + 3 * u2
        let h11 = u3 - u2
        let value = h00 * previous.offset
            + h10 * CGFloat(span) * slope0
            + h01 * next.offset
            + h11 * CGFloat(span) * slope1
        return min(max(previous.offset, value), next.offset)
    }

    private func applyEdgeFade(in context: CGContext) {
        let fade = min(max(0, fadeEdgeWidth), bounds.width / 3)
        guard fade > 1 else { return }

        let gradients: (left: CGGradient, right: CGGradient)
        if let cached = edgeFadeGradients {
            gradients = cached
        } else {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard
                let leftGradient = CGGradient(
                    colorsSpace: colorSpace,
                    colors: [
                        NSColor.black.withAlphaComponent(0.88).cgColor,
                        NSColor.black.withAlphaComponent(0.0).cgColor
                    ] as CFArray,
                    locations: [0, 1]
                ),
                let rightGradient = CGGradient(
                    colorsSpace: colorSpace,
                    colors: [
                        NSColor.black.withAlphaComponent(0.0).cgColor,
                        NSColor.black.withAlphaComponent(0.88).cgColor
                    ] as CFArray,
                    locations: [0, 1]
                )
            else {
                return
            }
            gradients = (leftGradient, rightGradient)
            edgeFadeGradients = gradients
        }

        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.drawLinearGradient(
            gradients.left,
            start: CGPoint(x: bounds.minX, y: bounds.midY),
            end: CGPoint(x: bounds.minX + fade, y: bounds.midY),
            options: []
        )
        context.drawLinearGradient(
            gradients.right,
            start: CGPoint(x: bounds.maxX - fade, y: bounds.midY),
            end: CGPoint(x: bounds.maxX, y: bounds.midY),
            options: []
        )
        context.restoreGState()
    }

    private func isSilencePlaceholderText(_ text: String) -> Bool {
        let compact = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return false }
        return compact.allSatisfy { $0 == "." || $0 == "…" || $0 == "⋯" }
    }

    private func mix(_ a: CFTimeInterval, _ b: CFTimeInterval, _ amount: CFTimeInterval) -> CFTimeInterval {
        let t = clamp(amount, 0, 1)
        return a + (b - a) * t
    }

    private func clamp(_ value: CFTimeInterval, _ lower: CFTimeInterval, _ upper: CFTimeInterval) -> CFTimeInterval {
        min(max(value, lower), upper)
    }

    private func pixelAligned(_ value: CGFloat) -> CGFloat {
        let scale = max(1, layer?.contentsScale ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        return (value * scale).rounded() / scale
    }

    private func smoothstepIntegral(_ value: CFTimeInterval) -> CFTimeInterval {
        let t = clamp(value, 0, 1)
        // Integral of smootherstep velocity: 6t^5 - 15t^4 + 10t^3.
        // The integral equals 0.5 at t = 1, which keeps the symmetric ramp math simple.
        let t2 = t * t
        let t4 = t2 * t2
        let t5 = t4 * t
        let t6 = t5 * t
        return t6 - 3 * t5 + 2.5 * t4
    }

    private func smootherStep(_ value: CFTimeInterval) -> CFTimeInterval {
        let t = clamp(value, 0, 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    private func easeOutCubic(_ value: CFTimeInterval) -> CFTimeInterval {
        let t = clamp(value, 0, 1)
        let p = 1 - t
        return 1 - p * p * p
    }
}

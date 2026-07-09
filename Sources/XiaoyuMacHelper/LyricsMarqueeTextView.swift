import AppKit
import QuartzCore

@MainActor
private final class LyricsMarqueeDisplayLinkTarget: NSObject {
    weak var view: LyricsMarqueeTextView?

    init(view: LyricsMarqueeTextView) {
        self.view = view
    }

    @objc func displayLinkDidFire(_ link: CADisplayLink) {
        view?.displayLinkDidFire(link)
    }
}

/// High-refresh text renderer used by desktop lyrics and compact lyrics surfaces.
///
/// The view does not advance text by accumulating pixels from a Timer. Instead, each frame is
/// derived from an absolute timeline. That keeps the motion stable even when now-playing polling
/// jitters slightly, and it lets timed lyrics finish revealing before the next line arrives.
@MainActor
final class LyricsMarqueeTextView: NSView {
    enum ScrollStyle {
        case hold
        case revealAndReturn
    }

    var stringValue: String = "" {
        didSet {
            guard oldValue != stringValue else { return }
            resetForNewText()
        }
    }

    var font: NSFont = NSFont.systemFont(ofSize: 14, weight: .medium) {
        didSet {
            guard oldValue != font else { return }
            invalidateTextCache()
            resetForNewText()
        }
    }

    var textColor: NSColor = .labelColor {
        didSet {
            invalidateAttributedCache()
            needsDisplay = true
        }
    }

    var strokeColor: NSColor = .clear {
        didSet {
            invalidateAttributedCache()
            needsDisplay = true
        }
    }

    var strokeWidth: CGFloat = 0 {
        didSet {
            invalidateAttributedCache()
            needsDisplay = true
        }
    }

    var textShadow: NSShadow? {
        didSet {
            invalidateAttributedCache()
            needsDisplay = true
        }
    }

    var alignment: NSTextAlignment = .center {
        didSet { needsDisplay = true }
    }

    var scrollStyle: ScrollStyle = .revealAndReturn {
        didSet { updateAnimationState() }
    }

    /// Fallback speed for untimed text. Timed lyrics ignore this and follow the lyric line duration.
    var scrollSpeed: CGFloat = 42

    /// Initial reading hold for untimed text only.
    var marqueeStartDelay: CFTimeInterval = 0.85

    /// Tail hold for untimed text only.
    var marqueeEdgePause: CFTimeInterval = 0.55

    /// Fade-reset duration for untimed text only.
    var resetFadeDuration: CFTimeInterval = 0.20

    /// Soft text-edge fade while text is clipped.
    var fadeEdgeWidth: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    private enum UntimedPhase {
        case headHold
        case moving
        case tailHold
        case resetFade
    }

    private var activeDisplayLink: CADisplayLink?
    private var displayLinkTarget: LyricsMarqueeDisplayLinkTarget?
    private var fallbackTimer: Timer?

    private var cachedAttributedText: NSAttributedString?
    private var cachedTextSize: NSSize = .zero

    private var renderedOffset: CGFloat = 0
    private var renderedAlpha: CGFloat = 1
    private var lastFrameTimestamp: CFTimeInterval = CACurrentMediaTime()

    private var lineDuration: CFTimeInterval?
    private var elapsedAtSync: CFTimeInterval = 0
    private var syncedAt: CFTimeInterval = CACurrentMediaTime()
    private var timingIsFresh = false

    private var untimedPhase: UntimedPhase = .headHold
    private var untimedPhaseStartedAt: CFTimeInterval = CACurrentMediaTime()
    private var untimedResetSwapped = false

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
            updateAnimationState()
            needsDisplay = true
        }
    }

    func syncLineTiming(duration: TimeInterval?, elapsed: TimeInterval) {
        let now = CACurrentMediaTime()
        let normalizedDuration = normalizedLineDuration(duration)
        let normalizedElapsed = normalizedDuration.map { min(max(0, elapsed), $0) } ?? max(0, elapsed)

        guard let duration = normalizedDuration else {
            if lineDuration != nil || timingIsFresh {
                lineDuration = nil
                elapsedAtSync = normalizedElapsed
                syncedAt = now
                timingIsFresh = false
                updateAnimationState()
            }
            return
        }

        if shouldHardResync(duration: duration, elapsed: normalizedElapsed, now: now) {
            lineDuration = duration
            elapsedAtSync = normalizedElapsed
            syncedAt = now
            timingIsFresh = true
            updateAnimationState()
            return
        }

        // Now-playing samples may jitter by a few hundred milliseconds. Do not restart or snap the
        // text for that; only blend larger drift back into the absolute time base.
        let predicted = predictedElapsed(now: now, duration: duration)
        let drift = normalizedElapsed - predicted
        if abs(drift) > 0.38 {
            let correctionStrength: CFTimeInterval = abs(drift) > 1.15 ? 0.62 : 0.18
            elapsedAtSync = min(max(0, predicted + drift * correctionStrength), duration)
            syncedAt = now
        }
        lineDuration = duration
        timingIsFresh = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !stringValue.isEmpty, bounds.width > 2, bounds.height > 2 else { return }

        let attributed = attributedString()
        let textSize = measuredTextSize(for: attributed)
        let shouldMove = shouldAnimate(textWidth: textSize.width)
        let x = drawingOriginX(textWidth: textSize.width, shouldMove: shouldMove)
        let y = floor((bounds.height - textSize.height) / 2)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()

        if let context = NSGraphicsContext.current?.cgContext {
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            if renderedAlpha < 0.999 {
                context.setAlpha(renderedAlpha)
            }
            attributed.draw(at: NSPoint(x: x, y: y))
            if shouldMove {
                applyEdgeFade(in: context)
            }
            context.endTransparencyLayer()
        } else {
            attributed.draw(at: NSPoint(x: x, y: y))
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func updateLayerScale() {
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func normalizedLineDuration(_ value: TimeInterval?) -> CFTimeInterval? {
        guard let value, value.isFinite, value > 0.38 else { return nil }
        return min(45.0, max(0.50, value))
    }

    private func shouldHardResync(duration: CFTimeInterval, elapsed: CFTimeInterval, now: CFTimeInterval) -> Bool {
        guard let oldDuration = lineDuration, timingIsFresh else { return true }
        if abs(oldDuration - duration) > 0.18 { return true }

        let predicted = predictedElapsed(now: now, duration: duration)
        if elapsed + 0.16 < predicted { return true }
        if abs(elapsed - predicted) > 1.75 { return true }
        return false
    }

    private func predictedElapsed(now: CFTimeInterval, duration: CFTimeInterval) -> CFTimeInterval {
        min(max(0, elapsedAtSync + now - syncedAt), duration)
    }

    private func attributedString() -> NSAttributedString {
        if let cachedAttributedText { return cachedAttributedText }

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

        let value = NSAttributedString(string: stringValue, attributes: attributes)
        cachedAttributedText = value
        return value
    }

    private func measuredTextSize(for attributed: NSAttributedString) -> NSSize {
        if cachedTextSize == .zero {
            let size = attributed.size()
            cachedTextSize = NSSize(width: ceil(size.width + 1), height: ceil(size.height))
        }
        return cachedTextSize
    }

    private func invalidateAttributedCache() {
        cachedAttributedText = nil
    }

    private func invalidateTextCache() {
        cachedAttributedText = nil
        cachedTextSize = .zero
    }

    private func currentTextWidth() -> CGFloat {
        measuredTextSize(for: attributedString()).width
    }

    private func shouldAnimate(textWidth: CGFloat) -> Bool {
        scrollStyle != .hold && bounds.width > 2 && textWidth > bounds.width + 8
    }

    private func drawingOriginX(textWidth: CGFloat, shouldMove: Bool) -> CGFloat {
        guard shouldMove else {
            renderedOffset = 0
            switch alignment {
            case .left, .natural, .justified:
                return 0
            case .right:
                return max(0, bounds.width - textWidth)
            default:
                return max(0, floor((bounds.width - textWidth) / 2))
            }
        }
        return -renderedOffset
    }

    private func resetForNewText() {
        invalidateTextCache()
        renderedOffset = 0
        renderedAlpha = 1
        lineDuration = nil
        elapsedAtSync = 0
        syncedAt = CACurrentMediaTime()
        timingIsFresh = false
        untimedPhase = .headHold
        untimedPhaseStartedAt = syncedAt
        untimedResetSwapped = false
        lastFrameTimestamp = syncedAt
        needsDisplay = true
        updateAnimationState()
    }

    private func updateAnimationState() {
        guard window != nil else {
            stopDisplayDriver()
            return
        }

        let textWidth = currentTextWidth()
        if shouldAnimate(textWidth: textWidth) && !stringValue.isEmpty {
            startDisplayDriverIfNeeded()
        } else {
            stopDisplayDriver()
            renderedOffset = 0
            renderedAlpha = 1
            untimedPhase = .headHold
        }
        needsDisplay = true
    }

    private func startDisplayDriverIfNeeded() {
        guard activeDisplayLink == nil, fallbackTimer == nil else { return }

        let target = LyricsMarqueeDisplayLinkTarget(view: self)
        let link = displayLink(target: target, selector: #selector(LyricsMarqueeDisplayLinkTarget.displayLinkDidFire(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = false
        displayLinkTarget = target
        activeDisplayLink = link
        lastFrameTimestamp = CACurrentMediaTime()
    }

    private func stopDisplayDriver() {
        activeDisplayLink?.invalidate()
        activeDisplayLink = nil
        displayLinkTarget = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    fileprivate func displayLinkDidFire(_ link: CADisplayLink) {
        let timestamp = link.targetTimestamp > 0 ? link.targetTimestamp : CACurrentMediaTime()
        renderFrame(at: timestamp)
    }

    private func renderFrame(at timestamp: CFTimeInterval) {
        let textWidth = currentTextWidth()
        let maxOffset = max(0, textWidth - bounds.width)
        guard maxOffset > 1, shouldAnimate(textWidth: textWidth) else {
            stopDisplayDriver()
            renderedOffset = 0
            renderedAlpha = 1
            needsDisplay = true
            return
        }

        if let duration = lineDuration, timingIsFresh {
            renderTimedFrame(at: timestamp, duration: duration, maxOffset: maxOffset)
        } else {
            renderUntimedFrame(at: timestamp, maxOffset: maxOffset)
        }

        lastFrameTimestamp = timestamp
        needsDisplay = true
    }

    private struct TimedScrollPlan {
        var startDelay: CFTimeInterval
        var travelDuration: CFTimeInterval
        var targetOffset: CGFloat

        var travelEnd: CFTimeInterval { startDelay + travelDuration }
    }

    private func renderTimedFrame(at timestamp: CFTimeInterval, duration: CFTimeInterval, maxOffset: CGFloat) {
        let elapsed = predictedElapsed(now: timestamp, duration: duration)
        let plan = timedScrollPlan(duration: duration, maxOffset: maxOffset)
        let progress = clamp(elapsed / max(0.001, plan.travelDuration), 0, 1)

        renderedAlpha = 1
        guard plan.targetOffset > 1 else {
            renderedOffset = 0
            return
        }

        renderedOffset = plan.targetOffset * CGFloat(formulaTimelineProgress(progress, rampFraction: 0.055))
    }

    private func timedScrollPlan(duration: CFTimeInterval, maxOffset: CGFloat) -> TimedScrollPlan {
        TimedScrollPlan(
            startDelay: 0,
            travelDuration: clamp(duration, 0.14, 45.0),
            targetOffset: maxOffset
        )
    }

    private func renderUntimedFrame(at timestamp: CFTimeInterval, maxOffset: CGFloat) {
        let elapsed = timestamp - untimedPhaseStartedAt
        let travelDuration = max(1.25, CFTimeInterval(maxOffset / max(18, scrollSpeed)))

        switch untimedPhase {
        case .headHold:
            renderedOffset = 0
            renderedAlpha = 1
            if elapsed >= marqueeStartDelay {
                untimedPhase = .moving
                untimedPhaseStartedAt = timestamp
            }
        case .moving:
            let progress = min(1, max(0, elapsed / travelDuration))
            renderedOffset = maxOffset * CGFloat(smootherStep(progress))
            renderedAlpha = 1
            if progress >= 1 {
                renderedOffset = maxOffset
                untimedPhase = .tailHold
                untimedPhaseStartedAt = timestamp
            }
        case .tailHold:
            renderedOffset = maxOffset
            renderedAlpha = 1
            if elapsed >= marqueeEdgePause {
                untimedPhase = .resetFade
                untimedPhaseStartedAt = timestamp
                untimedResetSwapped = false
            }
        case .resetFade:
            let duration = max(0.12, resetFadeDuration)
            let progress = min(1, max(0, elapsed / duration))
            if progress >= 0.5, !untimedResetSwapped {
                renderedOffset = 0
                untimedResetSwapped = true
            }
            if progress < 0.5 {
                renderedAlpha = CGFloat(1 - easeOutCubic(progress * 2))
            } else {
                renderedAlpha = CGFloat(easeOutCubic((progress - 0.5) * 2))
            }
            if progress >= 1 {
                renderedOffset = 0
                renderedAlpha = 1
                untimedPhase = .headHold
                untimedPhaseStartedAt = timestamp
                untimedResetSwapped = false
            }
        }
    }

    private func applyEdgeFade(in context: CGContext) {
        let fade = min(max(0, fadeEdgeWidth), bounds.width / 3)
        guard fade > 1 else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let leftGradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [
                    NSColor.black.withAlphaComponent(0.90).cgColor,
                    NSColor.black.withAlphaComponent(0.0).cgColor
                ] as CFArray,
                locations: [0, 1]
            ),
            let rightGradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [
                    NSColor.black.withAlphaComponent(0.0).cgColor,
                    NSColor.black.withAlphaComponent(0.90).cgColor
                ] as CFArray,
                locations: [0, 1]
            )
        else {
            return
        }

        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.drawLinearGradient(
            leftGradient,
            start: CGPoint(x: bounds.minX, y: bounds.midY),
            end: CGPoint(x: bounds.minX + fade, y: bounds.midY),
            options: []
        )
        context.drawLinearGradient(
            rightGradient,
            start: CGPoint(x: bounds.maxX - fade, y: bounds.midY),
            end: CGPoint(x: bounds.maxX, y: bounds.midY),
            options: []
        )
        context.restoreGState()
    }

    private func adaptiveScrollEase(_ value: CFTimeInterval) -> CFTimeInterval {
        formulaTimelineProgress(value, rampFraction: 0.055)
    }

    private func formulaTimelineProgress(_ value: CFTimeInterval, rampFraction: CFTimeInterval) -> CFTimeInterval {
        let t = clamp(value, 0, 1)
        let ramp = clamp(rampFraction, 0.018, 0.20)
        let totalArea = max(0.001, 1 - ramp)
        if t < ramp {
            let u = t / ramp
            return ramp * smoothstepIntegral(u) / totalArea
        }
        if t > 1 - ramp {
            let u = (t - (1 - ramp)) / ramp
            let beforeTail = 0.5 * ramp + (1 - 2 * ramp)
            let tailArea = ramp * (u - smoothstepIntegral(u))
            return (beforeTail + tailArea) / totalArea
        }
        return (0.5 * ramp + (t - ramp)) / totalArea
    }

    private func clamp(_ value: CFTimeInterval, _ lower: CFTimeInterval, _ upper: CFTimeInterval) -> CFTimeInterval {
        min(max(value, lower), upper)
    }

    private func smoothstepIntegral(_ value: CFTimeInterval) -> CFTimeInterval {
        let t = min(1, max(0, value))
        let t2 = t * t
        let t4 = t2 * t2
        let t5 = t4 * t
        let t6 = t5 * t
        return t6 - 3 * t5 + 2.5 * t4
    }

    private func smootherStep(_ value: CFTimeInterval) -> CFTimeInterval {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    private func easeOutCubic(_ value: CFTimeInterval) -> CFTimeInterval {
        let t = min(1, max(0, value))
        let p = 1 - t
        return 1 - p * p * p
    }
}

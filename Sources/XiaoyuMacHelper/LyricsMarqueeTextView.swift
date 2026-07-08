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

        renderedAlpha = 1

        guard plan.targetOffset > 1, plan.travelDuration > 0.05 else {
            renderedOffset = 0
            return
        }

        if elapsed <= plan.startDelay {
            renderedOffset = 0
            return
        }

        if elapsed >= plan.travelEnd {
            renderedOffset = plan.targetOffset
            return
        }

        let progress = (elapsed - plan.startDelay) / plan.travelDuration
        renderedOffset = plan.targetOffset * CGFloat(adaptiveScrollEase(progress))
    }

    private func timedScrollPlan(duration: CFTimeInterval, maxOffset: CGFloat) -> TimedScrollPlan {
        let visibleWidth = max(1, bounds.width)
        let overflowRatio = CFTimeInterval(min(3.0, maxOffset / visibleWidth))
        let fontSize = CFTimeInterval(max(12, font.pointSize))
        let textLength = CFTimeInterval(max(1, stringValue.count))
        let complexity = min(1.35, max(0.55, textLength / 34.0))

        // Mainstream desktop lyrics should feel readable first and mechanical second:
        // 1. choose a comfortable natural speed from font size + overflow pressure;
        // 2. finish early when the line has enough time;
        // 3. only compress the holds / speed up when the line is short;
        // 4. never force extreme speed just to hit the very end before the next lyric.
        let comfortableSpeed = clamp(
            fontSize * (0.95 + 0.16 * complexity) + 14.0 + overflowRatio * 12.0,
            34.0,
            92.0
        )
        let maximumReadableSpeed = clamp(comfortableSpeed * 1.72, 62.0, 148.0)

        let normalHeadHold = clamp(
            0.42 + duration * 0.08 - overflowRatio * 0.12,
            0.18,
            min(1.05, duration * 0.26)
        )
        let normalTailHold = clamp(
            0.24 + duration * 0.055,
            0.16,
            min(0.82, duration * 0.20)
        )
        let naturalTravelDuration = CFTimeInterval(maxOffset) / comfortableSpeed
        let naturalAvailable = max(0.08, duration - normalHeadHold - normalTailHold)

        if naturalTravelDuration <= naturalAvailable {
            return TimedScrollPlan(
                startDelay: normalHeadHold,
                travelDuration: max(0.12, naturalTravelDuration),
                targetOffset: maxOffset
            )
        }

        let compressedHeadHold = clamp(duration * (0.055 + 0.025 / max(0.7, overflowRatio + 0.5)), 0.08, 0.40)
        let compressedTailHold = clamp(duration * 0.045, 0.06, 0.24)
        let compressedAvailable = max(0.10, duration - compressedHeadHold - compressedTailHold)
        let requiredSpeed = CFTimeInterval(maxOffset) / compressedAvailable

        if requiredSpeed <= maximumReadableSpeed {
            return TimedScrollPlan(
                startDelay: compressedHeadHold,
                travelDuration: compressedAvailable,
                targetOffset: maxOffset
            )
        }

        // For extremely long text in a short lyric line, forcing the end would look like a stock
        // ticker. Move only as much as can be read naturally, prioritizing smoothness over a rushed
        // full reveal. Long enough future lines will still reveal fully by the branch above.
        let readableOffset = CGFloat(maximumReadableSpeed * compressedAvailable)
        let targetOffset = min(maxOffset, max(maxOffset * 0.42, readableOffset))
        return TimedScrollPlan(
            startDelay: compressedHeadHold,
            travelDuration: compressedAvailable,
            targetOffset: min(maxOffset, targetOffset)
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
        let t = min(1, max(0, value))
        // Smooth but not sluggish: slower at the head for readability, a stable middle section,
        // then a soft landing at the tail. This avoids both linear ticker motion and late snapping.
        if t < 0.18 {
            return 0.18 * smootherStep(t / 0.18)
        }
        if t > 0.82 {
            return 0.82 + 0.18 * smootherStep((t - 0.82) / 0.18)
        }
        return t
    }

    private func clamp(_ value: CFTimeInterval, _ lower: CFTimeInterval, _ upper: CFTimeInterval) -> CFTimeInterval {
        min(max(value, lower), upper)
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

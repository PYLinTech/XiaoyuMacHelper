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
        var previousBucket: Int
        var nextBucket: Int
    }

    private struct TimedScrollPlan {
        var signature: ScrollPlanSignature
        var startDelay: CFTimeInterval
        var travelDuration: CFTimeInterval
        var tailHold: CFTimeInterval
        var targetOffset: CGFloat
        var rampFraction: CFTimeInterval
        var leadInOffset: CGFloat

        var travelEnd: CFTimeInterval { startDelay + travelDuration }
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
    private var cachedPlan: TimedScrollPlan?
    private var untimedState = UntimedState()
    private var untimedPausedAt: CFTimeInterval?

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
        isPlaying: Bool = true
    ) {
        let now = CACurrentMediaTime()
        let normalizedIdentity = normalizedIdentity(identity)
        let normalizedDuration = normalizedDuration(duration)
        let normalizedPrevious = normalizedNeighborDuration(previousDuration)
        let normalizedNext = normalizedNeighborDuration(nextDuration)
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
                invalidateScrollPlan()
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

        let attributed = attributedString()
        let textSize = measuredSize(for: attributed)
        let textRect = protectedTextRect()
        let maxOffset = max(0, textSize.width - textRect.width)
        let shouldScroll = maxOffset > 8
        let sample = renderSample(maxOffset: maxOffset, shouldScroll: shouldScroll)
        let x = drawingOriginX(textWidth: textSize.width, shouldScroll: shouldScroll, offset: sample.offset, textRect: textRect)
        let y = drawingOriginY(for: attributed, measuredSize: textSize)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()

        if let context = NSGraphicsContext.current?.cgContext {
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            if sample.alpha < 0.999 {
                context.setAlpha(sample.alpha)
            }
            attributed.draw(at: NSPoint(x: x, y: y))
            if shouldScroll {
                applyEdgeFade(in: context)
            }
            context.endTransparencyLayer()
        } else {
            attributed.draw(at: NSPoint(x: x, y: y))
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawingOriginY(for attributed: NSAttributedString, measuredSize: NSSize) -> CGFloat {
        guard usesTypographicVerticalCentering,
              attributed.length > 0,
              let effectiveFont = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        else {
            return floor((bounds.height - measuredSize.height) / 2)
        }

        // attributed.size() discards the vertical origin of the glyph box. When the font-size
        // slider changes, different fonts report different ascender/descender offsets, so only
        // centering by height makes the lyric look high or low. Center the actual typographic box.
        let textBounds = typographicBounds(for: attributed)
        let fontBounds = effectiveFont.boundingRectForFont
        let sourceBounds = textBounds.height > 0 ? textBounds : fontBounds
        return floor(bounds.midY - sourceBounds.midY)
    }

    private func renderSample(maxOffset: CGFloat, shouldScroll: Bool) -> (offset: CGFloat, alpha: CGFloat) {
        guard shouldScroll else { return (0, 1) }
        let now = CACurrentMediaTime()
        if let duration = timing.duration, timingIsFresh {
            let plan = scrollPlan(duration: duration, maxOffset: maxOffset)
            return (timedOffset(at: now, plan: plan), 1)
        }
        if timingIsPaused {
            return (untimedState.offset, untimedState.alpha)
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

        let attributed = NSAttributedString(string: stringValue, attributes: attributes)
        attributedCache = attributed
        return attributed
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

    private func resetLineState(keepsTiming: Bool) {
        untimedState = UntimedState(phase: .headHold, phaseStartedAt: CACurrentMediaTime(), resetSwapped: false, offset: 0, alpha: 1)
        cachedPlan = nil
        if !keepsTiming {
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
        if !timingIsPaused, !stringValue.isEmpty, bounds.width > 2, textWidth > textWidthLimit + 8 {
            startDisplayDriverIfNeeded()
        } else {
            stopDisplayDriver()
        }
        needsDisplay = true
    }

    private func startDisplayDriverIfNeeded() {
        guard activeDisplayLink == nil else { return }
        let target = DesktopLyricsDisplayLinkTarget(view: self)
        let link = displayLink(target: target, selector: #selector(DesktopLyricsDisplayLinkTarget.displayLinkDidFire(_:)))
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
        needsDisplay = true
    }

    private func protectedTextRect() -> NSRect {
        let inset = min(max(0, contentInsetX), max(0, bounds.width * 0.30))
        return bounds.insetBy(dx: inset, dy: 0)
    }

    private func drawingOriginX(textWidth: CGFloat, shouldScroll: Bool, offset: CGFloat, textRect: NSRect) -> CGFloat {
        guard shouldScroll else {
            switch alignment {
            case .left, .natural, .justified:
                return textRect.minX
            case .right:
                return max(textRect.minX, textRect.maxX - textWidth)
            default:
                return max(textRect.minX, floor(textRect.midX - textWidth / 2))
            }
        }
        return textRect.minX - offset
    }

    private func scrollPlan(duration: CFTimeInterval, maxOffset: CGFloat) -> TimedScrollPlan {
        let signature = currentSignature(duration: duration, maxOffset: maxOffset)
        if let cachedPlan, cachedPlan.signature == signature {
            return cachedPlan
        }

        let visibleWidth = max(1, protectedTextRect().width)
        let overflowRatio = clamp(CFTimeInterval(maxOffset / visibleWidth), 0.03, 6.0)
        let fontSize = CFTimeInterval(max(12, font.pointSize))
        let current = clamp(duration, 0.14, 42.0)
        let previous = timing.previousDuration ?? current
        let next = timing.nextDuration ?? current
        let rhythm = weightedRhythm(previous: previous, current: current, next: next)
        let characterCount = CFTimeInterval(max(1, stringValue.count))

        // Tempo/readability pressures.  The planner now treats tail hold as a real budget item,
        // not a leftover.  This prevents the old "arrived and instantly switched" feeling.
        let tempoPressure = clamp((2.35 - rhythm) / 1.55, 0, 1)
        let slowSection = clamp((rhythm - 3.70) / 4.60, 0, 1)
        let shortLinePressure = clamp((1.35 - current) / 0.95, 0, 1)
        let overflowPressure = clamp((overflowRatio - 0.20) / 1.70, 0, 1)
        let densityPressure = clamp((characterCount / max(0.42, current) - 7.0) / 17.0, 0, 1)
        let urgency = clamp(
            max(tempoPressure * 0.95, shortLinePressure, overflowPressure * 0.68, densityPressure * 0.72),
            0,
            1
        )

        // The parser may show the next line a tiny bit before its timestamp.  Account for that so
        // this line reaches the end and visibly rests before the visual switch happens.
        let switchReserve = clamp(current * 0.010, 0.002, 0.024)
        let usableDuration = max(0.080, current - switchReserve)

        // Readability speed is the preferred middle-section speed.  The deadline can force a
        // higher speed, but only after head hold has been compressed and a small tail rest has been
        // protected.
        let readableSpeed = clamp(
            fontSize * (1.18 + overflowRatio * 0.080)
                + 32.0
                + tempoPressure * 20.0
                + densityPressure * 18.0
                - slowSection * 7.0,
            52.0,
            154.0
        )

        // Head hold should be short and prepared; tail hold should be perceptible.  For very fast
        // lines the tail can be tiny, but it is still preserved before the next lyric appears.
        let relaxedHeadHold = clamp(current * (0.070 + slowSection * 0.018), 0.070, 0.320)
        let compactHeadHold = clamp(current * (0.012 + overflowPressure * 0.004), 0.003, 0.055)
        var headHold = mix(relaxedHeadHold, compactHeadHold, urgency)
        headHold = clamp(headHold - tempoPressure * 0.026 - overflowPressure * 0.016, 0.002, usableDuration * 0.24)

        let desiredTailHold = clamp(current * (0.115 + slowSection * 0.038), 0.145, 0.520)
        let compactTailHold = clamp(current * (0.060 - shortLinePressure * 0.018), 0.034, 0.125)
        var tailHold = mix(desiredTailHold, compactTailHold, urgency)
        tailHold = clamp(tailHold, 0.030, usableDuration * 0.40)

        // Reserve a little more tail for ordinary lines.  This is the direct fix for the perceived
        // haste: when there is enough time, arrive early and let the tail sit briefly.
        let naturalTravel = CFTimeInterval(maxOffset) / max(1, readableSpeed)
        let ordinaryLine = urgency < 0.72 && current > 1.25
        if ordinaryLine {
            let extraTail = min(usableDuration * 0.070, max(0, usableDuration - headHold - tailHold - naturalTravel) * 0.66)
            tailHold += max(0, extraTail)
        }

        // If the line is too short, preserve tail first, then reduce head hold.  Only after that do
        // we compress the tail.  The result is a scan that still lands before the visual switch.
        var travelBudget = usableDuration - headHold - tailHold
        if travelBudget < 0.055 {
            headHold = min(headHold, max(0.002, usableDuration * 0.040))
            travelBudget = usableDuration - headHold - tailHold
        }
        if travelBudget < 0.055 {
            let protectedTail = clamp(usableDuration * 0.075, 0.026, 0.080)
            tailHold = min(tailHold, protectedTail)
            travelBudget = usableDuration - headHold - tailHold
        }
        if travelBudget < 0.045 {
            headHold = max(0.001, usableDuration * 0.020)
            tailHold = max(0.012, usableDuration * 0.045)
            travelBudget = max(0.038, usableDuration - headHold - tailHold)
        }

        // Finish slightly before the computed deadline.  Normal/slow lines scroll at a readable
        // pace and may finish much earlier; fast lines use almost the full travel budget but still
        // keep the protected tail hold.
        let earlyFinishBias = clamp(0.090 + slowSection * 0.060 - urgency * 0.055, 0.020, 0.155)
        let preferredTravelCap = max(0.038, travelBudget * (1.0 - earlyFinishBias))
        let minimumTravel = clamp(0.095 + overflowPressure * 0.030 - shortLinePressure * 0.045, 0.040, 0.300)
        let travelDuration = clamp(naturalTravel, min(minimumTravel, preferredTravelCap), preferredTravelCap)

        // If naturalTravel is longer than the cap, clamp() above intentionally accelerates the
        // middle section.  The display remains smooth because the velocity envelope is continuous.
        let actualSpeed = CFTimeInterval(maxOffset) / max(0.001, travelDuration)
        let speedPressure = clamp((actualSpeed - readableSpeed) / max(1.0, readableSpeed * 2.2), 0, 1)
        let rampFraction = clamp(
            0.170
                + slowSection * 0.030
                - tempoPressure * 0.038
                - shortLinePressure * 0.046
                - speedPressure * 0.052,
            0.045,
            0.230
        )

        // If we gained spare time because natural scrolling was shorter than the cap, put most of
        // it after arrival instead of before departure.  This creates the desired "early arrive,
        // quiet tail, then next line" rhythm.
        let spare = max(0, travelBudget - travelDuration)
        let finalStartDelay = max(0.001, headHold + spare * 0.10)
        let finalTailHold = max(0.012, tailHold + spare * 0.82)

        let plan = TimedScrollPlan(
            signature: signature,
            startDelay: finalStartDelay,
            travelDuration: max(0.035, travelDuration),
            tailHold: finalTailHold,
            targetOffset: maxOffset,
            rampFraction: rampFraction,
            leadInOffset: 0
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
            previousBucket: bucket(timing.previousDuration ?? duration),
            nextBucket: bucket(timing.nextDuration ?? duration)
        )
    }

    private func bucket(_ value: CFTimeInterval) -> Int {
        Int((value * 5).rounded())
    }

    private func timedOffset(at timestamp: CFTimeInterval, plan: TimedScrollPlan) -> CGFloat {
        let elapsed = timing.elapsed(at: timestamp, isPaused: timingIsPaused)
        if elapsed <= plan.startDelay {
            // Keep the head hold truly still; the non-linear curve itself handles the soft start.
            let warmup = clamp(elapsed / max(0.001, plan.startDelay), 0, 1)
            return plan.leadInOffset * CGFloat(easeOutCubic(warmup))
        }
        if elapsed >= plan.travelEnd { return plan.targetOffset }
        let progress = clamp((elapsed - plan.startDelay) / max(0.001, plan.travelDuration), 0, 1)
        let curve = CGFloat(readableMotionCurve(progress, rampFraction: plan.rampFraction))
        let remainingDistance = max(0, plan.targetOffset - plan.leadInOffset)
        return plan.leadInOffset + remainingDistance * curve
    }

    private func untimedSample(at timestamp: CFTimeInterval, maxOffset: CGFloat) -> (offset: CGFloat, alpha: CGFloat) {
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
            untimedState.offset = maxOffset * CGFloat(readableMotionCurve(progress, rampFraction: 0.20))
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
        return (untimedState.offset, untimedState.alpha)
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

    private func readableMotionCurve(_ value: CFTimeInterval, rampFraction: CFTimeInterval) -> CFTimeInterval {
        let t = clamp(value, 0, 1)
        let ramp = clamp(rampFraction, 0.045, 0.42)
        guard ramp < 0.49 else { return smootherStep(t) }

        // Integrated minimum-jerk velocity envelope:
        // - velocity and acceleration ease in at the start,
        // - the middle stays almost constant for readable lyric motion,
        // - velocity and acceleration ease out before the protected tail hold.
        // This avoids both segmented linear jerk and the floating feel of a full-interval ease.
        let totalArea = 1 - ramp
        if t < ramp {
            let u = t / ramp
            return ramp * smoothstepIntegral(u) / totalArea
        }
        if t > 1 - ramp {
            let u = (1 - t) / ramp
            let tailArea = ramp * smoothstepIntegral(u)
            return 1 - tailArea / totalArea
        }
        return (0.5 * ramp + (t - ramp)) / totalArea
    }

    private func applyEdgeFade(in context: CGContext) {
        let fade = min(max(0, fadeEdgeWidth), bounds.width / 3)
        guard fade > 1 else { return }

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

    private func mix(_ a: CFTimeInterval, _ b: CFTimeInterval, _ amount: CFTimeInterval) -> CFTimeInterval {
        let t = clamp(amount, 0, 1)
        return a + (b - a) * t
    }

    private func clamp(_ value: CFTimeInterval, _ lower: CFTimeInterval, _ upper: CFTimeInterval) -> CFTimeInterval {
        min(max(value, lower), upper)
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

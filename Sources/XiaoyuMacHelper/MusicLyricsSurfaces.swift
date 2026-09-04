import AppKit
import QuartzCore

@MainActor
final class DynamicIslandLyricsWindow: FloatingOverlayPanel {
    private enum Metrics {
        static let defaultWidth: CGFloat = 900
        static let minWidth: CGFloat = 360
        static let maxWidth: CGFloat = 1700
        static let defaultHeight: CGFloat = 58
        static let minHeight: CGFloat = 32
        static let maxHeight: CGFloat = 180
        static let collapsedHeight: CGFloat = 22
        static let topBleed: CGFloat = 9
        static let sideInset: CGFloat = 42
        static let horizontalPadding: CGFloat = 22
        static let textGap: CGFloat = 20
        static let defaultBlankWidth: CGFloat = 210
        static let minBlankWidth: CGFloat = 60
        static let maxBlankWidth: CGFloat = 900
        static let defaultSlantRatio: CGFloat = 0.55
        static let defaultCornerRatio: CGFloat = 0.55
        static let minShapeRatio: CGFloat = 0.01
        static let maxShapeRatio: CGFloat = 1.0
        static let defaultFontSize: CGFloat = 15.0
        static let minFontSize: CGFloat = 11.0
        static let maxFontSize: CGFloat = 64.0
    }

    private final class DynamicContinentBackgroundView: NSView {
        var isHovering = false { didSet { needsDisplay = true } }
        var blankWidth: CGFloat = Metrics.defaultBlankWidth { didSet { needsDisplay = true } }
        var slantRatio: CGFloat = Metrics.defaultSlantRatio { didSet { needsDisplay = true } }
        var cornerRatio: CGFloat = Metrics.defaultCornerRatio { didSet { needsDisplay = true } }
        var onHoverChanged: ((Bool) -> Void)?
        private var trackingAreaRef: NSTrackingArea?

        override var isOpaque: Bool { false }

        override func updateTrackingAreas() {
            if let trackingAreaRef {
                removeTrackingArea(trackingAreaRef)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingAreaRef = area
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChanged?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChanged?(false)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard bounds.width > 10, bounds.height > 10 else { return }

            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = continentPath(in: rect)

            NSGraphicsContext.saveGraphicsState()
            path.addClip()

            let top = NSColor(calibratedWhite: isHovering ? 0.090 : 0.064, alpha: isHovering ? 0.992 : 0.975)
            let middle = NSColor(calibratedWhite: isHovering ? 0.036 : 0.026, alpha: isHovering ? 0.988 : 0.964)
            let bottom = NSColor(calibratedWhite: 0.000, alpha: isHovering ? 0.990 : 0.958)
            NSGradient(colors: [top, middle, bottom])?.draw(in: bounds, angle: -90)

            drawSubtleGlass(in: rect)

            NSGraphicsContext.restoreGraphicsState()
            drawStraightEdges(on: path, in: rect)
        }

        private func continentPath(in rect: NSRect) -> NSBezierPath {
            let topY = rect.maxY + Metrics.topBleed + 1
            let bottomY = rect.minY + 2
            let height = max(1, topY - bottomY)
            let rawSlant = min(Metrics.maxShapeRatio, max(Metrics.minShapeRatio, slantRatio))
            let rawCorner = min(Metrics.maxShapeRatio, max(Metrics.minShapeRatio, cornerRatio))

            // The silhouette now has two independent controls:
            // slantRatio changes only the side inward angle, while cornerRatio changes only the
            // lower transition radius/handles. This keeps strong rounding from unintentionally
            // narrowing the continent and lets a sharp shape still keep the requested side tilt.
            let slantT = rawSlant * rawSlant * (3 - 2 * rawSlant)
            let cornerT = rawCorner * rawCorner * (3 - 2 * rawCorner)
            let maxSlantInset = min(rect.width * 0.165, max(36, height * 1.42))
            let slantInset = maxSlantInset * slantT
            let cornerRadius = min(
                max(5.5, height * (0.11 + 0.35 * cornerT)),
                min(height * 0.50, rect.width * 0.12)
            )

            let bottomLeftX = rect.minX + slantInset
            let bottomRightX = rect.maxX - slantInset
            let bottomWidth = max(1, bottomRightX - bottomLeftX)
            let safeRadius = min(cornerRadius, bottomWidth * 0.42)
            let sideProgressAtCurve = max(0, (height - safeRadius) / height)

            let topLeft = NSPoint(x: rect.minX, y: topY)
            let topRight = NSPoint(x: rect.maxX, y: topY)
            let rightSideEnd = NSPoint(
                x: rect.maxX - slantInset * sideProgressAtCurve,
                y: bottomY + safeRadius
            )
            let rightBottomCornerEnd = NSPoint(
                x: bottomRightX - safeRadius,
                y: bottomY
            )
            let leftBottomCornerStart = NSPoint(
                x: bottomLeftX + safeRadius,
                y: bottomY
            )
            let leftSideEnd = NSPoint(
                x: rect.minX + slantInset * sideProgressAtCurve,
                y: bottomY + safeRadius
            )

            func normalized(_ point: NSPoint) -> NSPoint {
                let length = max(0.0001, hypot(point.x, point.y))
                return NSPoint(x: point.x / length, y: point.y / length)
            }

            let rightSideTangent = normalized(NSPoint(x: rightSideEnd.x - topRight.x, y: rightSideEnd.y - topRight.y))
            let leftSideTangent = normalized(NSPoint(x: topLeft.x - leftSideEnd.x, y: topLeft.y - leftSideEnd.y))
            let curveDistance = max(1, hypot(rightSideEnd.x - rightBottomCornerEnd.x, rightSideEnd.y - rightBottomCornerEnd.y))
            let sideHandle = curveDistance * (0.34 + 0.12 * cornerT)
            let bottomHandle = safeRadius * (0.62 + 0.34 * cornerT)

            let path = NSBezierPath()
            path.move(to: topLeft)
            path.line(to: topRight)
            path.line(to: rightSideEnd)
            path.curve(
                to: rightBottomCornerEnd,
                controlPoint1: NSPoint(
                    x: rightSideEnd.x + rightSideTangent.x * sideHandle,
                    y: rightSideEnd.y + rightSideTangent.y * sideHandle
                ),
                controlPoint2: NSPoint(
                    x: rightBottomCornerEnd.x + bottomHandle,
                    y: rightBottomCornerEnd.y
                )
            )
            path.line(to: leftBottomCornerStart)
            path.curve(
                to: leftSideEnd,
                controlPoint1: NSPoint(
                    x: leftBottomCornerStart.x - bottomHandle,
                    y: leftBottomCornerStart.y
                ),
                controlPoint2: NSPoint(
                    x: leftSideEnd.x - leftSideTangent.x * sideHandle,
                    y: leftSideEnd.y - leftSideTangent.y * sideHandle
                )
            )
            path.line(to: topLeft)
            path.close()
            return path
        }

        private func drawSubtleGlass(in rect: NSRect) {
            let shine = NSBezierPath()
            shine.move(to: NSPoint(x: rect.minX + Metrics.sideInset + 12, y: rect.maxY - 9))
            shine.line(to: NSPoint(x: rect.maxX - Metrics.sideInset - 12, y: rect.maxY - 9))
            NSColor.white.withAlphaComponent(isHovering ? 0.105 : 0.062).setStroke()
            shine.lineWidth = 0.8
            shine.stroke()

        }

        private func drawStraightEdges(on path: NSBezierPath, in rect: NSRect) {
            NSColor.white.withAlphaComponent(isHovering ? 0.14 : 0.085).setStroke()
            path.lineWidth = 0.8
            path.stroke()
        }
    }

    @MainActor
    private final class CircularSpectrumIconView: NSView, DisplayLinkResponding {
        var isActive: Bool = false {
            didSet {
                guard oldValue != isActive else { return }
                if isActive {
                    startDisplayDriverIfNeeded()
                } else {
                    for index in 0..<barCount {
                        targetLevels[index] = idleLevel
                    }
                }
                needsDisplay = true
            }
        }

        var accentColor: NSColor = NSColor.white.withAlphaComponent(0.88) {
            didSet { needsDisplay = true }
        }

        private let barCount = 7
        private let idleLevel: CGFloat = 0.018
        private var visualLevels: [CGFloat]
        private var targetLevels: [CGFloat]
        private var activeDisplayLink: CADisplayLink?
        private var displayLinkTarget: DisplayLinkTarget<CircularSpectrumIconView>?
        private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
        private var lastRealAudioTime: CFTimeInterval = 0
        private var hasReceivedRealAudio = false

        override var isOpaque: Bool { false }

        override init(frame frameRect: NSRect) {
            let initial = Array(repeating: CGFloat(0.024), count: 7)
            visualLevels = initial
            targetLevels = initial
            super.init(frame: frameRect)
            commonInit()
        }

        required init?(coder: NSCoder) {
            let initial = Array(repeating: CGFloat(0.024), count: 7)
            visualLevels = initial
            targetLevels = initial
            super.init(coder: coder)
            commonInit()
        }

        private func commonInit() {
            wantsLayer = true
            layer?.masksToBounds = false
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
            layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            if isActive {
                startDisplayDriverIfNeeded()
            }
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            needsDisplay = true
        }

        override func removeFromSuperview() {
            stopDisplayDriver()
            super.removeFromSuperview()
        }

        func setAudioLevels(_ incomingLevels: [CGFloat]) {
            guard !incomingLevels.isEmpty else { return }
            hasReceivedRealAudio = true
            lastRealAudioTime = CACurrentMediaTime()

            let mappedLevels = remapToBars(incomingLevels)
            for index in 0..<barCount {
                let incoming = index < mappedLevels.count ? mappedLevels[index] : idleLevel
                let value = min(0.88, max(idleLevel, incoming))
                // The analyzer already performs AGC and musical shaping.  Keep a
                // small amount of target smoothing only to remove one-frame spikes;
                // do not amplify again in the view layer.
                let blend: CGFloat = value > targetLevels[index] ? 0.82 : 0.48
                targetLevels[index] += (value - targetLevels[index]) * blend
            }
            if isActive {
                startDisplayDriverIfNeeded()
            }
            needsDisplay = true
        }

        private func remapToBars(_ levels: [CGFloat]) -> [CGFloat] {
            let normalized = levels.map { min(1.0, max(0.0, $0)) }
            if normalized.count == barCount {
                return normalized
            }

            var result: [CGFloat] = []
            result.reserveCapacity(barCount)
            for index in 0..<barCount {
                let sourcePosition = CGFloat(index) * CGFloat(max(0, normalized.count - 1)) / CGFloat(max(1, barCount - 1))
                let lower = max(0, min(normalized.count - 1, Int(floor(sourcePosition))))
                let upper = max(0, min(normalized.count - 1, lower + 1))
                let fraction = sourcePosition - CGFloat(lower)
                let lowerValue = normalized[lower]
                let upperValue = normalized[upper]
                result.append(lowerValue + (upperValue - lowerValue) * fraction)
            }
            return result
        }

        func displayLinkDidFire(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            let dt = min(1.0 / 24.0, max(1.0 / 240.0, now - lastFrameTime))
            lastFrameTime = now
            advance(now: now, dt: CGFloat(dt))
            needsDisplay = true
        }

        private func advance(now: CFTimeInterval, dt: CGFloat) {
            if !isActive || now - lastRealAudioTime > 0.55 {
                for index in 0..<barCount {
                    targetLevels[index] = idleLevel
                }
            }

            var hasVisibleMotion = false
            for index in 0..<barCount {
                let target = targetLevels[index]
                let attack: CGFloat = 54.0
                let release: CGFloat = 10.5 + CGFloat(index % 3) * 0.90
                let rate = target > visualLevels[index] ? attack : release
                let blend = 1.0 - exp(-dt * rate)
                visualLevels[index] += (target - visualLevels[index]) * blend
                if visualLevels[index] > idleLevel + 0.012 || abs(target - visualLevels[index]) > 0.006 {
                    hasVisibleMotion = true
                }
            }

            if !hasVisibleMotion, !isActive {
                stopDisplayDriver()
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard bounds.width > 4, bounds.height > 4 else { return }

            let side = min(bounds.width, bounds.height)
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            let radius = side * 0.48
            let circleRect = NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let circle = NSBezierPath(ovalIn: circleRect)
            let activeAlpha: CGFloat = hasReceivedRealAudio ? 1.0 : 0.42

            NSGraphicsContext.saveGraphicsState()
            circle.addClip()
            let top = NSColor.white.withAlphaComponent(0.026 + 0.020 * activeAlpha)
            let bottom = NSColor.black.withAlphaComponent(0.050 + 0.040 * activeAlpha)
            NSGradient(colors: [top, bottom])?.draw(in: circleRect, angle: -90)

            let barArea = circleRect.insetBy(dx: side * 0.180, dy: side * 0.155)
            guard barArea.width > 4, barArea.height > 4 else {
                NSGraphicsContext.restoreGraphicsState()
                return
            }
            let count = CGFloat(barCount)
            let barWidth = max(2.2, min(side * 0.102, barArea.width / (count * 1.46)))
            let gap = barCount > 1 ? max(1.0, (barArea.width - barWidth * count) / CGFloat(barCount - 1)) : 0
            let minHeight = max(2.2, side * 0.060)
            let maxHeight = max(minHeight + 1, barArea.height)
            let centerY = barArea.midY
            for index in 0..<barCount {
                let level = min(1, max(0, visualLevels[index]))
                let visualLevel = min(1.0, smoothVisualLevel(level))
                let height = minHeight + (maxHeight - minHeight) * visualLevel
                let x = barArea.minX + CGFloat(index) * (barWidth + gap)
                let y = centerY - height / 2
                let rect = NSRect(x: x, y: y, width: barWidth, height: height)
                let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
                accentColor.withAlphaComponent(0.20 + 0.78 * visualLevel).setFill()
                path.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        private func smoothVisualLevel(_ value: CGFloat) -> CGFloat {
            let t = min(1, max(0, value))
            // Keep mid-level motion visible, but avoid forcing every bar to full height.
            return t * t * (3.0 - 2.0 * t)
        }

        private func startDisplayDriverIfNeeded() {
            guard activeDisplayLink == nil, window != nil else { return }
            lastFrameTime = CACurrentMediaTime()
            let target = DisplayLinkTarget(view: self)
            let link = displayLink(target: target, selector: #selector(DisplayLinkTarget<CircularSpectrumIconView>.displayLinkDidFire(_:)))
            // 频谱动画 60fps 足够；不设上限时 ProMotion 屏会跑 120fps，功耗翻倍。
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
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
    }

    @MainActor
    private final class TitleTickerTextView: NSView, DisplayLinkResponding {
        var stringValue: String = "" {
            didSet {
                guard oldValue != stringValue else { return }
                attributedCache = nil
                measuredTextSize = .zero
                measuredTypographicBounds = .zero
                cycleStartedAt = CACurrentMediaTime()
                updateAnimationState()
            }
        }

        var font: NSFont = NSFont.systemFont(ofSize: 12.5, weight: .medium) {
            didSet {
                guard oldValue != font else { return }
                attributedCache = nil
                measuredTextSize = .zero
                measuredTypographicBounds = .zero
                updateAnimationState()
            }
        }

        var textColor: NSColor = NSColor.white.withAlphaComponent(0.72) {
            didSet {
                attributedCache = nil
                needsDisplay = true
            }
        }

        var scrollSpeed: CGFloat = 26 {
            didSet { needsDisplay = true }
        }

        var fadeEdgeWidth: CGFloat = 12 {
            didSet { needsDisplay = true }
        }

        var contentInsetX: CGFloat = 0 {
            didSet {
                guard oldValue != contentInsetX else { return }
                updateAnimationState()
                needsDisplay = true
            }
        }

        private var activeDisplayLink: CADisplayLink?
        private var displayLinkTarget: DisplayLinkTarget<TitleTickerTextView>?
        private var attributedCache: NSAttributedString?
        private var measuredTextSize: NSSize = .zero
        private var measuredTypographicBounds: NSRect = .zero
        private var cycleStartedAt: CFTimeInterval = CACurrentMediaTime()

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
            layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            updateAnimationState()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            needsDisplay = true
        }

        override func removeFromSuperview() {
            stopDisplayDriver()
            super.removeFromSuperview()
        }

        override func setFrameSize(_ newSize: NSSize) {
            let old = frame.size
            super.setFrameSize(newSize)
            if abs(old.width - newSize.width) > 0.5 || abs(old.height - newSize.height) > 0.5 {
                cycleStartedAt = CACurrentMediaTime()
                updateAnimationState()
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard !stringValue.isEmpty, bounds.width > 2, bounds.height > 2 else { return }

            let attributed = attributedString()
            let textSize = measuredSize(for: attributed)
            let textRect = protectedTextRect()
            let y = drawingOriginY(for: attributed, measuredSize: textSize)
            let shouldScroll = textSize.width > textRect.width + 8

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: bounds).addClip()
            if let context = NSGraphicsContext.current?.cgContext {
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                if shouldScroll {
                    let gap = max(42, textRect.width * 0.25)
                    let cycle = max(1, textSize.width + gap)
                    let elapsed = max(0, CACurrentMediaTime() - cycleStartedAt)
                    let offset = CGFloat((elapsed * CFTimeInterval(scrollSpeed)).truncatingRemainder(dividingBy: CFTimeInterval(cycle)))
                    attributed.draw(at: NSPoint(x: textRect.minX - offset, y: y))
                    attributed.draw(at: NSPoint(x: textRect.minX - offset + cycle, y: y))
                    applyEdgeFade(in: context)
                } else {
                    attributed.draw(at: NSPoint(x: textRect.minX, y: y))
                }
                context.endTransparencyLayer()
            } else {
                attributed.draw(at: NSPoint(x: textRect.minX, y: y))
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        private func drawingOriginY(for attributed: NSAttributedString, measuredSize: NSSize) -> CGFloat {
            guard attributed.length > 0,
                  let effectiveFont = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            else {
                return floor((bounds.height - measuredSize.height) / 2)
            }

            // Keep the song-title ticker vertically anchored by the typographic bounds, not just
            // the reported height. This prevents visible drifting when 灵动大陆 font size or family
            // changes because ascender/descender offsets are compensated.
            let textBounds = typographicBounds(for: attributed)
            let fontBounds = effectiveFont.boundingRectForFont
            let sourceBounds = textBounds.height > 0 ? textBounds : fontBounds
            return floor(bounds.midY - sourceBounds.midY)
        }

        private func attributedString() -> NSAttributedString {
            if let attributedCache { return attributedCache }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byClipping
            let attributed = NSAttributedString(
                string: stringValue,
                attributes: [
                    .font: font,
                    .foregroundColor: textColor,
                    .paragraphStyle: paragraph
                ]
            )
            attributedCache = attributed
            return attributed
        }

        private func measuredSize(for attributed: NSAttributedString) -> NSSize {
            if measuredTextSize != .zero { return measuredTextSize }
            measuredTextSize = typographicBounds(for: attributed).integral.size
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

        private func updateAnimationState() {
            // 隐藏（orderOut）后 window 仍非 nil：必须以可见性判定，
            // 否则标题滚动 display link 在窗口隐藏后持续 60fps 空转。
            guard window?.isVisible == true else {
                stopDisplayDriver()
                return
            }
            let shouldScroll = measuredSize(for: attributedString()).width > protectedTextRect().width + 8
            if shouldScroll {
                startDisplayDriverIfNeeded()
            } else {
                stopDisplayDriver()
            }
            needsDisplay = true
        }

        private func startDisplayDriverIfNeeded() {
            guard activeDisplayLink == nil else { return }
            let target = DisplayLinkTarget(view: self)
            let link = displayLink(target: target, selector: #selector(DisplayLinkTarget<TitleTickerTextView>.displayLinkDidFire(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
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
            // 自愈：窗口不可见时主动停驱动，防止 orderOut 后 link 残留空转。
            guard window?.isVisible == true else {
                stopDisplayDriver()
                return
            }
            needsDisplay = true
        }

        /// 供宿主窗口上屏后补调：首次 show 时文本先于 orderFront 赋值，
        /// didSet 里的 updateAnimationState 会因窗口尚不可见而拒绝启动滚动，
        /// 需要在 orderFront 之后重估一次（与 LineView 靠轮询自愈不同，本视图
        /// 只在文本/字体/尺寸变化时重估，错过即静置到下一次文本变化）。
        func refreshAnimationState() {
            updateAnimationState()
        }

        private func protectedTextRect() -> NSRect {
            let inset = min(max(0, contentInsetX), max(0, bounds.width * 0.30))
            return bounds.insetBy(dx: inset, dy: 0)
        }

        private func applyEdgeFade(in context: CGContext) {
            let fade = min(max(0, fadeEdgeWidth), bounds.width / 3)
            guard fade > 1 else { return }
            guard let gradients = EdgeFadeRenderer.makeGradients(peakAlpha: 0.82) else { return }
            EdgeFadeRenderer.apply(in: context, bounds: bounds, fade: fade, gradients: gradients)
        }
    }

    private final class PassthroughContentView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private let rootView = NSView(frame: NSRect(x: 0, y: 0, width: Metrics.defaultWidth, height: Metrics.defaultHeight))
    private let continentView = DynamicContinentBackgroundView()
    private let textContainerView = PassthroughContentView(frame: .zero)
    private let spectrumView = CircularSpectrumIconView(frame: .zero)
    private let audioSpectrumMonitor = SystemAudioSpectrumMonitor()
    private let titleLabel = TitleTickerTextView(frame: .zero)
    private let lyricLabel = DesktopLyricsLineView(frame: .zero)
    private var configuredWidth: CGFloat = Metrics.defaultWidth
    private var configuredBlankWidth: CGFloat = Metrics.defaultBlankWidth
    private var configuredHeight: CGFloat = Metrics.defaultHeight
    private var configuredSlantRatio: CGFloat = Metrics.defaultSlantRatio
    private var configuredCornerRatio: CGFloat = Metrics.defaultCornerRatio
    private var configuredFontSize: CGFloat = Metrics.defaultFontSize
    private var configuredFontName = ""
    private var configuredAlignment: NSTextAlignment = .center
    private var isSpectrumEnabled = false
    private var hidesOnMouseHover = false
    private var isPresented = false
    private var isHovering = false
    private var isHiddenForMouseHover = false
    private var hoverRestoreTimer: Timer?
    private var hoverHiddenRestoreFrame: NSRect?
    private var presentationAnimationGeneration = 0
    private var baseSize = NSSize(width: Metrics.defaultWidth, height: Metrics.defaultHeight)
    private var currentTitleText = ""
    private var currentLyricText = ""
    private var currentLineIdentity: TimeInterval?

    /// 淡入/淡出的目标视图。逐个对子视图(频谱/标题/歌词)的 layer 直接做透明度动画,
    /// 容器 textContainerView 始终保持不透明(恒 1)。若对容器层整体做 opacity 动画,
    /// 子视图 layer 会被合入非不透明父层,触发离屏合成路径——文字淡入帧上可能产生
    /// 垂直方向的合成伪影,表现为"文本出现瞬间从上向下位移"。逐原子视图动画可绕开该路径。
    private var textContentViews: [NSView] {
        [spectrumView, titleLabel, lyricLabel]
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.defaultWidth, height: Metrics.defaultHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configureFloatingOverlay()
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        alphaValue = 0
        collectionBehavior.insert(.canJoinAllSpaces)
        collectionBehavior.insert(.fullScreenAuxiliary)
        collectionBehavior.insert(.stationary)
        collectionBehavior.insert(.ignoresCycle)

        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.autoresizingMask = [.width, .height]

        continentView.autoresizingMask = [.width, .height]
        continentView.wantsLayer = true
        continentView.layerContentsRedrawPolicy = .duringViewResize
        continentView.onHoverChanged = { [weak self] hovering in
            Task { @MainActor [weak self] in
                self?.setHovering(hovering)
            }
        }

        spectrumView.accentColor = NSColor.white.withAlphaComponent(0.88)
        spectrumView.wantsLayer = true
        spectrumView.layer?.zPosition = 8
        audioSpectrumMonitor.onLevels = { [weak self] levels in
            self?.spectrumView.setAudioLevels(levels)
        }
        audioSpectrumMonitor.onCaptureStateChanged = { [weak self] isCapturing in
            guard let self else { return }
            if !isCapturing {
                self.continentView.needsDisplay = true
            }
        }

        titleLabel.font = Self.configuredFont(familyName: "", size: Metrics.defaultFontSize, weight: .semibold, managerWeight: 8)
        titleLabel.textColor = .white
        titleLabel.scrollSpeed = 24
        titleLabel.fadeEdgeWidth = 18
        titleLabel.contentInsetX = 24

        lyricLabel.alignment = configuredAlignment
        lyricLabel.fadeEdgeWidth = 16
        lyricLabel.contentInsetX = 16
        lyricLabel.fallbackScrollSpeed = 52
        lyricLabel.font = Self.configuredFont(familyName: "", size: Metrics.defaultFontSize, weight: .semibold, managerWeight: 8)
        lyricLabel.usesTypographicVerticalCentering = true
        lyricLabel.textColor = .white
        lyricLabel.strokeColor = .clear
        lyricLabel.strokeWidth = 0

        // Keep the text and spectrum as siblings of the animated background instead of children
        // of the scaled layer.  AppKit can redraw layer-backed text on fractional transform frames,
        // which caused slight flashing and vertical drift near the presentation settle/rebound.
        // Only the black continent background scales; the text stays at its final pixel position and
        // fades in/out independently.
        textContainerView.autoresizingMask = [.width, .height]
        textContainerView.wantsLayer = true
        textContainerView.canDrawSubviewsIntoLayer = false
        textContainerView.layer?.backgroundColor = NSColor.clear.cgColor
        // 容器层恒定不透明(默认 1),透明度只作用于子视图——避免非不透明父层触发离屏
        // 合成路径,导致淡入帧上子视图内容出现垂直合成伪影("文字显示瞬间从上向下位移")。
        textContainerView.layer?.opacity = 1
        textContainerView.layer?.zPosition = 8
        continentView.layer?.zPosition = 0

        rootView.addSubview(continentView)
        textContainerView.addSubview(spectrumView)
        textContainerView.addSubview(titleLabel)
        textContainerView.addSubview(lyricLabel)
        rootView.addSubview(textContainerView)
        contentView = rootView
    }

    func apply(settings: AppSettings) {
        configuredWidth = Self.clampedWidth(CGFloat(settings.dynamicIslandLyricsWidth))
        configuredBlankWidth = Self.clampedBlankWidth(CGFloat(settings.dynamicIslandLyricsBlankWidth))
        configuredHeight = Self.clampedHeight(CGFloat(settings.dynamicIslandLyricsHeight))
        configuredSlantRatio = Self.clampedShapeRatio(CGFloat(settings.dynamicIslandLyricsSlantRatio))
        configuredCornerRatio = Self.clampedShapeRatio(CGFloat(settings.dynamicIslandLyricsCornerRatio))
        configuredFontSize = Self.clampedFontSize(CGFloat(settings.dynamicIslandLyricsFontSize))
        configuredFontName = settings.dynamicIslandLyricsFontName
        configuredAlignment = settings.dynamicIslandLyricsAlignment.nsTextAlignment
        lyricLabel.alignment = configuredAlignment
        applyConfiguredFonts()
        isSpectrumEnabled = settings.isDynamicIslandLyricsSpectrumEnabled
        hidesOnMouseHover = settings.isDynamicIslandLyricsHidesOnHover
        if !hidesOnMouseHover, isHiddenForMouseHover {
            restoreAfterMouseLeaves()
        }
        spectrumView.isHidden = !isSpectrumEnabled
        if !isSpectrumEnabled {
            spectrumView.isActive = false
            audioSpectrumMonitor.stop()
        }
        baseSize = NSSize(width: configuredWidth, height: configuredHeight)
        continentView.blankWidth = configuredBlankWidth
        continentView.slantRatio = configuredSlantRatio
        continentView.cornerRatio = configuredCornerRatio
        guard isPresented || isVisible else { return }

        let displaySize = displayedSize(for: baseSize)
        layoutLabels(size: displaySize)
        setFrame(continentFrame(size: displaySize), display: true)
    }

    func show(
        primary: String,
        translation: String?,
        showsTranslation: Bool,
        songTitle: String?,
        lineStartTime: TimeInterval? = nil,
        lineDuration: TimeInterval? = nil,
        lineElapsed: TimeInterval = 0,
        previousLineDuration: TimeInterval? = nil,
        nextLineDuration: TimeInterval? = nil,
        wordTimings: [DesktopLyricWordTiming] = [],
        isPlaying: Bool = true
    ) {
        let cleanPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrimary.isEmpty else {
            hide()
            return
        }

        let cleanSongTitle = songTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleText: String
        if let cleanSongTitle, !cleanSongTitle.isEmpty {
            titleText = cleanSongTitle
        } else {
            titleText = "音乐歌词"
        }
        let cleanTranslation = translation?.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleTranslation = showsTranslation && cleanTranslation?.isEmpty == false ? cleanTranslation : nil
        let lyricText = compactLyric(primary: cleanPrimary, translation: visibleTranslation)
        let lyricWordTimings = visibleTranslation == nil ? wordTimings : []
        let didTextChange = titleText != currentTitleText || lyricText != currentLyricText
        let didLineChange = lineIdentityChanged(from: currentLineIdentity, to: lineStartTime)

        if isSpectrumEnabled {
            spectrumView.isHidden = false
            spectrumView.isActive = true
            audioSpectrumMonitor.start()
        } else {
            spectrumView.isHidden = true
            spectrumView.isActive = false
            audioSpectrumMonitor.stop()
        }

        if titleText != currentTitleText {
            titleLabel.stringValue = titleText
            currentTitleText = titleText
        }
        if lyricText != currentLyricText {
            lyricLabel.stringValue = lyricText
            currentLyricText = lyricText
        }
        currentLineIdentity = lineStartTime
        lyricLabel.syncLineTiming(
            identity: lineStartTime,
            duration: lineDuration,
            elapsed: lineElapsed,
            previousDuration: previousLineDuration,
            nextDuration: nextLineDuration,
            wordTimings: lyricWordTimings,
            isPlaying: isPlaying
        )

        baseSize = NSSize(width: configuredWidth, height: configuredHeight)
        continentView.blankWidth = configuredBlankWidth
        continentView.slantRatio = configuredSlantRatio
        continentView.cornerRatio = configuredCornerRatio
        let displaySize = displayedSize(for: baseSize)
        let targetFrame = continentFrame(size: displaySize)

        let wasPresented = isPresented
        if !wasPresented {
            setFrame(targetFrame, display: true)
            layoutLabels(size: displaySize)
            orderFrontRegardless()
            animatePresentationIn(to: targetFrame, targetSize: displaySize)
            // 首次上屏：标题文本是在 orderFront 之前赋值的，其 didSet 的可见性
            // 判定当时为 false，滚动驱动没启动；上屏后必须补估一次。
            titleLabel.refreshAnimationState()
        } else {
            let frameChanged = !NSEqualRects(frame, targetFrame)
            if frameChanged {
                setFrame(targetFrame, display: true)
                layoutLabels(size: displaySize)
            } else if (didTextChange || didLineChange),
                      !(continentView.layer.map(hasRunningPresentationAnimation(on:)) ?? false) {
                // 标签/大陆的 frame 只随设置变化，行切换只需更新文字内部绘制，无需重排。
                // 变换动画进行中跳过 needsDisplay，避免在运动帧上重绘大陆导致整片闪烁。
                continentView.needsDisplay = true
            }
        }
        isPresented = true
    }

    func hide() {
        guard isPresented || isVisible else { return }
        isPresented = false
        isHovering = false
        isHiddenForMouseHover = false
        hoverRestoreTimer?.invalidate()
        hoverRestoreTimer = nil
        hoverHiddenRestoreFrame = nil
        ignoresMouseEvents = false
        currentTitleText = ""
        currentLyricText = ""
        currentLineIdentity = nil
        continentView.isHovering = false
        spectrumView.isActive = false
        audioSpectrumMonitor.stop()

        animatePresentationOut(duration: 0.105) { [weak self] in
            self?.orderOut(nil)
        }
    }

    private static func clampedWidth(_ value: CGFloat) -> CGFloat {
        min(Metrics.maxWidth, max(Metrics.minWidth, value == 0 ? Metrics.defaultWidth : value))
    }

    private static func clampedBlankWidth(_ value: CGFloat) -> CGFloat {
        min(Metrics.maxBlankWidth, max(Metrics.minBlankWidth, value == 0 ? Metrics.defaultBlankWidth : value))
    }

    private static func clampedHeight(_ value: CGFloat) -> CGFloat {
        min(Metrics.maxHeight, max(Metrics.minHeight, value == 0 ? Metrics.defaultHeight : value))
    }

    private static func clampedShapeRatio(_ value: CGFloat) -> CGFloat {
        min(Metrics.maxShapeRatio, max(Metrics.minShapeRatio, value == 0 ? Metrics.defaultSlantRatio : value))
    }

    private static func clampedFontSize(_ value: CGFloat) -> CGFloat {
        min(Metrics.maxFontSize, max(Metrics.minFontSize, value == 0 ? Metrics.defaultFontSize : value))
    }

    private static func configuredFont(familyName: String, size: CGFloat, weight: NSFont.Weight, managerWeight: Int) -> NSFont {
        let trimmedFamily = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFamily.isEmpty {
            let manager = NSFontManager.shared
            if let familyFont = manager.font(withFamily: trimmedFamily, traits: [], weight: managerWeight, size: size) {
                return familyFont
            }
            if let namedFont = NSFont(name: trimmedFamily, size: size) {
                return namedFont
            }
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    private func applyConfiguredFonts() {
        // 标题与歌词字体完全一致：同字号（configuredFontSize）、同字重（.semibold/8），
        // 颜色同为纯白——不保留任何视觉主次区分。
        let contentFont = Self.configuredFont(
            familyName: configuredFontName,
            size: configuredFontSize,
            weight: .semibold,
            managerWeight: 8
        )
        lyricLabel.font = contentFont
        titleLabel.font = contentFont
    }

    private static func typographicLineHeight(for font: NSFont) -> CGFloat {
        max(20, ceil(font.ascender - font.descender + font.leading + 2))
    }

    private func compactLyric(primary: String, translation: String?) -> String {
        let cleanTranslation = translation?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleanTranslation, !cleanTranslation.isEmpty, cleanTranslation != primary else {
            return primary
        }
        return "\(primary)  ·  \(cleanTranslation)"
    }

    private func displayedSize(for size: NSSize) -> NSSize {
        // Keep the window frame stable.  Earlier hover/content pulses changed the frame and made
        // the continent look like it was drifting by itself while lyrics refreshed.
        return size
    }

    private func layoutLabels(size: NSSize) {
        // 布局基准与窗口系统权威内容区对齐：若窗口 frame 尚未同步到请求尺寸，先 setFrame 一次
        // （同步刷新 contentLayoutRect），再以 contentLayoutRect 布局。日志实测 setFrame 后系统
        // 实际布局高度可能与请求 size 差 1pt（写入 37 会被滞后布局弹回 36），若按请求 size 布局，
        // 容器与文字 y 会出现 1pt 脉冲，落在文字淡入窗口内即表现为“文本一显示就从上向下位移”。
        if !NSEqualSizes(frame.size, size) {
            setFrame(continentFrame(size: size), display: true)
        }
        let resolvedSize = contentLayoutRect.size
        let layoutSize = (resolvedSize.width > 20 && resolvedSize.height > 8) ? resolvedSize : size
        rootView.frame = NSRect(origin: .zero, size: layoutSize)
        rootView.layer?.contentsScale = backingScaleFactor > 0 ? backingScaleFactor : (screen?.backingScaleFactor ?? 2)
        continentView.frame = NSRect(origin: .zero, size: layoutSize)
        textContainerView.frame = NSRect(origin: .zero, size: layoutSize)
        let size = layoutSize
        let widthScale = baseSize.width > 0 ? size.width / baseSize.width : 1
        let safeBlankWidth = min(
            configuredBlankWidth * widthScale,
            max(0, size.width - (Metrics.sideInset + Metrics.horizontalPadding) * 2 - 190)
        )
        continentView.blankWidth = safeBlankWidth

        let centerX = size.width / 2
        let blankLeft = centerX - safeBlankWidth / 2
        let blankRight = centerX + safeBlankWidth / 2
        let sideSafe = Metrics.sideInset + Metrics.horizontalPadding
        // 行高取左右两侧实际字体度量（ascender - descender + leading）的较大值，保证大字体时
        // 文字完整绘制、不被 masksToBounds 裁切，字体大小严格跟随设置。不再用 fontSize+10 的
        // 估值，也不再被窗口高度钳制——高度不足时文字以大陆可见中心为锚对称溢出，仍然居中。
        let textHeight = max(
            22,
            max(
                Self.typographicLineHeight(for: titleLabel.font),
                Self.typographicLineHeight(for: lyricLabel.font)
            )
        )
        // The continent intentionally bleeds above the top edge of the screen to attach to the
        // MacBook notch.  Center controls inside the actually visible mainland area instead of the
        // full window bounds; otherwise icons/text look slightly high or low depending on height.
        let visibleTop = max(10, size.height - Metrics.topBleed)
        let visibleBottom: CGFloat = 2
        let contentCenterY = floor((visibleTop + visibleBottom) / 2)
        let y = floor(contentCenterY - textHeight / 2)

        let spectrumSide = isSpectrumEnabled ? min(28, max(22, textHeight + 1)) : 0
        let spectrumX = sideSafe
        let spectrumY = floor(contentCenterY - spectrumSide / 2)
        let titleX = spectrumX + (isSpectrumEnabled ? spectrumSide + 9 : 0)
        let titleRight = max(titleX + 80, blankLeft - Metrics.textGap / 2)
        let lyricX = min(size.width - sideSafe - 112, blankRight + Metrics.textGap / 2)
        let lyricRight = size.width - sideSafe

        spectrumView.isHidden = !isSpectrumEnabled
        spectrumView.frame = NSRect(
            x: spectrumX,
            y: spectrumY,
            width: spectrumSide,
            height: spectrumSide
        )
        titleLabel.frame = NSRect(
            x: titleX,
            y: y,
            width: max(80, titleRight - titleX),
            height: textHeight
        )
        lyricLabel.frame = NSRect(
            x: lyricX,
            y: y,
            width: max(112, lyricRight - lyricX),
            height: textHeight
        )
        continentView.needsDisplay = true
    }

    private func continentFrame(size: NSSize) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 720 - size.width / 2, y: 900 - size.height + Metrics.topBleed, width: size.width, height: size.height)
        }

        let frame = screen.frame
        let x = min(max(frame.minX, frame.midX - size.width / 2), frame.maxX - size.width)
        return NSRect(x: x, y: frame.maxY - size.height + Metrics.topBleed, width: size.width, height: size.height)
    }

    private func setHovering(_ hovering: Bool) {
        guard isPresented else { return }
        if hovering, hidesOnMouseHover {
            hideTemporarilyForMouseHover()
            return
        }
        guard hovering != isHovering else { return }
        isHovering = hovering
        continentView.isHovering = hovering
        continentView.needsDisplay = true
    }

    private func hideTemporarilyForMouseHover() {
        guard hidesOnMouseHover, isPresented, !isHiddenForMouseHover else { return }
        isHiddenForMouseHover = true
        isHovering = false
        continentView.isHovering = false
        continentView.needsDisplay = true
        ignoresMouseEvents = true
        hoverHiddenRestoreFrame = frame
        startHoverRestoreTimer()

        animatePresentationOut(duration: 0.105)
    }

    private func startHoverRestoreTimer() {
        hoverRestoreTimer?.invalidate()
        // 悬停隐藏期持续轮询鼠标位置（窗口 ignoresMouseEvents 收不到事件）。
        // 0.1s 足够灵敏（恢复无感），0.035s 纯属空转唤醒。
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkMouseHoverRestore()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverRestoreTimer = timer
    }

    private func checkMouseHoverRestore() {
        guard isHiddenForMouseHover else {
            hoverRestoreTimer?.invalidate()
            hoverRestoreTimer = nil
            return
        }
        let restoreFrame = hoverHiddenRestoreFrame ?? frame
        let paddedFrame = restoreFrame.insetBy(dx: -6, dy: -6)
        if !paddedFrame.contains(NSEvent.mouseLocation) {
            restoreAfterMouseLeaves()
        }
    }

    private func restoreAfterMouseLeaves() {
        hoverRestoreTimer?.invalidate()
        hoverRestoreTimer = nil
        isHiddenForMouseHover = false
        ignoresMouseEvents = false
        guard isPresented || isVisible else { return }

        let targetFrame = hoverHiddenRestoreFrame ?? continentFrame(size: displayedSize(for: baseSize))
        hoverHiddenRestoreFrame = nil
        let targetSize = targetFrame.size
        setFrame(targetFrame, display: true)
        layoutLabels(size: targetSize)
        animatePresentationIn(to: targetFrame, targetSize: targetSize)
    }

    private func lineIdentityChanged(from old: TimeInterval?, to new: TimeInterval?) -> Bool {
        switch (old, new) {
        case (.none, .none):
            return false
        case let (.some(lhs), .some(rhs)):
            return abs(lhs - rhs) > 0.012
        default:
            return true
        }
    }

    private func presentationCollapsedSize(for targetSize: NSSize) -> NSSize {
        // The animation is a top-attached reveal, not a full "pop".  A less extreme collapsed
        // size keeps the first frame close to the final silhouette, which removes the sudden
        // stretch / dropped-frame feeling during quick hover-in and hover-out gestures.
        let width = min(max(240, targetSize.width * 0.88), max(240, targetSize.width * 0.94))
        let height = min(max(20, targetSize.height * 0.70), max(20, targetSize.height * 0.80))
        return NSSize(width: width, height: height)
    }

    private struct PresentationState {
        var scaleX: CGFloat
        var scaleY: CGFloat
        var opacity: Float
    }

    private func preparePresentationLayer() -> CALayer? {
        // Animate only the background layer.  The title/lyric views are kept outside this transform
        // so their glyph rasterization is not recomputed on fractional scale frames.
        continentView.wantsLayer = true
        guard let layer = continentView.layer else { return nil }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isOpaque = false
        layer.backgroundColor = NSColor.clear.cgColor
        layer.zPosition = 0
        layer.masksToBounds = false
        layer.allowsEdgeAntialiasing = true
        // 大陆只在状态切换/悬停时重绘，同步绘制即可：异步绘制会让入场首帧内容迟到，
        // 表现为上屏瞬间大陆先空白/旧内容、随后再补上（即“整个大陆闪烁”的来源之一）。
        layer.drawsAsynchronously = false
        layer.contentsScale = backingScaleFactor
        layer.rasterizationScale = backingScaleFactor > 0 ? backingScaleFactor : (screen?.backingScaleFactor ?? 2)
        layer.anchorPoint = CGPoint(x: 0.5, y: 1.0)
        layer.position = CGPoint(x: continentView.bounds.midX, y: continentView.bounds.maxY)
        CATransaction.commit()
        return layer
    }

    private func setPresentationLayer(scaleX: CGFloat, scaleY: CGFloat, opacity: Float) {
        guard let layer = preparePresentationLayer() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(CGAffineTransform(scaleX: scaleX, y: scaleY))
        layer.opacity = opacity
        CATransaction.commit()
    }

    private func presentationState(for layer: CALayer) -> PresentationState {
        let source = layer.presentation() ?? layer
        let transform = source.affineTransform()
        let scaleX = max(0.01, min(1.08, abs(transform.a)))
        let scaleY = max(0.01, min(1.06, abs(transform.d)))
        return PresentationState(scaleX: scaleX, scaleY: scaleY, opacity: source.opacity)
    }

    private func hasRunningPresentationAnimation(on layer: CALayer) -> Bool {
        guard let keys = layer.animationKeys() else { return false }
        return keys.contains("dynamicContinentTransform")
            || keys.contains("dynamicContinentScaleX")
            || keys.contains("dynamicContinentScaleY")
            || keys.contains("dynamicContinentOpacity")
    }

    private func easeInCubic(_ t: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, t))
        return clamped * clamped * clamped
    }

    private func smoothstep(_ t: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, t))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func smootherstep(_ t: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, t))
        return clamped * clamped * clamped * (clamped * (clamped * 6 - 15) + 10)
    }

    private func lerp(_ from: CGFloat, _ to: CGFloat, _ progress: CGFloat) -> CGFloat {
        from + (to - from) * progress
    }

    private func adjustedPresentationDuration(
        base: TimeInterval,
        from state: PresentationState,
        targetScaleX: CGFloat,
        targetScaleY: CGFloat,
        targetOpacity: Float,
        minimum: TimeInterval
    ) -> TimeInterval {
        let distance = max(
            abs(state.scaleX - targetScaleX),
            abs(state.scaleY - targetScaleY),
            CGFloat(abs(state.opacity - targetOpacity))
        )
        let normalized = min(1, Double(distance / 0.48))
        let factor = 0.46 + 0.54 * sqrt(normalized)
        return max(minimum, base * factor)
    }

    private func easedProgress(_ t: CGFloat, completesAt completionPoint: CGFloat, power: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, t))
        let normalized = min(1, clamped / max(0.01, completionPoint))
        return CGFloat(1 - pow(Double(1 - normalized), Double(power)))
    }

    private func makeKeyframeAnimation(
        keyPath: String,
        values: [NSNumber],
        keyTimes: [NSNumber],
        duration: CFTimeInterval
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.duration = duration
        animation.calculationMode = .linear
        animation.isRemovedOnCompletion = true
        return animation
    }

    private func sampledShowValues(
        from state: PresentationState,
        duration: CFTimeInterval
    ) -> (x: [NSNumber], y: [NSNumber], opacity: [NSNumber], keyTimes: [NSNumber]) {
        let steps = max(20, min(34, Int(duration * 120)))
        var xValues: [NSNumber] = []
        var yValues: [NSNumber] = []
        var opacityValues: [NSNumber] = []
        var keyTimes: [NSNumber] = []
        xValues.reserveCapacity(steps + 1)
        yValues.reserveCapacity(steps + 1)
        opacityValues.reserveCapacity(steps + 1)
        keyTimes.reserveCapacity(steps + 1)

        for index in 0...steps {
            let t = CGFloat(index) / CGFloat(steps)
            // 入场采用“单调逼近”曲线：尺寸从收缩态一路缓到 1.0，全程不越过终态（无 overshoot）。
            // 旧版 1.4%–2.2% 的弹性回弹正是“显示时轻微放大”的来源，回弹收尾的亚像素运动还会让
            // 大陆边缘反复重采样、产生抖动闪烁。现在宽度先到位、高度稍后跟上；透明度提前完成，
            // 轮廓先“浮现”再“定形”，观感从“弹一下”变成自然地“长出来”。
            let scaleProgress = easedProgress(t, completesAt: 0.86, power: 4.6)
            let heightProgress = easedProgress(t, completesAt: 0.91, power: 5.2)
            let opacityProgress = easedProgress(t, completesAt: 0.55, power: 2.8)
            let scaleX = lerp(state.scaleX, 1, scaleProgress)
            let scaleY = lerp(state.scaleY, 1, heightProgress)
            let opacity = CGFloat(state.opacity) + (1 - CGFloat(state.opacity)) * opacityProgress
            xValues.append(NSNumber(value: Double(scaleX)))
            yValues.append(NSNumber(value: Double(scaleY)))
            opacityValues.append(NSNumber(value: Double(min(CGFloat(1), max(CGFloat(0), opacity)))))
            keyTimes.append(NSNumber(value: Double(t)))
        }
        xValues[xValues.count - 1] = NSNumber(value: 1.0)
        yValues[yValues.count - 1] = NSNumber(value: 1.0)
        opacityValues[opacityValues.count - 1] = NSNumber(value: 1.0)
        return (xValues, yValues, opacityValues, keyTimes)
    }

    private func sampledHideValues(
        from state: PresentationState,
        endScaleX: CGFloat,
        endScaleY: CGFloat,
        duration: CFTimeInterval
    ) -> (x: [NSNumber], y: [NSNumber], opacity: [NSNumber], keyTimes: [NSNumber]) {
        let steps = max(14, min(28, Int(duration * 150)))
        var xValues: [NSNumber] = []
        var yValues: [NSNumber] = []
        var opacityValues: [NSNumber] = []
        var keyTimes: [NSNumber] = []
        xValues.reserveCapacity(steps + 1)
        yValues.reserveCapacity(steps + 1)
        opacityValues.reserveCapacity(steps + 1)
        keyTimes.reserveCapacity(steps + 1)

        for index in 0...steps {
            let t = CGFloat(index) / CGFloat(steps)
            // Hide stays decisive, not springy: opacity leaves well ahead of the size change
            // (fully transparent by ~72% of the timeline), and the shape contracts monotonically
            // toward the top center underneath — reading as "drawn up and absorbed", not dropped.
            let scaleProgress = easeInCubic(t)
            let heightProgress = smootherstep(t)
            let fadeProgress = smoothstep(min(1, t * 1.38))
            let scaleX = lerp(state.scaleX, endScaleX, scaleProgress)
            let scaleY = lerp(state.scaleY, endScaleY, heightProgress)
            let opacity = CGFloat(state.opacity) * (1 - fadeProgress)
            xValues.append(NSNumber(value: Double(scaleX)))
            yValues.append(NSNumber(value: Double(scaleY)))
            opacityValues.append(NSNumber(value: Double(max(CGFloat(0), min(CGFloat(1), opacity)))))
            keyTimes.append(NSNumber(value: Double(t)))
        }
        xValues[xValues.count - 1] = NSNumber(value: Double(endScaleX))
        yValues[yValues.count - 1] = NSNumber(value: Double(endScaleY))
        opacityValues[opacityValues.count - 1] = NSNumber(value: 0.0)
        return (xValues, yValues, opacityValues, keyTimes)
    }

    private func prepareTextContentLayers() {
        let scale = backingScaleFactor > 0 ? backingScaleFactor : (screen?.backingScaleFactor ?? 2)
        for view in textContentViews {
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contentsScale = scale
            layer.rasterizationScale = scale
            layer.allowsEdgeAntialiasing = true
            layer.drawsAsynchronously = false
            layer.zPosition = 8
            layer.setAffineTransform(CGAffineTransform.identity)
            CATransaction.commit()
        }
    }

    private func contentOpacityState() -> Float {
        let layers = textContentViews.compactMap { $0.layer }
        guard !layers.isEmpty else { return 1 }
        let opacity = layers.map { ($0.presentation() ?? $0).opacity }.reduce(Float(0), +) / Float(layers.count)
        return max(Float(0), min(Float(1), opacity))
    }

    private func setTextContentOpacity(_ opacity: Float) {
        let clamped = max(Float(0), min(Float(1), opacity))
        prepareTextContentLayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for view in textContentViews {
            view.layer?.removeAnimation(forKey: "dynamicContinentContentOpacity")
            view.layer?.opacity = clamped
        }
        CATransaction.commit()
    }

    private func animateTextContentOpacity(
        from startOpacity: Float,
        to finalOpacity: Float,
        duration: CFTimeInterval,
        delay: CFTimeInterval = 0,
        timingFunctionName: CAMediaTimingFunctionName = .easeInEaseOut
    ) {
        let start = max(Float(0), min(Float(1), startOpacity))
        let end = max(Float(0), min(Float(1), finalOpacity))
        prepareTextContentLayers()

        for view in textContentViews {
            guard let layer = view.layer else { continue }
            layer.removeAnimation(forKey: "dynamicContinentContentOpacity")

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = start
            CATransaction.commit()

            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = start
            animation.toValue = end
            animation.duration = max(0.001, duration)
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + max(0, delay)
            animation.timingFunction = CAMediaTimingFunction(name: timingFunctionName)
            animation.fillMode = .both
            animation.isRemovedOnCompletion = true

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = end
            layer.add(animation, forKey: "dynamicContinentContentOpacity")
            CATransaction.commit()
        }
    }

    private func fadeTextContentOutForPresentation(from opacity: Float, duration: CFTimeInterval) {
        animateTextContentOpacity(
            from: opacity,
            to: 0,
            duration: duration,
            delay: 0,
            timingFunctionName: .easeOut
        )
    }

    private func animatePresentationLayer(
        layer: CALayer,
        from state: PresentationState,
        duration: CFTimeInterval,
        finalScaleX: CGFloat,
        finalScaleY: CGFloat,
        finalOpacity: Float,
        isShowing: Bool,
        completion: (@Sendable @MainActor () -> Void)? = nil
    ) {
        presentationAnimationGeneration += 1
        let generation = presentationAnimationGeneration

        let startContentOpacity = contentOpacityState()

        layer.removeAnimation(forKey: "dynamicContinentTransform")
        layer.removeAnimation(forKey: "dynamicContinentScaleX")
        layer.removeAnimation(forKey: "dynamicContinentScaleY")
        layer.removeAnimation(forKey: "dynamicContinentOpacity")
        for view in textContentViews {
            view.layer?.removeAnimation(forKey: "dynamicContinentContentOpacity")
        }

        let startState = PresentationState(
            scaleX: max(0.01, min(1.08, state.scaleX)),
            scaleY: max(0.01, min(1.06, state.scaleY)),
            opacity: max(Float(0), min(Float(1), state.opacity))
        )
        let endOpacity = max(Float(0), min(Float(1), finalOpacity))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Put the model layer at the actual current visual state before replacing animations.
        // This avoids a one-frame jump when the mouse quickly enters/leaves and interrupts an
        // in-flight transition.
        layer.shouldRasterize = false
        layer.setAffineTransform(CGAffineTransform(scaleX: startState.scaleX, y: startState.scaleY))
        layer.opacity = startState.opacity
        // 入场时文字瞬时置零，不做旧的 30ms“闪出”：背景在任何运动帧上都叠不到文字，
        // 根除“文字在背景缩放帧上被重栅格化而闪烁”的路径；退场则从当前可见度平滑淡出。
        // 透明度只作用于子视图（textContentViews 已为原子视图列表）；容器层恒为不透明 1，
        // 不做离屏合成，杜绝淡入帧上的垂直合成伪影。
        textContainerView.layer?.opacity = 1
        textContainerView.layer?.removeAnimation(forKey: "dynamicContinentContentOpacity")
        for view in textContentViews {
            view.layer?.opacity = isShowing ? 0 : startContentOpacity
        }
        CATransaction.commit()

        let sampled = isShowing
            ? sampledShowValues(from: startState, duration: duration)
            : sampledHideValues(from: startState, endScaleX: finalScaleX, endScaleY: finalScaleY, duration: duration)
        let scaleXAnimation = makeKeyframeAnimation(
            keyPath: "transform.scale.x",
            values: sampled.x,
            keyTimes: sampled.keyTimes,
            duration: duration
        )
        let scaleYAnimation = makeKeyframeAnimation(
            keyPath: "transform.scale.y",
            values: sampled.y,
            keyTimes: sampled.keyTimes,
            duration: duration
        )
        let opacityAnimation = makeKeyframeAnimation(
            keyPath: "opacity",
            values: sampled.opacity,
            keyTimes: sampled.keyTimes,
            duration: duration
        )

        // 入场时文字保持全隐（上方事务已置 0），淡入推迟到背景动画完成回调里再触发——
        // 见下方 completion 块。若在此处调度带 delay 的淡入，淡入窗口会与背景尾部收敛及
        // completion 内的 setFrame/layoutLabels 重排重叠，文字半透明时被挪动即表现为“上下弹跳”。
        if !isShowing {
            let textFadeOutDuration = min(0.030, max(0.014, duration * 0.26))
            fadeTextContentOutForPresentation(from: startContentOpacity, duration: textFadeOutDuration)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(CGAffineTransform(scaleX: finalScaleX, y: finalScaleY))
        layer.opacity = endOpacity
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.presentationAnimationGeneration == generation else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.shouldRasterize = false
                layer.setAffineTransform(CGAffineTransform(scaleX: finalScaleX, y: finalScaleY))
                layer.opacity = endOpacity
                CATransaction.commit()
                completion?()
                if isShowing, self.presentationAnimationGeneration == generation {
                    // 文字此刻模型 opacity 仍为 0（不可见）。在淡入前先把布局落定并强制
                    // 同步栅格化：字体度量、typographic bounds、attributed 缓存、像素对齐
                    // 全部一次性建立。若把这份“首次渲染”留到淡入窗口内，图层内容会在
                    // 半透明期间被重建/重排，表现为文字出现瞬间从上向下位移与闪动。
                    self.rootView.layoutSubtreeIfNeeded()
                    self.titleLabel.display()
                    self.lyricLabel.display()
                    self.textContainerView.display()
                    // 淡入零延迟成立的前提（与上方 completion?() 的 setFrame 移除配合）：
                    // 窗口 frame 的最后一次写入发生在动画开始前，窗口系统在 0.30s 动画窗口内
                    // 已完成滞后布局收敛；完成回调里不再重复 setFrame，也就没有“动画结束后
                    // 60~90ms 再弹回 1pt”的滞后布局。此刻 contentLayoutRect 读到的就是收敛
                    // 权威值（36/y=3），layoutLabels 写入与系统一致 → 无弹回 → 无需固定 delay。
                    // displayIfNeeded 只负责把上述布局与首帧栅格化同步到当前事务，保证淡入
                    // 窗口（0.18s）内几何绝对静止。
                    self.displayIfNeeded()
                    self.animateTextContentOpacity(
                        from: 0,
                        to: 1,
                        duration: 0.18,
                        delay: 0,
                        timingFunctionName: .easeOut
                    )
                }
            }
        }
        layer.add(scaleXAnimation, forKey: "dynamicContinentScaleX")
        layer.add(scaleYAnimation, forKey: "dynamicContinentScaleY")
        layer.add(opacityAnimation, forKey: "dynamicContinentOpacity")
        CATransaction.commit()
    }

    private func animatePresentationIn(to targetFrame: NSRect, targetSize: NSSize, duration: TimeInterval = 0.30) {
        let wasVisuallyHidden = alphaValue < 0.05 || !isVisible
        setFrame(targetFrame, display: true)
        layoutLabels(size: targetSize)
        if wasVisuallyHidden {
            setTextContentOpacity(0)
        }
        hasShadow = false
        alphaValue = 1

        guard let layer = preparePresentationLayer() else { return }

        // 让大陆首帧内容在动画启动前完成同步绘制并提交到图层（layoutLabels 已置 needsDisplay）。
        // 否则窗口上屏的首帧可能拿到尚未绘制完成的图层内容，动画起步瞬间会闪一下空白。
        continentView.displayIfNeeded()

        let collapsed = presentationCollapsedSize(for: targetSize)
        let collapsedState = PresentationState(
            scaleX: max(0.80, min(0.90, collapsed.width / max(targetSize.width, 1))),
            scaleY: max(0.62, min(0.74, collapsed.height / max(targetSize.height, 1))),
            opacity: 0
        )
        let fromState = hasRunningPresentationAnimation(on: layer) || !wasVisuallyHidden
            ? presentationState(for: layer)
            : collapsedState
        let targetDuration = adjustedPresentationDuration(
            base: duration,
            from: fromState,
            targetScaleX: 1.0,
            targetScaleY: 1.0,
            targetOpacity: 1.0,
            minimum: 0.095
        )

        animatePresentationLayer(
            layer: layer,
            from: fromState,
            duration: targetDuration,
            finalScaleX: 1.0,
            finalScaleY: 1.0,
            finalOpacity: 1.0,
            isShowing: true
        ) { [weak self] in
            guard let self else { return }
            self.setPresentationLayer(scaleX: 1.0, scaleY: 1.0, opacity: 1.0)
            // 入场动画只作用于 layer transform，窗口 frame 自 show()/本方法入口写入后从未
            // 改变，完成回调不再重复 setFrame —— 与退场路径（animatePresentationOut 不写
            // frame）对齐。日志实测：同值 setFrame 仍会让窗口系统在动画结束后约 60~90ms
            // 再触发一轮滞后布局，把容器从写入值“弹回”收敛值（37→36，1pt），弹回落在文字
            // 淡入窗口内即表现为“从上向下位移”。去掉它就没有新的滞后布局可弹。
            // layoutLabels 保留：此刻 frame.size 已等于目标尺寸，其内部的先 setFrame 同步
            // 分支不会命中，只会读取动画窗口（0.30s）内早已收敛的 contentLayoutRect 做最终
            // 对齐，写入值即系统权威值，不会引起新的弹回。
            self.layoutLabels(size: targetSize)
            self.hasShadow = false
        }
    }

    /// targetFrame 形参已移除：退场动画从不改写窗口 frame，实际由调用方决定（见下方注释）。
    private func animatePresentationOut(duration: TimeInterval, completion: (@Sendable @MainActor () -> Void)? = nil) {
        let currentSize = frame.size.width > 20 && frame.size.height > 8 ? frame.size : baseSize
        guard let layer = preparePresentationLayer() else {
            completion?()
            return
        }
        let collapsed = presentationCollapsedSize(for: currentSize)
        let endScaleX = max(0.80, min(0.90, collapsed.width / max(currentSize.width, 1)))
        let endScaleY = max(0.62, min(0.74, collapsed.height / max(currentSize.height, 1)))
        let fromState = hasRunningPresentationAnimation(on: layer)
            ? presentationState(for: layer)
            : PresentationState(scaleX: 1.0, scaleY: 1.0, opacity: 1.0)
        let targetDuration = adjustedPresentationDuration(
            base: duration,
            from: fromState,
            targetScaleX: endScaleX,
            targetScaleY: endScaleY,
            targetOpacity: 0.0,
            minimum: 0.055
        )

        hasShadow = false
        alphaValue = 1
        animatePresentationLayer(
            layer: layer,
            from: fromState,
            duration: targetDuration,
            finalScaleX: endScaleX,
            finalScaleY: endScaleY,
            finalOpacity: 0.0,
            isShowing: false
        ) { [weak self] in
            guard let self else { return }
            self.alphaValue = 0
            self.setPresentationLayer(scaleX: 1.0, scaleY: 1.0, opacity: 1.0)
            // Keep the real window frame unchanged during the hide animation.  The caller decides
            // whether to order the panel out or restore it after mouse hover.
            completion?()
        }
    }

}
@MainActor
private final class MenuBarLyricsTickerView: NSView, DisplayLinkResponding {
    /// 滚动时序与采样引擎（单实现，与桌面歌词行视图共用；行为基准为灵动大陆调优版本）。
    private let engine = LyricsScrollEngine()

    private struct Metrics {
        static let horizontalInset: CGFloat = 7
    }

    var font: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium) {
        didSet {
            guard oldValue != font else { return }
            resetTextCaches()
        }
    }

    var textColor: NSColor = .labelColor {
        didSet {
            attributedText = nil
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

    private var stringValue = ""
    private var attributedText: NSAttributedString?
    private var measuredTextRect: NSRect = .zero
    private var measuredSize: NSSize = .zero
    private var displayTimestamp: CFTimeInterval = CACurrentMediaTime()
    private var activeDisplayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget<MenuBarLyricsTickerView>?

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

        // 显式同步引擎字号：engine 默认 28，而本视图实际字号 12——若只依赖
        // font.didSet，ensureTickerView 赋同款字体时 guard 跳过，engine.fontPointSize
        // 永远停在 28，repeatGapWidth/minimumVisualStep 等按 28 计算导致间距偏大。
        resetTextCaches()

        engine.onRequestRedraw = { [weak self] in self?.needsDisplay = true }
        engine.measureInlineWidth = { [weak self] text in
            guard let self else { return 0 }
            return self.measuredInlineWidth(text)
        }
        engine.currentMaxOffset = { [weak self] in
            guard let self, !self.stringValue.isEmpty else { return 0 }
            let textSize = self.measuredSizeForCurrentText()
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
            needsDisplay = true
        }
    }

    func setText(
        _ text: String,
        lineStartTime: TimeInterval?,
        lineDuration: TimeInterval?,
        lineElapsed: TimeInterval,
        previousLineDuration: TimeInterval? = nil,
        nextLineDuration: TimeInterval? = nil,
        wordTimings: [DesktopLyricWordTiming] = [],
        isPlaying: Bool = true
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldText = stringValue
        if oldText != trimmed {
            stringValue = trimmed
            engine.text = trimmed
            engine.invalidateTextCaches()
            engine.resetLineState(keepsTiming: false)
            // 视图级富文本/尺寸缓存必须一并失效，否则 draw() 永远命中旧句缓存。
            attributedText = nil
            measuredTextRect = .zero
            measuredSize = .zero
        }
        engine.syncLineTiming(
            identity: lineStartTime,
            duration: lineDuration,
            elapsed: lineElapsed,
            previousDuration: previousLineDuration,
            nextDuration: nextLineDuration,
            wordTimings: wordTimings,
            isPlaying: isPlaying
        )
        updateAnimationState()
        needsDisplay = true
    }

    func clear() {
        stringValue = ""
        engine.text = ""
        engine.clearAll()
        attributedText = nil
        measuredTextRect = .zero
        measuredSize = .zero
        stopDisplayDriver()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !stringValue.isEmpty, bounds.width > 2, bounds.height > 2 else { return }
        let attributed = attributedString()
        let textRect = protectedTextRect()
        let textSize = measuredSizeForCurrentText()
        let maxOffset = max(0, textSize.width - textRect.width)
        let shouldScroll = maxOffset > 8
        let sample = engine.renderSample(maxOffset: maxOffset, shouldScroll: shouldScroll, viewportWidth: textRect.width, now: renderTimestamp())
        let x = drawingOriginX(textWidth: textSize.width, shouldScroll: shouldScroll, offset: sample.offset, textRect: textRect)
        let y = verticallyCenteredTextY()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        if sample.alpha < 0.999 {
            NSGraphicsContext.current?.cgContext.setAlpha(sample.alpha)
        }
        // 与桌面歌词一致的多份 repeat marquee：长行按引擎计划重复绘制。
        let copies = max(1, sample.repeatCount)
        let stride = sample.repeatStride > 1 ? sample.repeatStride : 0
        for index in 0..<copies {
            attributed.draw(at: NSPoint(x: x + CGFloat(index) * stride, y: y))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func updateLayerScale() {
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func updateAnimationState() {
        // 与桌面歌词行视图一致：以可见性判定（orderOut 后 window 仍非 nil），
        // 防止 display link 在不可见窗口上持续空转。
        guard window?.isVisible == true else {
            stopDisplayDriver()
            return
        }
        if !engine.timingIsPaused, !stringValue.isEmpty, bounds.width > 2, measuredSizeForCurrentText().width > protectedTextRect().width + 8 {
            startDisplayDriver()
        } else {
            stopDisplayDriver()
        }
        needsDisplay = true
    }

    private func startDisplayDriver() {
        guard activeDisplayLink == nil, window != nil else { return }
        displayTimestamp = CACurrentMediaTime()
        let target = DisplayLinkTarget(view: self)
        let link = displayLink(target: target, selector: #selector(DisplayLinkTarget<MenuBarLyricsTickerView>.displayLinkDidFire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        link.isPaused = false
        activeDisplayLink = link
        displayLinkTarget = target
    }

    private func stopDisplayDriver() {
        activeDisplayLink?.invalidate()
        activeDisplayLink = nil
        displayLinkTarget = nil
    }

    func displayLinkDidFire(_ link: CADisplayLink) {
        // Use the actual display-link timestamp rather than the predicted target timestamp; the
        // predicted value can jitter slightly under variable refresh pacing and makes slow lyric
        // motion look uneven.
        displayTimestamp = link.timestamp > 0 ? link.timestamp : CACurrentMediaTime()
        needsDisplay = true
    }

    private func renderTimestamp() -> CFTimeInterval {
        activeDisplayLink == nil ? CACurrentMediaTime() : displayTimestamp
    }

    private func attributedString() -> NSAttributedString {
        if let attributedText { return attributedText }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
            .kern: 0.1
        ]
        let attributed = NSAttributedString(string: stringValue, attributes: attributes)
        attributedText = attributed
        return attributed
    }

    private func measuredSizeForCurrentText() -> NSSize {
        if measuredSize == .zero {
            let rect = attributedString().boundingRect(
                with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).integral
            measuredTextRect = rect
            measuredSize = NSSize(width: ceil(rect.width + 1), height: ceil(rect.height))
        }
        return measuredSize
    }

    private func verticallyCenteredTextY() -> CGFloat {
        _ = measuredSizeForCurrentText()
        let textHeight = max(1, measuredTextRect.height)
        // NSStatusBarButton's content area is short and uses a visual center that is slightly above
        // the mathematical center.  Use the attributed bounding rect origin instead of raw size so
        // ascenders/descenders sit on the same center line as the system menu bar icons.
        let y = (bounds.height - textHeight) / 2 - measuredTextRect.minY
        return floor(y) + 0.5
    }

    private func protectedTextRect() -> NSRect {
        bounds.insetBy(dx: Metrics.horizontalInset, dy: 0)
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

    private func resetTextCaches() {
        engine.fontPointSize = font.pointSize
        engine.invalidateTextCaches()
        attributedText = nil
        measuredTextRect = .zero
        measuredSize = .zero
    }

    /// Where in the visible viewport the currently sung word should rest while it scrolls.
    /// Follows the lyric alignment: left-aligned text parks the active word on the left edge,
    /// right-aligned parks it on the right edge, centered keeps it at the visual center.

    private func measuredInlineWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraph,
                .kern: 0.1
            ]
        )
        return attributed.size().width
    }

}

@MainActor
final class MenuBarLyricsSurface {
    private enum Metrics {
        static let defaultWidth: CGFloat = 220
        static let minWidth: CGFloat = 40
        static let maxWidth: CGFloat = 760
        static let preferredHeight: CGFloat = 22
    }

    private var statusItem: NSStatusItem?
    private weak var tickerView: MenuBarLyricsTickerView?
    private var configuredWidth: CGFloat = Metrics.defaultWidth
    private var configuredAlignment: NSTextAlignment = .center

    func apply(settings: AppSettings) {
        configuredWidth = Self.clampedWidth(CGFloat(settings.menuBarLyricsWidth))
        configuredAlignment = settings.menuBarLyricsAlignment.nsTextAlignment
        tickerView?.alignment = configuredAlignment
        statusItem?.length = configuredWidth
        updateTickerFrame()
    }
    func show(
        primary: String,
        translation: String?,
        showsTranslation: Bool,
        lineStartTime: TimeInterval?,
        lineDuration: TimeInterval?,
        lineElapsed: TimeInterval,
        previousLineDuration: TimeInterval? = nil,
        nextLineDuration: TimeInterval? = nil,
        wordTimings: [DesktopLyricWordTiming] = [],
        isPlaying: Bool = true
    ) {
        let text = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            hide()
            return
        }

        let item = ensureStatusItem()
        item.isVisible = true
        item.length = configuredWidth
        let cleanTranslation = translation?.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleTranslation = showsTranslation && cleanTranslation?.isEmpty == false ? cleanTranslation : nil
        let combined = compactTitle(primary: text, translation: visibleTranslation)
        let tickerWordTimings = visibleTranslation == nil ? wordTimings : []
        let ticker = ensureTickerView(on: item)
        ticker.setText(
            combined,
            lineStartTime: lineStartTime,
            lineDuration: lineDuration,
            lineElapsed: lineElapsed,
            previousLineDuration: previousLineDuration,
            nextLineDuration: nextLineDuration,
            wordTimings: tickerWordTimings,
            isPlaying: isPlaying
        )
        item.button?.toolTip = [text, showsTranslation ? translation : nil]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    func hide() {
        tickerView?.clear()
        statusItem?.isVisible = false
    }

    private func ensureStatusItem() -> NSStatusItem {
        if let statusItem { return statusItem }
        let item = NSStatusBar.system.statusItem(withLength: configuredWidth)
        statusItem = item
        return item
    }

    private func ensureTickerView(on item: NSStatusItem) -> MenuBarLyricsTickerView {
        if let tickerView {
            updateTickerFrame()
            return tickerView
        }

        let ticker = MenuBarLyricsTickerView(frame: NSRect(x: 0, y: 0, width: configuredWidth, height: Metrics.preferredHeight))
        ticker.autoresizingMask = [.width, .height]
        ticker.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        ticker.textColor = .labelColor
        ticker.alignment = configuredAlignment

        if let button = item.button {
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.image = nil
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            button.alignment = configuredAlignment
            button.cell?.lineBreakMode = .byClipping
            button.wantsLayer = true
            button.layer?.masksToBounds = true
            button.subviews.forEach { subview in
                if subview is MenuBarLyricsTickerView {
                    subview.removeFromSuperview()
                }
            }
            ticker.frame = button.bounds
            button.addSubview(ticker)
        }

        tickerView = ticker
        return ticker
    }

    private func updateTickerFrame() {
        statusItem?.length = configuredWidth
        if let button = statusItem?.button, let tickerView {
            tickerView.frame = button.bounds
        }
    }

    private static func clampedWidth(_ value: CGFloat) -> CGFloat {
        min(Metrics.maxWidth, max(Metrics.minWidth, value == 0 ? Metrics.defaultWidth : value))
    }

    private func compactTitle(primary: String, translation: String?) -> String {
        let secondary = translation?.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = secondary?.isEmpty == false ? "\(primary) / \(secondary ?? "")" : primary
        return combined
    }
}

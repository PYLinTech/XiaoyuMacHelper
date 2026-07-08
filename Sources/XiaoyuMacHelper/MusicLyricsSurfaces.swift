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
        static let hoverWidthScale: CGFloat = 1.0
        static let hoverHeightGain: CGFloat = 0
        static let updateHeightGain: CGFloat = 0
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

            drawNotchSeparation(in: rect)
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

        private func drawNotchSeparation(in rect: NSRect) {
            // The blank notch reserve is created by layout, not by visible divider lines.
            // Drawing an inner rounded rectangle here made the continent look split into panels.
            _ = rect
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
    private final class SpectrumDisplayLinkTarget: NSObject {
        weak var view: CircularSpectrumIconView?

        init(view: CircularSpectrumIconView) {
            self.view = view
        }

        @objc func displayLinkDidFire(_ link: CADisplayLink) {
            view?.displayLinkDidFire(link)
        }
    }

    @MainActor
    private final class CircularSpectrumIconView: NSView {
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
        private var displayLinkTarget: SpectrumDisplayLinkTarget?
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

        func pulse(strength: CGFloat = 0.0) {
            // Real audio drives the spectrum.  Keep this method as a compatibility hook for
            // lyric updates, but do not synthesize fake bars from text changes.
            _ = strength
        }

        fileprivate func displayLinkDidFire(_ link: CADisplayLink) {
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
            let target = SpectrumDisplayLinkTarget(view: self)
            let link = displayLink(target: target, selector: #selector(SpectrumDisplayLinkTarget.displayLinkDidFire(_:)))
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
    private final class TitleTickerDisplayLinkTarget: NSObject {
        weak var view: TitleTickerTextView?

        init(view: TitleTickerTextView) {
            self.view = view
        }

        @objc func displayLinkDidFire(_ link: CADisplayLink) {
            view?.displayLinkDidFire(link)
        }
    }

    @MainActor
    private final class TitleTickerTextView: NSView {
        var stringValue: String = "" {
            didSet {
                guard oldValue != stringValue else { return }
                textVersion &+= 1
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
        private var displayLinkTarget: TitleTickerDisplayLinkTarget?
        private var attributedCache: NSAttributedString?
        private var measuredTextSize: NSSize = .zero
        private var measuredTypographicBounds: NSRect = .zero
        private var cycleStartedAt: CFTimeInterval = CACurrentMediaTime()
        private var textVersion = 0

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
            guard window != nil else {
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
            let target = TitleTickerDisplayLinkTarget(view: self)
            let link = displayLink(target: target, selector: #selector(TitleTickerDisplayLinkTarget.displayLinkDidFire(_:)))
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

        private func applyEdgeFade(in context: CGContext) {
            let fade = min(max(0, fadeEdgeWidth), bounds.width / 3)
            guard fade > 1 else { return }

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard
                let leftGradient = CGGradient(
                    colorsSpace: colorSpace,
                    colors: [
                        NSColor.black.withAlphaComponent(0.82).cgColor,
                        NSColor.black.withAlphaComponent(0.0).cgColor
                    ] as CFArray,
                    locations: [0, 1]
                ),
                let rightGradient = CGGradient(
                    colorsSpace: colorSpace,
                    colors: [
                        NSColor.black.withAlphaComponent(0.0).cgColor,
                        NSColor.black.withAlphaComponent(0.82).cgColor
                    ] as CFArray,
                    locations: [0, 1]
                )
            else { return }

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
    private var isSpectrumEnabled = false
    private var hidesOnMouseHover = false
    private var isPresented = false
    private var isHovering = false
    private var isHiddenForMouseHover = false
    private var hoverRestoreTimer: Timer?
    private var hoverHiddenRestoreFrame: NSRect?
    private var presentationAnimationGeneration = 0
    private var pendingTextFadeInWorkItem: DispatchWorkItem?
    private var baseSize = NSSize(width: Metrics.defaultWidth, height: Metrics.defaultHeight)
    private var currentTitleText = ""
    private var currentLyricText = ""
    private var currentLineIdentity: TimeInterval?

    private var textContentViews: [NSView] {
        [textContainerView]
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
        audioSpectrumMonitor.onLevels = { [weak self] levels in
            self?.spectrumView.setAudioLevels(levels)
        }
        audioSpectrumMonitor.onCaptureStateChanged = { [weak self] isCapturing in
            guard let self else { return }
            if !isCapturing {
                self.continentView.needsDisplay = true
            }
        }

        titleLabel.font = Self.configuredFont(familyName: "", size: Metrics.defaultFontSize - 2.4, weight: .medium, managerWeight: 6)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.70)
        titleLabel.scrollSpeed = 24
        titleLabel.fadeEdgeWidth = 18
        titleLabel.contentInsetX = 24

        lyricLabel.alignment = .left
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
        isPlaying: Bool = true
    ) {
        let cleanPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrimary.isEmpty else {
            hide()
            return
        }

        let cleanSongTitle = songTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleText = cleanSongTitle?.isEmpty == false ? (cleanSongTitle ?? "") : "音乐歌词"
        let lyricText = compactLyric(primary: cleanPrimary, translation: showsTranslation ? translation : nil)
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
        if isSpectrumEnabled, didTextChange || didLineChange {
            spectrumView.pulse(strength: didLineChange ? 0.68 : 0.44)
        }
        currentLineIdentity = lineStartTime
        lyricLabel.syncLineTiming(
            identity: lineStartTime,
            duration: lineDuration,
            elapsed: lineElapsed,
            previousDuration: previousLineDuration,
            nextDuration: nextLineDuration,
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
        } else {
            layoutLabels(size: displaySize)
            if !NSEqualRects(frame, targetFrame) {
                setFrame(targetFrame, display: true)
            } else if didTextChange || didLineChange {
                continentView.needsDisplay = true
            }
        }
        isPresented = true
    }

    func hide() {
        guard isPresented || isVisible else { return }
        cancelPendingTextFadeIn()
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

        let currentSize = frame.size.width > 20 && frame.size.height > 8 ? frame.size : baseSize
        let collapsedSize = presentationCollapsedSize(for: currentSize)
        animatePresentationOut(to: continentFrame(size: collapsedSize), duration: 0.105) { [weak self] in
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
        let lyricFont = Self.configuredFont(
            familyName: configuredFontName,
            size: configuredFontSize,
            weight: .semibold,
            managerWeight: 8
        )
        let titleFont = Self.configuredFont(
            familyName: configuredFontName,
            size: max(Metrics.minFontSize, configuredFontSize - 2.4),
            weight: .medium,
            managerWeight: 6
        )
        lyricLabel.font = lyricFont
        titleLabel.font = titleFont
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
        rootView.frame = NSRect(origin: .zero, size: size)
        rootView.layer?.contentsScale = backingScaleFactor > 0 ? backingScaleFactor : (screen?.backingScaleFactor ?? 2)
        continentView.frame = NSRect(origin: .zero, size: size)
        textContainerView.frame = NSRect(origin: .zero, size: size)
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
        let textHeight = min(
            max(22, ceil(configuredFontSize + 10)),
            max(20, size.height - Metrics.topBleed + 2)
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

        let collapsedSize = presentationCollapsedSize(for: frame.size)
        animatePresentationOut(to: continentFrame(size: collapsedSize), duration: 0.105)
    }

    private func startHoverRestoreTimer() {
        hoverRestoreTimer?.invalidate()
        let timer = Timer(timeInterval: 0.035, repeats: true) { [weak self] _ in
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
        animatePresentationIn(to: targetFrame, targetSize: targetSize, duration: 0.18)
    }

    private func pulseContentUpdate() {
        // Intentionally no frame pulse.  Lyric updates happen frequently, so changing the window
        // size here makes the top-attached continent look jittery.
        continentView.needsDisplay = true
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
        layer.drawsAsynchronously = true
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

    private func easeOutCubic(_ t: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, t))
        let inverse = 1 - clamped
        return 1 - inverse * inverse * inverse
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
            // Monotonic expand with no overshoot.  Width and height both reach the final value a
            // little before the timeline ends, so the last frames are visually stable instead of
            // doing a tiny rebound / correction near the stop point.
            let scaleProgress = easedProgress(t, completesAt: 0.82, power: 3.35)
            let heightProgress = easedProgress(t, completesAt: 0.86, power: 3.55)
            let opacityProgress = easedProgress(t, completesAt: 0.58, power: 2.9)
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
            // Hide should feel decisive, not springy: opacity leaves slightly ahead of the
            // size change, and the shape contracts monotonically toward the top center.
            let scaleProgress = easeInCubic(t)
            let heightProgress = smootherstep(t)
            let fadeProgress = smoothstep(min(1, t * 1.22))
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

    private func cancelPendingTextFadeIn() {
        pendingTextFadeInWorkItem?.cancel()
        pendingTextFadeInWorkItem = nil
    }

    private func scheduleTextContentFadeIn(after delay: TimeInterval, generation: Int) {
        cancelPendingTextFadeIn()
        var scheduledWorkItem: DispatchWorkItem?
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      (scheduledWorkItem?.isCancelled ?? true) == false,
                      self.presentationAnimationGeneration == generation,
                      self.isPresented || self.isVisible
                else { return }
                self.fadeTextContentInAfterPresentation()
                self.pendingTextFadeInWorkItem = nil
            }
        }
        scheduledWorkItem = workItem
        pendingTextFadeInWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: workItem)
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

    private func fadeTextContentInAfterPresentation() {
        // Fade from an explicit zero after the background has already settled.  This prevents the
        // glyph layer from becoming visible during any fractional background transform frames.
        setTextContentOpacity(0)
        animateTextContentOpacity(
            from: 0,
            to: 1,
            duration: 0.175,
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

        cancelPendingTextFadeIn()
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
        for view in textContentViews {
            view.layer?.opacity = startContentOpacity
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

        let textFadeOutDuration = isShowing
            ? min(0.034, max(0.018, duration * 0.18))
            : min(0.030, max(0.014, duration * 0.26))
        // Text never participates in the background scale/rebound.  It leaves immediately at the
        // start of show/hide, stays fully invisible while the silhouette moves, and only fades
        // back after the background has reached its final stable frame.
        fadeTextContentOutForPresentation(from: startContentOpacity, duration: textFadeOutDuration)

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
                for view in self.textContentViews {
                    view.layer?.removeAnimation(forKey: "dynamicContinentContentOpacity")
                    view.layer?.opacity = 0
                }
                CATransaction.commit()
                completion?()
                if isShowing, self.presentationAnimationGeneration == generation {
                    // Wait one run-loop turn plus a tiny hold after the background CA animations have
                    // committed and layout has been refreshed by the completion block.  The text then
                    // fades in on a static layer, not during the settle frames.
                    self.scheduleTextContentFadeIn(after: 0.045, generation: generation)
                } else {
                    self.cancelPendingTextFadeIn()
                }
            }
        }
        layer.add(scaleXAnimation, forKey: "dynamicContinentScaleX")
        layer.add(scaleYAnimation, forKey: "dynamicContinentScaleY")
        layer.add(opacityAnimation, forKey: "dynamicContinentOpacity")
        CATransaction.commit()
    }


    private func animatePresentationIn(to targetFrame: NSRect, targetSize: NSSize, duration: TimeInterval = 0.19) {
        let wasVisuallyHidden = alphaValue < 0.05 || !isVisible
        setFrame(targetFrame, display: true)
        layoutLabels(size: targetSize)
        if wasVisuallyHidden {
            setTextContentOpacity(0)
        }
        hasShadow = false
        alphaValue = 1

        guard let layer = preparePresentationLayer() else { return }
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
            self.setFrame(targetFrame, display: true)
            self.layoutLabels(size: targetSize)
            self.hasShadow = false
        }
    }

    private func animatePresentationOut(to targetFrame: NSRect, duration: TimeInterval, completion: (@Sendable @MainActor () -> Void)? = nil) {
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
        alphaValue = max(alphaValue, 1)
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
            _ = targetFrame
            completion?()
        }
    }


}
@MainActor
private final class MenuBarLyricsTickerDisplayLinkTarget: NSObject {
    weak var view: MenuBarLyricsTickerView?

    init(view: MenuBarLyricsTickerView) {
        self.view = view
    }

    @objc func displayLinkDidFire(_ link: CADisplayLink) {
        view?.displayLinkDidFire(link)
    }
}

@MainActor
private final class MenuBarLyricsTickerView: NSView {
    private struct LineTiming {
        var identity: TimeInterval?
        var duration: CFTimeInterval?
        var previousDuration: CFTimeInterval?
        var nextDuration: CFTimeInterval?
        var elapsedAtSync: CFTimeInterval
        var syncedAt: CFTimeInterval
        /// Visual timeline speed. Normally 1.0; after pause/resume it is nudged slightly
        /// above/below 1.0 so the menu bar text catches up without a visible position jump.
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

    private struct Metrics {
        static let horizontalInset: CGFloat = 7
        static let wrapGap: CGFloat = 36
        static let fallbackSpeed: CGFloat = 46
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
            attributedText = nil
            needsDisplay = true
        }
    }

    private var stringValue = ""
    private var attributedText: NSAttributedString?
    private var measuredTextRect: NSRect = .zero
    private var measuredSize: NSSize = .zero
    private var textVersion = 0
    private var lineTiming = LineTiming(
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
    private var cachedPlan: TimedScrollPlan?
    private var timedOffsetMemory: (identity: TimeInterval?, maxOffset: CGFloat, offset: CGFloat)?
    private var untimedState = UntimedState()
    private var untimedPausedAt: CFTimeInterval?
    private var activeDisplayLink: CADisplayLink?
    private var displayLinkTarget: MenuBarLyricsTickerDisplayLinkTarget?

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
        isPlaying: Bool = true
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldText = stringValue
        if oldText != trimmed {
            stringValue = trimmed
            resetTextCaches()
            resetLineState(keepsTiming: false)
        }
        syncLineTiming(
            identity: lineStartTime,
            duration: lineDuration,
            elapsed: lineElapsed,
            previousDuration: previousLineDuration,
            nextDuration: nextLineDuration,
            isPlaying: isPlaying
        )
        updateAnimationState()
        needsDisplay = true
    }

    func clear() {
        stringValue = ""
        attributedText = nil
        measuredTextRect = .zero
        measuredSize = .zero
        cachedPlan = nil
        timingIsFresh = false
        timingIsPaused = false
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
        let sample = renderSample(maxOffset: maxOffset, shouldScroll: shouldScroll)
        let x = drawingOriginX(textWidth: textSize.width, shouldScroll: shouldScroll, offset: sample.offset, textRect: textRect)
        let y = verticallyCenteredTextY()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        if sample.alpha < 0.999 {
            NSGraphicsContext.current?.cgContext.setAlpha(sample.alpha)
        }
        attributed.draw(at: NSPoint(x: x, y: y))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func syncLineTiming(
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
        let visualElapsedBeforeUpdate = lineTiming.elapsed(at: now, isPaused: timingIsPaused)

        let identityChanged = didLineIdentityChange(from: lineTiming.identity, to: normalizedIdentity)
        if identityChanged {
            resetLineState(keepsTiming: true)
            lineTiming.identity = normalizedIdentity
            lineTiming.duration = normalizedDuration
            lineTiming.previousDuration = normalizedPrevious
            lineTiming.nextDuration = normalizedNext
            lineTiming.elapsedAtSync = normalizedElapsed
            lineTiming.syncedAt = now
            lineTiming.rate = 1.0
            timingIsFresh = normalizedDuration != nil
            timingIsPaused = shouldFreezeTiming
            invalidateScrollPlan()
            return
        }

        let oldDuration = lineTiming.duration
        let oldPrevious = lineTiming.previousDuration
        let oldNext = lineTiming.nextDuration
        let wasPaused = timingIsPaused
        lineTiming.identity = normalizedIdentity
        lineTiming.duration = normalizedDuration
        lineTiming.previousDuration = normalizedPrevious
        lineTiming.nextDuration = normalizedNext
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
                lineTiming.elapsedAtSync = normalizedDuration.map { min(max(0, visualElapsedBeforeUpdate), $0) } ?? max(0, visualElapsedBeforeUpdate)
                lineTiming.syncedAt = now
                lineTiming.rate = 1.0
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
            lineTiming.elapsedAtSync = frozenElapsed
            lineTiming.syncedAt = now
            lineTiming.rate = correctionRate(forDrift: normalizedElapsed - frozenElapsed, duration: normalizedDuration)
        } else if oldDuration == nil, normalizedDuration != nil {
            lineTiming.elapsedAtSync = normalizedElapsed
            lineTiming.syncedAt = now
            lineTiming.rate = 1.0
        } else if let duration = normalizedDuration {
            let predicted = lineTiming.elapsed(at: now, isPaused: timingIsPaused)
            let drift = normalizedElapsed - predicted
            if isLikelySeek(drift: drift, predicted: predicted, reported: normalizedElapsed, duration: duration) {
                lineTiming.elapsedAtSync = normalizedElapsed
                lineTiming.syncedAt = now
                lineTiming.rate = 1.0
                timedOffsetMemory = nil
                invalidateScrollPlan()
            } else {
                // Never correct ordinary polling drift by moving the offset immediately. Keep the
                // current position as the base and use a small speed bias to catch up or slow down.
                lineTiming.elapsedAtSync = predicted
                lineTiming.syncedAt = now
                lineTiming.rate = correctionRate(forDrift: drift, duration: normalizedDuration)
            }
        } else {
            lineTiming.elapsedAtSync = normalizedElapsed
            lineTiming.syncedAt = now
            lineTiming.rate = 1.0
        }

        if durationChanged(oldDuration, normalizedDuration)
            || neighborDurationChanged(oldPrevious, normalizedPrevious)
            || neighborDurationChanged(oldNext, normalizedNext) {
            invalidateScrollPlan()
        }
    }

    private func renderSample(maxOffset: CGFloat, shouldScroll: Bool) -> (offset: CGFloat, alpha: CGFloat) {
        guard shouldScroll else { return (0, 1) }
        let now = CACurrentMediaTime()
        if let duration = lineTiming.duration, timingIsFresh {
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
        let textRect = protectedTextRect()
        let textSize = measuredSizeForCurrentText()
        let maxOffset = max(0, textSize.width - textRect.width)
        guard maxOffset > 8 else { return }
        _ = untimedSample(at: timestamp, maxOffset: maxOffset)
    }

    private func scrollPlan(duration: CFTimeInterval, maxOffset: CGFloat) -> TimedScrollPlan {
        let signature = currentSignature(duration: duration, maxOffset: maxOffset)
        if let cachedPlan, cachedPlan.signature == signature {
            return cachedPlan
        }

        let visibleWidth = max(1, protectedTextRect().width)
        let overflowRatio = clamp(CFTimeInterval(maxOffset / visibleWidth), 0.03, 6.0)
        let fontSize = CFTimeInterval(max(10, font.pointSize))
        let current = clamp(duration, 0.14, 42.0)
        let previous = lineTiming.previousDuration ?? current
        let next = lineTiming.nextDuration ?? current
        let rhythm = weightedRhythm(previous: previous, current: current, next: next)
        let characterCount = CFTimeInterval(max(1, stringValue.count))

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

        let switchReserve = clamp(current * 0.010, 0.002, 0.024)
        let usableDuration = max(0.080, current - switchReserve)
        let readableSpeed = clamp(
            fontSize * (1.18 + overflowRatio * 0.080)
                + 32.0
                + tempoPressure * 20.0
                + densityPressure * 18.0
                - slowSection * 7.0,
            52.0,
            154.0
        )

        let relaxedHeadHold = clamp(current * (0.070 + slowSection * 0.018), 0.070, 0.320)
        let compactHeadHold = clamp(current * (0.012 + overflowPressure * 0.004), 0.003, 0.055)
        var headHold = mix(relaxedHeadHold, compactHeadHold, urgency)
        headHold = clamp(headHold - tempoPressure * 0.026 - overflowPressure * 0.016, 0.002, usableDuration * 0.24)

        let desiredTailHold = clamp(current * (0.115 + slowSection * 0.038), 0.145, 0.520)
        let compactTailHold = clamp(current * (0.060 - shortLinePressure * 0.018), 0.034, 0.125)
        var tailHold = mix(desiredTailHold, compactTailHold, urgency)
        tailHold = clamp(tailHold, 0.030, usableDuration * 0.40)

        let naturalTravel = CFTimeInterval(maxOffset) / max(1, readableSpeed)
        let ordinaryLine = urgency < 0.72 && current > 1.25
        if ordinaryLine {
            let extraTail = min(usableDuration * 0.070, max(0, usableDuration - headHold - tailHold - naturalTravel) * 0.66)
            tailHold += max(0, extraTail)
        }

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

        let earlyFinishBias = clamp(0.090 + slowSection * 0.060 - urgency * 0.055, 0.020, 0.155)
        let preferredTravelCap = max(0.038, travelBudget * (1.0 - earlyFinishBias))
        let minimumTravel = clamp(0.095 + overflowPressure * 0.030 - shortLinePressure * 0.045, 0.040, 0.300)
        let travelDuration = clamp(naturalTravel, min(minimumTravel, preferredTravelCap), preferredTravelCap)

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

    private func timedOffset(at timestamp: CFTimeInterval, plan: TimedScrollPlan) -> CGFloat {
        let elapsed = lineTiming.elapsed(at: timestamp, isPaused: timingIsPaused)
        let rawOffset: CGFloat
        if elapsed <= plan.startDelay {
            let warmup = clamp(elapsed / max(0.001, plan.startDelay), 0, 1)
            rawOffset = plan.leadInOffset * CGFloat(easeOutCubic(warmup))
        } else if elapsed >= plan.travelEnd {
            rawOffset = plan.targetOffset
        } else {
            let progress = clamp((elapsed - plan.startDelay) / max(0.001, plan.travelDuration), 0, 1)
            let curve = CGFloat(readableMotionCurve(progress, rampFraction: plan.rampFraction))
            let remainingDistance = max(0, plan.targetOffset - plan.leadInOffset)
            rawOffset = plan.leadInOffset + remainingDistance * curve
        }
        return continuousTimedOffset(rawOffset, maxOffset: plan.targetOffset)
    }

    private func continuousTimedOffset(_ rawOffset: CGFloat, maxOffset: CGFloat) -> CGFloat {
        let clampedOffset = min(max(0, rawOffset), maxOffset)
        guard !timingIsPaused else {
            timedOffsetMemory = (lineTiming.identity, maxOffset, clampedOffset)
            return clampedOffset
        }

        if let memory = timedOffsetMemory {
            let sameIdentity = !didLineIdentityChange(from: memory.identity, to: lineTiming.identity)
            let sameDistance = abs(memory.maxOffset - maxOffset) <= 2.0
            if sameIdentity && sameDistance {
                let stabilized = max(memory.offset, clampedOffset)
                timedOffsetMemory = (lineTiming.identity, maxOffset, stabilized)
                return stabilized
            }
        }

        timedOffsetMemory = (lineTiming.identity, maxOffset, clampedOffset)
        return clampedOffset
    }

    private func untimedSample(at timestamp: CFTimeInterval, maxOffset: CGFloat) -> (offset: CGFloat, alpha: CGFloat) {
        let elapsed = timestamp - untimedState.phaseStartedAt
        let travelDuration = max(1.25, CFTimeInterval(maxOffset / max(18, Metrics.fallbackSpeed)))

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

    private func updateLayerScale() {
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func updateAnimationState() {
        guard window != nil else {
            stopDisplayDriver()
            return
        }
        if !timingIsPaused, !stringValue.isEmpty, bounds.width > 2, measuredSizeForCurrentText().width > protectedTextRect().width + 8 {
            startDisplayDriver()
        } else {
            stopDisplayDriver()
        }
        needsDisplay = true
    }

    private func startDisplayDriver() {
        guard activeDisplayLink == nil, window != nil else { return }
        let target = MenuBarLyricsTickerDisplayLinkTarget(view: self)
        let link = displayLink(target: target, selector: #selector(MenuBarLyricsTickerDisplayLinkTarget.displayLinkDidFire(_:)))
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

    fileprivate func displayLinkDidFire(_ link: CADisplayLink) {
        needsDisplay = true
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
        textVersion &+= 1
        attributedText = nil
        measuredTextRect = .zero
        measuredSize = .zero
        invalidateScrollPlan()
    }

    private func resetLineState(keepsTiming: Bool) {
        untimedState = UntimedState(phase: .headHold, phaseStartedAt: CACurrentMediaTime(), resetSwapped: false, offset: 0, alpha: 1)
        cachedPlan = nil
        timedOffsetMemory = nil
        if !keepsTiming {
            lineTiming = LineTiming(identity: nil, duration: nil, previousDuration: nil, nextDuration: nil, elapsedAtSync: 0, syncedAt: CACurrentMediaTime(), rate: 1.0)
            timingIsFresh = false
            timingIsPaused = false
            untimedPausedAt = nil
        }
        needsDisplay = true
    }

    private func invalidateScrollPlan() {
        cachedPlan = nil
        needsDisplay = true
    }

    private func currentSignature(duration: CFTimeInterval, maxOffset: CGFloat) -> ScrollPlanSignature {
        ScrollPlanSignature(
            textVersion: textVersion,
            widthBucket: Int((protectedTextRect().width / 2).rounded()),
            textWidthBucket: Int((maxOffset / 2).rounded()),
            fontBucket: Int((font.pointSize * 10).rounded()),
            durationBucket: bucket(lineTiming.duration ?? duration),
            previousBucket: bucket(lineTiming.previousDuration ?? duration),
            nextBucket: bucket(lineTiming.nextDuration ?? duration)
        )
    }

    private func bucket(_ value: CFTimeInterval) -> Int {
        Int((value * 5).rounded())
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

    private func mix(_ a: CFTimeInterval, _ b: CFTimeInterval, _ amount: CFTimeInterval) -> CFTimeInterval {
        let t = clamp(amount, 0, 1)
        return a + (b - a) * t
    }

    private func clamp(_ value: CFTimeInterval, _ lower: CFTimeInterval, _ upper: CFTimeInterval) -> CFTimeInterval {
        min(max(value, lower), upper)
    }

    private func smoothstepIntegral(_ value: CFTimeInterval) -> CFTimeInterval {
        let t = clamp(value, 0, 1)
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

    func prepare() {
        let item = ensureStatusItem()
        item.isVisible = true
        item.length = configuredWidth
        let ticker = ensureTickerView(on: item)
        ticker.setText("音乐歌词", lineStartTime: nil, lineDuration: nil, lineElapsed: 0)
        item.button?.toolTip = "播放白名单应用中的音乐时显示歌词"
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
        let combined = compactTitle(primary: text, translation: showsTranslation ? translation : nil)
        let ticker = ensureTickerView(on: item)
        ticker.setText(
            combined,
            lineStartTime: lineStartTime,
            lineDuration: lineDuration,
            lineElapsed: lineElapsed,
            previousLineDuration: previousLineDuration,
            nextLineDuration: nextLineDuration,
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

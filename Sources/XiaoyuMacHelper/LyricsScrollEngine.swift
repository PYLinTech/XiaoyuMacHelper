import AppKit
import QuartzCore

/// 歌词滚动引擎（单实现）：桌面歌词行视图（DesktopLyricsLineView，灵动大陆歌词行即其复用）
/// 与菜单栏歌词视图（MenuBarLyricsTickerView）共用。
///
/// 行为基准 = 灵动大陆/桌面歌词调优后的实现：smootherstep 缓动曲线、逐词 fluid 引导、
/// 长行多份 repeat marquee、静音占位文本处理、连续阻尼防卡顿。两表面各自仅保留
/// 绘制、文本测量与 display link 驱动层，滚动时序与采样全部收敛到此。
@MainActor
final class LyricsScrollEngine {
    struct LineTiming {
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

    struct ScrollPlanSignature: Equatable {
        var textVersion: Int
        var widthBucket: Int
        var textWidthBucket: Int
        var fontBucket: Int
        var durationBucket: Int
        var wordTimingBucket: Int
    }

    struct WordScrollAnchor {
        var time: CFTimeInterval
        var offset: CGFloat
    }

    struct TimedScrollPlan {
        var signature: ScrollPlanSignature
        var travelDuration: CFTimeInterval
        var targetOffset: CGFloat
        var rampFraction: CFTimeInterval
        var repeatCount: Int
        var repeatStride: CGFloat
        var wordAnchors: [WordScrollAnchor]
    }

    struct RenderSample {
        var offset: CGFloat
        var alpha: CGFloat
        var repeatCount: Int
        var repeatStride: CGFloat
    }

    struct UntimedState {
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

    /// 宿主测量回调：按宿主字体/对齐属性排版内联文本并返回宽度（逐词锚点用）。
    var measureInlineWidth: (String) -> CGFloat = { _ in 0 }
    /// 宿主回调：返回当前文本的 maxOffset（文本宽 - 可视宽）；暂停冻结未计时运动时使用。
    var currentMaxOffset: () -> CGFloat = { 0 }
    /// 引擎内部状态变化需要宿主重绘时回调（原视图的 needsDisplay = true）。
    var onRequestRedraw: (() -> Void)?

    private(set) var timing = LineTiming(
        identity: nil,
        duration: nil,
        previousDuration: nil,
        nextDuration: nil,
        elapsedAtSync: 0,
        syncedAt: CACurrentMediaTime(),
        rate: 1.0
    )
    private(set) var timingIsFresh = false
    private(set) var timingIsPaused = false

    var text: String = ""
    var fontPointSize: CGFloat = 28
    var alignment: NSTextAlignment = .center
    /// Untimed fallback speed. Timed lines use the adaptive cross-line planner instead.
    var fallbackScrollSpeed: CGFloat = 48

    private var textVersion = 0
    private var cachedPlan: TimedScrollPlan?
    private var timedOffsetMemory: (identity: TimeInterval?, maxOffset: CGFloat, offset: CGFloat, timestamp: CFTimeInterval)?
    private var wordTimings: [DesktopLyricWordTiming] = []
    private var untimedState = UntimedState()
    private var untimedPausedAt: CFTimeInterval?

    // MARK: - 失效与复位

    /// 文本内容或排版属性变化时由宿主调用：版本号自增并废弃滚动计划。
    func invalidateTextCaches() {
        textVersion &+= 1
        invalidateScrollPlan()
    }

    func invalidateScrollPlan() {
        cachedPlan = nil
        onRequestRedraw?()
    }

    /// 文本行改变时复位行状态；keepsTiming = true 仅复位未计时滚动状态、保留时序。
    /// 宿主负责在调用后自行刷新动画驱动（updateAnimationState）。
    func resetLineState(keepsTiming: Bool) {
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
        onRequestRedraw?()
    }

    /// 完全清空时序与滚动状态（菜单栏 clear 等场景）。
    func clearAll() {
        resetLineState(keepsTiming: false)
    }

    // MARK: - 时序同步

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
        let lineDuration = normalizedDuration(duration)
        let normalizedPrevious = normalizedDuration(previousDuration)
        let normalizedNext = normalizedDuration(nextDuration)
        let normalizedWords = normalizedWordTimings(wordTimings, duration: lineDuration)
        let wordsChanged = normalizedWords != self.wordTimings
        if wordsChanged {
            self.wordTimings = normalizedWords
            timedOffsetMemory = nil
            invalidateScrollPlan()
        }
        let normalizedElapsed = lineDuration.map { min(max(0, elapsed), $0) } ?? max(0, elapsed)
        let shouldFreezeTiming = !isPlaying
        let visualElapsedBeforeUpdate = timing.elapsed(at: now, isPaused: timingIsPaused)

        let identityChanged = didLineIdentityChange(from: timing.identity, to: normalizedIdentity)
        if identityChanged {
            resetLineState(keepsTiming: true)
            timing.identity = normalizedIdentity
            timing.duration = lineDuration
            timing.previousDuration = normalizedPrevious
            timing.nextDuration = normalizedNext
            timing.elapsedAtSync = normalizedElapsed
            timing.syncedAt = now
            timing.rate = 1.0
            timingIsFresh = lineDuration != nil
            timingIsPaused = shouldFreezeTiming
            invalidateScrollPlan()
            return
        }

        let oldDuration = timing.duration
        let oldPrevious = timing.previousDuration
        let oldNext = timing.nextDuration
        let wasPaused = timingIsPaused
        timing.identity = normalizedIdentity
        timing.duration = lineDuration
        timing.previousDuration = normalizedPrevious
        timing.nextDuration = normalizedNext
        timingIsFresh = lineDuration != nil
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
                timing.elapsedAtSync = lineDuration.map { min(max(0, visualElapsedBeforeUpdate), $0) } ?? max(0, visualElapsedBeforeUpdate)
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
            let frozenElapsed = lineDuration.map { min(max(0, visualElapsedBeforeUpdate), $0) } ?? max(0, visualElapsedBeforeUpdate)
            timing.elapsedAtSync = frozenElapsed
            timing.syncedAt = now
            timing.rate = correctionRate(forDrift: normalizedElapsed - frozenElapsed, duration: lineDuration)
        } else if oldDuration == nil, lineDuration != nil {
            timing.elapsedAtSync = normalizedElapsed
            timing.syncedAt = now
            timing.rate = 1.0
        } else if let duration = lineDuration {
            let predicted = timing.elapsed(at: now, isPaused: timingIsPaused)
            let drift = normalizedElapsed - predicted
            if isLikelySeek(drift: drift, predicted: predicted, reported: normalizedElapsed, duration: duration) {
                timing.elapsedAtSync = normalizedElapsed
                timing.syncedAt = now
                timing.rate = 1.0
                timedOffsetMemory = nil
                invalidateScrollPlan()
            } else if abs(drift) < 0.24 {
                // Ordinary polling jitter should not keep changing the velocity bias. Rebase to
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
                timing.rate = correctionRate(forDrift: drift, duration: lineDuration)
            }
        } else {
            timing.elapsedAtSync = normalizedElapsed
            timing.syncedAt = now
            timing.rate = 1.0
        }

        if durationChanged(oldDuration, lineDuration)
            || neighborDurationChanged(oldPrevious, normalizedPrevious)
            || neighborDurationChanged(oldNext, normalizedNext) {
            invalidateScrollPlan()
        }
    }

    // MARK: - 采样

    func renderSample(
        maxOffset: CGFloat,
        shouldScroll: Bool,
        viewportWidth: CGFloat,
        now: CFTimeInterval
    ) -> RenderSample {
        if DesktopLyricsParser.isSilencePlaceholderText(text) {
            return RenderSample(offset: 0, alpha: 1, repeatCount: 1, repeatStride: 0)
        }
        guard shouldScroll else { return RenderSample(offset: 0, alpha: 1, repeatCount: 1, repeatStride: 0) }
        if let duration = timing.duration, timingIsFresh {
            let plan = scrollPlan(duration: duration, maxOffset: maxOffset, viewportWidth: viewportWidth)
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

    /// 暂停时冻结未计时滚动运动的当前帧（状态已写入 untimedState，无需返回值）。
    private func freezeUntimedMotion(at timestamp: CFTimeInterval) {
        let maxOffset = currentMaxOffset()
        guard maxOffset > 8 else { return }
        _ = untimedSample(at: timestamp, maxOffset: maxOffset)
    }

    private func scrollPlan(duration: CFTimeInterval, maxOffset: CGFloat, viewportWidth: CGFloat) -> TimedScrollPlan {
        let signature = currentSignature(duration: duration, maxOffset: maxOffset, viewportWidth: viewportWidth)
        if let cachedPlan, cachedPlan.signature == signature {
            return cachedPlan
        }

        let visibleWidth = max(1, viewportWidth)
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

        // Timed lyrics use a direct visual-time formula. There is no separate head hold,
        // travel phase, or tail hold: every rendered frame maps the current line's elapsed time to
        // a deterministic offset. This is the actual marquee model:
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

    private func currentSignature(duration: CFTimeInterval, maxOffset: CGFloat, viewportWidth: CGFloat) -> ScrollPlanSignature {
        ScrollPlanSignature(
            textVersion: textVersion,
            widthBucket: Int((viewportWidth / 2).rounded()),
            textWidthBucket: Int((maxOffset / 2).rounded()),
            fontBucket: Int((fontPointSize * 10).rounded()),
            durationBucket: bucket(timing.duration ?? duration),
            wordTimingBucket: wordTimingBucket()
        )
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
        // stop-start motion. Word mode uses a lighter one-frame damper and only hard-snaps
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

    // MARK: - 计划构建

    private func timedRepeatCount(
        duration: CFTimeInterval,
        viewportWidth: CGFloat,
        textWidth: CGFloat,
        maxOffset: CGFloat
    ) -> Int {
        if DesktopLyricsParser.isSilencePlaceholderText(text) || !wordTimings.isEmpty { return 1 }
        let visible = max(1, CFTimeInterval(viewportWidth))
        let total = max(visible, CFTimeInterval(textWidth))
        let scrollable = max(0, CFTimeInterval(maxOffset))
        guard scrollable > 8 else { return 1 }

        // Repeat-count planning is intentionally based on the two stable dimensions of a timed
        // lyric line:
        //   1. the line's total duration;
        //   2. the full text length / visible viewport length.
        // It no longer uses raw pixel speed as the primary trigger. That keeps the decision tied
        // to the lyric itself and avoids tiny width/timing jitter flipping the copy count.
        let lengthRatio = clamp(total / visible, 1.0, 7.5)
        let overflowRatio = max(0.0, lengthRatio - 1.0)

        // Do not enter repeated mode for ordinary short lines. Wider text is already visually
        // moving across more content, so it needs a little more time before we allow repetition.
        let minimumRepeatDuration = 5.55 + min(1.65, overflowRatio) * 0.72
        guard duration >= minimumRepeatDuration else { return 1 }

        let gapRatio = CFTimeInterval(repeatGapWidth(viewportWidth: viewportWidth)) / visible
        let strideUnits = max(1.0, lengthRatio + gapRatio)

        // The maximum grows slowly with total line time. This makes repetition an n-copy model
        // instead of a hard-coded 2/3-copy model, while still preventing sudden high-copy jumps.
        let durationHeadroom = max(0, duration - minimumRepeatDuration)
        let maxRepeatsByDuration = min(8, max(1, 2 + Int(floor(durationHeadroom / 3.15))))

        var repeats = 1
        while repeats < maxRepeatsByDuration {
            let currentUnits = max(0.12, overflowRatio + CFTimeInterval(repeats - 1) * strideUnits)
            let secondsPerViewportUnit = duration / currentUnits

            // Higher repeat levels require stronger evidence. This small progressive threshold is
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
        let fontScaled = fontPointSize * 2.35
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

        // The ramp is part of the formula, not a separate delay. It only shapes velocity at the
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

    // MARK: - 逐词时序

    private func normalizedWordTimings(_ timings: [DesktopLyricWordTiming], duration: CFTimeInterval?) -> [DesktopLyricWordTiming] {
        let textLength = text.utf16.count
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
        let nsText = text as NSString
        let preferredCenter = preferredAnchorCenter(viewportWidth: viewportWidth)
        var anchors: [WordScrollAnchor] = [WordScrollAnchor(time: 0, offset: 0)]
        var lastOffset: CGFloat = 0
        for timing in wordTimings {
            guard timing.utf16End <= nsText.length else { continue }
            let prefix = nsText.substring(with: NSRange(location: 0, length: timing.utf16Location))
            let segment = nsText.substring(with: NSRange(location: timing.utf16Location, length: timing.utf16Length))
            let segmentCenter = measureInlineWidth(prefix) + measureInlineWidth(segment) / 2
            let rawTarget = min(maxOffset, max(lastOffset, segmentCenter - preferredCenter))
            let target = max(lastOffset, rawTarget)
            let anchorTime = clamp(mix(timing.start, timing.end, 0.35), 0, duration)
            let minimumVisualStep = max(3.5, min(7.0, fontPointSize * 0.16))
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

    // MARK: - 时序归一化与数学工具

    private func normalizedIdentity(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else { return nil }
        return (value * 1000).rounded() / 1000
    }

    private func normalizedDuration(_ value: TimeInterval?) -> CFTimeInterval? {
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

    private func bucket(_ value: CFTimeInterval) -> Int {
        Int((value * 5).rounded())
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

    private func easeOutCubic(_ value: CFTimeInterval) -> CFTimeInterval {
        let t = clamp(value, 0, 1)
        let p = 1 - t
        return 1 - p * p * p
    }
}

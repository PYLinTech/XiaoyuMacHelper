import AppKit

@MainActor
final class DesktopLyricsController {
    private enum Metrics {
        static let pollInterval: TimeInterval = 0.1
    }

    private struct RenderedLineContext {
        var trackKey: String
        var primary: String
        var translation: String?
        var trackTitle: String
        var lineIndex: Int?
        var lineStartTime: TimeInterval?
        var lineDuration: TimeInterval?
        var lineElapsed: TimeInterval
        var previousLineDuration: TimeInterval?
        var nextLineDuration: TimeInterval?
        var wordTimings: [DesktopLyricWordTiming]
    }

    private var settings: AppSettings
    private let lyricsWindow: DesktopLyricsWindow
    private let islandWindow = DynamicIslandLyricsWindow()
    private let menuBarSurface = MenuBarLyricsSurface()
    private var pollTimer: Timer?
    private var lyricsResolveTask: Task<Void, Never>?
    private var lyricsResolveGeneration: UInt64 = 0
    private var resolvingTrackKey: String?
    private var isResolvingLyrics: Bool {
        guard let currentTrackKey else { return false }
        return resolvingTrackKey == currentTrackKey
    }
    private var currentTrackKey: String?
    private var currentProviderName: String?
    private var currentLines: [DesktopLyricLine] = []
    private var presentationTrackKey: String?
    private var presentationElapsedAtSync: TimeInterval = 0
    private var presentationSyncedAt: CFTimeInterval = CACurrentMediaTime()
    private var presentationRate: TimeInterval = 1.0
    private var presentationIsPaused = false
    private var stableLineTrackKey: String?
    private var stableLineIndex: Int?
    private var stableLineLastElapsed: TimeInterval = 0
    private var stableLineSwitchedAt: CFTimeInterval = CACurrentMediaTime()
    private var lastRenderedLineContext: RenderedLineContext?
    private var pausedRenderedLineContext: RenderedLineContext?
    private var cachedLyrics: [String: DesktopLyricsSearchResult] = [:]
    private var searchService: DesktopLyricsSearchService
    var onPositionChanged: ((NSPoint) -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        self.lyricsWindow = DesktopLyricsWindow(settings: settings)
        self.searchService = DesktopLyricsSearchService(settings: settings)
        islandWindow.apply(settings: settings)
        menuBarSurface.apply(settings: settings)
        lyricsWindow.onPositionChanged = { [weak self] origin in
            self?.settings.desktopLyricsPositionX = Double(origin.x)
            self?.settings.desktopLyricsPositionY = Double(origin.y)
            self?.onPositionChanged?(origin)
        }
    }

    func start() {
        guard settings.isDesktopLyricsEnabled else {
            cancelLyricsResolve()
            resetPresentationState()
            hideAllSurfaces()
            return
        }

        startPollingIfNeeded()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        cancelLyricsResolve()
        resetPresentationState()
        hideAllSurfaces()
    }

    func update(settings: AppSettings) {
        let didTokenChange = self.settings.appleMusicMediaUserToken != settings.appleMusicMediaUserToken
        let didSourceOrderChange = self.settings.desktopLyricsSourceOrder != settings.desktopLyricsSourceOrder
        let didLanguageChange = self.settings.desktopLyricsPreferredLanguage != settings.desktopLyricsPreferredLanguage
        lyricsWindow.apply(settings: settings)
        islandWindow.apply(settings: settings)
        menuBarSurface.apply(settings: settings)
        self.settings = settings
        if didTokenChange || didSourceOrderChange || didLanguageChange {
            cancelLyricsResolve()
            searchService = DesktopLyricsSearchService(settings: settings)
            cachedLyrics.removeAll()
            currentTrackKey = nil
            currentProviderName = nil
            currentLines = []
            resetPresentationState()
        }

        if settings.isDesktopLyricsEnabled {
            start()
        } else {
            stop()
        }
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Metrics.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollNowPlaying()
            }
        }
        timer.tolerance = 0.008
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        timer.fire()
    }

    private func pollNowPlaying() async {
        guard settings.isDesktopLyricsEnabled else {
            cancelLyricsResolve()
            resetPresentationState()
            hideAllSurfaces()
            return
        }
        guard let track = await DesktopLyricsNowPlayingProvider.currentTrack() else {
            cancelLyricsResolve()
            currentTrackKey = nil
            currentProviderName = nil
            currentLines = []
            resetPresentationState()
            hideAllSurfaces()
            return
        }

        guard track.isValidForLyrics,
              isAllowedByWhitelist(appName: track.appName, bundleIdentifier: track.appBundleIdentifier) else {
            cancelLyricsResolve()
            currentTrackKey = nil
            currentProviderName = nil
            currentLines = []
            resetPresentationState()
            hideAllSurfaces()
            return
        }

        if track.cacheKey != currentTrackKey {
            currentTrackKey = track.cacheKey
            currentProviderName = nil
            currentLines = []
            resetPresentationState()
            show(primary: "正在搜索歌词：\(track.displayTitle)", translation: nil, trackTitle: track.displayTitle, islandPrimary: "正在搜索歌词", isPlaying: track.isPlaying)
            beginResolveLyrics(for: track)
        }

        let isPauseEdge = presentationTrackKey == track.cacheKey && !presentationIsPaused && !track.isPlaying
        let displayElapsedTime = presentationElapsedTime(for: track)

        if isPauseEdge,
           let lastRenderedLineContext,
           lastRenderedLineContext.trackKey == track.cacheKey {
            pausedRenderedLineContext = lastRenderedLineContext
            show(rendered: lastRenderedLineContext, isPlaying: false)
            return
        }

        if !track.isPlaying,
           let pausedRenderedLineContext,
           pausedRenderedLineContext.trackKey == track.cacheKey {
            show(rendered: pausedRenderedLineContext, isPlaying: false)
            return
        }

        if track.isPlaying {
            pausedRenderedLineContext = nil
        }

        if let context = stableCurrentLineContext(in: currentLines, at: displayElapsedTime, track: track) {
            let rendered = renderedLineContext(from: context, track: track)
            lastRenderedLineContext = rendered
            show(rendered: rendered, isPlaying: track.isPlaying)
        } else if isResolvingLyrics {
            lastRenderedLineContext = nil
            show(primary: "正在搜索歌词：\(track.displayTitle)", translation: nil, trackTitle: track.displayTitle, islandPrimary: "正在搜索歌词", isPlaying: track.isPlaying)
        } else if currentLines.isEmpty {
            lastRenderedLineContext = nil
            show(primary: "未找到歌词：\(track.displayTitle)", translation: nil, trackTitle: track.displayTitle, islandPrimary: "未找到歌词", isPlaying: track.isPlaying)
        }
    }

    private func presentationElapsedTime(for track: DesktopLyricsTrack) -> TimeInterval {
        let now = CACurrentMediaTime()
        let reported = clampedElapsed(track.elapsedTime, duration: track.duration)

        guard presentationTrackKey == track.cacheKey else {
            presentationTrackKey = track.cacheKey
            presentationElapsedAtSync = reported
            presentationSyncedAt = now
            presentationRate = 1.0
            presentationIsPaused = !track.isPlaying
            return reported
        }

        let predicted = currentPresentationElapsed(at: now, duration: track.duration)

        guard track.isPlaying else {
            if !presentationIsPaused {
                presentationElapsedAtSync = predicted
                presentationSyncedAt = now
                presentationRate = 1.0
                presentationIsPaused = true
            }
            return presentationElapsedAtSync
        }

        if presentationIsPaused {
            presentationElapsedAtSync = predicted
            presentationSyncedAt = now
            presentationRate = presentationCorrectionRate(forDrift: reported - predicted, duration: track.duration)
            presentationIsPaused = false
            return predicted
        }

        let drift = reported - predicted
        if isLikelyPlaybackSeek(drift: drift, predicted: predicted, reported: reported, duration: track.duration) {
            presentationElapsedAtSync = reported
            presentationSyncedAt = now
            presentationRate = 1.0
            return reported
        }

        presentationElapsedAtSync = predicted
        presentationSyncedAt = now
        presentationRate = presentationCorrectionRate(forDrift: drift, duration: track.duration)
        return predicted
    }

    private func currentPresentationElapsed(at now: CFTimeInterval, duration: TimeInterval?) -> TimeInterval {
        let raw = presentationIsPaused
            ? presentationElapsedAtSync
            : presentationElapsedAtSync + (now - presentationSyncedAt) * presentationRate
        return clampedElapsed(raw, duration: duration)
    }

    private func presentationCorrectionRate(forDrift drift: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        let recoveryWindow = min(max((duration ?? 180.0) * 0.018, 0.85), 2.80)
        let requestedBias = drift / max(0.20, recoveryWindow)
        return 1.0 + min(max(requestedBias, -0.10), 0.14)
    }

    private func isLikelyPlaybackSeek(
        drift: TimeInterval,
        predicted: TimeInterval,
        reported: TimeInterval,
        duration: TimeInterval?
    ) -> Bool {
        if reported + 0.45 < predicted { return true }
        let trackAwareThreshold = min(max((duration ?? 180.0) * 0.018, 2.25), 6.0)
        return abs(drift) > trackAwareThreshold
    }

    private func clampedElapsed(_ elapsed: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        let safeElapsed = elapsed.isFinite ? max(0, elapsed) : 0
        guard let duration, duration.isFinite, duration > 0 else { return safeElapsed }
        return min(safeElapsed, duration)
    }

    private func resetPresentationState() {
        presentationTrackKey = nil
        presentationElapsedAtSync = 0
        presentationSyncedAt = CACurrentMediaTime()
        presentationRate = 1.0
        presentationIsPaused = false
        lastRenderedLineContext = nil
        pausedRenderedLineContext = nil
        resetStableLineSelection()
    }

    private func stableCurrentLineContext(
        in lines: [DesktopLyricLine],
        at displayElapsedTime: TimeInterval,
        track: DesktopLyricsTrack
    ) -> DesktopLyricLineContext? {
        guard let rawIndex = visualLineIndex(in: lines, at: displayElapsedTime, trackDuration: track.duration) else {
            resetStableLineSelection()
            return nil
        }

        let now = CACurrentMediaTime()
        if stableLineTrackKey != track.cacheKey || stableLineIndex == nil {
            stableLineTrackKey = track.cacheKey
            stableLineIndex = rawIndex
            stableLineLastElapsed = displayElapsedTime
            stableLineSwitchedAt = now
            return DesktopLyricsParser.lineContext(in: lines, index: rawIndex, at: displayElapsedTime, trackDuration: track.duration)
        }

        guard var stableIndex = stableLineIndex, lines.indices.contains(stableIndex) else {
            stableLineIndex = rawIndex
            stableLineLastElapsed = displayElapsedTime
            stableLineSwitchedAt = now
            return DesktopLyricsParser.lineContext(in: lines, index: rawIndex, at: displayElapsedTime, trackDuration: track.duration)
        }

        let previousElapsed = stableLineLastElapsed
        let elapsedJump = displayElapsedTime - previousElapsed
        if isLikelyLyricSeek(
            rawIndex: rawIndex,
            stableIndex: stableIndex,
            elapsedJump: elapsedJump,
            displayElapsedTime: displayElapsedTime,
            lines: lines
        ) {
            stableLineIndex = rawIndex
            stableLineLastElapsed = displayElapsedTime
            stableLineSwitchedAt = now
            return DesktopLyricsParser.lineContext(in: lines, index: rawIndex, at: displayElapsedTime, trackDuration: track.duration)
        }

        if rawIndex > stableIndex {
            while stableIndex + 1 < lines.count {
                guard now - stableLineSwitchedAt >= 0.055 else { break }
                let nextStart = lines[stableIndex + 1].time
                let gap = max(0, nextStart - lines[stableIndex].time)
                let commitDelay = lineSwitchCommitDelay(previousGap: gap)
                guard displayElapsedTime >= nextStart + commitDelay else { break }
                stableIndex += 1
                stableLineSwitchedAt = now
                if stableIndex >= rawIndex { break }
            }
        } else if rawIndex < stableIndex {
            let currentStart = lines[stableIndex].time
            let tolerance = backwardLineBoundaryTolerance(currentGap: stableLineDuration(in: lines, index: stableIndex, trackDuration: track.duration))
            if displayElapsedTime < currentStart - tolerance {
                stableIndex = rawIndex
                stableLineSwitchedAt = now
            }
        }

        stableLineIndex = stableIndex
        stableLineLastElapsed = max(previousElapsed, displayElapsedTime)
        return DesktopLyricsParser.lineContext(in: lines, index: stableIndex, at: displayElapsedTime, trackDuration: track.duration)
    }

    private func renderedLineContext(from context: DesktopLyricLineContext, track: DesktopLyricsTrack) -> RenderedLineContext {
        RenderedLineContext(
            trackKey: track.cacheKey,
            primary: context.line.text,
            translation: context.line.translation,
            trackTitle: track.displayTitle,
            lineIndex: context.index,
            lineStartTime: context.line.time,
            lineDuration: context.duration,
            lineElapsed: context.elapsedInLine,
            previousLineDuration: context.previousDuration,
            nextLineDuration: context.nextDuration,
            wordTimings: context.line.wordTimings
        )
    }

    private func resetStableLineSelection() {
        stableLineTrackKey = nil
        stableLineIndex = nil
        stableLineLastElapsed = 0
        stableLineSwitchedAt = CACurrentMediaTime()
    }

    private func isLikelyLyricSeek(
        rawIndex: Int,
        stableIndex: Int,
        elapsedJump: TimeInterval,
        displayElapsedTime: TimeInterval,
        lines: [DesktopLyricLine]
    ) -> Bool {
        if elapsedJump < -0.85 { return true }
        if elapsedJump > 3.50 { return true }
        if abs(rawIndex - stableIndex) >= 3 { return true }
        if lines.indices.contains(stableIndex), displayElapsedTime + 1.20 < lines[stableIndex].time { return true }
        return false
    }

    private func lineSwitchCommitDelay(previousGap: TimeInterval) -> TimeInterval {
        // The renderer now consumes the whole line duration for scrolling, so an extra visual
        // commit delay would look like the lyric finished and waited. Keep only a tiny debounce to
        // absorb Now Playing timestamp jitter at the exact boundary.
        guard previousGap.isFinite, previousGap > 0 else { return 0.020 }
        return min(0.040, max(0.014, previousGap * 0.004))
    }

    private func backwardLineBoundaryTolerance(currentGap: TimeInterval?) -> TimeInterval {
        guard let currentGap, currentGap.isFinite, currentGap > 0 else { return 0.32 }
        if currentGap >= 12.0 { return 0.85 }
        if currentGap >= 7.0 { return 0.58 }
        return min(0.38, max(0.20, currentGap * 0.030))
    }

    private func stableLineDuration(in lines: [DesktopLyricLine], index: Int, trackDuration: TimeInterval?) -> TimeInterval? {
        guard lines.indices.contains(index) else { return nil }
        let line = lines[index]
        let endTime: TimeInterval?
        if let explicitEnd = line.endTime, explicitEnd.isFinite, explicitEnd > line.time + 0.12 {
            endTime = explicitEnd
        } else if index + 1 < lines.count {
            endTime = lines[index + 1].time
        } else {
            endTime = trackDuration
        }
        guard let endTime, endTime.isFinite else { return nil }
        return max(0, endTime - line.time)
    }

    private func visualLineIndex(
        in lines: [DesktopLyricLine],
        at elapsedTime: TimeInterval,
        trackDuration: TimeInterval?
    ) -> Int? {
        guard !lines.isEmpty else { return nil }
        let safeTime = elapsedTime.isFinite ? max(0, elapsedTime) : 0
        guard safeTime + 0.001 >= lines[lines.startIndex].time else { return nil }

        var index = lines.startIndex
        while index + 1 < lines.count {
            let boundary = visualSwitchBoundary(
                from: lines[index],
                to: lines[index + 1],
                previousIndex: index,
                nextIndex: index + 1,
                lines: lines,
                trackDuration: trackDuration
            )
            guard safeTime + 0.001 >= boundary else { break }
            index += 1
        }
        return index
    }

    private func visualSwitchBoundary(
        from previous: DesktopLyricLine,
        to next: DesktopLyricLine,
        previousIndex: Int,
        nextIndex: Int,
        lines: [DesktopLyricLine],
        trackDuration: TimeInterval?
    ) -> TimeInterval {
        let nextStart = next.time
        guard nextStart.isFinite else { return previous.time }

        // Placeholders intentionally own long silence. Do not preview a real lyric through a
        // leading/interlude placeholder, otherwise the old “blank intro shows lyrics too early”
        // problem comes back.
        guard !isSilencePlaceholderText(previous.text), !isSilencePlaceholderText(next.text) else {
            return nextStart
        }

        if let previousEnd = effectiveLineEndTime(in: lines, index: previousIndex, trackDuration: trackDuration),
           previousEnd.isFinite,
           previousEnd < nextStart - 0.035 {
            // If Apple Music gives a real gap between two sung lines, switch at the visual midpoint
            // of that gap. The outgoing line has already finished, and the incoming line gets time
            // to fade in before its first word.
            return max(previous.time, min(nextStart, (previousEnd + nextStart) * 0.5))
        }

        // When there is no explicit gap, the previous code changed exactly at the next line's
        // begin time. That made the crossfade and edge mask eat the first characters. Shift the
        // visual switch a small amount earlier, so the fade is centered around the line boundary
        // instead of starting after it.
        let previousDuration = stableLineDuration(in: lines, index: previousIndex, trackDuration: trackDuration) ?? 3.0
        let nextDuration = stableLineDuration(in: lines, index: nextIndex, trackDuration: trackDuration) ?? 3.0
        let sharedDuration = min(max(0.45, previousDuration), max(0.45, nextDuration))
        let visualLead = min(0.34, max(0.12, sharedDuration * 0.085))
        return max(previous.time + 0.08, nextStart - visualLead)
    }

    private func effectiveLineEndTime(in lines: [DesktopLyricLine], index: Int, trackDuration: TimeInterval?) -> TimeInterval? {
        guard lines.indices.contains(index) else { return nil }
        let line = lines[index]
        if let explicitEnd = line.endTime, explicitEnd.isFinite, explicitEnd > line.time + 0.12 {
            return explicitEnd
        }
        if index + 1 < lines.count { return lines[index + 1].time }
        return trackDuration
    }

    private func isSilencePlaceholderText(_ text: String) -> Bool {
        let compact = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return false }
        return compact.allSatisfy { $0 == "." || $0 == "…" || $0 == "⋯" }
    }


    private func show(rendered context: RenderedLineContext, isPlaying: Bool) {
        show(
            primary: context.primary,
            translation: context.translation,
            trackTitle: context.trackTitle,
            lineStartTime: context.lineStartTime,
            lineDuration: context.lineDuration,
            lineElapsed: context.lineElapsed,
            previousLineDuration: context.previousLineDuration,
            nextLineDuration: context.nextLineDuration,
            wordTimings: context.wordTimings,
            isPlaying: isPlaying
        )
    }

    private func show(
        primary: String,
        translation: String?,
        trackTitle: String? = nil,
        islandPrimary: String? = nil,
        lineStartTime: TimeInterval? = nil,
        lineDuration: TimeInterval? = nil,
        lineElapsed: TimeInterval = 0,
        previousLineDuration: TimeInterval? = nil,
        nextLineDuration: TimeInterval? = nil,
        wordTimings: [DesktopLyricWordTiming] = [],
        isPlaying: Bool = true
    ) {
        if settings.isDesktopLyricsSurfaceEnabled {
            lyricsWindow.show(
                primary: primary,
                translation: translation,
                showsTranslation: settings.desktopLyricsShowsTranslation,
                lineStartTime: lineStartTime,
                lineDuration: lineDuration,
                lineElapsed: lineElapsed,
                previousLineDuration: previousLineDuration,
                nextLineDuration: nextLineDuration,
                wordTimings: wordTimings,
                isPlaying: isPlaying
            )
        } else {
            lyricsWindow.hide()
        }

        if settings.isDynamicIslandLyricsEnabled {
            islandWindow.show(
                primary: islandPrimary ?? primary,
                translation: translation,
                showsTranslation: settings.desktopLyricsShowsTranslation,
                songTitle: trackTitle,
                lineStartTime: lineStartTime,
                lineDuration: lineDuration,
                lineElapsed: lineElapsed,
                previousLineDuration: previousLineDuration,
                nextLineDuration: nextLineDuration,
                wordTimings: wordTimings,
                isPlaying: isPlaying
            )
        } else {
            islandWindow.hide()
        }

        if settings.isMenuBarLyricsEnabled {
            menuBarSurface.show(
                primary: primary,
                translation: translation,
                showsTranslation: settings.desktopLyricsShowsTranslation,
                lineStartTime: lineStartTime,
                lineDuration: lineDuration,
                lineElapsed: lineElapsed,
                previousLineDuration: previousLineDuration,
                nextLineDuration: nextLineDuration,
                wordTimings: wordTimings,
                isPlaying: isPlaying
            )
        } else {
            menuBarSurface.hide()
        }
    }

    private func hideAllSurfaces() {
        lyricsWindow.hide()
        islandWindow.hide()
        menuBarSurface.hide()
    }

    private func isAllowedByWhitelist(appName: String, bundleIdentifier: String) -> Bool {
        let normalizedAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedBundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedBundleIdentifier.isEmpty || !normalizedAppName.isEmpty else { return false }
        let rawWhitelist = settings.musicLyricsAppWhitelist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawWhitelist != "__empty__" else { return false }

        if rawWhitelist.isEmpty {
            let value = "\(normalizedAppName) \(normalizedBundleIdentifier)"
            return value.contains("music") || value.contains("音乐")
        }

        let allowedBundleIdentifiers = rawWhitelist
            .components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        if !normalizedBundleIdentifier.isEmpty {
            return allowedBundleIdentifiers.contains(normalizedBundleIdentifier)
        }
        return false
    }

    private func beginResolveLyrics(for track: DesktopLyricsTrack) {
        lyricsResolveGeneration &+= 1
        let generation = lyricsResolveGeneration
        let trackKey = track.cacheKey

        lyricsResolveTask?.cancel()
        lyricsResolveTask = nil
        resolvingTrackKey = nil

        if let cached = cachedLyrics[trackKey] {
            applyLyricsResult(cached, forTrackKey: trackKey, generation: generation)
            return
        }

        resolvingTrackKey = trackKey
        let searchService = searchService
        lyricsResolveTask = Task { [weak self, searchService, track, trackKey, generation] in
            let result = await searchService.searchLyrics(for: track)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.applyLyricsResult(result, forTrackKey: trackKey, generation: generation)
            }
        }
    }

    private func applyLyricsResult(_ result: DesktopLyricsSearchResult?, forTrackKey trackKey: String, generation: UInt64) {
        guard generation == lyricsResolveGeneration,
              currentTrackKey == trackKey else {
            return
        }

        resolvingTrackKey = nil
        lyricsResolveTask = nil

        guard let result else {
            currentProviderName = nil
            currentLines = []
            return
        }

        cachedLyrics[trackKey] = result
        currentProviderName = result.providerName
        currentLines = result.lines
    }

    private func cancelLyricsResolve() {
        lyricsResolveGeneration &+= 1
        lyricsResolveTask?.cancel()
        lyricsResolveTask = nil
        resolvingTrackKey = nil
    }
}

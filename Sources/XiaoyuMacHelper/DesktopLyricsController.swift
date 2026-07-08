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
        var lineStartTime: TimeInterval?
        var lineDuration: TimeInterval?
        var lineElapsed: TimeInterval
        var previousLineDuration: TimeInterval?
        var nextLineDuration: TimeInterval?
    }

    private var settings: AppSettings
    private let lyricsWindow: DesktopLyricsWindow
    private let islandWindow = DynamicIslandLyricsWindow()
    private let menuBarSurface = MenuBarLyricsSurface()
    private var pollTimer: Timer?
    private var isResolvingLyrics = false
    private var currentTrackKey: String?
    private var currentProviderName: String?
    private var currentLines: [DesktopLyricLine] = []
    private var presentationTrackKey: String?
    private var presentationElapsedAtSync: TimeInterval = 0
    private var presentationSyncedAt: CFTimeInterval = CACurrentMediaTime()
    private var presentationRate: TimeInterval = 1.0
    private var presentationIsPaused = false
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
            resetPresentationState()
            hideAllSurfaces()
            return
        }

        startPollingIfNeeded()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
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
            resetPresentationState()
            hideAllSurfaces()
            return
        }
        guard let track = await DesktopLyricsNowPlayingProvider.currentTrack() else {
            currentTrackKey = nil
            currentProviderName = nil
            currentLines = []
            resetPresentationState()
            hideAllSurfaces()
            return
        }

        guard track.isValidForLyrics,
              isAllowedByWhitelist(appName: track.appName, bundleIdentifier: track.appBundleIdentifier) else {
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
            await resolveLyrics(for: track)
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

        if let context = DesktopLyricsParser.currentLineContext(in: currentLines, at: displayElapsedTime, trackDuration: track.duration) {
            let rendered = RenderedLineContext(
                trackKey: track.cacheKey,
                primary: context.line.text,
                translation: context.line.translation,
                trackTitle: track.displayTitle,
                lineStartTime: context.line.time,
                lineDuration: context.duration,
                lineElapsed: context.elapsedInLine,
                previousLineDuration: context.previousDuration,
                nextLineDuration: context.nextDuration
            )
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
                isPlaying: isPlaying
            )
        } else {
            lyricsWindow.orderOut(nil)
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
                isPlaying: isPlaying
            )
        } else {
            menuBarSurface.hide()
        }
    }

    private func hideAllSurfaces() {
        lyricsWindow.orderOut(nil)
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

    private func resolveLyrics(for track: DesktopLyricsTrack) async {
        guard !isResolvingLyrics else { return }
        isResolvingLyrics = true
        defer { isResolvingLyrics = false }

        if let cached = cachedLyrics[track.cacheKey] {
            currentProviderName = cached.providerName
            currentLines = cached.lines
            return
        }

        guard let result = await searchService.searchLyrics(for: track) else {
            currentProviderName = nil
            currentLines = []
            return
        }

        cachedLyrics[track.cacheKey] = result
        currentProviderName = result.providerName
        currentLines = result.lines
    }
}

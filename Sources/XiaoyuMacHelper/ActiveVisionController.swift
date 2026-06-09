import AppKit

@MainActor
final class ActiveVisionController {
    private enum Metrics {
        static let pollInterval: TimeInterval = 0.20
        static let displaySleepTimeoutRefreshInterval: TimeInterval = 30
        static let requiredPositiveHits = 2
        static let cameraStartupTimeout: TimeInterval = 3
        static let realUserActivityResetThreshold: TimeInterval = 2
        static let virtualTimerResetMargin: TimeInterval = 3
    }

    private enum ActiveVisionWindowState {
        case outside
        case active
        case expired
    }

    private var settings: AppSettings
    private let cameraCapture = CameraFrameCapture()
    private var timer: Timer?
    private var isCameraChecking = false
    private var cameraCheckingStartDate: Date?
    private var hasReceivedCameraResult = false
    private var cameraCheckGeneration = 0
    private var positiveHitCount = 0
    private var cachedDisplaySleepTimeout: TimeInterval?
    private var lastDisplaySleepTimeoutRefreshDate: Date?
    private var virtualDisplaySleepDeadlineDate: Date?
    private let toastWindow = ToastWindow()
    private let powerManager = ActiveVisionPowerManager()

    private var canRunActiveVision: Bool {
        settings.isActiveVisionEnabled &&
        CameraPermission.isAuthorized &&
        hasEnabledAttentionMode
    }

    private var hasEnabledAttentionMode: Bool {
        settings.activeVisionPreventsDisplaySleepOnGaze ||
        settings.activeVisionPreventsDisplaySleepOnFacing
    }

    private struct TimingInfo {
        let idleTime: TimeInterval
        let displaySleepTimeout: TimeInterval

        var secondsUntilDetection: TimeInterval {
            let triggerIdleTime = max(0, displaySleepTimeout - activeVisionLeadTimeBeforeDisplaySleep)
            return max(0, triggerIdleTime - idleTime)
        }
    }

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        updateTimer()
    }

    func update(settings newSettings: AppSettings) {
        let didChangeAttentionMode = settings.activeVisionPreventsDisplaySleepOnGaze != newSettings.activeVisionPreventsDisplaySleepOnGaze ||
            settings.activeVisionPreventsDisplaySleepOnFacing != newSettings.activeVisionPreventsDisplaySleepOnFacing
        let didDisableActiveVision = settings.isActiveVisionEnabled && !newSettings.isActiveVisionEnabled

        settings = newSettings

        if didChangeAttentionMode || didDisableActiveVision {
            stopCameraChecking(force: true)
        }

        updateTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopCameraChecking(force: true)
        cachedDisplaySleepTimeout = nil
        lastDisplaySleepTimeoutRefreshDate = nil
        virtualDisplaySleepDeadlineDate = nil
        powerManager.releaseAll()
    }

    private func updateTimer() {
        guard canRunActiveVision else {
            stop()
            return
        }

        guard timer == nil else {
            return
        }

        let timer = Timer(timeInterval: Metrics.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        guard canRunActiveVision else {
            stop()
            return
        }

        powerManager.releaseExpiredIfNeeded()

        let timingInfo = currentTimingInfo()

        switch currentActiveVisionWindowState(timingInfo: timingInfo) {
        case .outside:
            stopCameraChecking()
        case .active:
            recoverCameraCheckingIfNeeded()
            startCameraCheckingIfNeeded()
        case .expired:
            stopCameraChecking()
            virtualDisplaySleepDeadlineDate = nil
            powerManager.releaseAll()
        }
    }

    private func recoverCameraCheckingIfNeeded() {
        guard isCameraChecking,
              !hasReceivedCameraResult,
              let cameraCheckingStartDate,
              Date().timeIntervalSince(cameraCheckingStartDate) >= Metrics.cameraStartupTimeout else {
            return
        }

        stopCameraChecking()
    }

    private func startCameraCheckingIfNeeded() {
        guard !isCameraChecking else {
            return
        }

        cameraCheckGeneration &+= 1
        let generation = cameraCheckGeneration
        isCameraChecking = true
        cameraCheckingStartDate = Date()
        hasReceivedCameraResult = false
        cameraCapture.startChecking(needsGaze: settings.activeVisionPreventsDisplaySleepOnGaze) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.handle(result: result, generation: generation)
            }
        }
    }

    private func stopCameraChecking(force: Bool = false) {
        guard isCameraChecking || force else {
            resetDetectionWindow()
            return
        }

        cameraCheckGeneration &+= 1
        isCameraChecking = false
        resetDetectionWindow()
        cameraCapture.stopChecking()
    }

    private func handle(result: FaceAttentionResult?, generation: Int) {
        guard isCameraChecking, generation == cameraCheckGeneration else {
            return
        }

        hasReceivedCameraResult = true

        guard currentActiveVisionWindowState(timingInfo: currentTimingInfo()) == .active else {
            stopCameraChecking()
            return
        }

        guard let result else {
            stopCameraChecking()
            return
        }

        guard matchesEnabledAttentionMode(result) else {
            positiveHitCount = 0
            return
        }

        positiveHitCount += 1
        guard positiveHitCount >= Metrics.requiredPositiveHits else {
            return
        }

        guard extendDisplaySleep() else {
            positiveHitCount = 0
            return
        }

        completeSuccessfulExtension()
    }

    private func completeSuccessfulExtension() {
        scheduleNextDetectionCycle()
        stopCameraChecking()
        if settings.activeVisionNotifiesWhenExtendingDisplaySleep {
            toastWindow.show(message: "已延迟本次息屏")
        }
    }

    private func scheduleNextDetectionCycle() {
        guard let displaySleepTimeout = currentDisplaySleepTimeout(), displaySleepTimeout > 0 else {
            virtualDisplaySleepDeadlineDate = nil
            return
        }

        virtualDisplaySleepDeadlineDate = Date().addingTimeInterval(displaySleepTimeout)
    }

    private func resetDetectionWindow() {
        positiveHitCount = 0
        cameraCheckingStartDate = nil
        hasReceivedCameraResult = false
    }

    private func matchesEnabledAttentionMode(_ result: FaceAttentionResult) -> Bool {
        (settings.activeVisionPreventsDisplaySleepOnGaze && result.isGazingAtScreen) ||
        (settings.activeVisionPreventsDisplaySleepOnFacing && result.isFacingScreen)
    }

    private func currentTimingInfo() -> TimingInfo? {
        guard let displaySleepTimeout = currentDisplaySleepTimeout(), displaySleepTimeout > 0,
              let realIdleTime = currentUserIdleTime() else {
            return nil
        }

        if realIdleTime < Metrics.realUserActivityResetThreshold {
            virtualDisplaySleepDeadlineDate = nil
            return TimingInfo(idleTime: realIdleTime, displaySleepTimeout: displaySleepTimeout)
        }

        if let virtualDisplaySleepDeadlineDate {
            let secondsUntilVirtualDisplaySleep = virtualDisplaySleepDeadlineDate.timeIntervalSinceNow
            let virtualIdleTime = max(0, displaySleepTimeout - secondsUntilVirtualDisplaySleep)

            if realIdleTime + Metrics.virtualTimerResetMargin < virtualIdleTime {
                self.virtualDisplaySleepDeadlineDate = nil
                return TimingInfo(idleTime: realIdleTime, displaySleepTimeout: displaySleepTimeout)
            }

            return TimingInfo(idleTime: virtualIdleTime, displaySleepTimeout: displaySleepTimeout)
        }

        return TimingInfo(idleTime: realIdleTime, displaySleepTimeout: displaySleepTimeout)
    }

    private func currentActiveVisionWindowState(timingInfo: TimingInfo?) -> ActiveVisionWindowState {
        guard let timingInfo else {
            return .outside
        }

        if timingInfo.idleTime >= timingInfo.displaySleepTimeout {
            return .expired
        }

        return timingInfo.secondsUntilDetection <= 0 ? .active : .outside
    }

    private func currentDisplaySleepTimeout() -> TimeInterval? {
        let now = Date()
        if let cachedDisplaySleepTimeout,
           let lastDisplaySleepTimeoutRefreshDate,
           now.timeIntervalSince(lastDisplaySleepTimeoutRefreshDate) < Metrics.displaySleepTimeoutRefreshInterval {
            return cachedDisplaySleepTimeout
        }

        let timeout = readDisplaySleepTimeoutFromPMSet()
        cachedDisplaySleepTimeout = timeout
        lastDisplaySleepTimeoutRefreshDate = now
        return timeout
    }

    private func readDisplaySleepTimeoutFromPMSet() -> TimeInterval? {
        ActiveVisionTiming.readDisplaySleepTimeoutFromPMSet()
    }

    private func currentUserIdleTime() -> TimeInterval? {
        ActiveVisionTiming.currentUserIdleTime()
    }

    @discardableResult
    private func extendDisplaySleep() -> Bool {
        powerManager.extendDisplaySleep(displaySleepTimeout: currentDisplaySleepTimeout())
    }

}

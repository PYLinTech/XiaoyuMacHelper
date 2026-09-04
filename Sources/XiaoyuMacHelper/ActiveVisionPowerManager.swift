import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt

@MainActor
final class ActiveVisionPowerManager {
    private enum Metrics {
        static let assertionReason = "Xiaoyu MacHelper 主动视觉感知检测到用户仍在屏幕前"
        // 成功识别后声明用户活动会重置系统空闲计时；这里短暂持有显示器防睡断言，只用于兜底避免临界点竞态。
        static let guardDuration: TimeInterval = 8
        // 如果系统不接受用户活动声明，则退化为至少延迟一轮显示器睡眠时间。
        static let fallbackMinimumDuration: TimeInterval = 60
    }

    private let displaySleepAssertion = PowerAssertionToken()
    private let userActivityAssertion = PowerAssertionToken()

    @discardableResult
    func extendDisplaySleep(displaySleepTimeout: TimeInterval?) -> Bool {
        if declareUserActivity() {
            _ = holdDisplaySleepAssertion(for: Metrics.guardDuration)
            return true
        }

        // 极少数系统环境下如果用户活动声明不可用，就退回到“持有防显示器睡眠断言一整轮”。
        // 这样至少不会出现 toast 已提示成功但马上息屏的问题。
        let fallbackDuration = max(validDuration(displaySleepTimeout), Metrics.fallbackMinimumDuration)
        return holdDisplaySleepAssertion(for: fallbackDuration)
    }

    func releaseAll() {
        displaySleepAssertion.release()
        userActivityAssertion.release()
    }

    private func validDuration(_ duration: TimeInterval?) -> TimeInterval {
        guard let duration, duration.isFinite, duration > 0 else {
            return 0
        }
        return duration
    }

    @discardableResult
    private func declareUserActivity() -> Bool {
        // macOS 10.12+ 公开 API，直接静态调用（无需 dlopen/dlsym 动态查找）。
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionDeclareUserActivity(
            Metrics.assertionReason as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            return false
        }

        userActivityAssertion.hold(assertionID, duration: Metrics.guardDuration)
        return true
    }

    @discardableResult
    private func holdDisplaySleepAssertion(for duration: TimeInterval) -> Bool {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Metrics.assertionReason as CFString,
            &assertionID
        )

        guard result == kIOReturnSuccess else {
            return false
        }

        displaySleepAssertion.hold(assertionID, duration: duration)
        return true
    }
}

@MainActor
private final class PowerAssertionToken {
    private var assertionID = IOPMAssertionID(0)
    private var releaseTimer: Timer?

    func hold(_ newAssertionID: IOPMAssertionID, duration: TimeInterval) {
        release()
        guard newAssertionID != 0 else {
            return
        }

        guard duration.isFinite, duration > 0 else {
            IOPMAssertionRelease(newAssertionID)
            return
        }

        let holdDuration = max(duration, 1)
        assertionID = newAssertionID

        let timer = Timer(timeInterval: holdDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.release()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
    }

    func release() {
        releaseTimer?.invalidate()
        releaseTimer = nil

        guard assertionID != 0 else {
            return
        }

        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }
}

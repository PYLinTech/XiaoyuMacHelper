@preconcurrency import CoreGraphics
@preconcurrency import CoreFoundation
import Foundation
import os

/// 侧键按钮号（CGEventButtonNumber）：3 = 后退，4 = 前进。
private let miscBackButtonNumber: Int64 = 3
private let miscForwardButtonNumber: Int64 = 4

/// 方括号键虚拟键码（kVK_ANSI_BracketLeft / kVK_ANSI_BracketRight，Carbon Events.h）。
private let miscBracketLeftKeyCode: UInt16 = 0x21
private let miscBracketRightKeyCode: UInt16 = 0x1E

/// 杂项模块控制器：当前实现「鼠标滚轮反向」与「鼠标侧键映射前进/后退」。
///
/// 实现原理：单个 CGEventTap 拦截会话事件，按开关分流处理——
/// - scrollWheel：将纵向/横向的行增量与像素增量取反后放行，等效反转滚动方向；
/// - otherMouse（侧键）：侧键 3（后退）→ 模拟 ⌘[，侧键 4（前进）→ 模拟 ⌘]，
///   并吞掉原始按键事件；不修改系统设置，关闭开关即恢复原生行为。
/// 事件拦截与键盘模拟均依赖辅助功能权限（由 App 层在勾选时守卫）。
@MainActor
final class MiscController {
    private var settings: AppSettings
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// tap 回调为 C 函数指针且运行在 nonisolated 上下文：开关状态经锁同步供其读取，
    /// 仅在 apply()（设置变化）时由主线程写入。
    private struct TapFlags: Sendable {
        var wheelInverted = false
        var sideMapping = false
    }

    private let tapFlags = OSAllocatedUnfairLock<TapFlags>(initialState: TapFlags())

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        apply()
    }

    func stop() {
        tapFlags.withLock {
            $0.wheelInverted = false
            $0.sideMapping = false
        }
        removeTap()
    }

    func update(settings: AppSettings) {
        self.settings = settings
        apply()
    }

    private func apply() {
        let wheelInverted = settings.isMiscMouseWheelInverted
        let sideMapping = settings.isMiscMouseSideButtonsForwardBackEnabled
        tapFlags.withLock {
            $0.wheelInverted = wheelInverted
            $0.sideMapping = sideMapping
        }

        if wheelInverted || sideMapping {
            installTapIfNeeded()
        } else {
            removeTap()
        }
    }

    private func installTapIfNeeded() {
        guard eventTap == nil else {
            return
        }

        let eventMask: CGEventMask =
            (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
        // 回调为 C 函数指针，无法捕获 self：以 Unmanaged 指针穿透传递。
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<MiscController>.fromOpaque(userInfo).takeUnretainedValue()
            return controller.handleEvent(event, type: type)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    private func removeTap() {
        guard let tap = eventTap else {
            return
        }

        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private nonisolated func handleEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        // 系统可能因超时/用户输入禁用 tap：重新启用以保持功能持续生效。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTapSource() {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let flags = tapFlags.withLock { $0 }
        switch type {
        case .scrollWheel:
            guard flags.wheelInverted else {
                return Unmanaged.passUnretained(event)
            }
            invertField(.scrollWheelEventDeltaAxis1, of: event)
            invertField(.scrollWheelEventPointDeltaAxis1, of: event)
            invertField(.scrollWheelEventDeltaAxis2, of: event)
            invertField(.scrollWheelEventPointDeltaAxis2, of: event)
            return Unmanaged.passUnretained(event)
        case .otherMouseDown, .otherMouseUp:
            guard flags.sideMapping else {
                return Unmanaged.passUnretained(event)
            }
            return handleSideButton(event, isMouseDown: type == .otherMouseDown)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// 侧键处理：mouseDown 时模拟 ⌘[/⌘]（后退/前进），down/up 均吞掉原事件（返回 nil）。
    private nonisolated func handleSideButton(_ event: CGEvent, isMouseDown: Bool) -> Unmanaged<CGEvent>? {
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        guard buttonNumber == miscBackButtonNumber || buttonNumber == miscForwardButtonNumber else {
            return Unmanaged.passUnretained(event)
        }

        if isMouseDown {
            let virtualKey = buttonNumber == miscBackButtonNumber
                ? miscBracketLeftKeyCode
                : miscBracketRightKeyCode
            postNavigationKey(virtualKey: virtualKey)
        }
        return nil
    }

    /// 模拟一次 ⌘+按键 的 down/up 序列，投递到会话事件流。
    private nonisolated func postNavigationKey(virtualKey: CGKeyCode) {
        for keyDown in [true, false] {
            guard let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: keyDown) else {
                continue
            }
            keyEvent.flags = .maskCommand
            keyEvent.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private nonisolated func eventTapSource() -> CFMachPort? {
        MainActor.assumeIsolated { eventTap }
    }

    /// 仅对非零字段取反，避免无谓写入触发系统对事件的重新标注。
    private nonisolated func invertField(_ field: CGEventField, of event: CGEvent) {
        let value = event.getIntegerValueField(field)
        guard value != 0 else {
            return
        }
        event.setIntegerValueField(field, value: -value)
    }
}

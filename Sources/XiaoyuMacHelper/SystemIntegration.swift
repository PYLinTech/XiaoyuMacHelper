import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Darwin
import IOKit
import IOKit.hidsystem
import ScreenCaptureKit
import ServiceManagement

final class SingleInstanceLock {
    private let lockURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(appIdentifier).lock")
    private var lockDescriptor: Int32 = -1

    func acquireOrNotifyRunningInstance(shouldNotifyRunningInstance: Bool) -> Bool {
        lockDescriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0 else {
            return true
        }

        if flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 {
            ftruncate(lockDescriptor, 0)
            let pidText = "\(getpid())\n"
            pidText.withCString { pointer in
                _ = write(lockDescriptor, pointer, strlen(pointer))
            }
            return true
        }

        if shouldNotifyRunningInstance {
            DistributedNotificationCenter.default().postNotificationName(
                showControlWindowNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
        return false
    }

    func releaseLock() {
        guard lockDescriptor >= 0 else {
            return
        }

        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }
}

enum LoginItemManager {
    static func install() throws {
        try register(SMAppService.mainApp)
    }

    static func uninstall() throws {
        try unregister(SMAppService.mainApp)
    }

    static func isInstalled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func openLoginItemsSettings() {
        SystemSettingsOpener.openLoginItems()
    }

    private static func register(_ service: SMAppService) throws {
        guard service.status != .enabled else {
            return
        }

        do {
            try service.register()
        } catch {
            guard !isServiceManagementError(error, code: kSMErrorAlreadyRegistered) else {
                return
            }

            throw error
        }
    }

    private static func unregister(_ service: SMAppService) throws {
        do {
            try service.unregister()
        } catch {
            guard !isServiceManagementError(error, code: kSMErrorJobNotFound) else {
                return
            }

            throw error
        }
    }

    private static func isServiceManagementError(_ error: Error, code: Int) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SMAppServiceErrorDomain && nsError.code == code
    }
}

enum SystemSettingsOpener {
    static func openLoginItems() {
        open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

enum AccessibilityPermission {
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        SystemSettingsOpener.openAccessibility()
    }
}

@MainActor
enum AlertPresenter {
    @discardableResult
    static func show(
        title: String,
        message: String,
        style: NSAlert.Style = .informational,
        buttons: [String] = ["知道了"]
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }

    static func confirm(title: String, message: String) -> Bool {
        show(title: title, message: message, buttons: ["知道了", "取消"]) == .alertFirstButtonReturn
    }
}

@MainActor
func removeEventMonitor(_ monitor: inout Any?) {
    if let eventMonitor = monitor { NSEvent.removeMonitor(eventMonitor) }
    monitor = nil
}

extension NSRect {
    var area: CGFloat {
        width * height
    }
}


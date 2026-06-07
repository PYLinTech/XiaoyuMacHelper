import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Darwin
import IOKit
import IOKit.hidsystem
import ScreenCaptureKit
import ServiceManagement

enum ToolbarAction: String, Sendable {
    case copy
    case paste
    case search
    case screenshot

    static let configurableCases: [ToolbarAction] = [.copy, .paste, .search, .screenshot]

    var title: String {
        switch self {
        case .copy: return "复制"
        case .paste: return "粘贴"
        case .search: return "搜索"
        case .screenshot: return "截图"
        }
    }

    var shortcutKeyCode: CGKeyCode? {
        switch self {
        case .copy: return CGKeyCode(kVK_ANSI_C)
        case .paste: return CGKeyCode(kVK_ANSI_V)
        case .search, .screenshot: return nil
        }
    }

    var defaultsKey: String? {
        switch self {
        case .copy: return selectionToolbarCopyEnabledKey
        case .paste: return selectionToolbarPasteEnabledKey
        case .search: return selectionToolbarSearchEnabledKey
        case .screenshot: return selectionToolbarScreenshotEnabledKey
        }
    }
}

struct SearchEnginePreset: Equatable {
    let title: String
    let template: String

    static let all: [SearchEnginePreset] = [
        SearchEnginePreset(title: "谷歌", template: "https://www.google.com/search?q=%s"),
        SearchEnginePreset(title: "必应", template: "https://www.bing.com/search?q=%s"),
        SearchEnginePreset(title: "必应中国", template: "https://cn.bing.com/search?q=%s"),
        SearchEnginePreset(title: "百度", template: "https://www.baidu.com/s?wd=%s")
    ]

    static let defaultTemplate = all[0].template
    static let customTitle = "自定义"

    static func presetIndex(for template: String) -> Int? {
        all.firstIndex { $0.template == template }
    }
}

struct AppSettings: Equatable, Sendable {
    var isCapsLockIndicatorEnabled: Bool
    var isClickToDisableEnabled: Bool
    var isSelectionToolbarEnabled: Bool
    var isSelectionToolbarCopyEnabled: Bool
    var isSelectionToolbarPasteEnabled: Bool
    var isSelectionToolbarSearchEnabled: Bool
    var isSelectionToolbarScreenshotEnabled: Bool
    var selectionToolbarOrder: [ToolbarAction]
    var searchURLTemplate: String
    var screenshotSaveDirectory: String
    var screenshotCopiesToClipboard: Bool
    var screenshotSelectsRegion: Bool

    var visibleSelectionToolbarActions: [ToolbarAction] {
        selectionToolbarOrder.filter(isSelectionToolbarActionEnabled)
    }

    func isSelectionToolbarActionEnabled(_ action: ToolbarAction) -> Bool {
        switch action {
        case .copy: return isSelectionToolbarCopyEnabled
        case .paste: return isSelectionToolbarPasteEnabled
        case .search: return isSelectionToolbarSearchEnabled
        case .screenshot: return isSelectionToolbarScreenshotEnabled
        }
    }

    mutating func setSelectionToolbarAction(_ action: ToolbarAction, enabled isEnabled: Bool) {
        switch action {
        case .copy: isSelectionToolbarCopyEnabled = isEnabled
        case .paste: isSelectionToolbarPasteEnabled = isEnabled
        case .search: isSelectionToolbarSearchEnabled = isEnabled
        case .screenshot: isSelectionToolbarScreenshotEnabled = isEnabled
        }
    }
}

struct ControlState: Equatable {
    var settings: AppSettings
    var isLoginItemEnabled: Bool
    var isAccessibilityEnabled: Bool
}

struct LaunchMode {
    let showsControlWindowOnLaunch: Bool
    let notifiesRunningInstance: Bool

    static func current(arguments: [String] = CommandLine.arguments) -> LaunchMode {
        let isLoginItemLaunch = arguments.contains(loginItemArgument)

        return LaunchMode(
            showsControlWindowOnLaunch: !isLoginItemLaunch,
            notifiesRunningInstance: !isLoginItemLaunch
        )
    }
}

final class SettingsStore {
    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            capsLockIndicatorEnabledKey: true,
            capsLockIndicatorClickToDisableEnabledKey: true,
            selectionToolbarEnabledKey: false,
            selectionToolbarCopyEnabledKey: true,
            selectionToolbarPasteEnabledKey: true,
            selectionToolbarSearchEnabledKey: true,
            selectionToolbarScreenshotEnabledKey: true,
            selectionToolbarOrderKey: ToolbarAction.configurableCases.map(\.rawValue),
            searchURLTemplateKey: SearchEnginePreset.defaultTemplate,
            screenshotSaveDirectoryKey: defaultScreenshotDirectoryURL().path,
            screenshotCopiesToClipboardKey: true,
            screenshotSelectsRegionKey: false
        ])

        if !defaults.bool(forKey: selectionToolbarDefaultOffMigrationKey) {
            defaults.set(false, forKey: selectionToolbarEnabledKey)
            defaults.set(true, forKey: selectionToolbarDefaultOffMigrationKey)
        }
    }

    func read() -> AppSettings {
        let savedOrder = defaults.stringArray(forKey: selectionToolbarOrderKey) ?? []
        let order = normalizedOrder(savedOrder.compactMap(ToolbarAction.init(rawValue:)))

        return AppSettings(
            isCapsLockIndicatorEnabled: defaults.bool(forKey: capsLockIndicatorEnabledKey),
            isClickToDisableEnabled: defaults.bool(forKey: capsLockIndicatorClickToDisableEnabledKey),
            isSelectionToolbarEnabled: defaults.bool(forKey: selectionToolbarEnabledKey),
            isSelectionToolbarCopyEnabled: defaults.bool(forKey: selectionToolbarCopyEnabledKey),
            isSelectionToolbarPasteEnabled: defaults.bool(forKey: selectionToolbarPasteEnabledKey),
            isSelectionToolbarSearchEnabled: defaults.bool(forKey: selectionToolbarSearchEnabledKey),
            isSelectionToolbarScreenshotEnabled: defaults.bool(forKey: selectionToolbarScreenshotEnabledKey),
            selectionToolbarOrder: order,
            searchURLTemplate: defaults.string(forKey: searchURLTemplateKey) ?? SearchEnginePreset.defaultTemplate,
            screenshotSaveDirectory: defaults.string(forKey: screenshotSaveDirectoryKey) ?? defaultScreenshotDirectoryURL().path,
            screenshotCopiesToClipboard: defaults.bool(forKey: screenshotCopiesToClipboardKey),
            screenshotSelectsRegion: defaults.bool(forKey: screenshotSelectsRegionKey)
        )
    }

    func setCapsLockIndicatorEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: capsLockIndicatorEnabledKey)
    }

    func setClickToDisableEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: capsLockIndicatorClickToDisableEnabledKey)
    }

    func setSelectionToolbarEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: selectionToolbarEnabledKey)
    }

    func setSelectionToolbarAction(_ action: ToolbarAction, enabled isEnabled: Bool) {
        guard let defaultsKey = action.defaultsKey else {
            return
        }

        defaults.set(isEnabled, forKey: defaultsKey)
    }

    func setSearchURLTemplate(_ template: String) {
        defaults.set(template, forKey: searchURLTemplateKey)
    }

    func setScreenshotSaveDirectory(_ path: String) {
        defaults.set(path, forKey: screenshotSaveDirectoryKey)
    }

    func setScreenshotCopiesToClipboard(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: screenshotCopiesToClipboardKey)
    }

    func setScreenshotSelectsRegion(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: screenshotSelectsRegionKey)
    }

    func clearPersistentData() {
        let domain = Bundle.main.bundleIdentifier ?? appIdentifier
        defaults.removePersistentDomain(forName: domain)
        defaults.synchronize()
    }

    func moveSelectionToolbarAction(_ action: ToolbarAction, direction: Int) {
        var order = read().selectionToolbarOrder
        guard let index = order.firstIndex(of: action) else {
            return
        }

        let newIndex = max(0, min(order.count - 1, index + direction))
        guard newIndex != index else {
            return
        }

        order.remove(at: index)
        order.insert(action, at: newIndex)
        defaults.set(order.map(\.rawValue), forKey: selectionToolbarOrderKey)
    }

    private func normalizedOrder(_ savedOrder: [ToolbarAction]) -> [ToolbarAction] {
        var result: [ToolbarAction] = []

        for action in savedOrder where !result.contains(action) {
            result.append(action)
        }

        for action in ToolbarAction.configurableCases where !result.contains(action) {
            result.append(action)
        }

        return result
    }
}


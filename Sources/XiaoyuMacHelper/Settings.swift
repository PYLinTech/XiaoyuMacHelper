import Carbon
import CoreGraphics
import Foundation

enum ToolbarAction: String, Sendable {
    case selectAll
    case copy
    case paste
    case search
    case screenshot

    /// 可配置集合：全选默认在最前（默认 order = configurableCases 顺序）。
    static let configurableCases: [ToolbarAction] = [.selectAll, .copy, .paste, .search, .screenshot]

    var title: String {
        switch self {
        case .selectAll: return "全选"
        case .copy: return "复制"
        case .paste: return "粘贴"
        case .search: return "搜索"
        case .screenshot: return "截图"
        }
    }

    var shortcutKeyCode: CGKeyCode? {
        switch self {
        case .selectAll: return CGKeyCode(kVK_ANSI_A)
        case .copy: return CGKeyCode(kVK_ANSI_C)
        case .paste: return CGKeyCode(kVK_ANSI_V)
        case .search, .screenshot: return nil
        }
    }

    var defaultsKey: String? {
        switch self {
        case .selectAll: return selectionToolbarSelectAllEnabledKey
        case .copy: return selectionToolbarCopyEnabledKey
        case .paste: return selectionToolbarPasteEnabledKey
        case .search: return selectionToolbarSearchEnabledKey
        case .screenshot: return selectionToolbarScreenshotEnabledKey
        }
    }
}

enum DesktopLyricsSource: String, CaseIterable, Sendable {
    case appleMusic
    case qqMusic
    case netease

    static let defaultOrder: [DesktopLyricsSource] = [.appleMusic, .qqMusic, .netease]

    var title: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .qqMusic: return "QQ 音乐"
        case .netease: return "网易云音乐"
        }
    }
}


enum DesktopLyricsPreferredLanguage: String, CaseIterable, Sendable {
    case simplifiedChinese
    case english
    case traditionalChinese

    static let defaultValue: DesktopLyricsPreferredLanguage = .simplifiedChinese

    var title: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .traditionalChinese: return "繁體中文"
        }
    }

    var appleMusicLyricsLanguageCandidates: [String] {
        switch self {
        case .simplifiedChinese:
            return ["zh-Hans", "zh-Hans-CN", "zh-CN"]
        case .english:
            return ["en-US", "en-GB", "en"]
        case .traditionalChinese:
            return ["zh-Hant", "zh-Hant-TW", "zh-TW", "zh-Hant-HK"]
        }
    }

    var acceptLanguageHeader: String {
        switch self {
        case .simplifiedChinese: return "zh-Hans,zh-Hans-CN;q=0.95,zh-CN;q=0.9,en;q=0.7"
        case .english: return "en-US,en-GB;q=0.95,en;q=0.9"
        case .traditionalChinese: return "zh-Hant,zh-Hant-TW;q=0.95,zh-TW;q=0.9,en;q=0.7"
        }
    }

    var isSimplifiedChinese: Bool { self == .simplifiedChinese }
    var isTraditionalChinese: Bool { self == .traditionalChinese }

    func matches(ttml: String) -> Bool {
        let lowercased = ttml.lowercased()
        switch self {
        case .simplifiedChinese:
            return lowercased.contains("hans") || lowercased.contains("xml:lang=\"zh-cn") || lowercased.contains("xml:lang='zh-cn")
        case .traditionalChinese:
            return lowercased.contains("hant") || lowercased.contains("xml:lang=\"zh-tw") || lowercased.contains("xml:lang='zh-tw")
        case .english:
            return lowercased.contains("xml:lang=\"en") || lowercased.contains("xml:lang='en")
        }
    }
}


enum LyricsTextAlignment: String, CaseIterable, Sendable {
    case left
    case center
    case right

    static let defaultValue: LyricsTextAlignment = .center

    var title: String {
        switch self {
        case .left: return "左对齐"
        case .center: return "居中"
        case .right: return "右对齐"
        }
    }
}

enum DesktopLyricsStylePreset: String, CaseIterable, Sendable {
    case classic
    case softShadow
    case darkPanel
    case lightPanel
    case neon

    static let defaultValue: DesktopLyricsStylePreset = .classic

    var title: String {
        switch self {
        case .classic: return "清晰白字"
        case .softShadow: return "柔和阴影"
        case .darkPanel: return "深色浮层"
        case .lightPanel: return "浅色字幕"
        case .neon: return "霓虹微光"
        }
    }
}

struct SearchEnginePreset: Equatable {
    let title: String
    let template: String

    static let defaultTemplate = "https://cn.bing.com/search?q=%s"

    static let all: [SearchEnginePreset] = [
        SearchEnginePreset(title: "谷歌", template: "https://www.google.com/search?q=%s"),
        SearchEnginePreset(title: "必应", template: "https://www.bing.com/search?q=%s"),
        SearchEnginePreset(title: "必应中国", template: defaultTemplate),
        SearchEnginePreset(title: "百度", template: "https://www.baidu.com/s?wd=%s")
    ]

    static let customTitle = "自定义"

    static func presetIndex(for template: String) -> Int? {
        all.firstIndex { $0.template == template }
    }
}

struct AppSettings: Equatable, Sendable {
    var isCapsLockIndicatorEnabled: Bool
    var isClickToDisableEnabled: Bool
    var isSelectionToolbarEnabled: Bool
    var isSelectionToolbarHideInFullscreen: Bool
    var isSelectionToolbarSelectAllEnabled: Bool
    var isSelectionToolbarCopyEnabled: Bool
    var isSelectionToolbarPasteEnabled: Bool
    var isSelectionToolbarSearchEnabled: Bool
    var isSelectionToolbarScreenshotEnabled: Bool
    var selectionToolbarOrder: [ToolbarAction]
    var searchURLTemplate: String
    var screenshotSaveDirectory: String
    var screenshotCopiesToClipboard: Bool
    var screenshotSelectsRegion: Bool
    var isActiveVisionEnabled: Bool
    var isDesktopLyricsEnabled: Bool
    var isDesktopLyricsSurfaceEnabled: Bool
    var desktopLyricsWidth: Double
    var desktopLyricsAlignment: LyricsTextAlignment
    var isDynamicIslandLyricsEnabled: Bool
    var dynamicIslandLyricsWidth: Double
    var dynamicIslandLyricsBlankWidth: Double
    var dynamicIslandLyricsHeight: Double
    var dynamicIslandLyricsSlantRatio: Double
    var dynamicIslandLyricsCornerRatio: Double
    var dynamicIslandLyricsFontSize: Double
    var dynamicIslandLyricsFontName: String
    var dynamicIslandLyricsAlignment: LyricsTextAlignment
    var isDynamicIslandLyricsSpectrumEnabled: Bool
    var isDynamicIslandLyricsHidesOnHover: Bool
    var isMenuBarLyricsEnabled: Bool
    var menuBarLyricsWidth: Double
    var menuBarLyricsAlignment: LyricsTextAlignment
    var enabledDesktopLyricsSources: [DesktopLyricsSource]
    var desktopLyricsSourceOrder: [DesktopLyricsSource]
    var desktopLyricsPreferredLanguage: DesktopLyricsPreferredLanguage
    var desktopLyricsShowsTranslation: Bool
    var desktopLyricsFontSize: Double
    var desktopLyricsFontName: String
    var desktopLyricsTextColor: String
    var desktopLyricsStrokeColor: String
    var desktopLyricsStrokeWidth: Double
    var desktopLyricsPositionX: Double
    var desktopLyricsPositionY: Double
    var desktopLyricsLocked: Bool
    var desktopLyricsStylePreset: DesktopLyricsStylePreset
    var musicLyricsAppWhitelist: String
    var appleMusicMediaUserToken: String
    var activeVisionPreventsDisplaySleepOnGaze: Bool
    var activeVisionPreventsDisplaySleepOnFacing: Bool
    var activeVisionNotifiesWhenExtendingDisplaySleep: Bool
    var isSlideshowAnnotationEnabled: Bool

    var visibleSelectionToolbarActions: [ToolbarAction] {
        selectionToolbarOrder.filter(isSelectionToolbarActionEnabled)
    }

    func isSelectionToolbarActionEnabled(_ action: ToolbarAction) -> Bool {
        switch action {
        case .selectAll: return isSelectionToolbarSelectAllEnabled
        case .copy: return isSelectionToolbarCopyEnabled
        case .paste: return isSelectionToolbarPasteEnabled
        case .search: return isSelectionToolbarSearchEnabled
        case .screenshot: return isSelectionToolbarScreenshotEnabled
        }
    }

    mutating func setSelectionToolbarAction(_ action: ToolbarAction, enabled isEnabled: Bool) {
        switch action {
        case .selectAll: isSelectionToolbarSelectAllEnabled = isEnabled
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
    /// 用户主动启动（非登录项自启）：显示控制窗，并通知已运行实例。
    let isUserInitiatedLaunch: Bool

    static func current(arguments: [String] = CommandLine.arguments) -> LaunchMode {
        LaunchMode(isUserInitiatedLaunch: !arguments.contains(loginItemArgument))
    }
}

final class SettingsStore {
    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            capsLockIndicatorEnabledKey: true,
            capsLockIndicatorClickToDisableEnabledKey: true,
            selectionToolbarEnabledKey: false,
            selectionToolbarSelectAllEnabledKey: true,
            selectionToolbarCopyEnabledKey: true,
            selectionToolbarPasteEnabledKey: true,
            selectionToolbarSearchEnabledKey: true,
            selectionToolbarScreenshotEnabledKey: false,
            selectionToolbarHideInFullscreenKey: true,
            selectionToolbarOrderKey: ToolbarAction.configurableCases.map(\.rawValue),
            searchURLTemplateKey: SearchEnginePreset.defaultTemplate,
            screenshotSaveDirectoryKey: defaultScreenshotDirectoryURL().path,
            screenshotCopiesToClipboardKey: true,
            screenshotSelectsRegionKey: true,
            activeVisionEnabledKey: false,
            desktopLyricsEnabledKey: false,
            desktopLyricsSurfaceEnabledKey: true,
            desktopLyricsWidthKey: 980.0,
            desktopLyricsAlignmentKey: LyricsTextAlignment.defaultValue.rawValue,
            dynamicIslandLyricsEnabledKey: false,
            dynamicIslandLyricsWidthKey: 900.0,
            dynamicIslandLyricsBlankWidthKey: 210.0,
            dynamicIslandLyricsHeightKey: 58.0,
            dynamicIslandLyricsBottomRatioKey: 0.55,
            dynamicIslandLyricsSlantRatioKey: 0.55,
            dynamicIslandLyricsCornerRatioKey: 0.55,
            dynamicIslandLyricsFontSizeKey: 15.0,
            dynamicIslandLyricsFontNameKey: "",
            dynamicIslandLyricsAlignmentKey: LyricsTextAlignment.defaultValue.rawValue,
            dynamicIslandLyricsSpectrumEnabledKey: false,
            dynamicIslandLyricsHidesOnHoverKey: false,
            menuBarLyricsEnabledKey: false,
            menuBarLyricsWidthKey: 220.0,
            menuBarLyricsAlignmentKey: LyricsTextAlignment.defaultValue.rawValue,
            desktopLyricsEnabledSourcesKey: DesktopLyricsSource.defaultOrder.map(\.rawValue),
            desktopLyricsSourceOrderKey: DesktopLyricsSource.defaultOrder.map(\.rawValue),
            desktopLyricsPreferredLanguageKey: DesktopLyricsPreferredLanguage.defaultValue.rawValue,
            desktopLyricsShowsTranslationKey: true,
            desktopLyricsFontSizeKey: 28.0,
            desktopLyricsFontNameKey: "",
            desktopLyricsTextColorKey: "",
            desktopLyricsStrokeColorKey: "",
            desktopLyricsStrokeWidthKey: -1.0,
            desktopLyricsPositionXKey: -1.0,
            desktopLyricsPositionYKey: -1.0,
            desktopLyricsLockedKey: false,
            desktopLyricsStylePresetKey: DesktopLyricsStylePreset.defaultValue.rawValue,
            musicLyricsAppWhitelistKey: "",
            appleMusicMediaUserTokenKey: "",
            activeVisionPreventDisplaySleepOnGazeKey: true,
            activeVisionPreventDisplaySleepOnFacingKey: true,
            activeVisionNotifyWhenExtendingDisplaySleepKey: true,
            slideshowAnnotationEnabledKey: false
        ])

        if !defaults.bool(forKey: selectionToolbarDefaultOffMigrationKey) {
            defaults.set(false, forKey: selectionToolbarEnabledKey)
            defaults.set(true, forKey: selectionToolbarDefaultOffMigrationKey)
        }
    }

    func read() -> AppSettings {
        let savedOrder = defaults.stringArray(forKey: selectionToolbarOrderKey) ?? []
        let order = normalizedOrder(savedOrder.compactMap(ToolbarAction.init(rawValue:)))
        let savedDesktopLyricsSourceOrder = defaults.stringArray(forKey: desktopLyricsSourceOrderKey) ?? []
        let desktopLyricsSourceOrder = normalizedDesktopLyricsSourceOrder(savedDesktopLyricsSourceOrder.compactMap(DesktopLyricsSource.init(rawValue:)))
        let savedEnabledSources = defaults.stringArray(forKey: desktopLyricsEnabledSourcesKey) ?? DesktopLyricsSource.defaultOrder.map(\.rawValue)
        let enabledSources = normalizedEnabledDesktopLyricsSources(savedEnabledSources.compactMap(DesktopLyricsSource.init(rawValue:)))
        let preferredLanguage = defaults.string(forKey: desktopLyricsPreferredLanguageKey)
            .flatMap(DesktopLyricsPreferredLanguage.init(rawValue:)) ?? DesktopLyricsPreferredLanguage.defaultValue
        let stylePreset = defaults.string(forKey: desktopLyricsStylePresetKey)
            .flatMap(DesktopLyricsStylePreset.init(rawValue:)) ?? DesktopLyricsStylePreset.defaultValue
        let desktopLyricsAlignment = defaults.string(forKey: desktopLyricsAlignmentKey)
            .flatMap(LyricsTextAlignment.init(rawValue:)) ?? LyricsTextAlignment.defaultValue
        let dynamicIslandLyricsAlignment = defaults.string(forKey: dynamicIslandLyricsAlignmentKey)
            .flatMap(LyricsTextAlignment.init(rawValue:)) ?? LyricsTextAlignment.defaultValue
        let menuBarLyricsAlignment = defaults.string(forKey: menuBarLyricsAlignmentKey)
            .flatMap(LyricsTextAlignment.init(rawValue:)) ?? LyricsTextAlignment.defaultValue
        let legacyDynamicIslandShapeRatio = Self.clampedDynamicIslandLyricsRatio(defaults.double(forKey: dynamicIslandLyricsBottomRatioKey))
        let dynamicIslandSlantRatio = Self.clampedDynamicIslandLyricsRatio(
            Self.explicitDouble(defaults, forKey: dynamicIslandLyricsSlantRatioKey) ?? legacyDynamicIslandShapeRatio
        )
        let dynamicIslandCornerRatio = Self.clampedDynamicIslandLyricsRatio(
            Self.explicitDouble(defaults, forKey: dynamicIslandLyricsCornerRatioKey) ?? legacyDynamicIslandShapeRatio
        )

        return AppSettings(
            isCapsLockIndicatorEnabled: defaults.bool(forKey: capsLockIndicatorEnabledKey),
            isClickToDisableEnabled: defaults.bool(forKey: capsLockIndicatorClickToDisableEnabledKey),
            isSelectionToolbarEnabled: defaults.bool(forKey: selectionToolbarEnabledKey),
            isSelectionToolbarHideInFullscreen: defaults.bool(forKey: selectionToolbarHideInFullscreenKey),
            isSelectionToolbarSelectAllEnabled: defaults.bool(forKey: selectionToolbarSelectAllEnabledKey),
            isSelectionToolbarCopyEnabled: defaults.bool(forKey: selectionToolbarCopyEnabledKey),
            isSelectionToolbarPasteEnabled: defaults.bool(forKey: selectionToolbarPasteEnabledKey),
            isSelectionToolbarSearchEnabled: defaults.bool(forKey: selectionToolbarSearchEnabledKey),
            isSelectionToolbarScreenshotEnabled: defaults.bool(forKey: selectionToolbarScreenshotEnabledKey),
            selectionToolbarOrder: order,
            searchURLTemplate: defaults.string(forKey: searchURLTemplateKey) ?? SearchEnginePreset.defaultTemplate,
            screenshotSaveDirectory: defaults.string(forKey: screenshotSaveDirectoryKey) ?? defaultScreenshotDirectoryURL().path,
            screenshotCopiesToClipboard: defaults.bool(forKey: screenshotCopiesToClipboardKey),
            screenshotSelectsRegion: defaults.bool(forKey: screenshotSelectsRegionKey),
            isActiveVisionEnabled: defaults.bool(forKey: activeVisionEnabledKey),
            isDesktopLyricsEnabled: defaults.bool(forKey: desktopLyricsEnabledKey),
            isDesktopLyricsSurfaceEnabled: defaults.bool(forKey: desktopLyricsSurfaceEnabledKey),
            desktopLyricsWidth: Self.clampedDesktopLyricsWidth(defaults.double(forKey: desktopLyricsWidthKey)),
            desktopLyricsAlignment: desktopLyricsAlignment,
            isDynamicIslandLyricsEnabled: defaults.bool(forKey: dynamicIslandLyricsEnabledKey),
            dynamicIslandLyricsWidth: Self.clampedDynamicIslandLyricsWidth(defaults.double(forKey: dynamicIslandLyricsWidthKey)),
            dynamicIslandLyricsBlankWidth: Self.clampedDynamicIslandLyricsBlankWidth(defaults.double(forKey: dynamicIslandLyricsBlankWidthKey)),
            dynamicIslandLyricsHeight: Self.clampedDynamicIslandLyricsHeight(defaults.double(forKey: dynamicIslandLyricsHeightKey)),
            dynamicIslandLyricsSlantRatio: dynamicIslandSlantRatio,
            dynamicIslandLyricsCornerRatio: dynamicIslandCornerRatio,
            dynamicIslandLyricsFontSize: Self.clampedDynamicIslandLyricsFontSize(defaults.double(forKey: dynamicIslandLyricsFontSizeKey)),
            dynamicIslandLyricsFontName: defaults.string(forKey: dynamicIslandLyricsFontNameKey) ?? "",
            dynamicIslandLyricsAlignment: dynamicIslandLyricsAlignment,
            isDynamicIslandLyricsSpectrumEnabled: defaults.bool(forKey: dynamicIslandLyricsSpectrumEnabledKey),
            isDynamicIslandLyricsHidesOnHover: defaults.bool(forKey: dynamicIslandLyricsHidesOnHoverKey),
            isMenuBarLyricsEnabled: defaults.bool(forKey: menuBarLyricsEnabledKey),
            menuBarLyricsWidth: Self.clampedMenuBarLyricsWidth(defaults.double(forKey: menuBarLyricsWidthKey)),
            menuBarLyricsAlignment: menuBarLyricsAlignment,
            enabledDesktopLyricsSources: enabledSources,
            desktopLyricsSourceOrder: desktopLyricsSourceOrder,
            desktopLyricsPreferredLanguage: preferredLanguage,
            desktopLyricsShowsTranslation: defaults.bool(forKey: desktopLyricsShowsTranslationKey),
            desktopLyricsFontSize: Self.clampedDesktopLyricsFontSize(defaults.double(forKey: desktopLyricsFontSizeKey)),
            desktopLyricsFontName: defaults.string(forKey: desktopLyricsFontNameKey) ?? "",
            desktopLyricsTextColor: defaults.string(forKey: desktopLyricsTextColorKey) ?? "",
            desktopLyricsStrokeColor: defaults.string(forKey: desktopLyricsStrokeColorKey) ?? "",
            desktopLyricsStrokeWidth: defaults.double(forKey: desktopLyricsStrokeWidthKey),
            desktopLyricsPositionX: defaults.double(forKey: desktopLyricsPositionXKey),
            desktopLyricsPositionY: defaults.double(forKey: desktopLyricsPositionYKey),
            desktopLyricsLocked: defaults.bool(forKey: desktopLyricsLockedKey),
            desktopLyricsStylePreset: stylePreset,
            musicLyricsAppWhitelist: defaults.string(forKey: musicLyricsAppWhitelistKey) ?? "",
            appleMusicMediaUserToken: defaults.string(forKey: appleMusicMediaUserTokenKey) ?? "",
            activeVisionPreventsDisplaySleepOnGaze: defaults.bool(forKey: activeVisionPreventDisplaySleepOnGazeKey),
            activeVisionPreventsDisplaySleepOnFacing: defaults.bool(forKey: activeVisionPreventDisplaySleepOnFacingKey),
            activeVisionNotifiesWhenExtendingDisplaySleep: defaults.bool(forKey: activeVisionNotifyWhenExtendingDisplaySleepKey),
            isSlideshowAnnotationEnabled: defaults.bool(forKey: slideshowAnnotationEnabledKey)
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

    func setSelectionToolbarHideInFullscreen(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: selectionToolbarHideInFullscreenKey)
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

    func setActiveVisionEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: activeVisionEnabledKey)
    }

    func setDesktopLyricsEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: desktopLyricsEnabledKey)
    }

    func setDesktopLyricsSurfaceEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: desktopLyricsSurfaceEnabledKey)
    }

    func setDesktopLyricsWidth(_ width: Double) {
        defaults.set(Self.clampedDesktopLyricsWidth(width), forKey: desktopLyricsWidthKey)
    }

    func setDesktopLyricsAlignment(_ alignment: LyricsTextAlignment) {
        defaults.set(alignment.rawValue, forKey: desktopLyricsAlignmentKey)
    }

    func setDynamicIslandLyricsEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: dynamicIslandLyricsEnabledKey)
    }

    func setDynamicIslandLyricsWidth(_ width: Double) {
        defaults.set(Self.clampedDynamicIslandLyricsWidth(width), forKey: dynamicIslandLyricsWidthKey)
    }

    func setDynamicIslandLyricsBlankWidth(_ width: Double) {
        defaults.set(Self.clampedDynamicIslandLyricsBlankWidth(width), forKey: dynamicIslandLyricsBlankWidthKey)
    }

    func setDynamicIslandLyricsHeight(_ height: Double) {
        defaults.set(Self.clampedDynamicIslandLyricsHeight(height), forKey: dynamicIslandLyricsHeightKey)
    }

    func setDynamicIslandLyricsSlantRatio(_ ratio: Double) {
        defaults.set(Self.clampedDynamicIslandLyricsRatio(ratio), forKey: dynamicIslandLyricsSlantRatioKey)
    }

    func setDynamicIslandLyricsCornerRatio(_ ratio: Double) {
        defaults.set(Self.clampedDynamicIslandLyricsRatio(ratio), forKey: dynamicIslandLyricsCornerRatioKey)
    }

    func setDynamicIslandLyricsFontSize(_ fontSize: Double) {
        defaults.set(Self.clampedDynamicIslandLyricsFontSize(fontSize), forKey: dynamicIslandLyricsFontSizeKey)
    }

    func setDynamicIslandLyricsFontName(_ fontName: String) {
        defaults.set(fontName, forKey: dynamicIslandLyricsFontNameKey)
    }

    func setDynamicIslandLyricsAlignment(_ alignment: LyricsTextAlignment) {
        defaults.set(alignment.rawValue, forKey: dynamicIslandLyricsAlignmentKey)
    }

    func setDynamicIslandLyricsSpectrumEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: dynamicIslandLyricsSpectrumEnabledKey)
    }

    func setDynamicIslandLyricsHidesOnHover(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: dynamicIslandLyricsHidesOnHoverKey)
    }

    func setMenuBarLyricsEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: menuBarLyricsEnabledKey)
    }

    func setMenuBarLyricsWidth(_ width: Double) {
        defaults.set(Self.clampedMenuBarLyricsWidth(width), forKey: menuBarLyricsWidthKey)
    }

    func setMenuBarLyricsAlignment(_ alignment: LyricsTextAlignment) {
        defaults.set(alignment.rawValue, forKey: menuBarLyricsAlignmentKey)
    }

    func setDesktopLyricsSource(_ source: DesktopLyricsSource, enabled isEnabled: Bool) {
        var sources = read().enabledDesktopLyricsSources
        if isEnabled, !sources.contains(source) {
            sources.append(source)
        } else if !isEnabled {
            sources.removeAll { $0 == source }
        }
        defaults.set(sources.map(\.rawValue), forKey: desktopLyricsEnabledSourcesKey)
    }

    func setAppleMusicMediaUserToken(_ token: String) {
        defaults.set(token, forKey: appleMusicMediaUserTokenKey)
    }

    func setDesktopLyricsPreferredLanguage(_ language: DesktopLyricsPreferredLanguage) {
        defaults.set(language.rawValue, forKey: desktopLyricsPreferredLanguageKey)
    }

    func setDesktopLyricsShowsTranslation(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: desktopLyricsShowsTranslationKey)
    }

    func setDesktopLyricsFontSize(_ fontSize: Double) {
        defaults.set(Self.clampedDesktopLyricsFontSize(fontSize), forKey: desktopLyricsFontSizeKey)
    }

    func setDesktopLyricsFontName(_ fontName: String) {
        defaults.set(fontName, forKey: desktopLyricsFontNameKey)
    }

    func setDesktopLyricsTextColor(_ value: String) {
        defaults.set(value, forKey: desktopLyricsTextColorKey)
    }

    func setDesktopLyricsStrokeColor(_ value: String) {
        defaults.set(value, forKey: desktopLyricsStrokeColorKey)
    }

    func setDesktopLyricsStrokeWidth(_ value: Double) {
        defaults.set(max(0.0, min(6.0, value)), forKey: desktopLyricsStrokeWidthKey)
    }

    func setDesktopLyricsPosition(x: Double, y: Double) {
        defaults.set(x, forKey: desktopLyricsPositionXKey)
        defaults.set(y, forKey: desktopLyricsPositionYKey)
    }

    func setDesktopLyricsLocked(_ isLocked: Bool) {
        defaults.set(isLocked, forKey: desktopLyricsLockedKey)
    }

    func setDesktopLyricsStylePreset(_ preset: DesktopLyricsStylePreset) {
        defaults.set(preset.rawValue, forKey: desktopLyricsStylePresetKey)
        defaults.set("", forKey: desktopLyricsTextColorKey)
        defaults.set("", forKey: desktopLyricsStrokeColorKey)
        defaults.set(-1.0, forKey: desktopLyricsStrokeWidthKey)
    }

    func setMusicLyricsAppWhitelist(_ value: String) {
        defaults.set(value, forKey: musicLyricsAppWhitelistKey)
    }

    func moveDesktopLyricsSource(_ source: DesktopLyricsSource, direction: Int) {
        guard let order = orderMoved(source, direction: direction, in: read().desktopLyricsSourceOrder) else {
            return
        }
        defaults.set(order.map(\.rawValue), forKey: desktopLyricsSourceOrderKey)
    }

    func setActiveVisionPreventsDisplaySleepOnGaze(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: activeVisionPreventDisplaySleepOnGazeKey)
    }

    func setActiveVisionPreventsDisplaySleepOnFacing(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: activeVisionPreventDisplaySleepOnFacingKey)
    }

    func setActiveVisionNotifiesWhenExtendingDisplaySleep(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: activeVisionNotifyWhenExtendingDisplaySleepKey)
    }

    func setSlideshowAnnotationEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: slideshowAnnotationEnabledKey)
    }

    func clearPersistentData() {
        let domain = Bundle.main.bundleIdentifier ?? appIdentifier
        defaults.removePersistentDomain(forName: domain)
    }

    func moveSelectionToolbarAction(_ action: ToolbarAction, direction: Int) {
        guard let order = orderMoved(action, direction: direction, in: read().selectionToolbarOrder) else {
            return
        }
        defaults.set(order.map(\.rawValue), forKey: selectionToolbarOrderKey)
    }

    /// 将 element 在 order 中按 direction 移动一位；越界或找不到时返回 nil。
    private func orderMoved<T: Equatable>(_ element: T, direction: Int, in order: [T]) -> [T]? {
        guard let index = order.firstIndex(of: element) else {
            return nil
        }

        let newIndex = max(0, min(order.count - 1, index + direction))
        guard newIndex != index else {
            return nil
        }

        var result = order
        result.remove(at: index)
        result.insert(element, at: newIndex)
        return result
    }

    private func normalizedOrder(_ savedOrder: [ToolbarAction]) -> [ToolbarAction] {
        var result: [ToolbarAction] = []

        if savedOrder.contains(.selectAll) {
            for action in savedOrder where !result.contains(action) {
                result.append(action)
            }
        } else {
            // 首次升级（旧数据无 selectAll）：默认置于最前，其余保持用户原顺序。
            result.append(.selectAll)
            for action in savedOrder where !result.contains(action) {
                result.append(action)
            }
        }

        for action in ToolbarAction.configurableCases where !result.contains(action) {
            result.append(action)
        }

        return result
    }

    private func normalizedDesktopLyricsSourceOrder(_ savedOrder: [DesktopLyricsSource]) -> [DesktopLyricsSource] {
        var result: [DesktopLyricsSource] = []

        for source in savedOrder where !result.contains(source) {
            result.append(source)
        }

        for source in DesktopLyricsSource.defaultOrder where !result.contains(source) {
            result.append(source)
        }

        return result
    }

    private func normalizedEnabledDesktopLyricsSources(_ savedSources: [DesktopLyricsSource]) -> [DesktopLyricsSource] {
        savedSources.filter { DesktopLyricsSource.defaultOrder.contains($0) }
    }

    /// 读取「用户显式写入过」的 Double（区分未写入与写过 0——double(forKey:) 对两者都返回 0）。
    /// 用 object(forKey:) 判空即可，勿用 persistentDomain(forName:) 整域拷贝（read() 高频调用）。
    private static func explicitDouble(_ defaults: UserDefaults, forKey key: String) -> Double? {
        defaults.object(forKey: key) as? Double
    }

    // MARK: 数值边界（单一来源：App 层 setter 与 read() 共用，避免双处维护漂移）
    // 注：0 → 默认值的回退仅服务 read() 对「未写入」键的兜底；App 层 setter
    // 统一在写入后 read() 回读，clamp 结果天然一致。

    static func clampedDesktopLyricsFontSize(_ value: Double) -> Double {
        min(48.0, max(18.0, value == 0 ? 28.0 : value))
    }

    static func clampedDesktopLyricsWidth(_ value: Double) -> Double {
        min(2200.0, max(260.0, value == 0 ? 980.0 : value))
    }

    static func clampedDynamicIslandLyricsWidth(_ value: Double) -> Double {
        min(1700.0, max(360.0, value == 0 ? 900.0 : value))
    }

    static func clampedDynamicIslandLyricsBlankWidth(_ value: Double) -> Double {
        min(900.0, max(60.0, value == 0 ? 210.0 : value))
    }

    static func clampedDynamicIslandLyricsHeight(_ value: Double) -> Double {
        min(180.0, max(32.0, value == 0 ? 58.0 : value))
    }

    static func clampedDynamicIslandLyricsRatio(_ value: Double) -> Double {
        min(1.0, max(0.01, value == 0 ? 0.55 : value))
    }

    static func clampedDynamicIslandLyricsFontSize(_ value: Double) -> Double {
        min(64.0, max(11.0, value == 0 ? 15.0 : value))
    }

    static func clampedMenuBarLyricsWidth(_ value: Double) -> Double {
        min(760.0, max(40.0, value == 0 ? 220.0 : value))
    }
}

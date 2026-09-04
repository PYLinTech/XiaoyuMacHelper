import AppKit

@MainActor
final class ControlView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Page {
        case modules
        case capsLockSettings
        case selectionToolbarSettings
        case activeVisionSettings
        case desktopLyricsSettings
        case desktopLyricsSurfaceSettings
        case dynamicIslandLyricsSettings
        case menuBarLyricsSettings
        case appleMusicSettings
        case musicLyricsWhitelistSettings
        case searchSettings
        case screenshotSettings
    }

    private enum Metrics {
        static let outerPadding: CGFloat = 24
        static let titleTopInset: CGFloat = 34
        static let sectionGap: CGFloat = 18
        static let rowHeight: CGFloat = 44
        static let sectionInset: CGFloat = 16
        static let footerHeight: CGFloat = 32
        static let cornerRadius: CGFloat = 20
        static let overlayScrollerSafeGutter: CGFloat = 34
        static let overlayScrollerRightInset: CGFloat = 12
        static let overlayScrollerVerticalInset: CGFloat = 20
    }

    private struct ApplicationChoice: Hashable {
        let bundleIdentifier: String
        let displayName: String
    }

    private var page: Page = .modules
    private var selectionToolbarOrder = ToolbarAction.configurableCases
    private var desktopLyricsSourceOrder = DesktopLyricsSource.defaultOrder
    private var isAccessibilityEnabledForDisplay = false
    private var isSearchTemplateCustom = false
    private var lastCommittedSearchTemplate: String?

    private let glassContainer = LiquidGlassContainerView()
    private let glassContentView = NSView()
    private let titleLabel = NSTextField(labelWithString: "Xiaoyu MacHelper")
    private let versionLabel = NSTextField(labelWithString: "")
    private let checkUpdateButton = NSButton(title: "检查更新", target: nil, action: nil)
    private let toolOptionsTitle = NSTextField(labelWithString: "工具选项")
    private let moduleTitle = NSTextField(labelWithString: "功能模块")
    private let settingsTitle = NSTextField(labelWithString: "")
    private let toolOptionsCard = LiquidGlassEffectView()
    private let moduleCard = LiquidGlassEffectView()
    private let settingsCard = LiquidGlassEffectView()
    private let settingsScrollView = NSScrollView(frame: .zero)
    private let settingsContentView = NSView(frame: .zero)
    private var settingsContentHeight: CGFloat = 0
    private var shouldScrollSettingsContentToTop = false
    private let loginItemCheckbox = NSButton(checkboxWithTitle: "开启自启动", target: nil, action: nil)
    private let accessibilityCheckbox = NSButton(checkboxWithTitle: "开启辅助功能", target: nil, action: nil)
    private let capsLockCheckbox = NSButton(checkboxWithTitle: "大写指示器", target: nil, action: nil)
    private let selectionToolbarCheckbox = NSButton(checkboxWithTitle: "选区工具栏", target: nil, action: nil)
    private let activeVisionCheckbox = NSButton(checkboxWithTitle: "主动视觉感知", target: nil, action: nil)
    private let desktopLyricsCheckbox = NSButton(checkboxWithTitle: "音乐歌词", target: nil, action: nil)
    private let slideshowAnnotationCheckbox = NSButton(checkboxWithTitle: "幻灯片批注", target: nil, action: nil)
    private let clickToDisableCheckbox = NSButton(checkboxWithTitle: "点击指示器取消大写", target: nil, action: nil)
    private let selectionToolbarSettingTitle = NSTextField(labelWithString: "设置")
    private let selectionToolbarHideInFullscreenCheckbox = NSButton(checkboxWithTitle: "全屏时隐藏选区工具栏", target: nil, action: nil)
    private let selectionToolbarOrderTitle = NSTextField(labelWithString: "按钮顺序（拖动右侧手柄可排序）")
    private let capsLockSettingsButton = IconButtonView(systemSymbolName: "gearshape", accessibilityDescription: "设置", backgroundStyle: .plain, tintColor: .secondaryLabelColor)
    private let selectionToolbarSettingsButton = IconButtonView(systemSymbolName: "gearshape", accessibilityDescription: "设置", backgroundStyle: .plain, tintColor: .secondaryLabelColor)
    private let activeVisionSettingsButton = IconButtonView(systemSymbolName: "gearshape", accessibilityDescription: "设置", backgroundStyle: .plain, tintColor: .secondaryLabelColor)
    private let desktopLyricsSettingsButton = IconButtonView(systemSymbolName: "gearshape", accessibilityDescription: "设置", backgroundStyle: .plain, tintColor: .secondaryLabelColor)
    /// 幻灯片批注无独立设置页，占位以复用模块行布局，始终隐藏。
    private let slideshowAnnotationSettingsButton = IconButtonView(systemSymbolName: "gearshape", accessibilityDescription: "设置", backgroundStyle: .plain, tintColor: .secondaryLabelColor)
    private let backButton = IconButtonView(systemSymbolName: "chevron.left", accessibilityDescription: "返回", backgroundStyle: .glass)
    private let loginItemButton = NSButton(title: "前往设置启动项", target: nil, action: nil)
    private let accessibilityButton = NSButton(title: "前往设置辅助功能", target: nil, action: nil)
    private let clearDataAndQuitButton = NSButton(title: "清空应用数据并退出", target: nil, action: nil)
    private let quitButton = NSButton(title: "退出", target: nil, action: nil)
    private let selectAllRow = ActionSettingRow(action: .selectAll)
    private let copyRow = ActionSettingRow(action: .copy)
    private let pasteRow = ActionSettingRow(action: .paste)
    private let searchRow = ActionSettingRow(action: .search, showsSettingsButton: true)
    private let screenshotRow = ActionSettingRow(action: .screenshot, showsSettingsButton: true)
    private let searchEnginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchTemplateField = NSTextField(string: "")
    private let screenshotSaveLabel = NSTextField(labelWithString: "截图后保存到：")
    private let screenshotSaveButton = NSButton(title: "", target: nil, action: nil)
    private let screenshotCopyCheckbox = NSButton(checkboxWithTitle: "截图后复制到剪贴板", target: nil, action: nil)
    private let screenshotRegionCheckbox = NSButton(checkboxWithTitle: "截图时框选区域", target: nil, action: nil)
    private let activeVisionGazeCheckbox = NSButton(checkboxWithTitle: "注视屏幕时不要息屏", target: nil, action: nil)
    private let activeVisionFacingCheckbox = NSButton(checkboxWithTitle: "面向屏幕时不要息屏", target: nil, action: nil)
    private let activeVisionNotifyCheckbox = NSButton(checkboxWithTitle: "延迟息屏时通知", target: nil, action: nil)
    private let desktopLyricsHintLabel = NSTextField(labelWithString: "")
    private let desktopLyricsLanguageLabel = NSTextField(labelWithString: "首选语言：")
    private let desktopLyricsLanguagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let desktopLyricsSurfaceCheckbox = NSButton(checkboxWithTitle: "桌面歌词", target: nil, action: nil)
    private let desktopLyricsSurfaceSettingsButton = IconButtonView(systemSymbolName: "gearshape", accessibilityDescription: "桌面歌词设置", backgroundStyle: .plain, tintColor: .secondaryLabelColor)
    private let desktopLyricsWidthLabel = NSTextField(labelWithString: "桌面歌词宽度：")
    private let desktopLyricsWidthValueLabel = NSTextField(labelWithString: "")
    private let desktopLyricsWidthSlider = NSSlider(value: 980, minValue: 260, maxValue: 2200, target: nil, action: nil)
    private let desktopLyricsAlignmentLabel = NSTextField(labelWithString: "对齐方式：")
    private let desktopLyricsAlignmentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dynamicIslandLyricsCheckbox = NSButton(checkboxWithTitle: "灵动大陆歌词", target: nil, action: nil)
    private let dynamicIslandLyricsSettingsButton = IconButtonView(systemSymbolName: "gearshape", accessibilityDescription: "灵动大陆歌词设置", backgroundStyle: .plain, tintColor: .secondaryLabelColor)
    private let dynamicIslandLyricsSpectrumCheckbox = NSButton(checkboxWithTitle: "灵动大陆可视化频谱（需录音权限）", target: nil, action: nil)
    private let dynamicIslandLyricsHideOnHoverCheckbox = NSButton(checkboxWithTitle: "鼠标移入时隐藏灵动大陆", target: nil, action: nil)
    private let dynamicIslandLyricsWidthLabel = NSTextField(labelWithString: "灵动大陆总宽度：")
    private let dynamicIslandLyricsWidthValueLabel = NSTextField(labelWithString: "")
    private let dynamicIslandLyricsWidthSlider = NSSlider(value: 900, minValue: 360, maxValue: 1700, target: nil, action: nil)
    private let dynamicIslandLyricsBlankWidthLabel = NSTextField(labelWithString: "刘海避让空白宽度：")
    private let dynamicIslandLyricsBlankWidthValueLabel = NSTextField(labelWithString: "")
    private let dynamicIslandLyricsBlankWidthSlider = NSSlider(value: 210, minValue: 60, maxValue: 900, target: nil, action: nil)
    private let dynamicIslandLyricsHeightLabel = NSTextField(labelWithString: "灵动大陆高度：")
    private let dynamicIslandLyricsHeightValueLabel = NSTextField(labelWithString: "")
    private let dynamicIslandLyricsHeightSlider = NSSlider(value: 58, minValue: 32, maxValue: 180, target: nil, action: nil)
    private let dynamicIslandLyricsSlantRatioLabel = NSTextField(labelWithString: "侧边倾斜程度：")
    private let dynamicIslandLyricsSlantRatioValueLabel = NSTextField(labelWithString: "")
    private let dynamicIslandLyricsSlantRatioSlider = NSSlider(value: 55, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let dynamicIslandLyricsCornerRatioLabel = NSTextField(labelWithString: "圆润程度：")
    private let dynamicIslandLyricsCornerRatioValueLabel = NSTextField(labelWithString: "")
    private let dynamicIslandLyricsCornerRatioSlider = NSSlider(value: 55, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let dynamicIslandLyricsFontLabel = NSTextField(labelWithString: "字体：")
    private let dynamicIslandLyricsFontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dynamicIslandLyricsFontSizeLabel = NSTextField(labelWithString: "字体大小：")
    private let dynamicIslandLyricsFontSizeValueLabel = NSTextField(labelWithString: "")
    private let dynamicIslandLyricsFontSizeSlider = NSSlider(value: 15, minValue: 11, maxValue: 64, target: nil, action: nil)
    private let dynamicIslandLyricsAlignmentLabel = NSTextField(labelWithString: "歌词对齐方式：")
    private let dynamicIslandLyricsAlignmentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let menuBarLyricsCheckbox = NSButton(checkboxWithTitle: "任务栏歌词", target: nil, action: nil)
    private let menuBarLyricsSettingsButton = IconButtonView(systemSymbolName: "gearshape", accessibilityDescription: "任务栏歌词设置", backgroundStyle: .plain, tintColor: .secondaryLabelColor)
    private let menuBarLyricsWidthLabel = NSTextField(labelWithString: "任务栏歌词宽度：")
    private let menuBarLyricsWidthValueLabel = NSTextField(labelWithString: "")
    private let menuBarLyricsWidthSlider = NSSlider(value: 220, minValue: 40, maxValue: 760, target: nil, action: nil)
    private let menuBarLyricsAlignmentLabel = NSTextField(labelWithString: "对齐方式：")
    private let menuBarLyricsAlignmentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let desktopLyricsTranslationCheckbox = NSButton(checkboxWithTitle: "同时显示翻译和原文", target: nil, action: nil)
    private let desktopLyricsLockCheckbox = NSButton(checkboxWithTitle: "锁定桌面歌词位置", target: nil, action: nil)
    private let desktopLyricsStyleLabel = NSTextField(labelWithString: "桌面样式：")
    private let desktopLyricsStylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let desktopLyricsFontLabel = NSTextField(labelWithString: "字体：")
    private let desktopLyricsFontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let desktopLyricsFontSizeLabel = NSTextField(labelWithString: "字体大小：")
    private let desktopLyricsFontSizeValueLabel = NSTextField(labelWithString: "")
    private let desktopLyricsFontSizeSlider = NSSlider(value: 28, minValue: 18, maxValue: 48, target: nil, action: nil)
    private let desktopLyricsTextColorLabel = NSTextField(labelWithString: "文字颜色：")
    private let desktopLyricsTextColorWell = NSColorWell(frame: .zero)
    private let desktopLyricsStrokeColorLabel = NSTextField(labelWithString: "描边颜色：")
    private let desktopLyricsStrokeColorWell = NSColorWell(frame: .zero)
    private let desktopLyricsStrokeWidthLabel = NSTextField(labelWithString: "描边强度：")
    private let desktopLyricsStrokeWidthValueLabel = NSTextField(labelWithString: "")
    private let desktopLyricsStrokeWidthSlider = NSSlider(value: 0.8, minValue: 0, maxValue: 6, target: nil, action: nil)
    private let musicLyricsWhitelistLabel = NSTextField(labelWithString: "白名单应用：")
    private let musicLyricsWhitelistButton = NSButton(title: "管理白名单应用", target: nil, action: nil)
    private let lyricsSourceLabel = NSTextField(labelWithString: "歌词源：")
    private let whitelistScrollView = NSScrollView(frame: .zero)
    private let whitelistTableView = WhitelistTableView(frame: .zero)
    private let whitelistAddButton = IconButtonView(systemSymbolName: "plus", accessibilityDescription: "添加", backgroundStyle: .glass)
    private let whitelistRemoveButton = IconButtonView(systemSymbolName: "minus", accessibilityDescription: "移除", backgroundStyle: .glass)
    private var availableApplications: [ApplicationChoice] = []
    private var isLoadingAvailableApplications = false
    private var needsWhitelistRerenderWhenLoaded = false
    private var lastRenderedWhitelistRawValue: String?
    private var whitelistApplications: [ApplicationChoice] = []
    private let appleMusicSourceRow = DesktopLyricsSourceRow(source: .appleMusic)
    private let qqMusicSourceRow = DesktopLyricsSourceRow(source: .qqMusic)
    private let neteaseSourceRow = DesktopLyricsSourceRow(source: .netease)
    private let appleMusicTokenStatusLabel = NSTextField(labelWithString: "")
    private let appleMusicLoginButton = NSButton(title: "登录 Apple Music", target: nil, action: nil)
    private let appleMusicClearTokenButton = NSButton(title: "清除登录", target: nil, action: nil)

    var onCapsLockIndicatorChanged: ((Bool) -> Void)?
    var onClickToDisableChanged: ((Bool) -> Void)?
    var onSelectionToolbarChanged: ((Bool) -> Void)?
    var onSelectionToolbarHideInFullscreenChanged: ((Bool) -> Void)?
    var onActiveVisionChanged: ((Bool) -> Void)?
    var onDesktopLyricsChanged: ((Bool) -> Void)?
    var onSlideshowAnnotationChanged: ((Bool) -> Void)?
    var onSelectionToolbarActionChanged: ((ToolbarAction, Bool) -> Void)?
    var onSelectionToolbarActionMoved: ((ToolbarAction, Int) -> Void)?
    var onDesktopLyricsSourceMoved: ((DesktopLyricsSource, Int) -> Void)?
    var onDesktopLyricsSourceEnabledChanged: ((DesktopLyricsSource, Bool) -> Void)?
    var onDesktopLyricsPreferredLanguageChanged: ((DesktopLyricsPreferredLanguage) -> Void)?
    var onDesktopLyricsSurfaceChanged: ((Bool) -> Void)?
    var onDynamicIslandLyricsChanged: ((Bool) -> Void)?
    var onDynamicIslandLyricsSpectrumChanged: ((Bool) -> Void)?
    var onDynamicIslandLyricsHideOnHoverChanged: ((Bool) -> Void)?
    var onDesktopLyricsWidthChanged: ((Double) -> Void)?
    var onDesktopLyricsAlignmentChanged: ((LyricsTextAlignment) -> Void)?
    var onDynamicIslandLyricsWidthChanged: ((Double) -> Void)?
    var onDynamicIslandLyricsBlankWidthChanged: ((Double) -> Void)?
    var onDynamicIslandLyricsHeightChanged: ((Double) -> Void)?
    var onDynamicIslandLyricsSlantRatioChanged: ((Double) -> Void)?
    var onDynamicIslandLyricsCornerRatioChanged: ((Double) -> Void)?
    var onDynamicIslandLyricsFontSizeChanged: ((Double) -> Void)?
    var onDynamicIslandLyricsFontNameChanged: ((String) -> Void)?
    var onDynamicIslandLyricsAlignmentChanged: ((LyricsTextAlignment) -> Void)?
    var onMenuBarLyricsChanged: ((Bool) -> Void)?
    var onMenuBarLyricsWidthChanged: ((Double) -> Void)?
    var onMenuBarLyricsAlignmentChanged: ((LyricsTextAlignment) -> Void)?
    var onDesktopLyricsShowsTranslationChanged: ((Bool) -> Void)?
    var onDesktopLyricsFontSizeChanged: ((Double) -> Void)?
    var onDesktopLyricsLockedChanged: ((Bool) -> Void)?
    var onDesktopLyricsStylePresetChanged: ((DesktopLyricsStylePreset) -> Void)?
    var onDesktopLyricsFontNameChanged: ((String) -> Void)?
    var onDesktopLyricsTextColorChanged: ((String) -> Void)?
    var onDesktopLyricsStrokeColorChanged: ((String) -> Void)?
    var onDesktopLyricsStrokeWidthChanged: ((Double) -> Void)?
    var onMusicLyricsAppWhitelistChanged: ((String) -> Void)?
    var onSearchTemplateChanged: ((String) -> Void)?
    var onScreenshotSaveDirectoryChanged: ((String) -> Void)?
    var onScreenshotCopiesToClipboardChanged: ((Bool) -> Void)?
    var onScreenshotSelectsRegionChanged: ((Bool) -> Void)?
    var onActiveVisionGazeChanged: ((Bool) -> Void)?
    var onActiveVisionFacingChanged: ((Bool) -> Void)?
    var onActiveVisionNotifyChanged: ((Bool) -> Void)?
    var onAppleMusicLoginRequested: (() -> Void)?
    var onAppleMusicTokenCleared: (() -> Void)?
    var onLoginItemChanged: ((Bool) -> Void)?
    var onLoginItemGuide: (() -> Void)?
    var onAccessibilityEnableRequested: (() -> Void)?
    var onAccessibilityDisableRequested: (() -> Void)?
    var onAccessibilityGuide: (() -> Void)?
    var onClearDataAndQuit: (() -> Void)?
    var onQuit: (() -> Void)?
    var onCheckUpdateRequested: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func render(settings: AppSettings, isLoginItemEnabled: Bool, isAccessibilityEnabled: Bool) {
        selectionToolbarOrder = settings.selectionToolbarOrder
        desktopLyricsSourceOrder = settings.desktopLyricsSourceOrder
        isAccessibilityEnabledForDisplay = isAccessibilityEnabled
        loginItemCheckbox.state = isLoginItemEnabled ? .on : .off
        accessibilityCheckbox.state = isAccessibilityEnabled ? .on : .off
        capsLockCheckbox.state = settings.isCapsLockIndicatorEnabled ? .on : .off
        selectionToolbarCheckbox.state = settings.isSelectionToolbarEnabled ? .on : .off
        selectionToolbarHideInFullscreenCheckbox.state = settings.isSelectionToolbarHideInFullscreen ? .on : .off
        activeVisionCheckbox.state = settings.isActiveVisionEnabled ? .on : .off
        desktopLyricsCheckbox.state = settings.isDesktopLyricsEnabled ? .on : .off
        slideshowAnnotationCheckbox.state = settings.isSlideshowAnnotationEnabled ? .on : .off
        clickToDisableCheckbox.state = settings.isClickToDisableEnabled ? .on : .off
        selectAllRow.setEnabled(settings.isSelectionToolbarSelectAllEnabled)
        copyRow.setEnabled(settings.isSelectionToolbarCopyEnabled)
        pasteRow.setEnabled(settings.isSelectionToolbarPasteEnabled)
        searchRow.setEnabled(settings.isSelectionToolbarSearchEnabled)
        screenshotRow.setEnabled(settings.isSelectionToolbarScreenshotEnabled)
        renderSearchSettings(settings)
        renderScreenshotSettings(settings)
        renderActiveVisionSettings(settings)
        renderDesktopLyricsSettings(settings)
        layoutForCurrentPage()
    }

    override func layout() {
        super.layout()
        layoutForCurrentPage()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        glassContainer.spacing = 12
        glassContainer.contentView = glassContentView
        addSubview(glassContainer)

        settingsScrollView.documentView = settingsContentView
        configureSystemScrollView(settingsScrollView)
        settingsScrollView.verticalScrollElasticity = .automatic
        addSubview(settingsScrollView)
        [toolOptionsCard, moduleCard, settingsCard].forEach {
            $0.style = .regular
            $0.cornerRadius = Metrics.cornerRadius
            $0.wantsLayer = true
            $0.layer?.cornerRadius = Metrics.cornerRadius
            $0.layer?.masksToBounds = true
            glassContentView.addSubview($0)
        }

        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .labelColor
        addSubview(titleLabel)

        versionLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.alignment = .left
        versionLabel.stringValue = Self.appVersionDisplayString()
        addSubview(versionLabel)

        [toolOptionsTitle, moduleTitle].forEach {
            $0.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            $0.textColor = .secondaryLabelColor
            addSubview($0)
        }

        settingsTitle.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        settingsTitle.textColor = .labelColor
        addSubview(settingsTitle)

        configureCheckbox(loginItemCheckbox, size: 14, weight: .medium, action: #selector(loginItemCheckboxChanged))
        configureCheckbox(accessibilityCheckbox, size: 14, weight: .medium, action: #selector(accessibilityCheckboxChanged))
        accessibilityCheckbox.allowsMixedState = false
        configureCheckbox(capsLockCheckbox, size: 14, weight: .medium, action: #selector(capsLockCheckboxChanged))
        configureCheckbox(selectionToolbarCheckbox, size: 14, weight: .medium, action: #selector(selectionToolbarCheckboxChanged))
        configureCheckbox(activeVisionCheckbox, size: 14, weight: .medium, action: #selector(activeVisionCheckboxChanged))
        configureCheckbox(desktopLyricsCheckbox, size: 14, weight: .medium, action: #selector(desktopLyricsCheckboxChanged))
        configureCheckbox(slideshowAnnotationCheckbox, size: 14, weight: .medium, action: #selector(slideshowAnnotationCheckboxChanged))
        configureCheckbox(clickToDisableCheckbox, size: 14, weight: .regular, action: #selector(clickToDisableCheckboxChanged), in: settingsContentView)
        configureCheckbox(selectionToolbarHideInFullscreenCheckbox, size: 14, weight: .regular, action: #selector(selectionToolbarHideInFullscreenChanged), in: settingsContentView)

        [selectionToolbarSettingTitle, selectionToolbarOrderTitle].forEach {
            $0.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            $0.textColor = .secondaryLabelColor
        }
        settingsContentView.addSubview(selectionToolbarSettingTitle)
        settingsContentView.addSubview(selectionToolbarOrderTitle)

        [capsLockSettingsButton, selectionToolbarSettingsButton, activeVisionSettingsButton, desktopLyricsSettingsButton, slideshowAnnotationSettingsButton, backButton].forEach { addSubview($0) }
        slideshowAnnotationSettingsButton.isHidden = true
        capsLockSettingsButton.onClick = { [weak self] in self?.showCapsLockSettingsPage() }
        selectionToolbarSettingsButton.onClick = { [weak self] in self?.showSelectionToolbarSettingsPage() }
        activeVisionSettingsButton.onClick = { [weak self] in self?.showActiveVisionSettingsPage() }
        desktopLyricsSettingsButton.onClick = { [weak self] in self?.showDesktopLyricsSettingsPage() }
        backButton.onClick = { [weak self] in self?.backButtonClicked() }

        [loginItemButton, accessibilityButton, clearDataAndQuitButton, quitButton].forEach {
            $0.bezelStyle = .liquidGlass
            $0.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            addSubview($0)
        }
        loginItemButton.target = self
        loginItemButton.action = #selector(loginItemClicked)
        accessibilityButton.target = self
        accessibilityButton.action = #selector(accessibilityClicked)
        clearDataAndQuitButton.target = self
        clearDataAndQuitButton.action = #selector(clearDataAndQuitClicked)
        quitButton.target = self
        quitButton.action = #selector(quitClicked)

        checkUpdateButton.bezelStyle = .liquidGlass
        checkUpdateButton.controlSize = .small
        checkUpdateButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        checkUpdateButton.target = self
        checkUpdateButton.action = #selector(checkUpdateClicked)
        addSubview(checkUpdateButton)

        [selectAllRow, copyRow, pasteRow, searchRow, screenshotRow].forEach { row in
            row.onToggle = { [weak self] action, isEnabled in self?.onSelectionToolbarActionChanged?(action, isEnabled) }
            row.onMove = { [weak self] action, direction in self?.onSelectionToolbarActionMoved?(action, direction) }
            settingsContentView.addSubview(row)
        }

        [appleMusicSourceRow, qqMusicSourceRow, neteaseSourceRow].forEach { row in
            row.onMove = { [weak self] source, direction in self?.onDesktopLyricsSourceMoved?(source, direction) }
            row.onToggle = { [weak self] source, isEnabled in self?.onDesktopLyricsSourceEnabledChanged?(source, isEnabled) }
            row.onSettings = { [weak self] source in
                if source == .appleMusic { self?.showAppleMusicSettingsPage() }
            }
            settingsContentView.addSubview(row)
        }
        searchRow.onSettings = { [weak self] _ in self?.showSearchSettingsPage() }
        screenshotRow.onSettings = { [weak self] _ in self?.showScreenshotSettingsPage() }

        searchEnginePopup.addItems(withTitles: SearchEnginePreset.all.map(\.title) + [SearchEnginePreset.customTitle])
        searchEnginePopup.bezelStyle = .liquidGlass
        searchEnginePopup.target = self
        searchEnginePopup.action = #selector(searchEngineSelected)
        settingsContentView.addSubview(searchEnginePopup)

        searchTemplateField.cell = VerticallyCenteredTextFieldCell(textCell: "")
        searchTemplateField.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        searchTemplateField.placeholderString = "请以 %s 代表搜索词"
        searchTemplateField.cell?.usesSingleLineMode = true
        searchTemplateField.cell?.lineBreakMode = .byTruncatingTail
        searchTemplateField.isEditable = true
        searchTemplateField.isSelectable = true
        searchTemplateField.isBezeled = true
        searchTemplateField.bezelStyle = .roundedBezel
        searchTemplateField.drawsBackground = true
        searchTemplateField.backgroundColor = .controlBackgroundColor
        searchTemplateField.delegate = self
        searchTemplateField.target = self
        searchTemplateField.action = #selector(searchTemplateCommitted)
        settingsContentView.addSubview(searchTemplateField)

        screenshotSaveLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        screenshotSaveLabel.textColor = .labelColor
        settingsContentView.addSubview(screenshotSaveLabel)

        screenshotSaveButton.bezelStyle = .liquidGlass
        screenshotSaveButton.alignment = .left
        screenshotSaveButton.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        screenshotSaveButton.target = self
        screenshotSaveButton.action = #selector(screenshotSaveDirectoryClicked)
        settingsContentView.addSubview(screenshotSaveButton)

        configureCheckbox(screenshotCopyCheckbox, size: 13, weight: .regular, action: #selector(screenshotCopyCheckboxChanged), in: settingsContentView)
        configureCheckbox(screenshotRegionCheckbox, size: 13, weight: .regular, action: #selector(screenshotRegionCheckboxChanged), in: settingsContentView)
        configureCheckbox(activeVisionGazeCheckbox, size: 13, weight: .regular, action: #selector(activeVisionGazeCheckboxChanged), in: settingsContentView)
        configureCheckbox(activeVisionFacingCheckbox, size: 13, weight: .regular, action: #selector(activeVisionFacingCheckboxChanged), in: settingsContentView)
        configureCheckbox(activeVisionNotifyCheckbox, size: 13, weight: .regular, action: #selector(activeVisionNotifyCheckboxChanged), in: settingsContentView)
        configureCheckbox(desktopLyricsSurfaceCheckbox, size: 13, weight: .regular, action: #selector(desktopLyricsSurfaceCheckboxChanged), in: settingsContentView)
        configureCheckbox(dynamicIslandLyricsCheckbox, size: 13, weight: .regular, action: #selector(dynamicIslandLyricsCheckboxChanged), in: settingsContentView)
        configureCheckbox(dynamicIslandLyricsSpectrumCheckbox, size: 13, weight: .regular, action: #selector(dynamicIslandLyricsSpectrumCheckboxChanged), in: settingsContentView)
        configureCheckbox(dynamicIslandLyricsHideOnHoverCheckbox, size: 13, weight: .regular, action: #selector(dynamicIslandLyricsHideOnHoverCheckboxChanged), in: settingsContentView)
        configureCheckbox(menuBarLyricsCheckbox, size: 13, weight: .regular, action: #selector(menuBarLyricsCheckboxChanged), in: settingsContentView)
        [desktopLyricsSurfaceSettingsButton, dynamicIslandLyricsSettingsButton, menuBarLyricsSettingsButton].forEach { settingsContentView.addSubview($0) }
        desktopLyricsSurfaceSettingsButton.onClick = { [weak self] in self?.showDesktopLyricsSurfaceSettingsPage() }
        dynamicIslandLyricsSettingsButton.onClick = { [weak self] in self?.showDynamicIslandLyricsSettingsPage() }
        menuBarLyricsSettingsButton.onClick = { [weak self] in self?.showMenuBarLyricsSettingsPage() }
        configureCheckbox(desktopLyricsTranslationCheckbox, size: 13, weight: .regular, action: #selector(desktopLyricsTranslationCheckboxChanged), in: settingsContentView)
        configureCheckbox(desktopLyricsLockCheckbox, size: 13, weight: .regular, action: #selector(desktopLyricsLockCheckboxChanged), in: settingsContentView)

        [desktopLyricsHintLabel, appleMusicTokenStatusLabel].forEach { label in
            label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            settingsContentView.addSubview(label)
        }
        desktopLyricsLanguageLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        desktopLyricsLanguageLabel.textColor = .labelColor
        settingsContentView.addSubview(desktopLyricsLanguageLabel)
        desktopLyricsLanguagePopup.addItems(withTitles: DesktopLyricsPreferredLanguage.allCases.map(\.title))
        desktopLyricsLanguagePopup.bezelStyle = .liquidGlass
        desktopLyricsLanguagePopup.target = self
        desktopLyricsLanguagePopup.action = #selector(desktopLyricsLanguageSelected)
        settingsContentView.addSubview(desktopLyricsLanguagePopup)

        [desktopLyricsAlignmentPopup, dynamicIslandLyricsAlignmentPopup, menuBarLyricsAlignmentPopup].forEach { popup in
            popup.addItems(withTitles: LyricsTextAlignment.allCases.map(\.title))
            popup.bezelStyle = .liquidGlass
            settingsContentView.addSubview(popup)
        }
        desktopLyricsAlignmentPopup.target = self
        desktopLyricsAlignmentPopup.action = #selector(desktopLyricsAlignmentSelected)
        dynamicIslandLyricsAlignmentPopup.target = self
        dynamicIslandLyricsAlignmentPopup.action = #selector(dynamicIslandLyricsAlignmentSelected)
        menuBarLyricsAlignmentPopup.target = self
        menuBarLyricsAlignmentPopup.action = #selector(menuBarLyricsAlignmentSelected)
        [desktopLyricsStyleLabel, desktopLyricsFontLabel, desktopLyricsFontSizeLabel, desktopLyricsFontSizeValueLabel, desktopLyricsTextColorLabel, desktopLyricsStrokeColorLabel, desktopLyricsStrokeWidthLabel, desktopLyricsStrokeWidthValueLabel, desktopLyricsWidthLabel, desktopLyricsWidthValueLabel, desktopLyricsAlignmentLabel, dynamicIslandLyricsWidthLabel, dynamicIslandLyricsWidthValueLabel, dynamicIslandLyricsBlankWidthLabel, dynamicIslandLyricsBlankWidthValueLabel, dynamicIslandLyricsHeightLabel, dynamicIslandLyricsHeightValueLabel, dynamicIslandLyricsSlantRatioLabel, dynamicIslandLyricsSlantRatioValueLabel, dynamicIslandLyricsCornerRatioLabel, dynamicIslandLyricsCornerRatioValueLabel, dynamicIslandLyricsFontLabel, dynamicIslandLyricsFontSizeLabel, dynamicIslandLyricsFontSizeValueLabel, dynamicIslandLyricsAlignmentLabel, menuBarLyricsWidthLabel, menuBarLyricsWidthValueLabel, menuBarLyricsAlignmentLabel, musicLyricsWhitelistLabel, lyricsSourceLabel].forEach { label in
            label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            label.textColor = .labelColor
            settingsContentView.addSubview(label)
        }
        desktopLyricsStylePopup.addItems(withTitles: DesktopLyricsStylePreset.allCases.map(\.title))
        desktopLyricsStylePopup.bezelStyle = .liquidGlass
        desktopLyricsStylePopup.target = self
        desktopLyricsStylePopup.action = #selector(desktopLyricsStyleSelected)
        settingsContentView.addSubview(desktopLyricsStylePopup)
        let availableFontFamilies = NSFontManager.shared.availableFontFamilies.sorted()
        desktopLyricsFontPopup.addItem(withTitle: "系统默认")
        desktopLyricsFontPopup.addItems(withTitles: availableFontFamilies)
        desktopLyricsFontPopup.bezelStyle = .liquidGlass
        desktopLyricsFontPopup.target = self
        desktopLyricsFontPopup.action = #selector(desktopLyricsFontSelected)
        settingsContentView.addSubview(desktopLyricsFontPopup)
        dynamicIslandLyricsFontPopup.addItem(withTitle: "系统默认")
        dynamicIslandLyricsFontPopup.addItems(withTitles: availableFontFamilies)
        dynamicIslandLyricsFontPopup.bezelStyle = .liquidGlass
        dynamicIslandLyricsFontPopup.target = self
        dynamicIslandLyricsFontPopup.action = #selector(dynamicIslandLyricsFontSelected)
        settingsContentView.addSubview(dynamicIslandLyricsFontPopup)
        desktopLyricsFontSizeValueLabel.alignment = .right
        desktopLyricsWidthValueLabel.alignment = .right
        dynamicIslandLyricsWidthValueLabel.alignment = .right
        dynamicIslandLyricsBlankWidthValueLabel.alignment = .right
        dynamicIslandLyricsHeightValueLabel.alignment = .right
        dynamicIslandLyricsSlantRatioValueLabel.alignment = .right
        dynamicIslandLyricsCornerRatioValueLabel.alignment = .right
        dynamicIslandLyricsFontSizeValueLabel.alignment = .right
        menuBarLyricsWidthValueLabel.alignment = .right
        desktopLyricsWidthSlider.target = self
        desktopLyricsWidthSlider.action = #selector(desktopLyricsWidthChanged)
        settingsContentView.addSubview(desktopLyricsWidthSlider)
        desktopLyricsFontSizeSlider.target = self
        desktopLyricsFontSizeSlider.action = #selector(desktopLyricsFontSizeChanged)
        settingsContentView.addSubview(desktopLyricsFontSizeSlider)
        dynamicIslandLyricsWidthSlider.target = self
        dynamicIslandLyricsWidthSlider.action = #selector(dynamicIslandLyricsWidthChanged)
        settingsContentView.addSubview(dynamicIslandLyricsWidthSlider)
        dynamicIslandLyricsBlankWidthSlider.target = self
        dynamicIslandLyricsBlankWidthSlider.action = #selector(dynamicIslandLyricsBlankWidthChanged)
        settingsContentView.addSubview(dynamicIslandLyricsBlankWidthSlider)
        dynamicIslandLyricsHeightSlider.target = self
        dynamicIslandLyricsHeightSlider.action = #selector(dynamicIslandLyricsHeightChanged)
        settingsContentView.addSubview(dynamicIslandLyricsHeightSlider)
        dynamicIslandLyricsSlantRatioSlider.target = self
        dynamicIslandLyricsSlantRatioSlider.action = #selector(dynamicIslandLyricsSlantRatioChanged)
        settingsContentView.addSubview(dynamicIslandLyricsSlantRatioSlider)
        dynamicIslandLyricsCornerRatioSlider.target = self
        dynamicIslandLyricsCornerRatioSlider.action = #selector(dynamicIslandLyricsCornerRatioChanged)
        settingsContentView.addSubview(dynamicIslandLyricsCornerRatioSlider)
        dynamicIslandLyricsFontSizeSlider.target = self
        dynamicIslandLyricsFontSizeSlider.action = #selector(dynamicIslandLyricsFontSizeChanged)
        settingsContentView.addSubview(dynamicIslandLyricsFontSizeSlider)
        menuBarLyricsWidthSlider.target = self
        menuBarLyricsWidthSlider.action = #selector(menuBarLyricsWidthChanged)
        settingsContentView.addSubview(menuBarLyricsWidthSlider)
        desktopLyricsTextColorWell.target = self
        desktopLyricsTextColorWell.action = #selector(desktopLyricsTextColorChanged)
        desktopLyricsStrokeColorWell.target = self
        desktopLyricsStrokeColorWell.action = #selector(desktopLyricsStrokeColorChanged)
        desktopLyricsStrokeWidthSlider.target = self
        desktopLyricsStrokeWidthSlider.action = #selector(desktopLyricsStrokeWidthChanged)
        settingsContentView.addSubview(desktopLyricsTextColorWell)
        settingsContentView.addSubview(desktopLyricsStrokeColorWell)
        settingsContentView.addSubview(desktopLyricsStrokeWidthSlider)
        musicLyricsWhitelistButton.bezelStyle = .liquidGlass
        musicLyricsWhitelistButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        musicLyricsWhitelistButton.target = self
        musicLyricsWhitelistButton.action = #selector(showMusicLyricsWhitelistSettingsPage)
        settingsContentView.addSubview(musicLyricsWhitelistButton)
        whitelistAddButton.onClick = { [weak self] in self?.addWhitelistApplication() }
        whitelistRemoveButton.onClick = { [weak self] in self?.removeWhitelistApplication() }
        whitelistTableView.headerView = nil
        whitelistTableView.rowHeight = 62
        whitelistTableView.intercellSpacing = NSSize(width: 0, height: 6)
        whitelistTableView.backgroundColor = .clear
        whitelistTableView.selectionHighlightStyle = .none
        whitelistTableView.allowsMultipleSelection = false
        whitelistTableView.allowsEmptySelection = true
        whitelistTableView.focusRingType = .none
        whitelistTableView.usesAlternatingRowBackgroundColors = false
        whitelistTableView.delegate = self
        whitelistTableView.dataSource = self
        let whitelistColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        whitelistColumn.resizingMask = .autoresizingMask
        whitelistTableView.addTableColumn(whitelistColumn)
        whitelistScrollView.documentView = whitelistTableView
        configureSystemScrollView(whitelistScrollView)
        whitelistScrollView.verticalScrollElasticity = .automatic
        settingsContentView.addSubview(whitelistScrollView)
        settingsContentView.addSubview(whitelistAddButton)
        settingsContentView.addSubview(whitelistRemoveButton)

        [appleMusicLoginButton, appleMusicClearTokenButton].forEach { button in
            button.bezelStyle = .liquidGlass
            button.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            settingsContentView.addSubview(button)
        }
        appleMusicLoginButton.target = self
        appleMusicLoginButton.action = #selector(appleMusicLoginClicked)
        appleMusicClearTokenButton.target = self
        appleMusicClearTokenButton.action = #selector(appleMusicClearTokenClicked)

        showModulesPage()
    }

    private func configureCheckbox(
        _ checkbox: NSButton,
        size: CGFloat,
        weight: NSFont.Weight,
        action: Selector,
        in containerView: NSView? = nil
    ) {
        checkbox.font = NSFont.systemFont(ofSize: size, weight: weight)
        checkbox.target = self
        checkbox.action = action
        (containerView ?? self).addSubview(checkbox)
    }

    func refreshGlassSurfaces() {
        [toolOptionsCard, moduleCard, settingsCard].forEach {
            $0.layer?.cornerRadius = Metrics.cornerRadius
            $0.layer?.masksToBounds = true
            $0.needsDisplay = true
        }
        glassContainer.needsDisplay = true
        glassContentView.needsDisplay = true
    }

    @objc private func capsLockCheckboxChanged() {
        onCapsLockIndicatorChanged?(capsLockCheckbox.state == .on)
    }

    @objc private func clickToDisableCheckboxChanged() {
        onClickToDisableChanged?(clickToDisableCheckbox.state == .on)
    }

    @objc private func selectionToolbarCheckboxChanged() {
        onSelectionToolbarChanged?(selectionToolbarCheckbox.state == .on)
    }

    @objc private func selectionToolbarHideInFullscreenChanged() {
        onSelectionToolbarHideInFullscreenChanged?(selectionToolbarHideInFullscreenCheckbox.state == .on)
    }

    @objc private func activeVisionCheckboxChanged() {
        onActiveVisionChanged?(activeVisionCheckbox.state == .on)
    }

    @objc private func desktopLyricsCheckboxChanged() {
        onDesktopLyricsChanged?(desktopLyricsCheckbox.state == .on)
    }

    @objc private func slideshowAnnotationCheckboxChanged() {
        onSlideshowAnnotationChanged?(slideshowAnnotationCheckbox.state == .on)
    }

    @objc private func loginItemCheckboxChanged() {
        onLoginItemChanged?(loginItemCheckbox.state == .on)
    }

    @objc private func accessibilityCheckboxChanged() {
        let wantsEnable = accessibilityCheckbox.state == .on
        accessibilityCheckbox.state = isAccessibilityEnabledForDisplay ? .on : .off
        if wantsEnable { onAccessibilityEnableRequested?() } else { onAccessibilityDisableRequested?() }
    }

    @objc private func loginItemClicked() {
        onLoginItemGuide?()
    }

    @objc private func accessibilityClicked() {
        onAccessibilityGuide?()
    }

    @objc private func clearDataAndQuitClicked() {
        onClearDataAndQuit?()
    }

    @objc private func quitClicked() {
        onQuit?()
    }

    @objc private func checkUpdateClicked() {
        onCheckUpdateRequested?()
    }

    @objc private func backButtonClicked() {
        if page == .searchSettings || page == .screenshotSettings {
            showSelectionToolbarSettingsPage()
        } else if page == .appleMusicSettings || page == .musicLyricsWhitelistSettings || page == .desktopLyricsSurfaceSettings || page == .dynamicIslandLyricsSettings || page == .menuBarLyricsSettings {
            showDesktopLyricsSettingsPage()
        } else {
            showModulesPage()
        }
    }

    @objc private func showModulesPage() {
        page = .modules
        layoutForCurrentPage()
    }

    private func showSettingsPage(_ newPage: Page) {
        shouldScrollSettingsContentToTop = page != newPage
        page = newPage
        layoutForCurrentPage()
    }

    @objc private func showCapsLockSettingsPage() {
        showSettingsPage(.capsLockSettings)
    }

    @objc private func showSelectionToolbarSettingsPage() {
        showSettingsPage(.selectionToolbarSettings)
    }

    @objc private func showActiveVisionSettingsPage() {
        showSettingsPage(.activeVisionSettings)
    }

    @objc private func showDesktopLyricsSettingsPage() {
        showSettingsPage(.desktopLyricsSettings)
    }

    private func showDesktopLyricsSurfaceSettingsPage() {
        showSettingsPage(.desktopLyricsSurfaceSettings)
    }

    private func showDynamicIslandLyricsSettingsPage() {
        showSettingsPage(.dynamicIslandLyricsSettings)
    }

    private func showMenuBarLyricsSettingsPage() {
        showSettingsPage(.menuBarLyricsSettings)
    }

    private func showAppleMusicSettingsPage() {
        showSettingsPage(.appleMusicSettings)
    }

    @objc private func showMusicLyricsWhitelistSettingsPage() {
        refreshAvailableApplications()
        showSettingsPage(.musicLyricsWhitelistSettings)
    }

    private func showSearchSettingsPage() {
        showSettingsPage(.searchSettings)
    }

    private func showScreenshotSettingsPage() {
        showSettingsPage(.screenshotSettings)
    }

    @objc private func searchEngineSelected() {
        let index = searchEnginePopup.indexOfSelectedItem
        guard index != SearchEnginePreset.all.count else {
            isSearchTemplateCustom = true
            updateSearchTemplateFieldLock(isCustom: true)
            return
        }

        guard SearchEnginePreset.all.indices.contains(index) else { return }
        isSearchTemplateCustom = false
        searchTemplateField.stringValue = SearchEnginePreset.all[index].template
        updateSearchTemplateFieldLock(isCustom: false)
        commitSearchTemplate()
    }

    @objc private func searchTemplateCommitted() {
        commitSearchTemplate()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // 回车场景 action 与 end-editing 会先后到达：以最近提交值为幂等闸门去重。
        if notification.object as? NSTextField === searchTemplateField { commitSearchTemplate() }
    }

    private func commitSearchTemplate() {
        let trimmed = searchTemplateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastCommittedSearchTemplate else { return }
        lastCommittedSearchTemplate = trimmed
        onSearchTemplateChanged?(trimmed)
    }

    @objc private func screenshotSaveDirectoryClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: screenshotSaveButton.toolTip ?? screenshotSaveButton.title, isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        screenshotSaveButton.title = Self.displayName(forDirectoryAt: url.path)
        onScreenshotSaveDirectoryChanged?(url.path)
    }

    @objc private func screenshotCopyCheckboxChanged() {
        onScreenshotCopiesToClipboardChanged?(screenshotCopyCheckbox.state == .on)
    }

    @objc private func screenshotRegionCheckboxChanged() {
        onScreenshotSelectsRegionChanged?(screenshotRegionCheckbox.state == .on)
    }

    @objc private func activeVisionGazeCheckboxChanged() {
        onActiveVisionGazeChanged?(activeVisionGazeCheckbox.state == .on)
    }

    @objc private func activeVisionFacingCheckboxChanged() {
        onActiveVisionFacingChanged?(activeVisionFacingCheckbox.state == .on)
    }

    @objc private func activeVisionNotifyCheckboxChanged() {
        onActiveVisionNotifyChanged?(activeVisionNotifyCheckbox.state == .on)
    }

    @objc private func desktopLyricsLanguageSelected() {
        let index = desktopLyricsLanguagePopup.indexOfSelectedItem
        guard DesktopLyricsPreferredLanguage.allCases.indices.contains(index) else { return }
        onDesktopLyricsPreferredLanguageChanged?(DesktopLyricsPreferredLanguage.allCases[index])
    }

    @objc private func desktopLyricsSurfaceCheckboxChanged() {
        onDesktopLyricsSurfaceChanged?(desktopLyricsSurfaceCheckbox.state == .on)
    }

    @objc private func dynamicIslandLyricsCheckboxChanged() {
        onDynamicIslandLyricsChanged?(dynamicIslandLyricsCheckbox.state == .on)
    }

    @objc private func dynamicIslandLyricsSpectrumCheckboxChanged() {
        onDynamicIslandLyricsSpectrumChanged?(dynamicIslandLyricsSpectrumCheckbox.state == .on)
    }

    @objc private func dynamicIslandLyricsHideOnHoverCheckboxChanged() {
        onDynamicIslandLyricsHideOnHoverChanged?(dynamicIslandLyricsHideOnHoverCheckbox.state == .on)
    }

    @objc private func menuBarLyricsCheckboxChanged() {
        onMenuBarLyricsChanged?(menuBarLyricsCheckbox.state == .on)
    }

    @objc private func desktopLyricsWidthChanged() {
        onDesktopLyricsWidthChanged?(desktopLyricsWidthSlider.doubleValue)
    }

    @objc private func desktopLyricsAlignmentSelected() {
        let index = desktopLyricsAlignmentPopup.indexOfSelectedItem
        guard LyricsTextAlignment.allCases.indices.contains(index) else { return }
        onDesktopLyricsAlignmentChanged?(LyricsTextAlignment.allCases[index])
    }

    @objc private func dynamicIslandLyricsWidthChanged() {
        onDynamicIslandLyricsWidthChanged?(dynamicIslandLyricsWidthSlider.doubleValue)
    }

    @objc private func dynamicIslandLyricsBlankWidthChanged() {
        onDynamicIslandLyricsBlankWidthChanged?(dynamicIslandLyricsBlankWidthSlider.doubleValue)
    }

    @objc private func dynamicIslandLyricsHeightChanged() {
        dynamicIslandLyricsHeightValueLabel.stringValue = "\(Int(round(dynamicIslandLyricsHeightSlider.doubleValue))) px"
        onDynamicIslandLyricsHeightChanged?(dynamicIslandLyricsHeightSlider.doubleValue)
    }

    @objc private func dynamicIslandLyricsSlantRatioChanged() {
        dynamicIslandLyricsSlantRatioValueLabel.stringValue = "\(Int(round(dynamicIslandLyricsSlantRatioSlider.doubleValue)))"
        onDynamicIslandLyricsSlantRatioChanged?(dynamicIslandLyricsSlantRatioSlider.doubleValue / 100.0)
    }

    @objc private func dynamicIslandLyricsCornerRatioChanged() {
        dynamicIslandLyricsCornerRatioValueLabel.stringValue = "\(Int(round(dynamicIslandLyricsCornerRatioSlider.doubleValue)))"
        onDynamicIslandLyricsCornerRatioChanged?(dynamicIslandLyricsCornerRatioSlider.doubleValue / 100.0)
    }

    @objc private func dynamicIslandLyricsFontSizeChanged() {
        dynamicIslandLyricsFontSizeValueLabel.stringValue = "\(Int(round(dynamicIslandLyricsFontSizeSlider.doubleValue)))"
        onDynamicIslandLyricsFontSizeChanged?(dynamicIslandLyricsFontSizeSlider.doubleValue)
    }

    @objc private func dynamicIslandLyricsFontSelected() {
        let title = dynamicIslandLyricsFontPopup.titleOfSelectedItem ?? ""
        onDynamicIslandLyricsFontNameChanged?(title == "系统默认" ? "" : title)
    }

    @objc private func dynamicIslandLyricsAlignmentSelected() {
        let index = dynamicIslandLyricsAlignmentPopup.indexOfSelectedItem
        guard LyricsTextAlignment.allCases.indices.contains(index) else { return }
        onDynamicIslandLyricsAlignmentChanged?(LyricsTextAlignment.allCases[index])
    }

    @objc private func menuBarLyricsWidthChanged() {
        onMenuBarLyricsWidthChanged?(menuBarLyricsWidthSlider.doubleValue)
    }

    @objc private func menuBarLyricsAlignmentSelected() {
        let index = menuBarLyricsAlignmentPopup.indexOfSelectedItem
        guard LyricsTextAlignment.allCases.indices.contains(index) else { return }
        onMenuBarLyricsAlignmentChanged?(LyricsTextAlignment.allCases[index])
    }

    @objc private func desktopLyricsTranslationCheckboxChanged() {
        onDesktopLyricsShowsTranslationChanged?(desktopLyricsTranslationCheckbox.state == .on)
    }

    @objc private func desktopLyricsFontSizeChanged() {
        onDesktopLyricsFontSizeChanged?(desktopLyricsFontSizeSlider.doubleValue)
    }

    @objc private func desktopLyricsLockCheckboxChanged() {
        onDesktopLyricsLockedChanged?(desktopLyricsLockCheckbox.state == .on)
    }

    @objc private func desktopLyricsStyleSelected() {
        let index = desktopLyricsStylePopup.indexOfSelectedItem
        guard DesktopLyricsStylePreset.allCases.indices.contains(index) else { return }
        onDesktopLyricsStylePresetChanged?(DesktopLyricsStylePreset.allCases[index])
    }

    @objc private func desktopLyricsFontSelected() {
        let title = desktopLyricsFontPopup.titleOfSelectedItem ?? ""
        onDesktopLyricsFontNameChanged?(title == "系统默认" ? "" : title)
    }

    @objc private func desktopLyricsTextColorChanged() {
        onDesktopLyricsTextColorChanged?(desktopLyricsTextColorWell.color.hexString)
    }

    @objc private func desktopLyricsStrokeColorChanged() {
        onDesktopLyricsStrokeColorChanged?(desktopLyricsStrokeColorWell.color.hexString)
    }

    @objc private func desktopLyricsStrokeWidthChanged() {
        onDesktopLyricsStrokeWidthChanged?(desktopLyricsStrokeWidthSlider.doubleValue)
    }

    @objc private func appleMusicLoginClicked() {
        onAppleMusicLoginRequested?()
    }

    @objc private func appleMusicClearTokenClicked() {
        onAppleMusicTokenCleared?()
    }

    private func addWhitelistApplication() {
        refreshAvailableApplications()
        let selectedIDs = Set(whitelistApplications.map(\.bundleIdentifier))
        let candidates = availableApplications.filter { !selectedIDs.contains($0.bundleIdentifier) }
        guard !candidates.isEmpty else { return }

        let menu = NSMenu()
        for app in candidates {
            let item = NSMenuItem(title: app.displayName, action: #selector(addWhitelistApplicationFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.bundleIdentifier
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: whitelistAddButton.bounds.height + 4), in: whitelistAddButton)
    }

    private func removeWhitelistApplication() {
        let selectedRow = whitelistTableView.selectedRow
        guard whitelistApplications.indices.contains(selectedRow) else { return }
        whitelistApplications.remove(at: selectedRow)
        commitWhitelistApplications()
    }

    @objc private func addWhitelistApplicationFromMenu(_ sender: NSMenuItem) {
        guard let bundleIdentifier = sender.representedObject as? String,
              let app = availableApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }),
              !whitelistApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        whitelistApplications.append(app)
        whitelistApplications.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        commitWhitelistApplications()
    }

    private func commitWhitelistApplications() {
        onMusicLyricsAppWhitelistChanged?(whitelistApplications.isEmpty ? musicLyricsAppWhitelistEmptySentinel : whitelistApplications.map(\.bundleIdentifier).joined(separator: "\n"))
    }

    private func refreshAvailableApplications(reRenderWhitelistWhenDone: Bool = false) {
        if reRenderWhitelistWhenDone {
            needsWhitelistRerenderWhenLoaded = true
        }
        guard !isLoadingAvailableApplications else { return }
        isLoadingAvailableApplications = true
        Task { [weak self] in
            let apps = await Task.detached(priority: .utility) {
                Self.enumerateApplications()
            }.value

            guard let self else { return }
            self.isLoadingAvailableApplications = false
            self.availableApplications = apps

            if self.needsWhitelistRerenderWhenLoaded {
                self.needsWhitelistRerenderWhenLoaded = false
                if let rawValue = self.lastRenderedWhitelistRawValue {
                    self.renderWhitelist(rawValue)
                }
            }
        }
    }

    /// 递归枚举应用目录（后台线程调用）：/Applications 全量遍历较慢，禁止在主线程执行。
    private nonisolated static func enumerateApplications() -> [ApplicationChoice] {
        let roots = [
            "/Applications",
            "/System/Applications",
            NSHomeDirectory() + "/Applications"
        ]
        var appsByBundleID: [String: ApplicationChoice] = [:]
        let fileManager = FileManager.default
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url),
                      let bundleIdentifier = bundle.bundleIdentifier,
                      !bundleIdentifier.isEmpty else { continue }
                let displayName = localizedApplicationName(bundle: bundle, url: url)
                appsByBundleID[bundleIdentifier] = ApplicationChoice(
                    bundleIdentifier: bundleIdentifier,
                    displayName: displayName
                )
            }
        }
        return appsByBundleID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        whitelistApplications.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("WhitelistApplicationCell")
        let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? WhitelistApplicationCell) ?? WhitelistApplicationCell()
        view.identifier = identifier
        let app = whitelistApplications.indices.contains(row) ? whitelistApplications[row] : nil
        view.set(
            title: app?.displayName ?? "",
            subtitle: app?.bundleIdentifier ?? ""
        )
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        WhitelistApplicationRowView()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        whitelistApplications.indices.contains(row)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateWhitelistSelectionState()
    }

    private nonisolated static func localizedApplicationName(bundle: Bundle, url: URL) -> String {
        let keys = ["CFBundleDisplayName", "CFBundleName"]
        for key in keys {
            if let value = bundle.localizedInfoDictionary?[key] as? String, !value.isEmpty { return value }
            if let value = bundle.infoDictionary?[key] as? String, !value.isEmpty { return value }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private var settingsContentWidth: CGFloat {
        let scrollerGutter = settingsScrollView.hasVerticalScroller ? Metrics.overlayScrollerSafeGutter : 0
        return max(0, settingsScrollView.contentView.bounds.width - Metrics.sectionInset * 2 - scrollerGutter)
    }

    private var whitelistContentSafeGutter: CGFloat {
        whitelistScrollView.hasVerticalScroller ? Metrics.overlayScrollerSafeGutter : 0
    }

    private func configureSystemScrollView(_ scrollView: NSScrollView) {
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(
            top: Metrics.overlayScrollerVerticalInset,
            left: 0,
            bottom: Metrics.overlayScrollerVerticalInset,
            right: Metrics.overlayScrollerRightInset
        )
    }

    private func updateVerticalScrollerVisibility(for scrollView: NSScrollView, contentHeight: CGFloat) {
        // 样式/内边距与 configureSystemScrollView 一致：重设一遍以兜住运行期
        // 被外部改动的情况，这里只关心滚动条显隐的切换与重排。
        configureSystemScrollView(scrollView)

        let visibleHeight = max(0, scrollView.contentView.bounds.height)
        let shouldShowVerticalScroller = contentHeight > visibleHeight + 1
        if scrollView.hasVerticalScroller != shouldShowVerticalScroller {
            scrollView.hasVerticalScroller = shouldShowVerticalScroller
        }

        scrollView.tile()
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func prepareSettingsContent(minimumHeight: CGFloat) {
        updateVerticalScrollerVisibility(for: settingsScrollView, contentHeight: minimumHeight)
        let visibleSize = settingsScrollView.contentView.bounds.size
        let visibleHeight = max(1, visibleSize.height)
        let contentWidth = max(1, visibleSize.width)
        let contentHeight = max(minimumHeight, visibleHeight)
        let oldOrigin = settingsScrollView.contentView.bounds.origin

        settingsContentHeight = contentHeight
        settingsContentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)

        let maxOriginY = max(0, contentHeight - visibleHeight)
        let targetOriginY = shouldScrollSettingsContentToTop
            ? maxOriginY
            : min(max(oldOrigin.y, 0), maxOriginY)
        settingsScrollView.contentView.scroll(to: NSPoint(x: 0, y: targetOriginY))
        settingsScrollView.reflectScrolledClipView(settingsScrollView.contentView)
        shouldScrollSettingsContentToTop = false
    }

    private func layoutForCurrentPage() {
        glassContainer.frame = bounds
        glassContentView.frame = bounds

        switch page {
        case .modules:
            layoutModulesPage()
        case .capsLockSettings:
            layoutSettingsBase(title: "大写指示器")
            clickToDisableCheckbox.sizeToFit()
            prepareSettingsContent(minimumHeight: Metrics.sectionInset * 2 + clickToDisableCheckbox.frame.height)
            clickToDisableCheckbox.isHidden = false
            clickToDisableCheckbox.frame.origin = NSPoint(
                x: Metrics.sectionInset,
                y: settingsContentHeight - Metrics.sectionInset - clickToDisableCheckbox.frame.height
            )
        case .selectionToolbarSettings:
            layoutSelectionToolbarSettingsPage()
        case .activeVisionSettings:
            layoutActiveVisionSettingsPage()
        case .desktopLyricsSettings:
            layoutDesktopLyricsSettingsPage()
        case .desktopLyricsSurfaceSettings:
            layoutDesktopLyricsSurfaceSettingsPage()
        case .dynamicIslandLyricsSettings:
            layoutDynamicIslandLyricsSettingsPage()
        case .menuBarLyricsSettings:
            layoutMenuBarLyricsSettingsPage()
        case .appleMusicSettings:
            layoutAppleMusicSettingsPage()
        case .musicLyricsWhitelistSettings:
            layoutMusicLyricsWhitelistSettingsPage()
        case .searchSettings:
            layoutSearchSettingsPage()
        case .screenshotSettings:
            layoutScreenshotSettingsPage()
        }
    }

    private func layoutModulesPage() {
        let width = bounds.width
        let height = bounds.height
        let contentX = Metrics.outerPadding
        let contentWidth = width - Metrics.outerPadding * 2
        let footerY = Metrics.outerPadding
        let toolCardFrame = NSRect(x: contentX, y: height - 174, width: contentWidth, height: 86)
        let moduleCardFrame = NSRect(
            x: contentX,
            y: footerY + Metrics.footerHeight + Metrics.sectionGap,
            width: contentWidth,
            height: toolCardFrame.minY - footerY - Metrics.footerHeight - Metrics.sectionGap * 2 - 20
        )

        hideAllControls()
        show(
            titleLabel, versionLabel, checkUpdateButton, toolOptionsTitle, toolOptionsCard, loginItemCheckbox, accessibilityCheckbox,
            moduleTitle, moduleCard, capsLockCheckbox, selectionToolbarCheckbox, activeVisionCheckbox, desktopLyricsCheckbox, slideshowAnnotationCheckbox,
            capsLockSettingsButton, selectionToolbarSettingsButton, activeVisionSettingsButton, desktopLyricsSettingsButton, loginItemButton, accessibilityButton,
            clearDataAndQuitButton, quitButton
        )

        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(
            x: contentX,
            y: height - Metrics.titleTopInset - titleLabel.frame.height
        )

        versionLabel.stringValue = Self.appVersionDisplayString()
        versionLabel.sizeToFit()

        let checkButtonWidth: CGFloat = 72
        let checkButtonHeight: CGFloat = 24
        checkUpdateButton.frame = NSRect(
            x: width - Metrics.outerPadding - checkButtonWidth,
            y: titleLabel.frame.midY - checkButtonHeight / 2,
            width: checkButtonWidth,
            height: checkButtonHeight
        )
        let versionMaxX = checkUpdateButton.frame.minX - 8
        let versionX = min(titleLabel.frame.maxX + 10, versionMaxX - versionLabel.frame.width)
        versionLabel.frame.origin = NSPoint(
            x: max(contentX, versionX),
            y: titleLabel.frame.midY - versionLabel.frame.height / 2 - 0.5
        )

        toolOptionsTitle.sizeToFit()
        toolOptionsTitle.frame.origin = NSPoint(x: contentX + 2, y: toolCardFrame.maxY + 8)
        toolOptionsCard.frame = toolCardFrame

        loginItemCheckbox.sizeToFit()
        loginItemCheckbox.frame.origin = NSPoint(
            x: toolCardFrame.minX + Metrics.sectionInset,
            y: toolCardFrame.maxY - Metrics.sectionInset - loginItemCheckbox.frame.height
        )

        accessibilityCheckbox.sizeToFit()
        accessibilityCheckbox.frame.origin = NSPoint(
            x: toolCardFrame.minX + Metrics.sectionInset,
            y: toolCardFrame.minY + Metrics.sectionInset
        )

        moduleTitle.sizeToFit()
        moduleTitle.frame.origin = NSPoint(x: contentX + 2, y: moduleCardFrame.maxY + 8)
        moduleCard.frame = moduleCardFrame

        let capsRowY = moduleCardFrame.maxY - Metrics.sectionInset - Metrics.rowHeight
        layoutModuleRow(
            checkbox: capsLockCheckbox,
            settingsButton: capsLockSettingsButton,
            rowY: capsRowY,
            cardFrame: moduleCardFrame
        )

        layoutModuleRow(
            checkbox: selectionToolbarCheckbox,
            settingsButton: selectionToolbarSettingsButton,
            rowY: capsRowY - Metrics.rowHeight,
            cardFrame: moduleCardFrame
        )

        layoutModuleRow(
            checkbox: activeVisionCheckbox,
            settingsButton: activeVisionSettingsButton,
            rowY: capsRowY - Metrics.rowHeight * 2,
            cardFrame: moduleCardFrame
        )

        layoutModuleRow(
            checkbox: desktopLyricsCheckbox,
            settingsButton: desktopLyricsSettingsButton,
            rowY: capsRowY - Metrics.rowHeight * 3,
            cardFrame: moduleCardFrame
        )

        layoutModuleRow(
            checkbox: slideshowAnnotationCheckbox,
            settingsButton: slideshowAnnotationSettingsButton,
            rowY: capsRowY - Metrics.rowHeight * 4,
            cardFrame: moduleCardFrame
        )

        let gap: CGFloat = 10
        quitButton.frame = NSRect(x: width - Metrics.outerPadding - 54, y: footerY, width: 54, height: Metrics.footerHeight)
        clearDataAndQuitButton.frame = NSRect(x: quitButton.frame.minX - gap - 134, y: footerY, width: 134, height: Metrics.footerHeight)
        accessibilityButton.frame = NSRect(x: clearDataAndQuitButton.frame.minX - gap - 132, y: footerY, width: 132, height: Metrics.footerHeight)
        loginItemButton.frame = NSRect(x: accessibilityButton.frame.minX - gap - 122, y: footerY, width: 122, height: Metrics.footerHeight)
    }

    private func layoutModuleRow(checkbox: NSButton, settingsButton: IconButtonView, rowY: CGFloat, cardFrame: NSRect) {
        let rowMidY = rowY + Metrics.rowHeight / 2

        checkbox.sizeToFit()
        checkbox.frame.origin = NSPoint(
            x: cardFrame.minX + Metrics.sectionInset,
            y: rowMidY - checkbox.frame.height / 2
        )

        let settingsHitSize: CGFloat = 30
        settingsButton.frame = NSRect(
            x: checkbox.frame.maxX + 6,
            y: rowMidY - settingsHitSize / 2,
            width: settingsHitSize,
            height: settingsHitSize
        )
    }

    private func row(for action: ToolbarAction) -> ActionSettingRow {
        switch action {
        case .selectAll: return selectAllRow
        case .copy: return copyRow
        case .paste: return pasteRow
        case .search: return searchRow
        case .screenshot: return screenshotRow
        }
    }

    private func layoutSelectionToolbarSettingsPage() {
        layoutSettingsBase(title: "选区工具栏")
        let rows = selectionToolbarOrder.map { row(for: $0) }
        show(selectionToolbarSettingTitle, selectionToolbarHideInFullscreenCheckbox, selectionToolbarOrderTitle)
        rows.forEach { show($0) }

        // 面板分上下两区：上方为设置项目（标题 + checkbox），下方为可排序按钮列表
        // （下区标题 + rows）。Cocoa 坐标系 y 向上为正，origin.y 是视图底部 y；从
        // 上往下累减 topY 可避免 maxY/minY 误用导致元素重叠。
        let gapUpper: CGFloat = 8      // setting 标题与 checkbox 间距
        let gapBetween: CGFloat = 24   // 上区 checkbox 与下区标题间距
        let gapLower: CGFloat = 8      // 下区标题与 rows 间距
        selectionToolbarSettingTitle.sizeToFit()
        selectionToolbarHideInFullscreenCheckbox.sizeToFit()
        selectionToolbarOrderTitle.sizeToFit()
        let titleH = selectionToolbarSettingTitle.frame.height
        let checkboxH = selectionToolbarHideInFullscreenCheckbox.frame.height
        let orderTitleH = selectionToolbarOrderTitle.frame.height
        let upperBlockHeight = titleH + gapUpper + checkboxH + gapBetween + orderTitleH + gapLower
        prepareSettingsContent(minimumHeight: Metrics.sectionInset * 2 + upperBlockHeight + Metrics.rowHeight * CGFloat(rows.count))

        let contentX = Metrics.sectionInset
        let contentWidth = settingsContentWidth
        var topY = settingsContentHeight - Metrics.sectionInset

        // 1. setting 标题
        topY -= titleH
        selectionToolbarSettingTitle.frame.origin = NSPoint(x: contentX + 2, y: topY)

        // 2. 间距 8 → checkbox
        topY -= gapUpper + checkboxH
        selectionToolbarHideInFullscreenCheckbox.frame.origin = NSPoint(x: contentX, y: topY)

        // 3. 间距 24 → order 标题
        topY -= gapBetween + orderTitleH
        selectionToolbarOrderTitle.frame.origin = NSPoint(x: contentX + 2, y: topY)

        // 4. 间距 8 → rows
        topY -= gapLower
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(
                x: contentX,
                y: topY - Metrics.rowHeight - CGFloat(index) * Metrics.rowHeight,
                width: contentWidth,
                height: Metrics.rowHeight
            )
        }
    }

    private func desktopLyricsRow(for source: DesktopLyricsSource) -> DesktopLyricsSourceRow {
        switch source {
        case .appleMusic: return appleMusicSourceRow
        case .qqMusic: return qqMusicSourceRow
        case .netease: return neteaseSourceRow
        }
    }

    private func layoutSearchSettingsPage() {
        layoutSettingsBase(title: "搜索")
        show(searchEnginePopup, searchTemplateField)
        prepareSettingsContent(minimumHeight: Metrics.sectionInset * 2 + 34 + 52 + 34)

        let contentX = Metrics.sectionInset
        let contentWidth = settingsContentWidth
        searchEnginePopup.frame = NSRect(
            x: contentX,
            y: settingsContentHeight - Metrics.sectionInset - 34,
            width: 150,
            height: 32
        )
        searchTemplateField.frame = NSRect(
            x: contentX,
            y: searchEnginePopup.frame.minY - 52,
            width: contentWidth,
            height: 34
        )
    }

    private func layoutScreenshotSettingsPage() {
        layoutSettingsBase(title: "截图")
        show(screenshotSaveLabel, screenshotSaveButton, screenshotCopyCheckbox, screenshotRegionCheckbox)
        prepareSettingsContent(minimumHeight: Metrics.sectionInset * 2 + 32 + 42 + 32 + 42 + 24 + 34 + 24)

        let contentX = Metrics.sectionInset
        let contentWidth = settingsContentWidth
        screenshotSaveLabel.sizeToFit()
        screenshotSaveLabel.frame.origin = NSPoint(
            x: contentX,
            y: settingsContentHeight - Metrics.sectionInset - screenshotSaveLabel.frame.height
        )
        screenshotSaveButton.frame = NSRect(
            x: contentX,
            y: screenshotSaveLabel.frame.minY - 42,
            width: contentWidth,
            height: 32
        )

        layoutCheckbox(screenshotCopyCheckbox, below: screenshotSaveButton.frame, gap: 42, contentX: contentX)
        layoutCheckbox(screenshotRegionCheckbox, below: screenshotCopyCheckbox.frame, gap: 34, contentX: contentX)
    }

    private func layoutDesktopLyricsSettingsPage() {
        layoutSettingsBase(title: "音乐歌词")
        let rows = desktopLyricsSourceOrder.map { desktopLyricsRow(for: $0) }
        show(
            desktopLyricsHintLabel, desktopLyricsLanguageLabel, desktopLyricsLanguagePopup,
            desktopLyricsSurfaceCheckbox, desktopLyricsSurfaceSettingsButton,
            dynamicIslandLyricsCheckbox, dynamicIslandLyricsSettingsButton,
            menuBarLyricsCheckbox, menuBarLyricsSettingsButton,
            musicLyricsWhitelistLabel, musicLyricsWhitelistButton, lyricsSourceLabel
        )
        rows.forEach { show($0) }
        prepareSettingsContent(minimumHeight: 470 + Metrics.rowHeight * CGFloat(max(0, rows.count - 3)))

        let contentX = Metrics.sectionInset
        let contentWidth = settingsContentWidth
        desktopLyricsHintLabel.stringValue = "开启需要的歌词形态；点右侧设置图标进入对应子菜单。歌词源和白名单为通用设置。"
        desktopLyricsHintLabel.frame = NSRect(
            x: contentX,
            y: settingsContentHeight - Metrics.sectionInset - 36,
            width: contentWidth,
            height: 34
        )

        desktopLyricsLanguageLabel.sizeToFit()
        desktopLyricsLanguageLabel.frame.origin = NSPoint(
            x: contentX,
            y: desktopLyricsHintLabel.frame.minY - 38
        )
        desktopLyricsLanguagePopup.frame = NSRect(
            x: desktopLyricsLanguageLabel.frame.maxX + 8,
            y: desktopLyricsLanguageLabel.frame.midY - 16,
            width: 150,
            height: 32
        )

        var rowY = desktopLyricsLanguagePopup.frame.minY - 52
        layoutLyricsFeatureRow(
            checkbox: desktopLyricsSurfaceCheckbox,
            settingsButton: desktopLyricsSurfaceSettingsButton,
            rowY: rowY,
            contentX: contentX,
            contentWidth: contentWidth
        )
        rowY -= Metrics.rowHeight
        layoutLyricsFeatureRow(
            checkbox: dynamicIslandLyricsCheckbox,
            settingsButton: dynamicIslandLyricsSettingsButton,
            rowY: rowY,
            contentX: contentX,
            contentWidth: contentWidth
        )
        rowY -= Metrics.rowHeight
        layoutLyricsFeatureRow(
            checkbox: menuBarLyricsCheckbox,
            settingsButton: menuBarLyricsSettingsButton,
            rowY: rowY,
            contentX: contentX,
            contentWidth: contentWidth
        )

        musicLyricsWhitelistLabel.stringValue = "白名单应用："
        musicLyricsWhitelistLabel.sizeToFit()
        musicLyricsWhitelistLabel.frame.origin = NSPoint(
            x: contentX,
            y: rowY - 44
        )
        musicLyricsWhitelistButton.frame = NSRect(
            x: contentX,
            y: musicLyricsWhitelistLabel.frame.minY - 38,
            width: contentWidth,
            height: 32
        )

        lyricsSourceLabel.sizeToFit()
        lyricsSourceLabel.frame.origin = NSPoint(
            x: contentX,
            y: musicLyricsWhitelistButton.frame.minY - 42
        )
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(
                x: contentX,
                y: lyricsSourceLabel.frame.minY - 8 - Metrics.rowHeight - CGFloat(index) * Metrics.rowHeight,
                width: contentWidth,
                height: Metrics.rowHeight
            )
        }
    }

    private func layoutLyricsFeatureRow(
        checkbox: NSButton,
        settingsButton: IconButtonView,
        rowY: CGFloat,
        contentX: CGFloat,
        contentWidth: CGFloat
    ) {
        let rowMidY = rowY + Metrics.rowHeight / 2
        checkbox.sizeToFit()
        checkbox.frame.origin = NSPoint(
            x: contentX,
            y: rowMidY - checkbox.frame.height / 2
        )
        let hitSize: CGFloat = 30
        let iconGap: CGFloat = 10
        let desiredIconX = checkbox.frame.maxX + iconGap
        let maxIconX = contentX + contentWidth - hitSize
        settingsButton.frame = NSRect(
            x: min(desiredIconX, maxIconX),
            y: rowMidY - hitSize / 2,
            width: hitSize,
            height: hitSize
        )
    }

    @discardableResult
    private func layoutSettingsSliderRow(
        label: NSTextField,
        slider: NSSlider,
        valueLabel: NSTextField,
        y: CGFloat,
        contentX: CGFloat,
        contentWidth: CGFloat,
        valueWidth: CGFloat = 72
    ) -> CGFloat {
        label.sizeToFit()
        label.frame.origin = NSPoint(x: contentX, y: y)
        valueLabel.frame = NSRect(
            x: contentX + contentWidth - valueWidth,
            y: label.frame.minY,
            width: valueWidth,
            height: label.frame.height
        )
        slider.frame = NSRect(
            x: label.frame.maxX + 10,
            y: label.frame.midY - 12,
            width: valueLabel.frame.minX - label.frame.maxX - 20,
            height: 24
        )
        return slider.frame.minY - 34
    }

    private func layoutDesktopLyricsSurfaceSettingsPage() {
        layoutSettingsBase(title: "桌面歌词")
        show(
            desktopLyricsWidthLabel, desktopLyricsWidthSlider, desktopLyricsWidthValueLabel,
            desktopLyricsAlignmentLabel, desktopLyricsAlignmentPopup,
            desktopLyricsTranslationCheckbox, desktopLyricsLockCheckbox,
            desktopLyricsStyleLabel, desktopLyricsStylePopup,
            desktopLyricsFontSizeLabel, desktopLyricsFontSizeSlider, desktopLyricsFontSizeValueLabel,
            desktopLyricsFontLabel, desktopLyricsFontPopup,
            desktopLyricsTextColorLabel, desktopLyricsTextColorWell,
            desktopLyricsStrokeColorLabel, desktopLyricsStrokeColorWell,
            desktopLyricsStrokeWidthLabel, desktopLyricsStrokeWidthSlider, desktopLyricsStrokeWidthValueLabel
        )
        prepareSettingsContent(minimumHeight: 474)
        let contentX = Metrics.sectionInset
        let contentWidth = settingsContentWidth
        var y = settingsContentHeight - Metrics.sectionInset - 24
        y = layoutSettingsSliderRow(
            label: desktopLyricsWidthLabel,
            slider: desktopLyricsWidthSlider,
            valueLabel: desktopLyricsWidthValueLabel,
            y: y,
            contentX: contentX,
            contentWidth: contentWidth
        )

        desktopLyricsAlignmentLabel.sizeToFit()
        desktopLyricsAlignmentLabel.frame.origin = NSPoint(x: contentX, y: y)
        desktopLyricsAlignmentPopup.frame = NSRect(
            x: desktopLyricsAlignmentLabel.frame.maxX + 10,
            y: desktopLyricsAlignmentLabel.frame.midY - 16,
            width: 130,
            height: 32
        )
        y = desktopLyricsAlignmentPopup.frame.minY - 34

        desktopLyricsTranslationCheckbox.sizeToFit()
        desktopLyricsLockCheckbox.sizeToFit()
        desktopLyricsTranslationCheckbox.frame.origin = NSPoint(x: contentX, y: y)
        desktopLyricsLockCheckbox.frame.origin = NSPoint(x: contentX + 190, y: y)

        desktopLyricsStyleLabel.sizeToFit()
        desktopLyricsStyleLabel.frame.origin = NSPoint(x: contentX, y: y - 38)
        desktopLyricsStylePopup.frame = NSRect(
            x: desktopLyricsStyleLabel.frame.maxX + 10,
            y: desktopLyricsStyleLabel.frame.midY - 16,
            width: 150,
            height: 32
        )

        y = layoutSettingsSliderRow(
            label: desktopLyricsFontSizeLabel,
            slider: desktopLyricsFontSizeSlider,
            valueLabel: desktopLyricsFontSizeValueLabel,
            y: desktopLyricsStylePopup.frame.minY - 36,
            contentX: contentX,
            contentWidth: contentWidth,
            valueWidth: 58
        )

        desktopLyricsFontLabel.sizeToFit()
        desktopLyricsFontLabel.frame.origin = NSPoint(x: contentX, y: y)
        desktopLyricsFontPopup.frame = NSRect(
            x: desktopLyricsFontLabel.frame.maxX + 10,
            y: desktopLyricsFontLabel.frame.midY - 16,
            width: contentWidth - desktopLyricsFontLabel.frame.width - 10,
            height: 32
        )

        desktopLyricsTextColorLabel.sizeToFit()
        desktopLyricsTextColorLabel.frame.origin = NSPoint(x: contentX, y: desktopLyricsFontPopup.frame.minY - 38)
        desktopLyricsTextColorWell.frame = NSRect(x: desktopLyricsTextColorLabel.frame.maxX + 10, y: desktopLyricsTextColorLabel.frame.midY - 13, width: 56, height: 26)
        desktopLyricsStrokeColorLabel.sizeToFit()
        desktopLyricsStrokeColorLabel.frame.origin = NSPoint(x: contentX + 180, y: desktopLyricsTextColorLabel.frame.minY)
        desktopLyricsStrokeColorWell.frame = NSRect(x: desktopLyricsStrokeColorLabel.frame.maxX + 10, y: desktopLyricsStrokeColorLabel.frame.midY - 13, width: 56, height: 26)

        _ = layoutSettingsSliderRow(
            label: desktopLyricsStrokeWidthLabel,
            slider: desktopLyricsStrokeWidthSlider,
            valueLabel: desktopLyricsStrokeWidthValueLabel,
            y: desktopLyricsTextColorLabel.frame.minY - 38,
            contentX: contentX,
            contentWidth: contentWidth,
            valueWidth: 48
        )
    }

    private func layoutDynamicIslandLyricsSettingsPage() {
        layoutSettingsBase(title: "灵动大陆歌词")
        show(
            dynamicIslandLyricsWidthLabel, dynamicIslandLyricsWidthSlider, dynamicIslandLyricsWidthValueLabel,
            dynamicIslandLyricsBlankWidthLabel, dynamicIslandLyricsBlankWidthSlider, dynamicIslandLyricsBlankWidthValueLabel,
            dynamicIslandLyricsHeightLabel, dynamicIslandLyricsHeightSlider, dynamicIslandLyricsHeightValueLabel,
            dynamicIslandLyricsSlantRatioLabel, dynamicIslandLyricsSlantRatioSlider, dynamicIslandLyricsSlantRatioValueLabel,
            dynamicIslandLyricsCornerRatioLabel, dynamicIslandLyricsCornerRatioSlider, dynamicIslandLyricsCornerRatioValueLabel,
            dynamicIslandLyricsFontSizeLabel, dynamicIslandLyricsFontSizeSlider, dynamicIslandLyricsFontSizeValueLabel,
            dynamicIslandLyricsFontLabel, dynamicIslandLyricsFontPopup,
            dynamicIslandLyricsAlignmentLabel, dynamicIslandLyricsAlignmentPopup,
            dynamicIslandLyricsSpectrumCheckbox, dynamicIslandLyricsHideOnHoverCheckbox
        )
        prepareSettingsContent(minimumHeight: 430)
        let contentX = Metrics.sectionInset
        let contentWidth = settingsContentWidth
        var y = settingsContentHeight - Metrics.sectionInset - 24
        y = layoutSettingsSliderRow(
            label: dynamicIslandLyricsWidthLabel,
            slider: dynamicIslandLyricsWidthSlider,
            valueLabel: dynamicIslandLyricsWidthValueLabel,
            y: y,
            contentX: contentX,
            contentWidth: contentWidth
        )
        y = layoutSettingsSliderRow(
            label: dynamicIslandLyricsBlankWidthLabel,
            slider: dynamicIslandLyricsBlankWidthSlider,
            valueLabel: dynamicIslandLyricsBlankWidthValueLabel,
            y: y,
            contentX: contentX,
            contentWidth: contentWidth
        )
        y = layoutSettingsSliderRow(
            label: dynamicIslandLyricsHeightLabel,
            slider: dynamicIslandLyricsHeightSlider,
            valueLabel: dynamicIslandLyricsHeightValueLabel,
            y: y,
            contentX: contentX,
            contentWidth: contentWidth
        )
        y = layoutSettingsSliderRow(
            label: dynamicIslandLyricsSlantRatioLabel,
            slider: dynamicIslandLyricsSlantRatioSlider,
            valueLabel: dynamicIslandLyricsSlantRatioValueLabel,
            y: y,
            contentX: contentX,
            contentWidth: contentWidth
        )
        y = layoutSettingsSliderRow(
            label: dynamicIslandLyricsCornerRatioLabel,
            slider: dynamicIslandLyricsCornerRatioSlider,
            valueLabel: dynamicIslandLyricsCornerRatioValueLabel,
            y: y,
            contentX: contentX,
            contentWidth: contentWidth
        )
        y = layoutSettingsSliderRow(
            label: dynamicIslandLyricsFontSizeLabel,
            slider: dynamicIslandLyricsFontSizeSlider,
            valueLabel: dynamicIslandLyricsFontSizeValueLabel,
            y: y,
            contentX: contentX,
            contentWidth: contentWidth,
            valueWidth: 58
        )
        dynamicIslandLyricsFontLabel.sizeToFit()
        dynamicIslandLyricsFontLabel.frame.origin = NSPoint(x: contentX, y: y)
        dynamicIslandLyricsFontPopup.frame = NSRect(
            x: dynamicIslandLyricsFontLabel.frame.maxX + 10,
            y: dynamicIslandLyricsFontLabel.frame.midY - 16,
            width: contentWidth - dynamicIslandLyricsFontLabel.frame.width - 10,
            height: 32
        )
        y = dynamicIslandLyricsFontPopup.frame.minY - 34
        dynamicIslandLyricsAlignmentLabel.sizeToFit()
        dynamicIslandLyricsAlignmentLabel.frame.origin = NSPoint(x: contentX, y: y)
        dynamicIslandLyricsAlignmentPopup.frame = NSRect(
            x: dynamicIslandLyricsAlignmentLabel.frame.maxX + 10,
            y: dynamicIslandLyricsAlignmentLabel.frame.midY - 16,
            width: 130,
            height: 32
        )
        y = dynamicIslandLyricsAlignmentPopup.frame.minY - 36
        dynamicIslandLyricsSpectrumCheckbox.sizeToFit()
        dynamicIslandLyricsSpectrumCheckbox.frame.origin = NSPoint(x: contentX, y: y)
        layoutCheckbox(dynamicIslandLyricsHideOnHoverCheckbox, below: dynamicIslandLyricsSpectrumCheckbox.frame, gap: 34, contentX: contentX)
    }

    private func layoutMenuBarLyricsSettingsPage() {
        layoutSettingsBase(title: "任务栏歌词")
        show(menuBarLyricsWidthLabel, menuBarLyricsWidthSlider, menuBarLyricsWidthValueLabel, menuBarLyricsAlignmentLabel, menuBarLyricsAlignmentPopup)
        prepareSettingsContent(minimumHeight: 154)
        let contentX = Metrics.sectionInset
        let contentWidth = settingsContentWidth
        let y = layoutSettingsSliderRow(
            label: menuBarLyricsWidthLabel,
            slider: menuBarLyricsWidthSlider,
            valueLabel: menuBarLyricsWidthValueLabel,
            y: settingsContentHeight - Metrics.sectionInset - 24,
            contentX: contentX,
            contentWidth: contentWidth
        )
        menuBarLyricsAlignmentLabel.sizeToFit()
        menuBarLyricsAlignmentLabel.frame.origin = NSPoint(x: contentX, y: y)
        menuBarLyricsAlignmentPopup.frame = NSRect(
            x: menuBarLyricsAlignmentLabel.frame.maxX + 10,
            y: menuBarLyricsAlignmentLabel.frame.midY - 16,
            width: 130,
            height: 32
        )
    }

    private func layoutAppleMusicSettingsPage() {
        layoutSettingsBase(title: "Apple Music")
        show(appleMusicTokenStatusLabel, appleMusicLoginButton, appleMusicClearTokenButton)
        prepareSettingsContent(minimumHeight: Metrics.sectionInset * 2 + 32 + 48 + 32)
        let contentX = Metrics.sectionInset
        let contentWidth = settingsContentWidth
        appleMusicTokenStatusLabel.frame = NSRect(
            x: contentX,
            y: settingsContentHeight - Metrics.sectionInset - 32,
            width: contentWidth,
            height: 28
        )
        appleMusicLoginButton.frame = NSRect(x: contentX, y: appleMusicTokenStatusLabel.frame.minY - 48, width: 170, height: 32)
        appleMusicClearTokenButton.frame = NSRect(x: appleMusicLoginButton.frame.maxX + 12, y: appleMusicLoginButton.frame.minY, width: 170, height: 32)
    }

    private func layoutMusicLyricsWhitelistSettingsPage() {
        layoutSettingsBase(title: "白名单应用")
        show(musicLyricsWhitelistLabel, whitelistScrollView, whitelistAddButton, whitelistRemoveButton)
        prepareSettingsContent(minimumHeight: 420)
        let contentX = Metrics.sectionInset
        let contentWidth = settingsContentWidth
        musicLyricsWhitelistLabel.stringValue = "已允许的应用："
        musicLyricsWhitelistLabel.sizeToFit()
        musicLyricsWhitelistLabel.frame.origin = NSPoint(x: contentX, y: settingsContentHeight - Metrics.sectionInset - musicLyricsWhitelistLabel.frame.height)
        whitelistScrollView.frame = NSRect(
            x: contentX,
            y: Metrics.sectionInset + 42,
            width: contentWidth,
            height: max(120, musicLyricsWhitelistLabel.frame.minY - Metrics.sectionInset - 56)
        )
        updateWhitelistTableLayout()
        whitelistAddButton.frame = NSRect(x: contentX, y: Metrics.sectionInset, width: 32, height: 32)
        whitelistRemoveButton.frame = NSRect(x: whitelistAddButton.frame.maxX + 8, y: whitelistAddButton.frame.minY, width: 32, height: 32)
        whitelistRemoveButton.isEnabled = whitelistTableView.selectedRow >= 0
    }

    private var whitelistContentHeight: CGFloat {
        let rowCount = whitelistApplications.count
        guard rowCount > 0 else { return 0 }
        return CGFloat(rowCount) * whitelistTableView.rowHeight + CGFloat(max(rowCount - 1, 0)) * whitelistTableView.intercellSpacing.height
    }

    private func updateWhitelistTableLayout() {
        updateVerticalScrollerVisibility(for: whitelistScrollView, contentHeight: whitelistContentHeight)
        let visibleBounds = whitelistScrollView.contentView.bounds
        let safeTrailingInset = whitelistContentSafeGutter
        whitelistTableView.contentTrailingSafeInset = safeTrailingInset
        let tableWidth = max(1, visibleBounds.width)
        let tableHeight = max(visibleBounds.height, whitelistContentHeight)
        whitelistTableView.frame = NSRect(x: 0, y: 0, width: tableWidth, height: tableHeight)
        whitelistTableView.tableColumns.first?.width = tableWidth
        whitelistTableView.noteNumberOfRowsChanged()
        whitelistTableView.setNeedsDisplay(whitelistTableView.bounds)
        updateWhitelistSelectionState()
    }

    private func updateWhitelistSelectionState() {
        let selectedRow = whitelistTableView.selectedRow
        whitelistRemoveButton.isEnabled = selectedRow >= 0 && whitelistApplications.indices.contains(selectedRow)
    }

    private func layoutActiveVisionSettingsPage() {
        layoutSettingsBase(title: "主动视觉感知")
        show(activeVisionGazeCheckbox, activeVisionFacingCheckbox, activeVisionNotifyCheckbox)

        let contentX = Metrics.sectionInset
        activeVisionGazeCheckbox.sizeToFit()
        activeVisionFacingCheckbox.sizeToFit()
        activeVisionNotifyCheckbox.sizeToFit()
        prepareSettingsContent(minimumHeight: Metrics.sectionInset * 2 + activeVisionGazeCheckbox.frame.height + 34 + activeVisionFacingCheckbox.frame.height + 34 + activeVisionNotifyCheckbox.frame.height)
        activeVisionGazeCheckbox.frame.origin = NSPoint(
            x: contentX,
            y: settingsContentHeight - Metrics.sectionInset - activeVisionGazeCheckbox.frame.height
        )
        layoutCheckbox(activeVisionFacingCheckbox, below: activeVisionGazeCheckbox.frame, gap: 34, contentX: contentX)
        layoutCheckbox(activeVisionNotifyCheckbox, below: activeVisionFacingCheckbox.frame, gap: 34, contentX: contentX)
    }

    private func layoutCheckbox(_ checkbox: NSButton, below frame: NSRect, gap: CGFloat, contentX: CGFloat) {
        checkbox.sizeToFit()
        checkbox.frame.origin = NSPoint(x: contentX, y: frame.minY - gap)
    }

    private func layoutSettingsBase(title: String) {
        let width = bounds.width
        let height = bounds.height
        let contentX = Metrics.outerPadding
        let headerY = height - 86
        let cardFrame = NSRect(
            x: contentX,
            y: Metrics.outerPadding,
            width: width - Metrics.outerPadding * 2,
            height: headerY - Metrics.sectionGap - Metrics.outerPadding
        )

        hideAllControls()
        show(settingsTitle, settingsCard, settingsScrollView, backButton)

        settingsScrollView.frame = cardFrame
        backButton.frame = NSRect(x: contentX, y: headerY, width: 34, height: 34)
        settingsTitle.stringValue = title
        settingsTitle.sizeToFit()
        settingsTitle.frame.origin = NSPoint(x: backButton.frame.maxX + 14, y: backButton.frame.midY - settingsTitle.frame.height / 2)
        settingsCard.frame = cardFrame
    }

    private func hideAllControls() {
        allControls.forEach { $0.isHidden = true }
    }

    private func show(_ views: NSView...) {
        views.forEach { $0.isHidden = false }
    }

    private lazy var allControls: [NSView] = [
        titleLabel, versionLabel, checkUpdateButton, toolOptionsTitle, moduleTitle, settingsTitle, toolOptionsCard, moduleCard, settingsCard, settingsScrollView,
        loginItemCheckbox, accessibilityCheckbox, capsLockCheckbox, selectionToolbarCheckbox, activeVisionCheckbox, desktopLyricsCheckbox, slideshowAnnotationCheckbox, clickToDisableCheckbox,
        selectionToolbarSettingTitle, selectionToolbarHideInFullscreenCheckbox, selectionToolbarOrderTitle,
        capsLockSettingsButton, selectionToolbarSettingsButton, activeVisionSettingsButton, desktopLyricsSettingsButton, slideshowAnnotationSettingsButton, backButton,
        loginItemButton, accessibilityButton, clearDataAndQuitButton, quitButton, selectAllRow, copyRow, pasteRow, searchRow, screenshotRow,
        appleMusicSourceRow, qqMusicSourceRow, neteaseSourceRow, searchEnginePopup, searchTemplateField, screenshotSaveLabel, screenshotSaveButton, screenshotCopyCheckbox,
        screenshotRegionCheckbox, activeVisionGazeCheckbox, activeVisionFacingCheckbox, activeVisionNotifyCheckbox,
        desktopLyricsHintLabel, desktopLyricsLanguageLabel, desktopLyricsLanguagePopup,
        desktopLyricsSurfaceCheckbox, desktopLyricsSurfaceSettingsButton, dynamicIslandLyricsCheckbox, dynamicIslandLyricsSettingsButton, dynamicIslandLyricsSpectrumCheckbox, dynamicIslandLyricsHideOnHoverCheckbox, menuBarLyricsCheckbox, menuBarLyricsSettingsButton,
        desktopLyricsWidthLabel, desktopLyricsWidthSlider, desktopLyricsWidthValueLabel, desktopLyricsAlignmentLabel, desktopLyricsAlignmentPopup,
        dynamicIslandLyricsWidthLabel, dynamicIslandLyricsWidthSlider, dynamicIslandLyricsWidthValueLabel,
        dynamicIslandLyricsBlankWidthLabel, dynamicIslandLyricsBlankWidthSlider, dynamicIslandLyricsBlankWidthValueLabel,
        dynamicIslandLyricsHeightLabel, dynamicIslandLyricsHeightSlider, dynamicIslandLyricsHeightValueLabel,
        dynamicIslandLyricsSlantRatioLabel, dynamicIslandLyricsSlantRatioSlider, dynamicIslandLyricsSlantRatioValueLabel,
        dynamicIslandLyricsCornerRatioLabel, dynamicIslandLyricsCornerRatioSlider, dynamicIslandLyricsCornerRatioValueLabel,
        dynamicIslandLyricsFontLabel, dynamicIslandLyricsFontPopup,
        dynamicIslandLyricsFontSizeLabel, dynamicIslandLyricsFontSizeSlider, dynamicIslandLyricsFontSizeValueLabel,
        dynamicIslandLyricsAlignmentLabel, dynamicIslandLyricsAlignmentPopup,
        menuBarLyricsWidthLabel, menuBarLyricsWidthSlider, menuBarLyricsWidthValueLabel, menuBarLyricsAlignmentLabel, menuBarLyricsAlignmentPopup,
        desktopLyricsTranslationCheckbox, desktopLyricsLockCheckbox,
        desktopLyricsStyleLabel, desktopLyricsStylePopup,
        desktopLyricsFontLabel, desktopLyricsFontPopup,
        desktopLyricsFontSizeLabel, desktopLyricsFontSizeSlider, desktopLyricsFontSizeValueLabel,
        desktopLyricsTextColorLabel, desktopLyricsTextColorWell,
        desktopLyricsStrokeColorLabel, desktopLyricsStrokeColorWell,
        desktopLyricsStrokeWidthLabel, desktopLyricsStrokeWidthSlider, desktopLyricsStrokeWidthValueLabel,
        musicLyricsWhitelistLabel, musicLyricsWhitelistButton, lyricsSourceLabel,
        whitelistScrollView, whitelistAddButton, whitelistRemoveButton,
        appleMusicTokenStatusLabel, appleMusicLoginButton, appleMusicClearTokenButton
    ]

    private static func appVersionDisplayString() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let shortVersion = (info["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let buildVersion = (info["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (shortVersion?.isEmpty == false ? shortVersion : nil, buildVersion?.isEmpty == false ? buildVersion : nil) {
        case let (.some(version), .some(build)) where build != version:
            return "v\(version) (\(build))"
        case let (.some(version), _):
            return "v\(version)"
        case let (_, .some(build)):
            return "Build \(build)"
        default:
            return ""
        }
    }

    private static func displayName(forDirectoryAt path: String) -> String {
        let directoryURL = path.isEmpty ? defaultScreenshotDirectoryURL() : URL(fileURLWithPath: path, isDirectory: true)
        return directoryURL.path
    }

    private func renderSearchSettings(_ settings: AppSettings) {
        let presetIndex = SearchEnginePreset.presetIndex(for: settings.searchURLTemplate)
        let shouldUseCustom = isSearchTemplateCustom || presetIndex == nil

        if searchTemplateField.currentEditor() == nil && searchTemplateField.stringValue != settings.searchURLTemplate {
            searchTemplateField.stringValue = settings.searchURLTemplate
        }

        isSearchTemplateCustom = shouldUseCustom
        searchEnginePopup.selectItem(at: shouldUseCustom ? SearchEnginePreset.all.count : (presetIndex ?? 0))
        updateSearchTemplateFieldLock(isCustom: isSearchTemplateCustom)
    }

    private func updateSearchTemplateFieldLock(isCustom: Bool) {
        searchTemplateField.isEditable = isCustom
        searchTemplateField.isSelectable = isCustom
        searchTemplateField.textColor = isCustom ? .labelColor : .secondaryLabelColor
        searchTemplateField.backgroundColor = isCustom
            ? .controlBackgroundColor
            : .unemphasizedSelectedContentBackgroundColor
    }

    private func renderScreenshotSettings(_ settings: AppSettings) {
        screenshotSaveButton.title = Self.displayName(forDirectoryAt: settings.screenshotSaveDirectory)
        screenshotSaveButton.toolTip = settings.screenshotSaveDirectory
        screenshotCopyCheckbox.state = settings.screenshotCopiesToClipboard ? .on : .off
        screenshotRegionCheckbox.state = settings.screenshotSelectsRegion ? .on : .off
    }

    private func renderActiveVisionSettings(_ settings: AppSettings) {
        activeVisionGazeCheckbox.state = settings.activeVisionPreventsDisplaySleepOnGaze ? .on : .off
        activeVisionFacingCheckbox.state = settings.activeVisionPreventsDisplaySleepOnFacing ? .on : .off
        activeVisionNotifyCheckbox.state = settings.activeVisionNotifiesWhenExtendingDisplaySleep ? .on : .off
    }

    private func renderDesktopLyricsSettings(_ settings: AppSettings) {
        let hasAppleToken = !settings.appleMusicMediaUserToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let enabledSources = Set(settings.enabledDesktopLyricsSources)
        appleMusicSourceRow.setEnabled(enabledSources.contains(.appleMusic))
        qqMusicSourceRow.setEnabled(enabledSources.contains(.qqMusic))
        neteaseSourceRow.setEnabled(enabledSources.contains(.netease))
        appleMusicTokenStatusLabel.stringValue = hasAppleToken
            ? "Apple Music 已登录"
            : "Apple Music 未登录；QQ 音乐、网易云音乐无需登录。"
        desktopLyricsLanguagePopup.selectItem(at: DesktopLyricsPreferredLanguage.allCases.firstIndex(of: settings.desktopLyricsPreferredLanguage) ?? 0)
        desktopLyricsSurfaceCheckbox.state = settings.isDesktopLyricsSurfaceEnabled ? .on : .off
        dynamicIslandLyricsCheckbox.state = settings.isDynamicIslandLyricsEnabled ? .on : .off
        dynamicIslandLyricsSpectrumCheckbox.state = settings.isDynamicIslandLyricsSpectrumEnabled ? .on : .off
        dynamicIslandLyricsHideOnHoverCheckbox.state = settings.isDynamicIslandLyricsHidesOnHover ? .on : .off
        dynamicIslandLyricsSpectrumCheckbox.isEnabled = settings.isDynamicIslandLyricsEnabled
        dynamicIslandLyricsHideOnHoverCheckbox.isEnabled = settings.isDynamicIslandLyricsEnabled
        desktopLyricsWidthSlider.doubleValue = settings.desktopLyricsWidth
        desktopLyricsWidthValueLabel.stringValue = "\(Int(round(settings.desktopLyricsWidth))) px"
        desktopLyricsAlignmentPopup.selectItem(at: LyricsTextAlignment.allCases.firstIndex(of: settings.desktopLyricsAlignment) ?? 0)
        dynamicIslandLyricsWidthSlider.doubleValue = settings.dynamicIslandLyricsWidth
        dynamicIslandLyricsWidthValueLabel.stringValue = "\(Int(round(settings.dynamicIslandLyricsWidth))) px"
        dynamicIslandLyricsBlankWidthSlider.doubleValue = settings.dynamicIslandLyricsBlankWidth
        dynamicIslandLyricsBlankWidthValueLabel.stringValue = "\(Int(round(settings.dynamicIslandLyricsBlankWidth))) px"
        dynamicIslandLyricsHeightSlider.doubleValue = settings.dynamicIslandLyricsHeight
        dynamicIslandLyricsHeightValueLabel.stringValue = "\(Int(round(settings.dynamicIslandLyricsHeight))) px"
        dynamicIslandLyricsSlantRatioSlider.doubleValue = max(1, min(100, settings.dynamicIslandLyricsSlantRatio * 100))
        dynamicIslandLyricsSlantRatioValueLabel.stringValue = "\(Int(round(dynamicIslandLyricsSlantRatioSlider.doubleValue)))"
        dynamicIslandLyricsCornerRatioSlider.doubleValue = max(1, min(100, settings.dynamicIslandLyricsCornerRatio * 100))
        dynamicIslandLyricsCornerRatioValueLabel.stringValue = "\(Int(round(dynamicIslandLyricsCornerRatioSlider.doubleValue)))"
        dynamicIslandLyricsFontSizeSlider.doubleValue = settings.dynamicIslandLyricsFontSize
        dynamicIslandLyricsFontSizeValueLabel.stringValue = "\(Int(round(settings.dynamicIslandLyricsFontSize)))"
        dynamicIslandLyricsAlignmentPopup.selectItem(at: LyricsTextAlignment.allCases.firstIndex(of: settings.dynamicIslandLyricsAlignment) ?? 0)
        selectFontPopup(dynamicIslandLyricsFontPopup, fontName: settings.dynamicIslandLyricsFontName)
        menuBarLyricsCheckbox.state = settings.isMenuBarLyricsEnabled ? .on : .off
        menuBarLyricsWidthSlider.doubleValue = settings.menuBarLyricsWidth
        menuBarLyricsWidthValueLabel.stringValue = "\(Int(round(settings.menuBarLyricsWidth))) px"
        menuBarLyricsAlignmentPopup.selectItem(at: LyricsTextAlignment.allCases.firstIndex(of: settings.menuBarLyricsAlignment) ?? 0)
        desktopLyricsTranslationCheckbox.state = settings.desktopLyricsShowsTranslation ? .on : .off
        desktopLyricsLockCheckbox.state = settings.desktopLyricsLocked ? .on : .off
        desktopLyricsStylePopup.selectItem(at: DesktopLyricsStylePreset.allCases.firstIndex(of: settings.desktopLyricsStylePreset) ?? 0)
        selectFontPopup(desktopLyricsFontPopup, fontName: settings.desktopLyricsFontName)
        desktopLyricsFontSizeSlider.doubleValue = settings.desktopLyricsFontSize
        desktopLyricsFontSizeValueLabel.stringValue = "\(Int(round(settings.desktopLyricsFontSize)))"
        let styleDefaults = DesktopLyricsUIPresetDefaults(preset: settings.desktopLyricsStylePreset)
        desktopLyricsTextColorWell.color = NSColor(hexString: settings.desktopLyricsTextColor) ?? styleDefaults.textColor
        desktopLyricsStrokeColorWell.color = NSColor(hexString: settings.desktopLyricsStrokeColor) ?? styleDefaults.strokeColor
        let strokeWidth = settings.desktopLyricsStrokeWidth >= 0 ? settings.desktopLyricsStrokeWidth : styleDefaults.strokeWidth
        desktopLyricsStrokeWidthSlider.doubleValue = strokeWidth
        desktopLyricsStrokeWidthValueLabel.stringValue = String(format: "%.1f", strokeWidth)
        renderWhitelist(settings.musicLyricsAppWhitelist)
        appleMusicClearTokenButton.isEnabled = hasAppleToken
    }

    /// 字体弹窗选中回显（灵动岛/桌面歌词共用）：
    /// 空名 → 系统默认；字体已卸载/名称不匹配时同样回退到系统默认。
    private func selectFontPopup(_ popup: NSPopUpButton, fontName: String) {
        if !fontName.isEmpty, popup.item(withTitle: fontName) != nil {
            popup.selectItem(withTitle: fontName)
        } else {
            popup.selectItem(withTitle: "系统默认")
        }
    }

    private func renderWhitelist(_ rawValue: String) {
        lastRenderedWhitelistRawValue = rawValue
        if availableApplications.isEmpty {
            // 应用目录枚举在后台执行：首次渲染先用空缓存，枚举完成后按同一 rawValue 重渲染。
            refreshAvailableApplications(reRenderWhitelistWhenDone: true)
        }
        if rawValue == musicLyricsAppWhitelistEmptySentinel {
            whitelistApplications = []
        } else if rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            whitelistApplications = defaultWhitelistApplications()
        } else {
            whitelistApplications = parsedWhitelistEntries(rawValue)
        }
        whitelistTableView.reloadData()
        if !whitelistApplications.indices.contains(whitelistTableView.selectedRow) {
            whitelistTableView.deselectAll(nil)
        }
        updateWhitelistTableLayout()
    }

    private func parsedWhitelistEntries(_ rawValue: String) -> [ApplicationChoice] {
        let ids = Set(rawValue
            .components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != musicLyricsAppWhitelistEmptySentinel })
        return availableApplications
            .filter { ids.contains($0.bundleIdentifier) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func defaultWhitelistApplications() -> [ApplicationChoice] {
        availableApplications
            .filter {
                let value = "\($0.displayName) \($0.bundleIdentifier)".lowercased()
                return value.contains("music") || value.contains("音乐")
            }
    }
}

@MainActor
private final class WhitelistTableView: NSTableView {
    var contentTrailingSafeInset: CGFloat = 0 {
        didSet {
            guard abs(contentTrailingSafeInset - oldValue) > 0.5 else { return }
            setNeedsDisplay(bounds)
            let visibleRows = rows(in: visibleRect)
            guard visibleRows.length > 0 else { return }
            for row in visibleRows.location..<(visibleRows.location + visibleRows.length) {
                view(atColumn: 0, row: row, makeIfNecessary: false)?.needsLayout = true
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0 {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }
}

@MainActor
private final class WhitelistApplicationCell: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(titleLabel)
        addSubview(subtitleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(title: String, subtitle: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        // 选中高亮由 WhitelistApplicationRowView.drawCustomSelectionIfNeeded 承担，
        // 文字颜色恒定，无需随选中态变化。
        titleLabel.textColor = .labelColor
        subtitleLabel.textColor = .secondaryLabelColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let insetX: CGFloat = 22
        let overlaySafeInset = (superview as? WhitelistTableView)?.contentTrailingSafeInset ?? 0
        let trailingInset: CGFloat = 22 + overlaySafeInset
        let titleHeight: CGFloat = 20
        let subtitleHeight: CGFloat = 16
        let verticalGap: CGFloat = 3
        let totalHeight = titleHeight + verticalGap + subtitleHeight
        let subtitleY = max(9, floor((bounds.height - totalHeight) / 2))
        let textWidth = max(0, bounds.width - insetX - trailingInset)
        subtitleLabel.frame = NSRect(x: insetX, y: subtitleY, width: textWidth, height: subtitleHeight)
        titleLabel.frame = NSRect(x: insetX, y: subtitleLabel.frame.maxY + verticalGap, width: textWidth, height: titleHeight)
    }
}

@MainActor
private final class WhitelistApplicationRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    override var isEmphasized: Bool {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        drawCustomSelectionIfNeeded()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        drawCustomSelectionIfNeeded()
    }

    private func drawCustomSelectionIfNeeded() {
        guard isSelected else { return }

        let tableView = superview as? WhitelistTableView
        let clipWidth = tableView?.enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let overlaySafeInset = tableView?.contentTrailingSafeInset ?? 0
        let selectionX: CGFloat = 12
        let selectionTrailingInset: CGFloat = 22 + overlaySafeInset
        let availableWidth = min(bounds.width, clipWidth)
        let selectionWidth = max(0, availableWidth - selectionX - selectionTrailingInset)
        let selectionRect = NSRect(
            x: selectionX,
            y: 6,
            width: selectionWidth,
            height: max(0, bounds.height - 12)
        )

        NSColor.controlAccentColor.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: selectionRect, xRadius: 11, yRadius: 11).fill()
    }
}

private struct DesktopLyricsUIPresetDefaults {
    let textColor: NSColor
    let strokeColor: NSColor
    let strokeWidth: Double

    init(preset: DesktopLyricsStylePreset) {
        switch preset {
        case .classic:
            textColor = .white
            strokeColor = NSColor.black.withAlphaComponent(0.55)
            strokeWidth = 0.8
        case .softShadow:
            textColor = NSColor(calibratedWhite: 0.98, alpha: 1)
            strokeColor = NSColor.black.withAlphaComponent(0.36)
            strokeWidth = 0.35
        case .darkPanel:
            textColor = NSColor(calibratedWhite: 0.98, alpha: 1)
            strokeColor = NSColor.black.withAlphaComponent(0.24)
            strokeWidth = 0
        case .lightPanel:
            textColor = NSColor(calibratedWhite: 0.1, alpha: 1)
            strokeColor = NSColor.white.withAlphaComponent(0.4)
            strokeWidth = 0
        case .neon:
            textColor = NSColor(calibratedRed: 0.78, green: 0.96, blue: 1.0, alpha: 1)
            strokeColor = NSColor.black.withAlphaComponent(0.5)
            strokeWidth = 0.6
        }
    }
}

extension NSColor {
    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        let red = Int(round(color.redComponent * 255))
        let green = Int(round(color.greenComponent * 255))
        let blue = Int(round(color.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    convenience init?(hexString: String) {
        let value = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespacesAndNewlines))
        guard value.count == 6, let number = Int(value, radix: 16) else { return nil }
        self.init(
            calibratedRed: CGFloat((number >> 16) & 0xff) / 255,
            green: CGFloat((number >> 8) & 0xff) / 255,
            blue: CGFloat(number & 0xff) / 255,
            alpha: 1
        )
    }
}

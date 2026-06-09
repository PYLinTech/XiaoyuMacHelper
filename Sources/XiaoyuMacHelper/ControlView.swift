import AppKit

@MainActor
final class ControlView: NSView, NSTextFieldDelegate {
    private enum Page {
        case modules
        case capsLockSettings
        case selectionToolbarSettings
        case activeVisionSettings
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
    }

    private var page: Page = .modules
    private var selectionToolbarOrder = ToolbarAction.configurableCases
    private var isAccessibilityEnabledForDisplay = false
    private var isSearchTemplateCustom = false

    private let glassContainer = NSGlassEffectContainerView()
    private let glassContentView = NSView()
    private let titleLabel = NSTextField(labelWithString: "Xiaoyu MacHelper")
    private let toolOptionsTitle = NSTextField(labelWithString: "工具选项")
    private let moduleTitle = NSTextField(labelWithString: "功能模块")
    private let settingsTitle = NSTextField(labelWithString: "")
    private let toolOptionsCard = NSGlassEffectView()
    private let moduleCard = NSGlassEffectView()
    private let settingsCard = NSGlassEffectView()
    private let loginItemCheckbox = NSButton(checkboxWithTitle: "开启自启动", target: nil, action: nil)
    private let accessibilityCheckbox = NSButton(checkboxWithTitle: "开启辅助功能", target: nil, action: nil)
    private let capsLockCheckbox = NSButton(checkboxWithTitle: "大写指示器", target: nil, action: nil)
    private let selectionToolbarCheckbox = NSButton(checkboxWithTitle: "选区工具栏", target: nil, action: nil)
    private let activeVisionCheckbox = NSButton(checkboxWithTitle: "主动视觉感知", target: nil, action: nil)
    private let clickToDisableCheckbox = NSButton(checkboxWithTitle: "点击指示器取消大写", target: nil, action: nil)
    private let capsLockSettingsButton = IconButtonView(systemSymbolName: "gearshape", accessibilityDescription: "设置", backgroundStyle: .plain, tintColor: .secondaryLabelColor)
    private let selectionToolbarSettingsButton = IconButtonView(systemSymbolName: "gearshape", accessibilityDescription: "设置", backgroundStyle: .plain, tintColor: .secondaryLabelColor)
    private let activeVisionSettingsButton = IconButtonView(systemSymbolName: "gearshape", accessibilityDescription: "设置", backgroundStyle: .plain, tintColor: .secondaryLabelColor)
    private let backButton = IconButtonView(systemSymbolName: "chevron.left", accessibilityDescription: "返回", backgroundStyle: .glass)
    private let loginItemButton = NSButton(title: "前往设置启动项", target: nil, action: nil)
    private let accessibilityButton = NSButton(title: "前往设置辅助功能", target: nil, action: nil)
    private let clearDataAndQuitButton = NSButton(title: "清空应用数据并退出", target: nil, action: nil)
    private let quitButton = NSButton(title: "退出", target: nil, action: nil)
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

    var onCapsLockIndicatorChanged: ((Bool) -> Void)?
    var onClickToDisableChanged: ((Bool) -> Void)?
    var onSelectionToolbarChanged: ((Bool) -> Void)?
    var onActiveVisionChanged: ((Bool) -> Void)?
    var onSelectionToolbarActionChanged: ((ToolbarAction, Bool) -> Void)?
    var onSelectionToolbarActionMoved: ((ToolbarAction, Int) -> Void)?
    var onSearchTemplateChanged: ((String) -> Void)?
    var onScreenshotSaveDirectoryChanged: ((String) -> Void)?
    var onScreenshotCopiesToClipboardChanged: ((Bool) -> Void)?
    var onScreenshotSelectsRegionChanged: ((Bool) -> Void)?
    var onActiveVisionGazeChanged: ((Bool) -> Void)?
    var onActiveVisionFacingChanged: ((Bool) -> Void)?
    var onActiveVisionNotifyChanged: ((Bool) -> Void)?
    var onLoginItemChanged: ((Bool) -> Void)?
    var onLoginItemGuide: (() -> Void)?
    var onAccessibilityEnableRequested: (() -> Void)?
    var onAccessibilityDisableRequested: (() -> Void)?
    var onAccessibilityGuide: (() -> Void)?
    var onClearDataAndQuit: (() -> Void)?
    var onQuit: (() -> Void)?

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
        isAccessibilityEnabledForDisplay = isAccessibilityEnabled
        loginItemCheckbox.state = isLoginItemEnabled ? .on : .off
        accessibilityCheckbox.state = isAccessibilityEnabled ? .on : .off
        capsLockCheckbox.state = settings.isCapsLockIndicatorEnabled ? .on : .off
        selectionToolbarCheckbox.state = settings.isSelectionToolbarEnabled ? .on : .off
        activeVisionCheckbox.state = settings.isActiveVisionEnabled ? .on : .off
        clickToDisableCheckbox.state = settings.isClickToDisableEnabled ? .on : .off
        copyRow.setEnabled(settings.isSelectionToolbarCopyEnabled)
        pasteRow.setEnabled(settings.isSelectionToolbarPasteEnabled)
        searchRow.setEnabled(settings.isSelectionToolbarSearchEnabled)
        screenshotRow.setEnabled(settings.isSelectionToolbarScreenshotEnabled)
        renderSearchSettings(settings)
        renderScreenshotSettings(settings)
        renderActiveVisionSettings(settings)
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
        configureCheckbox(clickToDisableCheckbox, size: 14, weight: .regular, action: #selector(clickToDisableCheckboxChanged))

        [capsLockSettingsButton, selectionToolbarSettingsButton, activeVisionSettingsButton, backButton].forEach { addSubview($0) }
        capsLockSettingsButton.onClick = { [weak self] in self?.showCapsLockSettingsPage() }
        selectionToolbarSettingsButton.onClick = { [weak self] in self?.showSelectionToolbarSettingsPage() }
        activeVisionSettingsButton.onClick = { [weak self] in self?.showActiveVisionSettingsPage() }
        backButton.onClick = { [weak self] in self?.backButtonClicked() }

        [loginItemButton, accessibilityButton, clearDataAndQuitButton, quitButton].forEach {
            $0.bezelStyle = .glass
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

        [copyRow, pasteRow, searchRow, screenshotRow].forEach { row in
            row.onToggle = { [weak self] action, isEnabled in self?.onSelectionToolbarActionChanged?(action, isEnabled) }
            row.onMove = { [weak self] action, direction in self?.onSelectionToolbarActionMoved?(action, direction) }
            addSubview(row)
        }
        searchRow.onSettings = { [weak self] _ in self?.showSearchSettingsPage() }
        screenshotRow.onSettings = { [weak self] _ in self?.showScreenshotSettingsPage() }

        searchEnginePopup.addItems(withTitles: SearchEnginePreset.all.map(\.title) + [SearchEnginePreset.customTitle])
        searchEnginePopup.bezelStyle = .glass
        searchEnginePopup.target = self
        searchEnginePopup.action = #selector(searchEngineSelected)
        addSubview(searchEnginePopup)

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
        addSubview(searchTemplateField)

        screenshotSaveLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        screenshotSaveLabel.textColor = .labelColor
        addSubview(screenshotSaveLabel)

        screenshotSaveButton.bezelStyle = .glass
        screenshotSaveButton.alignment = .left
        screenshotSaveButton.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        screenshotSaveButton.target = self
        screenshotSaveButton.action = #selector(screenshotSaveDirectoryClicked)
        addSubview(screenshotSaveButton)

        configureCheckbox(screenshotCopyCheckbox, size: 13, weight: .regular, action: #selector(screenshotCopyCheckboxChanged))
        configureCheckbox(screenshotRegionCheckbox, size: 13, weight: .regular, action: #selector(screenshotRegionCheckboxChanged))
        configureCheckbox(activeVisionGazeCheckbox, size: 13, weight: .regular, action: #selector(activeVisionGazeCheckboxChanged))
        configureCheckbox(activeVisionFacingCheckbox, size: 13, weight: .regular, action: #selector(activeVisionFacingCheckboxChanged))
        configureCheckbox(activeVisionNotifyCheckbox, size: 13, weight: .regular, action: #selector(activeVisionNotifyCheckboxChanged))

        showModulesPage()
    }

    private func configureCheckbox(_ checkbox: NSButton, size: CGFloat, weight: NSFont.Weight, action: Selector) {
        checkbox.font = NSFont.systemFont(ofSize: size, weight: weight)
        checkbox.target = self
        checkbox.action = action
        addSubview(checkbox)
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

    @objc private func activeVisionCheckboxChanged() {
        onActiveVisionChanged?(activeVisionCheckbox.state == .on)
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

    @objc private func backButtonClicked() {
        if page == .searchSettings || page == .screenshotSettings {
            showSelectionToolbarSettingsPage()
        } else {
            showModulesPage()
        }
    }

    @objc private func showModulesPage() {
        page = .modules
        layoutForCurrentPage()
    }

    @objc private func showCapsLockSettingsPage() {
        page = .capsLockSettings
        layoutForCurrentPage()
    }

    @objc private func showSelectionToolbarSettingsPage() {
        page = .selectionToolbarSettings
        layoutForCurrentPage()
    }

    @objc private func showActiveVisionSettingsPage() {
        page = .activeVisionSettings
        layoutForCurrentPage()
    }

    private func showSearchSettingsPage() {
        page = .searchSettings
        layoutForCurrentPage()
    }

    private func showScreenshotSettingsPage() {
        page = .screenshotSettings
        layoutForCurrentPage()
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
        guard notification.object as? NSTextField === searchTemplateField else { return }
        commitSearchTemplate()
    }

    private func commitSearchTemplate() {
        onSearchTemplateChanged?(searchTemplateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
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

    private func layoutForCurrentPage() {
        glassContainer.frame = bounds
        glassContentView.frame = bounds

        switch page {
        case .modules:
            layoutModulesPage()
        case .capsLockSettings:
            layoutSettingsBase(title: "大写指示器")
            clickToDisableCheckbox.isHidden = false
            clickToDisableCheckbox.sizeToFit()
            clickToDisableCheckbox.frame.origin = NSPoint(
                x: settingsCard.frame.minX + Metrics.sectionInset,
                y: settingsCard.frame.maxY - Metrics.sectionInset - clickToDisableCheckbox.frame.height
            )
        case .selectionToolbarSettings:
            layoutSettingsBase(title: "选区工具栏")
            let rows = selectionToolbarOrder.map { row(for: $0) }
            for (index, row) in rows.enumerated() {
                row.isHidden = false
                row.frame = NSRect(
                    x: settingsCard.frame.minX + Metrics.sectionInset,
                    y: settingsCard.frame.maxY - Metrics.sectionInset - Metrics.rowHeight - CGFloat(index) * Metrics.rowHeight,
                    width: settingsCard.frame.width - Metrics.sectionInset * 2,
                    height: Metrics.rowHeight
                )
            }
        case .activeVisionSettings:
            layoutActiveVisionSettingsPage()
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
            titleLabel, toolOptionsTitle, toolOptionsCard, loginItemCheckbox, accessibilityCheckbox,
            moduleTitle, moduleCard, capsLockCheckbox, selectionToolbarCheckbox, activeVisionCheckbox,
            capsLockSettingsButton, selectionToolbarSettingsButton, activeVisionSettingsButton, loginItemButton, accessibilityButton,
            clearDataAndQuitButton, quitButton
        )

        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(
            x: contentX,
            y: height - Metrics.titleTopInset - titleLabel.frame.height
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
        case .copy: return copyRow
        case .paste: return pasteRow
        case .search: return searchRow
        case .screenshot: return screenshotRow
        }
    }

    private func layoutSearchSettingsPage() {
        layoutSettingsBase(title: "搜索")
        show(searchEnginePopup, searchTemplateField)

        let contentX = settingsCard.frame.minX + Metrics.sectionInset
        let contentWidth = settingsCard.frame.width - Metrics.sectionInset * 2
        searchEnginePopup.frame = NSRect(
            x: contentX,
            y: settingsCard.frame.maxY - Metrics.sectionInset - 34,
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

        let contentX = settingsCard.frame.minX + Metrics.sectionInset
        let contentWidth = settingsCard.frame.width - Metrics.sectionInset * 2
        screenshotSaveLabel.sizeToFit()
        screenshotSaveLabel.frame.origin = NSPoint(
            x: contentX,
            y: settingsCard.frame.maxY - Metrics.sectionInset - screenshotSaveLabel.frame.height
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

    private func layoutActiveVisionSettingsPage() {
        layoutSettingsBase(title: "主动视觉感知")
        show(activeVisionGazeCheckbox, activeVisionFacingCheckbox, activeVisionNotifyCheckbox)

        let contentX = settingsCard.frame.minX + Metrics.sectionInset
        activeVisionGazeCheckbox.sizeToFit()
        activeVisionGazeCheckbox.frame.origin = NSPoint(
            x: contentX,
            y: settingsCard.frame.maxY - Metrics.sectionInset - activeVisionGazeCheckbox.frame.height
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
        show(settingsTitle, settingsCard, backButton)

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
        titleLabel, toolOptionsTitle, moduleTitle, settingsTitle, toolOptionsCard, moduleCard, settingsCard,
        loginItemCheckbox, accessibilityCheckbox, capsLockCheckbox, selectionToolbarCheckbox, activeVisionCheckbox, clickToDisableCheckbox,
        capsLockSettingsButton, selectionToolbarSettingsButton, activeVisionSettingsButton, backButton,
        loginItemButton, accessibilityButton, clearDataAndQuitButton, quitButton, copyRow, pasteRow, searchRow, screenshotRow,
        searchEnginePopup, searchTemplateField, screenshotSaveLabel, screenshotSaveButton, screenshotCopyCheckbox,
        screenshotRegionCheckbox, activeVisionGazeCheckbox, activeVisionFacingCheckbox, activeVisionNotifyCheckbox
    ]

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
}


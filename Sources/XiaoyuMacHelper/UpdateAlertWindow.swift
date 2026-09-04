import AppKit

/// 自绘更新弹窗：替代系统 NSAlert，承载"发现新版本"确认与"下载/校验/安装"进度两个阶段。
///
/// 布局（自上而下）：
/// ① 程序图标 + "v1.1.5 更新日志：" 标题；
/// ② 限高可滚动的更新日志区；
/// ③ "当前 v1.1.3 → 最新 v1.1.5 是否更新？" 版本对比行；
/// ④ [稍后] [立即更新] 按钮。
/// 点击"立即更新"后进入安装模式：隐藏 ②③④，显示进度条 + 状态文字。
@MainActor
final class UpdateAlertWindow: NSWindow {
    var onInstall: (() -> Void)?
    var onLater: (() -> Void)?

    private enum Metrics {
        static let windowWidth: CGFloat = 520
        static let windowHeight: CGFloat = 332
        static let padding: CGFloat = 24
        static let buttonHeight: CGFloat = 32
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let latestVersionDescription: String
    private let logScrollView = NSScrollView(frame: .zero)
    private let logTextView = NSTextView(frame: .zero)
    private let versionLabel = NSTextField(labelWithString: "")
    private let laterButton = NSButton(title: "稍后", target: nil, action: nil)
    private let installButton = NSButton(title: "立即更新", target: nil, action: nil)
    private let progressIndicator = NSProgressIndicator(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")

    init(currentVersion: Version, latestVersion: Version, notes: String) {
        latestVersionDescription = latestVersion.description
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.windowWidth, height: Metrics.windowHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "软件更新"
        isReleasedWhenClosed = false
        setupViews(latestVersion: latestVersion, notes: notes)
        layoutPromptMode(currentVersion: currentVersion, latestVersion: latestVersion)
    }

    func show() {
        center()
        makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    override func close() {
        // 安装中不允许关闭（进度不可见会让人误以为卡死）；"稍后"或红点走 onLater。
        guard !isInstalling else { return }
        onLater?()
        super.close()
    }

    /// 失败/异常路径强制关闭（不触发 onLater，App 层自行接管兜底）。
    func forceClose() {
        isInstalling = false
        super.close()
    }

    // MARK: - 安装进度

    private var isInstalling = false

    /// 进入安装模式：隐藏确认区，显示进度条与状态文字。
    func enterInstallingMode() {
        isInstalling = true
        titleLabel.stringValue = "正在更新到 v\(latestVersionDescription)…"
        titleLabel.isHidden = false
        logScrollView.isHidden = true
        versionLabel.isHidden = true
        laterButton.isHidden = true
        installButton.isHidden = true
        progressIndicator.isHidden = false
        statusLabel.isHidden = false
        layoutInstallingMode()
        setStatus("正在下载更新包…")
        setProgress(0)
    }

    /// 下载进度 0...1，状态文字同步百分比。
    func setProgress(_ fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        progressIndicator.doubleValue = clamped
        if clamped < 1 {
            setStatus("正在下载更新包… \(Int(clamped * 100))%")
        }
    }

    /// 更新状态文字（下载/校验/安装阶段说明）。
    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    // MARK: - 视图搭建

    private func setupViews(latestVersion: Version, notes: String) {
        contentView?.wantsLayer = true

        iconView.image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        contentView?.addSubview(iconView)

        titleLabel.stringValue = "v\(latestVersion.description) 更新日志："
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        contentView?.addSubview(titleLabel)

        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.isRichText = false
        logTextView.drawsBackground = false
        logTextView.font = NSFont.systemFont(ofSize: 12)
        logTextView.textColor = .secondaryLabelColor
        logTextView.textContainerInset = NSSize(width: 10, height: 8)
        logTextView.textContainer?.widthTracksTextView = true
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        logTextView.autoresizingMask = [.width]
        logTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        logScrollView.wantsLayer = true
        logScrollView.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        logScrollView.layer?.cornerRadius = 10
        logScrollView.layer?.masksToBounds = true
        logScrollView.documentView = logTextView
        logScrollView.hasVerticalScroller = true
        logScrollView.autohidesScrollers = true
        logScrollView.drawsBackground = false
        logScrollView.borderType = .noBorder
        contentView?.addSubview(logScrollView)

        versionLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        versionLabel.textColor = .secondaryLabelColor
        contentView?.addSubview(versionLabel)

        configureButton(laterButton, action: #selector(laterClicked))
        configureButton(installButton, action: #selector(installClicked))
        installButton.keyEquivalent = "\r"

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        progressIndicator.isHidden = true
        contentView?.addSubview(progressIndicator)

        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true
        contentView?.addSubview(statusLabel)

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        logTextView.string = trimmedNotes.isEmpty ? "暂无更新说明。" : trimmedNotes
        logTextView.textColor = .secondaryLabelColor
    }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .liquidGlass
        button.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        button.target = self
        button.action = action
        contentView?.addSubview(button)
    }

    @objc private func laterClicked() {
        close()
    }

    @objc private func installClicked() {
        onInstall?()
    }

    private func scrollViewFrame() -> NSRect {
        let width = Metrics.windowWidth
        let padding = Metrics.padding
        let buttonHeight = Metrics.buttonHeight
        let buttonY = padding
        let versionHeight: CGFloat = 20
        let versionY = buttonY + buttonHeight + 14
        let logHeight: CGFloat = 150
        let logY = versionY + versionHeight + 12
        return NSRect(
            x: padding,
            y: logY,
            width: width - padding * 2,
            height: logHeight
        )
    }

    private func layoutPromptMode(currentVersion: Version, latestVersion: Version) {
        let width = Metrics.windowWidth
        let padding = Metrics.padding

        let logFrame = scrollViewFrame()
        let iconSize: CGFloat = 48
        let iconY = logFrame.maxY + 12
        iconView.frame = NSRect(x: padding, y: iconY, width: iconSize, height: iconSize)

        let titleX = padding + iconSize + 14
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.sizeToFit()
        titleLabel.frame = NSRect(
            x: titleX,
            y: iconY + (iconSize - titleLabel.frame.height) / 2,
            width: width - titleX - padding,
            height: titleLabel.frame.height
        )

        logScrollView.frame = logFrame
        logTextView.frame = NSRect(x: 0, y: 0, width: logFrame.width, height: logFrame.height)
        logTextView.textContainer?.containerSize = NSSize(width: logFrame.width, height: .greatestFiniteMagnitude)
        // 立即按最终容器宽度完成文本布局，textView 高度随之增长，过长日志才能正确出现滚动条。
        if let container = logTextView.textContainer {
            logTextView.layoutManager?.ensureLayout(for: container)
        }

        let versionHeight: CGFloat = 20
        let versionY = logFrame.minY - versionHeight - 12
        let arrow = "\u{2192}"
        versionLabel.stringValue = "当前 v\(currentVersion.description) \(arrow) 最新 v\(latestVersion.description) 是否更新？"
        versionLabel.sizeToFit()
        versionLabel.frame = NSRect(
            x: padding,
            y: versionY,
            width: width - padding * 2,
            height: versionHeight
        )

        let buttonY = padding
        let installWidth: CGFloat = 110
        let laterWidth: CGFloat = 70
        let gap: CGFloat = 12
        installButton.frame = NSRect(
            x: width - padding - installWidth,
            y: buttonY,
            width: installWidth,
            height: Metrics.buttonHeight
        )
        laterButton.frame = NSRect(
            x: installButton.frame.minX - gap - laterWidth,
            y: buttonY,
            width: laterWidth,
            height: Metrics.buttonHeight
        )
    }

    private func layoutInstallingMode() {
        let width = Metrics.windowWidth
        let height = Metrics.windowHeight
        let padding = Metrics.padding

        let iconSize: CGFloat = 48
        let titleX = padding + iconSize + 14
        iconView.frame = NSRect(x: padding, y: height - padding - iconSize, width: iconSize, height: iconSize)
        titleLabel.sizeToFit()
        titleLabel.frame = NSRect(
            x: titleX,
            y: height - padding - iconSize + (iconSize - titleLabel.frame.height) / 2,
            width: width - titleX - padding,
            height: titleLabel.frame.height
        )

        let indicatorY: CGFloat = height / 2 + 6
        progressIndicator.frame = NSRect(x: padding + 24, y: indicatorY, width: width - (padding + 24) * 2, height: 14)
        // 状态文字固定行高：layoutInstallingMode 早于首次 setStatus 执行，若按空串 sizeToFit 会得到 0 高度导致文字被裁切。
        let statusHeight: CGFloat = 18
        statusLabel.frame = NSRect(
            x: padding,
            y: indicatorY - statusHeight - 10,
            width: width - padding * 2,
            height: statusHeight
        )
        statusLabel.alignment = .center
    }
}

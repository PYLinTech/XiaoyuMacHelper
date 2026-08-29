import AppKit
import WebKit

@MainActor
final class AppleMusicTokenLoginWindow: NSWindow, WKNavigationDelegate {
    private let webView = WKWebView(frame: .zero)
    private let instructionLabel = NSTextField(labelWithString: "请在网页中登录 Apple Music。登录完成后，本窗口会自动提取 media-user-token 并保存到本机。")
    private let checkButton = NSButton(title: "我已登录，立即检测", target: nil, action: nil)
    private let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 680))
    private var tokenCheckTimer: Timer?

    var onTokenCaptured: ((String) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        title = "Apple Music 登录"
        isReleasedWhenClosed = false
        center()
        setupViews()
        layoutContent()
        loadAppleMusic()
    }

    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startTokenChecking()
    }

    override func close() {
        tokenCheckTimer?.invalidate()
        tokenCheckTimer = nil
        super.close()
    }

    private func setupViews() {
        containerView.autoresizingMask = [.width, .height]
        contentView = containerView

        instructionLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        instructionLabel.textColor = .secondaryLabelColor
        instructionLabel.lineBreakMode = .byWordWrapping
        instructionLabel.maximumNumberOfLines = 2
        containerView.addSubview(instructionLabel)

        checkButton.bezelStyle = .liquidGlass
        checkButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        checkButton.target = self
        checkButton.action = #selector(checkTokenNow)
        containerView.addSubview(checkButton)

        webView.navigationDelegate = self
        webView.customUserAgent = LyricsNetwork.userAgent
        containerView.addSubview(webView)
    }


    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        layoutContent()
    }

    private func layoutContent() {
        guard let contentView else { return }
        let bounds = contentView.bounds
        let inset: CGFloat = 16
        let headerHeight: CGFloat = 58
        instructionLabel.frame = NSRect(x: inset, y: bounds.height - headerHeight + 12, width: bounds.width - 200 - inset * 2, height: 34)
        checkButton.frame = NSRect(x: bounds.width - inset - 170, y: bounds.height - 44, width: 170, height: 30)
        webView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - headerHeight)
    }

    private func loadAppleMusic() {
        guard let url = URL(string: "https://music.apple.com/us/browse") else { return }
        webView.load(URLRequest(url: url))
    }

    private func startTokenChecking() {
        guard tokenCheckTimer == nil else { return }
        tokenCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.captureTokenIfPossible()
            }
        }
    }

    @objc private func checkTokenNow() {
        captureTokenIfPossible()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.captureTokenIfPossible()
        }
    }

    private func captureTokenIfPossible() {
        let script = """
        (() => {
            const results = [];
            const collect = (name, store) => {
                try {
                    for (let i = 0; i < store.length; i++) {
                        const key = store.key(i);
                        const value = store.getItem(key) || '';
                        const joined = `${key} ${value}`.toLowerCase();
                        if (joined.includes('media-user-token') || joined.includes('mediausertoken') || joined.includes('ampwebplayback')) {
                            results.push({ source: name, key, value });
                        }
                        try {
                            const parsed = JSON.parse(value);
                            const walk = (prefix, node) => {
                                if (!node) return;
                                if (typeof node === 'string') {
                                    const needle = `${prefix} ${node}`.toLowerCase();
                                    if (needle.includes('media-user-token') || needle.includes('mediausertoken') || needle.includes('ampwebplayback')) {
                                        results.push({ source: name, key: `${key}.${prefix}`, value: node });
                                    }
                                    return;
                                }
                                if (typeof node === 'object') {
                                    Object.keys(node).forEach(childKey => walk(`${prefix}.${childKey}`, node[childKey]));
                                }
                            };
                            walk(key, parsed);
                        } catch (e) {}
                    }
                } catch (e) {}
            };
            collect('localStorage', window.localStorage);
            collect('sessionStorage', window.sessionStorage);
            const cookieMatch = document.cookie.match(/(?:^|;\\s*)media-user-token=([^;]+)/i);
            if (cookieMatch) results.push({ source: 'cookie', key: 'media-user-token', value: decodeURIComponent(cookieMatch[1]) });
            return JSON.stringify(results);
        })();
        """

        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self, let text = value as? String,
                  let data = text.data(using: .utf8),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return
            }

            let token = items
                .compactMap { $0["value"] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { $0.count > 40 && !$0.contains("{") && !$0.contains("}") }

            guard let token, !token.isEmpty else { return }
            self.tokenCheckTimer?.invalidate()
            self.tokenCheckTimer = nil
            self.onTokenCaptured?(token)
            self.close()
        }
    }
}

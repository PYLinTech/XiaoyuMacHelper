import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Darwin
import IOKit
import IOKit.hidsystem
import ScreenCaptureKit
import ServiceManagement

@MainActor
final class CapsLockWindow: GlassTextWindow {
    private enum Metrics {
        static let bottomInset: CGFloat = 36
    }

    var onClick: (() -> Void)?

    init() {
        super.init(
            configuration: Configuration(
                height: 36,
                horizontalPadding: 22,
                minWidth: 92,
                maxWidth: nil,
                font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                cornerRadius: 18
            ),
            initialMessage: "大写"
        )

        content.onClick = { [weak self] in
            self?.onClick?()
        }
    }

    func showAtBottomCenter() {
        let size = fittingSize(for: "大写")
        setFrame(NSRect(origin: .zero, size: size), display: false)
        setFrameOrigin(bottomCenterOrigin(size: size, bottomInset: Metrics.bottomInset))
        orderFrontRegardless()
    }
}


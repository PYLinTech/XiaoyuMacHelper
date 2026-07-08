import AppKit
import Carbon
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class SelectionToolbarController {
    private enum Metrics {
        static let dragThresholdSquared: CGFloat = 36
        static let showDelay: TimeInterval = 0.08
        static let shortcutDelay: TimeInterval = 0.06
        static let searchReadDelay: TimeInterval = 0.22
    }

    private static var unsupportedSearchPasteboardTypes: [NSPasteboard.PasteboardType] {
        [
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            NSPasteboard.PasteboardType("public.tiff"),
            NSPasteboard.PasteboardType("public.png"),
            NSPasteboard.PasteboardType("com.adobe.pdf")
        ]
    }

    private let toolbarWindow = SelectionToolbarWindow()
    private let toastWindow = ToastWindow()
    private lazy var screenshotSelectionWindow = ScreenshotSelectionWindow()
    private var eventMonitor: Any?
    private var currentSettings: AppSettings
    private var mouseDownLocation: NSPoint?
    private var selectionRect: CGRect?
    private var selectionTargetPID: pid_t?
    private var pendingShow: DispatchWorkItem?

    private var isEnabled: Bool {
        currentSettings.isSelectionToolbarEnabled && !currentSettings.visibleSelectionToolbarActions.isEmpty
    }

    init(settings: AppSettings) {
        currentSettings = settings
        toolbarWindow.onAction = { [weak self] action in
            self?.perform(action)
        }
    }

    func start() {
        syncEventMonitor()
    }

    func update(settings: AppSettings) {
        currentSettings = settings
        syncEventMonitor()
        if !isEnabled {
            reset(shouldHideToolbar: true, clearTarget: true)
        }
    }

    func stop() {
        reset(shouldHideToolbar: true, clearTarget: true)
        removeEventMonitor(&eventMonitor)
    }

    private func syncEventMonitor() {
        if isEnabled, eventMonitor == nil {
            eventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]
            ) { [weak self] event in
                DispatchQueue.main.async { self?.handle(event) }
            }
        } else if !isEnabled {
            removeEventMonitor(&eventMonitor)
        }
    }

    private func handle(_ event: NSEvent) {
        guard isEnabled else {
            reset(shouldHideToolbar: true, clearTarget: true)
            return
        }

        switch event.type {
        case .leftMouseDown:
            startSelectionTracking()
        case .leftMouseUp:
            finishSelectionTracking()
        case .rightMouseDown:
            reset(shouldHideToolbar: true, clearTarget: true)
        default:
            break
        }
    }

    private func startSelectionTracking() {
        reset(shouldHideToolbar: true, clearTarget: false)
        mouseDownLocation = NSEvent.mouseLocation
        selectionTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func finishSelectionTracking() {
        let point = NSEvent.mouseLocation
        guard let rect = dragSelectionRect(endingAt: point) else {
            reset(shouldHideToolbar: true, clearTarget: true)
            return
        }

        selectionRect = rect
        mouseDownLocation = nil
        showToolbarSoon(near: point)
    }

    private func dragSelectionRect(endingAt point: NSPoint) -> CGRect? {
        guard let start = mouseDownLocation else {
            return nil
        }

        let dx = point.x - start.x
        let dy = point.y - start.y
        guard dx * dx + dy * dy >= Metrics.dragThresholdSquared else {
            return nil
        }

        return CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(dx),
            height: abs(dy)
        )
    }

    private func showToolbarSoon(near point: NSPoint) {
        pendingShow?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.showToolbar(near: point)
        }
        pendingShow = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.showDelay, execute: workItem)
    }

    private func showToolbar(near point: NSPoint) {
        pendingShow = nil
        guard isEnabled else {
            hideToolbar()
            return
        }

        toolbarWindow.show(actions: currentSettings.visibleSelectionToolbarActions, near: point)
    }

    private func perform(_ action: ToolbarAction) {
        let pid = selectionTargetPID
        let rect = selectionRect
        reset(shouldHideToolbar: true, hidesToolbarImmediately: action == .screenshot, clearTarget: true)
        restoreTarget(pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.shortcutDelay) { [weak self] in
            switch action {
            case .copy, .paste:
                guard let keyCode = action.shortcutKeyCode else { return }
                Self.postCommandShortcut(keyCode)
            case .search:
                self?.copySelectionAndSearch()
            case .screenshot:
                self?.captureSelection(rect)
            }
        }
    }

    private func captureSelection(_ rect: CGRect?) {
        guard let rect, rect.width >= 1, rect.height >= 1 else {
            showToast("截图区域无效")
            return
        }

        if currentSettings.screenshotSelectsRegion {
            captureFullScreenForRegionSelection(initialRect: rect)
            return
        }

        guard let captureRect = Self.screenCaptureRect(fromAppKitRect: rect) else {
            showToast("截图区域无效")
            return
        }

        captureImage(in: captureRect) { [weak self] image in
            self?.finishScreenshot(image)
        }
    }

    private func captureFullScreenForRegionSelection(initialRect rect: CGRect) {
        let appKitRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        guard let screen = Self.screen(containing: appKitRect),
              let fullScreenCaptureRect = Self.screenCaptureRect(fromAppKitRect: screen.frame) else {
            showToast("截图区域无效")
            return
        }
        let screenFrame = screen.frame

        captureImage(in: fullScreenCaptureRect) { [weak self] image in
            guard let self else { return }
            let clippedSelection = appKitRect.intersection(screenFrame)
            let localSelection = NSRect(
                x: clippedSelection.minX - screenFrame.minX,
                y: clippedSelection.minY - screenFrame.minY,
                width: clippedSelection.width,
                height: clippedSelection.height
            )

            self.screenshotSelectionWindow.show(
                image: image,
                screenFrame: screenFrame,
                initialSelection: localSelection,
                onConfirm: { [weak self] croppedImage in
                    self?.finishScreenshot(croppedImage)
                },
                onFailure: { [weak self] in
                    self?.showToast("截图失败")
                },
                onCancel: {}
            )
        }
    }

    private func captureImage(in rect: CGRect, completion: @MainActor @Sendable @escaping (CGImage) -> Void) {
        SCScreenshotManager.captureImage(in: rect) { [weak self] image, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let image else {
                    self.showToast("截图失败")
                    return
                }

                completion(image)
            }
        }
    }

    private func finishScreenshot(_ image: CGImage) {
        if currentSettings.screenshotCopiesToClipboard {
            Self.copyScreenshotToPasteboard(image)
        }

        let saveDirectory = currentSettings.screenshotSaveDirectory
        DispatchQueue.global(qos: .userInitiated).async { [image, saveDirectory, weak self] in
            let result = Result {
                try SelectionToolbarController.saveScreenshot(image, toDirectoryAt: saveDirectory)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.showToast("已保存截图：\(url.lastPathComponent)")
                case .failure:
                    self.showToast("截图失败")
                }
            }
        }
    }

    private static func screenCaptureRect(fromAppKitRect rect: CGRect) -> CGRect? {
        let appKitRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        guard let screen = screen(containing: appKitRect),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }

        let clippedRect = appKitRect.intersection(screen.frame)
        guard clippedRect.width >= 1, clippedRect.height >= 1 else {
            return nil
        }

        let displayBounds = CGDisplayBounds(displayID)
        return CGRect(
            x: displayBounds.minX + clippedRect.minX - screen.frame.minX,
            y: displayBounds.minY + screen.frame.maxY - clippedRect.maxY,
            width: clippedRect.width,
            height: clippedRect.height
        )
    }

    private static func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens
            .filter { $0.frame.intersects(rect) }
            .max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
    }

    private static func copyScreenshotToPasteboard(_ image: CGImage) {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }

    nonisolated private static func saveScreenshot(_ image: CGImage, toDirectoryAt path: String) throws -> URL {
        let directoryURL = path.isEmpty ? defaultScreenshotDirectoryURL() : URL(fileURLWithPath: path, isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let fileURL = uniqueScreenshotURL(in: directoryURL, timestamp: formatter.string(from: Date()))

        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    nonisolated private static func uniqueScreenshotURL(in directory: URL, timestamp: String) -> URL {
        let baseName = "截图\(timestamp)"
        var candidate = directory.appendingPathComponent("\(baseName).png")
        var index = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(index).png")
            index += 1
        }

        return candidate
    }

    private func copySelectionAndSearch() {
        let pasteboard = NSPasteboard.general
        let beforeChangeCount = pasteboard.changeCount
        Self.postCommandShortcut(CGKeyCode(kVK_ANSI_C))

        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.searchReadDelay) { [weak self] in
            guard let self else { return }
            let text = pasteboard.changeCount == beforeChangeCount
                ? nil
                : Self.searchableText(from: pasteboard)

            guard let text, !text.isEmpty else {
                self.showToast("请选中文本进行搜索")
                return
            }

            self.openSearch(for: text)
        }
    }

    private func openSearch(for text: String) {
        let template = currentSettings.searchURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard template.contains("%s") else {
            showToast("搜索链接需要包含 %s")
            return
        }

        guard let encodedText = Self.encodedSearchQuery(text),
              let url = URL(string: template.replacingOccurrences(of: "%s", with: encodedText)) else {
            showToast("搜索链接无效")
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func showToast(_ message: String) {
        toastWindow.show(message: message)
    }

    private func restoreTarget(_ pid: pid_t?) {
        guard let pid, let app = NSRunningApplication(processIdentifier: pid), !app.isActive else {
            return
        }
        app.activate(options: [])
    }

    private func reset(shouldHideToolbar: Bool, hidesToolbarImmediately: Bool = false, clearTarget: Bool) {
        pendingShow?.cancel()
        pendingShow = nil
        mouseDownLocation = nil
        selectionRect = nil
        if clearTarget {
            selectionTargetPID = nil
        }
        if shouldHideToolbar {
            hideToolbar(immediately: hidesToolbarImmediately)
        }
    }

    private func hideToolbar(immediately: Bool = false) {
        toolbarWindow.hide(immediately: immediately)
    }

    private static func searchableText(from pasteboard: NSPasteboard) -> String? {
        guard pasteboard.availableType(from: unsupportedSearchPasteboardTypes) == nil else {
            return nil
        }

        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private static func encodedSearchQuery(_ text: String) -> String? {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text
            .addingPercentEncoding(withAllowedCharacters: unreserved)?
            .replacingOccurrences(of: "%20", with: "+")
    }

    private static func postCommandShortcut(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let commandKeyCode = CGKeyCode(kVK_Command)

        [
            (commandKeyCode, true, CGEventFlags.maskCommand),
            (keyCode, true, CGEventFlags.maskCommand),
            (keyCode, false, CGEventFlags.maskCommand),
            (commandKeyCode, false, CGEventFlags(rawValue: 0))
        ].forEach { step in
            postKey(step.0, isDown: step.1, flags: step.2, source: source)
        }
    }

    private static func postKey(
        _ keyCode: CGKeyCode,
        isDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource?
    ) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}


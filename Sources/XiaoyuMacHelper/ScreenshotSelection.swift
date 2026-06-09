import AppKit
import Carbon

@MainActor
final class ScreenshotSelectionWindow: NSPanel {
    private let selectionView = ScreenshotSelectionView()
    private let actionToolbarWindow = ScreenshotActionToolbarWindow()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        contentView = selectionView
    }

    override func orderOut(_ sender: Any?) {
        actionToolbarWindow.orderOut(nil)
        super.orderOut(sender)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show(
        image: CGImage,
        screenFrame: NSRect,
        initialSelection: NSRect,
        onConfirm: @escaping (CGImage) -> Void,
        onFailure: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        setFrame(screenFrame, display: true)
        attachActionToolbarIfNeeded()
        actionToolbarWindow.onFullScreen = { [weak self] in
            guard let self else { return }
            self.dismissSelectionOverlay()
            onConfirm(image)
        }
        actionToolbarWindow.onConfirm = { [weak self] in
            self?.selectionView.confirm()
        }
        selectionView.configure(
            image: image,
            initialSelection: initialSelection,
            onConfirm: { [weak self] selection in
                guard let self else { return }
                self.dismissSelectionOverlay()
                guard let croppedImage = Self.crop(image, selection: selection, screenSize: screenFrame.size) else {
                    onFailure()
                    return
                }
                onConfirm(croppedImage)
            },
            onCancel: { [weak self] in
                self?.dismissSelectionOverlay()
                onCancel()
            },
            onActionBarFrameChanged: { [weak self] frame in
                self?.positionActionToolbar(frame, screenFrame: screenFrame)
            }
        )
        orderFrontRegardless()
        positionActionToolbar(selectionView.actionBarFrame, screenFrame: screenFrame)
        makeKey()
    }

    private func attachActionToolbarIfNeeded() {
        guard actionToolbarWindow.parent !== self else { return }
        actionToolbarWindow.parent?.removeChildWindow(actionToolbarWindow)
        addChildWindow(actionToolbarWindow, ordered: .above)
    }

    private func dismissSelectionOverlay() {
        actionToolbarWindow.orderOut(nil)
        orderOut(nil)
    }

    private func positionActionToolbar(_ frame: NSRect, screenFrame: NSRect) {
        attachActionToolbarIfNeeded()
        actionToolbarWindow.show(at: NSRect(
            x: screenFrame.minX + frame.minX,
            y: screenFrame.minY + frame.minY,
            width: frame.width,
            height: frame.height
        ))
    }

    private static func crop(_ image: CGImage, selection: NSRect, screenSize: NSSize) -> CGImage? {
        guard selection.width >= 1, selection.height >= 1, screenSize.width > 0, screenSize.height > 0 else {
            return nil
        }

        let scaleX = CGFloat(image.width) / screenSize.width
        let scaleY = CGFloat(image.height) / screenSize.height
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let cropRect = CGRect(
            x: selection.minX * scaleX,
            y: (screenSize.height - selection.maxY) * scaleY,
            width: selection.width * scaleX,
            height: selection.height * scaleY
        ).integral.intersection(imageBounds)

        guard cropRect.width >= 1, cropRect.height >= 1 else {
            return nil
        }

        return image.cropping(to: cropRect)
    }
}

@MainActor
final class ScreenshotSelectionView: NSView {
    private enum Corner {
        case minXMinY
        case minXMaxY
        case maxXMinY
        case maxXMaxY
    }

    private enum Metrics {
        static let minSelectionSize: CGFloat = 18
        static let handleRadius: CGFloat = 10
        static let handleHitRadius: CGFloat = 28
        static let actionBarHeight: CGFloat = 38
        static let actionBarPadding: CGFloat = 6
        static let actionBarGap: CGFloat = 6
        static let actionBarCornerRadius: CGFloat = 10
        static let actionButtonHeight: CGFloat = 28
        static let actionButtonWidth: CGFloat = 58
        static let confirmGap: CGFloat = 12

        static var actionBarWidth: CGFloat {
            actionBarPadding * 2 + actionButtonWidth * 2 + actionBarGap
        }
    }

    private var previewImage: NSImage?
    private var selection = NSRect.zero
    private var draggedCorner: Corner?
    private var onConfirm: ((NSRect) -> Void)?
    private var onCancel: (() -> Void)?
    private var onActionBarFrameChanged: ((NSRect) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    func configure(
        image: CGImage,
        initialSelection: NSRect,
        onConfirm: @escaping (NSRect) -> Void,
        onCancel: @escaping () -> Void,
        onActionBarFrameChanged: @escaping (NSRect) -> Void
    ) {
        previewImage = NSImage(cgImage: image, size: bounds.size)
        selection = Self.normalized(initialSelection).intersection(bounds)
        if selection.width < Metrics.minSelectionSize || selection.height < Metrics.minSelectionSize {
            selection = bounds.insetBy(dx: bounds.width * 0.25, dy: bounds.height * 0.25)
        }
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onActionBarFrameChanged = onActionBarFrameChanged
        onActionBarFrameChanged(actionBarFrame)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let previewImage else { return }

        previewImage.draw(in: bounds)

        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).setClip()
        previewImage.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()

        drawSelectionBorder()
        drawHandles()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        draggedCorner = corner(at: point)

        // 点击选区外时不要让独立的确认工具栏被截图窗口压到后面。
        // 这里重新通知外层定位/置顶一次，保证工具栏仍停留在当前选区附近。
        onActionBarFrameChanged?(actionBarFrame)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let draggedCorner else { return }
        let previousDirtyRect = redrawRectForCurrentSelection()
        let point = clamped(convert(event.locationInWindow, from: nil))
        updateSelection(corner: draggedCorner, point: point)
        onActionBarFrameChanged?(actionBarFrame)
        setNeedsDisplay(previousDirtyRect.union(redrawRectForCurrentSelection()))
    }

    override func mouseUp(with event: NSEvent) {
        draggedCorner = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == kVK_Escape {
            cancel()
        } else if event.keyCode == kVK_Return {
            confirm()
        } else {
            super.keyDown(with: event)
        }
    }

    var actionBarFrame: NSRect {
        let preferredX = selection.maxX - Metrics.actionBarWidth
        let preferredY = selection.minY - Metrics.confirmGap - Metrics.actionBarHeight
        let x = min(max(preferredX, bounds.minX + 8), bounds.maxX - Metrics.actionBarWidth - 8)
        let y = preferredY >= bounds.minY + 8
            ? preferredY
            : min(selection.maxY + Metrics.confirmGap, bounds.maxY - Metrics.actionBarHeight - 8)
        return NSRect(
            origin: NSPoint(x: x, y: y),
            size: NSSize(width: Metrics.actionBarWidth, height: Metrics.actionBarHeight)
        )
    }

    private func drawSelectionBorder() {
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: selection)
        path.lineWidth = 2
        path.stroke()
    }

    private func drawHandles() {
        for point in handlePoints {
            let frame = handleFrame(centeredAt: point)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: frame).fill()

            NSColor.black.withAlphaComponent(0.45).setStroke()
            let ring = NSBezierPath(ovalIn: frame)
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    private var handlePoints: [NSPoint] {
        [
            NSPoint(x: selection.minX, y: selection.minY),
            NSPoint(x: selection.minX, y: selection.maxY),
            NSPoint(x: selection.maxX, y: selection.minY),
            NSPoint(x: selection.maxX, y: selection.maxY)
        ]
    }

    private func corner(at point: NSPoint) -> Corner? {
        let corners: [(Corner, NSPoint)] = [
            (.minXMinY, NSPoint(x: selection.minX, y: selection.minY)),
            (.minXMaxY, NSPoint(x: selection.minX, y: selection.maxY)),
            (.maxXMinY, NSPoint(x: selection.maxX, y: selection.minY)),
            (.maxXMaxY, NSPoint(x: selection.maxX, y: selection.maxY))
        ]

        return corners.first { _, cornerPoint in
            hypot(point.x - cornerPoint.x, point.y - cornerPoint.y) <= Metrics.handleHitRadius
        }?.0
    }

    private func handleFrame(centeredAt point: NSPoint) -> NSRect {
        NSRect(
            x: point.x - Metrics.handleRadius,
            y: point.y - Metrics.handleRadius,
            width: Metrics.handleRadius * 2,
            height: Metrics.handleRadius * 2
        )
    }

    private func redrawRectForCurrentSelection() -> NSRect {
        let handleBounds = handlePoints
            .map { handleFrame(centeredAt: $0).insetBy(dx: -2, dy: -2) }
            .reduce(selection.insetBy(dx: -3, dy: -3)) { $0.union($1) }
        return handleBounds.union(actionBarFrame.insetBy(dx: -3, dy: -3)).intersection(bounds)
    }

    private func updateSelection(corner: Corner, point: NSPoint) {
        var minX = selection.minX
        var maxX = selection.maxX
        var minY = selection.minY
        var maxY = selection.maxY

        switch corner {
        case .minXMinY:
            minX = min(point.x, maxX - Metrics.minSelectionSize)
            minY = min(point.y, maxY - Metrics.minSelectionSize)
        case .minXMaxY:
            minX = min(point.x, maxX - Metrics.minSelectionSize)
            maxY = max(point.y, minY + Metrics.minSelectionSize)
        case .maxXMinY:
            maxX = max(point.x, minX + Metrics.minSelectionSize)
            minY = min(point.y, maxY - Metrics.minSelectionSize)
        case .maxXMaxY:
            maxX = max(point.x, minX + Metrics.minSelectionSize)
            maxY = max(point.y, minY + Metrics.minSelectionSize)
        }

        selection = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds)
    }

    private func clamped(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private static func normalized(_ rect: NSRect) -> NSRect {
        NSRect(
            x: min(rect.minX, rect.maxX),
            y: min(rect.minY, rect.maxY),
            width: abs(rect.width),
            height: abs(rect.height)
        )
    }

    func confirm() {
        confirm(selection: selection)
    }

    private func confirm(selection selectedRect: NSRect) {
        clearImage()
        onConfirm?(selectedRect)
    }

    private func cancel() {
        clearImage()
        onCancel?()
    }

    private func clearImage() {
        previewImage = nil
        onActionBarFrameChanged = nil
    }
}


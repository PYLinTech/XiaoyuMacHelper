import AppKit
import Carbon

@MainActor
final class ScreenshotSelectionWindow: NSPanel {
    private let selectionView = ScreenshotSelectionView()
    private let actionToolbarWindow = ScreenshotActionToolbarWindow()
    private let annotationWindow = ScreenshotAnnotationWindow()

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
        actionToolbarWindow.onCancel = { [weak self] in
            self?.selectionView.cancel()
        }
        actionToolbarWindow.onAnnotate = { [weak self] in
            guard let self else { return }
            self.actionToolbarWindow.orderOut(nil)
            let imageSelection = Self.imageRect(
                fromAppKitSelection: self.selectionView.currentSelection,
                screenSize: screenFrame.size,
                imageSize: NSSize(width: image.width, height: image.height)
            )
            self.annotationWindow.show(
                image: image,
                selection: imageSelection,
                screenFrame: screenFrame,
                onSave: { [weak self] annotatedImage in
                    guard let self else { return }
                    self.dismissSelectionOverlay()
                    onConfirm(annotatedImage)
                },
                onCancel: { [weak self] in
                    guard let self else { return }
                    self.orderFrontRegardless()
                    self.positionActionToolbar(self.selectionView.actionBarFrame, screenFrame: screenFrame)
                }
            )
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

    /// 把选区从视图坐标（左下原点）转换为图像坐标（左上原点、像素），供批注窗口使用。
    private static func imageRect(
        fromAppKitSelection selection: NSRect,
        screenSize: NSSize,
        imageSize: NSSize
    ) -> NSRect {
        guard screenSize.width > 0, screenSize.height > 0 else { return .zero }
        let scaleX = imageSize.width / screenSize.width
        let scaleY = imageSize.height / screenSize.height
        return NSRect(
            x: selection.minX * scaleX,
            y: (screenSize.height - selection.maxY) * scaleY,
            width: selection.width * scaleX,
            height: selection.height * scaleY
        )
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
            ScreenshotActionToolbarWindow.preferredWidth
        }
    }

    private var previewImage: NSImage?
    private var selection = NSRect.zero
    private var draggedCorner: Corner?
    private var isMovingSelection = false
    private var dragStartPoint: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var onConfirm: ((NSRect) -> Void)?
    private var onCancel: (() -> Void)?
    private var onActionBarFrameChanged: ((NSRect) -> Void)?

    /// 当前选区（视图坐标，供批注窗口换算为图像坐标）。
    var currentSelection: NSRect { selection }

    override var acceptsFirstResponder: Bool { true }

    func configure(
        image: CGImage,
        initialSelection: NSRect,
        onConfirm: @escaping (NSRect) -> Void,
        onCancel: @escaping () -> Void,
        onActionBarFrameChanged: @escaping (NSRect) -> Void
    ) {
        previewImage = NSImage(cgImage: image, size: bounds.size)
        // 保留用户实际拖出的选区原样（不做"位移太小回退默认位置"的放大处理）。
        selection = Self.normalized(initialSelection).intersection(bounds)
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
        let point = clamped(convert(event.locationInWindow, from: nil))
        if let corner = corner(at: point) {
            draggedCorner = corner
            isMovingSelection = false
        } else if selection.contains(point) {
            // 点在选区内部：进入"整体拖动"模式，像拖动一个块一样平移选区。
            draggedCorner = nil
            isMovingSelection = true
            dragStartPoint = point
            dragStartOrigin = selection.origin
        } else {
            draggedCorner = nil
            isMovingSelection = false
        }

        // 点击选区外时不要让独立的确认工具栏被截图窗口压到后面。
        // 这里重新通知外层定位/置顶一次，保证工具栏仍停留在当前选区附近。
        onActionBarFrameChanged?(actionBarFrame)
    }

    override func mouseDragged(with event: NSEvent) {
        let previousDirtyRect = redrawRectForCurrentSelection()
        let point = clamped(convert(event.locationInWindow, from: nil))

        if let corner = draggedCorner {
            updateSelection(corner: corner, point: point)
        } else if isMovingSelection, let start = dragStartPoint, let origin = dragStartOrigin {
            moveSelection(
                by: NSPoint(x: point.x - start.x, y: point.y - start.y),
                fromOrigin: origin
            )
        }

        onActionBarFrameChanged?(actionBarFrame)
        window?.invalidateCursorRects(for: self)
        setNeedsDisplay(previousDirtyRect.union(redrawRectForCurrentSelection()))
    }

    override func mouseUp(with event: NSEvent) {
        draggedCorner = nil
        isMovingSelection = false
        dragStartPoint = nil
        dragStartOrigin = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == kVK_Escape {
            cancel()
        } else if event.keyCode == kVK_Return {
            confirm()
        } else if nudgeSelection(with: event) {
            // 方向键微调完成：刷新工具栏位置与光标区。
            onActionBarFrameChanged?(actionBarFrame)
            window?.invalidateCursorRects(for: self)
            setNeedsDisplay(redrawRectForCurrentSelection())
        } else {
            super.keyDown(with: event)
        }
    }

    /// 方向键微调选区（±1pt / Shift+方向 ±10pt），尺寸不变，clamp 到 bounds 内。
    /// 返回 true 表示消费了该事件，false 表示非方向键交由父类处理。
    private func nudgeSelection(with event: NSEvent) -> Bool {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch event.keyCode {
        case UInt16(kVK_LeftArrow):  dx = -step
        case UInt16(kVK_RightArrow): dx = step
        case UInt16(kVK_DownArrow):  dy = -step   // AppKit 视图 y 向上，DownArrow = 减小 y
        case UInt16(kVK_UpArrow):    dy = step
        default: return false
        }
        selection.origin = clampedSelectionOrigin(x: selection.minX + dx, y: selection.minY + dy)
        return true
    }

    /// 把选区 origin 限制在 bounds 内（选区完整可见；选区大于 bounds 时贴 bounds 原点，
    /// 避免 clamp 区间反转导致 origin 越界）。
    private func clampedSelectionOrigin(x: CGFloat, y: CGFloat) -> NSPoint {
        let maxX = max(bounds.minX, bounds.maxX - selection.width)
        let maxY = max(bounds.minY, bounds.maxY - selection.height)
        return NSPoint(x: min(max(x, bounds.minX), maxX), y: min(max(y, bounds.minY), maxY))
    }

    // MARK: 鼠标光标（角点 crosshair / 选区内 openHand）

    override func resetCursorRects() {
        super.resetCursorRects()
        discardCursorRects()
        // 选区内部（含角点命中区外扩）：openHand（整体平移）。
        addCursorRect(selection.insetBy(dx: -2, dy: -2), cursor: .openHand)
        // 角点周围：crosshair（拖拽改大小）。
        let cornerSize: CGFloat = 32
        for point in handlePoints {
            addCursorRect(
                NSRect(
                    x: point.x - cornerSize / 2,
                    y: point.y - cornerSize / 2,
                    width: cornerSize,
                    height: cornerSize
                ),
                cursor: .crosshair
            )
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

    /// 平移整个选区（尺寸不变），并限制在 bounds 内保证选区完整可见。
    private func moveSelection(by delta: NSPoint, fromOrigin origin: NSPoint) {
        selection.origin = clampedSelectionOrigin(x: origin.x + delta.x, y: origin.y + delta.y)
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

    func cancel() {
        clearImage()
        onCancel?()
    }

    private func clearImage() {
        previewImage = nil
        onActionBarFrameChanged = nil
    }
}


import AppKit

// MARK: - 液态玻璃双 SDK 自适应兼容层
//
// 目标：同一份源码既能在 macOS 15 SDK（Xcode 16.x / Swift 6.1）编译，
// 也能在 macOS 26 SDK（Xcode 26 / Swift 6.2+）编译；
// 产物在 macOS 15 上自动使用 NSVisualEffectView 毛玻璃降级，
// 在 macOS 26 上自动使用系统原生 NSGlassEffectView 液态玻璃。
//
// 说明：
// - 不使用 NSGlassEffectView 这个名字定义自定义类型，避免与 macOS 26 SDK
//   中的系统类型重名冲突。对外统一用 LiquidGlassEffectView /
//   LiquidGlassContainerView。
// - 系统 NSGlassEffectView 仅存在于 macOS 26 SDK（compiler >= 6.2），
//   因此用 `#if compiler(>=6.2)` 做编译期分流，用 `if #available(macOS 26, *)`
//   做运行期分流。

/// 液态玻璃视图：macOS 26 用系统原生 NSGlassEffectView，否则用 NSVisualEffectView 模拟。
///
/// 所有视觉/样式属性（style / tintColor / cornerRadius / contentView）都透传到 backingView，
/// 保证 macOS 26 与 macOS 15 行为一致，避免在外层 NSView 上叠一层容器导致子视图坐标系偏移。
@MainActor
final class LiquidGlassEffectView: NSView {
    enum Style {
        case clear
        case regular
    }

    var style: Style = .regular {
        didSet { applyStyle() }
    }

    var tintColor: NSColor? {
        didSet { applyTintColor() }
    }

    var cornerRadius: CGFloat = 0 {
        didSet { applyCornerRadius() }
    }

    var contentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let contentView else { return }
            #if compiler(>=6.2)
            if #available(macOS 26.0, *), let glass = backingView as? NSGlassEffectView {
                glass.contentView = contentView
                return
            }
            #endif
            contentView.frame = bounds
            contentView.autoresizingMask = [.width, .height]
            backingView.addSubview(contentView)
        }
    }

    private let backingView: NSView

    override init(frame frameRect: NSRect) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            backingView = NSGlassEffectView(frame: frameRect)
        } else {
            backingView = Self.makeFallbackView(frame: frameRect)
        }
        #else
        backingView = Self.makeFallbackView(frame: frameRect)
        #endif
        super.init(frame: frameRect)
        setup()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        backingView.autoresizingMask = [.width, .height]
        backingView.frame = bounds
        addSubview(backingView, positioned: .below, relativeTo: nil)
        applyStyle()
        applyTintColor()
        applyCornerRadius()
    }

    override func layout() {
        super.layout()
        backingView.frame = bounds
    }

    private static func makeFallbackView(frame: NSRect) -> NSVisualEffectView {
        let view = NSVisualEffectView(frame: frame)
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    private func applyStyle() {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = backingView as? NSGlassEffectView {
            if style == .clear {
                glass.style = .clear
            } else {
                glass.style = .regular
            }
            return
        }
        #endif
        guard let effect = backingView as? NSVisualEffectView else { return }
        switch style {
        case .clear:
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
        case .regular:
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
        }
    }

    private func applyTintColor() {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = backingView as? NSGlassEffectView {
            glass.tintColor = tintColor
            return
        }
        #endif
        backingView.wantsLayer = true
        backingView.layer?.backgroundColor = tintColor?.withAlphaComponent(0.45).cgColor
    }

    private func applyCornerRadius() {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = backingView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            return
        }
        #endif
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = cornerRadius > 0
    }
}

/// 液态玻璃容器视图：macOS 26 用系统原生 NSGlassEffectContainerView，否则用 NSVisualEffectView 模拟。
///
/// spacing / contentView 都透传到 backingView（macOS 26 上是 NSGlassEffectContainerView 系统类）。
/// 不要在外层 self 上做 contentView inset，否则会导致子视图坐标系原点偏移，
/// 进而让基于 bounds.height 计算卡片 frame 的布局公式（如 `toolCardFrame.minY = bounds.height - 174`）
/// 与实际渲染的 glassContentView 坐标系不一致，造成卡片位置错位。
@MainActor
final class LiquidGlassContainerView: NSView {
    var spacing: CGFloat = 0 {
        didSet {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *), let glass = backingView as? NSGlassEffectContainerView {
                glass.spacing = spacing
            }
            #endif
        }
    }

    var contentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let contentView else { return }
            #if compiler(>=6.2)
            if #available(macOS 26.0, *), let glass = backingView as? NSGlassEffectContainerView {
                glass.contentView = contentView
                return
            }
            #endif
            contentView.frame = bounds
            contentView.autoresizingMask = [.width, .height]
            backingView.addSubview(contentView)
        }
    }

    private let backingView: NSView

    override init(frame frameRect: NSRect) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            backingView = NSGlassEffectContainerView(frame: frameRect)
        } else {
            backingView = Self.makeFallbackView(frame: frameRect)
        }
        #else
        backingView = Self.makeFallbackView(frame: frameRect)
        #endif
        super.init(frame: frameRect)
        setup()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        backingView.autoresizingMask = [.width, .height]
        backingView.frame = bounds
        addSubview(backingView, positioned: .below, relativeTo: nil)
    }

    override func layout() {
        super.layout()
        backingView.frame = bounds
    }

    private static func makeFallbackView(frame: NSRect) -> NSVisualEffectView {
        let view = NSVisualEffectView(frame: frame)
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
}

// MARK: - 按钮玻璃样式兼容
//
// macOS 26 提供 NSButton.BezelStyle.glass，旧系统没有。
// 提供统一的静态属性 liquidGlass：26 上返回 .glass，旧系统返回 .rounded。

extension NSButton.BezelStyle {
    /// 液态玻璃按钮样式：macOS 26+ 返回系统 .glass，旧系统返回 .rounded。
    static var liquidGlass: NSButton.BezelStyle {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return .glass
        }
        #endif
        return .rounded
    }
}

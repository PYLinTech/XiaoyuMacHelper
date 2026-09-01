import AppKit

@MainActor
enum LiquidGlassOverlayStyle {
    static func configureGlass(_ view: LiquidGlassEffectView, cornerRadius: CGFloat) {
        view.style = .clear
        view.tintColor = nil
        view.cornerRadius = cornerRadius
    }

    static func primaryTextColor() -> NSColor {
        NSColor.white.withAlphaComponent(0.96)
    }

    static func hoverBackgroundColor() -> CGColor {
        NSColor.controlAccentColor.cgColor
    }

    static func textShadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.74)
        shadow.shadowBlurRadius = 2.8
        shadow.shadowOffset = NSSize(width: 0, height: -1.0)
        return shadow
    }

    static func attributedText(
        _ text: String,
        font: NSFont,
        color: NSColor = primaryTextColor()
    ) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: color,
                .font: font,
                .shadow: textShadow()
            ]
        )
    }
}


import AppKit

/// Draws the menu bar item as a solid coloured badge with white content, so it reads
/// clearly on any wallpaper (light, dark, or busy), unlike coloured glyphs or text.
enum StatusIcon {
    private static let height: CGFloat = 18
    private static let corner: CGFloat = 5
    private static let textPadding: CGFloat = 5
    private static let glyphBase = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
    private static let textFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)

    /// Square badge: coloured tile + white chip (green / orange states).
    static func badge(fill: NSColor, symbol: String = "memorychip.fill") -> NSImage {
        pill(fill: fill, symbol: symbol, text: nil)
    }

    /// Where the swap dot goes: the chip's top right corner, measured from the image's top left.
    static func swapDotCenter(hasText: Bool) -> NSPoint {
        // With text the chip sits at the pill's left, so its corner is a little further right.
        NSPoint(x: hasText ? textPadding + height - 5 : height - 4, y: 4)
    }

    /// Several badges side by side in one image.
    static func joined(_ images: [NSImage], gap: CGFloat = 4) -> NSImage {
        let width = images.reduce(0) { $0 + $1.size.width } + gap * CGFloat(max(0, images.count - 1))
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for part in images {
                part.draw(in: NSRect(x: x, y: 0, width: part.size.width, height: part.size.height))
                x += part.size.width + gap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Badge that can also carry text, e.g. "⚠ 3.5 GB" in the red state.
    static func pill(fill: NSColor, symbol: String, text: String?) -> NSImage {
        // Two-layer symbols (the warning triangle) get a coloured "!" punched into a white shape.
        let palette: [NSColor] = symbol.contains("triangle") ? [fill, .white] : [.white]
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(glyphBase.applying(.init(paletteColors: palette)))
        let glyphSize = glyph?.size ?? .zero

        let attributed = text.map {
            NSAttributedString(string: $0, attributes: [.font: textFont, .foregroundColor: NSColor.white])
        }
        let textSize = attributed?.size() ?? .zero

        let padding: CGFloat = attributed == nil ? 0 : textPadding
        let gap: CGFloat = attributed == nil ? 0 : 3
        let width = attributed == nil
            ? height
            : ceil(padding + glyphSize.width + gap + textSize.width + padding)
        let size = NSSize(width: width, height: height)

        let image = NSImage(size: size, flipped: false) { rect in
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()

            let glyphX = attributed == nil ? (rect.width - glyphSize.width) / 2 : padding
            glyph?.draw(in: NSRect(
                x: glyphX, y: (rect.height - glyphSize.height) / 2,
                width: glyphSize.width, height: glyphSize.height))

            if let attributed {
                attributed.draw(at: NSPoint(
                    x: glyphX + glyphSize.width + gap,
                    y: (rect.height - textSize.height) / 2))
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

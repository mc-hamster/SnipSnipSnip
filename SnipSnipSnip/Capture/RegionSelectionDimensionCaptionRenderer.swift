import AppKit
import CoreText

/// Draws the fixed numeric alphabet used by the magnifier, not arbitrary/localized text.
@MainActor
struct RegionSelectionDimensionCaptionRenderer {
    private let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold) as CTFont

    static func caption(for size: CGSize) -> String? {
        guard size.width >= 0, size.height >= 0,
              let width = Int(exactly: size.width.rounded()),
              let height = Int(exactly: size.height.rounded()) else {
            return nil
        }
        return "\(width) × \(height)"
    }

    /// `rect` is in the capture overlay's flipped (top-left origin) coordinate space.
    func draw(size: CGSize, in rect: CGRect, context: CGContext) {
        guard let caption = Self.caption(for: size),
              rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else {
            return
        }

        let characters = Array(caption.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else {
            return
        }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        var x: CGFloat = 0
        let positions = advances.map { advance in
            defer { x += advance.width }
            return CGPoint(x: x, y: 0)
        }

        // Build 170 crashed in NSString.draw -> CoreText TAttributes::ApplyFont while
        // copying an attributed-string dictionary. This numeric-only glyph run avoids
        // that typesetting/attribute bridge entirely; a Swift catch cannot catch NSException.
        context.saveGState()
        let previousTextMatrix = context.textMatrix
        let previousTextPosition = context.textPosition
        defer {
            context.restoreGState()
            context.textMatrix = previousTextMatrix
            context.textPosition = previousTextPosition
        }
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY + CTFontGetAscent(font))
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        context.setTextDrawingMode(.fill)
        context.setFillColor(CGColor(gray: 1, alpha: 0.78))
        CTFontDrawGlyphs(font, glyphs, positions, glyphs.count, context)
    }
}

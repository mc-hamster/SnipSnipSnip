import AppKit
import CoreText

struct GlyphLineLayout {
    fileprivate let font: CTFont
    fileprivate let glyphs: [CGGlyph]
    fileprivate let positions: [CGPoint]
    fileprivate let baselineOffset: CGFloat

    let size: CGSize
}

/// Lays out and draws short HUD labels without bridging a Swift attributes
/// dictionary through NSString. That bridge can abort inside CoreText on macOS
/// 26 when it copies a font attribute while an AppKit view is drawing.
enum GlyphLineRenderer {
    static func layout(text: String, font: NSFont) -> GlyphLineLayout? {
        let characters = Array(text.utf16)
        guard !characters.isEmpty else {
            return nil
        }

        let coreTextFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        let resolvedEveryGlyph = characters.withUnsafeBufferPointer { characterBuffer in
            glyphs.withUnsafeMutableBufferPointer { glyphBuffer in
                guard let characterBaseAddress = characterBuffer.baseAddress,
                      let glyphBaseAddress = glyphBuffer.baseAddress else {
                    return false
                }

                return CTFontGetGlyphsForCharacters(
                    coreTextFont,
                    characterBaseAddress,
                    glyphBaseAddress,
                    characters.count
                )
            }
        }
        guard resolvedEveryGlyph else {
            return nil
        }

        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        glyphs.withUnsafeBufferPointer { glyphBuffer in
            advances.withUnsafeMutableBufferPointer { advanceBuffer in
                guard let glyphBaseAddress = glyphBuffer.baseAddress,
                      let advanceBaseAddress = advanceBuffer.baseAddress else {
                    return
                }

                CTFontGetAdvancesForGlyphs(
                    coreTextFont,
                    .horizontal,
                    glyphBaseAddress,
                    advanceBaseAddress,
                    glyphs.count
                )
            }
        }

        var currentX: CGFloat = 0
        let positions = advances.map { advance in
            defer { currentX += max(advance.width, 0) }
            return CGPoint(x: currentX, y: 0)
        }
        let ascent = CTFontGetAscent(coreTextFont)
        let descent = CTFontGetDescent(coreTextFont)
        let leading = max(CTFontGetLeading(coreTextFont), 0)

        return GlyphLineLayout(
            font: coreTextFont,
            glyphs: glyphs,
            positions: positions,
            baselineOffset: leading / 2 + ascent,
            size: CGSize(
                width: ceil(currentX),
                height: ceil(ascent + descent + leading)
            )
        )
    }

    static func draw(
        _ layout: GlyphLineLayout,
        at origin: CGPoint,
        color: NSColor,
        in context: CGContext
    ) {
        context.saveGState()
        context.setFillColor(color.cgColor)

        let baselineY = origin.y + layout.baselineOffset
        for (glyph, position) in zip(layout.glyphs, layout.positions) {
            guard let path = CTFontCreatePathForGlyph(layout.font, glyph, nil) else {
                continue
            }

            var transform = CGAffineTransform(
                a: 1,
                b: 0,
                c: 0,
                d: -1,
                tx: origin.x + position.x,
                ty: baselineY
            )
            guard let transformedPath = path.copy(using: &transform) else {
                continue
            }

            context.addPath(transformedPath)
            context.fillPath()
        }

        context.restoreGState()
    }
}

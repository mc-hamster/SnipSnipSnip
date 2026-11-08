import AppKit
import SwiftUI

/// A neutral, opaque surround keeps screenshot edges distinct from the palette's cards.
/// This is display-only: the stored image and every copy/export path retain their original pixels.
struct ClipboardImagePreview: View {
    let image: NSImage
    var cropsToFill = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geometry in
            Group {
                if cropsToFill {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 1 : 0.22),
                                  lineWidth: contrast == .increased ? 1.5 : 0.75)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.12), radius: 4, y: 2)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .padding(cropsToFill ? 12 : 16)
        .background {
            Color(nsColor: .windowBackgroundColor)
                .overlay(Color.primary.opacity(contrast == .increased ? 0.22 : 0.14))
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: cropsToFill ? 0 : 8))
    }
}

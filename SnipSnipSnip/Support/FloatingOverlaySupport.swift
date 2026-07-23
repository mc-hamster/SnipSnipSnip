import AppKit
import SwiftUI

/// The only custom surface treatment used by app chrome. It is intentionally
/// limited to controls that float over screenshots, video, or the desktop.
struct SSSFloatingOverlaySurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let cornerRadius: CGFloat
    let isInteractive: Bool
    let shadowOpacity: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content
                    .background(
                        Color(nsColor: .windowBackgroundColor),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
            } else {
                content
                    .glassEffect(
                        isInteractive ? .regular.interactive() : .regular,
                        in: .rect(cornerRadius: cornerRadius)
                    )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(colorSchemeContrast == .increased ? 0.42 : 0.16),
                    lineWidth: colorSchemeContrast == .increased ? 1.5 : 0.75
                )
                // This is visual chrome, not a control. Without this, the overlay
                // wins hit testing and prevents HUD buttons and toggles underneath
                // it from receiving clicks.
                .allowsHitTesting(false)
        }
        .shadow(
            color: Color.black.opacity(reduceTransparency ? 0 : shadowOpacity),
            radius: 14,
            y: 6
        )
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
    }
}

extension View {
    func sssFloatingOverlaySurface(
        cornerRadius: CGFloat = 18,
        isInteractive: Bool = false,
        shadowOpacity: Double = 0.08
    ) -> some View {
        modifier(
            SSSFloatingOverlaySurfaceModifier(
                cornerRadius: cornerRadius,
                isInteractive: isInteractive,
                shadowOpacity: shadowOpacity
            )
        )
    }
}

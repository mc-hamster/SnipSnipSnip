import SwiftUI

struct SSSGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let isInteractive: Bool
    let shadowOpacity: Double

    func body(content: Content) -> some View {
        content
            .glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
            .shadow(color: Color.black.opacity(shadowOpacity), radius: 14, y: 6)
    }

    private var glass: Glass {
        var effect = Glass.regular

        if let tint {
            effect = effect.tint(tint)
        }

        if isInteractive {
            effect = effect.interactive()
        }

        return effect
    }
}

struct SSSGlassActionModifier: ViewModifier {
    let tint: Color
    let isEnabled: Bool
    let isSelected: Bool
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let minHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(minHeight: minHeight)
            .foregroundStyle(foregroundStyle)
            .glassEffect(glass, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(strokeStyle, lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: tint.opacity(isEnabled && isSelected ? 0.16 : 0.05), radius: 7, y: 2)
            .opacity(isEnabled ? 1 : 0.56)
    }

    private var glass: Glass {
        var effect = Glass.regular
            .tint(tint.opacity(glassTintOpacity))

        if isEnabled {
            effect = effect.interactive()
        }

        return effect
    }

    private var glassTintOpacity: Double {
        guard isEnabled else {
            return 0.04
        }

        return isSelected ? 0.34 : 0.08
    }

    private var strokeStyle: Color {
        if isSelected {
            return tint.opacity(0.52)
        }

        return Color.white.opacity(isEnabled ? 0.16 : 0.07)
    }

    private var foregroundStyle: Color {
        guard isEnabled else {
            return Color.secondary.opacity(0.55)
        }

        return isSelected ? tint : Color.primary
    }
}

struct SSSChromeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let tint: Color
    let isSelected: Bool

    init(tint: Color = .accentColor, isSelected: Bool = false) {
        self.tint = tint
        self.isSelected = isSelected
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .sssGlassAction(
                tint: tint,
                isEnabled: isEnabled,
                isSelected: isSelected
            )
            .opacity(configuration.isPressed ? 0.92 : 1)
    }
}

struct SSSChromeIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let tint: Color
    let isSelected: Bool

    init(tint: Color = .accentColor, isSelected: Bool = false) {
        self.tint = tint
        self.isSelected = isSelected
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 30, height: 30)
            .sssGlassAction(
                tint: tint,
                isEnabled: isEnabled,
                isSelected: isSelected,
                horizontalPadding: 0,
                verticalPadding: 0,
                minHeight: 30
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

extension View {
    func sssGlassSurface(
        cornerRadius: CGFloat = 18,
        tint: Color? = nil,
        isInteractive: Bool = false,
        shadowOpacity: Double = 0.08
    ) -> some View {
        modifier(
            SSSGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                tint: tint,
                isInteractive: isInteractive,
                shadowOpacity: shadowOpacity
            )
        )
    }

    func sssGlassAction(
        tint: Color = .accentColor,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        horizontalPadding: CGFloat = 10,
        verticalPadding: CGFloat = 6,
        minHeight: CGFloat = 30
    ) -> some View {
        modifier(
            SSSGlassActionModifier(
                tint: tint,
                isEnabled: isEnabled,
                isSelected: isSelected,
                horizontalPadding: horizontalPadding,
                verticalPadding: verticalPadding,
                minHeight: minHeight
            )
        )
    }
}

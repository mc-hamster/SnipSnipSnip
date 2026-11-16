import SwiftUI

// Shared command chrome for Screenshot, Polish, and Video workflows.
struct EditorCommandGroup<Content: View>: View {
    let accessibilityLabel: String
    let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ accessibilityLabel: String, @ViewBuilder content: () -> Content) {
        self.accessibilityLabel = accessibilityLabel
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 5) {
            content
        }
        .padding(3)
        .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    Color(nsColor: .separatorColor),
                    lineWidth: contrast == .increased ? 2 : 1
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct EditorDirectToolButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: isSelected || contrast == .increased ? 2 : 1
                    )
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(contrast == .increased ? 0.28 : 0.18)
        }
        if isPressed {
            return Color.primary.opacity(0.10)
        }
        return Color(nsColor: .controlBackgroundColor)
    }
}

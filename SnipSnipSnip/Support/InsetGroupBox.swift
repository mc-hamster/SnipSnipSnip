import SwiftUI

struct InsetGroupBox<Label: View, Content: View>: View {
    private let spacing: CGFloat
    private let label: Label
    private let content: Content

    init(
        spacing: CGFloat = 12,
        @ViewBuilder content: () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        self.spacing = spacing
        self.content = content()
        self.label = label()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: spacing) {
                label
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension InsetGroupBox where Label == Text {
    init(
        _ title: LocalizedStringKey,
        spacing: CGFloat = 12,
        @ViewBuilder content: () -> Content
    ) {
        self.init(spacing: spacing, content: content) {
            Text(title)
        }
    }

    init(
        verbatim title: String,
        spacing: CGFloat = 12,
        @ViewBuilder content: () -> Content
    ) {
        self.init(spacing: spacing, content: content) {
            Text(verbatim: title)
        }
    }
}

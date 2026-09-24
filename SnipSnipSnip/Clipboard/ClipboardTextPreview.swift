import AppKit
import SwiftUI

/// A reading surface. Editing is a separate, explicit mode and never replaces the stored item.
struct ClipboardTextPreview: View {
    let item: ClipboardItem
    let text: String

    var body: some View {
        Group {
            if item.semanticType == .color, let components = ClipboardColorComponents(text: text) {
                VStack(alignment: .leading, spacing: 18) {
                    ClipboardColorSwatch(components: components)
                        .frame(height: 190)
                        .accessibilityLabel("Color Preview")
                        .accessibilityValue(text)
                    Text(text).font(.system(size: 24, weight: .medium, design: .monospaced))
                }
            } else if case .link = item.kind {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "link")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, height: 52)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                    Text(ClipboardItemPresentation.title(for: item))
                        .font(.system(size: 23, weight: .semibold))
                        .lineLimit(4)
                    Text(text)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if ClipboardItemPresentation.usesMonospacedText(item) {
                Text(text)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text(text)
                    .font(.system(size: 17))
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
        .accessibilityLabel("Clipboard Text Preview")
    }
}

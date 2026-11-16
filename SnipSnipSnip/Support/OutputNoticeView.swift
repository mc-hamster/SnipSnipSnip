import SwiftUI

/// A completion notice occupies an overlay layer rather than resizing media.
struct OutputNoticeView: View {
    let notice: EditorNotice
    let onAction: (EditorNoticeAction) -> Void
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Text(notice.message)
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if let action = notice.action {
                Button(action.title) { onAction(action) }
                    .buttonStyle(.borderless)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss notification")
            .help("Dismiss notification")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .sssFloatingOverlaySurface(cornerRadius: 18, shadowOpacity: 0.10)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notice.accessibilityAnnouncement)
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: notice.id)
    }
}

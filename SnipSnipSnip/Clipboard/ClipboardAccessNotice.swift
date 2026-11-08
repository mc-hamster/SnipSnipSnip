import SwiftUI

struct ClipboardAccessNotice: View {
    @ObservedObject var clipboard: ClipboardWorkflowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(clipboard.monitoringStatus, systemImage: "lock.circle")
                .font(.headline)
            Text("macOS is limiting background clipboard access. Review clipboard access for \(AppBranding.displayName) in Privacy & Security to resume monitoring. Your saved items remain available.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if clipboard.monitor.accessPolicy != .denied {
                Button("Read Clipboard Once", action: clipboard.readClipboardOnce)
                    .disabled(clipboard.isReadingClipboardOnce)
                    .accessibilityIdentifier("clipboard.readOnce")
                Text("This reads the current item. To monitor future copies without prompts, allow clipboard access in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Open Privacy Settings", action: clipboard.openClipboardPrivacySettings)
        }
        .padding(12)
        .accessibilityIdentifier("clipboard.permissionNotice")
    }
}

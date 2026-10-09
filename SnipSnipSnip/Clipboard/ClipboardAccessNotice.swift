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
            Button("Open Privacy Settings", action: clipboard.openClipboardPrivacySettings)
        }
        .padding(12)
        .accessibilityIdentifier("clipboard.permissionNotice")
    }
}

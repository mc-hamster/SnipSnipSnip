import SwiftUI

struct MediaPermissionStatusRow: View {
    let kind: MediaPermissionKind
    @ObservedObject var permissions: PermissionWorkflowModel

    private var status: MediaPermissionStatus { permissions.mediaPermissionStatuses[kind] ?? .notRequested }

    var body: some View {
        LabeledContent {
            HStack {
                Text(status.title)
                    .foregroundStyle(status == .allowed ? Color.secondary : Color.primary)
                Button(status == .notRequested ? "Set Up" : "Open Settings") {
                    permissions.setUpMediaPermission(kind)
                }
                .disabled(permissions.activeMediaPermissionRequest != nil || permissions.activePermissionRequest != nil || status == .restricted)
            }
        } label: {
            Label(kind.title, systemImage: kind.symbol)
            Text(status == .restricted ? "Access is restricted by this Mac. Contact its administrator." : kind.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("permissions.\(kind.rawValue)")
    }
}

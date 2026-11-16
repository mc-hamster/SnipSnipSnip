import Foundation

@MainActor
extension PermissionWorkflowModel {
    var availableMediaPermissions: [MediaPermissionKind] {
        dependencies.capabilities.isEnabled(.connectedDeviceCapture) ? [.microphone, .camera] : [.microphone]
    }

    func mediaPermissionStatus(for kind: MediaPermissionKind) -> MediaPermissionStatus {
        guard availableMediaPermissions.contains(kind) else { return .restricted }
        return dependencies.mediaPermissions.status(for: kind)
    }

    func refreshMediaPermissions() {
        for kind in availableMediaPermissions {
            let status = dependencies.mediaPermissions.status(for: kind)
            if mediaPermissionStatuses[kind] != status { mediaPermissionStatuses[kind] = status }
        }
    }

    func setUpMediaPermission(_ kind: MediaPermissionKind) {
        guard availableMediaPermissions.contains(kind), activeMediaPermissionRequest == nil, activePermissionRequest == nil else { return }
        let status = dependencies.mediaPermissions.status(for: kind)
        guard status == .notRequested else {
            openMediaPermissionSettings(kind)
            return
        }
        activeMediaPermissionRequest = kind
        Task { @MainActor [weak self] in
            guard let self else { return }
            await dependencies.mediaPermissions.request(kind)
            refreshMediaPermissions()
            activeMediaPermissionRequest = nil
        }
    }

    func openMediaPermissionSettings(_ kind: MediaPermissionKind) {
        guard availableMediaPermissions.contains(kind) else { return }
        dependencies.mediaPermissions.openSettings(for: kind)
    }
}

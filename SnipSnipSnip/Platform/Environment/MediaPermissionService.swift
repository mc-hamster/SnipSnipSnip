import AppKit
import AVFoundation

nonisolated enum MediaPermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case camera
    var id: String { rawValue }
    var title: String { self == .microphone ? "Microphone" : "Camera" }
    var symbol: String { self == .microphone ? "mic" : "camera" }
    var detail: String {
        self == .microphone
            ? "Optional narration for Video and Guide."
            : "Preview and capture a connected iPhone or iPad screen."
    }
    var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(self == .microphone ? "Microphone" : "Camera")")!
    }
}

nonisolated enum MediaPermissionStatus: Equatable {
    case notRequested, allowed, denied, restricted
    var title: String {
        switch self {
        case .notRequested: String(localized: "Not Requested")
        case .allowed: String(localized: "Allowed")
        case .denied: String(localized: "Not Allowed")
        case .restricted: String(localized: "Restricted")
        }
    }
}

@MainActor
protocol MediaPermissionServicing {
    func status(for kind: MediaPermissionKind) -> MediaPermissionStatus
    func request(_ kind: MediaPermissionKind) async
    func openSettings(for kind: MediaPermissionKind)
}

@MainActor
struct SystemMediaPermissionService: MediaPermissionServicing {
    func status(for kind: MediaPermissionKind) -> MediaPermissionStatus {
        if kind == .microphone {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .allowed
            case .denied: return .denied
            case .undetermined: return .notRequested
            @unknown default: return .restricted
            }
        }
#if APP_STORE_BUILD
        return .restricted
#else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .allowed
        case .notDetermined: return .notRequested
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
#endif
    }

    func request(_ kind: MediaPermissionKind) async {
        guard status(for: kind) == .notRequested else { return }
        switch kind {
        case .microphone:
            _ = await AVAudioApplication.requestRecordPermission()
        case .camera:
#if !APP_STORE_BUILD
            _ = await AVCaptureDevice.requestAccess(for: .video)
#else
            return
#endif
        }
    }

    func openSettings(for kind: MediaPermissionKind) {
#if APP_STORE_BUILD
        guard kind != .camera else { return }
#endif
        NSWorkspace.shared.open(kind.settingsURL)
    }
}

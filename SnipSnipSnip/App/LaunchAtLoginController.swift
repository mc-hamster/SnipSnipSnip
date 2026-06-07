import Combine
import Foundation
import ServiceManagement

enum LaunchAtLoginServiceState: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

enum LaunchAtLoginStatus: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable

    init(serviceState: LaunchAtLoginServiceState) {
        switch serviceState {
        case .notRegistered:
            self = .disabled
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .unavailable
        }
    }

    var prefersEnabledToggle: Bool {
        switch self {
        case .enabled, .requiresApproval:
            return true
        case .disabled, .unavailable:
            return false
        }
    }

    var needsSystemSettingsApproval: Bool {
        self == .requiresApproval
    }

    var stateLabel: String {
        switch self {
        case .disabled:
            return "Off"
        case .enabled:
            return "On"
        case .requiresApproval:
            return "Needs Approval"
        case .unavailable:
            return "Unavailable"
        }
    }

    var detail: String {
        switch self {
        case .disabled:
            return "SnipSnipSnip will stay off until you open it, but you can turn this on any time in Settings."
        case .enabled:
            return "SnipSnipSnip will launch automatically when you log in so the menu bar extra and shortcuts are ready right away."
        case .requiresApproval:
            return "macOS needs one more confirmation in Login Items before launch at login is fully enabled."
        case .unavailable:
            return "SnipSnipSnip couldn't verify its Login Items entry right now. Try again or open Login Items in System Settings."
        }
    }

    var systemImage: String {
        switch self {
        case .disabled:
            return "power.circle"
        case .enabled:
            return "checkmark.circle.fill"
        case .requiresApproval:
            return "exclamationmark.triangle.fill"
        case .unavailable:
            return "questionmark.circle"
        }
    }

    func matchesRequestedState(_ isEnabled: Bool) -> Bool {
        if isEnabled {
            return prefersEnabledToggle
        }

        return self == .disabled || self == .unavailable
    }
}

enum LaunchAtLoginActionResult: Equatable {
    case updated(LaunchAtLoginStatus)
    case requiresApproval
    case failed(String)
}

protocol LaunchAtLoginControlling {
    var serviceState: LaunchAtLoginServiceState { get }

    func register() throws
    func unregister() throws
    func openSystemSettings()
}

struct MainAppLaunchAtLoginService: LaunchAtLoginControlling {
    var serviceState: LaunchAtLoginServiceState {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: LaunchAtLoginStatus

    private let service: any LaunchAtLoginControlling

    init(service: any LaunchAtLoginControlling = MainAppLaunchAtLoginService()) {
        self.service = service
        self.status = LaunchAtLoginStatus(serviceState: service.serviceState)
    }

    @discardableResult
    func refreshStatus() -> LaunchAtLoginStatus {
        let refreshedStatus = LaunchAtLoginStatus(serviceState: service.serviceState)
        status = refreshedStatus
        return refreshedStatus
    }

    @discardableResult
    func setEnabled(_ isEnabled: Bool) -> LaunchAtLoginActionResult {
        do {
            if isEnabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            let refreshedStatus = refreshStatus()

            if refreshedStatus.needsSystemSettingsApproval {
                return .requiresApproval
            }

            if refreshedStatus.matchesRequestedState(isEnabled) {
                return .updated(refreshedStatus)
            }

            return .failed(error.localizedDescription)
        }

        let refreshedStatus = refreshStatus()

        if refreshedStatus.needsSystemSettingsApproval {
            return .requiresApproval
        }

        return .updated(refreshedStatus)
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}

import AppKit

nonisolated enum ClipboardAccessPolicy: Equatable {
    case systemDefault, ask, allowed, denied

    init(_ behavior: NSPasteboard.AccessBehavior) {
        switch behavior {
        case .default: self = .systemDefault
        case .ask: self = .ask
        case .alwaysAllow: self = .allowed
        case .alwaysDeny: self = .denied
        @unknown default: self = .denied
        }
    }

    var allowsBackgroundRead: Bool { self == .allowed }
    var title: String {
        switch self {
        case .systemDefault: String(localized: "Not Requested")
        case .ask: String(localized: "Asks for Access")
        case .allowed: String(localized: "Allowed")
        case .denied: String(localized: "Not Allowed")
        }
    }
}

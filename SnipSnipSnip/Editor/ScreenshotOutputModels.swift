import Foundation

nonisolated enum ScreenshotOutputAppearance: String, CaseIterable, Identifiable, Sendable {
    case plain
    case styled

    var id: String { rawValue }
    var title: String {
        switch self {
        case .plain: "Plain"
        case .styled: "Styled"
        }
    }
    var filenameSuffix: String {
        switch self {
        case .plain: "edited"
        case .styled: "styled"
        }
    }
}

nonisolated enum ScreenshotOutputError: LocalizedError {
    case styledOutputNotConfigured
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .styledOutputNotConfigured:
            "Styled output is not configured. Open Presentation and choose a style or scene first."
        case .renderingFailed:
            "The screenshot output could not be rendered."
        }
    }
}

enum EditorNoticeAction: Equatable {
    case open(URL)
    case reveal(URL)

    var title: String {
        switch self {
        case .open: "Open"
        case .reveal: "Reveal"
        }
    }
}

struct EditorNotice: Identifiable, Equatable {
    let id: UUID
    let message: String
    let accessibilityAnnouncement: String
    let action: EditorNoticeAction?
    let dismissalDelaySeconds: Double?

    init(
        message: String,
        accessibilityAnnouncement: String? = nil,
        action: EditorNoticeAction? = nil,
        dismissalDelaySeconds: Double? = 3
    ) {
        self.id = UUID()
        self.message = message
        self.accessibilityAnnouncement = accessibilityAnnouncement ?? message
        self.action = action
        self.dismissalDelaySeconds = dismissalDelaySeconds
    }
}

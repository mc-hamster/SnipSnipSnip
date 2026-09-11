import Foundation

extension AppSettingsTab {
    var title: String {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .presets: "Presets"
        case .editorOutput: "Editor & Output"
        case .shortcuts: "Shortcuts"
        case .recording: "Video"
        case .guide: "Guide"
        case .library: "Snip Library"
        case .privacy: "Privacy"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .capture: "viewfinder"
        case .presets: "star"
        case .editorOutput: "slider.horizontal.3"
        case .shortcuts: "keyboard"
        case .recording: "video"
        case .guide: "list.number"
        case .library: "books.vertical"
        case .privacy: "hand.raised"
        }
    }

    /// Intent words supplement category names without duplicating Help copy.
    var searchText: String {
        let keywords: String
        switch self {
        case .general: keywords = "startup login quit background help onboarding support updates quick controls dock reset"
        case .capture: keywords = "timer cursor display screen window region scrolling UI map accessibility ruler inspector magnifier grid"
        case .presets: keywords = "saved capture setup repeat region timer display"
        case .editorOutput: keywords = "filename naming format JPEG PNG PDF quality share export default tool crop dim crosshatch mockup folder polish after capture preview thumbnail auto copy redact"
        case .shortcuts: keywords = "keyboard global hotkey single key command tool"
        case .recording: keywords = "video recording quality frame rate fps display screen source microphone audio sound cursor clicks keyboard shortcuts"
        case .guide: keywords = "guide source video frame rate audio microphone captions privacy secure fields desktop HUD brand logo copyright theme design PDF export"
        case .library: keywords = "snip history archive storage location recycle bin deleted clipboard history encryption retention monitoring ignored apps"
        case .privacy: keywords = "private capture permission accessibility screen recording diagnostics"
        }
        return title + " " + keywords
    }
}

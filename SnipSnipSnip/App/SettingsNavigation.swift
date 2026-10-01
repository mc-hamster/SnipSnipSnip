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
        case .editorOutput: keywords = "filename naming format JPEG PNG PDF quality share export default tool crop dim crosshatch mockup folder polish after capture preview thumbnail redact"
        case .shortcuts: keywords = "keyboard global hotkey single key command tool"
        case .recording: keywords = "video recording quality frame rate fps display screen source microphone audio sound cursor clicks keyboard shortcuts"
        case .guide: keywords = "guide source video frame rate audio microphone captions privacy secure fields desktop HUD brand logo copyright theme design PDF export"
        case .library: keywords = "snip history archive storage location recycle bin deleted clipboard history encryption retention monitoring ignored apps"
        case .privacy: keywords = "private capture permission accessibility screen recording diagnostics"
        }
        return title + " " + keywords
    }
}


struct SettingsSearchResult: Identifiable, Hashable {
    let id: String
    let title: String
    let tab: AppSettingsTab
    let section: String
    let libraryPage: LibrarySettingsSection?
    let requiredCapability: AppCapability?
    let aliases: String

    var breadcrumb: String {
        [tab.title, libraryPage?.title, section].compactMap { $0 }.joined(separator: " › ")
    }

    func matches(_ query: String) -> Bool {
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let searchable = [title, breadcrumb, aliases].joined(separator: " ")
        return !tokens.isEmpty && tokens.allSatisfy { searchable.localizedStandardContains($0) }
    }

    private func rank(for query: String) -> Int {
        if title.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return 0 }
        if title.localizedStandardContains(query) { return 1 }
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return tokens.allSatisfy { title.localizedStandardContains($0) } ? 2 : 3
    }

    static func search(_ query: String, capabilities: AppCapabilitySnapshot) -> [SettingsSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let globalControls: [SettingsSearchResult] = GlobalHotKeyAction.availableActions(for: capabilities).map {
            .init(id: "shortcuts.global.\($0.rawValue)", title: $0.label + " Shortcut", tab: .shortcuts,
                  section: String(localized: "Global Shortcuts"), libraryPage: nil, requiredCapability: nil, aliases: "keyboard hotkey global command")
        }
        return (catalog + globalControls).filter {
            ($0.tab != .guide || capabilities.isEnabled(.guideCapture)) &&
                ($0.requiredCapability.map { capabilities.isEnabled($0) } ?? true) && $0.matches(query)
        }.sorted { $0.rank(for: query) < $1.rank(for: query) }
    }

    static let catalog: [SettingsSearchResult] = [
        .init(id: "general.launchLogin", title: String(localized: "Launch \(AppBranding.displayName) at Login"), tab: .general, section: String(localized: "Startup"), libraryPage: nil, requiredCapability: nil, aliases: "login startup launch"),
        .init(id: "general.confirmQuit", title: String(localized: "Confirm Before Quitting"), tab: .general, section: String(localized: "Startup"), libraryPage: nil, requiredCapability: nil, aliases: "quit background"),
        .init(id: "general.onboarding", title: String(localized: "Show Onboarding Again"), tab: .general, section: String(localized: "Help & Onboarding"), libraryPage: nil, requiredCapability: nil, aliases: "setup welcome help"),
        .init(id: "general.support", title: String(localized: "Open Support Page"), tab: .general, section: String(localized: "Help & Onboarding"), libraryPage: nil, requiredCapability: nil, aliases: "support help feature requests"),
        .init(id: "general.quickControlsStartup", title: String(localized: "Show Quick Controls when \(AppBranding.displayName) starts"), tab: .general, section: String(localized: "Quick Controls"), libraryPage: nil, requiredCapability: nil, aliases: "dock startup launch"),
        .init(id: "general.customizeQuickControls", title: String(localized: "Customize Quick Controls…"), tab: .general, section: String(localized: "Quick Controls"), libraryPage: nil, requiredCapability: nil, aliases: "dock palette shortcuts"),
        .init(id: "general.reset", title: String(localized: "Reset All Settings to Defaults"), tab: .general, section: String(localized: "Reset Settings"), libraryPage: nil, requiredCapability: nil, aliases: "restore preferences"),
        .init(id: "capture.cursor", title: String(localized: "Include Cursor as Editable Overlay"), tab: .capture, section: String(localized: "Screenshot Capture"), libraryPage: nil, requiredCapability: nil, aliases: "mouse pointer screenshot"),
        .init(id: "capture.regionCommit", title: String(localized: "After Selecting a Region"), tab: .capture, section: String(localized: "Screenshot Capture"), libraryPage: nil, requiredCapability: nil, aliases: "region release capture confirm"),
        .init(id: "capture.screenSource", title: String(localized: "Screen Capture"), tab: .capture, section: String(localized: "Screenshot Capture"), libraryPage: nil, requiredCapability: nil, aliases: "display monitor fullscreen"),
        .init(id: "capture.selectedDisplay", title: String(localized: "Selected Display"), tab: .capture, section: String(localized: "Screenshot Capture"), libraryPage: nil, requiredCapability: nil, aliases: "screen monitor"),
        .init(id: "capture.mouseDistance", title: String(localized: "Show Mouse Distance"), tab: .capture, section: String(localized: "Screen Ruler"), libraryPage: nil, requiredCapability: nil, aliases: "measurement"),
        .init(id: "capture.halfMarkers", title: String(localized: "Show Half Markers"), tab: .capture, section: String(localized: "Screen Ruler"), libraryPage: nil, requiredCapability: nil, aliases: "measurement"),
        .init(id: "capture.horizontalTickEdge", title: String(localized: "Horizontal Tick Edge"), tab: .capture, section: String(localized: "Screen Ruler"), libraryPage: nil, requiredCapability: nil, aliases: "ruler top bottom"),
        .init(id: "capture.verticalTickEdge", title: String(localized: "Vertical Tick Edge"), tab: .capture, section: String(localized: "Screen Ruler"), libraryPage: nil, requiredCapability: nil, aliases: "ruler left right"),
        .init(id: "capture.horizontalOrigin", title: String(localized: "Horizontal 0 Origin"), tab: .capture, section: String(localized: "Screen Ruler"), libraryPage: nil, requiredCapability: nil, aliases: "ruler zero position"),
        .init(id: "capture.verticalOrigin", title: String(localized: "Vertical 0 Origin"), tab: .capture, section: String(localized: "Screen Ruler"), libraryPage: nil, requiredCapability: nil, aliases: "ruler zero position"),
        .init(id: "capture.rulerOpacity", title: String(localized: "Opacity"), tab: .capture, section: String(localized: "Screen Ruler"), libraryPage: nil, requiredCapability: nil, aliases: "ruler transparency"),
        .init(id: "capture.tickSpacing", title: String(localized: "Tick Spacing"), tab: .capture, section: String(localized: "Screen Ruler"), libraryPage: nil, requiredCapability: nil, aliases: "ruler measurements"),
        .init(id: "capture.majorTick", title: String(localized: "Major Tick Every"), tab: .capture, section: String(localized: "Screen Ruler"), libraryPage: nil, requiredCapability: nil, aliases: "ruler measurements"),
        .init(id: "capture.zoom", title: String(localized: "Zoom Level"), tab: .capture, section: String(localized: "Screen Inspector"), libraryPage: nil, requiredCapability: nil, aliases: "magnifier pixels"),
        .init(id: "capture.pixelGrid", title: String(localized: "Show Pixel Grid"), tab: .capture, section: String(localized: "Screen Inspector"), libraryPage: nil, requiredCapability: nil, aliases: "magnifier"),
        .init(id: "capture.crosshair", title: String(localized: "Show Crosshair"), tab: .capture, section: String(localized: "Screen Inspector"), libraryPage: nil, requiredCapability: nil, aliases: "magnifier pointer"),
        .init(id: "presets.presets", title: String(localized: "Capture Presets"), tab: .presets, section: String(localized: "Capture Presets"), libraryPage: nil, requiredCapability: nil, aliases: "saved repeat setup timer region"),
        .init(id: "editorOutput.preview", title: String(localized: "Show Capture Preview"), tab: .editorOutput, section: String(localized: "After Capture"), libraryPage: nil, requiredCapability: nil, aliases: "thumbnail after screenshot"),
        .init(id: "editorOutput.filename", title: String(localized: "Filename Template"), tab: .editorOutput, section: String(localized: "Naming"), libraryPage: nil, requiredCapability: nil, aliases: "file name date tokens"),
        .init(id: "editorOutput.dragFormat", title: String(localized: "Drag-Out Format"), tab: .editorOutput, section: String(localized: "Export & Sharing"), libraryPage: nil, requiredCapability: nil, aliases: "screenshot format jpeg png share file"),
        .init(id: "editorOutput.jpegQuality", title: String(localized: "JPEG Quality"), tab: .editorOutput, section: String(localized: "Export & Sharing"), libraryPage: nil, requiredCapability: nil, aliases: "compression export jpeg"),
        .init(id: "editorOutput.defaultTool", title: String(localized: "Default Tool"), tab: .editorOutput, section: String(localized: "Editor"), libraryPage: nil, requiredCapability: nil, aliases: "last used annotation"),
        .init(id: "editorOutput.cropDimming", title: String(localized: "Crop Outside Dimming"), tab: .editorOutput, section: String(localized: "Editor"), libraryPage: nil, requiredCapability: nil, aliases: "crop dark overlay"),
        .init(id: "editorOutput.crosshatch", title: String(localized: "Show Out-of-Capture Crosshatch"), tab: .editorOutput, section: String(localized: "Editor"), libraryPage: nil, requiredCapability: nil, aliases: "canvas pattern"),
        .init(id: "editorOutput.patternSpacing", title: String(localized: "Pattern Spacing"), tab: .editorOutput, section: String(localized: "Editor"), libraryPage: nil, requiredCapability: nil, aliases: "crosshatch"),
        .init(id: "editorOutput.lineOpacity", title: String(localized: "Line Opacity"), tab: .editorOutput, section: String(localized: "Editor"), libraryPage: nil, requiredCapability: nil, aliases: "crosshatch"),
        .init(id: "editorOutput.dotSize", title: String(localized: "Dot Size"), tab: .editorOutput, section: String(localized: "Editor"), libraryPage: nil, requiredCapability: nil, aliases: "crosshatch"),
        .init(id: "editorOutput.dotOpacity", title: String(localized: "Dot Opacity"), tab: .editorOutput, section: String(localized: "Editor"), libraryPage: nil, requiredCapability: nil, aliases: "crosshatch"),
        .init(id: "editorOutput.mockups", title: String(localized: "Choose Mockup Folder..."), tab: .editorOutput, section: String(localized: "Editor"), libraryPage: nil, requiredCapability: nil, aliases: "polish mockups presentation svg scenes"),
        .init(id: "shortcuts.global", title: String(localized: "Enable Global Shortcuts"), tab: .shortcuts, section: String(localized: "Global Shortcuts"), libraryPage: nil, requiredCapability: nil, aliases: "hotkey keyboard command"),
        .init(id: "shortcuts.tools", title: String(localized: "Enable Single-Key Tool Shortcuts"), tab: .shortcuts, section: String(localized: "Editor Shortcuts"), libraryPage: nil, requiredCapability: nil, aliases: "keyboard annotation"),
        .init(id: "shortcuts.reference", title: String(localized: "Shortcut Reference"), tab: .shortcuts, section: String(localized: "Shortcut Reference"), libraryPage: nil, requiredCapability: nil, aliases: "keyboard command keys"),
        .init(id: "recording.quality", title: String(localized: "Quality"), tab: .recording, section: String(localized: "Quality"), libraryPage: nil, requiredCapability: nil, aliases: "video compression recording"),
        .init(id: "recording.frameRate", title: String(localized: "Frame Rate"), tab: .recording, section: String(localized: "Quality"), libraryPage: nil, requiredCapability: nil, aliases: "fps video recording"),
        .init(id: "recording.screenSource", title: String(localized: "Screen Source"), tab: .recording, section: String(localized: "Recording Sources"), libraryPage: nil, requiredCapability: nil, aliases: "display monitor fullscreen video"),
        .init(id: "recording.selectedDisplay", title: String(localized: "Selected Display"), tab: .recording, section: String(localized: "Recording Sources"), libraryPage: nil, requiredCapability: nil, aliases: "screen monitor video"),
        .init(id: "recording.audio", title: String(localized: "Record System Audio"), tab: .recording, section: String(localized: "Recording Sources"), libraryPage: nil, requiredCapability: nil, aliases: "sound video"),
        .init(id: "recording.microphone", title: String(localized: "Record Microphone"), tab: .recording, section: String(localized: "Recording Sources"), libraryPage: nil, requiredCapability: nil, aliases: "audio sound video"),
        .init(id: "recording.cursor", title: String(localized: "Show Cursor"), tab: .recording, section: String(localized: "Recording Sources"), libraryPage: nil, requiredCapability: nil, aliases: "pointer video"),
        .init(id: "recording.clicks", title: String(localized: "Show Mouse Clicks"), tab: .recording, section: String(localized: "Recording Sources"), libraryPage: nil, requiredCapability: nil, aliases: "pointer video"),
        .init(id: "recording.keyboard", title: String(localized: "Record Keyboard Shortcuts"), tab: .recording, section: String(localized: "Recording Sources"), libraryPage: nil, requiredCapability: .videoShortcutCapture, aliases: "keys video accessibility"),
        .init(id: "guide.sourceVideo", title: String(localized: "Keep Full-Motion Source Video"), tab: .guide, section: String(localized: "Capture"), libraryPage: nil, requiredCapability: nil, aliases: "guide recording"),
        .init(id: "guide.frameRate", title: String(localized: "Source Frame Rate"), tab: .guide, section: String(localized: "Capture"), libraryPage: nil, requiredCapability: nil, aliases: "fps video"),
        .init(id: "guide.audio", title: String(localized: "Record System Audio"), tab: .guide, section: String(localized: "Capture"), libraryPage: nil, requiredCapability: nil, aliases: "sound video"),
        .init(id: "guide.microphone", title: String(localized: "Record Microphone"), tab: .guide, section: String(localized: "Capture"), libraryPage: nil, requiredCapability: nil, aliases: "audio sound video"),
        .init(id: "guide.captions", title: String(localized: "Create Captions Automatically"), tab: .guide, section: String(localized: "Steps & Privacy"), libraryPage: nil, requiredCapability: nil, aliases: "steps description"),
        .init(id: "guide.refineCaptions", title: String(localized: "Refine Captions On Device"), tab: .guide, section: String(localized: "Steps & Privacy"), libraryPage: nil, requiredCapability: nil, aliases: "ai local"),
        .init(id: "guide.secureFields", title: String(localized: "Mask Secure Fields"), tab: .guide, section: String(localized: "Steps & Privacy"), libraryPage: nil, requiredCapability: nil, aliases: "password privacy"),
        .init(id: "guide.cursor", title: String(localized: "Show Cursor in Still Steps"), tab: .guide, section: String(localized: "Steps & Privacy"), libraryPage: nil, requiredCapability: nil, aliases: "pointer screenshots"),
        .init(id: "guide.desktopIcons", title: String(localized: "Hide Desktop Icons"), tab: .guide, section: String(localized: "Steps & Privacy"), libraryPage: nil, requiredCapability: nil, aliases: "desktop privacy"),
        .init(id: "guide.menuBar", title: String(localized: "Include Menu Bar in Screen Guides"), tab: .guide, section: String(localized: "Steps & Privacy"), libraryPage: nil, requiredCapability: nil, aliases: "screen display"),
        .init(id: "guide.hudCorner", title: String(localized: "Corner"), tab: .guide, section: String(localized: "Capture HUD"), libraryPage: nil, requiredCapability: nil, aliases: "floating controls position"),
        .init(id: "guide.stepPreviews", title: String(localized: "Show Recent Step Previews"), tab: .guide, section: String(localized: "Capture HUD"), libraryPage: nil, requiredCapability: nil, aliases: "thumbnail hud"),
        .init(id: "guide.organization", title: String(localized: "Organization"), tab: .guide, section: String(localized: "Default Brand Profile"), libraryPage: nil, requiredCapability: nil, aliases: "brand company"),
        .init(id: "guide.footer", title: String(localized: "Copyright / footer"), tab: .guide, section: String(localized: "Default Brand Profile"), libraryPage: nil, requiredCapability: nil, aliases: "brand legal"),
        .init(id: "guide.legal", title: String(localized: "Legal statement"), tab: .guide, section: String(localized: "Default Brand Profile"), libraryPage: nil, requiredCapability: nil, aliases: "brand copyright"),
        .init(id: "guide.themeName", title: String(localized: "Theme Name"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "design"),
        .init(id: "guide.saveTheme", title: String(localized: "Save Theme"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "design"),
        .init(id: "guide.appearance", title: String(localized: "Appearance"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "light dark design"),
        .init(id: "guide.arrowWidth", title: String(localized: "Arrow Width"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "marker design"),
        .init(id: "guide.arrowLength", title: String(localized: "Arrow Length"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "marker design"),
        .init(id: "guide.pdf", title: String(localized: "PDF"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "export format"),
        .init(id: "guide.gif", title: String(localized: "GIF"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "export animation"),
        .init(id: "guide.apng", title: String(localized: "APNG"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "export animation"),
        .init(id: "guide.fullMotion", title: String(localized: "Full Motion MP4"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "export video"),
        .init(id: "guide.highlights", title: String(localized: "Action Highlights MP4"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "export video"),
        .init(id: "guide.slideshow", title: String(localized: "Step Slideshow MP4"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "export video"),
        .init(id: "guide.images", title: String(localized: "Step Images"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "export images"),
        .init(id: "guide.zip", title: String(localized: "ZIP"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "export archive"),
        .init(id: "guide.pdfPaper", title: String(localized: "PDF Paper"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "page letter a4"),
        .init(id: "guide.pdfOrientation", title: String(localized: "PDF Orientation"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "portrait landscape"),
        .init(id: "guide.pdfQuality", title: String(localized: "PDF Quality"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "dpi resolution"),
        .init(id: "guide.imageFormat", title: String(localized: "Step Image Format"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "png jpeg export"),
        .init(id: "guide.filename", title: String(localized: "File Name"), tab: .guide, section: String(localized: "Default Design & Export"), libraryPage: nil, requiredCapability: nil, aliases: "filename export"),
        .init(id: "library.snipLocation", title: String(localized: "Choose Location…"), tab: .library, section: String(localized: "Snip History Storage"), libraryPage: .snips, requiredCapability: nil, aliases: "snip history storage folder archive"),
        .init(id: "library.snipLimit", title: String(localized: "Maximum Snip History Size"), tab: .library, section: String(localized: "Snip History Storage"), libraryPage: .snips, requiredCapability: nil, aliases: "storage archive limit"),
        .init(id: "library.deleteSnips", title: String(localized: "Permanently Delete Snip History and Empty Recycle Bin"), tab: .library, section: String(localized: "Snip History Storage"), libraryPage: .snips, requiredCapability: nil, aliases: "clear archive history storage"),
        .init(id: "library.snipRetention", title: String(localized: "Empty Deleted Snips After"), tab: .library, section: String(localized: "Recycle Bin"), libraryPage: .snips, requiredCapability: nil, aliases: "retention days recycle bin"),
        .init(id: "library.emptyBin", title: String(localized: "Empty Recycle Bin"), tab: .library, section: String(localized: "Recycle Bin"), libraryPage: .snips, requiredCapability: nil, aliases: "delete clear"),
        .init(id: "library.clipboardEnabled", title: String(localized: "Enable Clipboard History"), tab: .library, section: String(localized: "Clipboard History"), libraryPage: .clipboard, requiredCapability: nil, aliases: "monitoring encrypted keychain"),
        .init(id: "library.clipboardItems", title: String(localized: "Maximum Unpinned Items"), tab: .library, section: String(localized: "Clipboard History"), libraryPage: .clipboard, requiredCapability: nil, aliases: "clipboard limit count"),
        .init(id: "library.clipboardStorage", title: String(localized: "History Storage Target"), tab: .library, section: String(localized: "Clipboard History"), libraryPage: .clipboard, requiredCapability: nil, aliases: "clipboard size encrypted pinned"),
        .init(id: "library.clipboardItemSize", title: String(localized: "Maximum Item Size"), tab: .library, section: String(localized: "Clipboard History"), libraryPage: .clipboard, requiredCapability: nil, aliases: "clipboard limit size"),
        .init(id: "library.clipboardRetention", title: String(localized: "Delete Unpinned Items"), tab: .library, section: String(localized: "Clipboard History"), libraryPage: .clipboard, requiredCapability: nil, aliases: "clipboard retention days"),
        .init(id: "library.uncopiedSnips", title: String(localized: "Add Screenshots That Were Not Copied"), tab: .library, section: String(localized: "Clipboard History"), libraryPage: .clipboard, requiredCapability: nil, aliases: "clipboard capture"),
        .init(id: "library.deleteClipboard", title: String(localized: "Permanently Delete Clipboard History"), tab: .library, section: String(localized: "Clipboard History"), libraryPage: .clipboard, requiredCapability: nil, aliases: "clear clipboard storage"),
        .init(id: "library.ignoreApps", title: String(localized: "Ignore Running App"), tab: .library, section: String(localized: "Ignored Apps"), libraryPage: .clipboard, requiredCapability: nil, aliases: "clipboard ignored sources passwords privacy"),
        .init(id: "privacy.private", title: String(localized: "Private Capture"), tab: .privacy, section: String(localized: "Private Capture"), libraryPage: nil, requiredCapability: nil, aliases: "privacy history clipboard"),
        .init(id: "privacy.screenRecording", title: String(localized: "Screen Recording"), tab: .privacy, section: String(localized: "Permission Diagnostics"), libraryPage: nil, requiredCapability: nil, aliases: "permission screen capture"),
        .init(id: "privacy.diagnostics", title: String(localized: "Export Diagnostics…"), tab: .privacy, section: String(localized: "Permission Diagnostics"), libraryPage: nil, requiredCapability: nil, aliases: "support privacy permissions"),
        .init(id: "capture.uiMapEnabled", title: String(localized: "Enable UI Map for Window captures"), tab: .capture, section: String(localized: "Screenshot Capture › Advanced"), libraryPage: nil, requiredCapability: .uiMap, aliases: "ui map window metadata accessibility"),
        .init(id: "capture.uiMapOutline", title: String(localized: "Show outline"), tab: .capture, section: String(localized: "Screenshot Capture › Advanced"), libraryPage: nil, requiredCapability: .uiMap, aliases: "ui map pinned overlay metadata"),
        .init(id: "capture.uiMapSource", title: String(localized: "Show source"), tab: .capture, section: String(localized: "Screenshot Capture › Advanced"), libraryPage: nil, requiredCapability: .uiMap, aliases: "ui map pinned overlay metadata"),
        .init(id: "capture.uiMapName", title: String(localized: "Show name"), tab: .capture, section: String(localized: "Screenshot Capture › Advanced"), libraryPage: nil, requiredCapability: .uiMap, aliases: "ui map pinned overlay metadata"),
        .init(id: "capture.uiMapAccessibilityLabel", title: String(localized: "Show accessibility label"), tab: .capture, section: String(localized: "Screenshot Capture › Advanced"), libraryPage: nil, requiredCapability: .uiMap, aliases: "ui map pinned overlay metadata"),
        .init(id: "capture.uiMapIdentifier", title: String(localized: "Show identifier"), tab: .capture, section: String(localized: "Screenshot Capture › Advanced"), libraryPage: nil, requiredCapability: .uiMap, aliases: "ui map pinned overlay metadata"),
        .init(id: "capture.uiMapRole", title: String(localized: "Show role"), tab: .capture, section: String(localized: "Screenshot Capture › Advanced"), libraryPage: nil, requiredCapability: .uiMap, aliases: "ui map pinned overlay metadata"),
        .init(id: "capture.uiMapValue", title: String(localized: "Show value"), tab: .capture, section: String(localized: "Screenshot Capture › Advanced"), libraryPage: nil, requiredCapability: .uiMap, aliases: "ui map pinned overlay metadata"),
        .init(id: "capture.uiMapCoordinates", title: String(localized: "Show coordinates"), tab: .capture, section: String(localized: "Screenshot Capture › Advanced"), libraryPage: nil, requiredCapability: .uiMap, aliases: "ui map pinned overlay metadata"),
        .init(id: "capture.uiMapDimensions", title: String(localized: "Show dimensions"), tab: .capture, section: String(localized: "Screenshot Capture › Advanced"), libraryPage: nil, requiredCapability: .uiMap, aliases: "ui map pinned overlay metadata"),
        .init(id: "capture.uiMapOwningApp", title: String(localized: "Show owning app"), tab: .capture, section: String(localized: "Screenshot Capture › Advanced"), libraryPage: nil, requiredCapability: .uiMap, aliases: "ui map pinned overlay metadata"),
        .init(id: "capture.uiMapBundleIdentifier", title: String(localized: "Show bundle identifier"), tab: .capture, section: String(localized: "Screenshot Capture › Advanced"), libraryPage: nil, requiredCapability: .uiMap, aliases: "ui map pinned overlay metadata"),
        .init(id: "capture.uiMapParent", title: String(localized: "Show parent hierarchy"), tab: .capture, section: String(localized: "Screenshot Capture › Advanced"), libraryPage: nil, requiredCapability: .uiMap, aliases: "ui map pinned overlay metadata"),
        .init(id: "general.updates", title: String(localized: "Check for Pro Updates..."), tab: .general, section: String(localized: "Help & Onboarding"), libraryPage: nil, requiredCapability: .proUpdateCheck, aliases: "update version release"),
        .init(id: "privacy.accessibility", title: String(localized: "Accessibility"), tab: .privacy, section: String(localized: "Permission Diagnostics"), libraryPage: nil, requiredCapability: nil, aliases: "permission ui map scrolling keyboard shortcuts"),
        .init(id: "library.chooseIgnoredApp", title: String(localized: "Choose App..."), tab: .library, section: String(localized: "Ignored Apps"), libraryPage: .clipboard, requiredCapability: nil, aliases: "clipboard ignored sources passwords privacy"),
    ]
}

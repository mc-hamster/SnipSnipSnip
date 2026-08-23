import SwiftUI

nonisolated enum HelpSearchSelectionPolicy {
    struct Result: Equatable {
        let selectedID: String?
        let preSearchID: String?
    }

    static func resolve(
        currentID: String?,
        preSearchID: String?,
        oldQuery: String,
        newQuery: String,
        matchingIDs: [String],
        defaultID: String
    ) -> Result {
        let oldQuery = oldQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let newQuery = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let rememberedID = oldQuery.isEmpty && !newQuery.isEmpty ? currentID : preSearchID

        guard !newQuery.isEmpty else {
            return Result(selectedID: rememberedID ?? defaultID, preSearchID: nil)
        }
        if let currentID, matchingIDs.contains(currentID) {
            return Result(selectedID: currentID, preSearchID: rememberedID)
        }
        return Result(selectedID: matchingIDs.first, preSearchID: rememberedID)
    }
}

private struct HelpCategory: Identifiable {
    let title: String
    let articles: [HelpArticle]

    var id: String { title }
}

private struct HelpArticle: Identifiable {
    let id: String
    let title: String
    let summary: String
    let sections: [HelpArticleSection]
    let important: [String]
    let relatedIDs: [String]
}

private struct HelpArticleSection: Identifiable {
    let title: String
    let body: String?
    let steps: [String]
    let bullets: [String]
    let links: [HelpArticleLink]

    var id: String { title }

    init(
        title: String,
        body: String? = nil,
        steps: [String] = [],
        bullets: [String] = [],
        links: [HelpArticleLink] = []
    ) {
        self.title = title
        self.body = body
        self.steps = steps
        self.bullets = bullets
        self.links = links
    }
}

private struct HelpArticleLink: Identifiable {
    let title: String
    let url: URL

    var id: URL { url }
}

struct HelpGuideView: View {
    private static let defaultArticleID = "get-started"

    @State private var selectedArticleID: HelpArticle.ID? = Self.defaultArticleID
    @State private var selectedArticleIDBeforeSearch: HelpArticle.ID?
    @State private var searchText = ""
    @ObservedObject private var capture: CaptureWorkflowModel
    private let capabilities: AppCapabilitySnapshot

    init(capabilities: AppCapabilitySnapshot, capture: CaptureWorkflowModel) {
        self.capabilities = capabilities
        self.capture = capture
    }

    private static func categories(
        for capabilities: AppCapabilitySnapshot,
        fullscreenDisplayMode: ScreenshotFullscreenDisplayMode
    ) -> [HelpCategory] {
        let scrollingCaptureEnabled = capabilities.isEnabled(.scrollingCapture)
        let connectedDeviceCaptureEnabled = capabilities.isEnabled(.connectedDeviceCapture)
        let uiMapEnabled = capabilities.isEnabled(.uiMap)
        let proUpdateCheckEnabled = capabilities.isEnabled(.proUpdateCheck)
        let guideEnabled = capabilities.isEnabled(.guideCapture)
        var accessibilityUses: [String] = []
        if guideEnabled {
            accessibilityUses.append("Guide uses it while active to observe actions and keyboard focus, group non-secure text entry, and mask secure fields.")
        }
        if scrollingCaptureEnabled {
            accessibilityUses.append("Scrolling Capture uses it to scroll the selected app while collecting segments.")
        }
        if uiMapEnabled {
            accessibilityUses.append("Window UI Map uses it to read visible interface element names, roles, identifiers, and locations during a user-initiated Window capture.")
        }

        return [
        HelpCategory(
            title: "Start here",
            articles: [
                HelpArticle(
                    id: "get-started",
                    title: "Get started with SnipSnipSnip",
                    summary: "Take a screenshot, make a few edits, and share the finished result.",
                    sections: [
                        HelpArticleSection(
                            title: "Finish setup",
                            body: "Setup asks only for choices needed to keep capture available. Open Settings > General > Show Onboarding Again later to review them. Changes in Setup Summary save immediately; choose Close when you are finished.",
                            steps: [
                                "Allow Screen Recording so macOS can provide screenshot pixels and live window thumbnails. Restart SnipSnipSnip if setup asks you to.",
                                "Choose whether to enable encrypted, local Clipboard History.",
                                "Review Launch at Login, then choose Finish."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Take and finish a screenshot",
                            steps: [
                                "Use Quick Capture to choose Region, Window, or Screen. Region, Window, Screen, Scroll, and Repeat Last are direct actions, and Presets stays in its own menu.",
                                "Use the editor to crop, annotate, redact, or copy text.",
                                "Choose Copy, Export, Share, Float, or Drag for the result currently shown.",
                                "Choose Save or Save As when you want to keep an editable .sss document."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Create or record without an extra menu",
                            body: "Under Create, choose Comparison, Steps, or Combined Image to open setup with that result already selected. Under Record, choose Region, Window, Screen, Guide, or an available connected device directly. Use Quick Capture for a one-action Screenshot."
                        ),
                        HelpArticleSection(
                            title: "Discover screen tools and capture options",
                            body: "Use Screen Tools in the main header to add a Screen Ruler, open Screen Inspector, or show Quick Controls. Clipboard History opens beside those utilities. Point to an action or move keyboard focus to it to see an animated explanation of what it creates or opens. The pointer preview changes after a short 50 millisecond dwell, while keyboard focus changes it immediately. Timer, Cursor, Private Capture, and Auto Copy state stays visible beside Ready; choose a state control to change it. The main window keeps this single discovery stage visible whenever no document is open, and Reduce Motion shows the fully resolved static scene."
                        ),
                        HelpArticleSection(
                            title: "Know what stays editable",
                            body: "Screenshots open in the screenshot editor and Videos open in the video editor. Auto Copy copies the current screenshot after capture and editor changes when enabled. Import an existing image with File > Import Image. Find saved and recoverable screenshot work in the Snip Library."
                        )
                    ],
                    important: [
                        "Screen Recording permission is required before macOS lets SnipSnipSnip capture pixels or show live window thumbnails.",
                        "Support requests and feature requests start from Help > Support."
                    ] + (guideEnabled || scrollingCaptureEnabled || uiMapEnabled
                        ? ["Accessibility permission is required for the enabled workflows that observe other apps, including Guide\(scrollingCaptureEnabled ? ", Scrolling Capture" : "")\(uiMapEnabled ? ", and Window UI Map" : ""). Ordinary Region and Screen screenshots do not require Accessibility."]
                        : []),
                    relatedIDs: ["capture-screenshot", "edit-screenshot", "copy-save-export"]
                ),
                HelpArticle(
                    id: "permissions",
                    title: "Allow permissions",
                    summary: "Understand which macOS permissions are needed and when the app asks for them.",
                    sections: [
                        HelpArticleSection(
                            title: "Screen Recording",
                            body: "Required for screenshot pixels, live window thumbnails, and screen recording. The main capture screen shows the full setup card. While a screenshot, video, or Guide is open, a compact “Screenshot capture unavailable — Set Up” strip remains visible and expands to the full diagnostics when selected or when a capture is attempted.",
                            steps: [
                                "Click Set Up beside Screen Recording in SnipSnipSnip. If macOS does not show a prompt, SnipSnipSnip opens the Screen Recording settings pane.",
                                "Allow SnipSnipSnip in System Settings > Privacy & Security > Screen Recording.",
                                "If SnipSnipSnip shows Restart Required, finish any remaining onboarding permission first if you want it ready too, then use Restart SnipSnipSnip so macOS applies Screen Recording access without the normal quit confirmation."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Audio permissions",
                            body: "Microphone and system audio permissions are optional and are not part of onboarding setup. macOS asks for Microphone only when microphone narration is enabled for a recording or Guide, and asks for system audio only when system audio capture is enabled."
                        )
                    ] + (connectedDeviceCaptureEnabled ? [
                        HelpArticleSection(
                            title: "Camera",
                            body: "Required only when you start a connected iPhone or iPad preview, screenshot, or recording, and it is not part of onboarding setup. macOS exposes trusted iPhone and iPad screens as video sources, so the system permission is named Camera even though SnipSnipSnip is using it for the connected-device screen stream."
                        )
                    ] : []) + (guideEnabled || scrollingCaptureEnabled || uiMapEnabled
                        ? [
                            HelpArticleSection(
                                title: "Accessibility",
                                body: accessibilityUses.joined(separator: " "),
                                steps: [
                                    "Click Set Up beside Accessibility in SnipSnipSnip.",
                                    "Allow SnipSnipSnip in System Settings > Privacy & Security > Accessibility.",
                                    "If SnipSnipSnip is not listed, open the setup guide, choose Reveal App, and add that exact app with the + button."
                                ]
                            )
                        ]
                        : []),
                    important: guideEnabled || scrollingCaptureEnabled || uiMapEnabled
                        ? [
                            guideEnabled
                                ? "Ordinary Region and Screen screenshot capture do not require Accessibility. Guide does require it while capturing a workflow."
                                : "Region and Screen screenshot capture do not require Accessibility.",
                            "In Settings, Set Up starts a missing permission and Manage opens System Settings for a permission that is already allowed.",
                            "Development builds launched from Xcode may need Accessibility permission for the exact app in DerivedData, not a copy in Applications."
                        ]
                        : [],
                    relatedIDs: ["troubleshoot-capture", "privacy"]
                ),
                HelpArticle(
                    id: "quick-controls",
                    title: "Use Quick Controls",
                    summary: "Keep a configurable side dock of familiar SnipSnipSnip actions above other apps.",
                    sections: [
                        HelpArticleSection(
                            title: "Configure and show the dock",
                            steps: [
                                "Choose Quick Controls under Screen Tools in the main window, or choose Show Quick Controls in Settings, the Capture menu, or the menu bar icon.",
                                "Open Settings > General > Quick Controls, then choose Customize Quick Controls when you want to change its controls or presentation.",
                                "Drag the application icon or open space in the dock header to either side of a display. The dock snaps to the nearest screen edge and remembers its edge and vertical position.",
                                "Choose the edge-pointing button to switch between Expanded labeled rows and the space-saving Compact icon rail. The same controls stay in the same order, and the dock always fits them automatically."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Choose and arrange controls",
                            steps: [
                                "Choose the dock menu, then Customize Quick Controls, or use Customize Quick Controls in Settings.",
                                "Use the searchable Controls library. Screenshot, Create, and Record sections keep still-image actions such as Capture Region distinct from time-based actions such as Record Region.",
                                "Choose + to add a control. Added controls expose a direct − button in the library and a Remove button in Selected Control; the final control can be removed too.",
                                "Drag controls within their section in the Dock Preview. Move toward the top or bottom half of a control; the insertion line above or below shows whether the dragged control will land before or after it. You can also select a control and use Move Earlier and Move Later. Drag a section header to rearrange that whole group without changing its internal control order. The preview uses the exact same controls, section order, and presentation as the live dock.",
                                "Under Dock Settings, choose the Compact or Expanded Presentation and the Left or Right Screen Edge. Height and width follow the controls and presentation automatically.",
                                "Choose Close when the layout is ready. Changes are saved immediately. An empty dock offers Customize so you can add controls again. Restore Default Layout asks for confirmation before replacing the layout."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Understand capture and availability behavior",
                            bullets: [
                                "Quick Controls calls the same actions used by the main window, Capture menu, menu bar icon, and existing shared Presets and Timer menus.",
                                "Capture and recording actions become unavailable while another capture, recording, Guide, or connected-device session blocks a new one.",
                                "The dock follows across Spaces and stays above ordinary windows until hidden.",
                                "Quick Controls is excluded from screenshots, Guides, and videos captured by SnipSnipSnip. Other screenshot applications and macOS screenshot shortcuts control their own capture behavior."
                            ]
                        )
                    ],
                    important: [
                        "Hiding Quick Controls keeps the saved layout and settings. Choose Show Quick Controls whenever you want the dock back."
                    ],
                    relatedIDs: ["get-started", "capture-screenshot", "capture-presets"]
                )
            ] + (proUpdateCheckEnabled ? [
                HelpArticle(
                    id: "pro-updates",
                    title: "Update SnipSnipSnip Pro",
                    summary: "Check GitHub Releases for the newest Pro package and download it manually.",
                    sections: [
                        HelpArticleSection(
                            title: "Check for updates",
                            steps: [
                                "Choose Help > Check for Pro Updates, or open Settings > General > Help & Onboarding.",
                                "SnipSnipSnip Pro reads the latest GitHub release and compares it with the version you are running.",
                                "If a newer version is available, choose Download Update to open the GitHub release page.",
                                "Download the newest Pro package from GitHub Releases, quit SnipSnipSnip Pro, and install the package normally."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Current limitation",
                            body: "This checker only notifies you and opens GitHub Releases. It does not install updates automatically. A Sparkle-based updater is planned for a later Pro release."
                        )
                    ],
                    important: [
                        "Only download SnipSnipSnip Pro packages from the official GitHub Releases page or another trusted Oontz link."
                    ],
                    relatedIDs: ["get-started", "troubleshoot-capture"]
                )
            ] : []) + [
                HelpArticle(
                    id: "ui-map",
                    title: "Inspect a UI Map",
                    summary: "SnipSnipSnip Pro can save and inspect structured names, roles, identifiers, hierarchy, and locations of visible interface elements captured with a Window screenshot.",
                    sections: uiMapEnabled ? [
                        HelpArticleSection(
                            title: "Enable UI Map for Window captures",
                            body: "UI Map is a SnipSnipSnip Pro feature. Open Settings > Capture > Advanced and turn on Enable UI Map for Window captures. Window screenshots then try to save available metadata for visible interface elements in the selected window, including names, labels, identifiers, roles, positions, sizes, parent hierarchy, and owning app. This makes a Window screenshot searchable and inspectable as structured interface data, not just pixels. Settings also controls the default visible details for pinned UI Map overlays; only Show outline is enabled by default."
                        ),
                        HelpArticleSection(
                            title: "Capture behavior",
                            bullets: [
                                "UI Map capture runs only during user-initiated Window capture workflows.",
                                "Region, Screen, Scrolling Content, Video, Connected Device, and Screen Inspector captures are visual-only and do not request Accessibility because of UI Map.",
                                "After a Window screenshot opens, the editor command rows and UI Map controls report processing and availability while metadata is captured in the background.",
                                "The screenshot image stays visually unchanged by default.",
                                "If macOS provides interface metadata, SnipSnipSnip saves available names, labels, identifiers, roles, positions, sizes, parent hierarchy, and owning app.",
                                "Cross-app interface trees are available in Pro and development builds after Accessibility consent.",
                                "OCR supplement text is local text recognition used only to add missing visible text to a Window UI Map. It is not treated as a true Accessibility hierarchy.",
                                "Unavailable metadata fields are omitted.",
                                "Turning UI Map off stops new UI Map capture. Existing .sss documents that already contain UI Map metadata still open normally."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Use the panel",
                            steps: [
                                "Open a screenshot that contains UI Map metadata.",
                                "Choose Arrange > Show UI Map, or use the UI Map button in the lower editor command row.",
                                "Search by name, role, label, or identifier, filter by element type, or turn on Pinned Only to show just pinned UI Map overlays.",
                                "Select an element to show its region on the screenshot and inspect its metadata. With a row selected, use the arrow keys to move through the visible tree, expand, or collapse branches.",
                                "Use Show All to outline captured controls and leaf elements without permanently annotating the screenshot. Accessibility elements use blue outlines and OCR supplement text uses orange outlines unless you choose a custom outline color for pinned overlays.",
                                "For Window captures with UI Map available, use the UI Map button to open the panel or the adjacent Pin UI Map tool. Pin UI Map starts with captured element outlines hidden unless Show All is enabled in the UI Map panel. Move over the screenshot to preview an available element, then click to select and pin it; click it again to unpin it.",
                                "Pinned UI Map overlays stay visible in copied, shared, or exported screenshots. You can also pin or unpin the selected element from the inspector or UI Map panel.",
                                "Use Export JSON to save the structured UI Map metadata for debugging, review, or support.",
                                "In the UI Map panel or inspector, use the checkboxes beside the selected element's outline, source, name, accessibility label, identifier, role, value, position, size, owning app, bundle identifier, and parent hierarchy rows to choose what appears in pinned overlays. The outline row also lets you choose the overlay color."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Privacy",
                            body: "UI Map does not capture keyboard input, control other apps, or monitor other apps in the background. UI Map metadata remains local to the .sss document unless you export or share that editable document. Flattened PNG, JPEG, and PDF exports do not include hidden UI Map metadata; pinned UI Map overlays are visible pixels in flattened exports."
                        )
                    ] : [
                        HelpArticleSection(
                            title: "Unavailable in this build",
                            body: "This build does not include UI Map. Documents containing UI Map metadata still open safely, but the UI Map panel and capture options are hidden."
                        )
                    ],
                    important: uiMapEnabled
                        ? ["Editable .sss documents can contain UI Map metadata. Share flattened image exports when you do not want editable document metadata to travel with a screenshot."]
                        : [],
                    relatedIDs: ["capture-screenshot", "privacy", "copy-save-export"]
                ),
                HelpArticle(
                    id: "clipboard-history",
                    title: "Use Clipboard History",
                    summary: "Find copied text, links, images, files, and recent non-private snips in one local timeline.",
                    sections: [
                        HelpArticleSection(
                            title: "Open clipboard history",
                            body: "Clipboard History is optional and off by default. Make an explicit choice during onboarding or enable it in Settings > Snip Library > Clipboard, then choose Clipboard History from the menu bar icon or use Command-Shift-V. Search is focused when the floating window opens. Press Command-W to close the window."
                        ),
                        HelpArticleSection(
                            title: "What appears",
                            body: "Clipboard History saves copied plain and rich text, links, images, PDFs, files, and non-private SnipSnipSnip screenshots. It preserves compatible original clipboard representations so normal paste can retain formatting and multi-item selections. Adding screenshots that were not copied is on by default for new and reset installations, and Settings > Snip Library > Clipboard controls it. Private Capture screenshots are never added."
                        ),
                        HelpArticleSection(
                            title: "Copy and paste actions",
                            body: "Choose Copy to place the selected item on the system clipboard, then switch to the destination and paste with Command-V. Command-Return also copies the selection, and Option-1 through Option-9 copies the matching visible item. Choose Copy Plain Text when you need text without formatting."
                        ),
                        HelpArticleSection(
                            title: "Find and organize items",
                            body: "Search includes item content, source app, type, collections, link metadata, file paths, and locally recognized text inside images and screenshots. Narrow results by type, date, source app, or collection. The detail pane previews content, edits and transforms text, opens links, checks file availability, and adds named collections. Pin durable favorites for quick access."
                        ),
                        HelpArticleSection(
                            title: "Pause and retention",
                            body: "Use the Monitoring menu in Clipboard History or Settings > Snip Library > Clipboard to pause monitoring for five minutes, one hour, or until restart. Settings also controls unpinned item retention, the item and storage targets, and the maximum size accepted for a single item. Permanently deleting history requires confirmation."
                        ),
                        HelpArticleSection(
                            title: "Ignore apps",
                            body: "Open Settings > Snip Library > Clipboard to manage ignored apps. Use Ignore Running App for apps that are currently open, Choose App to pick an app from Applications, or Ignore beside a recent clipboard source."
                        ),
                        HelpArticleSection(
                            title: "Privacy defaults",
                            body: "SnipSnipSnip does not monitor the clipboard or request the history key until Clipboard History is enabled. It skips concealed and transient pasteboard types and ignores Apple Passwords plus common password managers by default. History metadata and stored representations are encrypted on this Mac with a key protected by Keychain, excluded from Spotlight indexing and backup, and never uploaded by Clipboard History. Turning the feature off stops monitoring, unloads decrypted entries and previews, and keeps the encrypted history without loading it or requesting its key on the next launch. Source-app detection remains best-effort because macOS does not identify the source of every copy."
                        )
                    ],
                    important: [
                        "Use Private Capture for screenshots that should stay out of Clipboard History."
                    ],
                    relatedIDs: ["privacy", "copy-save-export"]
                ),
                HelpArticle(
                    id: "screen-ruler",
                    title: "Use Screen Ruler",
                    summary: "Measure pixels on top of other apps with floating horizontal and vertical rulers.",
                    sections: [
                        HelpArticleSection(
                            title: "Add rulers",
                            bullets: [
                                "Choose Screen Ruler under Screen Tools in the main window.",
                                "Choose Screen Ruler from the menu bar icon, directly below Clipboard History.",
                                "Add as many Horizontal or Vertical rulers as you need."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Work with rulers",
                            bullets: [
                                "Drag a ruler to position it. Resize from the three blue grip lines: the right edge for a Horizontal ruler or the bottom edge for a Vertical ruler. The pointer changes to a grab hand over the draggable target.",
                                "Click a ruler once to cycle through tick-edge and zero-origin positions.",
                                "Move the pointer over a ruler to show the current pixel distance when Show Mouse Distance is enabled."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Capture rulers",
                            body: "Screen rulers are real floating overlay windows. If a visible ruler sits inside the area you capture, it is included in region and screen screenshots."
                        ),
                        HelpArticleSection(
                            title: "Configure rulers",
                            body: "Settings > Capture > Screen Ruler controls opacity, tick spacing, major tick frequency, horizontal and vertical tick edges, zero-origin positions, half markers, and mouse-distance labels for all open rulers."
                        )
                    ],
                    important: [
                        "Rulers are measuring overlays, not screenshot annotations. Close them when you do not want them to appear in a capture."
                    ],
                    relatedIDs: ["capture-screenshot", "keyboard-shortcuts"]
                ),
                HelpArticle(
                    id: "screen-inspector",
                    title: "Use Screen Inspector",
                    summary: "Inspect live pixels, coordinates, colors, spacing, and alignment without taking a screenshot.",
                    sections: [
                        HelpArticleSection(
                            title: "Open the inspector",
                            bullets: [
                                "Choose Screen Inspector under Screen Tools in the main window.",
                                "Choose Screen Inspector from the menu bar icon or the Capture menu.",
                                "Use Command-Shift-8 by default, or change the shortcut in Settings > Shortcuts.",
                                "The inspector floats above other apps so you can keep working while it follows the cursor."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Inspect pixels",
                            bullets: [
                                "Choose 2x, 4x, 8x, or 16x zoom.",
                                "Turn the pixel grid and crosshair on or off from the inspector or Settings.",
                                "Resize the inspector window when you need to inspect more screen area at the same zoom level.",
                                "Read display-local pixel coordinates, center-pixel color, and any active point-to-point distance below the magnified view."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Copy, freeze, and capture",
                            bullets: [
                                "Use Copy HEX or Option-Command-H to copy the current center-pixel color as HEX.",
                                "Use Copy RGB or Option-Command-R to copy the current center-pixel color as RGB.",
                                "Use Freeze, Space, or Option-Command-F to hold a static sample while you inspect details.",
                                "Use Measure or Option-Command-M to set the first point at the current cursor, move to the second point, then use Lock or Option-Command-M again to keep the one-line distance measurement.",
                                "Use Capture or Option-Command-S to open the current inspector sample in the editor.",
                                "Close the inspector from the close button, Escape, Command-W, the menu command, the menu bar, or the global shortcut."
                            ]
                        )
                    ],
                    important: [
                        "Screen Inspector samples the live screen. macOS Screen Recording permission is required before other apps' pixels can be inspected."
                    ],
                    relatedIDs: ["screen-ruler", "keyboard-shortcuts", "privacy"]
                )
            ]
        ),
        guideEnabled ? HelpCategory(
            title: "Guide",
            articles: [
                HelpArticle(
                    id: "create-guide",
                    title: "Create an editable Guide",
                    summary: "Turn a workflow into polished step-by-step instructions and tutorials.",
                    sections: [
                        HelpArticleSection(
                            title: "Capture a workflow",
                            steps: [
                                "Choose Record a Guide from the main window or Capture menu, choose Guide > Record a Guide from the menu bar, or press Command-Shift-9.",
                                "Choose what you want to make: an editable step-by-step Guide, or a Guide that also keeps full-motion video for a complete walkthrough or action highlights.",
                                "If you keep video, choose whether it should be silent, use your microphone narration, include app audio, or record narration and app audio together. Guide derives the recording settings from that choice. Audio is captured live; a silent source video cannot be given audio later in the Guide editor.",
                                "Choose Number each step to make every captured step start with a visible number. Leave it off for unnumbered steps. In either case, you can show or hide the number later for any individual step in the Step inspector.",
                                "Choose Show action crosshairs to mark where each captured action happened. Leave it off for clean steps without crosshairs. You can show or hide the crosshairs later for any individual step in the Marker section of the Step inspector.",
                                "Choose Region, Window, App, or Screen in Record a Guide. These match the capture terms used in the main window; App additionally follows you between one app’s windows. This choice controls how Guide follows your work, but it does not select the exact target yet. Window and App Guides automatically follow the active source when it moves, resizes, or crosses onto a mixed-scale or rotated display.",
                                "Review the plain-language capture summary, or expand Fine-tune capture for optional video smoothness, pointer, desktop cleanup, on-device instruction, secure-field, and display menu-bar choices. Hover over any choice for a plain-language explanation; the defaults work well for most Guides.",
                                "Choose Start Guide, then select the live target on screen. Draw a Region; hover and click a Window; click any window belonging to an App; or click a Screen when more than one display is connected. Window and App also offer Choose from List when the target is hidden or easier to recognize by name. Escape returns to Record a Guide without losing the choices you already made. A Guide region stays on the display where the drag begins; the selector visibly clamps it at that display edge. Ordinary screenshot regions may still span displays. Screen capture includes every visible app—even SnipSnipSnip itself when you are demonstrating it—while keeping the floating Guide controls out of the result.",
                                "Work normally. One click, double-click, text selection, scroll burst, three-finger swipe, non-secure text-entry burst, supported keyboard shortcut, or Manual Step creates one step. Guide waits briefly after a swipe so a transition between Spaces can finish before it saves the step. Printable typing is captured even in custom and web editors that do not expose a standard macOS text value. When a non-secure focused field does expose its value, paste, dictation, and input-method edits are detected too. Text changes are grouped into one step after about 0.65 seconds without a change rather than creating a step per key.",
                                "Use the floating HUD to pause, add a manual step, delete a recent step, stop, or discard. Discard closes the HUD immediately while Guide removes the live capture and its recovery checkpoint. Its System Audio and Mic controls use the same live meters and switches as the recording controls; turn either source on or off for the active Guide while it is capturing. The newest 20 step previews stay available in the HUD without making a long session progressively heavier; all earlier steps remain in the Guide. Hover a preview to see a larger version with its step number and captured instruction. When source video needs a moment to close safely, the HUD replaces the capture timer with the real finalization stage: stopping media, preparing the document, rendering the preview, or saving recovery. It does not invent a time estimate.",
                                "Guide checks capture permissions and temporary storage during long sessions. If permission changes, the capture stream stops, or disk headroom becomes low, Guide pauses and explains the issue in the HUD. Restore the permission or free space, then choose Resume; completed steps and finalized video segments stay intact.",
                                "Stop always ends capture. If no steps were captured, it discards the empty Guide instead of opening the editor.",
                                "Press Command-Shift-9 again to stop and open the Guide editor."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Why the permissions are needed",
                            body: "Screen Recording provides local image and optional source-video frames. Accessibility observes actions and keyboard focus so Guide can create useful captions, group non-secure text entry, and mask secure fields. If either permission changes during capture, Guide pauses instead of silently dropping steps. After access is restored, Resume creates a fresh capture stream and continues the same Guide."
                        ),
                        HelpArticleSection(
                            title: "Edit without production work",
                            bullets: [
                                "Reorder, search, duplicate, delete, restore, include, or exclude steps in the left pane. Deleted steps are crossed out and marked Deleted; Control-click one and choose Restore to bring it back.",
                                "The inspector opens on Step and returns there whenever you select another step. Edit the instruction, action, duration, export inclusion, step number, marker, action crosshairs, screenshot, and optional internal note without digging through Guide-wide styling.",
                                "Choose Guide at the top of the inspector to edit the title, theme, appearance, colors, video click pulses, screenshot shadows, branding, and advanced style shared by every step. The Theme menu can save the current theme or make its organization, logo, copyright, legal statement, and styling the default for new Guides.",
                                "Guide uses the detected clicked control and available screenshot space to place a numbered marker outside the control when space allows, while keeping it inside the screenshot. Turn Show step number or Show action crosshairs off when a particular step reads better without them. The crosshairs use transparent rings so the clicked content remains visible. In the preview, drag the action handle to point at a different action, or drag the handle around a visible number to move it; the marker follows the pointer throughout the drag. Deleted steps are skipped when Guide calculates step numbers; hiding a number does not renumber the other steps.",
                                "Choose Edit Screenshot when a step needs the full screenshot annotation toolset. The familiar two editor command rows appear with direct tool buttons; choose a tool, make the edits, then select Apply to Step. Cancel leaves the step unchanged.",
                                String(localized: "Use Steps to arrange captures you already have. Use Guide to record a workflow automatically."),
                                String(localized: "Guide remains separate from the manual Steps workflow. Guide can also capture source video, audio, actions, and markers."),
                                "Save the editable project as .sssguide. Existing .sss and .sssvideo documents are unchanged."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Reuse company branding",
                            body: "Open Settings > Guide > Default Brand Profile to set an organization name, logo, copyright footer, and longer legal statement once. SnipSnipSnip copies that profile into every new Guide, including Guides started by automation. Each .sssguide remains self-contained, so changing the default later does not rewrite existing documents and shared Guide packages keep the branding they were created with."
                        ),
                        HelpArticleSection(
                            title: "Export and share",
                            bullets: [
                                "Click Export to choose one or more formats. The sheet groups formats by purpose: Documents (PDF and Word Document), Animated sharing (GIF and APNG), Video (Full Motion, Action Highlights, and Step Slideshow MP4), and Files and packages (step images and ZIP). PDF and GIF are selected by default. PDF and Word exports use print-quality stills to keep captured interface text sharp. The format choices live in this export sheet, not the editor inspector.",
                                "Choose whether to show the separate export-progress window. It reports the active format plus real step, segment, encoder, ZIP-entry, or byte progress. Work without a measurable fraction uses an activity indicator and a concrete stage such as Finalizing video. You can cancel a long or multi-format export while keeping completed top-level files. Each file is written to a temporary sibling and replaces the destination only after it finishes, so cancellation, an encoder failure, or app interruption does not overwrite an earlier good export. ZIP uses ZIP64 for large media and succeeds only when every selected nested format succeeds. Stale partial export files are cleaned up automatically.",
                                "Full Motion preserves capture chronology. Other step-based exports use the current Guide order. Video click highlights appear only as a brief pulse at each click and obey the current Guide's Show click target highlights setting.",
                                "Full Motion and Action Highlights require source video and include captured microphone or system audio. Slideshow MP4 remains available when source video is off.",
                                "After export, share through the native share sheet, copy the exported files, or reveal them in Finder for Mail, Messages, Slack, Notion, and other standard destinations."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Privacy and recovery",
                            bullets: [
                                "Guide does not upload screen images, source media, metadata, OCR, or captions.",
                                "Secure text values are never retained and detected secure fields receive an editable solid mask by default.",
                                "Private Guide skips Snip History, Clipboard History, OCR indexing, AI caption refinement, and content diagnostics.",
                                "Completed steps and finalized media segments are autosaved incrementally so an interrupted capture can be recovered without rewriting every earlier image after each action.",
                                "When you quit during a recoverable active Guide, choose Stop & Quit, Keep Capturing in Background, or Cancel. Restart offers Stop & Restart or Cancel. The app does not show a second ordinary quit confirmation after this Guide decision. If the final checkpoint fails, the Guide opens and the app stays running instead of risking the session.",
                                "Private Guide intentionally has no automatic recovery checkpoint. Quit and restart offer Open Guide & Stay, Discard and continue, or Cancel; the app never claims private work was saved for recovery.",
                                "The exact captured crop is stored with each video segment, so cursor placement and video orientation remain correct on mixed-scale or rotated displays even if the display arrangement changes before export."
                            ]
                        )
                    ],
                    important: [
                        "Guide groups ordinary typing in supported non-secure text fields into one step after a brief pause. It never stores the typed characters in the step caption, and secure input is ignored.",
                        "Keeping full-motion video can use substantial storage during long sessions. The setup summary shows an estimate before capture starts; Guide checks headroom before and during capture, and a step-by-step Guide does not retain source video or audio.",
                        "Two-hour sessions and Guides with hundreds of steps are supported. Pauses do not create empty media, step images use compressed backing stores, editor thumbnails load progressively for selected and visible rows, and exports render incrementally to keep memory use stable."
                    ],
                    relatedIDs: ["permissions", "copy-save-export", "privacy"]
                )
            ]
        ) : HelpCategory(
            title: "Guide",
            articles: [
                HelpArticle(
                    id: "create-guide",
                    title: "Open and edit an existing Guide",
                    summary: "Use this App Store edition with editable .sssguide documents created in SnipSnipSnip Pro.",
                    sections: [
                        HelpArticleSection(
                            title: "Open a Guide",
                            body: "This App Store edition does not capture new Guides, and it does not request Accessibility access. It keeps the Guide document model and editor so existing .sssguide files remain useful.",
                            steps: [
                                "Choose File > Open, or open a .sssguide file from Finder.",
                                "The first successfully opened Guide shows a one-time explanation that Guide creation is available in the free direct-download Pro edition.",
                                "Continue editing, saving, recovering, and exporting the Guide normally."
                            ],
                            links: [
                                HelpArticleLink(title: "Learn about SnipSnipSnip Pro", url: AppLinks.snipSnipSnipProduct)
                            ]
                        ),
                        HelpArticleSection(
                            title: "Edit and export",
                            bullets: [
                                "Reorder, search, duplicate, delete, restore, include, or exclude steps.",
                                "Edit instructions, markers, screenshots, branding, themes, and other saved Guide settings.",
                                "Save changes back to the editable .sssguide package or use Save As to create a copy.",
                                "Export the formats supported by the opened Guide, including document, image, package, and available video formats."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Compatibility and privacy",
                            body: "Opening and editing a Guide does not inspect other apps. SnipSnipSnip preserves the existing .sssguide package format so documents can move between the App Store and Pro editions without conversion."
                        )
                    ],
                    important: [
                        "Guide creation, live action monitoring, and dedicated Guide automation are available only in SnipSnipSnip Pro.",
                        "The App Store edition never asks for Accessibility access."
                    ],
                    relatedIDs: ["copy-save-export", "privacy"]
                )
            ]
        ),
        HelpCategory(
            title: "Capture and record",
            articles: [
                HelpArticle(
                    id: "capture-screenshot",
                    title: "Take a screenshot",
                    summary: "Capture a region, window, screen image, or repeat a previous capture.",
                    sections: [
                        HelpArticleSection(
                            title: "Capture a region",
                            steps: [
                                "Choose Region from the main window, menu bar icon, Capture menu, or global shortcut.",
                                "Drag the area you want to capture over the live desktop. The loupe refreshes while you aim without including capture overlay graphics.",
                                "Single-click a visible window instead of dragging to capture that window.",
                                "A screenshot region may span connected displays.",
                                "By default, releasing the mouse captures immediately. If Always Capture on Mouse Up is off, click Capture in the floating controls."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Use precision region controls",
                            body: "Settings > Capture offers three region commit modes. Capture Immediately finishes as soon as you release the pointer. Show Capture & Cancel pauses with simple confirmation controls. Show Precision Controls adds handles, numeric width and height, aspect-ratio lock, arrow-key nudging, Return to capture, and Escape to cancel. Existing preferences and presets keep their prior behavior."
                        ),
                        HelpArticleSection(
                            title: "Capture a window",
                            steps: [
                                "Choose Window.",
                                "From Window in the capture header or from the menu bar, use the quick menu to choose Pick On Screen, a suggested window, or More Windows.",
                                "The startup screen keeps the live-window carousel visible for one-click capture. Pick a thumbnail directly or use Pick On Screen for crowded desktops.",
                                "Use Refresh or Auto Refresh if the target window is visible but not listed. With Auto Refresh off, SnipSnipSnip still refreshes once whenever the app returns to the foreground."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Capture the screen",
                            body: "Choose Screen to use your screen-capture setting in Settings > Capture. \(fullscreenDisplayMode.detail) Choose Repeat Last Capture or press Command-Shift-7 to rerun the previous capture when the target can still be found. When captured content opens or resizes the editor, the main window keeps the placement you chose and only moves as much as needed to remain on-screen."
                        ),
                    ] + (connectedDeviceCaptureEnabled ? [
                        HelpArticleSection(
                            title: "Connected devices",
                            body: "Capture > Capture Connected Device scans for trusted USB iPhone and iPad sources when the menu opens. Choose a device to open a live preview, then capture the latest visible frame, copy it, save it, or open it in the screenshot editor. The first preview can ask for Camera access because macOS exposes trusted iPhone and iPad screens as video sources. Keep the device awake and unlocked. If the phone or tablet was just connected, unlocked, trusted, or reconnected, choose Refresh Devices."
                        )
                    ] : []) + [
                        HelpArticleSection(
                            title: "Use a timer",
                            body: "Choose a 3, 5, or 10 second timer from the Capture menu or menu bar extra when you need time to stage the screen before capture. For Region, Pick On Screen window capture, and Scrolling Content, select the target first; SnipSnipSnip then shows the countdown and takes the snapshot when it reaches zero. Screen, repeat, frontmost-window, and direct window captures count down immediately before reading pixels."
                        ),
                        HelpArticleSection(
                            title: "Use capture presets",
                            body: "After a region, window, frontmost-window, screen, or Screen Inspector snip, choose Presets > Save Last Capture as Preset to create a workflow. Give it a recognizable name, icon, and color; that colored badge identifies the preset consistently in capture menus and Settings. Then choose whether it opens in the editor, copies directly to the clipboard, or exports a rendered PNG, JPEG, or PDF to a folder you choose. You can assign a Command-Shift global shortcut; SnipSnipSnip checks built-in actions and other presets before saving it. Presets remember the screenshot source, timer, cursor option, screen display choice, region controls, and Window UI Map option used for that capture. Private Capture stays controlled by the current Privacy setting and is not saved inside presets. Run saved workflows from the main window, Capture menu, menu bar extra, or assigned shortcut; favorites appear first. If a saved region no longer fits the current display layout, SnipSnipSnip opens the region selector with the saved size so you can reposition it. If a saved window is not available, choose a replacement window to update and run the preset."
                        ),
                        HelpArticleSection(
                            title: "Recover from a capture problem",
                            body: "When a capture cannot finish, SnipSnipSnip keeps the selected target and shows the quickest recovery choices instead of making you start over. Depending on the issue, you can set up a missing permission, refresh or replace a window, retry the same capture, use the current display, or capture the visible area instead."
                        ),
                        HelpArticleSection(
                            title: "Include an editable cursor",
                            body: "Turn on Include Cursor from the Capture menu, menu bar extra, or Settings > Capture. Region, window, frontmost-window, screen, and repeat screenshots add the cursor as an editable overlay that you can move, resize, fade, or delete. Region capture follows the selected region commit mode in Settings. Scrolling Capture always excludes the cursor while stitching."
                        )
                    ],
                    important: [],
                    relatedIDs: scrollingCaptureEnabled ? ["capture-scrolling", "keyboard-shortcuts", "edit-screenshot"] : ["keyboard-shortcuts", "edit-screenshot"]
                )
            ]
            + (scrollingCaptureEnabled ? [
                HelpArticle(
                    id: "capture-scrolling",
                    title: "Capture scrolling content",
                    summary: "Capture a long page, document, or list as one editable screenshot.",
                    sections: [
                        HelpArticleSection(
                            title: "Before you begin",
                            body: "Scrolling Capture requires Accessibility permission because SnipSnipSnip must scroll the selected app while it captures and stitches segments. It works best with stable pages, documents, and lists; highly animated content, sticky overlays, and protected windows can make it less reliable."
                        ),
                        HelpArticleSection(
                            title: "Capture a scrollable area",
                            steps: [
                                "Choose Capture Scrolling Content.",
                                "Drag over a scrollable area within one display. The selector uses the same crosshair, live loupe, and precision-control preferences as Region Capture.",
                                "Confirm the detected app and selected viewport, or choose another area before capture starts. Turn off Show this again if you want future scrolling captures to start immediately after selection.",
                                "Wait while SnipSnipSnip scrolls and captures segments. The progress panel shows the captured length, capacity remaining, a stitched preview, and any quality warning.",
                                "Press Esc to cancel, or press Return or click Done to stop early and use the segments already captured."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Keep useful partial results",
                            body: "If later frames cannot be stitched or capture is interrupted after useful content was collected, choose Keep Partial Result to open what was captured. SnipSnipSnip labels it as partial and recommends reviewing seams before sharing. You can also retry the same area or capture only the visible area."
                        ),
                        HelpArticleSection(
                            title: "Best results",
                            bullets: [
                                "Start with the content positioned at the beginning of the area you need.",
                                "Avoid changing the target window while capture is running.",
                                "If a page has heavy animation or sticky overlays, try a smaller selection."
                            ]
                        )
                    ],
                    important: [
                        "The scrolling viewport must stay within one display.",
                        "Some apps, protected windows, and highly dynamic pages may not scroll or stitch reliably."
                    ],
                    relatedIDs: ["permissions", "troubleshoot-capture", "capture-screenshot"]
                )
            ] : [])
            + [
                HelpArticle(
                    id: "record-video",
                    title: "Record the screen",
                    summary: "Record a region, window, or screen and trim the video before export.",
                    sections: [
                        HelpArticleSection(
                            title: "Start and control a recording",
                            steps: [
                                "Choose Record Region, Record Window, or Record Screen.",
                                "Record Region and Pick On Screen recording start from the live desktop selection overlay, with the live loupe available while you aim. Drag to choose a custom region, or click a window to record the whole window.",
                                "Use the floating recording control to Pause, Resume, or Stop. The System and Mic meters show live signal when those sources are enabled.",
                                "When the recording finishes, use the video editor to review and trim the result."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Choose recording options",
                            body: "Open Settings > Video to set the default quality, frame rate, display used for Screen recording, cursor visibility, click rings, system audio, and microphone narration. During an active recording, use the floating recording control's color-coded System Audio and Mic switches to turn those sources on or off for that recording only. The meters below those switches confirm whether each enabled source is receiving signal."
                        ),
                        HelpArticleSection(
                            title: "Quit, restart, and recover",
                            body: "If you quit during a recording, choose Stop & Quit, Keep Recording in Background, or Cancel. Restart offers Stop & Restart or Cancel. Stop first enters Finishing, preserves the Video for recovery, and exits only after that checkpoint succeeds. Unsaved Videos are also preserved when the app exits. On the next launch, use Recover Last Session to reopen the Video; the recovery remains available until you save the Video or explicitly discard it."
                        ),
                    ] + (connectedDeviceCaptureEnabled ? [
                        HelpArticleSection(
                            title: "Connected-device recording",
                            body: "Choose Record Connected Device; the menu scans for trusted USB iPhone and iPad sources as it opens. Pick a device, then use the preview window to start and stop recording. The first preview can ask for Camera access because macOS exposes trusted iPhone and iPad screens as video sources. Keep the device awake, unlocked, and connected until recording is stopped. Finished MP4 recordings open in the normal video editor for poster frames, trimming, and export."
                        )
                    ] : []) + [
                        HelpArticleSection(
                            title: "Export video",
                            body: "Use the video editor Export menu or File > Export to export MP4 using a quality preset or a size-limited target, or export short silent loops as GIF or APNG. Size-limited exports retry at a lower bitrate if the result exceeds the selected cap. Drag the file icon beside Export to send the current trimmed export to Finder, Mail, or another app. Click the icon without dragging to see a short reminder. The editor window temporarily hides during the drag and returns when the drag finishes. Encoding begins after the destination accepts the drop."
                        )
                    ],
                    important: [
                        "A region video recording must stay within one display.",
                        "SnipSnipSnip checks temporary storage before recording and during long recordings so it can stop safely before disk pressure causes a failed write.",
                        "If ScreenCaptureKit stops unexpectedly, SnipSnipSnip enters Finishing and opens any usable captured footage instead of leaving the recording control in a false Recording state."
                    ],
                    relatedIDs: ["copy-save-export", "permissions"]
                )
            ]
        ),
        HelpCategory(
            title: "Edit screenshots",
            articles: [
                HelpArticle(
                    id: "edit-screenshot",
                    title: "Use the screenshot editor",
                    summary: "Work non-destructively with tools, selections, style controls, and history.",
                    sections: [
                        HelpArticleSection(
                            title: "Choose a tool",
                            body: "The first Edit command row keeps Select, Crop, the Arrow family, and Text visible as labeled one-click controls. Open the Arrow disclosure menu to choose Arrow or Numbered Arrow. Split controls also provide Shapes (Rectangle, Ellipse, Line, and Status Mark), Draw (Freehand and Highlighter), Emphasize (Highlight Box, Spotlight, and Ruler), Redact (Blur, Pixelate, and Redact), and More Tools (Callout, Copy Text, Pick Color, and Insert Image). After you choose a tool that remains active, the main button shows that tool’s name and icon and reuses it when clicked. Use the adjacent disclosure arrow to choose a different member of the group. Insert Image remains a one-time action. The active direct tool or group has a filled background and stronger boundary as well as its accessibility state. Review, Order & Caption, Arrange, and Polish still begin with Discard. The second Edit row keeps History, Layers and Arrangement, Zoom, Inspector, Output, and References and Drag Out in workflow order. At narrow widths, scroll each row horizontally without losing any action."
                        ),
                        HelpArticleSection(
                            title: "Select and arrange annotations",
                            body: "Select one or more annotations to move, resize, rotate 90 degrees, group, ungroup, align, or delete them. Use the trash button in Layers and Arrangement, press Delete, or right-click an annotation and choose Delete. Click an empty area with the Select tool or choose Edit > Unselect to clear the current selection. Snap guides appear while drawing, moving, and resizing.",
                            bullets: [
                                "With VoiceOver or Full Keyboard Access, Tab and Shift-Tab traverse annotations from front to back. Space selects and Shift-Space toggles additive selection; Escape returns focus to the canvas.",
                                "Arrow keys move a selected annotation by 1 pixel and Shift-arrows move it by 10. Option-arrows resize by 1 pixel and Shift-Option-arrows resize by 10.",
                                "Each accessible annotation provides actions for selection, editing text when applicable, duplication, deletion, layer ordering, and grouping. Redacted content is never announced.",
                                "Layers remains the complete accessible alternative for selection and arrangement."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Use the inspector",
                            body: "The native right inspector keeps Crop Image, Properties, and History directly visible. Crop Image opens exact crop controls without changing the selected annotation tool. Properties shows only controls for the current tool or selection and names that context, such as Arrow, Text, or Selection. History uses the full inspector for Change History and the Snip Library instead of stacking them beneath editing controls; the History button includes the current document’s change count. Crop handles remain available on the image while any annotation tool is selected, and crop changes apply immediately through normal undo. Comparison, Steps, Arrange, Look, and Mockup continue to show their stage-specific inspector. The inspector is visible by default and remembered for each window scene. Use the Inspector control immediately after Zoom, or View > Show/Hide Inspector (Command-Option-I), to toggle it."
                        )
                    ],
                    important: [
                        "The editor keeps the base screenshot separate from annotation state. Copy, Share, Export, Float, and Drag always use the output shown in the active Edit, Review, Steps, Arrange, or Polish stage."
                    ],
                    relatedIDs: ["floating-references", "crop-navigate", "annotate-style", "redact"]
                ),
                HelpArticle(
                    id: "compose-screenshots",
                    title: String(localized: "Compare, explain, or combine captures"),
                    summary: String(localized: "Choose what you want to make, then see only the controls that help finish it."),
                    sections: [
                        HelpArticleSection(
                            title: String(localized: "Choose what to make"),
                            steps: [
                                String(localized: "Use Quick Capture when you want a one-action Screenshot from Region, Window, Screen, Scrolling Content, a repeat, or a preset. Scroll and Repeat Last are direct actions; Presets stays in its own menu. Under Create, choose Comparison, Steps, or Combined Image to open setup with the result already selected. Under Record, choose Region, Window, Screen, Guide, or an available connected device directly. Use Screen Tools for Screen Ruler, Screen Inspector, and Quick Controls, and open Clipboard History beside them."),
                                String(localized: "To explain a process, choose Record a Guide for action-aware capture or Build Steps manually to add and caption each step yourself."),
                                String(localized: "Choose where the first image will come from: Region, Window, Screen, or Existing Image. Existing Image includes files, the clipboard, and the Snip Library. The Snip Library picker keeps the list beside a large scrollable and zoomable preview. Use Screenshot preserves editable captures by default; turn on Use Rendered Image Only only when you want a flattened image. More ways to capture keeps specialized acquisition methods out of the main decision. Fine-tune appears only when the selected source has optional settings."),
                                String(localized: "Review the summary and use the single primary action. Cancelling setup, target selection, permission setup, or capture leaves the current document and preferences unchanged.")
                            ]
                        ),
                        HelpArticleSection(
                            title: String(localized: "Add the first extra capture"),
                            body: String(localized: "Choose Add in a one-image Screenshot. The chooser explains each result: Compare shows Before and After together or highlights changes; Add as Step puts captures in order for captions and numbering; Combine arranges captures and images as one result. Region is ready by default, and the menu can preselect another source. The purpose changes only after the source is added successfully, and Undo returns to the original Screenshot. Later additions inherit the purpose without asking again. Option-Command-A invokes the same contextual action.")
                        ),
                        HelpArticleSection(
                            title: String(localized: "Follow the session"),
                            body: String(localized: "While a screenshot document is open, the header names its purpose and the next useful action. After you capture Before for a Comparison, Repeat Last Capture for After repeats the same source by default; open its menu to choose another source. Other stages use Capture After, Add Step, Add Image, Review Changes, Order & Caption, Arrange, or Back to Content. Global Capture-menu commands and shortcuts continue creating new Screenshot documents.")
                        ),
                        HelpArticleSection(
                            title: String(localized: "Arrange a combined image"),
                            body: String(localized: "Combined Image offers Auto, Row, Column, Grid, Freeform, and compatible templates. Auto chooses a useful arrangement from item count and image shapes. Reorder items on the canvas or in Items, and adjust Fit, Fill, alignment, framing, captions, replacement, duplication, visibility, and removal. Freeform expands automatically until you set an explicit size. Trim to Items removes unused bounds and Auto Expand restores growth. Arrow keys move selected items; Option-arrows resize them; add Shift for 10-pixel changes. Align, Distribute, Match Size, and numeric geometry provide complete keyboard alternatives.")
                        ),
                        HelpArticleSection(
                            title: String(localized: "Style the composition canvas"),
                            body: String(localized: "Choose Apply Theme for a complete Clean, Cards, Dark, or Documentation appearance, then refine padding, gaps, fill, borders, corners, captions, and title type. Advanced Appearance exposes panel fill and shadow, caption and title backgrounds and padding, step badge colors and size, connector styling, and the comparison divider. Saving a composition template preserves this appearance together with the layout.")
                        ),
                        HelpArticleSection(
                            title: String(localized: "Reuse a composition template"),
                            body: String(localized: "Choose a built-in template for an adaptable Grid, comparison, Steps sequence, or Freeform board. Open Manage Templates to save the current structure and appearance, then rename, duplicate, delete, import, or export it. Saved templates require the same item count; built-in templates adapt to the compatible count. Templates never include captures, item identities, the composition title, or item captions.")
                        ),
                        HelpArticleSection(
                            title: String(localized: "Edit the right level"),
                            bullets: [
                                String(localized: "Arrange changes item order, size, framing, and placement."),
                                String(localized: "Choose Edit Selected Capture, double-click an item, or press Return to crop and annotate only that source. Done returns to the same goal stage with the item selected. Press Option-Return to adjust framing, then Escape to finish."),
                                String(localized: "Choose Annotate Result to place annotations above the arranged items and below optional Polish. Anchored endpoints follow their items through layout changes; Pin Selection to Canvas keeps them in the overall result. Canvas bounds remain in Arrange."),
                                String(localized: "Paste adds an item while Arrange owns focus, an item overlay while Edit Selected Capture is active, and a whole-result overlay while Annotate Result is active.")
                            ]
                        ),
                        HelpArticleSection(
                            title: String(localized: "Compare two items"),
                            body: String(localized: "Comparison consistently uses Before and After. Show Both starts with side-by-side output, Highlight Changes uses automatic registration and local change detection, and Alternate switches between the images. More Options retains Overlay, Wipe, Difference, Blink, sensitivity, unchanged-content dimming, outline or pattern cues, timing, and poster-frame controls. Manual offsets remain available if automatic alignment is not reliable. Reduced Motion stops automatic Blink preview without changing exported timing.")
                        ),
                        HelpArticleSection(
                            title: String(localized: "Build a manual step sequence"),
                            body: String(localized: "Steps orders captures you already have, adds automatic numbers and captions, and supports row, column, or grid flow. Reordering, excluding, or removing an item renumbers the sequence. Steps is separate from Guide: use Steps to assemble existing captures, and use Guide when you want SnipSnipSnip Pro to observe a workflow and create action-aware steps automatically.")
                        ),
                        HelpArticleSection(
                            title: String(localized: "Export stills, pages, and animation"),
                            body: String(localized: "Copy, Share, Export, Float, and Drag use the visible stage. Edit, Review, Steps, and Arrange output unwrapped content; Polish outputs the visible Look or Mockup. PNG, JPEG, and PDF include the complete result and annotations. Before an oversized raster is created, choose Scale to Fit; a Steps PDF also offers Paginated PDF. Blink exports deterministic GIF, APNG, and MP4 output using its interval, crossfade, and loop settings, with a disclosed 4,096-pixel longest-side cap. Static Blink output defaults to After.")
                        ),
                        HelpArticleSection(
                            title: String(localized: "Export interactive HTML"),
                            body: String(localized: "Interactive HTML is one offline file. During export, an in-editor progress panel reports preparation, image encoding, assembly, and saving with a real percentage and Cancel Export; cancellation leaves any existing destination unchanged. Steps preserves decimal, letter, Roman, starting-value, or hidden numbering and includes step links, Previous and Next controls, and direction-aware Left and Right Arrow navigation. A Comparison opens in the view chosen in SnipSnipSnip, then Compare Using lets viewers switch among Side by Side, Wipe, Overlay, Blink, Difference, and Highlight Changes. Wipe supports direct divider dragging and direction choices. Fit keeps the complete active comparison area in view—including viewer controls and status—without shrinking the branding footer. Zoom keeps Before and After synchronized, and the file URL remembers the chosen view and adjustments. Difference and Highlight Changes use exact fully rendered, redaction-safe results. Blink keeps manual, timing, and playback controls. With Reduce Motion, Blink starts paused and offers Play Anyway when the viewer intentionally wants animation. Printing shows every step, and without JavaScript the selected static view remains visible. The file embeds full-dimension, losslessly optimized PNG images, escapes titles and captions, includes no source paths or capture metadata, loads no remote scripts, fonts, images, storage, or analytics, and uses a deny-by-default Content Security Policy. The outer page uses a subtle version of SnipSnipSnip's line-and-dot motif, and a small embedded app logo sits beside the linked attribution. The pattern is removed for print and Increased Contrast, and the file makes no network request unless the website link is chosen.")
                        ),
                        HelpArticleSection(
                            title: String(localized: "Private compositions"),
                            body: String(localized: "Adding an item captured in a Private Capture session permanently marks the entire composition Private, even if that item is later removed. A Private composition remains editable and can be explicitly saved or exported, but it stays out of Snip History, Recent Snips, the Recycle Bin, Clipboard History ingestion, OCR indexing, content diagnostics, and telemetry.")
                        )
                    ],
                    important: [
                        String(localized: "Every item keeps its own base image, crop, and annotations. Composition annotations remain a separate editable layer above all items."),
                        String(localized: "Opening an editable multi-item .sss restores its Comparison, Steps, or Combined Image purpose and focused content stage."),
                        String(localized: "Cancelling an Add, Replace, or Change Goal operation leaves the document unchanged.")
                    ],
                    relatedIDs: ["edit-screenshot", "copy-save-export", "create-guide", "privacy"]
                ),
                HelpArticle(
                    id: "floating-references",
                    title: "Float a reference screenshot",
                    summary: "Keep a rendered screenshot visible above other apps while you work.",
                    sections: [
                        HelpArticleSection(
                            title: "Create a floating reference",
                            bullets: [
                                "Click Float in a content stage to pin the annotated screenshot or assembled result without Polish.",
                                "Click Float in Polish to pin the visible Look or Mockup preview.",
                                "Choose Reference > Float Current Screenshot when you prefer the menu command; it follows the active editor workspace.",
                                "Open a Change History, Recent Snip, Snip History, or Recycle Bin preview and click Float Reference to pin that snapshot."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Work with the floating window",
                            bullets: [
                                "Drag the handle at the left of the top bar to move the reference and resize it from the window edges.",
                                "The Zoom menu shows the current percentage and includes Zoom In, Zoom Out, Actual Size (1:1), and Fit to View.",
                                "Scroll to pan around a zoomed image, pinch to zoom with a trackpad, or Command-scroll or Option-scroll to zoom.",
                                "Turn on Resize Window for Zoom when you want zoom changes to resize the reference window around the current image scale.",
                                "Manual zoom levels stay at their selected image scale while the floating window is resized. Fit to View follows the window size.",
                                "When the reference image leaves empty space, the same editor line-and-dot background marks the area outside the image.",
                                "Click or drag the opacity track when the reference should stay visible but less distracting. Click the opacity icon to return to 100%.",
                                "SnipSnipSnip keeps up to eight floating references open at once. Opening another reference closes the oldest one."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Close or recover controls",
                            body: "Close one reference with the x button. Use Reference > Close All Floating References or the same command from the menu bar icon when several references are open."
                        )
                    ],
                    important: [
                        "Floating references are alternate views only. They do not duplicate files or change the editable .sss document.",
                        "Each floating reference is a snapshot of the rendered image at the moment you float it."
                    ],
                    relatedIDs: ["edit-screenshot", "history-recovery", "copy-save-export"]
                ),
                HelpArticle(
                    id: "crop-navigate",
                    title: "Crop and navigate",
                    summary: "Adjust the visible area and move around the canvas without changing screenshot pixels.",
                    sections: [
                        HelpArticleSection(
                            title: "Crop a screenshot",
                            steps: [
                                "Drag a crop handle on the visible image perimeter.",
                                "Use the loupe and live pixel size to refine the crop.",
                                "Choose Crop Image at the top of the inspector for exact X, Y, Width, and Height values. This does not change the selected annotation tool.",
                                "Choose Freeform or a fixed aspect ratio in Crop Image before drawing or resizing the crop.",
                                "Click Auto Crop to tighten the current crop around screenshot content and visible annotations, or click Padded to keep a small margin.",
                                "Click Reset Crop to return to the full captured image.",
                                "Crop changes apply immediately and remain available through Undo and Change History."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Move around the canvas",
                            bullets: [
                                "Use the lower editor command row's Zoom Out, percentage, Zoom In, Fit to Window, or Actual Size controls. Fit scales the full editable image into view.",
                                "Use pinch zoom, Command-scroll, or Option-scroll to zoom.",
                                "Use two-finger or mouse-wheel panning and the visible scroll tracks to pan."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Crop aids",
                            body: "Settings includes Crop Outside Dimming and out-of-capture crosshatch controls. These editor aids are never burned into screenshot or composition pixels. Interactive HTML uses a separate fixed line-and-dot page background for branding; these settings do not alter it."
                        )
                    ],
                    important: [],
                    relatedIDs: ["edit-screenshot", "copy-save-export"]
                ),
                HelpArticle(
                    id: "annotate-style",
                    title: "Add and style annotations",
                    summary: "Use shapes, text, callouts, image overlays, measurements, and color sampling.",
                    sections: [
                        HelpArticleSection(
                            title: "Add annotations",
                            body: "Draw shapes, lines, arrows, numbered arrows, checkmarks and X status marks, freehand strokes, marker-style highlighter strokes, highlight boxes, rulers, spotlights, text, and callouts from the top editor command row. For Numbered Arrow, drag from the numbered badge toward the target. Each new Numbered Arrow receives the next number in the current annotation scope. Status Mark offers Circled, Cartoon, and Vintage treatments in the inspector, along with the standard color controls. Text boxes and callouts fit snugly while you type until you manually resize them; after a manual resize, their width stays fixed and they grow taller as text wraps. Selected text boxes and callouts can be edited in place with normal cursor movement, arrow keys, selection, and click-to-position behavior. Insert Image adds an editable overlay that can be moved, resized, rotated, faded, saved, copied, exported, and shared."
                        ),
                        HelpArticleSection(
                            title: "Edit styles",
                            body: "Use the inspector to change stroke color, fill color, line width, text size, effect strength, arrow heads, regular Arrow labels, Numbered Arrow badge style and sequence position, status mark symbol and treatment, callout style, rectangle corners, freehand smoothing, and alignment where supported. Use Rotate in the lower editor command row to turn selected annotations by 90 degrees."
                        ),
                        HelpArticleSection(
                            title: "Manage layers",
                            body: "Use the Layers button in the lower editor command row or Arrange > Show Layers to open a separate Layers window. For a single screenshot, the window shows annotations from front to back. A multi-capture document adds explicit Items, Result, and Capture scopes. Items controls panel selection, order, visibility, duplication, removal, and Edit Selected Capture. Result shows annotations above the assembled canvas, while Capture shows the crop and annotations for one original source with Previous and Next controls. Drag to reorder, or use the visible move buttons, Arrange menu, keyboard shortcuts, context menus, and VoiceOver actions. Group, Ungroup, Delete, and the editing-scope buttons remain available without pointer input. A multi-capture document always keeps at least one item."
                        ),
                        HelpArticleSection(
                            title: "Sample colors",
                            steps: [
                                "In the Style section, choose Picker or Fill under Sample From Image.",
                                "Drag on the screenshot to preview the sampled color.",
                                "Release to apply the color to the current tool or selection."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Create a step guide",
                            body: "Numbered callouts can be copied as a step guide from the inspector. If you delete a numbered callout, the remaining callouts are renumbered."
                        ),
                        HelpArticleSection(
                            title: "Sequence numbered arrows",
                            body: "Numbered Arrows use a contiguous sequence that is separate from numbered Callouts and from layer order. Select one to use Move Earlier or Move Later in Properties. Choose Resequence… to select every Numbered Arrow on the canvas in the order it should appear, then choose Done. Cancel leaves the existing sequence unchanged. Deleting a Numbered Arrow closes the gap; duplicating one appends the copy. Each Screenshot, source-capture editing scope, and assembled result keeps its own sequence. The A key continues to select regular Arrow."
                        )
                    ],
                    important: [],
                    relatedIDs: ["edit-screenshot", "copy-text", "redact"]
                ),
                HelpArticle(
                    id: "redact",
                    title: "Redact sensitive information",
                    summary: "Hide sensitive content in rendered output while keeping the editable document reversible.",
                    sections: [
                        HelpArticleSection(
                            title: "Choose a redaction mode",
                            steps: [
                                "Open the direct Redaction tool's menu and choose Blur, Pixelate, or Redact.",
                                "The menu label changes to show the active redaction mode.",
                                "Drag over the content you want to cover.",
                                "Use the Effect slider for Blur or Pixelate strength."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Share redacted output",
                            body: "Use Copy, Share, or Export when redactions need to be flattened. Editable .sss documents retain the original screenshot and the redaction annotations. When you explicitly save an editable .sss that contains redactions, SnipSnipSnip warns once for that editor session and offers to export a flattened PNG instead."
                        ),
                        HelpArticleSection(
                            title: "Use Private Capture",
                            body: "Turn on Private Capture for screenshots that should skip Snip History, Recent Snips, Recycle Bin retention, and background OCR indexing for that capture session."
                        )
                    ],
                    important: [
                        "Do not share editable .sss packages when the recipient must not have access to the original unredacted pixels."
                    ],
                    relatedIDs: ["privacy", "copy-save-export", "editable-documents"]
                ),
                HelpArticle(
                    id: "copy-text",
                    title: "Copy text from a screenshot",
                    summary: "Run local OCR on a selected screenshot region and copy the recognized text.",
                    sections: [
                        HelpArticleSection(
                            title: "Copy recognized text",
                            steps: [
                                "Choose the Copy Text tool in the top editor command row.",
                                "Drag over the text region in the screenshot.",
                                "Review the normalized text.",
                                "Copy the accepted text to the clipboard."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Where OCR runs",
                            body: "Text recognition runs locally on this Mac. Snip History search can also index recognized screenshot text unless Private Capture is enabled."
                        )
                    ],
                    important: [],
                    relatedIDs: ["privacy", "edit-screenshot", "history-recovery"]
                )
            ]
        ),
        HelpCategory(
            title: "Save and recover",
            articles: [
                HelpArticle(
                    id: "copy-save-export",
                    title: "Copy, save, export, and share",
                    summary: "Choose the right output for editing later or sending now.",
                    sections: [
                        HelpArticleSection(
                            title: "Use Copy or Share",
                            body: "Copy, Export, Share, Float, and Drag follow the visible stage. Edit, Comparison Review, Steps, and Arrange use the unwrapped content, annotations, pinned UI Map overlays, and flattened redactions. Polish uses the visible Look or Mockup; when none is configured, it uses the same unwrapped content. Back to Content changes the boundary explicitly. Edit Selected Capture and Annotate Result hide document output until Done returns to the focused content stage. When Auto Copy runs after capture or an Edit change, it uses that same visible-stage output. Polish changes do not trigger Auto Copy."
                        ),
                        HelpArticleSection(
                            title: "Export screenshots",
                            body: "Choose Polish when you want optional finishing treatment. Look handles transparent, solid, gradient, spotlight, or blurred-screenshot backgrounds, spacing, corners, and shadows. Mockup applies browser, window, phone, tablet, and other designed SVG wrappers. Entering Polish does not apply a treatment automatically. Copy, Export, Share, Float, and Drag use the visible Polish preview; Back to Content restores unwrapped output. Transparent Polish output uses PNG without disabling JPEG or PDF in content stages."
                        ),
                        HelpArticleSection(
                            title: "Export interactive compositions",
                            body: "Choose Interactive HTML for a portable single-file composition that works offline. A determinate progress panel shows the current export stage and offers Cancel Export while the embedded images are prepared and saved. Step navigation and comparison controls never contact a server. A Comparison starts with the app’s chosen view; use Compare Using to switch among Side by Side, Wipe, Overlay, Blink, Difference, and Highlight Changes. Before, After, Difference, and Highlight Changes labels stay above screenshot pixels in every mode. Drag directly on Wipe, use Fit to keep the active viewer and controls visible without fitting the branding footer, use Zoom for synchronized image inspection, and bookmark the current file URL when you want its fragment to restore the viewer settings. With Reduce Motion, Blink starts paused and offers Play Anyway instead of treating the preference as an error. SnipSnipSnip losslessly optimizes embedded PNG pixels at their full dimensions without source metadata, escapes user-authored text, and restricts the file with a deny-by-default Content Security Policy whose only executable resources are the exact exporter-owned style and interaction code. A subtle line-and-dot background and small embedded app logo brand the outer page without covering the composition. The pattern is removed for print and Increased Contrast. The linked attribution makes no network request unless chosen."
                        ),
                        HelpArticleSection(
                            title: "Export composition animation and pages",
                            body: "Steps PDF honors Steps per Page. If a raster composition exceeds 16,384 pixels on one side, 134,217,728 output pixels, or an estimated 1 GiB working set, export offers Scale to Fit; Steps PDF also offers one-step-per-page pagination. PDF pages render and write one at a time. Compare → Blink exports GIF, APNG, or MP4 using the composition’s timing, crossfade, and loop choices. Animated files use a 4,096-pixel longest-side safety limit and the completion message discloses scaling. PNG, JPEG, PDF, Copy, and Share use the configured Blink poster, defaulting to After."
                        ),
                        HelpArticleSection(
                            title: "Use Mockups",
                            body: "Polish → Mockup applies SVG templates from the Mockup folder. Mockups are grouped as Bundled or User, can expose editable text fields, and embed a sanitized snapshot in the .sss document so output can render later without depending on the original file. Use Framing to choose Auto, Show Full, Fill, edge focus presets, or Actual Size for the screenshot slot."
                        ),
                        HelpArticleSection(
                            title: "Adjust Mockup framing",
                            body: "Auto tries to fit arbitrary screenshot sizes into the Mockup slot. If the result needs correction, open Adjust to change alignment, scale, or nudge the screenshot. Drag inside the slot to reposition it. Pinch, Command-scroll, and Option-scroll zoom the full Polish preview. Double-click the slot or use Reset Framing to return to the Mockup default."
                        ),
                        HelpArticleSection(
                            title: "Save Polish presets in a document",
                            body: "Manage stores named Polish variants inside the current .sss document. Save the current Look or Mockup, then apply, rename, update, duplicate, or delete variants as the document evolves. Global Look templates remain app preferences; document variants travel with the .sss file."
                        ),
                        HelpArticleSection(
                            title: "Manage Mockup files",
                            body: "Mockup → Manage includes controls for revealing the User Mockups folder and reloading files. Settings > Editor & Output lets you choose, reveal, reset, or reload the root Mockup folder. The default folder contains Bundled and User subfolders. Add custom SVG files to User. For file-format compatibility, Mockups use the presentation-scene metadata schema and data-sss-slot markers; remote URLs, file URLs, scripts, foreignObject, animation, and event handlers are rejected. Diagnostics appear only when there is something to review."
                        ),
                        HelpArticleSection(
                            title: "Import from Finder or Photos",
                            body: "In Finder, use Open With > SnipSnipSnip on common image files to import them into the screenshot editor. In Apple Photos, right-click a photo, choose Share, then choose SnipSnipSnip to open that photo as an editable imported image."
                        ),
                        HelpArticleSection(
                            title: "Drag output into another app",
                            body: "Drag sends the output shown in the active content or Polish stage to Finder, Mail, or another app. If you click without dragging, SnipSnipSnip shows a short reminder. During the drag, the editor window temporarily hides so you can reach the destination, then returns when the drag finishes. Settings > Editor & Output controls whether screenshot drag-out normally uses PNG, JPEG, or PDF and sets JPEG quality. Transparent Polish output automatically uses PNG so the result stays faithful."
                        ),
                        HelpArticleSection(
                            title: "Save editable work",
                            body: "Save and Save As write .sss screenshot and composition packages or .sssvideo video packages. Use these formats when you may need to revise item order, layout, crop, annotations, redactions, trim range, or other editable state later."
                        ),
                        HelpArticleSection(
                            title: "Filename suggestions",
                            body: "Settings > Editor & Output controls filename templates for Save As and export. Supported tokens include {kind}, {source}, {width}, {height}, {format}, and date patterns such as {yyyy-MM-dd-HH-mm-ss}. Content output uses the existing edited or composition suffix and Polish keeps the presentation suffix for compatibility; save panels describe the visible stage."
                        )
                    ],
                    important: [
                        "Exported and copied screenshots are newly encoded so source EXIF, TIFF, GPS, IPTC, and user metadata are not carried forward."
                    ],
                    relatedIDs: ["editable-documents", "compose-screenshots", "redact", "history-recovery"]
                ),
                HelpArticle(
                    id: "editable-documents",
                    title: "Use editable documents",
                    summary: "Save work as .sss or .sssvideo packages when you need to reopen and revise it.",
                    sections: [
                        HelpArticleSection(
                            title: ".sss screenshot packages",
                            body: "A .sss package keeps the base image, preview, crop, annotations, optional Polish settings, image overlay assets, undo and redo history, and searchable metadata."
                        ),
                        HelpArticleSection(
                            title: ".sssvideo video packages",
                            body: "A .sssvideo package keeps the source media, trim range, poster frame, and recording metadata."
                        ),
                        HelpArticleSection(
                            title: "Compatibility",
                            body: "Current packages open directly. Older unsupported packages and recovery checkpoints can be moved to the macOS Trash when SnipSnipSnip detects that they no longer match the current document baseline."
                        )
                    ],
                    important: [
                        "Editable screenshot packages can contain original unredacted pixels."
                    ],
                    relatedIDs: ["copy-save-export", "redact", "privacy"]
                ),
                HelpArticle(
                    id: "history-recovery",
                    title: "Find or recover work",
                    summary: "Use local history, autosave, search, and the Recycle Bin before starting over.",
                    sections: [
                        HelpArticleSection(
                            title: "Recover an interrupted session",
                            body: "If SnipSnipSnip closes while a session has unsaved work, the next launch can show Recover Last Session."
                        ),
                        HelpArticleSection(
                            title: "Use Change History",
                            body: "Autosave checkpoints appear in the editor inspector. Click a thumbnail or focus it and press Space to open the separate History Preview window without replacing the editor canvas. Use the arrow controls or arrow keys to browse neighboring items, scroll to pan, pinch or Command-scroll to zoom, double-click to switch between Fit and Actual Size, and use the source-appropriate Restore or Open action when you are ready. The preview stays open if opening cannot finish or you cancel a decision. Close it with its standard window control, Escape, or Command-W. You can also delete individual snapshots or clear the current snip's history from the inspector."
                        ),
                        HelpArticleSection(
                            title: "Use the Snip Library",
                            body: "The Capture screen keeps a few quick Snip History thumbnails within reach. Click a thumbnail to preview it, choose View All, or use Open Snip Library in the editor inspector to open the same modeless Snip Library window. Switch among Recent Snips, Snip History, and the Recycle Bin while the complete paged list, search, and a large scrollable and zoomable preview remain in place. View All carries the current Capture search with it. The library remembers its last section, search, selection, layout, size, and position. Selecting a row only previews it; choose Open or Restore when you are ready. Opening or restoring another non-private screenshot keeps the current non-private work in Recent Snips first and briefly offers Undo to switch back. Private work still asks whether to Save, Discard, or Cancel. Search matches labels, saved document names, annotation text, and recognized screenshot text without showing those private details in result rows. Deleting a Snip History row deletes that Screenshot session and all of its checkpoints."
                        ),
                        HelpArticleSection(
                            title: "Restore deleted snips",
                            body: "Deleted snips move to the Recycle Bin first, so ordinary Delete needs no interruption. Open the Recycle Bin from the Capture screen, the Snip Library window, or the editor inspector to preview and restore items before retention cleanup removes them. Permanently Delete and Empty Recycle Bin always ask for confirmation because they cannot be undone. New installations and Reset Defaults use 30 days. Configure any value from 1 through 180 days in Settings > Snip Library > Snips."
                        )
                    ],
                    important: [
                        "Private Capture skips Snip History, Recent Snips, Recycle Bin retention, and background OCR indexing for that capture session."
                    ],
                    relatedIDs: ["privacy", "copy-save-export"]
                )
            ]
        ),
        HelpCategory(
            title: "Reference",
            articles: [
                HelpArticle(
                    id: "privacy",
                    title: "Privacy and local processing",
                    summary: "Know what stays local, what is saved, and which output is safest to share.",
                    sections: [
                        HelpArticleSection(
                            title: "Local-first behavior",
                            body: "Screenshots, annotations, OCR, rendering, document handling, history, and recovery are processed locally on this Mac."
                        ),
                        HelpArticleSection(
                            title: "Private Capture",
                            body: "Private Capture keeps the current capture out of Snip History, Recent Snips, the Recycle Bin, Clipboard History, and background OCR indexing. The setting is locked while a capture or recording is active."
                        ),
                        HelpArticleSection(
                            title: "Rendered output",
                            body: "Copied, shared, and exported screenshots are rendered from the current crop and annotations. PNG, JPEG, and PDF output is newly encoded and does not carry source image metadata forward."
                        )
                    ],
                    important: [
                        "Use rendered output, not editable .sss packages, when redactions must be irreversible for the recipient."
                    ],
                    relatedIDs: ["redact", "permissions", "editable-documents"]
                ),
                HelpArticle(
                    id: "keyboard-shortcuts",
                    title: "Keyboard shortcuts",
                    summary: "Use centralized shortcuts for help, capture, save, editor tools, layers, and screen utilities.",
                    sections: AppShortcut.catalogSections.map { section in
                        HelpArticleSection(
                            title: section.title,
                            bullets: section.entries.map { "\($0.keys): \($0.action)." }
                        )
                    } + [
                        HelpArticleSection(
                            title: "Screen tools",
                            bullets: [
                                "Use Screen Tools in the main window to add a Screen Ruler, open Screen Inspector, or show Quick Controls.",
                                "Use the menu bar icon > Screen Ruler to add horizontal and vertical rulers.",
                                "Use the menu bar icon > Screen Inspector to inspect live pixels, colors, and coordinates.",
                                "Use Settings > Capture to adjust ruler appearance and inspector display options."
                            ]
                        )
                    ],
                    important: [
                        "Global shortcuts can be customized in Settings > Shortcuts.",
                        "Single-key editor tool shortcuts can be turned off in Settings > Shortcuts.",
                        "Apple Shortcuts actions are separate from these keyboard shortcuts and appear in the Shortcuts app."
                    ],
                    relatedIDs: ["capture-screenshot", "edit-screenshot", "screen-inspector", "automation-shortcuts"]
                ),
                HelpArticle(
                    id: "automation-shortcuts",
                    title: "Automate with Shortcuts",
                    summary: "Run capture actions from Apple Shortcuts, Spotlight, and system automation.",
                    sections: [
                        HelpArticleSection(
                            title: "Available actions",
                            bullets: [
                                "Get automation status and list capture presets.",
                                "Run a capture preset by choosing a saved preset.",
                                "Capture a screen, frontmost window, region, or interactive window.",
                                "Add a capture to a composition, replace an exact item, set its layout or comparison, apply a saved template, and export the completed composition.",
                                "Start, pause, resume, add a step to, stop, or export a Guide.",
                                "Repeat the last capture, open an editable .sss document, or export the current screenshot."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Foreground actions",
                            body: "Status and preset listing can run in the background and show Shortcuts result summaries. Non-interactive capture, composition, export, and fixed-target repeat actions return only after the requested change or file output finishes. Interactive region and window captures, connected-device or scrolling repeats, editor output, and floating references continue in SnipSnipSnip so you can choose a target or see the resulting UI."
                        ),
                        HelpArticleSection(
                            title: "Output and privacy",
                            body: "Shortcuts actions use the same automation validation as command-line, AppleScript, and URL automation. File output accepts an absolute path or file URL and still checks format and overwrite choices. In the sandboxed App Store build, unattended file output must be inside Downloads; interactive exports can use a location you choose in the save panel. The direct-download Pro build can use other writable absolute paths. Private Capture skips Snip History, Recent Snips, Recycle Bin retention, and background OCR indexing for that capture session."
                        ),
                        HelpArticleSection(
                            title: "Script interfaces",
                            body: "Use Apple Shortcuts actions for native macOS automation. Use the command-line helper, AppleScript suite, or URL routes from scripts and launchers when you need those interfaces directly. Those compatibility interfaces retain their existing fullscreen command and option identifiers even though the app’s visible source name is Screen."
                        )
                    ],
                    important: [
                        "Screen Recording permission is still required before capture actions can read pixels.",
                        "Use rendered PNG, JPEG, PDF, or clipboard output when redactions must be flattened."
                    ],
                    relatedIDs: ["keyboard-shortcuts", "capture-screenshot", "privacy"]
                ),
                HelpArticle(
                    id: "troubleshoot-capture",
                    title: "Solve common capture problems",
                    summary: scrollingCaptureEnabled
                        ? "Fix blank captures, missing windows, Scrolling Capture failures, and deleted snips."
                        : "Fix blank captures, missing windows, and deleted snips.",
                    sections: [
                        HelpArticleSection(
                            title: "Blank captures or missing thumbnails",
                            body: "Click Set Up for Screen Recording, use the macOS prompt or the Screen Recording settings pane that SnipSnipSnip opens, then return and click Check Again. If System Settings shows SnipSnipSnip enabled but the app still cannot capture, SnipSnipSnip shows Restart Required. During onboarding, finish any remaining permission first if you want it ready too, then use Restart SnipSnipSnip so macOS applies the new Screen Recording access."
                        ),
                        HelpArticleSection(
                            title: "A window is missing",
                            body: "Make sure the target window is visible, then use Refresh or Auto Refresh. With Auto Refresh off, SnipSnipSnip still refreshes once whenever the app returns to the foreground. Some protected or transient windows may not be available through macOS capture APIs."
                        ),
                        HelpArticleSection(
                            title: "Work was replaced or deleted",
                            body: "Check Change History, the Snip Library, or the Recycle Bin before recapturing."
                        ),
                        HelpArticleSection(
                            title: "Temporary storage is low",
                            body: "Free disk space before recording or exporting video. SnipSnipSnip blocks or stops video work early so temporary media can finalize safely."
                        ),
                        HelpArticleSection(
                            title: "Connected iPhone or iPad does not appear",
                            body: "Use a USB connection, unlock the device, confirm Trust This Computer if prompted, keep the device awake, then choose Refresh Devices. If SnipSnipSnip says the USB device is connected but macOS is not exposing its stream, reconnect the cable or reopen the device camera/screen source after unlocking it. App Store-safe builds cannot use private QuickTime device services."
                        ),
                        HelpArticleSection(
                            title: "Export diagnostics for support",
                            body: "Use Settings > Privacy > Export Diagnostics to save a local JSON report with sanitized app, permission, display, storage, connected-device, and status details. Diagnostics do not include screenshots, clipboard contents, OCR text, annotation text, document data, window titles, or raw file paths."
                        )
                    ] + (scrollingCaptureEnabled
                        ? [
                            HelpArticleSection(
                                title: "Scrolling Capture does not start",
                                body: "Allow Accessibility permission. If the app is not listed, use Reveal App from the setup guide and add the exact running app in System Settings. If the Ready to Capture panel is enabled, confirm that it names the expected app. If the selected area is not scrollable or stitching cannot continue, use the recovery panel to keep a useful partial result, choose another area, retry, or capture the visible area instead."
                            )
                        ]
                        : []),
                    important: [],
                    relatedIDs: scrollingCaptureEnabled
                        ? ["permissions", "history-recovery", "capture-scrolling"]
                        : ["permissions", "history-recovery"]
                )
            ]
        )
    ]
    }

    private var allArticles: [HelpArticle] {
        Self.categories(
            for: capabilities,
            fullscreenDisplayMode: capture.screenshotFullscreenDisplayMode
        ).flatMap(\.articles)
    }

    private var displayedCategories: [HelpCategory] {
        let normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return Self.categories(
                for: capabilities,
                fullscreenDisplayMode: capture.screenshotFullscreenDisplayMode
            )
        }

        let matches = allArticles.filter { article in
            article.searchText.localizedCaseInsensitiveContains(normalizedQuery)
        }

        return [HelpCategory(title: "Search Results", articles: matches)]
    }

    private var displayedArticles: [HelpArticle] {
        displayedCategories.flatMap(\.articles)
    }

    private var selectedArticle: HelpArticle? {
        if let selectedArticleID,
           let article = displayedArticles.first(where: { $0.id == selectedArticleID }) {
            return article
        }

        return displayedArticles.first
    }

    private var relatedArticles: [HelpArticle] {
        guard let selectedArticle else {
            return []
        }

        return selectedArticle.relatedIDs.compactMap { id in
            allArticles.first(where: { $0.id == id })
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedArticleID) {
                ForEach(displayedCategories) { category in
                    if category.articles.isEmpty {
                        Text("No help topics found")
                            .foregroundStyle(.secondary)
                    } else {
                        Section(AppBranding.branded(category.title)) {
                            ForEach(category.articles) { article in
                                Text(AppBranding.branded(article.title))
                                    .tag(Optional(article.id))
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search Help")
            .onChange(of: searchText) { oldValue, newValue in
                updateSelectionForSearchChange(from: oldValue, to: newValue)
            }
            .navigationTitle("\(AppBranding.displayName) Help")
            .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 340)
        } detail: {
            if let selectedArticle {
                HelpArticleView(
                    article: selectedArticle,
                    relatedArticles: relatedArticles,
                    onSelectRelated: { selectedArticleID = $0.id }
                )
            } else {
                ContentUnavailableView.search(text: searchText)
                    .accessibilityIdentifier("help.search.noResults")
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func updateSelectionForSearchChange(from oldValue: String, to newValue: String) {
        let newQuery = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = allArticles.filter {
            $0.searchText.localizedCaseInsensitiveContains(newQuery)
        }
        let result = HelpSearchSelectionPolicy.resolve(
            currentID: selectedArticleID,
            preSearchID: selectedArticleIDBeforeSearch,
            oldQuery: oldValue,
            newQuery: newValue,
            matchingIDs: matches.map(\.id),
            defaultID: Self.defaultArticleID
        )
        selectedArticleID = result.selectedID
        selectedArticleIDBeforeSearch = result.preSearchID
    }
}

private extension HelpArticle {
    var searchText: String {
        ([title, summary] + sections.flatMap(\.searchableText) + important).joined(separator: " ")
    }
}

private extension HelpArticleSection {
    var searchableText: [String] {
        [title, body].compactMap(\.self) + steps + bullets + links.map(\.title)
    }
}

private struct HelpArticleView: View {
    let article: HelpArticle
    let relatedArticles: [HelpArticle]
    let onSelectRelated: (HelpArticle) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                ForEach(article.sections) { section in
                    HelpArticleSectionView(section: section)
                }

                if !article.important.isEmpty {
                    HelpImportantView(items: article.important)
                }

                if !relatedArticles.isEmpty {
                    relatedTopics
                }
            }
            .padding(.horizontal, 42)
            .padding(.vertical, 36)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppBranding.branded(article.title))
                .font(.largeTitle.weight(.semibold))
                .textSelection(.enabled)

            Text(AppBranding.branded(article.summary))
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var relatedTopics: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("See also")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                ForEach(relatedArticles) { article in
                    Button {
                        onSelectRelated(article)
                    } label: {
                        Text(AppBranding.branded(article.title))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }
}

private struct HelpArticleSectionView: View {
    let section: HelpArticleSection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppBranding.branded(section.title))
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)

            if let body = section.body {
                Text(AppBranding.branded(body))
                    .font(.body)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if !section.steps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1).")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)

                            Text(AppBranding.branded(step))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if !section.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(section.bullets, id: \.self) { bullet in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("•")
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)

                            Text(AppBranding.branded(bullet))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if !section.links.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(section.links) { link in
                        Link(destination: link.url) {
                            Label(AppBranding.branded(link.title), systemImage: "arrow.up.right.square")
                                .labelStyle(.titleAndIcon)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }
}

private struct HelpImportantView: View {
    let items: [String]

    var body: some View {
        InsetGroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items, id: \.self) { item in
                    Text(AppBranding.branded(item))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Important", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
        }
    }
}

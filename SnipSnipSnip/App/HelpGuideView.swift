import SwiftUI

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

    var id: String { title }

    init(
        title: String,
        body: String? = nil,
        steps: [String] = [],
        bullets: [String] = []
    ) {
        self.title = title
        self.body = body
        self.steps = steps
        self.bullets = bullets
    }
}

struct HelpGuideView: View {
    private static let defaultArticleID = "get-started"

    @State private var selectedArticleID: HelpArticle.ID? = Self.defaultArticleID
    @State private var searchText = ""

    private static let categories: [HelpCategory] = [
        HelpCategory(
            title: "Start here",
            articles: [
                HelpArticle(
                    id: "get-started",
                    title: "Get started with SnipSnipSnip",
                    summary: "Take a screenshot, make a few edits, and share the finished result.",
                    sections: [
                        HelpArticleSection(
                            title: "First launch onboarding",
                            steps: [
                                "The first launch opens a guided onboarding flow with capture basics, permissions, UI Map disclosure when available, launch-at-login, and support links.",
                                "You can skip at any point and still start capturing immediately.",
                                "Open Settings > General > Show Onboarding Again any time to replay it."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Basic workflow",
                            steps: [
                                "Open SnipSnipSnip from the menu bar icon or the Help menu.",
                                "Choose Region, Window, or Fullscreen to take a screenshot.",
                                "Use the editor to crop, annotate, redact, or copy text.",
                                "Use Float when you want the rendered screenshot to stay above other apps as a temporary reference.",
                                "Use Copy, Share, or Export when you are ready to send a flattened result.",
                                "Use Save or Save As when you want to keep an editable .sss document."
                            ]
                        ),
                        HelpArticleSection(
                            title: "What happens after capture",
                            body: "Screenshots open in the editor. Screen recordings open in the video editor. Auto Copy is on by default, so the current rendered screenshot is copied after capture and after editor annotation changes."
                        ),
                        HelpArticleSection(
                            title: "Start on login",
                            body: "Settings > General includes Launch SnipSnipSnip at Login. If macOS needs extra confirmation, SnipSnipSnip can open Login Items in System Settings directly for you."
                        ),
                        HelpArticleSection(
                            title: "Keep running in the background",
                            body: "Command-Q minimizes SnipSnipSnip instead of quitting so the menu bar icon and shortcuts stay available. The menu bar Quit command asks before exiting; choose Run in Background to keep SnipSnipSnip available, or Quit to close the app."
                        ),
                        HelpArticleSection(
                            title: "Open an existing image",
                            body: "Choose File > Import Image to open PNG, JPEG, TIFF, HEIC, GIF, and other common image formats in the screenshot editor. You can also open supported images from Finder with Open With > SnipSnipSnip, or share a photo from Apple Photos to SnipSnipSnip."
                        )
                    ],
                    important: [
                        "Screen Recording permission is required before macOS lets SnipSnipSnip capture pixels or show live window thumbnails.",
                        "Support requests and feature requests are handled through Help > Support (Discord)."
                    ] + (FeatureFlags.scrollingCaptureEnabled || FeatureFlags.uiMapEnabled
                        ? ["Accessibility permission is required for Window UI Map metadata capture\(FeatureFlags.scrollingCaptureEnabled ? " and Scrolling Capture" : ""). Region and Fullscreen captures do not require Accessibility because of UI Map."]
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
                            body: "Required for screenshot pixels, live window thumbnails, and screen recording. If it is missing, captures can be blank and window previews may not appear.",
                            steps: [
                                "Click the Screen Recording Grant button in SnipSnipSnip.",
                                "Allow SnipSnipSnip in System Settings > Privacy & Security > Screen Recording.",
                                "Quit and reopen SnipSnipSnip if macOS asks you to."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Audio permissions",
                            body: "Microphone and system audio permissions are optional. macOS asks for them only when the matching recording source is enabled."
                        )
                    ] + (FeatureFlags.scrollingCaptureEnabled || FeatureFlags.uiMapEnabled
                        ? [
                            HelpArticleSection(
                                title: "Accessibility",
                                body: FeatureFlags.scrollingCaptureEnabled && FeatureFlags.uiMapEnabled
                                    ? "Required for Scrolling Capture and for Window capture when Enable UI Map for Window captures is on. SnipSnipSnip uses it to scroll the selected app during Scrolling Capture and to read visible interface element names, roles, identifiers, and locations from the selected window during UI Map capture."
                                    : FeatureFlags.uiMapEnabled
                                        ? "Required for Window capture when Enable UI Map for Window captures is on. SnipSnipSnip uses it to read visible interface element names, roles, identifiers, and locations from the selected window during a user-initiated Window capture."
                                        : "Required only for Scrolling Capture. SnipSnipSnip uses it to scroll the selected app while collecting segments.",
                                steps: [
                                    "Click the Accessibility Grant button in SnipSnipSnip.",
                                    "Allow SnipSnipSnip in System Settings > Privacy & Security > Accessibility.",
                                    "If SnipSnipSnip is not listed, open the setup guide, choose Reveal App, and add that exact app with the + button."
                                ]
                            )
                        ]
                        : []),
                    important: FeatureFlags.scrollingCaptureEnabled || FeatureFlags.uiMapEnabled
                        ? [
                            FeatureFlags.uiMapEnabled
                                ? "Region and Fullscreen screenshot capture do not include UI Map metadata and do not require Accessibility because of UI Map."
                                : "Region and Fullscreen screenshot capture do not require Accessibility.",
                            "Development builds launched from Xcode may need Accessibility permission for the exact app in DerivedData, not a copy in Applications."
                        ]
                        : [],
                    relatedIDs: ["troubleshoot-capture", "privacy"]
                )
            ] + (FeatureFlags.proUpdateCheckEnabled ? [
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
                    sections: FeatureFlags.uiMapEnabled ? [
                        HelpArticleSection(
                            title: "Enable UI Map for Window captures",
                            body: "UI Map is a SnipSnipSnip Pro feature. Open Settings > General > Screenshot Capture and turn on Enable UI Map for Window captures. Window screenshots then try to save available metadata for visible interface elements in the selected window, including names, labels, identifiers, roles, positions, sizes, parent hierarchy, and owning app. This makes a Window screenshot searchable and inspectable as structured interface data, not just pixels. Settings also controls the default visible details for pinned UI Map overlays; only Show outline is enabled by default."
                        ),
                        HelpArticleSection(
                            title: "Capture behavior",
                            bullets: [
                                "UI Map capture runs only during user-initiated Window capture workflows.",
                                "Region, Fullscreen, Scrolling, Recording, Connected Device, and Screen Inspector captures are visual-only and do not request Accessibility because of UI Map.",
                                "After a Window screenshot opens, the header may show UI Map Processing while metadata is captured in the background, then UI Map Captured when metadata was saved with the screenshot.",
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
                                "Choose Arrange > Show UI Map, or use the UI Map toolbar button.",
                                "Search by name, role, label, or identifier, filter by element type, or turn on Pinned Only to show just pinned UI Map overlays.",
                                "Select an element to show its region on the screenshot and inspect its metadata. With a row selected, use the arrow keys to move through the visible tree, expand, or collapse branches.",
                                "Use Show All to outline captured controls and leaf elements without permanently annotating the screenshot. Accessibility elements use blue outlines; OCR supplement text uses orange outlines.",
                                "For Window captures with UI Map available, use the lower toolbar UI Map group to open the UI Map panel or switch to Pin UI Map. Pin UI Map starts with captured element outlines hidden unless Show All is enabled in the UI Map panel. Move over the screenshot to preview an available element, then click to select and pin it; click it again to unpin it.",
                                "Pinned UI Map overlays stay visible in copied, shared, or exported screenshots. You can also pin or unpin the selected element from the inspector or UI Map panel.",
                                "Use Export JSON to save the structured UI Map metadata for debugging, review, or support.",
                                "Use the UI Map panel or inspector display toggles to show the selected element outline, label, identifier, role, coordinates, or dimensions."
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
                    important: FeatureFlags.uiMapEnabled
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
                            body: "Choose Clipboard History from the menu bar icon or use Command-Shift-V. Search is focused when the floating window opens. Press Command-W to close the Clipboard History window."
                        ),
                        HelpArticleSection(
                            title: "What appears",
                            body: "Clipboard History saves copied text, links, images, files, and non-private SnipSnipSnip screenshots. Snips are added even when Auto Copy is off. Private Capture screenshots are not added."
                        ),
                        HelpArticleSection(
                            title: "Copy and paste actions",
                            body: "Copy writes the selected item back to the system clipboard. Copy & Paste writes the item to the clipboard, keeps Clipboard History open, returns to the app that was active before Clipboard History opened, and sends Command-V. For text and links, Plain Text actions sanitize formatting by writing only the unstyled string before copying or pasting. Use Option-1 through Option-9 while the Clipboard History window is focused to copy the matching visible item."
                        ),
                        HelpArticleSection(
                            title: "Ignore apps",
                            body: "Open Settings > Clipboard to manage ignored apps. Use Ignore Running App for apps that are currently open, Choose App to pick an app from Applications, or Ignore beside a recent clipboard source."
                        ),
                        HelpArticleSection(
                            title: "Privacy defaults",
                            body: "SnipSnipSnip skips concealed and transient pasteboard types and ignores Apple Passwords plus common password managers by default. Clipboard history is local to this Mac."
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
                                "Choose Screen Ruler from the menu bar icon, directly below Clipboard History.",
                                "Add as many Horizontal or Vertical rulers as you need."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Work with rulers",
                            bullets: [
                                "Drag a ruler to position it and resize it from the window edges.",
                                "Click a ruler once to cycle through tick-edge and zero-origin positions.",
                                "Move the pointer over a ruler to show the current pixel distance when Show Mouse Distance is enabled."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Capture rulers",
                            body: "Screen rulers are real floating overlay windows. If a visible ruler sits inside the area you capture, it is included in region and fullscreen screenshots."
                        ),
                        HelpArticleSection(
                            title: "Configure rulers",
                            body: "Settings > General > Screen Ruler controls opacity, tick spacing, major tick frequency, horizontal and vertical tick edges, zero-origin positions, half markers, and mouse-distance labels for all open rulers."
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
                                "Choose Screen Inspector from the menu bar icon or the Capture menu.",
                                "Use Command-Shift-I by default, or change the shortcut in Settings > Shortcuts.",
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
                            title: "Copy, freeze, and snip",
                            bullets: [
                                "Use Copy HEX or Option-Command-H to copy the current center-pixel color as HEX.",
                                "Use Copy RGB or Option-Command-R to copy the current center-pixel color as RGB.",
                                "Use Freeze, Space, or Option-Command-F to hold a static sample while you inspect details.",
                                "Use Measure or Option-Command-M to set the first point at the current cursor, move to the second point, then use Lock or Option-Command-M again to keep the one-line distance measurement.",
                                "Use Snip or Option-Command-S to open the current inspector sample in the editor.",
                                "Close the inspector from the close button, Escape, the menu command, the menu bar, or the global shortcut."
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
        HelpCategory(
            title: "Capture and record",
            articles: [
                HelpArticle(
                    id: "capture-screenshot",
                    title: "Take a screenshot",
                    summary: "Capture a region, window, fullscreen image, or repeat a previous capture.",
                    sections: [
                        HelpArticleSection(
                            title: "Capture a region",
                            steps: [
                                "Choose Region from the main window, menu bar icon, Capture menu, or global hotkey.",
                                "Drag the area you want to capture over the live desktop. The loupe stays live while you aim.",
                                "Single-click a visible window instead of dragging to capture that window.",
                                "A screenshot region may span connected displays.",
                                "By default, releasing the mouse captures immediately. If Always Capture on Mouse Up is off, click Capture in the floating controls."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Use precision region controls",
                            body: "Settings > General > Screenshot Capture includes Enable Precision Region Controls. Leave it off for basic drag-to-capture. Turn it on when you want region capture to pause after dragging so you can resize with handles, type width and height, lock the aspect ratio, nudge with arrow keys, press Return to capture, or press Esc to cancel."
                        ),
                        HelpArticleSection(
                            title: "Capture a window",
                            steps: [
                                "Choose Window.",
                                "From the header Window button or menu bar, use the quick menu to choose Pick On Screen, a suggested window, or More Windows.",
                                "From the startup screen, pick a live thumbnail directly or use Pick On Screen for crowded desktops.",
                                "Use Refresh or Auto Refresh if the target window is visible but not listed. With Auto Refresh off, SnipSnipSnip still refreshes once whenever the app returns to the foreground."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Capture the screen",
                            body: "Choose Fullscreen to capture the current display by default. Settings > General > Screenshot Capture can switch fullscreen screenshots to a selected display or all displays. Choose Repeat Last Capture to rerun the previous capture when the target can still be found."
                        ),
                    ] + (FeatureFlags.connectedDeviceCaptureEnabled ? [
                        HelpArticleSection(
                            title: "Connected devices",
                            body: "Capture > Connected Device scans for trusted USB iPhone and iPad sources when the menu opens. Choose a device to open a live preview, then capture the latest visible frame, copy it, save it, or open it in the screenshot editor. Keep the device awake and unlocked. If the phone or tablet was just connected, unlocked, trusted, or reconnected, choose Refresh Devices."
                        )
                    ] : []) + [
                        HelpArticleSection(
                            title: "Use a timer",
                            body: "Choose a 3, 5, or 10 second timer from the Capture menu or menu bar extra when you need time to stage the screen before capture. For Region, Pick On Screen window capture, and Scrolling Capture, select the target first; SnipSnipSnip then shows the countdown and takes the snapshot when it reaches zero. Fullscreen, repeat, frontmost-window, and direct window captures count down immediately before reading pixels."
                        ),
                        HelpArticleSection(
                            title: "Use capture presets",
                            body: "After a region, window, frontmost-window, fullscreen, or Screen Inspector snip, choose Presets > Save Last Capture as Preset to name it. Presets remember the screenshot target, timer, cursor option, fullscreen display choice, region controls, and Window UI Map option used for that capture. Private Capture stays controlled by the current Privacy setting and is not saved inside presets. Run saved presets from the main window, Capture menu, or menu bar extra. Manage names, order, and deletion in Settings > Presets. If a saved region no longer fits the current display layout, SnipSnipSnip opens the region selector with the saved size so you can reposition it. If a saved window is not available, choose a replacement window to update and run the preset."
                        ),
                        HelpArticleSection(
                            title: "Include an editable cursor",
                            body: "Turn on Include Cursor from the Capture menu, menu bar extra, or Settings > General > Screenshot Capture. Region, window, frontmost-window, fullscreen, and repeat screenshots add the cursor as an editable overlay that you can move, resize, fade, or delete. Region capture keeps the fast drag-to-capture default unless you enable Precision Region Controls in Settings. Scrolling Capture always excludes the cursor while stitching."
                        )
                    ],
                    important: [],
                    relatedIDs: FeatureFlags.scrollingCaptureEnabled ? ["capture-scrolling", "keyboard-shortcuts", "edit-screenshot"] : ["keyboard-shortcuts", "edit-screenshot"]
                )
            ]
            + (FeatureFlags.scrollingCaptureEnabled ? [
                HelpArticle(
                    id: "capture-scrolling",
                    title: "Capture scrolling content",
                    summary: "Capture a long page, document, or list as one editable screenshot.",
                    sections: [
                        HelpArticleSection(
                            title: "Before you begin",
                            body: "Scrolling Capture requires Accessibility permission because SnipSnipSnip must scroll the selected app while it captures and stitches segments."
                        ),
                        HelpArticleSection(
                            title: "Capture a scrollable area",
                            steps: [
                                "Choose Scrolling Capture.",
                                "Drag over a scrollable area within one display.",
                                "Confirm the selected viewport.",
                                "Wait while SnipSnipSnip scrolls and captures segments.",
                                "Press Esc to cancel, or press Return or click Done to stop early and use the segments already captured."
                            ]
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
                    summary: "Record region, window, or fullscreen video and trim it before export.",
                    sections: [
                        HelpArticleSection(
                            title: "Start and control a recording",
                            steps: [
                                "Choose Record Region, Record Window, or Record Fullscreen.",
                                "Region and Pick On Screen recording start from the live desktop selection overlay, with the live loupe available while you aim.",
                                "Use the floating recording control to Pause, Resume, or Stop.",
                                "When the recording finishes, use the video editor to review and trim the result."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Choose recording options",
                            body: "Open Settings > Recording to set quality, frame rate, fullscreen display mode, cursor visibility, click rings, system audio, and microphone narration."
                        ),
                    ] + (FeatureFlags.connectedDeviceCaptureEnabled ? [
                        HelpArticleSection(
                            title: "Connected-device recording",
                            body: "Choose Record Connected Device; the menu scans for trusted USB iPhone and iPad sources as it opens. Pick a device, then use the preview window to start and stop recording. Keep the device awake, unlocked, and connected until recording is stopped. Finished MP4 recordings open in the normal video editor for poster frames, trimming, export, and archive behavior."
                        )
                    ] : []) + [
                        HelpArticleSection(
                            title: "Export video",
                            body: "Use the video editor Export menu or File > Export to export MP4 using a quality preset or a size-limited target, or export short silent loops as GIF or APNG. Size-limited exports retry at a lower bitrate if the result exceeds the selected cap. Drag the file icon beside Export to send the current trimmed export to Finder, Mail, or another app. Click the icon without dragging to see a short reminder. The editor window temporarily hides during the drag and returns when the drag finishes. Encoding begins after the destination accepts the drop."
                        )
                    ],
                    important: [
                        "A region video recording must stay within one display.",
                        "SnipSnipSnip checks temporary storage before recording and during long recordings so it can stop safely before disk pressure causes a failed write."
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
                            body: "The toolbar includes Select, Rectangle, Ellipse, Line, Arrow, Freehand, Highlighter, Highlight Box, Text, Callout, Ruler, Spotlight, Copy Text, Redaction, Import Image, and Presentation. Presentation switches to a final-export styling workspace without changing the screenshot annotation tools. For Window captures with UI Map metadata, the lower toolbar also includes Show UI Map and Pin UI Map."
                        ),
                        HelpArticleSection(
                            title: "Select and arrange annotations",
                            body: "Select one or more annotations to move, resize, rotate 90 degrees, group, ungroup, align, or delete them. Snap guides appear while drawing, moving, and resizing."
                        ),
                        HelpArticleSection(
                            title: "Use the inspector",
                            body: "The right inspector changes with the active tool, selection, or workspace. Use it to adjust style, colors, text size, effect strength, image overlay opacity, UI Map display and pin options when available, crop values, Presentation Styles and Scenes, callout step guides, Change History, Recent Snips, search, and the Recycle Bin."
                        )
                    ],
                    important: [
                        "The editor keeps the base screenshot separate from annotation state. Copy, Share, and Export create the flattened rendered result."
                    ],
                    relatedIDs: ["floating-references", "crop-navigate", "annotate-style", "redact"]
                ),
                HelpArticle(
                    id: "floating-references",
                    title: "Float a reference screenshot",
                    summary: "Keep a rendered screenshot visible above other apps while you work.",
                    sections: [
                        HelpArticleSection(
                            title: "Create a floating reference",
                            bullets: [
                                "Click Float in the editor toolbar to pin the current rendered screenshot.",
                                "Choose Reference > Float Current Screenshot when you prefer the menu command.",
                                "Open a Change History, Recent Snip, Capture History, or Recycle Bin preview and click Float Reference to pin that snapshot."
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
                                "Use the inspector fields for exact X, Y, Width, and Height values.",
                                "Choose Freeform or a fixed aspect ratio in the inspector before drawing or resizing the crop.",
                                "Click Auto Crop to tighten the current crop around screenshot content and visible annotations, or click Padded to keep a small margin.",
                                "Click Reset Crop to return to the full captured image."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Move around the canvas",
                            bullets: [
                                "Use Zoom In, Zoom Out, 100%, or Fit in the toolbar.",
                                "Use pinch zoom, Command-scroll, or Option-scroll to zoom.",
                                "Use two-finger or mouse-wheel panning and the visible scroll tracks to pan."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Crop aids",
                            body: "Settings includes Crop Outside Dimming and out-of-capture crosshatch controls. These are editor-only aids and are not included in copied, exported, shared, or saved rendered output."
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
                            body: "Draw shapes, lines, arrows, freehand strokes, marker-style highlighter strokes, highlight boxes, rulers, spotlights, text, and callouts from the toolbar. Import Image adds an editable overlay that can be moved, resized, rotated, faded, saved, copied, exported, and shared."
                        ),
                        HelpArticleSection(
                            title: "Edit styles",
                            body: "Use the inspector to change stroke color, fill color, line width, text size, effect strength, arrow heads, arrow labels, callout style, rectangle corners, freehand smoothing, and alignment where supported. Use the editor toolbar rotate button to turn selected annotations by 90 degrees."
                        ),
                        HelpArticleSection(
                            title: "Manage layers",
                            body: "Use the Layers button in the editor toolbar or Arrange > Show Layers to open a separate Layers window. The window shows editable annotations from front to back, lets you select one or more layers, drag to reorder, group or ungroup, and delete selected layers without using the inspector."
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
                                "Select the Redaction tool.",
                                "In the inspector, choose Blur, Pixelate, or Redact.",
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
                            body: "Turn on Private Capture for screenshots that should skip archive checkpoints, Recent Snips recovery, Recycle Bin retention, and background OCR indexing for that capture session."
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
                                "Select Copy Text in the toolbar.",
                                "Drag over the text region in the screenshot.",
                                "Review the normalized text.",
                                "Copy the accepted text to the clipboard."
                            ]
                        ),
                        HelpArticleSection(
                            title: "Where OCR runs",
                            body: "Text recognition runs locally on this Mac. Capture History search can also index recognized screenshot text unless Private Capture is enabled."
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
                            body: "Use the editor toolbar Copy menu for Copy Styled or Copy Plain. Copy Styled and Share use the current rendered screenshot: crop, annotations, presentation settings when enabled, and flattened redactions. Copy Plain bypasses the presentation wrapper while keeping crop, annotations, and flattened redactions. Presentation styling changes do not auto-copy while you are in Presentation mode; use Copy Styled when you want the current styled result on the clipboard."
                        ),
                        HelpArticleSection(
                            title: "Export screenshots",
                            body: "Click Presentation in the editor toolbar to switch into a focused export workspace. Presentation mode hides annotation tools and shows Back to Edit, zoom, Save Variant, Copy Styled, Copy Plain, Export Styled, Share, Float, and drag-out actions. The Style tab handles fast native polish such as transparent, solid, gradient, spotlight, or blurred-screenshot backgrounds, spacing, corners, and shadows. Use the Scene tab for browser, window, phone, tablet, and other template-driven layouts. Transparent presentation output uses PNG so rounded corners and shadows can stay on alpha."
                        ),
                        HelpArticleSection(
                            title: "Use Presentation Scenes",
                            body: "The Scene tab applies SVG templates from the Presentation Scenes folder. Scenes are grouped as Bundled or User, can expose editable text fields, and embed a sanitized snapshot of the SVG in the .sss document so the styled export can render later without depending on the original file. Use Framing to choose Auto, Show Full, Fill, edge focus presets, or Actual Size for the screenshot slot."
                        ),
                        HelpArticleSection(
                            title: "Adjust scene framing",
                            body: "Auto tries to fit arbitrary screenshot sizes into the scene slot. If the result needs correction, open Adjust to change alignment, scale, or nudge the screenshot. Drag inside the scene screenshot slot to reposition it, use Option-scroll or pinch inside the slot to scale it, and double-click or Reset Framing to return to the scene default."
                        ),
                        HelpArticleSection(
                            title: "Save presentations in a document",
                            body: "The Variants section stores named presentation variants inside the current .sss document. Save the current style or scene as a variant, then open Manage Variants to apply, rename, update, duplicate, or delete saved variants as the document evolves. Global Style templates remain app preferences; variants travel with the .sss file."
                        ),
                        HelpArticleSection(
                            title: "Manage scene files",
                            body: "The Scene tab includes Scene Files controls for revealing the User scenes folder and reloading scene files. Settings > General > Editor still lets you choose, reveal, reset, or reload the root Presentation Scenes folder. The default folder contains Bundled and User subfolders. Add custom SVG files to User. Bundled scenes use a metadata block with schema com.oontz.snipsnipsnip.presentation-scene and data-sss-slot markers; remote URLs, file URLs, scripts, foreignObject, animation, and event handlers are rejected. Scene diagnostics appear only when there is something to review."
                        ),
                        HelpArticleSection(
                            title: "Import from Finder or Photos",
                            body: "In Finder, use Open With > SnipSnipSnip on common image files to import them into the screenshot editor. In Apple Photos, right-click a photo, choose Share, then choose SnipSnipSnip to open that photo as an editable imported image."
                        ),
                        HelpArticleSection(
                            title: "Drag output into another app",
                            body: "Drag the file icon beside Share to send the current rendered screenshot to Finder, Mail, or another app. If you click without dragging, SnipSnipSnip shows a short reminder explaining how to use drag-out sharing. During the drag, the editor window temporarily hides so you can reach the destination, then returns when the drag finishes. Settings > General > Export & Sharing controls whether screenshot drag-out normally uses PNG, JPEG, or PDF and sets JPEG quality. Transparent presentation shadows automatically use PNG so the result stays faithful."
                        ),
                        HelpArticleSection(
                            title: "Save editable work",
                            body: "Save and Save As write .sss screenshot packages or .sssvideo video packages. Use these formats when you may need to revise crop, annotations, redactions, trim range, or other editable state later."
                        ),
                        HelpArticleSection(
                            title: "Filename suggestions",
                            body: "Settings > General controls filename templates for Save As and export. Supported tokens include {kind}, {source}, {width}, {height}, {format}, and date patterns such as {yyyy-MM-dd-HH-mm-ss}."
                        )
                    ],
                    important: [
                        "Exported and copied screenshots are newly encoded so source EXIF, TIFF, GPS, IPTC, and user metadata are not carried forward."
                    ],
                    relatedIDs: ["editable-documents", "redact", "history-recovery"]
                ),
                HelpArticle(
                    id: "editable-documents",
                    title: "Use editable documents",
                    summary: "Save work as .sss or .sssvideo packages when you need to reopen and revise it.",
                    sections: [
                        HelpArticleSection(
                            title: ".sss screenshot packages",
                            body: "A .sss package keeps the base image, preview, crop, annotations, presentation settings, image overlay assets, undo and redo history, and searchable metadata."
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
                            body: "Autosave checkpoints appear in the editor inspector. You can preview, restore, delete individual snapshots, or clear the current snip's history."
                        ),
                        HelpArticleSection(
                            title: "Use Capture History search",
                            body: "Capture History search is available from the main capture screen and the inspector, and searches labels, document names, annotation text, and recognized screenshot text. The main capture screen searches all capture history and shows one row per snip session with its checkpoint count, so autosave checkpoints do not repeat the same capture. Deleting a main-screen capture history row deletes that snip session and all of its checkpoints."
                        ),
                        HelpArticleSection(
                            title: "Restore deleted snips",
                            body: "Deleted snips move to the Recycle Bin first. Preview and restore them from the main capture screen or the bottom of the editor inspector before retention cleanup removes them."
                        )
                    ],
                    important: [
                        "Private Capture skips archive checkpoints, Recent Snips recovery, Recycle Bin retention, and background OCR indexing for that capture session."
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
                            body: "Private Capture keeps the current capture out of archive checkpoints, Recent Snips recovery, Recycle Bin retention, and background OCR indexing. The setting is locked while a capture or recording is active."
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
                                "Use the menu bar icon > Screen Ruler to add horizontal and vertical rulers.",
                                "Use the menu bar icon > Screen Inspector to inspect live pixels, colors, and coordinates.",
                                "Use Settings > General to adjust ruler appearance and inspector display options."
                            ]
                        )
                    ],
                    important: [
                        "Global capture and Screen Inspector shortcuts can be customized in Settings > Shortcuts.",
                        "Single-key editor tool shortcuts can be turned off in Settings > Shortcuts."
                    ],
                    relatedIDs: ["capture-screenshot", "edit-screenshot", "screen-inspector"]
                ),
                HelpArticle(
                    id: "troubleshoot-capture",
                    title: "Solve common capture problems",
                    summary: FeatureFlags.scrollingCaptureEnabled
                        ? "Fix blank captures, missing windows, Scrolling Capture failures, and deleted snips."
                        : "Fix blank captures, missing windows, and deleted snips.",
                    sections: [
                        HelpArticleSection(
                            title: "Blank captures or missing thumbnails",
                            body: "Allow Screen Recording permission for SnipSnipSnip, then quit and reopen the app if macOS asks you to."
                        ),
                        HelpArticleSection(
                            title: "A window is missing",
                            body: "Make sure the target window is visible, then use Refresh or Auto Refresh. With Auto Refresh off, SnipSnipSnip still refreshes once whenever the app returns to the foreground. Some protected or transient windows may not be available through macOS capture APIs."
                        ),
                        HelpArticleSection(
                            title: "Work was replaced or deleted",
                            body: "Check Change History, Capture History search, or the Recycle Bin before recapturing."
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
                    ] + (FeatureFlags.scrollingCaptureEnabled
                        ? [
                            HelpArticleSection(
                                title: "Scrolling Capture does not start",
                                body: "Allow Accessibility permission. If the app is not listed, use Reveal App from the setup guide and add the exact running app in System Settings."
                            )
                        ]
                        : []),
                    important: [],
                    relatedIDs: FeatureFlags.scrollingCaptureEnabled
                        ? ["permissions", "history-recovery", "capture-scrolling"]
                        : ["permissions", "history-recovery"]
                )
            ]
        )
    ]

    private static var allArticles: [HelpArticle] {
        categories.flatMap(\.articles)
    }

    private var displayedCategories: [HelpCategory] {
        let normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return Self.categories
        }

        let matches = Self.allArticles.filter { article in
            article.searchText.localizedCaseInsensitiveContains(normalizedQuery)
        }

        return [HelpCategory(title: "Search Results", articles: matches)]
    }

    private var selectedArticle: HelpArticle {
        if let selectedArticleID,
           let article = Self.allArticles.first(where: { $0.id == selectedArticleID }) {
            return article
        }

        return Self.allArticles[0]
    }

    private var relatedArticles: [HelpArticle] {
        selectedArticle.relatedIDs.compactMap { id in
            Self.allArticles.first(where: { $0.id == id })
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
            .navigationTitle("\(AppBranding.displayName) Help")
            .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 340)
        } detail: {
            HelpArticleView(
                article: selectedArticle,
                relatedArticles: relatedArticles,
                onSelectRelated: { selectedArticleID = $0.id }
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private extension HelpArticle {
    var searchText: String {
        ([title, summary] + sections.flatMap(\.searchableText) + important).joined(separator: " ")
    }
}

private extension HelpArticleSection {
    var searchableText: [String] {
        [title, body].compactMap(\.self) + steps + bullets
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
        }
    }
}

private struct HelpImportantView: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Important", systemImage: "exclamationmark.triangle")
                .font(.headline)

            ForEach(items, id: \.self) { item in
                Text(AppBranding.branded(item))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.yellow.opacity(0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.25), lineWidth: 1)
        }
    }
}

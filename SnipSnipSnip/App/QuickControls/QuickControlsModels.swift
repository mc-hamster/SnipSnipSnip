import CoreGraphics
import Foundation

nonisolated enum QuickControlsDockMetrics {
    static let compactWidth: CGFloat = 64
    static let expandedWidth: CGFloat = 240
    static let maximumExpandedWidth: CGFloat = 280
    static let panelInset: CGFloat = 8
    static let screenEdgeInset: CGFloat = 0
    static let panelCornerRadius: CGFloat = 16
    static let controlCornerRadius: CGFloat = 10
    static let expandedControlHeight: CGFloat = 42
    static let compactControlSize: CGFloat = 42
    static let expandedHeaderHeight: CGFloat = 50
    static let compactHeaderHeight: CGFloat = 48
    static let expandedSectionHeight: CGFloat = 18
    static let compactSectionHeight: CGFloat = 9
    static let contentTopPadding: CGFloat = 3
    static let contentBottomPadding: CGFloat = 9

    static func expandedWidth(for items: [QuickControlItem]) -> CGFloat {
        let longestLabelCount = items.map { item in
            max(item.kind.label.count, item.kind.category.label.count)
        }.max() ?? 0
        let contentWidth = 96 + (CGFloat(longestLabelCount) * 5.8)
        return min(max(ceil(contentWidth), expandedWidth), maximumExpandedWidth)
    }

    static func naturalHeight(
        itemCount: Int,
        sectionCount: Int,
        presentation: QuickControlsDockState
    ) -> CGFloat {
        guard itemCount > 0 else {
            return presentation == .expanded ? 154 : 104
        }
        let headerHeight = presentation == .expanded
            ? expandedHeaderHeight
            : compactHeaderHeight
        let sectionHeight = presentation == .expanded
            ? expandedSectionHeight
            : compactSectionHeight
        let spacing: CGFloat = presentation == .expanded ? 6 : 5
        let childCount = itemCount + sectionCount
        return (panelInset * 2)
            + headerHeight
            + 1
            + contentTopPadding
            + contentBottomPadding
            + (CGFloat(itemCount) * expandedControlHeight)
            + (CGFloat(sectionCount) * sectionHeight)
            + (CGFloat(max(childCount - 1, 0)) * spacing)
    }
}

nonisolated enum QuickControlsDockState: String, CaseIterable, Codable, Identifiable, Sendable {
    case compact
    case expanded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact:
            "Compact"
        case .expanded:
            "Expanded"
        }
    }

    var width: CGFloat {
        switch self {
        case .compact:
            QuickControlsDockMetrics.compactWidth
        case .expanded:
            QuickControlsDockMetrics.expandedWidth
        }
    }
}

nonisolated enum QuickControlsDockEdge: String, CaseIterable, Codable, Identifiable, Sendable {
    case left
    case right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .left:
            "Left"
        case .right:
            "Right"
        }
    }
}

nonisolated enum QuickControlSize: String, CaseIterable, Codable, Identifiable, Sendable {
    case compact
    case standard
    case wide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact:
            "Compact"
        case .standard:
            "Standard"
        case .wide:
            "Wide"
        }
    }

    var width: CGFloat {
        switch self {
        case .compact:
            76
        case .standard:
            158
        case .wide:
            240
        }
    }

    var tileSize: CGSize {
        CGSize(width: width, height: 52)
    }
}

nonisolated enum QuickControlsPaletteVisibilityDecision: Equatable, Sendable {
    case show
    case preserve
    case hide

    static func resolve(
        isRequestedVisible: Bool,
        isPanelVisible: Bool
    ) -> QuickControlsPaletteVisibilityDecision {
        guard isRequestedVisible else {
            return .hide
        }
        return isPanelVisible ? .preserve : .show
    }
}

nonisolated struct QuickControlTileState: Equatable, Sendable {
    var isOn: Bool
    var detail: String?
    var showsMenuIndicator: Bool

    init(
        isOn: Bool = false,
        detail: String? = nil,
        showsMenuIndicator: Bool = false
    ) {
        self.isOn = isOn
        self.detail = detail
        self.showsMenuIndicator = showsMenuIndicator
    }
}

nonisolated enum QuickControlCategory: String, CaseIterable, Identifiable, Sendable {
    case screenshot
    case captureOptions
    case create
    case record
    case screenTools
    case application

    var id: String { rawValue }

    var label: String {
        switch self {
        case .screenshot:
            "Screenshot"
        case .captureOptions:
            "Capture Options"
        case .create:
            "Create"
        case .record:
            "Record"
        case .screenTools:
            "Screen Tools"
        case .application:
            "Application"
        }
    }
}

nonisolated enum QuickControlKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case captureRegion
    case captureWindow
    case captureScreen
    case captureScrollingContent
    case repeatLastCapture
    case capturePresets
    case timer
    case includeCursor
    case privateCapture
    case autoCopy
    case createComparison
    case createSteps
    case createCombinedImage
    case recordRegion
    case recordWindow
    case recordScreen
    case recordGuide
    case clipboardHistory
    case horizontalScreenRuler
    case verticalScreenRuler
    case screenInspector
    case openApplication

    var id: String { rawValue }

    var category: QuickControlCategory {
        switch self {
        case .captureRegion, .captureWindow, .captureScreen,
             .captureScrollingContent, .repeatLastCapture, .capturePresets:
            .screenshot
        case .timer, .includeCursor, .privateCapture, .autoCopy:
            .captureOptions
        case .createComparison, .createSteps, .createCombinedImage:
            .create
        case .recordRegion, .recordWindow, .recordScreen, .recordGuide:
            .record
        case .clipboardHistory, .horizontalScreenRuler,
             .verticalScreenRuler, .screenInspector:
            .screenTools
        case .openApplication:
            .application
        }
    }

    var label: String {
        switch self {
        case .captureRegion:
            "Capture " + WorkflowVocabulary.Source.region
        case .captureWindow:
            "Capture " + WorkflowVocabulary.Source.window
        case .captureScreen:
            "Capture " + WorkflowVocabulary.Source.screen
        case .captureScrollingContent:
            "Capture " + WorkflowVocabulary.Source.scrollingContent
        case .repeatLastCapture:
            "Repeat Last Capture"
        case .capturePresets:
            "Capture Presets"
        case .timer:
            "Timer"
        case .includeCursor:
            "Include Cursor"
        case .privateCapture:
            "Private Capture"
        case .autoCopy:
            "Auto Copy"
        case .createComparison:
            "Create Comparison"
        case .createSteps:
            "Create Steps"
        case .createCombinedImage:
            "Create Combined Image"
        case .recordRegion:
            "Record Region"
        case .recordWindow:
            "Record Window"
        case .recordScreen:
            "Record Screen"
        case .recordGuide:
            WorkflowVocabulary.Instructions.recordGuide
        case .clipboardHistory:
            "Clipboard History"
        case .horizontalScreenRuler:
            "Horizontal Ruler"
        case .verticalScreenRuler:
            "Vertical Ruler"
        case .screenInspector:
            "Screen Inspector"
        case .openApplication:
            "Open \(AppBranding.displayName)"
        }
    }

    var systemImage: String {
        switch self {
        case .captureRegion:
            "selection.pin.in.out"
        case .captureWindow:
            "rectangle.on.rectangle"
        case .captureScreen:
            "display"
        case .captureScrollingContent:
            "arrow.down.to.line"
        case .repeatLastCapture:
            "arrow.clockwise"
        case .capturePresets:
            "star"
        case .timer:
            "timer"
        case .includeCursor:
            "cursorarrow"
        case .privateCapture:
            "hand.raised"
        case .autoCopy:
            "doc.on.clipboard"
        case .createComparison:
            "rectangle.split.2x1"
        case .createSteps:
            "list.number"
        case .createCombinedImage:
            "square.grid.2x2"
        case .recordRegion:
            "record.circle"
        case .recordWindow:
            "video"
        case .recordScreen:
            "video.fill"
        case .recordGuide:
            "list.number"
        case .clipboardHistory:
            "clipboard"
        case .horizontalScreenRuler:
            "ruler"
        case .verticalScreenRuler:
            "ruler"
        case .screenInspector:
            "scope"
        case .openApplication:
            "menubar.rectangle"
        }
    }

    var defaultSize: QuickControlSize {
        switch self {
        case .repeatLastCapture, .privateCapture, .createCombinedImage,
             .recordGuide, .clipboardHistory, .horizontalScreenRuler,
             .verticalScreenRuler, .screenInspector, .openApplication:
            .standard
        default:
            .compact
        }
    }

    var isToggle: Bool {
        switch self {
        case .includeCursor, .privateCapture, .autoCopy:
            true
        default:
            false
        }
    }

    var capability: AppCapability? {
        switch self {
        case .captureRegion:
            .regionCapture
        case .captureWindow:
            .windowCapture
        case .captureScreen:
            .fullscreenCapture
        case .captureScrollingContent:
            .scrollingCapture
        case .repeatLastCapture:
            .repeatCapture
        case .timer:
            .timerCapture
        case .privateCapture:
            .privateCapture
        case .recordRegion, .recordWindow, .recordScreen:
            .screenRecording
        case .recordGuide:
            .guideCapture
        case .clipboardHistory:
            .clipboardHistory
        case .horizontalScreenRuler, .verticalScreenRuler:
            .screenRuler
        case .screenInspector:
            .screenInspector
        case .capturePresets, .includeCursor, .autoCopy,
             .createComparison, .createSteps, .createCombinedImage,
             .openApplication:
            nil
        }
    }

    func isAvailable(in capabilities: AppCapabilitySnapshot) -> Bool {
        capability.map(capabilities.isEnabled) ?? true
    }
}

nonisolated struct QuickControlItem: Codable, Equatable, Identifiable, Sendable {
    var kind: QuickControlKind
    var size: QuickControlSize

    var id: QuickControlKind { kind }

    init(kind: QuickControlKind, size: QuickControlSize? = nil) {
        self.kind = kind
        self.size = size ?? kind.defaultSize
    }
}

nonisolated struct QuickControlsDockSection: Equatable, Identifiable, Sendable {
    let category: QuickControlCategory
    let items: [QuickControlItem]

    var id: QuickControlCategory { category }
}

nonisolated enum QuickControlsDockGrouping {
    static func sections(for items: [QuickControlItem]) -> [QuickControlsDockSection] {
        var categoryOrder: [QuickControlCategory] = []
        var itemsByCategory: [QuickControlCategory: [QuickControlItem]] = [:]

        for item in items {
            let category = item.kind.category
            if itemsByCategory[category] == nil {
                categoryOrder.append(category)
            }
            itemsByCategory[category, default: []].append(item)
        }

        return categoryOrder.map { category in
            QuickControlsDockSection(
                category: category,
                items: itemsByCategory[category] ?? []
            )
        }
    }
}

nonisolated struct QuickControlsPanelFrame: Codable, Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(_ frame: CGRect) {
        x = frame.origin.x
        y = frame.origin.y
        width = frame.width
        height = frame.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

nonisolated struct QuickControlsPanelSize: Codable, Equatable, Sendable {
    var width: CGFloat
    var height: CGFloat

    init(_ size: CGSize) {
        width = size.width
        height = size.height
    }

    var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}

nonisolated struct QuickControlsPreferences: Codable, Equatable, Sendable {
    static let currentDensityVersion = 4
    static let legacyDefaultPanelSize = CGSize(width: 340, height: 300)
    static let legacyCompactGridPanelSize = CGSize(width: 284, height: 240)
    static let defaultItems: [QuickControlItem] = [
        QuickControlItem(kind: .captureRegion),
        QuickControlItem(kind: .captureWindow),
        QuickControlItem(kind: .captureScreen),
        QuickControlItem(kind: .repeatLastCapture, size: .standard),
        QuickControlItem(kind: .capturePresets),
        QuickControlItem(kind: .timer),
    ]

    static var defaultPanelSize: CGSize {
        let sections = QuickControlsDockGrouping.sections(for: defaultItems)
        return CGSize(
            width: QuickControlsDockMetrics.expandedWidth(for: defaultItems),
            height: QuickControlsDockMetrics.naturalHeight(
                itemCount: defaultItems.count,
                sectionCount: sections.count,
                presentation: .expanded
            )
        )
    }

    static let `default` = QuickControlsPreferences(
        isVisible: false,
        items: defaultItems,
        panelFrame: nil,
        preferredPanelSize: QuickControlsPanelSize(defaultPanelSize)
    )

    var isVisible: Bool
    var items: [QuickControlItem]
    var panelFrame: QuickControlsPanelFrame?
    var preferredPanelSize: QuickControlsPanelSize? = nil
    var densityVersion: Int? = currentDensityVersion
    var dockState: QuickControlsDockState? = .expanded
    var dockEdge: QuickControlsDockEdge? = .right

    var resolvedDockState: QuickControlsDockState {
        dockState ?? .expanded
    }

    var resolvedDockEdge: QuickControlsDockEdge {
        dockEdge ?? .right
    }

    var resolvedPanelSize: CGSize {
        let presentation = resolvedDockState
        let sections = QuickControlsDockGrouping.sections(for: items)
        return CGSize(
            width: presentation == .expanded
                ? QuickControlsDockMetrics.expandedWidth(for: items)
                : presentation.width,
            height: QuickControlsDockMetrics.naturalHeight(
                itemCount: items.count,
                sectionCount: sections.count,
                presentation: presentation
            )
        )
    }

    func migratedToCurrentDock() -> QuickControlsPreferences {
        var result = self
        guard (result.densityVersion ?? 1) < Self.currentDensityVersion else {
            return result.sanitized()
        }

        result.dockState = result.dockState ?? .expanded
        result.dockEdge = result.dockEdge ?? .right
        let size = result.resolvedPanelSize
        result.preferredPanelSize = QuickControlsPanelSize(size)
        if let panelFrame = result.panelFrame?.cgRect {
            result.panelFrame = QuickControlsPanelFrame(
                CGRect(origin: panelFrame.origin, size: size)
            )
        }
        result.densityVersion = Self.currentDensityVersion
        return result.sanitized()
    }

    func sanitized() -> QuickControlsPreferences {
        var result = self
        var seen = Set<QuickControlKind>()
        result.items = items.filter { seen.insert($0.kind).inserted }
        if let frame = result.panelFrame {
            let size = result.resolvedPanelSize
            result.panelFrame = QuickControlsPanelFrame(
                CGRect(
                    x: frame.x,
                    y: frame.y,
                    width: size.width,
                    height: size.height
                )
            )
        }
        let size = result.resolvedPanelSize
        result.preferredPanelSize = QuickControlsPanelSize(size)
        return result
    }
}

import AppKit
import Combine
import Foundation

@MainActor
final class QuickControlsModel: ObservableObject {
    let capabilities: AppCapabilitySnapshot
    let lifecycle: AppLifecycleModel
    let capture: CaptureWorkflowModel
    let clipboard: ClipboardWorkflowModel
    let video: VideoWorkflowModel
    let guide: GuideWorkflowModel
    let tools: ToolWorkflowModel
    let creation: CreationWorkflowModel

    private let preferenceStore: QuickControlsPreferenceStore
    var showCustomizationHandler: (() -> Void)?

    @Published var preferences: QuickControlsPreferences {
        didSet {
            let sanitized = preferences.sanitized()
            if sanitized != preferences {
                preferences = sanitized
                return
            }
            preferenceStore.savePreferences(preferences)
        }
    }

    init(
        capabilities: AppCapabilitySnapshot,
        lifecycle: AppLifecycleModel,
        capture: CaptureWorkflowModel,
        clipboard: ClipboardWorkflowModel,
        video: VideoWorkflowModel,
        guide: GuideWorkflowModel,
        tools: ToolWorkflowModel,
        creation: CreationWorkflowModel,
        preferenceStore: QuickControlsPreferenceStore
    ) {
        self.capabilities = capabilities
        self.lifecycle = lifecycle
        self.capture = capture
        self.clipboard = clipboard
        self.video = video
        self.guide = guide
        self.tools = tools
        self.creation = creation
        self.preferenceStore = preferenceStore
        self.preferences = preferenceStore.loadPreferences()
    }

    var isVisible: Bool {
        preferences.isVisible
    }

    var configuredKinds: Set<QuickControlKind> {
        Set(preferences.items.map(\.kind))
    }

    var catalogByCategory: [(category: QuickControlCategory, kinds: [QuickControlKind])] {
        QuickControlCategory.allCases.compactMap { category in
            let kinds = QuickControlKind.allCases.filter {
                $0.category == category
                    && $0.isAvailable(in: capabilities)
            }
            return kinds.isEmpty ? nil : (category, kinds)
        }
    }

    var isCaptureActionDisabled: Bool {
        capture.isWorking
            || video.blocksNewCapture
            || guide.isActive
            || capture.isConnectedDeviceSessionActive
    }

    var activeStatusLabel: String? {
        if guide.isActive {
            return "Guide Active"
        }
        if video.blocksNewCapture {
            return "Recording"
        }
        if capture.isWorking {
            return lifecycle.workingMessage
        }
        return nil
    }

    func tileState(for kind: QuickControlKind) -> QuickControlTileState {
        switch kind {
        case .capturePresets:
            QuickControlTileState(
                detail: capture.capturePresets.isEmpty ? "None Saved" : "Choose a Preset",
                showsMenuIndicator: true
            )
        case .timer:
            QuickControlTileState(
                isOn: capture.captureDelay != .immediate,
                detail: capture.captureDelay == .immediate
                    ? "Off"
                    : "\(capture.captureDelay.countdownSeconds) Seconds",
                showsMenuIndicator: true
            )
        case .includeCursor:
            QuickControlTileState(
                isOn: capture.screenshotIncludesCursor,
                detail: capture.screenshotIncludesCursor ? "On" : "Off"
            )
        case .privateCapture:
            QuickControlTileState(
                isOn: capture.privateCaptureEnabled,
                detail: capture.privateCaptureEnabled ? "On" : "Off"
            )
        case .autoCopy:
            QuickControlTileState(
                isOn: clipboard.autoCopyEnabled,
                detail: clipboard.autoCopyEnabled ? "On" : "Off"
            )
        default:
            QuickControlTileState()
        }
    }

    func setVisible(_ visible: Bool) {
        var updated = preferences
        updated.isVisible = visible
        preferences = updated
    }

    func toggleVisibility() {
        setVisible(!isVisible)
    }

    func showCustomization() {
        showCustomizationHandler?()
    }

    @discardableResult
    func add(_ kind: QuickControlKind, after anchor: QuickControlKind? = nil) -> Bool {
        guard kind.isAvailable(in: capabilities), !configuredKinds.contains(kind) else {
            return false
        }
        var updated = preferences
        let item = QuickControlItem(kind: kind)
        if let anchor,
           let anchorIndex = updated.items.firstIndex(where: { $0.kind == anchor }) {
            updated.items.insert(item, at: anchorIndex + 1)
        } else {
            updated.items.append(item)
        }
        preferences = updated
        return true
    }

    @discardableResult
    func remove(_ kind: QuickControlKind) -> Bool {
        guard configuredKinds.contains(kind) else {
            return false
        }
        var updated = preferences
        updated.items.removeAll { $0.kind == kind }
        preferences = updated
        return true
    }

    func moveItem(_ kind: QuickControlKind, by offset: Int) {
        let sections = QuickControlsDockGrouping.sections(for: preferences.items)
        guard let sectionIndex = sections.firstIndex(where: { $0.category == kind.category }),
              let itemIndex = sections[sectionIndex].items.firstIndex(where: { $0.kind == kind }) else {
            return
        }
        let destination = min(max(itemIndex + offset, 0), sections[sectionIndex].items.count - 1)
        guard destination != itemIndex else {
            return
        }
        var reorderedSections = sections
        let item = reorderedSections[sectionIndex].items[itemIndex]
        var reorderedItems = reorderedSections[sectionIndex].items
        reorderedItems.remove(at: itemIndex)
        reorderedItems.insert(item, at: destination)
        reorderedSections[sectionIndex] = QuickControlsDockSection(
            category: reorderedSections[sectionIndex].category,
            items: reorderedItems
        )
        applySections(reorderedSections)
    }

    @discardableResult
    func moveItem(_ kind: QuickControlKind, before target: QuickControlKind) -> Bool {
        moveItem(kind, relativeTo: target, insertAfterTarget: false)
    }

    @discardableResult
    func moveItem(_ kind: QuickControlKind, after target: QuickControlKind) -> Bool {
        moveItem(kind, relativeTo: target, insertAfterTarget: true)
    }

    private func moveItem(
        _ kind: QuickControlKind,
        relativeTo target: QuickControlKind,
        insertAfterTarget: Bool
    ) -> Bool {
        guard kind != target,
              kind.category == target.category else {
            return false
        }
        var sections = QuickControlsDockGrouping.sections(for: preferences.items)
        guard let sectionIndex = sections.firstIndex(where: { $0.category == kind.category }),
              let sourceIndex = sections[sectionIndex].items.firstIndex(where: { $0.kind == kind }) else {
            return false
        }
        var items = sections[sectionIndex].items
        let item = items.remove(at: sourceIndex)
        guard let targetIndex = items.firstIndex(where: { $0.kind == target }) else {
            return false
        }
        items.insert(item, at: targetIndex + (insertAfterTarget ? 1 : 0))
        sections[sectionIndex] = QuickControlsDockSection(
            category: sections[sectionIndex].category,
            items: items
        )
        applySections(sections)
        return true
    }

    func moveSection(_ category: QuickControlCategory, before target: QuickControlCategory) {
        guard category != target else {
            return
        }
        let sections = QuickControlsDockGrouping.sections(for: preferences.items)
        var categories = sections.map(\.category)
        guard let sourceIndex = categories.firstIndex(of: category) else {
            return
        }
        categories.remove(at: sourceIndex)
        guard let targetIndex = categories.firstIndex(of: target) else {
            return
        }
        categories.insert(category, at: targetIndex)
        applySectionOrder(categories)
    }

    func moveSection(_ category: QuickControlCategory, by offset: Int) {
        let sections = QuickControlsDockGrouping.sections(for: preferences.items)
        var categories = sections.map(\.category)
        guard let sourceIndex = categories.firstIndex(of: category) else {
            return
        }
        let destination = min(max(sourceIndex + offset, 0), categories.count - 1)
        guard destination != sourceIndex else {
            return
        }
        categories.remove(at: sourceIndex)
        categories.insert(category, at: destination)
        applySectionOrder(categories)
    }

    private func applySectionOrder(_ categories: [QuickControlCategory]) {
        let itemsByCategory = Dictionary(grouping: preferences.items) { $0.kind.category }
        applySections(categories.map { category in
            QuickControlsDockSection(category: category, items: itemsByCategory[category] ?? [])
        })
    }

    private func applySections(_ sections: [QuickControlsDockSection]) {
        var updated = preferences
        updated.items = sections.flatMap(\.items)
        preferences = updated
    }

    func updateSize(_ size: QuickControlSize, for kind: QuickControlKind) {
        guard let index = preferences.items.firstIndex(where: { $0.kind == kind }) else {
            return
        }
        var updated = preferences
        updated.items[index].size = size
        preferences = updated
    }

    func setDockState(_ state: QuickControlsDockState) {
        var updated = preferences
        updated.dockState = state
        preferences = updated
    }

    func toggleDockState() {
        setDockState(preferences.resolvedDockState == .expanded ? .compact : .expanded)
    }

    func setDockEdge(_ edge: QuickControlsDockEdge) {
        var updated = preferences
        updated.dockEdge = edge
        preferences = updated
    }

    func recordPanelFrame(_ frame: CGRect, dockEdge: QuickControlsDockEdge) {
        var updated = preferences
        updated.dockEdge = dockEdge
        updated.panelFrame = QuickControlsPanelFrame(frame)
        updated.preferredPanelSize = QuickControlsPanelSize(frame.size)
        preferences = updated
    }

    func restoreDefaultLayout() {
        var updated = preferences
        updated.items = QuickControlsPreferences.defaultItems
        updated.dockState = .expanded
        updated.dockEdge = .right
        preferences = updated
    }

    func resetPreferencesToDefaults() {
        preferences = .default
    }

    func perform(_ kind: QuickControlKind) {
        switch kind {
        case .captureRegion:
            capture.captureRegion()
        case .captureWindow:
            capture.presentWindowPicker()
        case .captureScreen:
            capture.captureCurrentDisplay()
        case .captureScrollingContent:
            capture.captureScrollingArea()
        case .repeatLastCapture:
            capture.repeatLastCapture()
        case .createComparison:
            creation.presentQuickStart(prefilledDraft: CreationDraft(goal: .comparison))
            requestMainWindowPresentation()
        case .createSteps:
            creation.presentQuickStart(prefilledDraft: CreationDraft(goal: .instructions(.addCaptures)))
            requestMainWindowPresentation()
        case .createCombinedImage:
            creation.presentQuickStart(prefilledDraft: CreationDraft(goal: .combineImages))
            requestMainWindowPresentation()
        case .recordRegion:
            video.recordRegion()
        case .recordWindow:
            video.presentVideoWindowPicker()
        case .recordScreen:
            video.recordCurrentDisplay()
        case .recordGuide:
            guide.presentQuickStart()
            requestMainWindowPresentation()
        case .clipboardHistory:
            clipboard.showClipboardManager()
        case .horizontalScreenRuler:
            tools.presentScreenRuler(.horizontal)
        case .verticalScreenRuler:
            tools.presentScreenRuler(.vertical)
        case .screenInspector:
            tools.toggleScreenInspector()
        case .openApplication:
            requestMainWindowPresentation()
        case .capturePresets, .timer, .includeCursor, .privateCapture, .autoCopy:
            break
        }
    }

    func isDisabled(_ kind: QuickControlKind) -> Bool {
        guard kind.isAvailable(in: capabilities) else {
            return true
        }

        switch kind {
        case .captureRegion, .captureWindow, .captureScreen,
             .captureScrollingContent, .recordRegion, .recordWindow,
             .recordScreen, .recordGuide, .createComparison,
             .createSteps, .createCombinedImage:
            return isCaptureActionDisabled
        case .repeatLastCapture:
            return isCaptureActionDisabled || !capture.canRepeatLastCapture
        case .privateCapture:
            return !capture.canChangePrivateCapture
        case .capturePresets:
            return isCaptureActionDisabled
        case .timer, .includeCursor, .autoCopy, .clipboardHistory,
             .horizontalScreenRuler, .verticalScreenRuler,
             .screenInspector, .openApplication:
            return false
        }
    }

    private func requestMainWindowPresentation() {
        NotificationCenter.default.post(name: .sssOpenMainWindowRequest, object: nil)
    }
}

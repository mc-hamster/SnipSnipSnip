import AppKit
import SwiftUI

extension Notification.Name {
    /// Shared entry point for menu and shortcut commands that must follow the
    /// active document's intent, including the first-add purpose chooser.
    static let sssRequestContextualCaptureAddition = Notification.Name(
        "sssRequestContextualCaptureAddition"
    )
}

struct EditorView: View {
    @ObservedObject var controller: EditorController
    @Binding var isInspectorPresented: Bool
    let historyEntries: [DocumentHistoryEntry]
    let recentSnipEntries: [DocumentHistoryEntry]
    let captureHistoryEntries: [DocumentHistoryEntry]
    let recycleBinEntries: [DocumentHistoryEntry]
    @Binding var captureSearchQuery: String
    let captureHistorySearchResultsLabel: String
    let historyActions: EditorHistoryActions
    var compositionActions: CompositionInspectorActions = .unavailable
    @State private var previewedHistoryEntry: DocumentHistoryEntry?

    var body: some View {
        ZStack {
            EditorCanvasScrollContainer(controller: controller)

            if let entry = previewedHistoryEntry {
                HistoryPreviewOverlayView(
                    entry: entry,
                    onClose: {
                        previewedHistoryEntry = nil
                    },
                    onFloat: {
                        historyActions.onFloatHistoryEntry(entry)
                    },
                    onRestore: {
                        previewedHistoryEntry = nil
                        historyActions.onRestoreHistoryEntry(entry)
                    }
                )
                    .zIndex(1)
            }

            if let notice = controller.notice {
                HStack(spacing: 10) {
                    Text(notice.message)
                        .font(.caption.weight(.medium))

                    if let action = notice.action {
                        Button(action.title) {
                            performNoticeAction(action)
                        }
                        .buttonStyle(.borderless)
                    }

                    Button {
                        controller.dismissNotice()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss notification")
                    .help("Dismiss notification")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .sssFloatingOverlaySurface(cornerRadius: 18, shadowOpacity: 0.10)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(notice.accessibilityAnnouncement)
                .accessibilityIdentifier("editor.notice")
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .inspector(isPresented: $isInspectorPresented) {
            EditorInspectorView(
                controller: controller,
                historyEntries: historyEntries,
                recentSnipEntries: recentSnipEntries,
                captureHistoryEntries: captureHistoryEntries,
                recycleBinEntries: recycleBinEntries,
                captureSearchQuery: $captureSearchQuery,
                captureHistorySearchResultsLabel: captureHistorySearchResultsLabel,
                actions: historyActions,
                compositionActions: compositionActions,
                previewedHistoryEntry: $previewedHistoryEntry
            )
            .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sssToggleEditorInspector)) { _ in
            isInspectorPresented.toggle()
        }
        .alert("Editor Error", isPresented: Binding(get: {
            controller.errorMessage != nil
        }, set: { value in
            if !value {
                controller.dismissError()
            }
        })) {
            Button("OK", role: .cancel) {
                controller.dismissError()
            }
        } message: {
            Text(controller.errorMessage ?? "")
        }
        .sheet(isPresented: Binding(get: {
            controller.ocrReviewText != nil
        }, set: { value in
            if !value {
                controller.dismissOCRReview()
            }
        })) {
            OCRReviewView(
                text: Binding(get: {
                    controller.ocrReviewText ?? ""
                }, set: { value in
                    controller.ocrReviewText = value
                }),
                onCopy: controller.copyOCRReviewTextToClipboard,
                onCancel: controller.dismissOCRReview
            )
            .frame(width: 480, height: 320)
        }
        .onExitCommand {
            if previewedHistoryEntry != nil {
                previewedHistoryEntry = nil
            }
        }
    }

    private func performNoticeAction(_ action: EditorNoticeAction) {
        switch action {
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        controller.dismissNotice()
    }
}

private struct EditorCanvasScrollContainer: View {
    @ObservedObject var controller: EditorController

    private let scrollerThickness: CGFloat = 20

    var body: some View {
        GeometryReader { proxy in
            if controller.workspaceMode == .presentation {
                PresentationModeCanvasView(controller: controller)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            } else {
                let canvasWidth = max(proxy.size.width - scrollerThickness, 0)
                let canvasHeight = max(proxy.size.height - scrollerThickness, 0)

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        AnnotationCanvasContainer(controller: controller)
                            .frame(width: canvasWidth, height: canvasHeight)

                        ViewportScrollbar(
                            axis: .vertical,
                            controller: controller,
                            thickness: scrollerThickness
                        )
                        .frame(width: scrollerThickness, height: canvasHeight)
                    }

                    HStack(spacing: 0) {
                        ViewportScrollbar(
                            axis: .horizontal,
                            controller: controller,
                            thickness: scrollerThickness
                        )
                        .frame(width: canvasWidth, height: scrollerThickness)

                        Rectangle()
                            .fill(Color.black.opacity(0.40))
                            .overlay {
                                Rectangle()
                                    .stroke(Color.white.opacity(0.34), lineWidth: 1)
                            }
                            .frame(width: scrollerThickness, height: scrollerThickness)
                    }
                }
                .clipped()
            }
        }
    }
}

private struct ViewportScrollbar: View {
    enum Axis {
        case horizontal
        case vertical
    }

    private var crossAxisInset: CGFloat {
        axis == .vertical ? 2 : 4
    }

    let axis: Axis
    @ObservedObject var controller: EditorController
    let thickness: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let metrics = scrollbarMetrics(in: proxy.size)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.black.opacity(0.40))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.white.opacity(0.34), lineWidth: 1)
                    }

                RoundedRectangle(cornerRadius: thickness / 2, style: .continuous)
                    .fill(Color.white.opacity(metrics.isEnabled ? 0.88 : 0.58))
                    .frame(
                        width: axis == .horizontal ? metrics.knobLength : max(thickness - crossAxisInset * 2, 6),
                        height: axis == .vertical ? metrics.knobLength : max(thickness - crossAxisInset * 2, 6)
                    )
                    .offset(
                        x: axis == .horizontal ? metrics.knobOffset : crossAxisInset,
                        y: axis == .vertical ? metrics.knobOffset : crossAxisInset
                    )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        updateScrollPosition(using: value.location, metrics: metrics)
                    }
            )
        }
    }

    private func scrollbarMetrics(in size: CGSize) -> (isEnabled: Bool, position: CGFloat, knobLength: CGFloat, knobOffset: CGFloat, travel: CGFloat) {
        let isEnabled: Bool
        let position: CGFloat
        let knobProportion: CGFloat
        let trackLength: CGFloat

        switch axis {
        case .horizontal:
            isEnabled = controller.viewport.canScrollHorizontally
            position = controller.viewport.horizontalScrollPosition
            knobProportion = controller.viewport.horizontalScrollKnobProportion
            trackLength = max(size.width, 0)
        case .vertical:
            isEnabled = controller.viewport.canScrollVertically
            position = controller.viewport.verticalScrollPosition
            knobProportion = controller.viewport.verticalScrollKnobProportion
            trackLength = max(size.height, 0)
        }

        let inset: CGFloat = 4
        let effectiveTrackLength = max(trackLength - inset * 2, 0)
        let visibleKnobProportion = isEnabled ? knobProportion : 0.55
        let knobLength = min(
            max(effectiveTrackLength * visibleKnobProportion, 28),
            effectiveTrackLength
        )
        let travel = max(effectiveTrackLength - knobLength, 0)
        let knobOffset = inset + travel * min(max(position, 0), 1)

        return (isEnabled, position, knobLength, knobOffset, travel)
    }

    private func updateScrollPosition(using location: CGPoint, metrics: (isEnabled: Bool, position: CGFloat, knobLength: CGFloat, knobOffset: CGFloat, travel: CGFloat)) {
        guard metrics.travel > 0 else {
            return
        }

        let inset: CGFloat = 4
        let coordinate = axis == .horizontal ? location.x : location.y
        let target = min(max((coordinate - inset - metrics.knobLength / 2) / metrics.travel, 0), 1)

        switch axis {
        case .horizontal:
            controller.scrollViewport(horizontalPosition: target)
        case .vertical:
            controller.scrollViewport(verticalPosition: target)
        }
    }
}

enum EditorToolbarMode {
    case standard
    case guideStep(onApply: () -> Void)

    var isGuideStep: Bool {
        if case .guideStep = self { return true }
        return false
    }

    var backTitle: String { isGuideStep ? "Cancel" : "Discard" }

    var backHelp: String {
        isGuideStep
            ? "Cancel Advanced Edit and leave this Guide step unchanged."
            : "Discard the current editor session and return to the capture screen."
    }

    var applyAction: (() -> Void)? {
        guard case .guideStep(let onApply) = self else { return nil }
        return onApply
    }
}

struct CompositionAddSourceAction: Identifiable {
    let id: String
    let title: String
    let action: () -> Void
    let flattenedAction: () -> Void
}

struct CompositionAddActions {
    let addRegion: () -> Void
    let addWindow: () -> Void
    let addFrontmostWindow: () -> Void
    let addFullScreen: () -> Void
    let addRepeat: () -> Void
    let canRepeat: Bool
    let captureDelay: CaptureDelay
    let addTimedRegion: (CaptureDelay) -> Void
    let addScrolling: (() -> Void)?
    let addScreenInspector: (() -> Void)?
    let connectedDevices: [CompositionAddSourceAction]
    let importImages: () -> Void
    let pasteImage: () -> Void
    let recentSnips: [CompositionAddSourceAction]
    let captureHistory: [CompositionAddSourceAction]
    let archive: [CompositionAddSourceAction]
    var actionsForCompletionRole:
        ((CaptureCompletionRole) -> CompositionAddActions)? = nil
}

enum ContextualCompositionAdditionSource: Equatable {
    case region
    case window
    case frontmostWindow
    case fullScreen
    case repeatLast
    case timedRegion(CaptureDelay)
    case scrolling
    case connectedDevice(String)
    case screenInspector
    case importImages
    case pasteImage
    case recentSnip(UUID, flattened: Bool)
    case captureHistory(UUID, flattened: Bool)
    case archive(UUID, flattened: Bool)

    func perform(using actions: CompositionAddActions) {
        switch self {
        case .region:
            actions.addRegion()
        case .window:
            actions.addWindow()
        case .frontmostWindow:
            actions.addFrontmostWindow()
        case .fullScreen:
            actions.addFullScreen()
        case .repeatLast:
            actions.addRepeat()
        case .timedRegion(let delay):
            actions.addTimedRegion(delay)
        case .scrolling:
            actions.addScrolling?()
        case .connectedDevice(let deviceID):
            actions.connectedDevices.first(where: { $0.id == deviceID })?.action()
        case .screenInspector:
            actions.addScreenInspector?()
        case .importImages:
            actions.importImages()
        case .pasteImage:
            actions.pasteImage()
        case .recentSnip(let id, let flattened):
            performHistoryAction(
                actions.recentSnips.first(where: { $0.id == id.uuidString }),
                flattened: flattened
            )
        case .captureHistory(let id, let flattened):
            performHistoryAction(
                actions.captureHistory.first(where: { $0.id == id.uuidString }),
                flattened: flattened
            )
        case .archive(let id, let flattened):
            performHistoryAction(
                actions.archive.first(where: { $0.id == id.uuidString }),
                flattened: flattened
            )
        }
    }

    private func performHistoryAction(
        _ source: CompositionAddSourceAction?,
        flattened: Bool
    ) {
        guard let source else { return }
        if flattened {
            source.flattenedAction()
        } else {
            source.action()
        }
    }
}

private struct FirstAdditionPurposeSheet: View {
    let onChoose: (CaptureCompletionRole) -> Void
    let onCancel: () -> Void
    @FocusState private var isCompareFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Form {
                InsetGroupBox(spacing: 14) {
                    Text(
                        "Choose what you are making. Images you add later will use the same choice."
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    FirstAdditionPurposeChoiceButton(
                        title: "Compare",
                        detail:
                            "Compare is for showing Before and After together or highlighting what changed.",
                        systemImage: "rectangle.split.2x1"
                    ) {
                        onChoose(.comparisonAfter)
                    }
                    .focused($isCompareFocused)

                    FirstAdditionPurposeChoiceButton(
                        title: "Add as Step",
                        detail:
                            "Add as Step is for putting captures in order, then adding captions and numbers.",
                        systemImage: "list.number"
                    ) {
                        onChoose(.step)
                    }

                    FirstAdditionPurposeChoiceButton(
                        title: "Combine",
                        detail:
                            "Combine is for arranging several captures and images as one result.",
                        systemImage: "rectangle.3.group"
                    ) {
                        onChoose(.collectionItem)
                    }
                } label: {
                    Text("How do you want to use the second image?")
                        .font(.title2.weight(.semibold))
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()

                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 430)
        .accessibilityIdentifier("composition.firstAdditionPurpose")
        .onAppear {
            isCompareFocused = true
        }
    }
}

private struct FirstAdditionPurposeChoiceButton: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)

                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(detail))
        .help(Text(detail))
    }
}

struct EditorCommandBar: View {
    private static let primaryTools: [EditorTool] = [.select, .crop]
    private static let shapeTools: [EditorTool] = [.rectangle, .ellipse, .line, .arrow, .statusMark, .measure]
    private static let drawingTools: [EditorTool] = [.freehand, .highlighter, .highlight, .spotlight]
    private static let textTools: [EditorTool] = [.text, .callout]
    private static let utilityTools: [EditorTool] = [.ocrText, .colorPicker]

    @ObservedObject var controller: EditorController
    @Binding var isInspectorPresented: Bool
    let onBack: () -> Void
    let onFloatReference: (ScreenshotOutputAppearance) -> Void
    let onExportPNG: (ScreenshotOutputAppearance) -> Void
    let onExportJPEG: (ScreenshotOutputAppearance) -> Void
    let onExportPDF: (ScreenshotOutputAppearance) -> Void
    var onExportComposition: (CompositionOutputFormat, ScreenshotOutputAppearance) -> Void = { _, _ in }
    let onCopy: (ScreenshotOutputAppearance) -> Void
    let onShare: (ScreenshotOutputAppearance) -> Void
    let onShowLayers: () -> Void
    let onShowUIMap: () -> Void
    let dragOutPayloadProvider: @MainActor (ScreenshotOutputAppearance) -> PromisedFilePayload?
    var compositionAddActions: CompositionAddActions?
    var mode: EditorToolbarMode = .standard
    @State private var isShowingFirstAdditionPurpose = false
    @State private var pendingFirstAddition:
        ((CompositionAddActions) -> Void)?

    var body: some View {
        Group {
            if controller.workspaceMode == .presentation, !mode.isGuideStep {
                presentationCommands
            } else {
                editCommands
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(
            isPresented: $isShowingFirstAdditionPurpose,
            onDismiss: {
                pendingFirstAddition = nil
            }
        ) {
            FirstAdditionPurposeSheet(
                onChoose: { role in
                    isShowingFirstAdditionPurpose = false
                    completeFirstAddition(with: role)
                },
                onCancel: {
                    pendingFirstAddition = nil
                    isShowingFirstAdditionPurpose = false
                }
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .sssRequestContextualCaptureAddition
            )
        ) { notification in
            let source =
                notification.object
                    as? ContextualCompositionAdditionSource
                ?? .region
            requestCompositionAddition {
                source.perform(using: $0)
            }
        }
    }

    private var editCommands: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if controller.compositionEditingScope != .layout, !mode.isGuideStep {
                        Button(action: controller.finishCompositionEditing) {
                            Label("Done", systemImage: "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .keyboardShortcut(.defaultAction)
                        .help("Apply these edits and return to the focused content stage.")

                        Text(controller.compositionEditingScopeTitle ?? "Composition Editing")
                            .font(.headline)
                            .lineLimit(1)
                            .accessibilityAddTraits(.isHeader)

                        if case .item = controller.compositionEditingScope {
                            Button(action: controller.selectPreviousCompositionItemForEditing) {
                                Image(systemName: "chevron.left")
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.circle)
                            .disabled(!controller.canSelectPreviousCompositionItem)
                            .help("Edit Previous Item")
                            .accessibilityLabel("Edit Previous Item")

                            Button(action: controller.selectNextCompositionItemForEditing) {
                                Image(systemName: "chevron.right")
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.circle)
                            .disabled(!controller.canSelectNextCompositionItem)
                            .help("Edit Next Item")
                            .accessibilityLabel("Edit Next Item")
                        }
                    } else {
                        Button(action: onBack) {
                            Label(mode.backTitle, systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .help(mode.backHelp)
                    }

                    if mode.isGuideStep {
                        Text("Advanced Step Edit")
                            .font(.headline)
                            .lineLimit(1)
                    }

                    EditorCommandGroup("Selection tools") {
                        toolButtons(Self.primaryTools)
                    }
                    EditorCommandGroup("Shape tools") {
                        toolButtons(Self.shapeTools)
                    }
                    EditorCommandGroup("Drawing and highlight tools") {
                        toolButtons(Self.drawingTools)
                    }
                    EditorCommandGroup("Text and callout tools") {
                        toolButtons(Self.textTools)
                    }
                    EditorCommandGroup("Redaction tools") {
                        redactionControl
                    }
                    EditorCommandGroup("Recognition and image tools") {
                        toolButtons(Self.utilityTools)
                        insertImageButton
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    EditorCommandGroup("History") {
                        undoButton
                        redoButton
                    }
                    EditorCommandGroup("Layers and arrangement") {
                        arrangementCommands
                    }
                    EditorCommandGroup("Zoom") {
                        zoomCommands
                    }
                    EditorCommandGroup("Inspector") {
                        inspectorToggle
                    }

                    if let applyAction = mode.applyAction {
                        Button("Apply to Step", action: applyAction)
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .help("Save these annotations on this Guide step and return to the Guide editor.")
                    } else if controller.compositionEditingScope == .layout {
                        EditorCommandGroup("Output") {
                            documentOutputCommands
                        }
                        EditorCommandGroup("References and drag out") {
                            referenceCommands
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityIdentifier("editor.commandBar.edit.secondary.scroll")
        }
    }

    private var presentationCommands: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if controller.workflowStage != .polishing {
                    Button(action: leaveCurrentWorkspace) {
                        Label(
                            "Annotate Result",
                            systemImage: EditorWorkspaceMode.edit.systemImage
                        )
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .help(currentWorkspaceBackHelp)
                    .accessibilityIdentifier("editor.backToEdit")
                }

                EditorCommandGroup("History") {
                    undoButton
                    redoButton
                }
                EditorCommandGroup("Zoom") {
                    zoomCommands
                }
                EditorCommandGroup("Inspector") {
                    inspectorToggle
                }

                EditorCommandGroup("Output") {
                    outputCommands(appearance: controller.currentWorkspaceOutputAppearance)
                }
                EditorCommandGroup("References and drag out") {
                    referenceCommands
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityIdentifier("editor.commandBar.presentation.scroll")
    }

    @ViewBuilder
    private var arrangementCommands: some View {
        Button(action: onShowLayers) {
            Image(systemName: "square.3.layers.3d")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help("Show Layers")
        .accessibilityLabel("Show Layers")
        .accessibilityIdentifier("editor.layers.show")

        if controller.capabilities.isEnabled(.uiMap), controller.capture.kind == .window {
            Button(action: onShowUIMap) {
                Image(systemName: "rectangle.3.group")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .help(uiMapButtonHelpText)
            .accessibilityLabel("Show UI Map")
            .disabled(controller.uiMapSnapshot == nil && !controller.isProcessingUIMap)

            toolButton(.uiMapInspect)
        }

        Button(action: controller.rotateSelectedClockwise90) {
            Image(systemName: "rotate.right")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help("Rotate selected annotation 90 degrees clockwise.")
        .accessibilityLabel("Rotate Clockwise")
        .disabled(!controller.canRotateSelection)

        Button(action: controller.deleteSelected) {
            Image(systemName: "trash")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help(deleteSelectionHelpText)
        .accessibilityLabel(deleteSelectionHelpText)
        .disabled(controller.selectedCount == 0)
    }

    private var undoButton: some View {
        Button(action: controller.undo) {
            Image(systemName: "arrow.uturn.backward")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help("Undo")
        .accessibilityLabel("Undo")
        .disabled(!controller.canUndo)
    }

    private var redoButton: some View {
        Button(action: controller.redo) {
            Image(systemName: "arrow.uturn.forward")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help("Redo")
        .accessibilityLabel("Redo")
        .disabled(!controller.canRedo)
    }

    @ViewBuilder
    private var zoomCommands: some View {
        Button(action: controller.zoomOut) {
            Image(systemName: "minus.magnifyingglass")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help("Zoom Out")
        .accessibilityLabel("Zoom Out")
        .disabled(!controller.canZoomOut)

        Text(controller.zoomPercentageLabel)
            .font(.caption.monospacedDigit().weight(.semibold))
            .frame(minWidth: 42)
            .accessibilityLabel("Zoom")
            .accessibilityValue(controller.zoomPercentageLabel)

        Button(action: controller.zoomIn) {
            Image(systemName: "plus.magnifyingglass")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help("Zoom In")
        .accessibilityLabel("Zoom In")
        .disabled(!controller.canZoomIn)

        Button(action: controller.zoomToFit) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help("Fit to Window")
        .accessibilityLabel("Fit to Window")

        Button(action: controller.zoomToActualSize) {
            Image(systemName: "1.magnifyingglass")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help("Actual Size")
        .accessibilityLabel("Actual Size")
    }

    private func leaveCurrentWorkspace() {
        if controller.workflowStage == .polishing {
            controller.leavePolish()
            if controller.documentPurpose == .screenshot {
                controller.setWorkspaceMode(.edit)
            } else {
                controller.presentationInspectorTab = .layout
                controller.setWorkspaceMode(.presentation)
            }
        } else if controller.hasComposition {
            controller.enterCompositionEditingFromPresentation()
        } else {
            controller.setWorkspaceMode(.edit)
        }
    }

    private var currentWorkspaceBackHelp: String {
        if controller.workflowStage == .polishing {
            return "Return to the unpolished content. Saved Polish settings remain available."
        }
        return controller.hasComposition
            ? "Annotate the complete result. Done returns here."
            : "Return to screenshot editing."
    }

    private func requestCompositionAddition(
        _ action: @escaping (CompositionAddActions) -> Void
    ) {
        guard controller.documentPurpose == .screenshot else {
            if let baseActions = compositionAddActions {
                let role: CaptureCompletionRole
                switch controller.documentPurpose {
                case .screenshot:
                    role = .standalone
                case .comparison:
                    role = .comparisonAfter
                case .steps:
                    role = .step
                case .collection:
                    role = .collectionItem
                }
                action(
                    baseActions.actionsForCompletionRole?(role)
                        ?? baseActions
                )
            }
            return
        }
#if DEBUG
        CompositionUITestLaunchSupport.forceMainWindowFront()
#endif
        pendingFirstAddition = action
        isShowingFirstAdditionPurpose = true
#if DEBUG
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard isShowingFirstAdditionPurpose else {
                return
            }
            CompositionUITestLaunchSupport.forceMainWindowFront()
        }
#endif
    }

    private func completeFirstAddition(
        with role: CaptureCompletionRole
    ) {
        guard let action = pendingFirstAddition,
              let baseActions = compositionAddActions else {
            pendingFirstAddition = nil
            return
        }
        let actions =
            baseActions.actionsForCompletionRole?(role)
            ?? baseActions
        pendingFirstAddition = nil
        action(actions)
    }

    private var inspectorToggle: some View {
        Toggle(isOn: $isInspectorPresented) {
            Label("Inspector", systemImage: "sidebar.right")
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
        .accessibilityLabel("Inspector")
        .accessibilityValue(isInspectorPresented ? "Shown" : "Hidden")
        .accessibilityIdentifier("editor.inspector.toggle")
    }

    @ViewBuilder
    private var documentOutputCommands: some View {
        outputCommands(appearance: .plain)
    }

    @ViewBuilder
    private var referenceCommands: some View {
        floatButton
        dragControl
    }

    @ViewBuilder
    private func outputCommands(
        appearance: ScreenshotOutputAppearance
    ) -> some View {
        Button {
            onCopy(appearance)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .help("Copy the output currently shown in this workspace.")
        .accessibilityValue(visibleOutputAccessibilityValue)
        .accessibilityIdentifier("editor.output.copy.current")

        exportMenu(appearance: appearance)
        shareButton(appearance: appearance)
    }

    private func exportMenu(
        appearance: ScreenshotOutputAppearance
    ) -> some View {
        Menu {
            outputFormatButtons(appearance: appearance)
        } label: {
            Label("Export", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .help("Export the output currently shown in this workspace.")
        .accessibilityValue(visibleOutputAccessibilityValue)
        .accessibilityIdentifier(
            "editor.output.export.current"
        )
    }

    @ViewBuilder
    private func outputFormatButtons(
        appearance: ScreenshotOutputAppearance
    ) -> some View {
        Button("PNG…") { onExportPNG(appearance) }
        Button("JPEG…") { onExportJPEG(appearance) }
            .disabled(
                appearance == .styled
                    && controller.requiresPNGForFaithfulExport
            )
        Button("PDF…") { onExportPDF(appearance) }
            .disabled(
                appearance == .styled
                    && controller.requiresPNGForFaithfulExport
            )
        if controller.hasComposition {
            Divider()
            Button("Animated GIF…") {
                onExportComposition(.gif, appearance)
            }
            .disabled(!controller.supportsAnimatedCompositionOutput)
            Button("Animated APNG…") {
                onExportComposition(.apng, appearance)
            }
            .disabled(!controller.supportsAnimatedCompositionOutput)
            Button("Blink MP4…") {
                onExportComposition(.mp4, appearance)
            }
            .disabled(!controller.supportsAnimatedCompositionOutput)
            Divider()
            Button("Interactive HTML…") {
                onExportComposition(.html, appearance)
            }
            .disabled(!controller.supportsInteractiveCompositionHTML)
        }
    }

    private func shareButton(
        appearance: ScreenshotOutputAppearance
    ) -> some View {
        Button {
            onShare(appearance)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .help("Share the output currently shown in this workspace.")
        .accessibilityValue(visibleOutputAccessibilityValue)
        .accessibilityIdentifier("editor.output.share.current")
    }

    private var floatButton: some View {
        let appearance = controller.currentWorkspaceOutputAppearance
        return Button {
            onFloatReference(appearance)
        } label: {
            Label("Float", systemImage: "pin")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .help("Float the output currently shown in this workspace.")
        .accessibilityValue(visibleOutputAccessibilityValue)
        .accessibilityIdentifier("editor.output.float.current")
    }

    private var dragControl: some View {
        let appearance = controller.currentWorkspaceOutputAppearance
        return PromisedFileDragView(
            accessibilityLabel: "Drag current screenshot output",
            payloadProvider: { dragOutPayloadProvider(appearance) }
        )
        .frame(width: 68, height: 30)
        .accessibilityValue(visibleOutputAccessibilityValue)
        .accessibilityIdentifier("editor.output.drag.current")
        .help("Drag the output currently shown in this workspace.")
    }

    private var visibleOutputAccessibilityValue: String {
        controller.workflowStage == .polishing
            ? "Polished preview"
            : "Content preview"
    }

    @ViewBuilder
    private func toolButtons(_ tools: [EditorTool]) -> some View {
        ForEach(tools) { tool in
            if tool != .crop || controller.compositionEditingScope != .composition {
                toolButton(tool)
            }
        }
    }

    private func toolButton(_ tool: EditorTool) -> some View {
        Button {
            controller.activateToolbarTool(tool)
        } label: {
            Image(systemName: tool.systemImage)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(EditorDirectToolButtonStyle(isSelected: controller.activeTool == tool))
        .help(helpText(for: tool))
        .accessibilityLabel(tool.label)
        .accessibilityValue(controller.activeTool == tool ? "Selected" : "Not selected")
        .disabled(!isToolEnabled(tool))
    }

    private var redactionControl: some View {
        Menu {
            ForEach(RedactionMode.allCases) { redactionMode in
                Button {
                    controller.updateRedactionMode(redactionMode)
                } label: {
                    Label(
                        redactionMode.label,
                        systemImage: redactionMode == controller.currentRedactionMode ? "checkmark" : redactionMode.toolbarSystemImage
                    )
                }
            }
        } label: {
            Image(systemName: controller.currentRedactionMode.toolbarSystemImage)
                .frame(width: 30, height: 28)
        } primaryAction: {
            controller.activateToolbarTool(.blur)
        }
        .buttonStyle(EditorDirectToolButtonStyle(isSelected: controller.activeTool.defaultRedactionMode != nil))
        .help("Redaction: \(controller.currentRedactionMode.label). Click to use; open the menu to change mode.")
        .accessibilityLabel("Redaction")
        .accessibilityHint("Current mode: \(controller.currentRedactionMode.label). Press to activate or open the menu to change mode.")
        .accessibilityValue(controller.activeTool.defaultRedactionMode != nil ? "Selected" : "Not selected")
    }

    private var insertImageButton: some View {
        Button(action: controller.importImageOverlay) {
            Image(systemName: "photo.badge.plus")
                .frame(width: 30, height: 28)
        }
        .buttonStyle(EditorDirectToolButtonStyle(isSelected: false))
        .help("Insert an image overlay.")
        .accessibilityLabel("Insert Image")
    }

    private func isToolEnabled(_ tool: EditorTool) -> Bool {
        tool != .uiMapInspect || controller.uiMapSnapshot != nil
    }

    private var uiMapButtonHelpText: String {
        if controller.isProcessingUIMap {
            return "Window UI Map metadata is still processing."
        }
        return controller.uiMapSnapshot == nil ? "No UI Map metadata is available." : "Show UI Map"
    }

    private var deleteSelectionHelpText: String {
        switch controller.selectedCount {
        case 1:
            return "Delete selected annotation."
        case 2...:
            return "Delete \(controller.selectedCount) selected annotations."
        default:
            return "Delete selected annotations."
        }
    }

    private func helpText(for tool: EditorTool) -> String {
        if tool == .uiMapInspect, controller.isProcessingUIMap {
            return "Pin UI Map will be available after processing finishes."
        }
        if tool == .uiMapInspect, controller.uiMapSnapshot == nil {
            return "Pin UI Map is available when this Window capture contains UI Map metadata."
        }
        return tool.label
    }
}

private struct EditorCommandGroup<Content: View>: View {
    let accessibilityLabel: String
    let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ accessibilityLabel: String, @ViewBuilder content: () -> Content) {
        self.accessibilityLabel = accessibilityLabel
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 5) {
            content
        }
        .padding(3)
        .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    Color(nsColor: .separatorColor),
                    lineWidth: contrast == .increased ? 2 : 1
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct EditorDirectToolButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: isSelected || contrast == .increased ? 2 : 1
                    )
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(contrast == .increased ? 0.28 : 0.18)
        }
        if isPressed {
            return Color.primary.opacity(0.10)
        }
        return Color(nsColor: .controlBackgroundColor)
    }
}

private struct OCRReviewView: View {
    @Binding var text: String
    let onCopy: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recognized Text")
                .font(.title3.weight(.semibold))

            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass)
                Button("Copy Text", action: onCopy)
                    .buttonStyle(.glass)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

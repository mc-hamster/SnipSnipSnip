import AppKit
import SwiftUI

struct EditorView: View {
    @ObservedObject var controller: EditorController
    let historyEntries: [DocumentHistoryEntry]
    let recentSnipEntries: [DocumentHistoryEntry]
    let captureHistoryEntries: [DocumentHistoryEntry]
    let recycleBinEntries: [DocumentHistoryEntry]
    @Binding var captureSearchQuery: String
    let captureHistorySearchResultsLabel: String
    let historyActions: EditorHistoryActions
    @State private var previewedHistoryEntry: DocumentHistoryEntry?
    @SceneStorage("editor.inspector.isPresented") private var isInspectorPresented = true

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
                previewedHistoryEntry: $previewedHistoryEntry
            )
            .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
        }
        .toolbar {
            ToolbarItem(id: "editor-inspector", placement: .primaryAction) {
                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label(isInspectorPresented ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
                .accessibilityValue(isInspectorPresented ? "Shown" : "Hidden")
            }
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

struct EditorCommandBar: View {
    private static let primaryTools: [EditorTool] = [.select, .crop]
    private static let shapeTools: [EditorTool] = [.rectangle, .ellipse, .line, .arrow, .statusMark, .measure]
    private static let drawingTools: [EditorTool] = [.freehand, .highlighter, .highlight, .spotlight]
    private static let textTools: [EditorTool] = [.text, .callout]
    private static let utilityTools: [EditorTool] = [.ocrText, .colorPicker]

    @ObservedObject var controller: EditorController
    let onBack: () -> Void
    let onFloatReference: (ScreenshotOutputAppearance) -> Void
    let onExportPNG: (ScreenshotOutputAppearance) -> Void
    let onExportJPEG: (ScreenshotOutputAppearance) -> Void
    let onExportPDF: (ScreenshotOutputAppearance) -> Void
    let onCopy: (ScreenshotOutputAppearance) -> Void
    let onShare: (ScreenshotOutputAppearance) -> Void
    let onShowLayers: () -> Void
    let onShowUIMap: () -> Void
    let dragOutPayloadProvider: @MainActor (ScreenshotOutputAppearance) -> PromisedFilePayload?
    var mode: EditorToolbarMode = .standard

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
    }

    private var editCommands: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button(action: onBack) {
                        Label(mode.backTitle, systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .help(mode.backHelp)

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

                    if let applyAction = mode.applyAction {
                        Button("Apply to Step", action: applyAction)
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .help("Save these annotations on this Guide step and return to the Guide editor.")
                    } else {
                        EditorCommandGroup("Workspace") {
                            presentationButton
                        }
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
        }
    }

    private var presentationCommands: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    controller.setWorkspaceMode(.edit)
                } label: {
                    Label("Back to Edit", systemImage: EditorWorkspaceMode.edit.systemImage)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)

                EditorCommandGroup("History") {
                    undoButton
                    redoButton
                }
                EditorCommandGroup("Zoom") {
                    zoomCommands
                }

                EditorCommandGroup("Presentation variants") {
                    Button {
                        _ = controller.saveCurrentPresentationToDocument()
                    } label: {
                        Label("Save Variant", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
                EditorCommandGroup("Output") {
                    Button {
                        onCopy(.styled)
                    } label: {
                        Label("Copy Styled", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)

                    exportMenu(primaryAppearance: .styled)
                    shareMenu(primaryAppearance: .styled)
                }
                EditorCommandGroup("References and drag out") {
                    referenceCommands
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
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

    private var presentationButton: some View {
        return HStack(spacing: 6) {
            Button {
                controller.setWorkspaceMode(.presentation)
            } label: {
                Label("Presentation", systemImage: EditorWorkspaceMode.presentation.systemImage)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .help("Open Presentation mode to style the final copy, share, and export output.")
            .accessibilityIdentifier("editor.presentation.open")

            Text("Beta")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: .capsule)
                .accessibilityLabel("Presentation, Beta")
                .help("Presentation is in beta. Your editable screenshot remains unchanged.")

            Text(controller.styledOutputConfigurationLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(controller.styledOutputConfigurationLabel)
        }
    }

    @ViewBuilder
    private var documentOutputCommands: some View {
        Menu {
            Button("Copy Plain") { onCopy(.plain) }
            Button("Copy Styled") { onCopy(.styled) }
                .disabled(!controller.hasStyledOutputConfigured)
        } label: {
            Label("Copy Plain", systemImage: "doc.on.doc")
        } primaryAction: {
            onCopy(.plain)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .help("Copy the plain annotated screenshot.")

        exportMenu(primaryAppearance: .plain)
        shareMenu(primaryAppearance: .plain)
    }

    @ViewBuilder
    private var referenceCommands: some View {
        floatButton
        dragControl
    }

    private func exportMenu(primaryAppearance: ScreenshotOutputAppearance) -> some View {
        Menu {
            outputFormatMenu(appearance: primaryAppearance)
            Divider()
            outputFormatMenu(appearance: primaryAppearance == .plain ? .styled : .plain)
        } label: {
            Label("Export \(primaryAppearance.title)", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .help("Export explicit Plain or Styled output as PNG, JPEG, or PDF.")
    }

    private func outputFormatMenu(appearance: ScreenshotOutputAppearance) -> some View {
        Menu(appearance.title) {
            Button("\(appearance.title) PNG…") { onExportPNG(appearance) }
            Button("\(appearance.title) JPEG…") { onExportJPEG(appearance) }
                .disabled(
                    appearance == .styled
                        && (!controller.hasStyledOutputConfigured || controller.requiresPNGForFaithfulExport)
                )
            Button("\(appearance.title) PDF…") { onExportPDF(appearance) }
                .disabled(
                    appearance == .styled
                        && (!controller.hasStyledOutputConfigured || controller.requiresPNGForFaithfulExport)
                )
        }
        .disabled(appearance == .styled && !controller.hasStyledOutputConfigured)
    }

    private func shareMenu(primaryAppearance: ScreenshotOutputAppearance) -> some View {
        Menu {
            Button("Share Plain") { onShare(.plain) }
            Button("Share Styled") { onShare(.styled) }
                .disabled(!controller.hasStyledOutputConfigured)
        } label: {
            Label("Share \(primaryAppearance.title)", systemImage: "square.and.arrow.up")
        } primaryAction: {
            onShare(primaryAppearance)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(primaryAppearance == .styled && !controller.hasStyledOutputConfigured)
    }

    private var floatButton: some View {
        let appearance: ScreenshotOutputAppearance = controller.workspaceMode == .presentation ? .styled : .plain
        return Button {
            onFloatReference(appearance)
        } label: {
            Label("Float \(appearance.title)", systemImage: "pin")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(appearance == .styled && !controller.hasStyledOutputConfigured)
    }

    private var dragControl: some View {
        let appearance: ScreenshotOutputAppearance = controller.workspaceMode == .presentation ? .styled : .plain
        return HStack(spacing: 4) {
            PromisedFileDragView(
                accessibilityLabel: "Drag \(appearance.title) screenshot to share",
                payloadProvider: { dragOutPayloadProvider(appearance) }
            )
            .frame(width: 28, height: 30)
            Text("Drag \(appearance.title)")
                .font(.caption)
        }
        .disabled(appearance == .styled && !controller.hasStyledOutputConfigured)
    }

    @ViewBuilder
    private func toolButtons(_ tools: [EditorTool]) -> some View {
        ForEach(tools) { tool in
            toolButton(tool)
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

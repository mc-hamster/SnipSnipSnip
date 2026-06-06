import AppKit
import SwiftUI

struct EditorView: View {
    private let inspectorWidth: CGFloat = 300
    private let inspectorDividerWidth: CGFloat = 1
    private let inspectorScrollbarGutter: CGFloat = 8

    @ObservedObject var controller: EditorController
    let historyEntries: [DocumentHistoryEntry]
    let recentSnipEntries: [DocumentHistoryEntry]
    let captureHistoryEntries: [DocumentHistoryEntry]
    let recycleBinEntries: [DocumentHistoryEntry]
    @Binding var captureSearchQuery: String
    let captureHistorySearchResultsLabel: String
    let historyActions: EditorHistoryActions
    let dragOutPayloadProvider: @MainActor () -> PromisedFilePayload?
    @State private var previewedHistoryEntry: DocumentHistoryEntry?

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let canvasWidth = max(
                    proxy.size.width - inspectorWidth - inspectorDividerWidth - inspectorScrollbarGutter,
                    0
                )

                HStack(spacing: 0) {
                    EditorCanvasScrollContainer(controller: controller)
                        .frame(width: canvasWidth, height: proxy.size.height)

                    Color.clear
                        .frame(width: inspectorScrollbarGutter, height: proxy.size.height)

                    Divider()
                        .frame(width: inspectorDividerWidth)

                    EditorInspectorView(
                        controller: controller,
                        historyEntries: historyEntries,
                        recentSnipEntries: recentSnipEntries,
                        captureHistoryEntries: captureHistoryEntries,
                        recycleBinEntries: recycleBinEntries,
                        captureSearchQuery: $captureSearchQuery,
                        captureHistorySearchResultsLabel: captureHistorySearchResultsLabel,
                        actions: historyActions,
                        previewedHistoryEntry: $previewedHistoryEntry,
                        dragOutPayloadProvider: dragOutPayloadProvider
                    )
                    .frame(width: inspectorWidth, height: proxy.size.height)
                }
            }

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

            if let noticeMessage = controller.noticeMessage {
                Text(noticeMessage)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
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
}

private struct EditorCanvasScrollContainer: View {
    @ObservedObject var controller: EditorController

    private let scrollerThickness: CGFloat = 20

    var body: some View {
        GeometryReader { proxy in
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

struct EditorToolbarView: View {
    let controller: EditorController?
    let onBack: () -> Void
    let onFloatReference: () -> Void
    let onExportPNG: () -> Void
    let onExportJPEG: () -> Void
    let onExportPDF: () -> Void
    let onShare: () -> Void
    let dragOutPayloadProvider: @MainActor () -> PromisedFilePayload?

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            Group {
                if let controller {
                    ActiveEditorToolbarView(
                        controller: controller,
                        onBack: onBack,
                        onFloatReference: onFloatReference,
                        onExportPNG: onExportPNG,
                        onExportJPEG: onExportJPEG,
                        onExportPDF: onExportPDF,
                        onShare: onShare,
                        dragOutPayloadProvider: dragOutPayloadProvider
                    )
                } else {
                    InactiveEditorToolbarView(onBack: onBack)
                }
            }
        }
    }
}

private struct ActiveEditorToolbarView: View {
    private static let primaryTools: [EditorTool] = [.select]
    private static let drawingTools: [EditorTool] = [.rectangle, .ellipse, .line, .arrow, .measure, .freehand, .highlighter, .highlight, .spotlight]
    private static let textTools: [EditorTool] = [.text, .callout]
    private static let utilityTools: [EditorTool] = [.ocrText]

    @ObservedObject var controller: EditorController
    let onBack: () -> Void
    let onFloatReference: () -> Void
    let onExportPNG: () -> Void
    let onExportJPEG: () -> Void
    let onExportPDF: () -> Void
    let onShare: () -> Void
    let dragOutPayloadProvider: @MainActor () -> PromisedFilePayload?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Label("Discard", systemImage: "xmark")
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                .help("Discard the current editor session and return to the capture screen.")

                toolbarDivider

                toolGroup(Self.primaryTools)
                toolbarDivider
                toolGroup(Self.drawingTools)
                toolbarDivider
                toolGroup(Self.textTools)
                toolbarDivider
                redactionToolButton
                toolbarDivider
                utilityToolGroup

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button(action: controller.undo) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(SSSChromeIconButtonStyle(tint: .secondary))
                .help("Undo")
                .disabled(!controller.canUndo)

                Button(action: controller.redo) {
                    Image(systemName: "arrow.uturn.forward")
                }
                .buttonStyle(SSSChromeIconButtonStyle(tint: .secondary))
                .help("Redo")
                .disabled(!controller.canRedo)

                Button(action: controller.rotateSelectedClockwise90) {
                    Image(systemName: "rotate.right")
                }
                .buttonStyle(SSSChromeIconButtonStyle(tint: .secondary))
                .help("Rotate selected annotation 90 degrees clockwise.")
                .disabled(!controller.canRotateSelection)

                toolbarDivider

                Button(action: controller.zoomOut) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(SSSChromeIconButtonStyle(tint: .secondary))
                .help("Zoom Out")
                .disabled(!controller.canZoomOut)

                Text(controller.zoomPercentageLabel)
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 54)

                Button(action: controller.zoomIn) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(SSSChromeIconButtonStyle(tint: .secondary))
                .help("Zoom In")
                .disabled(!controller.canZoomIn)

                Button("100%", action: controller.zoomToActualSize)
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                    .help("Actual Size")

                Button("Fit", action: controller.zoomToFit)
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                    .help("Fit to Window")

                toolbarDivider

                Button("Export PNG…", action: onExportPNG)
                    .buttonStyle(SSSChromeButtonStyle())
                    .help("Export the rendered image as a PNG file.")

                Button("Export JPEG…", action: onExportJPEG)
                    .buttonStyle(SSSChromeButtonStyle())
                    .help("Export the rendered image as a JPEG file.")
                    .disabled(controller.requiresPNGForFaithfulExport)

                Button("Export PDF…", action: onExportPDF)
                    .buttonStyle(SSSChromeButtonStyle())
                    .help("Export the rendered image as a PDF file.")
                    .disabled(controller.requiresPNGForFaithfulExport)

                Button("Share", action: onShare)
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                    .help("Share the current rendered image using macOS sharing services.")

                Button(action: onFloatReference) {
                    Label("Float", systemImage: "pin")
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                .help("Open the current rendered screenshot as an always-on-top floating reference.")

                PromisedFileDragView(
                    accessibilityLabel: "Drag rendered screenshot to share",
                    payloadProvider: dragOutPayloadProvider
                )
                .frame(width: 68, height: 30)
                .help("Drag the current rendered screenshot into Finder, Mail, or another app.")

                Spacer(minLength: 0)
            }
        }
    }

    private var utilityToolGroup: some View {
        HStack(spacing: 6) {
            ForEach(Self.utilityTools) { tool in
                Button {
                    controller.activateToolbarTool(tool)
                } label: {
                    Image(systemName: tool.systemImage)
                        .frame(width: 32, height: 32)
                }
                .help(tool.label)
                .buttonStyle(EditorToolButtonStyle(isSelected: controller.activeTool == tool))
            }

            Button {
                controller.importImageOverlay()
            } label: {
                Image(systemName: "photo.badge.plus")
                    .frame(width: 32, height: 32)
            }
            .help("Import an image overlay into the editable screenshot.")
            .buttonStyle(EditorToolButtonStyle(isSelected: false))
        }
        .padding(3)
        .glassEffect(.regular.tint(.white.opacity(0.04)), in: .rect(cornerRadius: 12))
    }

    private func toolGroup(_ tools: [EditorTool]) -> some View {
        HStack(spacing: 6) {
            ForEach(tools) { tool in
                Button {
                    controller.activateToolbarTool(tool)
                } label: {
                    Image(systemName: tool.systemImage)
                        .frame(width: 32, height: 32)
                }
                .help(tool.label)
                .buttonStyle(EditorToolButtonStyle(isSelected: controller.activeTool == tool))
            }
        }
        .padding(3)
        .glassEffect(.regular.tint(.white.opacity(0.04)), in: .rect(cornerRadius: 12))
    }

    private var redactionToolButton: some View {
        Button {
            controller.activateToolbarTool(.blur)
        } label: {
            Image(systemName: controller.currentRedactionMode.toolbarSystemImage)
                .frame(width: 32, height: 32)
        }
        .help("Redaction: \(controller.currentRedactionMode.label)")
        .buttonStyle(EditorToolButtonStyle(isSelected: controller.activeTool.defaultRedactionMode != nil))
    }

    private var toolbarDivider: some View {
        Divider()
            .frame(height: 22)
            .opacity(0.22)
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
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                Button("Copy Text", action: onCopy)
                    .buttonStyle(SSSChromeButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .sssGlassSurface(cornerRadius: 18)
    }
}

private struct InactiveEditorToolbarView: View {
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Label("Discard", systemImage: "trash")
            }
            .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
            .help("Discard the inactive editor view.")
            .disabled(true)

            Spacer()
        }
    }
}

private struct EditorToolButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .glassEffect(glass(isPressed: configuration.isPressed), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.12), lineWidth: 0.75)
            }
            .opacity(configuration.isPressed ? 0.9 : 1)
    }

    private func glass(isPressed: Bool) -> Glass {
        if isSelected {
            return .regular.tint(Color.accentColor.opacity(isPressed ? 0.38 : 0.28)).interactive()
        }

        return .regular.tint(isPressed ? Color.secondary.opacity(0.14) : Color.white.opacity(0.03)).interactive()
    }
}

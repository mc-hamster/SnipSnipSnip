import SwiftUI

struct VideoEditorCommandBar: View {
    @ObservedObject var controller: VideoEditorController
    @Binding var inspectorVisible: Bool
    let exportPreferences: VideoExportPreferences
    let onBack: () -> Void
    let onExportRequest: (VideoExportRequest) -> Void
    let dragOutPayloadProvider: @MainActor () -> PromisedFilePayload?
    @Environment(\.undoManager) private var undoManager
    @State private var showsExportOptions = false
    @State private var pendingExportRequest: VideoExportRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button(action: onBack) { Label("Discard", systemImage: "xmark") }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .help("Discard the current video editor session and return to the capture screen.")
                        .accessibilityIdentifier("video.discard")
                    EditorCommandGroup("Video tools") {
                        tool(.trim)
                        tool(.zooms)
                        tool(.cursor)
                        tool(.audio)
                    }
                    if controller.isPolishing {
                        EditorCommandGroup("Polish") { tool(.polish) }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    EditorCommandGroup("History") {
                        Button { undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(.bordered).buttonBorderShape(.circle)
                            .help("Undo").accessibilityLabel("Undo")
                            .disabled(undoManager?.canUndo != true)
                        Button { undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                            .buttonStyle(.bordered).buttonBorderShape(.circle)
                            .help("Redo").accessibilityLabel("Redo")
                            .disabled(undoManager?.canRedo != true)
                    }
                    EditorCommandGroup("Inspector") {
                        Toggle(isOn: $inspectorVisible) { Label("Inspector", systemImage: "sidebar.right") }
                            .toggleStyle(.button)
                            .buttonStyle(.bordered).buttonBorderShape(.capsule)
                            .help(inspectorVisible ? "Hide Inspector" : "Show Inspector")
                            .accessibilityValue(inspectorVisible ? "Shown" : "Hidden")
                            .accessibilityIdentifier("video.inspector.toggle")
                    }
                    EditorCommandGroup("Output") {
                        Button { showsExportOptions = true } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                            .help("Export the finished video as MP4, GIF, or APNG.")
                            .disabled(controller.isExporting || controller.isPreparingPreview || controller.previewError != nil)
                            .accessibilityIdentifier("video.export")
                    }
                    EditorCommandGroup("Drag Out") {
                        PromisedFileDragView(accessibilityLabel: "Drag finished video to share", payloadProvider: dragOutPayloadProvider)
                            .frame(width: 72, height: 30)
                            .help("Drag the finished video into Finder, Mail, or another app. Trims and effects are included; export starts after the drop is accepted.")
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("video.commandBar")
        .sheet(isPresented: $showsExportOptions, onDismiss: {
            if let request = pendingExportRequest {
                pendingExportRequest = nil
                onExportRequest(request)
            }
        }) {
            VideoExportOptionsView(preferences: exportPreferences) { request in
                pendingExportRequest = request
                showsExportOptions = false
            }
        }
    }

    private func tool(_ section: VideoInspectorSection) -> some View {
        let isSelected = inspectorVisible && controller.inspectorSection == section
        return Button {
            if section == .zooms, controller.inspectorSection != .zooms, let zoom = controller.selectedZoom {
                controller.selectZoom(zoom.id)
            } else {
                controller.inspectorSection = section
            }
            inspectorVisible = true
        } label: {
            Label(section == .polish ? "Look" : section.rawValue, systemImage: section.symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 8).frame(height: 28)
        }
        .buttonStyle(EditorDirectToolButtonStyle(isSelected: isSelected))
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityIdentifier("video.tool.\(section.id)")
    }
}

struct VideoSessionBar: View {
    @ObservedObject var controller: VideoEditorController
    @Binding var inspectorVisible: Bool

    var body: some View {
        HStack(spacing: 8) {
            Label(controller.isPolishing ? "Video — Polish" : "Video — Review", systemImage: "video")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 4)
            if controller.isPolishing {
                Button {
                    controller.isPolishing = false
                    controller.inspectorSection = .trim
                } label: { Label("Back to Content", systemImage: "arrow.left") }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small)
                    .accessibilityIdentifier("video.backToContent")
            } else {
                Button {
                    controller.isPolishing = true
                    controller.inspectorSection = .polish
                    inspectorVisible = true
                } label: {
                    Label {
                        HStack(spacing: 4) {
                            Text("Polish")
                            if controller.session.effects.presentation.isEnabled {
                                Image(systemName: "checkmark.circle.fill").imageScale(.small).accessibilityHidden(true)
                            }
                        }
                    } icon: { Image(systemName: "sparkles") }
                }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                .accessibilityIdentifier("video.polish.show")
                .help("Adjust the video's Look. Opening Polish does not change your edits.")
            }
            Text(controller.trimmedDurationLabel)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("video.sessionBar")
    }
}

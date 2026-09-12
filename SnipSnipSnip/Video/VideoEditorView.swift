import AppKit
import SwiftUI


struct VideoEditorView: View {
    @ObservedObject var controller: VideoEditorController
    var supportsShortcutCapture = true
    @Environment(\.undoManager) private var undoManager
    @Binding var inspectorVisible: Bool

    var body: some View {
        VideoEditorWorkspace(
            controller: controller,
            inspectorVisible: $inspectorVisible,
            supportsShortcutCapture: supportsShortcutCapture
        )
        .onAppear { controller.undoManager = undoManager }
        .onReceive(NotificationCenter.default.publisher(for: .sssToggleEditorInspector)) { _ in inspectorVisible.toggle() }
        .onChange(of: controller.inspectorSection) { _, _ in inspectorVisible = true }
        .onDisappear { controller.endContinuousEdit(); controller.pause() }
    }
}

/// Shared by the live editor and window-layout regression tests.
struct VideoEditorWorkspace: View {
    @ObservedObject var controller: VideoEditorController
    @Binding var inspectorVisible: Bool
    var supportsShortcutCapture = true

    var body: some View {
        VStack(spacing: 0) {
            VideoPlaybackView(
                controller: controller,
                showsTrimControls: inspectorVisible && controller.inspectorSection == .trim,
                showsZoomTargets: inspectorVisible && controller.inspectorSection == .zooms
            )
            if let message = controller.statusMessage {
                HStack {
                    Label(message, systemImage: "checkmark.circle")
                    Spacer()
                    Button("Dismiss", action: controller.dismissStatus)
                }
                .font(.callout).padding(12)
                .background(.background)
                .accessibilityElement(children: .combine)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .inspector(isPresented: $inspectorVisible) {
            VideoInspectorView(controller: controller, supportsShortcutCapture: supportsShortcutCapture)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
        }
        .overlay {
            if let exportProgress = controller.exportProgress {
                exportProgressOverlay(exportProgress)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Video Error", isPresented: Binding(get: {
            controller.errorMessage != nil
        }, set: { value in
            if !value { controller.dismissError() }
        })) {
            Button("OK", role: .cancel, action: controller.dismissError)
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    private func exportProgressOverlay(_ progress: VideoExportProgress) -> some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text(progress.title)
                    .font(.headline)

                Text(progress.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let fractionCompleted = progress.fractionCompleted {
                    ProgressView(value: min(max(fractionCompleted, 0), 1))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                HStack {
                    Spacer(minLength: 0)
                    Button("Cancel", role: .destructive, action: controller.cancelExport)
                        .buttonStyle(.glass)
                }
            }
            .padding(18)
            .frame(width: 360)
            .sssFloatingOverlaySurface(cornerRadius: 18, shadowOpacity: 0.16)
        }
    }

}

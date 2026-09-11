import AppKit
import Combine
import SwiftUI

/// Presentation policy is independent of window creation, so background
/// automation and multi-capture workflows never acquire an incidental HUD.
enum CapturePreviewPolicy {
    static func shouldPresent(
        result: CaptureWorkflowResult,
        disposition: CaptureInstallationDisposition,
        isEnabled: Bool
    ) -> Bool {
        isEnabled && result.allowsCapturePreview
            && disposition == .newDocument
            && result.intent == .newDocument
            && result.completionRole == .standalone
            && result.workflowPreset == nil
            && !result.isPrivateCapture
            && result.capture.kind != .connectedDevice
    }
}

@MainActor
final class CapturePreviewCoordinator {
    private(set) var model: CapturePreviewModel?
    private(set) var panel: NSPanel?
    private var preparation: Task<Void, Never>?
    private var observations: Set<AnyCancellable> = []
    var presentsWindows = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil

    func present(
        controller: EditorController,
        autoCopyEnabled: Bool,
        copy: @escaping (@escaping (Bool) -> Void) -> Void,
        edit: @escaping () -> Void,
        export: @escaping () -> Void,
        drag: @escaping () -> PromisedFilePayload?
    ) {
        clear()
        let model = CapturePreviewModel(
            autoCopyEnabled: autoCopyEnabled,
            copy: copy, edit: edit, export: export, drag: drag
        )
        self.model = model
        model.close = { [weak self] in self?.close() }
        controller.$notice.compactMap { $0 }.sink { [weak model] notice in
            model?.message = notice.message
        }.store(in: &observations)
        controller.$errorMessage.compactMap { $0 }.sink { [weak model] message in
            model?.message = message
            model?.hasError = true
        }.store(in: &observations)

        // Render through the same pipeline as Copy/Export, including the cursor.
        // Never display the unrendered source as a substitute for this output.
        preparation = Task { @MainActor [weak self, weak model] in
            do {
                let image = try await controller.renderedImageForExport(appearance: .plain)
                guard !Task.isCancelled, self?.model === model else { return }
                model?.image = image
            } catch {
                guard !Task.isCancelled, self?.model === model else { return }
                model?.hasError = true
                model?.message = String(localized: "Preview unavailable. Open in Editor to continue.")
            }
        }
        show()
    }

    func show() {
        guard let model else { return }
        model.allowsWindowRestoration = true
        guard presentsWindows else { return }
        if panel == nil {
            let panel = CapturePreviewPanel(
                contentRect: NSRect(x: 0, y: 0, width: 304, height: 310),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.title = String(localized: "Capture Preview")
            panel.identifier = NSUserInterfaceItemIdentifier("capture.preview")
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.sharingType = .none
            panel.contentView = NSHostingView(rootView: CapturePreviewView(model: model))
            self.panel = panel
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            // The lower-left corner leaves the default right-edge Quick Controls
            // dock alone. Use the visible frame to avoid the Dock and menu bar.
            panel?.setFrameOrigin(Self.origin(in: screen.visibleFrame, panelSize: panel?.frame.size ?? .zero))
        }
        panel?.orderFrontRegardless()
    }

    static func origin(in visibleFrame: CGRect, panelSize: CGSize) -> CGPoint {
        CGPoint(
            x: max(visibleFrame.minX, min(visibleFrame.minX + 16, visibleFrame.maxX - panelSize.width)),
            y: max(visibleFrame.minY, min(visibleFrame.minY + 16, visibleFrame.maxY - panelSize.height))
        )
    }

    /// Closing hides only the presentation. The document and recovery session
    /// remain owned by DocumentWorkflowModel; no screenshot is discarded here.
    func close() {
        model?.allowsWindowRestoration = false
        panel?.orderOut(nil)
    }

    func clear() {
        preparation?.cancel()
        preparation = nil
        model?.allowsWindowRestoration = false
        panel?.close()
        panel = nil
        model = nil
        observations.removeAll()
    }
}

private final class CapturePreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CapturePreviewModel: ObservableObject {
    @Published var image: CGImage?
    @Published var message: String
    @Published var isCopying = false
    @Published var hasError = false
    @Published var autoCopyEnabled: Bool
    let copy: (@escaping (Bool) -> Void) -> Void
    let edit: () -> Void
    let export: () -> Void
    let drag: () -> PromisedFilePayload?
    var close: () -> Void = {}
    var allowsWindowRestoration = true

    init(autoCopyEnabled: Bool, copy: @escaping (@escaping (Bool) -> Void) -> Void,
         edit: @escaping () -> Void, export: @escaping () -> Void,
         drag: @escaping () -> PromisedFilePayload?) {
        self.autoCopyEnabled = autoCopyEnabled
        self.copy = copy
        self.edit = edit
        self.export = export
        self.drag = drag
        message = autoCopyEnabled
            ? String(localized: "Auto Copy is on. Captures and edits copy automatically.")
            : String(localized: "Review sensitive details before copying or dragging.")
    }

    func copyScreenshot() {
        guard !isCopying else { return }
        isCopying = true
        hasError = false
        message = String(localized: "Copying screenshot…")
        copy { [weak self] succeeded in
            self?.isCopying = false
            self?.hasError = !succeeded
            self?.message = succeeded
                ? String(localized: "Copied screenshot. Ready to paste.")
                : String(localized: "Could not copy. Try again or open in Editor.")
        }
    }

    func updateAutoCopy(_ enabled: Bool) {
        autoCopyEnabled = enabled
        guard !isCopying else { return }
        message = enabled
            ? String(localized: "Auto Copy is on. Captures and edits copy automatically.")
            : String(localized: "Review sensitive details before copying or dragging.")
        hasError = false
    }
}

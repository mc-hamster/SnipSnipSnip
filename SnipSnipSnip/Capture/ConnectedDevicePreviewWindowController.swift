import AVFoundation
import AppKit
import Combine
import SwiftUI

enum ConnectedDevicePreviewIntent {
    case screenshot
    case recording
}

final class ConnectedDevicePreviewWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: ConnectedDevicePreviewViewModel
    private let onClose: () -> Void
    private var didClose = false

    init(
        device: ConnectedAppleDevice,
        session: ConnectedDevicePreviewSession,
        intent: ConnectedDevicePreviewIntent,
        isPrivateCapture: Bool,
        screenshotFilenameTemplate: ScreenshotFilenameTemplate,
        openScreenshot: @escaping (CapturedScreenshot, Bool) throws -> Void,
        openRecording: @escaping (CapturedVideoRecording) -> Void,
        presentError: @escaping (Error) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        self.viewModel = ConnectedDevicePreviewViewModel(
            device: device,
            session: session,
            intent: intent,
            isPrivateCapture: isPrivateCapture,
            screenshotFilenameTemplate: screenshotFilenameTemplate,
            openScreenshot: openScreenshot,
            openRecording: openRecording,
            presentError: presentError
        )

        let view = ConnectedDevicePreviewView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "\(device.displayName) Preview"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 440, height: 700))
        window.minSize = NSSize(width: 360, height: 480)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        viewModel.closeWindow = { [weak window] in
            window?.performClose(nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func start() async throws {
        try await viewModel.start()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else {
            return
        }

        didClose = true
        viewModel.stop()
        onClose()
    }
}

@MainActor
private final class ConnectedDevicePreviewViewModel: ObservableObject {
    enum Status: Equatable {
        case starting
        case live
        case recording
        case stopped
        case failed(String)

        var label: String {
            switch self {
            case .starting:
                return "Starting preview"
            case .live:
                return "Live"
            case .recording:
                return "Recording"
            case .stopped:
                return "Stopped"
            case .failed(let message):
                return message
            }
        }
    }

    let device: ConnectedAppleDevice
    let session: ConnectedDevicePreviewSession
    @Published var status: Status = .starting
    @Published var isBusy = false
    @Published var latestScreenshot: CapturedScreenshot?
    @Published var latestRecording: CapturedVideoRecording?

    private let intent: ConnectedDevicePreviewIntent
    private let isPrivateCapture: Bool
    private let screenshotFilenameTemplate: ScreenshotFilenameTemplate
    private let openScreenshot: (CapturedScreenshot, Bool) throws -> Void
    private let openRecording: (CapturedVideoRecording) -> Void
    private let presentError: (Error) -> Void
    fileprivate var closeWindow: (() -> Void)?
    private var hasStopped = false

    init(
        device: ConnectedAppleDevice,
        session: ConnectedDevicePreviewSession,
        intent: ConnectedDevicePreviewIntent,
        isPrivateCapture: Bool,
        screenshotFilenameTemplate: ScreenshotFilenameTemplate,
        openScreenshot: @escaping (CapturedScreenshot, Bool) throws -> Void,
        openRecording: @escaping (CapturedVideoRecording) -> Void,
        presentError: @escaping (Error) -> Void
    ) {
        self.device = device
        self.session = session
        self.intent = intent
        self.isPrivateCapture = isPrivateCapture
        self.screenshotFilenameTemplate = screenshotFilenameTemplate
        self.openScreenshot = openScreenshot
        self.openRecording = openRecording
        self.presentError = presentError

        session.setRuntimeIssueHandler { [weak self] issue in
            Task { @MainActor [weak self] in
                self?.handleRuntimeIssue(issue)
            }
        }
    }

    var isRecording: Bool {
        status == .recording
    }

    var primaryButtonTitle: String {
        intent == .recording ? "Start Recording" : "Capture Screenshot"
    }

    var guidanceText: String {
        switch status {
        case .starting:
            return "Starting the live USB preview."
        case .live:
            return "Keep the device awake and unlocked. If the stream disappears, choose Refresh Devices from the capture menu."
        case .recording:
            return "Recording the connected-device stream. Keep the cable connected until recording is stopped."
        case .stopped:
            return "Preview stopped."
        case .failed:
            return "Reconnect or unlock the device, then choose Refresh Devices before trying again."
        }
    }

    func start() async throws {
        do {
            try await session.start()
            status = .live
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    func stop() {
        guard !hasStopped else {
            return
        }

        hasStopped = true
        session.setRuntimeIssueHandler(nil)
        if isRecording {
            Task {
                await stopRecording(openWhenFinished: false)
                session.stop()
            }
        } else {
            status = .stopped
            session.stop()
        }
    }

    func performPrimaryAction() {
        switch intent {
        case .screenshot:
            captureScreenshot(openInEditor: true)
        case .recording:
            startRecording()
        }
    }

    func captureScreenshot(openInEditor: Bool) {
        guard !isBusy, !isRecording else {
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let capture = try session.captureLatestScreenshot()
            latestScreenshot = capture

            if openInEditor {
                try openScreenshot(capture, isPrivateCapture)
            }
        } catch {
            present(error)
        }
    }

    func copyScreenshot() {
        do {
            let capture = try latestOrCapturedScreenshot()
            latestScreenshot = capture
            try ImageExporter.copyToClipboard(capture.image)
        } catch {
            present(error)
        }
    }

    func openLatestScreenshot() {
        do {
            let capture = try session.captureLatestScreenshot()
            latestScreenshot = capture
            try openScreenshot(capture, isPrivateCapture)
        } catch {
            present(error)
        }
    }

    func saveScreenshot() {
        Task {
            do {
                let capture = try latestOrCapturedScreenshot()
                latestScreenshot = capture
                try await ImageExporter.save(
                    capture.image,
                    suggestedFilename: screenshotFilenameTemplate.resolvedFilename(for: capture, formatExtension: "png"),
                    format: .png
                )
            } catch {
                present(error)
            }
        }
    }

    func startRecording() {
        guard !isBusy, !isRecording else {
            return
        }

        isBusy = true
        Task {
            defer { isBusy = false }

            do {
                try await session.startRecording()
                status = .recording
            } catch {
                present(error)
            }
        }
    }

    func stopRecording(openWhenFinished: Bool = true) async {
        guard isRecording, !isBusy else {
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let recording = try await session.stopRecording()
            latestRecording = recording
            status = .live
            if openWhenFinished {
                openRecording(recording)
            }
        } catch {
            status = .failed(error.localizedDescription)
            present(error)
        }
    }

    func openLatestRecording() {
        guard let latestRecording else {
            return
        }

        openRecording(latestRecording)
    }

    func cancel() {
        closeWindow?()
    }

    private func handleRuntimeIssue(_ issue: ConnectedDeviceCaptureError) {
        guard !hasStopped else {
            return
        }

        isBusy = false
        status = .failed(issue.errorDescription ?? "Connected-device preview failed.")
        session.stop()
        present(issue)
    }

    private func present(_ error: Error) {
        presentError(error)
    }

    private func latestOrCapturedScreenshot() throws -> CapturedScreenshot {
        if let latestScreenshot {
            return latestScreenshot
        }

        return try session.captureLatestScreenshot()
    }
}

private struct ConnectedDevicePreviewView: View {
    @ObservedObject var viewModel: ConnectedDevicePreviewViewModel

    var body: some View {
        VStack(spacing: 14) {
            ConnectedDeviceVideoPreviewView(session: viewModel.session.captureSession)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack {
                statusBadge
                Spacer()
                Text(viewModel.device.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(viewModel.guidanceText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            controls
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 480)
    }

    private var statusBadge: some View {
        Label(viewModel.status.label, systemImage: statusIconName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusTint)
            .lineLimit(1)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(viewModel.primaryButtonTitle) {
                    viewModel.performPrimaryAction()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || viewModel.isRecording)

                Button("Stop Recording") {
                    Task {
                        await viewModel.stopRecording()
                    }
                }
                .disabled(!viewModel.isRecording || viewModel.isBusy)
            }

            HStack(spacing: 10) {
                Button("Copy Screenshot", action: viewModel.copyScreenshot)
                    .disabled(viewModel.isBusy || viewModel.isRecording)

                Button("Open Screenshot in Editor", action: viewModel.openLatestScreenshot)
                    .disabled(viewModel.isBusy || viewModel.isRecording)
            }

            HStack(spacing: 10) {
                Button("Save", action: viewModel.saveScreenshot)
                    .disabled(viewModel.isBusy || viewModel.isRecording)

                Button("Cancel") {
                    viewModel.cancel()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var statusIconName: String {
        switch viewModel.status {
        case .starting:
            return "circle.dotted"
        case .live:
            return "dot.radiowaves.left.and.right"
        case .recording:
            return "record.circle.fill"
        case .stopped:
            return "pause.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch viewModel.status {
        case .starting, .stopped:
            return .secondary
        case .live:
            return .green
        case .recording:
            return .red
        case .failed:
            return .orange
        }
    }
}

private struct ConnectedDeviceVideoPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewLayerContainerView {
        let view = PreviewLayerContainerView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewLayerContainerView, context: Context) {
        nsView.previewLayer.session = session
    }

    static func dismantleNSView(_ nsView: PreviewLayerContainerView, coordinator: ()) {
        nsView.previewLayer.session = nil
    }
}

private final class PreviewLayerContainerView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
        layer = previewLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

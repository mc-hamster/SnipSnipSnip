import AppKit
import Combine
import SwiftUI

@MainActor
final class RecordingControlOverlayModel: ObservableObject {
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var isPaused: Bool

    let title: String
    let pauseResumeAction: () -> Void
    let stopAction: () -> Void
    private let startedAt = Date()
    private var accumulatedPausedDuration: TimeInterval = 0
    private var pauseStartedAt: Date?
    private var timerTask: Task<Void, Never>?

    init(
        title: String,
        isPaused: Bool,
        pauseResumeAction: @escaping () -> Void,
        stopAction: @escaping () -> Void
    ) {
        self.title = title
        self.isPaused = isPaused
        self.pauseResumeAction = pauseResumeAction
        self.stopAction = stopAction

        if isPaused {
            pauseStartedAt = Date()
        }

        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    deinit {
        timerTask?.cancel()
    }

    var elapsedLabel: String {
        let seconds = max(Int(elapsedSeconds.rounded(.down)), 0)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var pauseResumeLabel: String {
        isPaused ? "Resume" : "Pause"
    }

    var pauseResumeSystemImage: String {
        isPaused ? "play.fill" : "pause.fill"
    }

    func updatePausedState(_ paused: Bool) {
        guard paused != isPaused else {
            return
        }

        if paused {
            pauseStartedAt = Date()
        } else if let pauseStartedAt {
            accumulatedPausedDuration += Date().timeIntervalSince(pauseStartedAt)
            self.pauseStartedAt = nil
        }

        isPaused = paused
        tick()
    }

    private func tick() {
        let now = Date()
        let activePauseDuration: TimeInterval
        if isPaused, let pauseStartedAt {
            activePauseDuration = now.timeIntervalSince(pauseStartedAt)
        } else {
            activePauseDuration = 0
        }

        elapsedSeconds = max(now.timeIntervalSince(startedAt) - accumulatedPausedDuration - activePauseDuration, 0)
    }
}

@MainActor
final class RecordingControlOverlay {
    private let model: RecordingControlOverlayModel
    private let panel: NSPanel

    init(
        title: String,
        isPaused: Bool,
        pauseResumeAction: @escaping () -> Void,
        stopAction: @escaping () -> Void
    ) {
        model = RecordingControlOverlayModel(
            title: title,
            isPaused: isPaused,
            pauseResumeAction: pauseResumeAction,
            stopAction: stopAction
        )
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 390, height: 82),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: RecordingControlOverlayView(model: model))
        positionPanel()
        panel.orderFrontRegardless()
    }

    deinit {
        MainActor.assumeIsolated {
            close()
        }
    }

    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    func updatePausedState(_ paused: Bool) {
        model.updatePausedState(paused)
    }

    private func positionPanel() {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let frame = CGRect(
            x: screenFrame.midX - 195,
            y: screenFrame.maxY - 104,
            width: 390,
            height: 82
        )
        panel.setFrame(frame, display: true)
    }
}

private struct RecordingControlOverlayView: View {
    @ObservedObject var model: RecordingControlOverlayModel

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.red)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Text(model.elapsedLabel)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
            }

            Spacer(minLength: 8)

            Button(action: model.pauseResumeAction) {
                Label(model.pauseResumeLabel, systemImage: model.pauseResumeSystemImage)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help(model.isPaused ? "Resume the recording." : "Pause the recording.")

            Button(role: .destructive, action: model.stopAction) {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 390, height: 82)
        .sssGlassSurface(cornerRadius: 18)
    }
}

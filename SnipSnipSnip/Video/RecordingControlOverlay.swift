import AppKit
import Combine
import SwiftUI

@MainActor
final class RecordingControlOverlayModel: ObservableObject {
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var isPaused: Bool

    let title: String
    let sourceLabel: String
    let preferences: VideoRecordingPreferences
    let pauseResumeAction: () -> Void
    let stopAction: () -> Void
    private let startedAt = Date()
    private var accumulatedPausedDuration: TimeInterval = 0
    private var pauseStartedAt: Date?
    private var timerTask: Task<Void, Never>?

    init(
        title: String,
        sourceLabel: String,
        preferences: VideoRecordingPreferences,
        isPaused: Bool,
        pauseResumeAction: @escaping () -> Void,
        stopAction: @escaping () -> Void
    ) {
        self.title = title
        self.sourceLabel = sourceLabel
        self.preferences = preferences
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

    var stateLabel: String {
        isPaused ? "Paused" : "Recording"
    }

    var sourceSummaryLabel: String {
        "\(sourceLabel) • \(preferences.frameRate.label) • \(preferences.quality.label)"
    }

    var recordingOptionsSummaryLabel: String {
        [
            preferences.recordsSystemAudio ? "System audio" : "No system audio",
            preferences.recordsMicrophone ? "Mic on" : "Mic off",
            preferences.showsCursor ? "Cursor shown" : "Cursor hidden",
            preferences.showsMouseClicks ? "Clicks shown" : "Clicks hidden"
        ].joined(separator: " • ")
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
        sourceLabel: String,
        preferences: VideoRecordingPreferences,
        isPaused: Bool,
        pauseResumeAction: @escaping () -> Void,
        stopAction: @escaping () -> Void
    ) {
        model = RecordingControlOverlayModel(
            title: title,
            sourceLabel: sourceLabel,
            preferences: preferences,
            isPaused: isPaused,
            pauseResumeAction: pauseResumeAction,
            stopAction: stopAction
        )
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 94),
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
            x: screenFrame.midX - 250,
            y: screenFrame.maxY - 116,
            width: 500,
            height: 94
        )
        panel.setFrame(frame, display: true)
    }
}

private struct RecordingControlOverlayView: View {
    @ObservedObject var model: RecordingControlOverlayModel

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 12) {
                recordingBeacon

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.stateLabel)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(model.isPaused ? .yellow : .red)

                        Text(model.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(model.sourceSummaryLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(model.recordingOptionsSummaryLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                Text(model.elapsedLabel)
                    .font(.system(.title2, design: .monospaced).weight(.bold))
                    .contentTransition(.numericText())

                HStack(spacing: 8) {
                    Button(action: model.pauseResumeAction) {
                        Label(model.pauseResumeLabel, systemImage: model.pauseResumeSystemImage)
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .frame(width: 104)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help(model.isPaused ? "Resume the recording." : "Pause the recording.")

                    Button(role: .destructive, action: model.stopAction) {
                        Label("Stop", systemImage: "stop.fill")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .frame(width: 72)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .help("Stop and save the recording.")
                }
            }
        }
        .padding(16)
        .frame(width: 500, height: 94)
        .sssGlassSurface(cornerRadius: 20)
    }

    private var recordingBeacon: some View {
        ZStack {
            Circle()
                .fill((model.isPaused ? Color.yellow : Color.red).opacity(0.18))
                .frame(width: 28, height: 28)

            Circle()
                .fill(model.isPaused ? Color.yellow : Color.red)
                .frame(width: 11, height: 11)
        }
    }
}

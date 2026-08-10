import AppKit
import Combine
import SwiftUI

@MainActor
final class RecordingControlOverlayModel: ObservableObject {
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var phase: VideoRecordingPhase
    @Published private(set) var isCommandInFlight: Bool
    @Published private(set) var preferences: VideoRecordingPreferences
    @Published private(set) var audioToggleErrorMessage: String?
    @Published private(set) var audioLevels = ScreenRecordingAudioLevels()

    let title: String
    let sourceLabel: String
    let pauseResumeAction: () -> Void
    let stopAction: () -> Void
    let audioOptionsAction: (_ recordsSystemAudio: Bool, _ recordsMicrophone: Bool) async throws -> Void
    private let startedAt = Date()
    private var accumulatedPausedDuration: TimeInterval = 0
    private var pauseStartedAt: Date?
    private var timerTask: Task<Void, Never>?
    private var audioOptionsTask: Task<Void, Never>?

    init(
        title: String,
        sourceLabel: String,
        preferences: VideoRecordingPreferences,
        phase: VideoRecordingPhase,
        isCommandInFlight: Bool = false,
        pauseResumeAction: @escaping () -> Void,
        stopAction: @escaping () -> Void,
        audioOptionsAction: @escaping (_ recordsSystemAudio: Bool, _ recordsMicrophone: Bool) async throws -> Void
    ) {
        self.title = title
        self.sourceLabel = sourceLabel
        self.preferences = preferences
        self.phase = phase
        self.isCommandInFlight = isCommandInFlight
        self.pauseResumeAction = pauseResumeAction
        self.stopAction = stopAction
        self.audioOptionsAction = audioOptionsAction

        if phase == .paused {
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
        audioOptionsTask?.cancel()
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
        switch phase {
        case .paused: WorkflowVocabulary.Status.videoPaused
        case .finishing: WorkflowVocabulary.Status.videoFinishing
        default: WorkflowVocabulary.Status.videoRecording
        }
    }

    var isPaused: Bool { phase == .paused }

    var controlsAreEnabled: Bool {
        phase != .finishing && !isCommandInFlight
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

    var recordsSystemAudio: Bool {
        preferences.recordsSystemAudio
    }

    var recordsMicrophone: Bool {
        preferences.recordsMicrophone
    }

    func audioLevel(for source: ScreenRecordingAudioSource) -> Double {
        switch source {
        case .system:
            return recordsSystemAudio && !isPaused ? audioLevels.system : 0
        case .microphone:
            return recordsMicrophone && !isPaused ? audioLevels.microphone : 0
        }
    }

    func setRecordsSystemAudio(_ recordsSystemAudio: Bool) {
        guard controlsAreEnabled else { return }
        updateAudioOptions(
            recordsSystemAudio: recordsSystemAudio,
            recordsMicrophone: preferences.recordsMicrophone
        )
    }

    func setRecordsMicrophone(_ recordsMicrophone: Bool) {
        guard controlsAreEnabled else { return }
        updateAudioOptions(
            recordsSystemAudio: preferences.recordsSystemAudio,
            recordsMicrophone: recordsMicrophone
        )
    }

    func updatePhase(_ phase: VideoRecordingPhase, commandInFlight: Bool) {
        let wasPaused = isPaused
        let willBePaused = phase == .paused
        self.phase = phase
        isCommandInFlight = commandInFlight

        if willBePaused, !wasPaused {
            pauseStartedAt = Date()
        } else if !willBePaused, wasPaused, let pauseStartedAt {
            accumulatedPausedDuration += Date().timeIntervalSince(pauseStartedAt)
            self.pauseStartedAt = nil
        }

        if willBePaused || phase == .finishing {
            audioLevels = ScreenRecordingAudioLevels()
        }
        tick()
    }

    func updatePausedState(_ paused: Bool) {
        updatePhase(paused ? .paused : .recording, commandInFlight: false)
    }

    func updateAudioLevels(_ levels: ScreenRecordingAudioLevels) {
        guard !isPaused else {
            audioLevels = ScreenRecordingAudioLevels()
            return
        }

        audioLevels = ScreenRecordingAudioLevels(
            system: preferences.recordsSystemAudio ? levels.system : 0,
            microphone: preferences.recordsMicrophone ? levels.microphone : 0
        )
    }

    private func updateAudioOptions(recordsSystemAudio: Bool, recordsMicrophone: Bool) {
        guard controlsAreEnabled else { return }
        guard recordsSystemAudio != preferences.recordsSystemAudio
                || recordsMicrophone != preferences.recordsMicrophone else {
            return
        }

        let previousPreferences = preferences
        preferences.recordsSystemAudio = recordsSystemAudio
        preferences.recordsMicrophone = recordsMicrophone
        audioLevels = ScreenRecordingAudioLevels(
            system: recordsSystemAudio ? audioLevels.system : 0,
            microphone: recordsMicrophone ? audioLevels.microphone : 0
        )
        audioToggleErrorMessage = nil
        audioOptionsTask?.cancel()
        audioOptionsTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await audioOptionsAction(recordsSystemAudio, recordsMicrophone)
            } catch {
                preferences = previousPreferences
                audioToggleErrorMessage = error.localizedDescription
            }
        }
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

extension RecordingControlOverlayModel {
    convenience init(
        title: String,
        sourceLabel: String,
        preferences: VideoRecordingPreferences,
        isPaused: Bool,
        pauseResumeAction: @escaping () -> Void,
        stopAction: @escaping () -> Void,
        audioOptionsAction: @escaping (_ recordsSystemAudio: Bool, _ recordsMicrophone: Bool) async throws -> Void
    ) {
        self.init(
            title: title,
            sourceLabel: sourceLabel,
            preferences: preferences,
            phase: isPaused ? .paused : .recording,
            pauseResumeAction: pauseResumeAction,
            stopAction: stopAction,
            audioOptionsAction: audioOptionsAction
        )
    }
}

nonisolated enum RecordingOverlayPlacement {
    static let panelSize = CGSize(width: 590, height: 136)

    static func frame(in visibleFrame: CGRect) -> CGRect {
        let normalized = visibleFrame.standardized
        guard normalized.width > 0, normalized.height > 0 else {
            return CGRect(origin: normalized.origin, size: panelSize)
        }
        let size = CGSize(
            width: min(panelSize.width, normalized.width),
            height: min(panelSize.height, normalized.height)
        )
        let x = min(
            max(normalized.midX - size.width / 2, normalized.minX),
            normalized.maxX - size.width
        )
        let preferredY = normalized.maxY - size.height - 22
        let y = min(
            max(preferredY, normalized.minY),
            normalized.maxY - size.height
        )
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
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
        phase: VideoRecordingPhase,
        presentationFrame: CGRect?,
        pauseResumeAction: @escaping () -> Void,
        stopAction: @escaping () -> Void,
        audioOptionsAction: @escaping (_ recordsSystemAudio: Bool, _ recordsMicrophone: Bool) async throws -> Void
    ) {
        model = RecordingControlOverlayModel(
            title: title,
            sourceLabel: sourceLabel,
            preferences: preferences,
            phase: phase,
            pauseResumeAction: pauseResumeAction,
            stopAction: stopAction,
            audioOptionsAction: audioOptionsAction
        )
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 590, height: 136),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: RecordingControlOverlayView(model: model))
        positionPanel(in: presentationFrame)
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

    func updatePhase(_ phase: VideoRecordingPhase, commandInFlight: Bool) {
        model.updatePhase(phase, commandInFlight: commandInFlight)
    }

    func updateAudioLevels(_ levels: ScreenRecordingAudioLevels) {
        model.updateAudioLevels(levels)
    }

    private func positionPanel(in presentationFrame: CGRect?) {
        let screenFrame = presentationFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? .zero
        panel.setFrame(RecordingOverlayPlacement.frame(in: screenFrame), display: true)
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
                            .foregroundStyle(stateColor)

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

                    if let audioToggleErrorMessage = model.audioToggleErrorMessage {
                        Text(audioToggleErrorMessage)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                Text(model.elapsedLabel)
                    .font(.system(.title2, design: .monospaced).weight(.bold))
                    .contentTransition(.numericText())

                HStack(alignment: .top, spacing: 10) {
                    RecordingAudioSourceControl(
                        title: "System Audio",
                        level: model.audioLevel(for: .system),
                        isEnabled: model.recordsSystemAudio && !model.isPaused,
                        tint: .green,
                        isOn: Binding(
                            get: { model.recordsSystemAudio },
                            set: { model.setRecordsSystemAudio($0) }
                        )
                    )
                    .help("Include or mute system audio for this recording only.")

                    RecordingAudioSourceControl(
                        title: "Mic",
                        level: model.audioLevel(for: .microphone),
                        isEnabled: model.recordsMicrophone && !model.isPaused,
                        tint: .cyan,
                        isOn: Binding(
                            get: { model.recordsMicrophone },
                            set: { model.setRecordsMicrophone($0) }
                        )
                    )
                    .help("Include or mute microphone narration for this recording only.")
                }
                .disabled(!model.controlsAreEnabled)

                HStack(spacing: 8) {
                    Button(action: model.pauseResumeAction) {
                        Label(model.pauseResumeLabel, systemImage: model.pauseResumeSystemImage)
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .frame(width: 104)
                    }
                    .buttonStyle(RecordingControlButtonStyle(tint: model.isPaused ? .green : .yellow))
                    .controlSize(.small)
                    .disabled(!model.controlsAreEnabled)
                    .help(model.isPaused ? "Resume the recording." : "Pause the recording.")

                    Button(role: .destructive, action: model.stopAction) {
                        Label("Stop", systemImage: "stop.fill")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .frame(width: 72)
                    }
                    .buttonStyle(RecordingControlButtonStyle(tint: .red, isProminent: true))
                    .controlSize(.small)
                    .disabled(!model.controlsAreEnabled)
                    .help("Stop and save the recording.")
                }
            }
        }
        .padding(16)
        .frame(width: 590, height: 136)
        .sssFloatingOverlaySurface(cornerRadius: 20, shadowOpacity: 0.12)
    }

    private var recordingBeacon: some View {
        ZStack {
            Circle()
                .fill(beaconColor.opacity(0.18))
                .frame(width: 28, height: 28)

            Circle()
                .fill(beaconColor)
                .frame(width: 11, height: 11)
        }
    }

    private var beaconColor: Color {
        switch model.phase {
        case .paused: .orange
        case .finishing: .secondary
        default: .red
        }
    }

    private var stateColor: Color {
        switch model.phase {
        case .paused: .yellow
        case .finishing: .secondary
        default: .red
        }
    }
}

struct RecordingAudioSourceControl: View {
    let title: String
    let level: Double
    let isEnabled: Bool
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            RecordingAudioToggle(title: title, isOn: $isOn)

            RecordingAudioMeter(
                level: level,
                isEnabled: isEnabled,
                tint: tint
            )
        }
        .frame(width: RecordingAudioLayout.sourceControlWidth, alignment: .leading)
    }
}

private enum RecordingAudioLayout {
    static let sourceControlWidth: CGFloat = 136
}

private struct RecordingAudioMeter: View {
    let level: Double
    let isEnabled: Bool
    let tint: Color

    private var clampedLevel: Double {
        min(max(level, 0), 1)
    }

    private var meterColor: Color {
        isEnabled ? tint : .secondary
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(meterColor.opacity(isEnabled ? 0.16 : 0.10))

                Capsule()
                    .fill(meterColor.opacity(isEnabled ? 0.78 : 0.24))
                    .frame(width: max(proxy.size.width * clampedLevel, 3))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 6)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(meterColor.opacity(isEnabled ? 0.12 : 0.08))
        )
        .overlay(
            Capsule()
                .strokeBorder(meterColor.opacity(isEnabled ? 0.28 : 0.16), lineWidth: 1)
        )
        .accessibilityLabel("Audio signal level")
        .animation(.easeOut(duration: 0.12), value: clampedLevel)
        .animation(.easeInOut(duration: 0.16), value: isEnabled)
    }
}

private struct RecordingAudioToggle: View {
    let title: String
    @Binding var isOn: Bool

    private var stateColor: Color {
        isOn ? .green : .secondary
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(isOn ? .green : .gray)
                .accessibilityLabel(title)
        }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(stateColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(stateColor.opacity(isOn ? 0.18 : 0.12))
            )
            .overlay(
                Capsule()
                    .strokeBorder(stateColor.opacity(isOn ? 0.45 : 0.26), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.16), value: isOn)
    }
}

struct RecordingControlButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let tint: Color
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.bold))
            .foregroundStyle(isEnabled ? tint : Color.secondary.opacity(0.6))
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(tint.opacity(isEnabled ? (isProminent ? 0.24 : 0.18) : 0.08))
            )
            .overlay(
                Capsule()
                    .strokeBorder(tint.opacity(isEnabled ? (isProminent ? 0.62 : 0.48) : 0.18), lineWidth: 1)
            )
            .shadow(color: tint.opacity(isEnabled ? (isProminent ? 0.18 : 0.10) : 0), radius: 6, y: 2)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
    }
}

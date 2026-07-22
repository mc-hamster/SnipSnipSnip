import AppKit
import SwiftUI

@MainActor
final class GuideCaptureHUDController: NSObject, NSWindowDelegate {
    static let shared = GuideCaptureHUDController()
    private var panel: NSPanel?
    private var thumbnailPreviewPanel: NSPanel?
    private var previewedStepID: UUID?

    func show(guide: GuideWorkflowModel) {
        if let panel {
            // A panel can outlive its first Guide briefly while AppKit completes its
            // close cycle. Refresh its hosted view and bring it forward so a second
            // Guide always receives fresh, live controls.
            panel.contentView = NSHostingView(rootView: GuideCaptureHUD(guide: guide))
            panel.setContentSize(NSSize(width: 590, height: 320))
            panel.acceptsMouseMovedEvents = true
            position(panel, corner: guide.capturePreferences.hudCorner)
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 590, height: 320),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        // SwiftUI's native `.help` uses AppKit hover tracking. Explicit mouse
        // move delivery is needed for this non-activating capture panel.
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.contentView = NSHostingView(rootView: GuideCaptureHUD(guide: guide))
        panel.delegate = self
        position(panel, corner: guide.capturePreferences.hudCorner)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        hideThumbnailPreview()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        hideThumbnailPreview()
        panel = nil
    }

    func showThumbnailPreview(step: GuideStep, image: CGImage) {
        guard let sourcePanel = panel else { return }
        let previewPanel: NSPanel
        if let thumbnailPreviewPanel {
            previewPanel = thumbnailPreviewPanel
        } else {
            previewPanel = NSPanel(
                contentRect: CGRect(x: 0, y: 0, width: 320, height: 270),
                styleMask: [.nonactivatingPanel, .hudWindow],
                backing: .buffered,
                defer: false
            )
            previewPanel.level = .floating
            previewPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            previewPanel.hidesOnDeactivate = false
            previewPanel.ignoresMouseEvents = true
            previewPanel.sharingType = .none
            previewPanel.backgroundColor = .clear
            previewPanel.isOpaque = false
            thumbnailPreviewPanel = previewPanel
        }
        previewPanel.contentView = NSHostingView(rootView: GuideCaptureThumbnailPreview(step: step, image: image))
        previewedStepID = step.id
        positionThumbnailPreview(previewPanel, beside: sourcePanel)
        previewPanel.orderFrontRegardless()
    }

    func hideThumbnailPreview(for stepID: UUID? = nil) {
        if let stepID, previewedStepID != stepID { return }
        thumbnailPreviewPanel?.orderOut(nil)
        previewedStepID = nil
    }

    private func position(_ panel: NSPanel, corner: String) {
        guard let frame = NSScreen.main?.visibleFrame else { return }
        let inset: CGFloat = 20
        let x = corner.contains("Right") ? frame.maxX - panel.frame.width - inset : frame.minX + inset
        let y = corner.contains("bottom") ? frame.minY + inset : frame.maxY - panel.frame.height - inset
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func positionThumbnailPreview(_ preview: NSPanel, beside source: NSPanel) {
        guard let visibleFrame = source.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        let inset: CGFloat = 12
        let preferredLeft = source.frame.minX - preview.frame.width - inset
        let x = preferredLeft >= visibleFrame.minX ? preferredLeft : source.frame.maxX + inset
        let y = min(max(source.frame.minY, visibleFrame.minY), visibleFrame.maxY - preview.frame.height)
        preview.setFrameOrigin(CGPoint(x: x, y: y))
    }
}

private struct GuideCaptureHUD: View {
    @ObservedObject var guide: GuideWorkflowModel
    @ObservedObject private var capture: GuideCaptureCoordinator
    @State private var hoveredTooltip: String?

    init(guide: GuideWorkflowModel) {
        self.guide = guide
        self.capture = guide.captureCoordinator
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 10) {
                HStack(spacing: 9) {
                    recordingBeacon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(statusTitle)
                            .font(.headline)
                        Text("\(guide.stepCount) steps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if capture.state == .finishing {
                        HStack(spacing: 6) {
                            if let fraction = capture.finalizationProgress?.fraction {
                                ProgressView(value: fraction).frame(width: 72)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                            Text("Working…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(elapsed)
                                .font(.system(.title3, design: .monospaced).weight(.bold))
                                .contentTransition(.numericText())
                        }
                    }
                }

                HStack(alignment: .bottom, spacing: 10) {
                    guideAudioControl(
                        title: "System Audio",
                        level: capture.audioLevels.system,
                        isOn: systemAudioBinding,
                        tint: .green,
                        tooltip: "Include or mute system audio for this Guide."
                    )

                    guideAudioControl(
                        title: "Mic",
                        level: capture.audioLevels.microphone,
                        isOn: microphoneBinding,
                        tint: .cyan,
                        tooltip: "Include or mute microphone narration for this Guide."
                    )

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 7) {
                        Button(action: guide.togglePauseResume) {
                            Label(capture.state == .paused ? "Resume" : "Pause", systemImage: capture.state == .paused ? "play.fill" : "pause.fill")
                                .frame(width: 82)
                        }
                        .buttonStyle(RecordingControlButtonStyle(tint: capture.state == .paused ? .green : .yellow))
                        .guideHUDTooltip(capture.state == .paused ? "Resume Guide Capture" : "Pause Guide Capture", hoveredTooltip: $hoveredTooltip)
                        .disabled(capture.state == .finishing)

                        HStack(spacing: 7) {
                            Button(action: guide.addManualStep) {
                                Label("Step", systemImage: "plus.square")
                            }
                            .buttonStyle(RecordingControlButtonStyle(tint: .blue))
                            .guideHUDTooltip("Add Manual Step", hoveredTooltip: $hoveredTooltip)
                            .disabled(capture.state != .recording)

                            Button(role: .destructive, action: guide.stopGuide) {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .buttonStyle(RecordingControlButtonStyle(tint: .red, isProminent: true))
                            .guideHUDTooltip("Stop Capturing and Open the Guide Editor", hoveredTooltip: $hoveredTooltip)
                            .disabled(capture.state == .finishing)

                            Button(role: .destructive, action: guide.discardGuide) {
                                Label("Discard", systemImage: "trash")
                            }
                            .buttonStyle(RecordingControlButtonStyle(tint: .red))
                            .guideHUDTooltip("Discard This Guide", hoveredTooltip: $hoveredTooltip)
                            .disabled(capture.state == .finishing)
                        }
                    }
                }
                .opacity(capture.state == .finishing ? 0.6 : 1)

                if capture.state == .finishing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(capture.finalizationProgress?.detail ?? "Finalizing Guide…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Completed work stays protected")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let issue = capture.captureIssue ?? capture.recoveryIssue {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(issue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                }
                if guide.capturePreferences.hudPreviewsEnabled {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                        // Keep the newest steps immediately available while bounding
                        // HUD work during sessions with hundreds of steps.
                            ForEach(hudSteps) { step in
                                if let image = capture.stepThumbnails[step.id] ?? capture.stepImages[step.id] {
                                    ZStack(alignment: .topTrailing) {
                                        Image(decorative: image, scale: 1)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 133, height: 74)
                                            .clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 7))
                                            .onHover { isHovering in
                                                if isHovering { GuideCaptureHUDController.shared.showThumbnailPreview(step: step, image: image) }
                                                else { GuideCaptureHUDController.shared.hideThumbnailPreview(for: step.id) }
                                            }
                                        Button { guide.deleteStep(id: step.id) } label: { Image(systemName: "xmark.circle.fill") }
                                            .buttonStyle(.plain).foregroundStyle(.white, .black.opacity(0.65)).padding(3)
                                            .guideHUDTooltip("Delete Step \(step.sequence)", hoveredTooltip: $hoveredTooltip)
                                            .disabled(capture.state == .finishing)
                                    }
                                }
                            }
                            if guide.stepCount > hudSteps.count {
                                Text("+\(guide.stepCount - hudSteps.count) earlier")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 76, height: 74)
                            }
                        }
                    }
                    .frame(height: 80)
                }
            }
            if let hoveredTooltip {
                Text(hoveredTooltip)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.22)))
                    .padding(.bottom, 5)
                    .allowsHitTesting(false)
                    .zIndex(100)
            }
        }
        .padding(12)
        .sssFloatingOverlaySurface(cornerRadius: 20, shadowOpacity: 0.12)
    }

    private func guideAudioControl(
        title: String,
        level: Double,
        isOn: Binding<Bool>,
        tint: Color,
        tooltip: String
    ) -> some View {
        RecordingAudioSourceControl(
            title: title,
            level: capture.state == .recording ? level : 0,
            isEnabled: isOn.wrappedValue && capture.state == .recording,
            tint: tint,
            isOn: isOn
        )
        .guideHUDTooltip(tooltip, hoveredTooltip: $hoveredTooltip)
        .disabled(capture.state != .recording || capture.isUpdatingAudioOptions)
    }

    private var systemAudioBinding: Binding<Bool> {
        Binding(
            get: { guide.capturePreferences.capturesSystemAudio },
            set: { guide.setGuideCapturesSystemAudio($0) }
        )
    }

    private var microphoneBinding: Binding<Bool> {
        Binding(
            get: { guide.capturePreferences.capturesMicrophone },
            set: { guide.setGuideCapturesMicrophone($0) }
        )
    }

    private var recordingBeacon: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.18))
                .frame(width: 28, height: 28)
            Circle()
                .fill(statusColor)
                .frame(width: 11, height: 11)
        }
    }

    private var elapsed: String {
        let interval = max(0, Date().timeIntervalSince(capture.startedAt ?? Date()))
        return String(format: "%02d:%02d", Int(interval) / 60, Int(interval) % 60)
    }

    private var statusTitle: String {
        switch capture.state {
        case .paused: "Guide Paused"
        case .finishing: "Finishing Guide…"
        default: "Guide Capturing"
        }
    }

    private var statusColor: Color {
        switch capture.state {
        case .paused: .orange
        case .finishing: .blue
        default: .red
        }
    }

    private var hudSteps: [GuideStep] {
        Array((capture.project?.steps ?? []).reversed().prefix(20))
    }
}

/// The HUD remains non-activating while a person works in another app. This
/// visible hover label supplements the native AppKit tooltip so its controls
/// stay discoverable even when macOS suppresses standard tooltip bubbles.
private struct GuideHUDTooltip: ViewModifier {
    let text: String
    @Binding var hoveredTooltip: String?

    func body(content: Content) -> some View {
        content
            .help(text)
            .onHover { isHovering in
                if isHovering {
                    hoveredTooltip = text
                } else if hoveredTooltip == text {
                    hoveredTooltip = nil
                }
            }
    }
}

private extension View {
    func guideHUDTooltip(_ text: String, hoveredTooltip: Binding<String?>) -> some View {
        modifier(GuideHUDTooltip(text: text, hoveredTooltip: hoveredTooltip))
    }
}

private struct GuideCaptureThumbnailPreview: View {
    let step: GuideStep
    let image: CGImage

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "list.number")
                    .foregroundStyle(.tint)
                Text("Step \(step.sequence)")
                    .font(.headline)
                Spacer()
                Text(step.eventKind.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(width: 292, height: 155)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(step.caption)
                .font(.subheadline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.2)))
    }
}

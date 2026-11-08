import AppKit
import AVKit
import SwiftUI

private struct VideoPlayerContainerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        view.showsSharingServiceButton = false
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = false
        view.updatesNowPlayingInfoCenter = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize? {
        // The viewport owns sizing, never the movie's intrinsic dimensions.
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

struct VideoPlaybackView: View {
    @ObservedObject var controller: VideoEditorController
    var showsTrimControls: Bool
    var showsZoomTargets = false

    var body: some View {
        VStack(spacing: 0) {
            stage
            transport
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var stage: some View {
        GeometryReader { proxy in
            let viewport = CGRect(x: 16, y: 16, width: max(proxy.size.width - 32, 1), height: max(proxy.size.height - 32, 1))
            let fitted = AVMakeRect(aspectRatio: controller.previewPixelSize, insideRect: viewport)
            VideoPlayerContainerView(player: controller.player)
                .frame(width: fitted.width, height: fitted.height)
                .position(x: fitted.midX, y: fitted.midY)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay {
            if let error = controller.previewError {
                VStack(spacing: 12) {
                    Label("Preview Unavailable", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(error).multilineTextAlignment(.center)
                    Button("Try Again", action: controller.refreshPreview)
                }
                .padding(24).frame(maxWidth: 420)
                .sssFloatingOverlaySurface(cornerRadius: 12)
            } else if showsZoomTargets, !controller.isPlaying, let zoom = controller.selectedZoom {
                VideoZoomTargetView(controller: controller, zoom: zoom)
            }
        }
        .clipped()
        .focusable()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video preview")
        .accessibilityIdentifier("video.preview")
        .onKeyPress(.space) { controller.togglePlayback(); return .handled }
        .onKeyPress(.leftArrow) { stepFrame(-1); return .handled }
        .onKeyPress(.rightArrow) { stepFrame(1); return .handled }
    }

    private var transport: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                EditorCommandGroup("Playback") {
                Button(action: controller.togglePlayback) {
                    Label(controller.isPlaying ? "Pause" : "Play", systemImage: controller.isPlaying ? "pause.fill" : "play.fill")
                        .frame(minWidth: 62)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(controller.isPreparingPreview || controller.previewError != nil)
                .help("Play or pause the video with your current edits.")
                .accessibilityIdentifier("video.playback.toggle")

                Button(action: controller.returnToStart) {
                    Label("Back to Start", systemImage: "backward.end.fill")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .help("Pause and return to the first kept frame.")
                .accessibilityIdentifier("video.playback.start")
                }

                Spacer(minLength: 8)
                if controller.isPreparingPreview {
                    ProgressView().controlSize(.small)
                    Text("Updating Preview").font(.caption).foregroundStyle(.secondary)
                }
                Text(controller.currentTimeLabel + " / " + controller.durationLabel)
                    .monospacedDigit()
                    .accessibilityLabel("Playhead \(controller.currentTimeLabel) of \(controller.durationLabel)")
                    .accessibilityIdentifier("video.playback.time")
            }

            if showsTrimControls {
                VideoTrimTimelineView(controller: controller, trimAccent: .accentColor)
                    .frame(height: 64)
                    .accessibilityIdentifier("video.trim.timeline")
                HStack {
                    Text("Drag the strip to scrub, or move the handles to trim.")
                    Spacer()
                    Text("Finished Length: \(controller.trimmedDurationLabel)")
                        .monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Slider(value: Binding(get: { controller.currentTimeSeconds }, set: { controller.scrub(to: $0) }),
                       in: 0...max(controller.recording.duration, 0.1)) {
                    Text("Playhead")
                }
                .labelsHidden()
                .accessibilityValue(controller.currentTimeLabel)
                .accessibilityIdentifier("video.playback.seek")
            }
            VideoZoomTimelineView(controller: controller)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback controls")
        .accessibilityIdentifier("video.playback.controls")
    }

    private func stepFrame(_ direction: Double) {
        controller.scrub(to: controller.currentTimeSeconds + direction / Double(controller.recording.preferences.frameRate.rawValue))
    }
}

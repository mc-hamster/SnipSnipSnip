import AppKit
import AVKit
import SwiftUI

private struct VideoPlayerContainerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = player
        view.showsSharingServiceButton = false
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = false
        view.updatesNowPlayingInfoCenter = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

struct VideoEditorToolbarView: View {
    @ObservedObject var controller: VideoEditorController
    let documentFilename: String
    let hasUnsavedChanges: Bool
    let exportPreferences: VideoExportPreferences
    let onBack: () -> Void
    let onExportRequest: (VideoExportRequest) -> Void
    let dragOutPayloadProvider: @MainActor () -> PromisedFilePayload?

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Label("Discard", systemImage: "xmark")
                }
                .buttonStyle(.glass)
                .help("Discard the current video editor session and return to the capture screen.")

                Spacer(minLength: 12)

                Text(documentFilename + (hasUnsavedChanges ? " *" : ""))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Menu("Export") {
                    Button("Export \(exportPreferences.menuLabel)…") {
                        onExportRequest(
                            VideoExportRequest(
                                format: exportPreferences.format,
                                target: exportPreferences.target
                            )
                        )
                    }

                    Divider()

                    Section("MP4 Quality") {
                        ForEach(VideoExportQualityPreset.allCases) { preset in
                            Button(preset.label) {
                                onExportRequest(VideoExportRequest(format: .mp4, target: .quality(preset)))
                            }
                        }
                    }

                    Section("MP4 Size Limit") {
                        ForEach(VideoExportSizeLimit.allCases) { sizeLimit in
                            Button(sizeLimit.label) {
                                onExportRequest(VideoExportRequest(format: .mp4, target: .sizeLimit(sizeLimit)))
                            }
                        }
                    }
                }
                .buttonStyle(.glassProminent)
                .help("Export the trimmed video using the last used preset or a size-limited target.")
                .disabled(controller.isExporting)

                PromisedFileDragView(
                    accessibilityLabel: "Drag trimmed recording to share",
                    payloadProvider: dragOutPayloadProvider
                )
                .frame(width: 68, height: 30)
                .help("Drag the current trimmed MP4 into Finder, Mail, or another app. Export starts after the drop is accepted.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct VideoEditorView: View {
    @ObservedObject var controller: VideoEditorController
    private let trimAccent = Color(red: 1.0, green: 0.82, blue: 0.18)

    var body: some View {
        VStack(spacing: 0) {
            videoStage

            trimPanel
        }
        .overlay {
            if let exportProgress = controller.exportProgress {
                exportProgressOverlay(exportProgress)
            }
        }
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .black),
                    Color(nsColor: .controlBackgroundColor)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .alert("Video Error", isPresented: Binding(get: {
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
    }

    private var videoStage: some View {
        ZStack(alignment: .topLeading) {
            Color.black

            VideoPlayerContainerView(player: controller.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)

            HStack(spacing: 8) {
                playbackPill(title: controller.recording.kind.label, systemImage: "video")
                playbackPill(title: controller.recording.sourceName, systemImage: "display")
                playbackPill(title: controller.currentTimeLabel + " / " + controller.durationLabel, systemImage: "clock")
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trimPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                trimPanelHeader(compact: false)
                trimPanelHeader(compact: true)
            }

            VideoTrimTimelineView(controller: controller, trimAccent: trimAccent)
                .frame(height: 92)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)

            HStack {
                timelineLabel(title: "In", value: controller.trimStartLabel)
                Spacer(minLength: 12)
                timelineLabel(title: "Current", value: controller.currentTimeLabel)
                Spacer(minLength: 12)
                timelineLabel(title: "Out", value: controller.trimEndLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .sssGlassSurface(cornerRadius: 0, shadowOpacity: 0.04)
    }

    private func playbackPill(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(.black.opacity(0.18)), in: .capsule)
    }

    private func timelineLabel(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
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
            .sssGlassSurface(cornerRadius: 18)
        }
    }

    private func trimPanelHeader(compact: Bool) -> some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        playPauseButton
                        trimPanelTitle
                    }

                    HStack(spacing: 10) {
                        Button("Preview Trim", action: controller.playTrimmedPreview)
                            .buttonStyle(.glass)
                            .help("Play the selected trim range from the current playhead or trim start.")

                        Button("Use Start Frame as Poster", action: controller.setPosterToTrimStart)
                            .buttonStyle(.glass)
                            .help("Use the trim start frame as the package poster frame.")
                    }
                }
            } else {
                HStack(spacing: 14) {
                    playPauseButton
                    trimPanelTitle
                    Spacer(minLength: 0)

                    Button("Preview Trim", action: controller.playTrimmedPreview)
                        .buttonStyle(.glass)
                        .help("Play the selected trim range from the current playhead or trim start.")

                    Button("Use Start Frame as Poster", action: controller.setPosterToTrimStart)
                        .buttonStyle(.glass)
                        .help("Use the trim start frame as the package poster frame.")
                }
            }
        }
    }

    private var playPauseButton: some View {
        Button(action: controller.togglePlayback) {
            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.white.opacity(0.08)).interactive(), in: .circle)
        .contentShape(Circle())
        .help(controller.isPlaying ? "Pause playback." : "Play the selected trim range.")
    }

    private var trimPanelTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Trim Video")
                .font(.headline)
            Text("Drag the yellow handles to set the clip and preview each trim frame. Drag in the strip to scrub playback.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct VideoTrimTimelineView: View {
    @ObservedObject var controller: VideoEditorController
    let trimAccent: Color

    @State private var startHandleDragOrigin: TimeInterval?
    @State private var endHandleDragOrigin: TimeInterval?

    private let handleWidth: CGFloat = 12
    private let edgeInset: CGFloat = 12
    private var centerInset: CGFloat { edgeInset + handleWidth / 2 }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = proxy.size.height
            let duration = max(controller.recording.duration, 0.1)
            let timelineWidth = max(width - (edgeInset * 2), 1)
            let startCenter = position(for: controller.session.trimStartSeconds, width: width, duration: duration)
            let endCenter = position(for: controller.session.trimEndSeconds, width: width, duration: duration)
            let startLeading = startCenter - handleWidth / 2
            let endLeading = endCenter - handleWidth / 2
            let currentX = position(for: controller.currentTimeSeconds, width: width, duration: duration)
            let selectionWidth = max(endCenter - startCenter, 1)

            ZStack(alignment: .leading) {
                filmstrip
                    .frame(width: timelineWidth, height: height)
                    .offset(x: edgeInset)

                timelineMask
                    .frame(width: max(startCenter, 0), height: height)

                timelineMask
                    .frame(width: max(width - endCenter, 0), height: height)
                    .offset(x: endCenter)

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(trimAccent, lineWidth: 2.5)
                    .frame(width: selectionWidth, height: height)
                    .offset(x: min(max(startCenter, 0), max(width - selectionWidth, 0)))

                handle
                    .offset(x: min(max(startLeading, 0), max(width - handleWidth, 0)))
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                            .onChanged { value in
                                let dragOrigin = startHandleDragOrigin ?? controller.session.trimStartSeconds
                                if startHandleDragOrigin == nil {
                                    startHandleDragOrigin = dragOrigin
                                }

                                controller.updateTrimStart(
                                    shiftedTime(
                                        origin: dragOrigin,
                                        deltaX: value.translation.width,
                                        width: width,
                                        duration: duration
                                    )
                                )
                            }
                            .onEnded { _ in
                                startHandleDragOrigin = nil
                            }
                    )

                handle
                    .offset(x: min(max(endLeading, 0), max(width - handleWidth, 0)))
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                            .onChanged { value in
                                let dragOrigin = endHandleDragOrigin ?? controller.session.trimEndSeconds
                                if endHandleDragOrigin == nil {
                                    endHandleDragOrigin = dragOrigin
                                }

                                controller.updateTrimEnd(
                                    shiftedTime(
                                        origin: dragOrigin,
                                        deltaX: value.translation.width,
                                        width: width,
                                        duration: duration
                                    )
                                )
                            }
                            .onEnded { _ in
                                endHandleDragOrigin = nil
                            }
                    )

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: height + 10)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: min(max(currentX - 1, 0), max(width - 2, 0)), y: -5)
            }
            .frame(width: width, height: height)
            .coordinateSpace(name: "timeline")
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { value in
                        controller.scrub(to: time(for: value.location.x, width: width, duration: duration))
                    }
            )
        }
    }

    private var filmstrip: some View {
        HStack(spacing: 1) {
            if controller.timelineThumbnails.isEmpty {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.08), Color.white.opacity(0.16)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            } else {
                ForEach(Array(controller.timelineThumbnails.enumerated()), id: \.offset) { _, thumbnail in
                    Image(nsImage: NSImage(cgImage: thumbnail, size: CGSize(width: thumbnail.width, height: thumbnail.height)))
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(trimAccent)
            .frame(width: handleWidth, height: 72)
            .overlay(
                VStack(spacing: 3) {
                    Capsule().fill(Color.black.opacity(0.4)).frame(width: 2, height: 14)
                    Capsule().fill(Color.black.opacity(0.4)).frame(width: 2, height: 14)
                }
            )
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }

    private var timelineMask: some View {
        Rectangle()
            .fill(Color(nsColor: .windowBackgroundColor))
            .opacity(0.98)
    }

    private func position(for seconds: TimeInterval, width: CGFloat, duration: TimeInterval) -> CGFloat {
        let usableWidth = max(width - (centerInset * 2), 1)
        let progress = CGFloat(min(max(seconds, 0), duration) / duration)
        return centerInset + (progress * usableWidth)
    }

    private func shiftedTime(origin: TimeInterval, deltaX: CGFloat, width: CGFloat, duration: TimeInterval) -> TimeInterval {
        let usableWidth = max(width - (centerInset * 2), 1)
        let deltaSeconds = TimeInterval(deltaX / usableWidth) * duration
        return origin + deltaSeconds
    }

    private func time(for x: CGFloat, width: CGFloat, duration: TimeInterval) -> TimeInterval {
        let usableWidth = max(width - (centerInset * 2), 1)
        let clampedX = min(max(x - centerInset, 0), usableWidth)
        return TimeInterval(clampedX / usableWidth) * duration
    }
}

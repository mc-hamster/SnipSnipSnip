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
                    let preferredRequest = VideoExportRequest(
                        format: exportPreferences.format,
                        target: exportPreferences.target
                    )
                    Button("Export \(exportPreferences.menuLabel)…") {
                        onExportRequest(
                            preferredRequest
                        )
                    }
                    .disabled(!VideoExportSupport.capability(for: preferredRequest.format, target: preferredRequest.target).isSupported)

                    Divider()

                    Section("MP4 Quality") {
                        ForEach(VideoExportQualityPreset.allCases) { preset in
                            exportButton(format: .mp4, target: .quality(preset))
                        }
                    }

                    Section("MP4 Size Limit") {
                        ForEach(VideoExportSizeLimit.allCases) { sizeLimit in
                            exportButton(format: .mp4, target: .sizeLimit(sizeLimit))
                        }
                    }

                    Section("Animated Loops") {
                        ForEach(VideoExportQualityPreset.allCases) { preset in
                            exportButton(format: .gif, target: .quality(preset))
                            exportButton(format: .apng, target: .quality(preset))
                        }
                    }

                }
                .buttonStyle(.glassProminent)
                .help("Export the trimmed video using MP4, GIF, APNG, or another available format.")
                .disabled(controller.isExporting)

                PromisedFileDragView(
                    accessibilityLabel: "Drag trimmed recording to share",
                    payloadProvider: dragOutPayloadProvider
                )
                .frame(width: 68, height: 30)
                .help("Drag the current trimmed export into Finder, Mail, or another app. Export starts after the drop is accepted.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func exportButton(format: VideoExportFormat, target: VideoExportTarget) -> some View {
        let request = VideoExportRequest(format: format, target: target)
        let capability = VideoExportSupport.capability(for: format, target: target)
        Button(request.menuLabel) {
            onExportRequest(request)
        }
        .disabled(!capability.isSupported)
        .help(capability.unsupportedReason ?? format.exportDetail)
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
        .alert("Video Export", isPresented: Binding(get: {
            controller.statusMessage != nil
        }, set: { value in
            if !value {
                controller.dismissStatus()
            }
        })) {
            Button("OK", role: .cancel) {
                controller.dismissStatus()
            }
        } message: {
            Text(controller.statusMessage ?? "")
        }
    }

    private var videoStage: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color.black, Color(red: 0.06, green: 0.07, blue: 0.09)],
                startPoint: .top,
                endPoint: .bottom
            )

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 34, y: 18)
                .padding(.horizontal, 26)
                .padding(.vertical, 22)

            VideoPlayerContainerView(player: controller.player)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                .padding(.horizontal, 42)
                .padding(.vertical, 38)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    playbackPill(title: controller.recording.kind.label, systemImage: "video")
                    playbackPill(title: controller.recording.sourceName, systemImage: "display")
                    playbackPill(title: controller.currentTimeLabel + " / " + controller.durationLabel, systemImage: "clock")
                }

                HStack(spacing: 8) {
                    playbackPill(title: controller.exportSummaryLabel, systemImage: "waveform")
                    playbackPill(title: "Space pauses or plays", systemImage: "keyboard")
                }
            }
            .padding(.leading, 46)
            .padding(.bottom, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .onKeyPress(.space) {
            controller.togglePlayback()
            return .handled
        }
    }

    private var trimPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                trimPanelHeader(compact: false)
                trimPanelHeader(compact: true)
            }

            VideoTrimTimelineView(controller: controller, trimAccent: trimAccent)
                .frame(height: 92)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)

            trimMetricsBar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .padding(.horizontal, 22)
        .padding(.top, 15)
        .padding(.bottom, 18)
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

    private var trimMetricsBar: some View {
        HStack(spacing: 8) {
            trimMetric(title: "In", value: controller.trimStartLabel)
            trimMetric(title: "Out", value: controller.trimEndLabel)
            trimMetric(title: "Duration", value: controller.trimmedDurationLabel)

            Spacer(minLength: 12)

            trimMetric(title: "Current", value: controller.currentTimeLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.045), in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func trimMetric(title: String, value: String) -> some View {
        Text(title.uppercased() + " " + value)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
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
                            .controlSize(.small)
                            .help("Play the selected trim range from the current playhead or trim start.")

                        Button("Use Start Frame as Poster", action: controller.setPosterToTrimStart)
                            .buttonStyle(.glass)
                            .controlSize(.small)
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
                        .controlSize(.small)
                        .help("Play the selected trim range from the current playhead or trim start.")

                    Button("Use Start Frame as Poster", action: controller.setPosterToTrimStart)
                        .buttonStyle(.glass)
                        .controlSize(.small)
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
            Text("Drag the strip to scrub, or move the handles to trim.")
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

    private let handleHitWidth: CGFloat = 24
    private let handleVisualWidth: CGFloat = 10
    private let trackHorizontalInset: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = proxy.size.height
            let trackInsetY: CGFloat = 9
            let trackHeight = min(max(height - (trackInsetY * 2), 1), 74)
            let duration = max(controller.recording.duration, 0.1)
            let trackLeading = max(trackHorizontalInset, handleHitWidth / 2)
            let timelineWidth = max(width - (trackLeading * 2), 1)
            let trackTrailing = trackLeading + timelineWidth
            let startCenter = position(
                for: controller.session.trimStartSeconds,
                trackLeading: trackLeading,
                trackWidth: timelineWidth,
                duration: duration
            )
            let endCenter = position(
                for: controller.session.trimEndSeconds,
                trackLeading: trackLeading,
                trackWidth: timelineWidth,
                duration: duration
            )
            let startLeading = startCenter - handleHitWidth / 2
            let endLeading = endCenter - handleHitWidth / 2
            let currentX = position(
                for: controller.currentTimeSeconds,
                trackLeading: trackLeading,
                trackWidth: timelineWidth,
                duration: duration
            )
            let selectionWidth = max(endCenter - startCenter, 1)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.32))
                    .frame(width: timelineWidth, height: trackHeight)
                    .offset(x: trackLeading, y: trackInsetY)

                filmstrip(width: timelineWidth, height: trackHeight)
                    .frame(width: timelineWidth, height: trackHeight)
                    .offset(x: trackLeading, y: trackInsetY)

                selectedRangeFill
                    .frame(width: selectionWidth, height: trackHeight)
                    .offset(x: startCenter, y: trackInsetY)

                timelineMask
                    .frame(width: max(startCenter - trackLeading, 0), height: trackHeight)
                    .offset(x: trackLeading, y: trackInsetY)

                timelineMask
                    .frame(width: max(trackTrailing - endCenter, 0), height: trackHeight)
                    .offset(x: endCenter, y: trackInsetY)

                trimRail(width: selectionWidth)
                    .offset(x: startCenter, y: trackInsetY + 5)

                trimRail(width: selectionWidth)
                    .offset(x: startCenter, y: trackInsetY + trackHeight - 7)

                handle(height: trackHeight)
                    .offset(x: min(max(startLeading, 0), max(width - handleHitWidth, 0)), y: trackInsetY)
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
                                        trackWidth: timelineWidth,
                                        duration: duration
                                    )
                                )
                            }
                            .onEnded { _ in
                                startHandleDragOrigin = nil
                            }
                    )

                handle(height: trackHeight)
                    .offset(x: min(max(endLeading, 0), max(width - handleHitWidth, 0)), y: trackInsetY)
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
                                        trackWidth: timelineWidth,
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
                    .frame(width: 2, height: trackHeight - 8)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                    .offset(x: min(max(currentX - 1, 0), max(width - 2, 0)), y: trackInsetY + 4)
            }
            .frame(width: width, height: height)
            .coordinateSpace(name: "timeline")
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { value in
                        controller.scrub(
                            to: time(
                                for: value.location.x,
                                trackLeading: trackLeading,
                                trackWidth: timelineWidth,
                                duration: duration
                            )
                        )
                    }
            )
        }
    }

    private func filmstrip(width: CGFloat, height: CGFloat) -> some View {
        let thumbnails = controller.timelineThumbnails
        let spacing: CGFloat = 1
        let thumbnailCount = max(thumbnails.count, 1)
        let thumbnailWidth = max((width - (spacing * CGFloat(thumbnailCount - 1))) / CGFloat(thumbnailCount), 1)

        return Group {
            if thumbnails.isEmpty {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.08), Color.white.opacity(0.16)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            } else {
                HStack(spacing: spacing) {
                    ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, thumbnail in
                        Image(nsImage: NSImage(cgImage: thumbnail, size: CGSize(width: thumbnail.width, height: thumbnail.height)))
                            .resizable()
                            .scaledToFill()
                            .frame(width: thumbnailWidth, height: height)
                            .clipped()
                    }
                }
                .frame(width: width, height: height, alignment: .leading)
                .clipped()
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func handle(height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(trimAccent)
                .frame(width: handleVisualWidth, height: height)
                .shadow(color: .black.opacity(0.28), radius: 4, y: 1)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.black.opacity(0.2), lineWidth: 0.75)
                .frame(width: handleVisualWidth, height: height)

            VStack(spacing: 4) {
                Capsule().fill(Color.black.opacity(0.42)).frame(width: 2, height: 13)
                Capsule().fill(Color.black.opacity(0.42)).frame(width: 2, height: 13)
            }
        }
        .frame(width: handleHitWidth, height: height)
        .contentShape(Rectangle())
    }

    private var selectedRangeFill: some View {
        Rectangle()
            .fill(trimAccent.opacity(0.09))
    }

    private func trimRail(width: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(trimAccent)
            .frame(width: width, height: 2)
            .shadow(color: trimAccent.opacity(0.24), radius: 2)
    }

    private var timelineMask: some View {
        Rectangle()
            .fill(Color.black.opacity(0.54))
    }

    private func position(
        for seconds: TimeInterval,
        trackLeading: CGFloat,
        trackWidth: CGFloat,
        duration: TimeInterval
    ) -> CGFloat {
        let progress = CGFloat(min(max(seconds, 0), duration) / duration)
        return trackLeading + (progress * trackWidth)
    }

    private func shiftedTime(
        origin: TimeInterval,
        deltaX: CGFloat,
        trackWidth: CGFloat,
        duration: TimeInterval
    ) -> TimeInterval {
        let deltaSeconds = TimeInterval(deltaX / max(trackWidth, 1)) * duration
        return origin + deltaSeconds
    }

    private func time(
        for x: CGFloat,
        trackLeading: CGFloat,
        trackWidth: CGFloat,
        duration: TimeInterval
    ) -> TimeInterval {
        let clampedX = min(max(x - trackLeading, 0), trackWidth)
        return TimeInterval(clampedX / max(trackWidth, 1)) * duration
    }
}

import AppKit
import SwiftUI

struct VideoTrimTimelineView: View {
    @ObservedObject var controller: VideoEditorController
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
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
                                    controller.beginContinuousEdit("Trim Video")
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
                                controller.endContinuousEdit()
                            }
                    )
                    .accessibilityElement()
                    .accessibilityLabel("Trim start")
                    .accessibilityValue(controller.trimStartLabel)
                    .accessibilityAdjustableAction { direction in
                        let delta = direction == .increment ? 0.1 : -0.1
                        controller.updateTrimStart(controller.session.trimStartSeconds + delta)
                    }
                    .accessibilityIdentifier("video.trim.start")

                handle(height: trackHeight)
                    .offset(x: min(max(endLeading, 0), max(width - handleHitWidth, 0)), y: trackInsetY)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                            .onChanged { value in
                                let dragOrigin = endHandleDragOrigin ?? controller.session.trimEndSeconds
                                if endHandleDragOrigin == nil {
                                    endHandleDragOrigin = dragOrigin
                                    controller.beginContinuousEdit("Trim Video")
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
                                controller.endContinuousEdit()
                            }
                    )
                    .accessibilityElement()
                    .accessibilityLabel("Trim end")
                    .accessibilityValue(controller.trimEndLabel)
                    .accessibilityAdjustableAction { direction in
                        let delta = direction == .increment ? 0.1 : -0.1
                        controller.updateTrimEnd(controller.session.trimEndSeconds + delta)
                    }
                    .accessibilityIdentifier("video.trim.end")

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: trackHeight - 8)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                    .offset(x: min(max(currentX - 1, 0), max(width - 2, 0)), y: trackInsetY + 4)
                    .accessibilityElement()
                    .accessibilityLabel("Playhead")
                    .accessibilityValue(controller.currentTimeLabel)
                    .accessibilityAdjustableAction { direction in
                        let delta = direction == .increment ? 0.1 : -0.1
                        controller.scrub(to: controller.currentTimeSeconds + delta)
                    }
                    .accessibilityIdentifier("video.trim.playhead")
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
                .stroke(Color.primary.opacity(colorSchemeContrast == .increased ? 0.72 : 0.34), lineWidth: colorSchemeContrast == .increased ? 1.5 : 0.75)
                .frame(width: handleVisualWidth, height: height)

            VStack(spacing: 4) {
                Capsule().fill(Color.primary.opacity(0.72)).frame(width: 2, height: 13)
                Capsule().fill(Color.primary.opacity(0.72)).frame(width: 2, height: 13)
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

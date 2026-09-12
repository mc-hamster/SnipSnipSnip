import AVKit
import SwiftUI

struct VideoZoomTargetView: View {
    @ObservedObject var controller: VideoEditorController
    let zoom: VideoZoom
    @StateObject private var preview = VideoZoomTargetPreview()
    @State private var retry = 0
    @State private var isMovingTarget = false

    private struct Request: Equatable {
        let time: Double
        let renderer: ObjectIdentifier?
        let retry: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Zoom Target", systemImage: "scope").fontWeight(.semibold)
                Text("\(zoom.scale, specifier: "%.1f")×").monospacedDigit()
                Spacer(minLength: 8)
                Button("Preview Zoom") { controller.previewZoom(zoom.id) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .disabled(controller.isPreparingPreview || controller.previewError != nil)
            }
            .font(.callout)
            Text("Full frame. Click or drag to choose a fixed focus. The outlined area will fill the video.")
                .font(.caption).foregroundStyle(.secondary)
            focusDescription
                .font(.caption).foregroundStyle(.secondary)
            GeometryReader { proxy in
                if let frame = preview.frame, frame.time == controller.currentTimeSeconds {
                    let imageSize = CGSize(width: frame.image.width, height: frame.image.height)
                    let imageRect = AVMakeRect(aspectRatio: imageSize, insideRect: CGRect(origin: .zero, size: proxy.size))
                    let scale = imageRect.width / imageSize.width
                    let contentRect = CGRect(x: imageRect.minX + frame.contentRect.minX * scale,
                                             y: imageRect.minY + frame.contentRect.minY * scale,
                                             width: frame.contentRect.width * scale, height: frame.contentRect.height * scale)
                    let geometry = VideoZoomGeometry.resolve(zoom, at: frame.time, interactions: controller.recording.interactions, atFullMagnification: true)
                    let target = geometry.rect(in: contentRect)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: frame.image, scale: 1)
                            .resizable().frame(width: imageRect.width, height: imageRect.height)
                            .position(x: imageRect.midX, y: imageRect.midY)
                        ZoomTargetOutline()
                            .stroke(.black, lineWidth: 4)
                            .overlay { ZoomTargetOutline().stroke(.white, lineWidth: 2) }
                            .frame(width: target.width, height: target.height)
                            .position(x: target.midX, y: target.midY)
                            .allowsHitTesting(false)
                        Color.clear
                            .frame(width: contentRect.width, height: contentRect.height)
                            .contentShape(Rectangle())
                            .position(x: contentRect.midX, y: contentRect.midY)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("video.zoomTarget"))
                                .onChanged { value in
                                    guard let point = VideoZoomGeometry.point(at: value.location, in: contentRect) else { return }
                                    if !isMovingTarget {
                                        controller.beginContinuousEdit(String(localized: "Move Zoom Target"))
                                        isMovingTarget = true
                                    }
                                    controller.moveZoomTarget(zoom.id, to: point)
                                }
                                .onEnded { _ in finishMovingTarget() })
                            .accessibilityElement()
                            .accessibilityLabel("Zoom Target")
                            .accessibilityValue("Horizontal \(geometry.center.x.formatted(.percent.precision(.fractionLength(0)))), vertical \(geometry.center.y.formatted(.percent.precision(.fractionLength(0))))")
                            .accessibilityHint("Turn off Follow Cursor and use Horizontal Focus and Vertical Focus in the Zooms inspector to position the target with the keyboard.")
                            .accessibilityIdentifier("video.zoom.target")
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .coordinateSpace(name: "video.zoomTarget")
                    .clipped()
                } else if let error = preview.error {
                    VStack(spacing: 8) {
                        Label("Zoom Target Unavailable", systemImage: "exclamationmark.triangle")
                        Text(error).font(.caption).lineLimit(2)
                        Button("Try Again") { retry += 1 }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("Preparing Zoom Target…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .underPageBackgroundColor))
        .accessibilityIdentifier("video.zoom.targetEditor")
        .task(id: Request(time: controller.currentTimeSeconds, renderer: controller.previewRenderer.map(ObjectIdentifier.init), retry: retry)) {
            guard let renderer = controller.previewRenderer else { return }
            await preview.load(url: controller.recording.sourceURL, time: controller.currentTimeSeconds, renderer: renderer)
        }
        .onDisappear { finishMovingTarget() }
    }

    private var focusDescription: Text {
        let source = VideoZoomGeometry.resolve(zoom, at: controller.currentTimeSeconds,
                                               interactions: controller.recording.interactions,
                                               atFullMagnification: true).focusSource
        switch source {
        case .fixed:
            return Text("Fixed Focus")
        case .cursor:
            return controller.session.effects.showsCursor
                ? Text("Following the recorded cursor.")
                : Text("Following the recorded cursor, even though it is hidden in the video.")
        case .fallback:
            return Text("No cursor position at this frame. Using the saved fixed focus.")
        }
    }

    private func finishMovingTarget() {
        guard isMovingTarget else { return }
        controller.endContinuousEdit()
        isMovingTarget = false
    }
}

/// A two-tone outline stays legible on light and dark footage without relying on accent color.
private struct ZoomTargetOutline: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addRect(rect.insetBy(dx: 2, dy: 2))
            let arm = min(10, min(rect.width, rect.height) / 4)
            path.move(to: CGPoint(x: rect.midX - arm, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX + arm, y: rect.midY))
            path.move(to: CGPoint(x: rect.midX, y: rect.midY - arm))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.midY + arm))
        }
    }
}

import AVFoundation
import Combine
import CoreGraphics
import Foundation

nonisolated struct VideoZoomTargetFrame: @unchecked Sendable {
    let image: CGImage
    let contentRect: CGRect
    let time: Double
}

/// An editing-only full-frame image. Never changes the player item, document, or exports.
@MainActor
final class VideoZoomTargetPreview: ObservableObject {
    @Published private(set) var frame: VideoZoomTargetFrame?
    @Published private(set) var error: String?
    private var cachedSource: (url: URL, time: Double, image: CGImage)?

    func load(url: URL, time: Double, renderer: VideoFrameRenderer) async {
        error = nil
        if cachedSource?.url != url || cachedSource?.time != time { frame = nil }
        do {
            let source: CGImage
            if let cachedSource, cachedSource.url == url, cachedSource.time == time {
                source = cachedSource.image
            } else {
                try await Task.sleep(for: .milliseconds(60))
                source = try await Self.sourceFrame(url: url, at: time)
                try Task.checkCancellation()
                cachedSource = (url, time, source)
            }
            let image = await Task.detached(priority: .userInitiated) {
                renderer.cgImage(source, at: time, applyingZooms: false)
            }.value
            try Task.checkCancellation()
            guard let image else { throw VideoExportError.exportFailed }
            frame = VideoZoomTargetFrame(image: image, contentRect: renderer.sourceRectInOutput, time: time)
        } catch {
            guard !Task.isCancelled else { return }
            frame = nil
            self.error = error.localizedDescription
        }
    }

    private static func sourceFrame(url: URL, at time: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let requested = CMTime(seconds: max(time, 0), preferredTimescale: 600)
        do {
            return try await generator.image(at: requested).image
        } catch {
            try Task.checkCancellation()
            // The trim end can equal the media duration, just beyond the final frame.
            generator.requestedTimeToleranceBefore = .positiveInfinity
            return try await generator.image(at: requested).image
        }
    }
}

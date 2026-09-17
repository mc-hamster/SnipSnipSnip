import AVFoundation
import CoreGraphics

@MainActor
struct VideoRenderPipeline {
    let asset: AVAsset
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix?
    let duration: Double
    let renderer: VideoFrameRenderer

    static func make(document: EditableVideoDocument, appliesCuts: Bool, sourceAsset: AVURLAsset? = nil) async throws -> Self {
        let source = sourceAsset ?? AVURLAsset(url: document.recording.sourceURL)
        guard let videoTrack = try await source.loadTracks(withMediaType: .video).first else {
            throw VideoExportError.exportFailed
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized.size
        let contentSize = CGSize(width: max(oriented.width, 2), height: max(oriented.height, 2))
        let timing = VideoEditTimeline(session: document.session, duration: document.recording.duration)
        let asset: AVAsset
        if appliesCuts {
            guard timing.duration > 0 else { throw VideoExportError.invalidSizeConstrainedDuration }
            let composition = AVMutableComposition()
            guard let outputVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VideoExportError.exportFailed
            }
            outputVideo.preferredTransform = transform
            let audioTracks = try await source.loadTracks(withMediaType: .audio)
            let pairs = audioTracks.compactMap { sourceTrack -> (AVAssetTrack, AVMutableCompositionTrack)? in
                guard let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
                return (sourceTrack, destination)
            }
            var insertion = CMTime.zero
            for range in timing.ranges {
                try Task.checkCancellation()
                let span = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600), end: CMTime(seconds: range.end, preferredTimescale: 600))
                try outputVideo.insertTimeRange(span, of: videoTrack, at: insertion)
                for (audio, destination) in pairs {
                    let available = try await audio.load(.timeRange)
                    let overlap = CMTimeRangeGetIntersection(span, otherRange: available)
                    if overlap.duration.seconds > 0 {
                        try destination.insertTimeRange(overlap, of: audio, at: insertion + overlap.start - span.start)
                    }
                }
                insertion = insertion + span.duration
            }
            asset = composition
        } else { asset = source }

        let cursor = try VideoRenderAssets.cursor()
        let click = try VideoRenderAssets.click()
        let shortcuts = VideoRenderAssets.shortcuts(document.recording.interactions)
        let renderer = try await Task.detached(priority: .userInitiated) {
            try VideoFrameRenderer(document: document, contentSize: contentSize,
                                   cursorImage: cursor, clickImage: click, shortcutImages: shortcuts,
                                   timeline: appliesCuts ? timing : nil)
        }.value
        try Task.checkCancellation()
        let filtered = try await AVVideoComposition(applyingFiltersTo: asset) { request in
            AVCIImageFilteringResult(resultImage: renderer.render(request.sourceImage, at: request.compositionTime.seconds))
        }
        let videoComposition = AVVideoComposition(configuration: AVVideoComposition.Configuration(
            customVideoCompositorClass: filtered.customVideoCompositorClass,
            frameDuration: document.recording.preferences.frameRate.frameInterval,
            instructions: filtered.instructions,
            renderSize: renderer.outputSize,
            sourceTrackIDForFrameTiming: filtered.sourceTrackIDForFrameTiming
        ))
        let mix = AVMutableAudioMix()
        mix.inputParameters = try await asset.loadTracks(withMediaType: .audio).map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(Float(document.session.effects.audioVolume), at: .zero)
            return parameters
        }
        return Self(asset: asset, videoComposition: videoComposition, audioMix: mix.inputParameters.isEmpty ? nil : mix,
                    duration: appliesCuts ? timing.duration : document.recording.duration, renderer: renderer)
    }

    func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }
}

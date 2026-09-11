import AVFoundation
import CoreGraphics
import CoreVideo
import XCTest
@testable import SnipSnipSnip

/// Deterministic source shared by rendering, persistence, and export tests.
@MainActor
enum VideoTestMedia {
    static func make(in directory: URL, duration: Double = 2, withAudio: Bool = false) async throws -> CapturedVideoRecording {
        let url = directory.appendingPathComponent("source.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 240
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoExportError.exportFailed }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(duration * 30) {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32ARGB, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 320, height: 240,
                                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 240))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 160, y: 0, width: 160, height: 240))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 20 + frame, y: 20, width: 20, height: 20))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData, Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard input.isReadyForMoreMediaData,
                  adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? VideoExportError.exportFailed
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VideoExportError.exportFailed }
        let sourceURL = withAudio ? try await addingAudio(to: url, in: directory, duration: duration) : url
        return CapturedVideoRecording(sourceURL: sourceURL, kind: .region, sourceName: "Video Editing Test",
                                      bounds: CGRect(x: 0, y: 0, width: 320, height: 240), recordedAt: Date(),
                                      duration: duration, preferences: VideoRecordingPreferences(recordsSystemAudio: withAudio))
    }

    private static func addingAudio(to videoURL: URL, in directory: URL, duration: Double) async throws -> URL {
        let audioURL = directory.appendingPathComponent("sound.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(duration * 48_000)))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(buffer.frameLength) { samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000) * 0.3) }
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try file.write(from: buffer)
        }
        let video = AVURLAsset(url: videoURL)
        let audio = AVURLAsset(url: audioURL)
        let composition = AVMutableComposition()
        let videoTracks = try await video.loadTracks(withMediaType: .video)
        let audioTracks = try await audio.loadTracks(withMediaType: .audio)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let span = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?.insertTimeRange(span, of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?.insertTimeRange(span, of: audioTrack, at: .zero)
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        let outputURL = directory.appendingPathComponent("source-with-audio.mp4")
        try await exporter.export(to: outputURL, as: .mp4)
        return outputURL
    }
}

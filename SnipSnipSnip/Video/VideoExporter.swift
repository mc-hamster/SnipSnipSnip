import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

nonisolated enum VideoExportError: LocalizedError {
    case exportSessionUnavailable
    case exportFailed
    case exportFailedWithReason(String)
    case posterGenerationFailed
    case invalidSizeConstrainedDuration
    case sizeConstraintUnsatisfied(Int64)
    case unsupportedFileType(VideoExportFormat)

    var errorDescription: String? {
        switch self {
        case .exportSessionUnavailable:
            return "The video export session could not be created."
        case .exportFailed:
            return "The video could not be exported."
        case .exportFailedWithReason(let reason):
            return reason
        case .posterGenerationFailed:
            return "A poster frame could not be generated for this video."
        case .invalidSizeConstrainedDuration:
            return "The trimmed video must be longer than zero seconds to export with a size limit."
        case .sizeConstraintUnsatisfied(let maximumBytes):
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB]
            formatter.countStyle = .file
            return "The video could not be compressed below \(formatter.string(fromByteCount: maximumBytes))."
        case .unsupportedFileType(let format):
            return "\(format.label) export is not supported for this video."
        }
    }
}

nonisolated struct VideoSizeConstrainedExportPlan: Equatable {
    let attemptIndex: Int
    let attemptScale: Double
    let maximumBytes: Int64
    let targetBytes: Int64
    let overheadBytes: Int64
    let audioBitRate: Int
    let videoBitRate: Int
}

enum VideoExporter {
    private static let logger = Logger(subsystem: "com.oontz.SnipSnipSnip", category: "VideoExporter")
    nonisolated private static let constrainedAttemptScales: [Double] = [0.95, 0.91, 0.87, 0.83, 0.79, 0.77, 0.75]
    nonisolated private static let preferredSizeConstrainedTargetFraction = 0.95
    nonisolated private static let constrainedRetrySafetyFactor = 0.93
    nonisolated private static let minimumPlannedTotalBitRate = 48_000
    nonisolated private static let minimumAudioBitRate = 24_000
    nonisolated private static let maximumAudioBitRate = 128_000
    nonisolated private static let minimumVideoBitRateWithAudio = 24_000
    nonisolated private static let minimumVideoBitRateWithoutAudio = 48_000

    static func export(_ document: EditableVideoDocument, as format: VideoExportFormat, to url: URL) async throws {
        try await export(
            document,
            using: VideoExportRequest(format: format, target: .quality(.high), updatesDefaults: false),
            progressHandler: nil,
            to: url
        )
    }

    static func export(
        _ document: EditableVideoDocument,
        using request: VideoExportRequest,
        progressHandler: (@MainActor (VideoExportProgress) -> Void)?,
        to url: URL
    ) async throws {
        switch request.target {
        case .quality(let preset):
            try await export(document, as: request.format, preset: preset, progressHandler: progressHandler, to: url)
        case .sizeLimit(let sizeLimit):
            try await export(document, as: request.format, sizeLimit: sizeLimit, progressHandler: progressHandler, to: url)
        }
    }

    static func export(
        _ document: EditableVideoDocument,
        as format: VideoExportFormat,
        preset: VideoExportQualityPreset,
        progressHandler: (@MainActor (VideoExportProgress) -> Void)?,
        to url: URL
    ) async throws {
        try VideoStorageGuardrails.ensureCanExport(
            sourceURL: document.recording.sourceURL,
            request: VideoExportRequest(format: format, target: .quality(preset), updatesDefaults: false),
            destinationURL: url
        )

        let asset = AVURLAsset(url: document.recording.sourceURL)
        let session = document.session.normalized(for: document.recording.duration)
        let presetName = exportPreset(for: preset)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw VideoExportError.exportSessionUnavailable
        }

        guard exportSession.supportedFileTypes.contains(format.fileType) else {
            throw VideoExportError.unsupportedFileType(format)
        }

        try? FileManager.default.removeItem(at: url)

        exportSession.outputURL = url
        exportSession.outputFileType = format.fileType
        exportSession.shouldOptimizeForNetworkUse = format == .mp4
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: session.trimStartSeconds, preferredTimescale: 600),
            end: CMTime(seconds: session.trimEndSeconds, preferredTimescale: 600)
        )

        let progressTask = Task {
            while !Task.isCancelled {
                if let progressHandler {
                    await MainActor.run {
                        progressHandler(VideoExportProgress(
                            title: "Exporting Video",
                            detail: format.label + " • " + preset.label,
                            fractionCompleted: Double(exportSession.progress)
                        ))
                    }
                }

                if exportSession.progress >= 0.999 {
                    break
                }

                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        defer {
            progressTask.cancel()
        }

        try await exportWithCancellation(exportSession, to: url, as: format.fileType)
    }

    static func exportPreset(for preset: VideoExportQualityPreset) -> String {
        switch preset {
        case .compact:
            return AVAssetExportPresetMediumQuality
        case .balanced:
            return AVAssetExportPreset1920x1080
        case .high:
            return AVAssetExportPresetHighestQuality
        }
    }

    nonisolated static func sizeConstrainedPlan(
        duration: TimeInterval,
        maximumBytes: Int64,
        hasAudio: Bool,
        attemptIndex: Int,
        sourceAverageBitRate: Int? = nil,
        preferredVideoBitRate: Int? = nil
    ) throws -> VideoSizeConstrainedExportPlan {
        let boundedDuration = max(duration, 0)

        guard boundedDuration > 0 else {
            throw VideoExportError.invalidSizeConstrainedDuration
        }

        let safeAttemptIndex = max(attemptIndex, 0)
        let scale = constrainedAttemptScales[min(safeAttemptIndex, constrainedAttemptScales.count - 1)]
        let preferredTargetBytes = preferredSizeConstrainedTargetBytes(maximumBytes: maximumBytes)
        let targetBytes = max(Int64(Double(preferredTargetBytes) * (scale / preferredSizeConstrainedTargetFraction)), Int64(64_000))
        let overheadBytes = min(max(maximumBytes / 50, 32_768), 512_000)
        let plannedTotalBitRate = plannedTotalBitRate(
            targetBytes: targetBytes,
            overheadBytes: overheadBytes,
            duration: boundedDuration
        )
        let totalBitRate = plannedTotalBitRate

        let audioBitRate = plannedAudioBitRate(totalBitRate: totalBitRate, hasAudio: hasAudio)
        let minimumVideoBitRate = minimumVideoBitRate(hasAudio: hasAudio)
        let baselineVideoBitRate = max(totalBitRate - audioBitRate, minimumVideoBitRate)
        let videoBitRate: Int
        if let preferredVideoBitRate {
            videoBitRate = max(min(baselineVideoBitRate, preferredVideoBitRate), minimumVideoBitRate)
        } else {
            videoBitRate = baselineVideoBitRate
        }

        return VideoSizeConstrainedExportPlan(
            attemptIndex: safeAttemptIndex,
            attemptScale: scale,
            maximumBytes: maximumBytes,
            targetBytes: targetBytes,
            overheadBytes: overheadBytes,
            audioBitRate: audioBitRate,
            videoBitRate: videoBitRate
        )
    }

    nonisolated static func preferredSizeConstrainedTargetBytes(maximumBytes: Int64) -> Int64 {
        Int64((Double(max(maximumBytes, 1)) * preferredSizeConstrainedTargetFraction).rounded(.down))
    }

    nonisolated static func plannedTotalBitRate(targetBytes: Int64, overheadBytes: Int64, duration: TimeInterval) -> Int {
        guard duration > 0 else {
            return minimumPlannedTotalBitRate
        }

        let payloadBytes = max(targetBytes - overheadBytes, Int64(64_000))
        return max(Int((Double(payloadBytes) * 8) / duration), minimumPlannedTotalBitRate)
    }

    nonisolated static func nextSizeConstrainedVideoBitRate(
        previousVideoBitRate: Int,
        actualFileSize: Int64,
        targetFileSize: Int64,
        hasAudio: Bool
    ) -> Int {
        let minimumBitRate = minimumVideoBitRate(hasAudio: hasAudio)

        guard actualFileSize > 0, targetFileSize > 0 else {
            return max(previousVideoBitRate / 2, minimumBitRate)
        }

        let ratio = min(max(Double(targetFileSize) / Double(actualFileSize), 0.15), 0.98)
        let adaptedBitRate = Int((Double(previousVideoBitRate) * ratio * constrainedRetrySafetyFactor).rounded(.down))
        return max(adaptedBitRate, minimumBitRate)
    }

    nonisolated private static func plannedAudioBitRate(totalBitRate: Int, hasAudio: Bool) -> Int {
        guard hasAudio else {
            return 0
        }

        let boundedTotal = max(totalBitRate, minimumPlannedTotalBitRate)
        let byShare = boundedTotal / 12
        let byTightBudget = boundedTotal / 4
        let target = min(max(byShare, minimumAudioBitRate), maximumAudioBitRate)
        return min(target, max(byTightBudget, minimumAudioBitRate))
    }

    nonisolated private static func minimumVideoBitRate(hasAudio: Bool) -> Int {
        hasAudio ? minimumVideoBitRateWithAudio : minimumVideoBitRateWithoutAudio
    }

    private static func logSizeConstrained(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    private static func errorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        var parts: [String] = [
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "description=\(nsError.localizedDescription)"
        ]

        if let reason = nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String,
           !reason.isEmpty {
            parts.append("reason=\(reason)")
        }

        if let suggestion = nsError.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String,
           !suggestion.isEmpty {
            parts.append("recovery=\(suggestion)")
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append(
                "underlying_domain=\(underlying.domain) underlying_code=\(underlying.code) underlying_description=\(underlying.localizedDescription)"
            )
        }

        return parts.joined(separator: " | ")
    }

    private static func errorSummary(_ error: Error?) -> String {
        guard let error else {
            return "none"
        }

        return errorSummary(error)
    }

    nonisolated static func needsAnotherSizeConstrainedAttempt(fileSize: Int64, maximumBytes: Int64) -> Bool {
        fileSize > maximumBytes
    }

    private static func export(
        _ document: EditableVideoDocument,
        as format: VideoExportFormat,
        sizeLimit: VideoExportSizeLimit,
        progressHandler: (@MainActor (VideoExportProgress) -> Void)?,
        to url: URL
    ) async throws {
        guard format == .mp4 else {
            throw VideoExportError.unsupportedFileType(format)
        }

        let session = document.session.normalized(for: document.recording.duration)
        let duration = max(session.trimEndSeconds - session.trimStartSeconds, 0)
        let asset = AVURLAsset(url: document.recording.sourceURL)
        let attemptCount = constrainedAttemptScales.count
        let hasAudioTrack = try await asset.loadTracks(withMediaType: .audio).isEmpty == false
        let sourceFileSize = try? fileSize(at: document.recording.sourceURL)
        let estimatedTrimmedSourceBytes = estimatedTrimmedFileSize(
            sourceFileSize: sourceFileSize ?? 0,
            sourceDuration: document.recording.duration,
            trimmedDuration: duration
        )
        let preferredTargetBytes = preferredSizeConstrainedTargetBytes(maximumBytes: sizeLimit.maximumBytes)
        let exportRunID = String(UUID().uuidString.prefix(8))

        logSizeConstrained("================ CAPPED ENCODE BEGIN [\(exportRunID)] ================")
        logSizeConstrained(
            "[\(exportRunID)] mode=avexportsession-filelength format=\(format.label) limit=\(sizeLimit.maximumBytes)B preferredTarget=\(preferredTargetBytes)B duration=\(duration)s sourceSize=\(sourceFileSize ?? 0)B estimatedTrimmed=\(estimatedTrimmedSourceBytes)B hasAudio=\(hasAudioTrack)"
        )
        logSizeConstrained("[\(exportRunID)] attemptScales=\(constrainedAttemptScales.map { String(format: "%.2f", $0) }.joined(separator: ","))")

        guard duration > 0 else {
            logSizeConstrained("================ CAPPED ENCODE END [\(exportRunID)] FAILED_ZERO_DURATION ================")
            throw VideoExportError.invalidSizeConstrainedDuration
        }

        let timeRange = CMTimeRange(
            start: CMTime(seconds: session.trimStartSeconds, preferredTimescale: 600),
            end: CMTime(seconds: session.trimEndSeconds, preferredTimescale: 600)
        )

        for attemptIndex in constrainedAttemptScales.indices {
            try Task.checkCancellation()

            let attemptPlan = try sizeConstrainedPlan(
                duration: duration,
                maximumBytes: sizeLimit.maximumBytes,
                hasAudio: hasAudioTrack,
                attemptIndex: attemptIndex
            )
            let attemptURL = TemporaryVideoMediaManager.exportAttemptURL(format: format)

            logSizeConstrained("[\(exportRunID)] ---------- ATTEMPT \(attemptIndex + 1)/\(attemptCount) BEGIN ----------")
            logSizeConstrained(
                "[\(exportRunID)] attempt=\(attemptIndex + 1) fileLengthLimit=\(attemptPlan.targetBytes)B"
            )

            do {
                try await exportSizeConstrainedAttempt(
                    asset: asset,
                    format: format,
                    fileLengthLimit: attemptPlan.targetBytes,
                    timeRange: timeRange,
                    attemptIndex: attemptIndex,
                    attemptCount: attemptCount,
                    sizeLimit: sizeLimit,
                    progressHandler: progressHandler,
                    to: attemptURL
                )

                let outputSize = (try? fileSize(at: attemptURL)) ?? 0
                logSizeConstrained("[\(exportRunID)] attempt=\(attemptIndex + 1) result size=\(outputSize)B")

                guard outputSize > 0 else {
                    try? FileManager.default.removeItem(at: attemptURL)
                    logSizeConstrained("================ CAPPED ENCODE END [\(exportRunID)] FAILED_EMPTY ================")
                    throw VideoExportError.exportFailedWithReason("The export finished without writing any video data.")
                }

                guard needsAnotherSizeConstrainedAttempt(fileSize: outputSize, maximumBytes: sizeLimit.maximumBytes) else {
                    try? FileManager.default.removeItem(at: url)
                    do {
                        try FileManager.default.moveItem(at: attemptURL, to: url)
                    } catch {
                        try? FileManager.default.removeItem(at: attemptURL)
                        throw error
                    }
                    logSizeConstrained("[\(exportRunID)] SUCCESS attempt=\(attemptIndex + 1) finalSize=\(outputSize)B")
                    logSizeConstrained("================ CAPPED ENCODE END [\(exportRunID)] SUCCESS ================")
                    return
                }

                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                if let progressHandler {
                    await MainActor.run {
                        progressHandler(VideoExportProgress(
                            title: "Retrying Compression",
                            detail: "Previous attempt wrote \(formatter.string(fromByteCount: outputSize)), which is over the \(sizeLimit.label.lowercased()) target.",
                            fractionCompleted: Double(attemptIndex + 1) / Double(attemptCount)
                        ))
                    }
                }
                logSizeConstrained("[\(exportRunID)] attempt=\(attemptIndex + 1) overLimit size=\(outputSize)B > max=\(sizeLimit.maximumBytes)B; retrying with lower fileLengthLimit")
            } catch {
                // AVAssetExportSession hard failure — a different fileLengthLimit won't fix it.
                logSizeConstrained("[\(exportRunID)] attempt=\(attemptIndex + 1) failed: \(errorSummary(error))")
                try? FileManager.default.removeItem(at: attemptURL)
                logSizeConstrained("================ CAPPED ENCODE END [\(exportRunID)] FAILED_WRITER ================")
                throw error
            }

            try? FileManager.default.removeItem(at: attemptURL)
        }

        logSizeConstrained("================ CAPPED ENCODE END [\(exportRunID)] FAILED_OVER_LIMIT ================")
        throw VideoExportError.sizeConstraintUnsatisfied(sizeLimit.maximumBytes)
    }

    // AVAssetExportSession runs in a system XPC service with the entitlements needed to read
    // hardware-decoded, IOSurface-backed samples produced by ScreenCaptureKit recordings.
    // AVAssetReader/AVAssetWriter do not have those entitlements inside a sandboxed container
    // and fail with IOSurface KERN_NO_ACCESS, corrupting the write and causing -12905 at
    // finishWriting. fileLengthLimit caps the output without a manual bitrate pipeline.
    private static func exportSizeConstrainedAttempt(
        asset: AVURLAsset,
        format: VideoExportFormat,
        fileLengthLimit: Int64,
        timeRange: CMTimeRange,
        attemptIndex: Int,
        attemptCount: Int,
        sizeLimit: VideoExportSizeLimit,
        progressHandler: (@MainActor (VideoExportProgress) -> Void)?,
        to url: URL
    ) async throws {
        let presetCandidates: [String] = [
            AVAssetExportPresetHighestQuality,
            AVAssetExportPreset1920x1080,
            AVAssetExportPreset1280x720,
            AVAssetExportPreset960x540,
            AVAssetExportPresetMediumQuality
        ]

        var selectedSession: AVAssetExportSession?
        var selectedPreset: String?
        for preset in presetCandidates {
            if let candidate = AVAssetExportSession(asset: asset, presetName: preset),
               candidate.supportedFileTypes.contains(format.fileType) {
                selectedSession = candidate
                selectedPreset = preset
                break
            }
        }

        guard let exportSession = selectedSession, let preset = selectedPreset else {
            throw VideoExportError.exportSessionUnavailable
        }

        let attemptNumber = attemptIndex + 1
        logSizeConstrained(
            "Attempt \(attemptNumber) preset=\(preset) fileLengthLimit=\(fileLengthLimit)B timeRange=\(timeRange.start.seconds)s-\(timeRange.end.seconds)s"
        )

        try? FileManager.default.removeItem(at: url)
        exportSession.timeRange = timeRange
        exportSession.fileLengthLimit = fileLengthLimit

        let progressTask = Task {
            while !Task.isCancelled {
                let sessionFraction = Double(exportSession.progress)
                let perAttemptWeight = 1.0 / Double(max(attemptCount, 1))
                let base = Double(attemptIndex) * perAttemptWeight
                let fraction = base + perAttemptWeight * min(max(sessionFraction, 0), 0.999)
                if let progressHandler {
                    await MainActor.run {
                        progressHandler(VideoExportProgress(
                            title: attemptIndex == 0 ? "Compressing Video" : "Retrying Compression",
                            detail: "Target \(ByteCountFormatter.string(fromByteCount: sizeLimit.maximumBytes, countStyle: .file))",
                            fractionCompleted: fraction
                        ))
                    }
                }
                if exportSession.progress >= 0.999 { break }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        defer {
            progressTask.cancel()
        }

        try await exportWithCancellation(exportSession, to: url, as: format.fileType)
        logSizeConstrained("Attempt \(attemptNumber) export session completed")
    }

    private static func exportWithCancellation(
        _ exportSession: AVAssetExportSession,
        to url: URL,
        as fileType: AVFileType
    ) async throws {
        let cancellationProxy = ExportSessionCancellationProxy(exportSession)

        try await withTaskCancellationHandler(operation: {
            try await exportSession.export(to: url, as: fileType)
        }, onCancel: {
            cancellationProxy.cancel()
        })

        try Task.checkCancellation()
    }

    private static func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    nonisolated static func estimatedTrimmedFileSize(sourceFileSize: Int64, sourceDuration: TimeInterval, trimmedDuration: TimeInterval) -> Int64 {
        guard sourceFileSize > 0, sourceDuration > 0, trimmedDuration > 0 else {
            return 0
        }

        let boundedTrimmedDuration = min(trimmedDuration, sourceDuration)
        return Int64((Double(sourceFileSize) * (boundedTrimmedDuration / sourceDuration)).rounded(.up))
    }

    nonisolated static func estimatedAverageBitRate(fileSize: Int64, duration: TimeInterval) -> Int? {
        guard fileSize > 0, duration > 0 else {
            return nil
        }

        return max(Int((Double(fileSize) * 8) / duration), 1)
    }

    static func posterFrame(for url: URL, at seconds: TimeInterval) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let requestedTime = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)

        do {
            return try await generator.image(at: requestedTime).image
        } catch {
            generator.requestedTimeToleranceBefore = .positiveInfinity
            return try await generator.image(at: requestedTime).image
        }
    }

    static func timelineFrames(for url: URL, duration: TimeInterval, count: Int) async throws -> [CGImage] {
        try await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            generator.maximumSize = CGSize(width: 320, height: 180)

            let frameCount = max(count, 1)
            let boundedDuration = max(duration, 0)
            var images: [CGImage] = []
            images.reserveCapacity(frameCount)

            for index in 0..<frameCount {
                let seconds: TimeInterval
                if boundedDuration == 0 {
                    seconds = 0
                } else {
                    seconds = min((Double(index) + 0.5) / Double(frameCount) * boundedDuration, boundedDuration)
                }

                let requestedTime = CMTime(seconds: seconds, preferredTimescale: 600)

                do {
                    let image = try await generateImage(from: generator, at: requestedTime)
                    images.append(image)
                } catch {
                    if let previousImage = images.last {
                        images.append(previousImage)
                    }
                }
            }

            if let firstImage = images.first {
                while images.count < frameCount {
                    images.append(firstImage)
                }
                return images
            }

            throw VideoExportError.posterGenerationFailed
        }.value
    }

    nonisolated private static func generateImage(from generator: AVAssetImageGenerator, at requestedTime: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: requestedTime) { image, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let image else {
                    continuation.resume(throwing: VideoExportError.posterGenerationFailed)
                    return
                }

                continuation.resume(returning: image)
            }
        }
    }

    nonisolated static func pngData(for image: CGImage) throws -> Data {
        let data = NSMutableData()

        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw VideoExportError.posterGenerationFailed
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw VideoExportError.posterGenerationFailed
        }

        return data as Data
    }
}

private final class ExportSessionCancellationProxy: @unchecked Sendable {
    nonisolated(unsafe) private let exportSession: AVAssetExportSession

    nonisolated init(_ exportSession: AVAssetExportSession) {
        self.exportSession = exportSession
    }

    nonisolated func cancel() {
        exportSession.cancelExport()
    }
}

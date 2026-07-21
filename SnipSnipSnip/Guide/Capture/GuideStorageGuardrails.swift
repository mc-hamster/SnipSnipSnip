import CoreGraphics
import Foundation

nonisolated enum GuideStorageError: LocalizedError, Equatable {
    case insufficientAvailableSpace(location: String, requiredBytes: Int64, availableBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .insufficientAvailableSpace(let location, let requiredBytes, let availableBytes):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Guide needs at least \(formatter.string(fromByteCount: requiredBytes)) of free space in \(location), but only \(formatter.string(fromByteCount: availableBytes)) is available. Free space, then resume or retry."
        }
    }
}

/// Storage checks shared by Guide capture, recovery, and export. The estimates
/// intentionally reserve enough room to close an active media encoder and to
/// atomically replace an export without deleting the previous good file.
nonisolated enum GuideStorageGuardrails {
    static let minimumStepCaptureFreeBytes: Int64 = 256_000_000
    static let minimumVideoCaptureFreeBytes: Int64 = 1_000_000_000
    static let minimumLiveFreeBytes: Int64 = 500_000_000
    static let minimumExportFreeBytes: Int64 = 500_000_000

    static func captureHeadroomBytes(
        pixelWidth: Int,
        pixelHeight: Int,
        framesPerSecond: Int,
        sourceVideoEnabled: Bool
    ) -> Int64 {
        guard sourceVideoEnabled else { return minimumStepCaptureFreeBytes }
        let pixelsPerSecond = Int64(max(pixelWidth, 1))
            * Int64(max(pixelHeight, 1))
            * Int64(max(framesPerSecond, 1))
        // H.264 screen content varies sharply with motion. Reserve roughly three
        // minutes at a deliberately conservative 0.04 bytes per pixel-frame.
        let estimatedMediaBytes = Int64((Double(pixelsPerSecond) * 0.04 * 180).rounded(.up))
        return max(minimumVideoCaptureFreeBytes, estimatedMediaBytes)
    }

    static func exportHeadroomBytes(document: EditableGuideDocument, format: GuideExportFormat) -> Int64 {
        let includedIDs = Set(document.project.steps.lazy
            .filter { $0.isIncluded && !$0.isDeleted }
            .map(\.id))
        let sourcePixels = document.stepImages.reduce(into: Int64(0)) { total, pair in
            guard includedIDs.contains(pair.key) else { return }
            total += Int64(pair.value.width) * Int64(pair.value.height)
        }
        let sourceMediaBytes = document.mediaSegmentURLs.values.reduce(into: Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            total = min(total + max(size, 0), Int64.max / 2)
        }
        func estimatedBytes(for candidate: GuideExportFormat) -> Int64 {
            let bytesPerPixel: Int64
            switch candidate {
            case .gif, .apng: bytesPerPixel = 3
            case .slideshowMP4: bytesPerPixel = 2
            case .pdf, .docx, .stepImages: bytesPerPixel = 1
            case .fullMotionMP4, .highlightMP4: return sourceMediaBytes
            case .zip: return 0
            }
            return min(sourcePixels * bytesPerPixel, 8_000_000_000)
        }
        guard format == .zip else {
            return max(minimumExportFreeBytes, estimatedBytes(for: format))
        }

        let nestedBytes = document.project.exportSettings.formats
            .filter { $0 != .zip && $0 != .stepImages }
            .reduce(into: Int64(0)) { total, nestedFormat in
                total = min(total + estimatedBytes(for: nestedFormat), Int64.max / 2)
            }
        let renderedStepBytes = estimatedBytes(for: .stepImages)
        let includedSourceBytes = document.project.exportSettings.includesSourceMediaInZIP ? sourceMediaBytes : 0
        let payloadAndTemporaryFiles = min(
            renderedStepBytes + nestedBytes + includedSourceBytes,
            Int64.max / 2
        )
        // ZIP is replaced atomically, so reserve room for both the complete new
        // archive and all temporary nested outputs while an older good ZIP remains.
        return max(minimumExportFreeBytes, payloadAndTemporaryFiles * 2)
    }

    static func ensureCanStartCapture(
        pixelWidth: Int,
        pixelHeight: Int,
        framesPerSecond: Int,
        sourceVideoEnabled: Bool,
        temporaryDirectory: URL,
        availableCapacity: (URL) -> Int64? = availableCapacityBytes
    ) throws {
        try ensureAvailableSpace(
            at: temporaryDirectory,
            requiredBytes: captureHeadroomBytes(
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                framesPerSecond: framesPerSecond,
                sourceVideoEnabled: sourceVideoEnabled
            ),
            location: "temporary storage",
            availableCapacity: availableCapacity
        )
    }

    static func ensureCanContinueCapture(
        temporaryDirectory: URL,
        availableCapacity: (URL) -> Int64? = availableCapacityBytes
    ) throws {
        try ensureAvailableSpace(
            at: temporaryDirectory,
            requiredBytes: minimumLiveFreeBytes,
            location: "temporary storage",
            availableCapacity: availableCapacity
        )
    }

    static func ensureCanExport(
        document: EditableGuideDocument,
        format: GuideExportFormat,
        directory: URL,
        availableCapacity: (URL) -> Int64? = availableCapacityBytes
    ) throws {
        let required = exportHeadroomBytes(document: document, format: format)
        try ensureAvailableSpace(
            at: directory,
            requiredBytes: required,
            location: "the destination folder",
            availableCapacity: availableCapacity
        )
        let temporary = FileManager.default.temporaryDirectory
        if temporary.resolvingSymlinksInPath() != directory.resolvingSymlinksInPath() {
            try ensureAvailableSpace(
                at: temporary,
                requiredBytes: min(required, 2_000_000_000),
                location: "temporary storage",
                availableCapacity: availableCapacity
            )
        }
    }

    private static func ensureAvailableSpace(
        at directory: URL,
        requiredBytes: Int64,
        location: String,
        availableCapacity: (URL) -> Int64?
    ) throws {
        // An unavailable capacity reading should not make every export fail on a
        // network volume. Actual writes remain atomic and report their real error.
        guard let available = availableCapacity(directory) else { return }
        guard available >= requiredBytes else {
            throw GuideStorageError.insufficientAvailableSpace(
                location: location,
                requiredBytes: requiredBytes,
                availableBytes: available
            )
        }
    }

    private static func availableCapacityBytes(at directory: URL) -> Int64? {
        let fileManager = FileManager.default
        let resolved = fileManager.fileExists(atPath: directory.path)
            ? directory
            : directory.deletingLastPathComponent()
        let values = try? resolved.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage { return important }
        if let available = values?.volumeAvailableCapacity { return Int64(available) }
        return nil
    }
}

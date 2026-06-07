import Foundation

nonisolated enum VideoStorageError: LocalizedError {
    case exportAlreadyInProgress
    case insufficientAvailableSpace(location: String, requiredBytes: Int64, availableBytes: Int64)
    case temporaryStorageLimitExceeded(currentBytes: Int64, limitBytes: Int64)

    var errorDescription: String? {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        switch self {
        case .exportAlreadyInProgress:
            return "A video export is already in progress."
        case .insufficientAvailableSpace(let location, let requiredBytes, let availableBytes):
            return "SnipSnipSnip needs at least \(formatter.string(fromByteCount: requiredBytes)) of free space in \(location), but only \(formatter.string(fromByteCount: availableBytes)) is currently available."
        case .temporaryStorageLimitExceeded(let currentBytes, let limitBytes):
            return "SnipSnipSnip temporary video storage is already using \(formatter.string(fromByteCount: currentBytes)), which is over the current safety budget of \(formatter.string(fromByteCount: limitBytes)). Save or discard an open recording, then try again."
        }
    }
}

nonisolated enum VideoStorageGuardrails {
    static let maximumTemporaryStorageBytes: Int64 = 8_000_000_000
    static let minimumRecordingFreeBytes: Int64 = 2_000_000_000
    static let minimumLiveRecordingFreeBytes: Int64 = 500_000_000
    static let minimumExportFreeBytes: Int64 = 1_000_000_000

    static func recommendedRecordingHeadroomBytes(
        width: Int,
        height: Int,
        preferences: VideoRecordingPreferences
    ) -> Int64 {
        let pixelBudget = Int64(max(width, 1)) * Int64(max(height, 1)) * Int64(max(preferences.frameRate.rawValue, 1))
        let multiplier: Double

        switch preferences.quality {
        case .compact:
            multiplier = 0.025
        case .balanced:
            multiplier = 0.04
        case .high:
            multiplier = 0.06
        }

        let streamBytesPerSecond = Int64((Double(pixelBudget) * multiplier).rounded(.up))
        let audioBytesPerSecond: Int64 = (preferences.recordsSystemAudio || preferences.recordsMicrophone) ? 24_000 : 0
        let estimatedWorkingSet = (streamBytesPerSecond + audioBytesPerSecond) * 180

        return max(estimatedWorkingSet, minimumRecordingFreeBytes)
    }

    static func estimatedExportWorkingSetBytes(sourceFileSize: Int64, request: VideoExportRequest) -> Int64 {
        let boundedSourceSize = max(sourceFileSize, 0)

        switch request.target {
        case .quality:
            if request.format == .gif || request.format == .apng {
                return max(minimumExportFreeBytes, min(max(boundedSourceSize / 2, 250_000_000), 2_000_000_000))
            }

            return max(minimumExportFreeBytes, min(max(boundedSourceSize, 500_000_000), 4_000_000_000))
        case .sizeLimit(let sizeLimit):
            return max(minimumExportFreeBytes, min(max(sizeLimit.maximumBytes * 2, 500_000_000), 4_000_000_000))
        }
    }

    static func ownedTemporaryMediaURLs(
        fileManager: FileManager = .default,
        in directoryURL: URL? = nil,
        excluding excludedURLs: [URL] = []
    ) throws -> [URL] {
        let rootURL = (directoryURL ?? fileManager.temporaryDirectory).standardizedFileURL
        let excluded = Set(excludedURLs.map { $0.standardizedFileURL })
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .nameKey]
        let contents = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        return try contents.filter { candidateURL in
            let standardizedCandidate = candidateURL.standardizedFileURL

            guard !excluded.contains(standardizedCandidate) else {
                return false
            }

            let values = try standardizedCandidate.resourceValues(forKeys: resourceKeys)
            let fileName = values.name ?? standardizedCandidate.lastPathComponent
            return values.isRegularFile == true && TemporaryVideoMediaManager.isOwnedTemporaryMediaFileName(fileName)
        }
    }

    static func ownedTemporaryMediaSizeBytes(
        fileManager: FileManager = .default,
        in directoryURL: URL? = nil,
        excluding excludedURLs: [URL] = []
    ) throws -> Int64 {
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let urls = try ownedTemporaryMediaURLs(fileManager: fileManager, in: directoryURL, excluding: excludedURLs)

        return try urls.reduce(into: Int64(0)) { total, url in
            let values = try url.resourceValues(forKeys: resourceKeys)
            let fileSize = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            total += Int64(fileSize)
        }
    }

    @discardableResult
    static func cleanupOwnedTemporaryMedia(
        fileManager: FileManager = .default,
        in directoryURL: URL? = nil,
        excluding excludedURLs: [URL] = []
    ) throws -> Int64 {
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let urls = try ownedTemporaryMediaURLs(fileManager: fileManager, in: directoryURL, excluding: excludedURLs)
        var deletedBytes: Int64 = 0

        for url in urls {
            let values = try url.resourceValues(forKeys: resourceKeys)
            let fileSize = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            try? fileManager.removeItem(at: url)
            deletedBytes += Int64(fileSize)
        }

        return deletedBytes
    }

    static func ensureCanStartRecording(
        width: Int,
        height: Int,
        preferences: VideoRecordingPreferences,
        fileManager: FileManager = .default,
        excluding excludedURLs: [URL] = []
    ) throws {
        let currentUsage = try ownedTemporaryMediaSizeBytes(fileManager: fileManager, excluding: excludedURLs)

        guard currentUsage < maximumTemporaryStorageBytes else {
            throw VideoStorageError.temporaryStorageLimitExceeded(
                currentBytes: currentUsage,
                limitBytes: maximumTemporaryStorageBytes
            )
        }

        let requiredBytes = recommendedRecordingHeadroomBytes(width: width, height: height, preferences: preferences)
        try ensureAvailableSpace(
            at: fileManager.temporaryDirectory,
            requiredBytes: requiredBytes,
            location: "temporary storage",
            fileManager: fileManager
        )
    }

    static func liveRecordingHeadroomBytes(
        width: Int,
        height: Int,
        preferences: VideoRecordingPreferences
    ) -> Int64 {
        max(
            minimumLiveRecordingFreeBytes,
            recommendedRecordingHeadroomBytes(width: width, height: height, preferences: preferences) / 4
        )
    }

    static func ensureCanContinueRecording(
        width: Int,
        height: Int,
        preferences: VideoRecordingPreferences,
        fileManager: FileManager = .default,
        excluding excludedURLs: [URL] = []
    ) throws {
        let currentUsage = try ownedTemporaryMediaSizeBytes(fileManager: fileManager, excluding: excludedURLs)

        guard currentUsage < maximumTemporaryStorageBytes else {
            throw VideoStorageError.temporaryStorageLimitExceeded(
                currentBytes: currentUsage,
                limitBytes: maximumTemporaryStorageBytes
            )
        }

        try ensureAvailableSpace(
            at: fileManager.temporaryDirectory,
            requiredBytes: liveRecordingHeadroomBytes(width: width, height: height, preferences: preferences),
            location: "temporary storage",
            fileManager: fileManager
        )
    }

    static func ensureCanExport(
        sourceURL: URL,
        request: VideoExportRequest,
        destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let sourceFileSize = try fileSize(at: sourceURL, fileManager: fileManager)
        let requiredBytes = estimatedExportWorkingSetBytes(sourceFileSize: sourceFileSize, request: request)

        try ensureAvailableSpace(
            at: fileManager.temporaryDirectory,
            requiredBytes: requiredBytes,
            location: "temporary storage",
            fileManager: fileManager
        )
        try ensureAvailableSpace(
            at: destinationURL.deletingLastPathComponent(),
            requiredBytes: requiredBytes,
            location: "the destination folder",
            fileManager: fileManager
        )
    }

    private static func ensureAvailableSpace(
        at directoryURL: URL,
        requiredBytes: Int64,
        location: String,
        fileManager: FileManager
    ) throws {
        let availableBytes = availableCapacityBytes(at: directoryURL, fileManager: fileManager) ?? 0

        guard availableBytes >= requiredBytes else {
            throw VideoStorageError.insufficientAvailableSpace(
                location: location,
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )
        }
    }

    private static func fileSize(at url: URL, fileManager: FileManager) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }

    private static func availableCapacityBytes(at directoryURL: URL, fileManager: FileManager) -> Int64? {
        let resolvedDirectoryURL: URL

        if fileManager.fileExists(atPath: directoryURL.path) {
            resolvedDirectoryURL = directoryURL
        } else {
            resolvedDirectoryURL = directoryURL.deletingLastPathComponent()
        }

        let values = try? resolvedDirectoryURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])

        if let important = values?.volumeAvailableCapacityForImportantUsage {
            return important
        }

        if let available = values?.volumeAvailableCapacity {
            return Int64(available)
        }

        return nil
    }
}

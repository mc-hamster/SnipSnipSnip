import Foundation

nonisolated enum TemporaryVideoMediaManager {
    static let recordingPrefix = "SnipSnipSnip-"
    static let exportAttemptPrefix = "SnipSnipSnip-export-"
    private static let ownedFileExtensions: Set<String> = ["mp4", "mov"]

    static func recordingOutputURL(
        files: any FileSystemServicing = SystemFileService(),
        format: VideoExportFormat = .mp4
    ) -> URL {
        files.temporaryDirectory
            .appendingPathComponent("\(recordingPrefix)\(UUID().uuidString)")
            .appendingPathExtension(format.fileExtension)
    }

    static func exportAttemptURL(
        files: any FileSystemServicing = SystemFileService(),
        format: VideoExportFormat
    ) -> URL {
        files.temporaryDirectory
            .appendingPathComponent("\(exportAttemptPrefix)\(UUID().uuidString)")
            .appendingPathExtension(format.fileExtension)
    }

    static func isOwnedTemporaryMediaURL(
        _ url: URL,
        files: any FileSystemServicing = SystemFileService()
    ) -> Bool {
        let standardizedURL = url.standardizedFileURL
        let temporaryDirectoryURL = files.temporaryDirectory.standardizedFileURL

        guard standardizedURL.deletingLastPathComponent() == temporaryDirectoryURL else {
            return false
        }

        return isOwnedTemporaryMediaFileName(standardizedURL.lastPathComponent)
    }

    static func isOwnedTemporaryMediaFileName(_ fileName: String) -> Bool {
        let nsFileName = fileName as NSString
        let pathExtension = nsFileName.pathExtension.lowercased()

        guard ownedFileExtensions.contains(pathExtension) else {
            return false
        }

        let baseName = nsFileName.deletingPathExtension
        return baseName.hasPrefix(recordingPrefix) || baseName.hasPrefix(exportAttemptPrefix)
    }
}

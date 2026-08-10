import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

enum SSSVideoDocumentError: LocalizedError {
    case invalidPackage
    case missingManifest
    case missingMedia
    case invalidManifest
    case unsupportedFormatVersion(Int)
    case unsupportedFormatIdentifier(String)
    case invalidPosterData
    case posterUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidPackage:
            return "The selected .sssvideo file is not a valid \(AppBranding.displayName) video package."
        case .missingManifest:
            return "The selected .sssvideo file is missing its document manifest."
        case .missingMedia:
            return "The selected .sssvideo file is missing its video media."
        case .invalidManifest:
            return "The selected .sssvideo file could not be decoded."
        case .unsupportedFormatVersion(let version):
            return "This .sssvideo file uses unsupported format version \(version)."
        case .unsupportedFormatIdentifier(let identifier):
            return "The selected file is not a \(AppBranding.displayName) video document (\(identifier))."
        case .invalidPosterData:
            return "The poster frame in this .sssvideo file could not be decoded."
        case .posterUnavailable:
            return "The video poster frame is still being prepared. Try saving again in a moment."
        }
    }
}

nonisolated enum SSSVideoDocumentPackage {
    static let temporaryDirectoryPrefix = "SnipSnipSnipVideo-"
    static let formatIdentifier = "com.oontz.snipsnipsnip.video-document"
    static let formatVersion = 2

    static let manifestFilename = "document.json"
    static let mediaFilename = "media.mp4"
    static let posterFilename = "poster.png"

    nonisolated static func save(
        document: EditableVideoDocument,
        posterImage: CGImage?,
        to url: URL,
        files: any FileSystemServicing = SystemFileService()
    ) throws {
        guard let posterImage else {
            throw SSSVideoDocumentError.posterUnavailable
        }
        try savePackage(
            document: document,
            posterData: VideoExporter.pngData(for: posterImage),
            to: url,
            files: files
        )
    }

    nonisolated static func saveRecoveryCheckpoint(
        document: EditableVideoDocument,
        to url: URL,
        files: any FileSystemServicing = SystemFileService()
    ) throws {
        try savePackage(document: document, posterData: nil, to: url, files: files)
    }

    nonisolated private static func savePackage(
        document: EditableVideoDocument,
        posterData: Data?,
        to url: URL,
        files: any FileSystemServicing
    ) throws {
        let temporaryDirectoryURL = files.temporaryDirectory
            .appendingPathComponent("\(temporaryDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        let manifest = DocumentManifest(
            formatIdentifier: formatIdentifier,
            formatVersion: formatVersion,
            savedAt: Date(),
            assets: DocumentAssets(media: mediaFilename, posterImage: posterFilename),
            recording: RecordingRecord(document.recording),
            session: SessionRecord(document.session)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)

        defer {
            try? files.removeItem(at: temporaryDirectoryURL)
        }

        try? files.removeItem(at: temporaryDirectoryURL)
        try files.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: false)
        try files.writeData(manifestData, to: temporaryDirectoryURL.appendingPathComponent(manifestFilename), options: .atomic)
        try files.copyItem(at: document.recording.sourceURL, to: temporaryDirectoryURL.appendingPathComponent(mediaFilename))

        if let posterData {
            try files.writeData(
                posterData,
                to: temporaryDirectoryURL.appendingPathComponent(posterFilename),
                options: .atomic
            )
        }

        if files.fileExists(atPath: url.path) {
            try files.replaceItemAt(url, withItemAt: temporaryDirectoryURL)
        } else {
            try files.moveItem(at: temporaryDirectoryURL, to: url)
        }
    }

    nonisolated static func load(
        from url: URL,
        files: any FileSystemServicing = SystemFileService()
    ) throws -> EditableVideoDocument {
        guard files.directoryExists(at: url) else {
            throw SSSVideoDocumentError.invalidPackage
        }

        let manifestURL = url.appendingPathComponent(manifestFilename)

        guard files.fileExists(atPath: manifestURL.path) else {
            throw SSSVideoDocumentError.missingManifest
        }

        let manifestHeader = try loadManifestHeader(from: manifestURL, files: files)

        guard manifestHeader.formatIdentifier == formatIdentifier else {
            throw SSSVideoDocumentError.unsupportedFormatIdentifier(manifestHeader.formatIdentifier)
        }

        guard manifestHeader.formatVersion == formatVersion else {
            throw SSSVideoDocumentError.unsupportedFormatVersion(manifestHeader.formatVersion)
        }

        let manifest = try loadManifest(from: manifestURL, files: files)

        let mediaURL = url.appendingPathComponent(manifest.assets.media)

        guard files.fileExists(atPath: mediaURL.path) else {
            throw SSSVideoDocumentError.missingMedia
        }

        let recording = manifest.recording.capturedVideoRecording(with: mediaURL)
        let session = manifest.session.videoEditorSession().normalized(for: recording.duration)
        return EditableVideoDocument(recording: recording, session: session)
    }

    nonisolated static func compatibilityStatus(
        at url: URL,
        files: any FileSystemServicing = SystemFileService()
    ) -> PackageCompatibilityStatus {
        let manifestURL = url.appendingPathComponent(manifestFilename)

        guard files.directoryExists(at: url),
              files.fileExists(atPath: manifestURL.path) else {
            return .invalidManifest
        }

        do {
            let manifestHeader = try loadManifestHeader(from: manifestURL, files: files)

            guard manifestHeader.formatIdentifier == formatIdentifier else {
                return .unsupportedFormatIdentifier(manifestHeader.formatIdentifier)
            }

            guard manifestHeader.formatVersion == formatVersion else {
                return .unsupportedFormatVersion(manifestHeader.formatVersion)
            }

            return .compatible
        } catch {
            return .invalidManifest
        }
    }

    nonisolated static func previewAssetURL(
        in packageURL: URL,
        files: any FileSystemServicing = SystemFileService()
    ) -> URL? {
        let manifestURL = packageURL.appendingPathComponent(manifestFilename)
        let assetName = (try? loadManifest(from: manifestURL, files: files).assets.posterImage) ?? posterFilename
        let previewURL = packageURL.appendingPathComponent(assetName)
        return files.fileExists(atPath: previewURL.path) ? previewURL : nil
    }

    nonisolated static func loadPosterImage(
        from url: URL,
        files: any FileSystemServicing = SystemFileService()
    ) throws -> CGImage? {
        guard let posterURL = previewAssetURL(in: url, files: files) else {
            return nil
        }

        let posterData = try files.readData(from: posterURL)

        guard let source = CGImageSourceCreateWithData(posterData as CFData, nil),
              let posterImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SSSVideoDocumentError.invalidPosterData
        }

        return posterImage
    }

    nonisolated private static func loadManifest(
        from url: URL,
        files: any FileSystemServicing
    ) throws -> DocumentManifest {
        let data = try files.readData(from: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            return try decoder.decode(DocumentManifest.self, from: data)
        } catch {
            throw SSSVideoDocumentError.invalidManifest
        }
    }

    nonisolated private static func loadManifestHeader(
        from url: URL,
        files: any FileSystemServicing
    ) throws -> DocumentManifestHeader {
        do {
            return try JSONDecoder().decode(DocumentManifestHeader.self, from: files.readData(from: url))
        } catch {
            throw SSSVideoDocumentError.invalidManifest
        }
    }
}

nonisolated private struct DocumentManifest: Codable {
    var formatIdentifier: String
    var formatVersion: Int
    var savedAt: Date
    var assets: DocumentAssets
    var recording: RecordingRecord
    var session: SessionRecord
}

nonisolated private struct DocumentManifestHeader: Codable {
    var formatIdentifier: String
    var formatVersion: Int
}

nonisolated private struct DocumentAssets: Codable {
    var media: String
    var posterImage: String
}

nonisolated private struct RecordingRecord: Codable {
    var kind: VideoRecordingKind
    var sourceName: String
    var bounds: CodableRect
    var recordedAt: Date
    var duration: TimeInterval
    var preferences: VideoRecordingPreferences

    init(_ recording: CapturedVideoRecording) {
        kind = recording.kind
        sourceName = recording.sourceName
        bounds = CodableRect(recording.bounds)
        recordedAt = recording.recordedAt
        duration = recording.duration
        preferences = recording.preferences
    }

    func capturedVideoRecording(with mediaURL: URL) -> CapturedVideoRecording {
        CapturedVideoRecording(
            sourceURL: mediaURL,
            kind: kind,
            sourceName: sourceName,
            bounds: bounds.cgRect,
            recordedAt: recordedAt,
            duration: duration,
            preferences: preferences
        )
    }
}

nonisolated private struct SessionRecord: Codable {
    var trimStartSeconds: TimeInterval
    var trimEndSeconds: TimeInterval
    var posterTimeSeconds: TimeInterval

    init(_ session: VideoEditorSession) {
        trimStartSeconds = session.trimStartSeconds
        trimEndSeconds = session.trimEndSeconds
        posterTimeSeconds = session.posterTimeSeconds
    }

    func videoEditorSession() -> VideoEditorSession {
        VideoEditorSession(
            trimStartSeconds: trimStartSeconds,
            trimEndSeconds: trimEndSeconds,
            posterTimeSeconds: posterTimeSeconds
        )
    }
}

nonisolated private struct CodableRect: Codable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

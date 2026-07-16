import CoreGraphics
import Foundation
import ImageIO

nonisolated enum SSSGuideDocumentError: LocalizedError, Equatable {
    case invalidPackage
    case missingManifest
    case invalidManifest
    case unsupportedFormatVersion(Int)
    case unsupportedFormatIdentifier(String)
    case missingAsset(String)
    case invalidAssetPath(String)
    case invalidImage(String)
    case oversizedImage(String)
    case inconsistentStep(UUID)

    var errorDescription: String? {
        switch self {
        case .invalidPackage: "The selected .sssguide file is not a valid \(AppBranding.displayName) Guide package."
        case .missingManifest: "The selected .sssguide file is missing its document manifest."
        case .invalidManifest: "The selected .sssguide file could not be decoded."
        case .unsupportedFormatVersion(let version): "This .sssguide file uses unsupported format version \(version)."
        case .unsupportedFormatIdentifier(let identifier): "The selected file is not a \(AppBranding.displayName) Guide document (\(identifier))."
        case .missingAsset(let asset): "The Guide is missing a required asset: \(asset)."
        case .invalidAssetPath(let path): "The Guide contains an unsafe asset path: \(path)."
        case .invalidImage(let asset): "The Guide contains an unreadable image: \(asset)."
        case .oversizedImage(let asset): "The Guide contains an image that is too large to open safely: \(asset)."
        case .inconsistentStep(let id): "The Guide step \(id.uuidString) has inconsistent session data."
        }
    }
}

nonisolated struct EditableGuideDocument: @unchecked Sendable {
    var project: GuideProject
    var stepImages: [UUID: CGImage]
    var previewImage: CGImage?
    var logoImage: CGImage?
    var mediaSegmentURLs: [UUID: URL]
    var advancedEdits: [UUID: EditableScreenshotDocument] = [:]
}

nonisolated enum SSSGuideDocumentPackage {
    static let temporaryDirectoryPrefix = "SnipSnipSnipGuide-"
    static let formatIdentifier = "com.oontz.snipsnipsnip.guide-document"
    static let formatVersion = 1
    static let manifestFilename = "document.json"
    static let previewFilename = "preview.png"
    static let brandDirectory = "brand"
    static let stepsDirectory = "steps"
    static let mediaDirectory = "media"
    static let timelineFilename = "media/timeline.json"
    static let maximumImageDimension = 65_536
    static let maximumImagePixels = 268_435_456

    nonisolated static func save(
        document: EditableGuideDocument,
        to url: URL,
        files: any FileSystemServicing = SystemFileService()
    ) throws {
        let temporaryURL = files.temporaryDirectory
            .appendingPathComponent("\(temporaryDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: temporaryURL) }

        try? files.removeItem(at: temporaryURL)
        try files.createDirectory(at: temporaryURL, withIntermediateDirectories: false)
        try files.createDirectory(at: temporaryURL.appendingPathComponent(stepsDirectory), withIntermediateDirectories: false)

        var project = document.project
        project.modifiedAt = Date()
        project.normalizeStepSequence()
        var stepAssets: [StepAssets] = []

        for index in project.steps.indices {
            if let advanced = document.advancedEdits[project.steps[index].id] {
                let directoryName = project.steps[index].id.uuidString.lowercased()
                let assetsDirectory = temporaryURL
                    .appendingPathComponent(stepsDirectory, isDirectory: true)
                    .appendingPathComponent(directoryName, isDirectory: true)
                    .appendingPathComponent("assets", isDirectory: true)
                try files.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
                let path = "steps/\(directoryName)/assets/advanced.sss"
                try SSSDocumentPackage.save(
                    document: advanced,
                    previewImage: advanced.capture.image,
                    to: temporaryURL.appendingPathComponent(path),
                    includeUIMapSearchText: false,
                    files: files
                )
                project.steps[index].session.annotationSessionAsset = path
            }
            let step = project.steps[index]
            guard let image = document.stepImages[step.id] else {
                throw SSSGuideDocumentError.missingAsset("steps/\(step.id.uuidString)/base.png")
            }
            try validateDimensions(image, asset: "steps/\(step.id.uuidString)/base.png")
            let directoryName = step.id.uuidString.lowercased()
            let stepDirectory = temporaryURL
                .appendingPathComponent(stepsDirectory, isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
            if !files.directoryExists(at: stepDirectory) {
                try files.createDirectory(at: stepDirectory, withIntermediateDirectories: false)
            }
            let basePath = "steps/\(directoryName)/base.png"
            let sessionPath = "steps/\(directoryName)/session.json"
            try files.writeData(try ImageExporter.pngData(for: image), to: temporaryURL.appendingPathComponent(basePath), options: .atomic)
            try files.writeData(try encoder.encode(StepSessionRecord(id: step.id, session: step.session)), to: temporaryURL.appendingPathComponent(sessionPath), options: .atomic)
            stepAssets.append(StepAssets(id: step.id, baseImage: basePath, session: sessionPath))
        }

        if let previewImage = document.previewImage {
            try validateDimensions(previewImage, asset: previewFilename)
            try files.writeData(try ImageExporter.pngData(for: previewImage), to: temporaryURL.appendingPathComponent(previewFilename), options: .atomic)
        }

        var logoPath: String?
        if let logoImage = document.logoImage {
            let brandURL = temporaryURL.appendingPathComponent(brandDirectory, isDirectory: true)
            try files.createDirectory(at: brandURL, withIntermediateDirectories: false)
            logoPath = "brand/logo.png"
            try files.writeData(try ImageExporter.pngData(for: logoImage), to: temporaryURL.appendingPathComponent(logoPath!), options: .atomic)
        }

        var mediaAssets: [MediaAsset] = []
        if !project.timeline.segments.isEmpty {
            let segmentsDirectory = temporaryURL.appendingPathComponent("media/segments", isDirectory: true)
            try files.createDirectory(at: segmentsDirectory, withIntermediateDirectories: true)
            for segment in project.timeline.segments {
                guard let sourceURL = document.mediaSegmentURLs[segment.id], files.fileExists(atPath: sourceURL.path) else {
                    throw SSSGuideDocumentError.missingAsset(segment.asset)
                }
                let filename = "\(segment.id.uuidString.lowercased()).mp4"
                let relativePath = "media/segments/\(filename)"
                try files.copyItem(at: sourceURL, to: temporaryURL.appendingPathComponent(relativePath))
                mediaAssets.append(MediaAsset(id: segment.id, path: relativePath))
            }
            try files.writeData(try encoder.encode(project.timeline), to: temporaryURL.appendingPathComponent(timelineFilename), options: .atomic)
        }

        let manifest = Manifest(
            formatIdentifier: formatIdentifier,
            formatVersion: formatVersion,
            savedAt: Date(),
            project: project,
            assets: Assets(preview: document.previewImage == nil ? nil : previewFilename, logo: logoPath, steps: stepAssets, media: mediaAssets)
        )
        try files.writeData(try encoder.encode(manifest), to: temporaryURL.appendingPathComponent(manifestFilename), options: .atomic)

        if files.fileExists(atPath: url.path) {
            try files.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try files.moveItem(at: temporaryURL, to: url)
        }
    }

    nonisolated static func load(
        from url: URL,
        files: any FileSystemServicing = SystemFileService()
    ) throws -> EditableGuideDocument {
        guard files.directoryExists(at: url) else { throw SSSGuideDocumentError.invalidPackage }
        let manifestURL = url.appendingPathComponent(manifestFilename)
        guard files.fileExists(atPath: manifestURL.path) else { throw SSSGuideDocumentError.missingManifest }

        let header: ManifestHeader
        do { header = try decoder.decode(ManifestHeader.self, from: files.readData(from: manifestURL)) }
        catch { throw SSSGuideDocumentError.invalidManifest }
        guard header.formatIdentifier == formatIdentifier else { throw SSSGuideDocumentError.unsupportedFormatIdentifier(header.formatIdentifier) }
        guard header.formatVersion == formatVersion else { throw SSSGuideDocumentError.unsupportedFormatVersion(header.formatVersion) }

        let manifest: Manifest
        do { manifest = try decoder.decode(Manifest.self, from: files.readData(from: manifestURL)) }
        catch { throw SSSGuideDocumentError.invalidManifest }

        var images: [UUID: CGImage] = [:]
        var advancedEdits: [UUID: EditableScreenshotDocument] = [:]
        for asset in manifest.assets.steps {
            guard manifest.project.steps.contains(where: { $0.id == asset.id }) else { throw SSSGuideDocumentError.inconsistentStep(asset.id) }
            let imageURL = try validatedAssetURL(asset.baseImage, packageURL: url)
            let sessionURL = try validatedAssetURL(asset.session, packageURL: url)
            guard files.fileExists(atPath: imageURL.path) else { throw SSSGuideDocumentError.missingAsset(asset.baseImage) }
            guard files.fileExists(atPath: sessionURL.path) else { throw SSSGuideDocumentError.missingAsset(asset.session) }
            let session: StepSessionRecord
            do { session = try decoder.decode(StepSessionRecord.self, from: files.readData(from: sessionURL)) }
            catch { throw SSSGuideDocumentError.invalidManifest }
            guard session.id == asset.id,
                  manifest.project.steps.first(where: { $0.id == asset.id })?.session == session.session else {
                throw SSSGuideDocumentError.inconsistentStep(asset.id)
            }
            images[asset.id] = try loadImage(at: imageURL, asset: asset.baseImage, files: files)
            if let path = session.session.annotationSessionAsset {
                let advancedURL = try validatedAssetURL(path, packageURL: url)
                guard files.directoryExists(at: advancedURL) else { throw SSSGuideDocumentError.missingAsset(path) }
                advancedEdits[asset.id] = try SSSDocumentPackage.load(from: advancedURL, files: files)
            }
        }
        guard images.count == manifest.project.steps.count else { throw SSSGuideDocumentError.invalidManifest }

        let preview = try manifest.assets.preview.map { path -> CGImage in
            let assetURL = try validatedAssetURL(path, packageURL: url)
            guard files.fileExists(atPath: assetURL.path) else { throw SSSGuideDocumentError.missingAsset(path) }
            return try loadImage(at: assetURL, asset: path, files: files)
        }
        let logo = try manifest.assets.logo.map { path -> CGImage in
            let assetURL = try validatedAssetURL(path, packageURL: url)
            guard files.fileExists(atPath: assetURL.path) else { throw SSSGuideDocumentError.missingAsset(path) }
            return try loadImage(at: assetURL, asset: path, files: files)
        }
        var mediaURLs: [UUID: URL] = [:]
        for asset in manifest.assets.media {
            let assetURL = try validatedAssetURL(asset.path, packageURL: url)
            guard files.fileExists(atPath: assetURL.path) else { throw SSSGuideDocumentError.missingAsset(asset.path) }
            mediaURLs[asset.id] = assetURL
        }
        return EditableGuideDocument(project: manifest.project, stepImages: images, previewImage: preview, logoImage: logo, mediaSegmentURLs: mediaURLs, advancedEdits: advancedEdits)
    }

    nonisolated static func compatibilityStatus(
        at url: URL,
        files: any FileSystemServicing = SystemFileService()
    ) -> PackageCompatibilityStatus {
        let manifestURL = url.appendingPathComponent(manifestFilename)
        guard files.directoryExists(at: url), files.fileExists(atPath: manifestURL.path) else { return .invalidManifest }
        do {
            let header = try decoder.decode(ManifestHeader.self, from: files.readData(from: manifestURL))
            guard header.formatIdentifier == formatIdentifier else { return .unsupportedFormatIdentifier(header.formatIdentifier) }
            guard header.formatVersion == formatVersion else { return .unsupportedFormatVersion(header.formatVersion) }
            return .compatible
        } catch { return .invalidManifest }
    }

    nonisolated static func previewAssetURL(
        in packageURL: URL,
        files: any FileSystemServicing = SystemFileService()
    ) -> URL? {
        let manifestURL = packageURL.appendingPathComponent(manifestFilename)
        guard let data = try? files.readData(from: manifestURL),
              let manifest = try? decoder.decode(Manifest.self, from: data),
              let path = manifest.assets.preview,
              let url = try? validatedAssetURL(path, packageURL: packageURL),
              files.fileExists(atPath: url.path) else { return nil }
        return url
    }

    nonisolated private static func validatedAssetURL(_ path: String, packageURL: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { throw SSSGuideDocumentError.invalidAssetPath(path) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw SSSGuideDocumentError.invalidAssetPath(path) }
        let root = packageURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = packageURL.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { throw SSSGuideDocumentError.invalidAssetPath(path) }
        return candidate
    }

    nonisolated private static func loadImage(at url: URL, asset: String, files: any FileSystemServicing) throws -> CGImage {
        let data = try files.readData(from: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SSSGuideDocumentError.invalidImage(asset) }
        try validateDimensions(image, asset: asset)
        return image
    }

    nonisolated private static func validateDimensions(_ image: CGImage, asset: String) throws {
        guard image.width <= maximumImageDimension,
              image.height <= maximumImageDimension,
              image.width.multipliedReportingOverflow(by: image.height).overflow == false,
              image.width * image.height <= maximumImagePixels else { throw SSSGuideDocumentError.oversizedImage(asset) }
    }

    nonisolated private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    nonisolated private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            guard let date = basic.date(from: value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO-8601 date."))
            }
            return date
        }
        return decoder
    }
}

nonisolated private struct ManifestHeader: Codable {
    var formatIdentifier: String
    var formatVersion: Int
}

nonisolated private struct Manifest: Codable {
    var formatIdentifier: String
    var formatVersion: Int
    var savedAt: Date
    var project: GuideProject
    var assets: Assets
}

nonisolated private struct Assets: Codable {
    var preview: String?
    var logo: String?
    var steps: [StepAssets]
    var media: [MediaAsset]
}

nonisolated private struct StepAssets: Codable {
    var id: UUID
    var baseImage: String
    var session: String
}

nonisolated private struct MediaAsset: Codable {
    var id: UUID
    var path: String
}

nonisolated private struct StepSessionRecord: Codable {
    var id: UUID
    var session: GuideStepSession
}

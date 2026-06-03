import CoreGraphics
import Foundation
import ImageIO

nonisolated struct EditorDocumentSession: Equatable {
    var initialSnapshot: EditorSnapshot
    var currentSnapshot: EditorSnapshot
    var undoStack: [EditorSnapshot]
    var redoStack: [EditorSnapshot]
    var toolStyles: [EditorTool: AnnotationStyle]
}

nonisolated struct EditableScreenshotDocument {
    var capture: CapturedScreenshot
    var session: EditorDocumentSession
}

nonisolated enum SSSDocumentError: LocalizedError {
    case invalidPackage
    case missingManifest
    case missingBaseImage
    case invalidManifest
    case unsupportedFormatVersion(Int)
    case unsupportedFormatIdentifier(String)
    case invalidImageData
    case unknownAnnotationKind(String)

    var errorDescription: String? {
        switch self {
        case .invalidPackage:
            return "The selected .sss file is not a valid SnipSnipSnip document package."
        case .missingManifest:
            return "The selected .sss file is missing its document manifest."
        case .missingBaseImage:
            return "The selected .sss file is missing its base screenshot."
        case .invalidManifest:
            return "The selected .sss file could not be decoded."
        case .unsupportedFormatVersion(let version):
            return "This .sss file uses unsupported format version \(version)."
        case .unsupportedFormatIdentifier(let identifier):
            return "The selected file is not a SnipSnipSnip document (\(identifier))."
        case .invalidImageData:
            return "The screenshot image in this .sss file could not be decoded."
        case .unknownAnnotationKind(let kind):
            return "The document contains an unsupported annotation type: \(kind)."
        }
    }
}

nonisolated enum SSSDocumentPackage {
    nonisolated struct DisplayPreview {
        let image: CGImage
        let source: String
    }

    nonisolated enum BaseImageStorage {
        case embedded
        case shared(assetName: String, fileURL: URL)
    }

    static let temporaryDirectoryPrefix = "SnipSnipSnip-"
    static let formatIdentifier = "com.oontz.snipsnipsnip.document"
    static let formatVersion = 6

    static let manifestFilename = "document.json"
    static let baseImageFilename = "base.png"
    static let previewImageFilename = "preview.png"
    static let imageOverlayAssetsDirectoryName = "assets/image-overlays"

    nonisolated static func searchableText(
        sourceName: String,
        session: EditorDocumentSession,
        recognizedText: String? = nil
    ) -> String {
        let annotationText = annotationSearchText(for: session)
        return buildSearchableText(
            sourceName: sourceName,
            annotationText: annotationText,
            recognizedText: recognizedText
        )
    }

    nonisolated static func searchableText(
        for document: EditableScreenshotDocument,
        recognizedText: String? = nil
    ) -> String {
        searchableText(
            sourceName: document.capture.sourceName,
            session: document.session,
            recognizedText: recognizedText
        )
    }

    nonisolated static func save(
        document: EditableScreenshotDocument,
        previewImage: CGImage,
        to url: URL,
        baseImageStorage: BaseImageStorage = .embedded
    ) throws {
        let fileManager = FileManager.default
        let temporaryDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("\(temporaryDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        let previewData = try ImageExporter.pngData(for: previewImage)
        let baseImageAssetName: String
        let embeddedBaseImageData: Data?

        switch baseImageStorage {
        case .embedded:
            baseImageAssetName = baseImageFilename
            embeddedBaseImageData = try ImageExporter.pngData(for: document.capture.image)
        case let .shared(assetName, fileURL):
            baseImageAssetName = assetName
            embeddedBaseImageData = nil

            if !fileManager.fileExists(atPath: fileURL.path) {
                let baseImageData = try ImageExporter.pngData(for: document.capture.image)
                try fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try baseImageData.write(to: fileURL, options: .atomic)
            }
        }

        let manifest = DocumentManifest(
            formatIdentifier: formatIdentifier,
            formatVersion: formatVersion,
            savedAt: Date(),
            coordinateContract: document.capture.coordinateContract,
            assets: DocumentAssets(
                baseImage: baseImageAssetName,
                previewImage: previewImageFilename,
                imageOverlays: imageOverlayAssetRecords(in: document.session)
            ),
            capture: CaptureRecord(document.capture),
            session: SessionRecord(document.session),
            metadata: DocumentMetadata(
                search: DocumentSearchMetadata(
                    annotationText: annotationSearchText(for: document.session),
                    recognizedText: nil,
                    searchableText: buildSearchableText(
                        sourceName: document.capture.sourceName,
                        annotationText: annotationSearchText(for: document.session),
                        recognizedText: nil
                    )
                )
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)

        defer {
            try? fileManager.removeItem(at: temporaryDirectoryURL)
        }

        try? fileManager.removeItem(at: temporaryDirectoryURL)
        try fileManager.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: false, attributes: nil)
        try manifestData.write(to: temporaryDirectoryURL.appendingPathComponent(manifestFilename), options: .atomic)
        if let embeddedBaseImageData {
            try embeddedBaseImageData.write(to: temporaryDirectoryURL.appendingPathComponent(baseImageFilename), options: .atomic)
        }
        try writeImageOverlayAssets(from: document.session, to: temporaryDirectoryURL)
        try previewData.write(to: temporaryDirectoryURL.appendingPathComponent(previewImageFilename), options: .atomic)

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryDirectoryURL)
        } else {
            try fileManager.moveItem(at: temporaryDirectoryURL, to: url)
        }
    }

    nonisolated static func load(from url: URL) throws -> EditableScreenshotDocument {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)

        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SSSDocumentError.invalidPackage
        }

        let manifestURL = url.appendingPathComponent(manifestFilename)

        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw SSSDocumentError.missingManifest
        }

        let manifestHeader = try loadManifestHeader(from: manifestURL)

        guard manifestHeader.formatIdentifier == formatIdentifier else {
            throw SSSDocumentError.unsupportedFormatIdentifier(manifestHeader.formatIdentifier)
        }

        guard manifestHeader.formatVersion == formatVersion else {
            throw SSSDocumentError.unsupportedFormatVersion(manifestHeader.formatVersion)
        }

        let manifest = try loadManifest(from: manifestURL)

        let baseImageURL = assetURL(named: manifest.assets.baseImage, in: url)

        guard fileManager.fileExists(atPath: baseImageURL.path) else {
            throw SSSDocumentError.missingBaseImage
        }

        let baseImageData = try Data(contentsOf: baseImageURL)

        guard let imageSource = CGImageSourceCreateWithData(baseImageData as CFData, nil),
              let baseImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw SSSDocumentError.invalidImageData
        }

        let imageOverlays = try loadImageOverlayAssets(manifest.assets.imageOverlays ?? [], from: url)
        let capture = try manifest.capture.capturedScreenshot(
            with: baseImage,
            coordinateContract: manifest.coordinateContract
        )
        let session = try manifest.session.editorDocumentSession(imageOverlays: imageOverlays)
        return EditableScreenshotDocument(capture: capture, session: session)
    }

    nonisolated static func compatibilityStatus(at url: URL) -> PackageCompatibilityStatus {
        let fileManager = FileManager.default
        let manifestURL = url.appendingPathComponent(manifestFilename)
        var isDirectory = ObjCBool(false)

        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.fileExists(atPath: manifestURL.path) else {
            return .invalidManifest
        }

        do {
            let manifestHeader = try loadManifestHeader(from: manifestURL)

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

    nonisolated static func previewAssetURL(in packageURL: URL) -> URL? {
        let manifestURL = packageURL.appendingPathComponent(manifestFilename)
        let assetName = (try? loadManifest(from: manifestURL).assets.previewImage) ?? previewImageFilename
        let previewURL = assetURL(named: assetName, in: packageURL)
        return FileManager.default.fileExists(atPath: previewURL.path) ? previewURL : nil
    }

    nonisolated static func loadPreviewImage(from url: URL) throws -> CGImage? {
        guard let previewURL = previewAssetURL(in: url) else {
            return nil
        }

        return try loadImage(from: previewURL)
    }

    nonisolated static func loadDisplayPreview(from url: URL) throws -> DisplayPreview? {
        if let storedPreview = try loadStoredDisplayPreview(from: url, maxPixelDimension: nil) {
            return storedPreview
        }

        let document = try load(from: url)

        if let renderedPreview = ScreenshotPresentationRenderer.render(baseImage: document.capture.image, snapshot: document.session.currentSnapshot) {
            return DisplayPreview(image: renderedPreview, source: "rerendered-package")
        }

        if let storedPreview = try loadPreviewImage(from: url) {
            return DisplayPreview(image: storedPreview, source: "stored-preview-fallback")
        }

        return nil
    }

    nonisolated static func loadThumbnailDisplayPreview(from url: URL, maxPixelDimension: Int) throws -> DisplayPreview? {
        if let storedPreview = try loadStoredDisplayPreview(from: url, maxPixelDimension: maxPixelDimension) {
            return storedPreview
        }

        guard let displayPreview = try loadDisplayPreview(from: url) else {
            return nil
        }

        return DisplayPreview(
            image: downsample(displayPreview.image, maxPixelDimension: maxPixelDimension),
            source: displayPreview.source
        )
    }

    nonisolated static func loadSearchableText(from packageURL: URL) -> String {
        let manifestURL = packageURL.appendingPathComponent(manifestFilename)

        guard let manifest = try? loadManifest(from: manifestURL) else {
            return ""
        }

        return manifest.metadata?.search?.searchableText ?? ""
    }

    nonisolated static func updateRecognizedText(_ recognizedText: String?, in packageURL: URL) throws -> String {
        let manifestURL = packageURL.appendingPathComponent(manifestFilename)
        var manifest = try loadManifest(from: manifestURL)
        let annotationText = manifest.metadata?.search?.annotationText ?? ""
        let searchableText = buildSearchableText(
            sourceName: manifest.capture.sourceName,
            annotationText: annotationText,
            recognizedText: recognizedText
        )

        manifest.metadata = DocumentMetadata(
            search: DocumentSearchMetadata(
                annotationText: annotationText,
                recognizedText: normalizedSearchText(recognizedText),
                searchableText: searchableText
            )
        )

        try saveManifest(manifest, to: manifestURL)
        return searchableText
    }

    nonisolated private static func loadManifest(from manifestURL: URL) throws -> DocumentManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifestData = try Data(contentsOf: manifestURL)

        do {
            return try decoder.decode(DocumentManifest.self, from: manifestData)
        } catch {
            throw SSSDocumentError.invalidManifest
        }
    }

    nonisolated private static func loadManifestHeader(from manifestURL: URL) throws -> DocumentManifestHeader {
        do {
            return try JSONDecoder().decode(DocumentManifestHeader.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw SSSDocumentError.invalidManifest
        }
    }

    nonisolated private static func saveManifest(_ manifest: DocumentManifest, to manifestURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    nonisolated private static func imageOverlayAssetRecords(in session: EditorDocumentSession) -> [ImageOverlayAssetRecord] {
        let overlays = imageOverlayShapes(in: session)
        return overlays.map { shape in
            ImageOverlayAssetRecord(
                id: shape.assetID,
                filename: "\(imageOverlayAssetsDirectoryName)/\(shape.assetID.uuidString).png"
            )
        }
    }

    nonisolated private static func writeImageOverlayAssets(from session: EditorDocumentSession, to packageURL: URL) throws {
        let overlays = imageOverlayShapes(in: session)

        guard !overlays.isEmpty else {
            return
        }

        let directoryURL = packageURL.appendingPathComponent(imageOverlayAssetsDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var writtenIDs: Set<UUID> = []
        for shape in overlays where !writtenIDs.contains(shape.assetID) {
            writtenIDs.insert(shape.assetID)
            let data = try ImageExporter.pngData(for: shape.image)
            try data.write(to: directoryURL.appendingPathComponent("\(shape.assetID.uuidString).png"), options: .atomic)
        }
    }

    nonisolated private static func imageOverlayShapes(in session: EditorDocumentSession) -> [ImageOverlayShape] {
        let snapshots = [session.initialSnapshot, session.currentSnapshot] + session.undoStack + session.redoStack
        var seenIDs: Set<UUID> = []
        var overlays: [ImageOverlayShape] = []

        for snapshot in snapshots {
            for annotation in snapshot.annotations {
                guard case let .imageOverlay(shape) = annotation.kind, !seenIDs.contains(shape.assetID) else {
                    continue
                }

                seenIDs.insert(shape.assetID)
                overlays.append(shape)
            }
        }

        return overlays
    }

    nonisolated private static func loadImageOverlayAssets(_ records: [ImageOverlayAssetRecord], from packageURL: URL) throws -> [UUID: CGImage] {
        var images: [UUID: CGImage] = [:]

        for record in records {
            let url = assetURL(named: record.filename, in: packageURL)
            images[record.id] = try loadImage(from: url)
        }

        return images
    }

    nonisolated private static func assetURL(named assetName: String, in packageURL: URL) -> URL {
        let path = (packageURL.path as NSString).appendingPathComponent(assetName)
        return URL(fileURLWithPath: (path as NSString).standardizingPath)
    }

    nonisolated private static func loadStoredDisplayPreview(from url: URL, maxPixelDimension: Int?) throws -> DisplayPreview? {
        guard let previewURL = previewAssetURL(in: url) else {
            return nil
        }

        let manifest = try loadManifest(from: url.appendingPathComponent(manifestFilename))
        let expectedSize = ScreenshotPresentationRenderer.outputSize(
            for: manifest.session.currentSnapshot.cropRect.cgRect.gscIntegralStandardized.size,
            presentation: manifest.session.currentSnapshot.presentation?.screenshotPresentation ?? .plain
        )
        let properties = try imageProperties(from: previewURL)
        let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
        let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int

        guard pixelWidth == Int(expectedSize.width),
              pixelHeight == Int(expectedSize.height) else {
            return nil
        }

        return DisplayPreview(
            image: try loadImage(from: previewURL, maxPixelDimension: maxPixelDimension),
            source: "stored-preview"
        )
    }

    nonisolated private static func imageProperties(from url: URL) throws -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw SSSDocumentError.invalidImageData
        }

        return properties
    }

    nonisolated private static func loadImage(from url: URL, maxPixelDimension: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw SSSDocumentError.invalidImageData
        }

        if let maxPixelDimension {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixelDimension, 1)
            ]

            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw SSSDocumentError.invalidImageData
            }

            return image
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SSSDocumentError.invalidImageData
        }

        return image
    }

    nonisolated private static func downsample(_ image: CGImage, maxPixelDimension: Int) -> CGImage {
        let maxPixelDimension = max(maxPixelDimension, 1)
        let largestDimension = max(image.width, image.height)

        guard largestDimension > maxPixelDimension else {
            return image
        }

        let scale = CGFloat(maxPixelDimension) / CGFloat(largestDimension)
        let width = max(Int((CGFloat(image.width) * scale).rounded()), 1)
        let height = max(Int((CGFloat(image.height) * scale).rounded()), 1)

        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    nonisolated private static func annotationSearchText(for session: EditorDocumentSession) -> String {
        let textSnippets = session.currentSnapshot.annotations.compactMap { annotation -> String? in
            switch annotation.kind {
            case let .text(shape):
                return shape.text
            case let .callout(shape):
                return ["Callout \(shape.number)", shape.text]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: " ")
            default:
                return nil
            }
        }

        return normalizedSearchText(textSnippets.joined(separator: " ")) ?? ""
    }

    nonisolated private static func buildSearchableText(sourceName: String, annotationText: String, recognizedText: String?) -> String {
        let segments = [
            normalizedSearchText(sourceName),
            normalizedSearchText(annotationText),
            normalizedSearchText(recognizedText)
        ].compactMap { $0 }

        return segments.joined(separator: "\n")
    }

    nonisolated private static func normalizedSearchText(_ text: String?) -> String? {
        guard let text else {
            return nil
        }

        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return collapsed.isEmpty ? nil : collapsed
    }
}

nonisolated private struct DocumentManifest: Codable {
    var formatIdentifier: String
    var formatVersion: Int
    var savedAt: Date
    var coordinateContract: DocumentCoordinateContract
    var assets: DocumentAssets
    var capture: CaptureRecord
    var session: SessionRecord
    var metadata: DocumentMetadata?
}

nonisolated private struct DocumentManifestHeader: Codable {
    var formatIdentifier: String
    var formatVersion: Int
}

nonisolated private struct DocumentMetadata: Codable {
    var search: DocumentSearchMetadata?
}

nonisolated private struct DocumentSearchMetadata: Codable {
    var annotationText: String
    var recognizedText: String?
    var searchableText: String
}

nonisolated private struct DocumentAssets: Codable {
    var baseImage: String
    var previewImage: String
    var imageOverlays: [ImageOverlayAssetRecord]?
}

nonisolated private struct ImageOverlayAssetRecord: Codable {
    var id: UUID
    var filename: String
}

nonisolated private struct CaptureRecord: Codable {
    var kind: String
    var sourceName: String
    var sourceRect: RectRecord
    var capturedAt: Date

    nonisolated init(_ capture: CapturedScreenshot) {
        kind = capture.kind.rawValue
        sourceName = capture.sourceName
        sourceRect = RectRecord(capture.sourceRect)
        capturedAt = capture.capturedAt
    }

    nonisolated func capturedScreenshot(with image: CGImage, coordinateContract: DocumentCoordinateContract) throws -> CapturedScreenshot {
        guard let kind = CaptureKind(rawValue: kind) else {
            throw SSSDocumentError.invalidManifest
        }

        return CapturedScreenshot(
            image: image,
            kind: kind,
            sourceName: sourceName,
            sourceRect: sourceRect.cgRect,
            coordinateContract: coordinateContract,
            capturedAt: capturedAt
        )
    }
}

nonisolated private struct SessionRecord: Codable {
    var initialSnapshot: SnapshotRecord
    var currentSnapshot: SnapshotRecord
    var undoStack: [SnapshotRecord]
    var redoStack: [SnapshotRecord]
    var toolStyles: [ToolStyleRecord]

    nonisolated init(_ session: EditorDocumentSession) {
        initialSnapshot = SnapshotRecord(session.initialSnapshot)
        currentSnapshot = SnapshotRecord(session.currentSnapshot)
        undoStack = session.undoStack.map(SnapshotRecord.init)
        redoStack = session.redoStack.map(SnapshotRecord.init)
        toolStyles = EditorTool.allCases.map { tool in
            ToolStyleRecord(tool: tool.rawValue, style: StyleRecord(session.toolStyles[tool] ?? .default(for: tool)))
        }
    }

    nonisolated func editorDocumentSession(imageOverlays: [UUID: CGImage] = [:]) throws -> EditorDocumentSession {
        var decodedToolStyles: [EditorTool: AnnotationStyle] = Dictionary(uniqueKeysWithValues: EditorTool.allCases.map {
            ($0, .default(for: $0))
        })

        for record in toolStyles {
            guard let tool = EditorTool(rawValue: record.tool) else {
                continue
            }

            decodedToolStyles[tool] = record.style.annotationStyle
        }

        return EditorDocumentSession(
            initialSnapshot: try initialSnapshot.editorSnapshot(imageOverlays: imageOverlays),
            currentSnapshot: try currentSnapshot.editorSnapshot(imageOverlays: imageOverlays),
            undoStack: try undoStack.map { try $0.editorSnapshot(imageOverlays: imageOverlays) },
            redoStack: try redoStack.map { try $0.editorSnapshot(imageOverlays: imageOverlays) },
            toolStyles: decodedToolStyles
        )
    }
}

nonisolated private struct ToolStyleRecord: Codable {
    var tool: String
    var style: StyleRecord
}

nonisolated private struct SnapshotRecord: Codable {
    var cropRect: RectRecord
    var annotations: [AnnotationRecord]
    var selectedAnnotationIDs: [UUID]
    var nextCalloutNumber: Int
    var presentation: ScreenshotPresentationRecord?

    nonisolated init(_ snapshot: EditorSnapshot) {
        cropRect = RectRecord(snapshot.cropRect)
        annotations = snapshot.annotations.map(AnnotationRecord.init)
        selectedAnnotationIDs = snapshot.selectedAnnotationIDs
        nextCalloutNumber = snapshot.nextCalloutNumber
        presentation = ScreenshotPresentationRecord(snapshot.presentation)
    }

    nonisolated func editorSnapshot(imageOverlays: [UUID: CGImage] = [:]) throws -> EditorSnapshot {
        EditorSnapshot(
            cropRect: cropRect.cgRect,
            annotations: try annotations.map { try $0.annotation(imageOverlays: imageOverlays) },
            selectedAnnotationIDs: selectedAnnotationIDs,
            nextCalloutNumber: nextCalloutNumber,
            presentation: presentation?.screenshotPresentation ?? .plain
        )
    }
}

nonisolated private struct ScreenshotPresentationRecord: Codable {
    var isEnabled: Bool
    var background: ScreenshotPresentationBackgroundRecord
    var padding: Double
    var cornerRadius: Double
    var shadow: String
    var shadowBlurRadius: Double?
    var shadowOffsetX: Double?
    var shadowOffsetY: Double?
    var shadowOpacity: Double?

    nonisolated init(_ presentation: ScreenshotPresentation) {
        isEnabled = presentation.isEnabled
        background = ScreenshotPresentationBackgroundRecord(presentation.background)
        padding = Double(presentation.padding)
        cornerRadius = Double(presentation.cornerRadius)
        shadow = presentation.shadow.rawValue
        shadowBlurRadius = Double(presentation.shadowBlurRadius)
        shadowOffsetX = Double(presentation.shadowOffsetX)
        shadowOffsetY = Double(presentation.shadowOffsetY)
        shadowOpacity = Double(presentation.shadowOpacity)
    }

    var screenshotPresentation: ScreenshotPresentation {
        let shadowStyle = ScreenshotShadowStyle(rawValue: shadow) ?? .off
        return ScreenshotPresentation(
            isEnabled: isEnabled,
            background: background.screenshotPresentationBackground,
            padding: CGFloat(padding),
            cornerRadius: CGFloat(cornerRadius),
            shadow: shadowStyle,
            shadowBlurRadius: shadowBlurRadius.map { CGFloat($0) } ?? shadowStyle.blurRadius,
            shadowOffsetX: shadowOffsetX.map { CGFloat($0) } ?? shadowStyle.offsetX,
            shadowOffsetY: shadowOffsetY.map { CGFloat($0) } ?? shadowStyle.offsetY,
            shadowOpacity: shadowOpacity.map { CGFloat($0) } ?? shadowStyle.opacity
        )
    }
}

nonisolated private struct ScreenshotPresentationBackgroundRecord: Codable {
    var kind: String
    var color: ColorRecord?

    nonisolated init(_ background: ScreenshotPresentationBackground) {
        switch background {
        case .transparent:
            kind = "transparent"
            color = nil
        case let .solid(fillColor):
            kind = "solid"
            color = ColorRecord(fillColor)
        }
    }

    var screenshotPresentationBackground: ScreenshotPresentationBackground {
        switch kind {
        case "transparent":
            return .transparent
        default:
            return .solid(color?.rgbaColor ?? RGBAColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1))
        }
    }
}

nonisolated private struct AnnotationRecord: Codable {
    var id: UUID
    var groupID: UUID?
    var kind: String
    var rect: RectRecord?
    var start: PointRecord?
    var end: PointRecord?
    var points: [PointRecord]?
    var text: String?
    var number: Int?
    var textAlignment: String?
    var arrowHeadStyle: String?
    var arrowHeadShape: String?
    var arrowCurvature: Double?
    var arrowLabelBoxColor: ColorRecord?
    var arrowLabelPlacement: String?
    var arrowLabelFontSize: Double?
    var arrowLabelTextColor: String?
    var calloutStyle: String?
    var redactionMode: String?
    var assetID: UUID?
    var opacity: Double?
    var imageOverlayRole: String?
    var isEllipse: Bool?
    var rotationDegrees: Double?
    var leaderPoint: PointRecord?
    var style: StyleRecord

    nonisolated init(_ annotation: Annotation) {
        id = annotation.id
        groupID = annotation.groupID
        kind = ""
        rect = nil
        start = nil
        end = nil
        points = nil
        text = nil
        number = nil
        textAlignment = nil
        arrowHeadStyle = nil
        arrowHeadShape = nil
        arrowCurvature = nil
        arrowLabelBoxColor = nil
        arrowLabelPlacement = nil
        arrowLabelFontSize = nil
        arrowLabelTextColor = nil
        calloutStyle = nil
        redactionMode = nil
        assetID = nil
        opacity = nil
        imageOverlayRole = nil
        isEllipse = nil
        rotationDegrees = Double(annotation.rotationDegrees)
        leaderPoint = nil
        style = StyleRecord(annotation.style)

        switch annotation.kind {
        case let .rectangle(shape):
            kind = "rectangle"
            rect = RectRecord(shape.rect)
        case let .ellipse(shape):
            kind = "ellipse"
            rect = RectRecord(shape.rect)
        case let .line(shape):
            kind = "line"
            start = PointRecord(shape.start)
            end = PointRecord(shape.end)
        case let .arrow(shape):
            kind = "arrow"
            start = PointRecord(shape.start)
            end = PointRecord(shape.end)
            text = shape.label
            arrowHeadStyle = shape.headStyle.rawValue
            arrowHeadShape = shape.headShape.rawValue
            arrowCurvature = Double(shape.curvature)
            arrowLabelBoxColor = ColorRecord(shape.labelBoxColor)
            arrowLabelPlacement = shape.labelPlacement.rawValue
            arrowLabelFontSize = Double(shape.labelFontSize)
            arrowLabelTextColor = shape.labelTextColor.rawValue
        case let .freehand(shape):
            kind = "freehand"
            points = shape.points.map(PointRecord.init)
        case let .highlighter(shape):
            kind = "highlighter"
            points = shape.points.map(PointRecord.init)
        case let .highlight(shape):
            kind = "highlight"
            rect = RectRecord(shape.rect)
        case let .text(shape):
            kind = "text"
            rect = RectRecord(shape.rect)
            text = shape.text
            textAlignment = shape.alignment.rawValue
        case let .callout(shape):
            kind = "callout"
            rect = RectRecord(shape.rect)
            number = shape.number
            text = shape.text
            textAlignment = shape.alignment.rawValue
            calloutStyle = shape.style.rawValue
            leaderPoint = shape.leaderPoint.map(PointRecord.init)
        case let .measurement(shape):
            kind = "measurement"
            start = PointRecord(shape.start)
            end = PointRecord(shape.end)
        case let .spotlight(shape):
            kind = "spotlight"
            rect = RectRecord(shape.rect)
            isEllipse = shape.isEllipse
        case let .imageOverlay(shape):
            kind = "imageOverlay"
            rect = RectRecord(shape.rect)
            assetID = shape.assetID
            opacity = Double(shape.opacity)
            imageOverlayRole = shape.role.rawValue
        case let .redaction(shape):
            kind = "redaction"
            rect = RectRecord(shape.rect)
            redactionMode = shape.mode.rawValue
        }
    }

    nonisolated func annotation(imageOverlays: [UUID: CGImage] = [:]) throws -> Annotation {
        let annotationKind: AnnotationKind

        switch kind {
        case "rectangle":
            guard let rect else {
                throw SSSDocumentError.invalidManifest
            }
            annotationKind = .rectangle(RectangleShape(rect: rect.cgRect))
        case "ellipse":
            guard let rect else {
                throw SSSDocumentError.invalidManifest
            }
            annotationKind = .ellipse(EllipseShape(rect: rect.cgRect))
        case "line":
            guard let start, let end else {
                throw SSSDocumentError.invalidManifest
            }
            annotationKind = .line(LineShape(start: start.cgPoint, end: end.cgPoint))
        case "arrow":
            guard let start, let end else {
                throw SSSDocumentError.invalidManifest
            }
            annotationKind = .arrow(ArrowShape(
                start: start.cgPoint,
                end: end.cgPoint,
                curvature: CGFloat(arrowCurvature ?? 0),
                headStyle: ArrowHeadStyle(rawValue: arrowHeadStyle ?? "single") ?? .single,
                label: text ?? "",
                labelBoxColor: arrowLabelBoxColor?.rgbaColor ?? .clear,
                labelPlacement: ArrowLabelPlacement(rawValue: arrowLabelPlacement ?? ArrowLabelPlacement.parallelAbove.rawValue) ?? .parallelAbove,
                labelFontSize: CGFloat(arrowLabelFontSize ?? 14),
                labelTextColor: ArrowLabelTextColor(rawValue: arrowLabelTextColor ?? ArrowLabelTextColor.stroke.rawValue) ?? .stroke,
                headShape: ArrowHeadShape(rawValue: arrowHeadShape ?? "open") ?? .open
            ))
        case "freehand":
            annotationKind = .freehand(FreehandShape(points: (points ?? []).map(\.cgPoint)))
        case "highlighter":
            annotationKind = .highlighter(HighlighterShape(points: (points ?? []).map(\.cgPoint)))
        case "highlight":
            guard let rect else {
                throw SSSDocumentError.invalidManifest
            }
            annotationKind = .highlight(HighlightShape(rect: rect.cgRect))
        case "text":
            guard let rect, let text else {
                throw SSSDocumentError.invalidManifest
            }
            annotationKind = .text(TextShape(rect: rect.cgRect, text: text, alignment: TextAlignmentMode(rawValue: textAlignment ?? "left") ?? .left))
        case "callout":
            guard let rect, let number, let text else {
                throw SSSDocumentError.invalidManifest
            }
            annotationKind = .callout(CalloutShape(
                rect: rect.cgRect,
                number: number,
                text: text,
                alignment: TextAlignmentMode(rawValue: textAlignment ?? "left") ?? .left,
                style: CalloutVisualStyle(rawValue: calloutStyle ?? "filled") ?? .filled,
                leaderPoint: leaderPoint?.cgPoint
            ))
        case "measurement":
            guard let start, let end else {
                throw SSSDocumentError.invalidManifest
            }
            annotationKind = .measurement(MeasurementShape(start: start.cgPoint, end: end.cgPoint))
        case "spotlight":
            guard let rect else {
                throw SSSDocumentError.invalidManifest
            }
            annotationKind = .spotlight(SpotlightShape(rect: rect.cgRect, isEllipse: isEllipse ?? true))
        case "imageOverlay":
            guard let rect, let assetID, let image = imageOverlays[assetID] else {
                throw SSSDocumentError.invalidManifest
            }
            annotationKind = .imageOverlay(ImageOverlayShape(
                assetID: assetID,
                rect: rect.cgRect,
                image: image,
                opacity: CGFloat(opacity ?? 1),
                role: ImageOverlayShape.Role(rawValue: imageOverlayRole ?? "") ?? .importedImage
            ))
        case "redaction":
            guard let rect, let redactionMode, let mode = RedactionMode(rawValue: redactionMode) else {
                throw SSSDocumentError.invalidManifest
            }
            annotationKind = .redaction(RedactionShape(rect: rect.cgRect, mode: mode))
        default:
            throw SSSDocumentError.unknownAnnotationKind(kind)
        }

        return Annotation(
            id: id,
            groupID: groupID,
            kind: annotationKind,
            style: style.annotationStyle,
            rotationDegrees: CGFloat(rotationDegrees ?? 0)
        )
    }
}

nonisolated private struct StyleRecord: Codable {
    var strokeColor: ColorRecord
    var fillColor: ColorRecord
    var lineWidth: Double
    var fontSize: Double
    var effectRadius: Double
    var cornerRadius: Double?
    var dashStyle: String?
    var freehandSmoothing: Double?
    var freehandSimplification: Double?

    nonisolated init(_ style: AnnotationStyle) {
        strokeColor = ColorRecord(style.strokeColor)
        fillColor = ColorRecord(style.fillColor)
        lineWidth = Double(style.lineWidth)
        fontSize = Double(style.fontSize)
        effectRadius = Double(style.effectRadius)
        cornerRadius = Double(style.cornerRadius)
        dashStyle = style.dashStyle.rawValue
        freehandSmoothing = Double(style.freehandSmoothing)
        freehandSimplification = Double(style.freehandSimplification)
    }

    nonisolated var annotationStyle: AnnotationStyle {
        AnnotationStyle(
            strokeColor: strokeColor.rgbaColor,
            fillColor: fillColor.rgbaColor,
            lineWidth: CGFloat(lineWidth),
            fontSize: CGFloat(fontSize),
            effectRadius: CGFloat(effectRadius),
            cornerRadius: CGFloat(cornerRadius ?? 0),
            dashStyle: StrokeDashStyle(rawValue: dashStyle ?? "solid") ?? .solid,
            freehandSmoothing: CGFloat(freehandSmoothing ?? 0.65),
            freehandSimplification: CGFloat(freehandSimplification ?? 1.5)
        )
    }
}

nonisolated private struct ColorRecord: Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    nonisolated init(_ color: RGBAColor) {
        red = Double(color.red)
        green = Double(color.green)
        blue = Double(color.blue)
        alpha = Double(color.alpha)
    }

    nonisolated var rgbaColor: RGBAColor {
        RGBAColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

nonisolated private struct RectRecord: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    nonisolated init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.size.width)
        height = Double(rect.size.height)
    }

    nonisolated var cgRect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }
}

nonisolated private struct PointRecord: Codable {
    var x: Double
    var y: Double

    nonisolated init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }

    nonisolated var cgPoint: CGPoint {
        CGPoint(x: CGFloat(x), y: CGFloat(y))
    }
}

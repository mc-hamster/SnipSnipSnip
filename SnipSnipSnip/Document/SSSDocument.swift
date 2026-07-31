import CoreGraphics
import Foundation
import ImageIO

nonisolated struct EditorDocumentSession: Equatable {
    var initialSnapshot: EditorSnapshot
    var currentSnapshot: EditorSnapshot
    var undoStack: [EditorSnapshot]
    var redoStack: [EditorSnapshot]
    var toolStyles: [EditorTool: AnnotationStyle]
    var savedPresentations: [SavedPresentation] = []
    var hasTruncatedUndoHistory = false
}

nonisolated struct EditableScreenshotDocument {
    var capture: CapturedScreenshot
    var session: EditorDocumentSession
    var compositionStoredAssets: [CompositionStoredAsset] = []
    /// Navigation is persisted for resume and recovery, but deliberately lives
    /// outside `EditorSnapshot`: moving between content and Polish is not an
    /// edit, does not enter undo, and does not make the document dirty.
    var workflowResumeState: ScreenshotWorkflowResumeState = ScreenshotWorkflowResumeState()
    /// Privacy is a permanent document-level provenance bit. It is never
    /// inferred from the currently visible items because undo history can
    /// retain source pixels after an item is removed.
    var isPrivate: Bool = false
    /// The version read from disk. Newly captured documents use the current
    /// version and legacy documents retain their source version until saved.
    var sourceFormatVersion: Int = SSSDocumentPackage.formatVersion
}

nonisolated enum SSSDocumentError: LocalizedError {
    case invalidPackage
    case missingManifest
    case missingBaseImage
    case invalidManifest
    case unsupportedFormatVersion(Int)
    case unsupportedFormatIdentifier(String)
    case invalidImageData
    case invalidAssetPath(String)
    case oversizedImage(String)
    case missingCompositionAsset(UUID)
    case tooManyCompositionAssets
    case compositionAssetsTooLarge
    case compositionAssetConflict(UUID)
    case invalidComposition(String)
    case unknownAnnotationKind(String)

    var errorDescription: String? {
        switch self {
        case .invalidPackage:
            return "The selected .sss file is not a valid \(AppBranding.displayName) document package."
        case .missingManifest:
            return "The selected .sss file is missing its document manifest."
        case .missingBaseImage:
            return "The selected .sss file is missing its base screenshot."
        case .invalidManifest:
            return "The selected .sss file could not be decoded."
        case .unsupportedFormatVersion(let version):
            return "This .sss file uses unsupported format version \(version)."
        case .unsupportedFormatIdentifier(let identifier):
            return "The selected file is not a \(AppBranding.displayName) document (\(identifier))."
        case .invalidImageData:
            return "The screenshot image in this .sss file could not be decoded."
        case .invalidAssetPath(let path):
            return "The document contains an unsafe asset path: \(path)."
        case .oversizedImage(let path):
            return "The image asset is too large to open safely: \(path)."
        case .missingCompositionAsset(let id):
            return "Composition image \(id.uuidString) is missing or corrupt. Locate, replace, exclude, or remove it before saving or exporting."
        case .tooManyCompositionAssets:
            return "The document contains too many composition assets to open safely."
        case .compositionAssetsTooLarge:
            return "The document's image assets exceed the safe resource limit."
        case .compositionAssetConflict(let id):
            return "Composition image \(id.uuidString) conflicts with an immutable image already stored for this document."
        case .invalidComposition(let reason):
            return "The document contains an invalid composition: \(reason)"
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

    /// Recovery checkpoints keep immutable composition captures once per
    /// session. Normal editable packages always use `.embedded`.
    nonisolated enum CompositionAssetStorage {
        case embedded
        case sharedRecovery(directoryURL: URL)
    }

    static let temporaryDirectoryPrefix = "SnipSnipSnip-"
    static let formatIdentifier = "com.oontz.snipsnipsnip.document"
    static let legacyFormatVersion = 6
    static let formatVersion = 7
    static let supportedFormatVersions = legacyFormatVersion...formatVersion

    static let manifestFilename = "document.json"
    static let baseImageFilename = "base.png"
    static let previewImageFilename = "preview.png"
    static let imageOverlayAssetsDirectoryName = "assets/image-overlays"
    static let compositionCaptureAssetsDirectoryName = "assets/captures"
    static let maximumImageDimension = 65_536
    static let maximumImagePixels = 268_435_456
    static let maximumCompositionAssetCount = 10_000
    /// A single encoded source can still contain a normal long scrolling
    /// capture, while malformed or sparse multi-gigabyte files are rejected
    /// before loading encoded bytes into memory.
    static let maximumEncodedImageAssetBytes: UInt64 = 1 * 1_024 * 1_024 * 1_024
    /// Includes the base image, every image-overlay source, and every existing
    /// composition capture. This replaces the former captures-only 8 GiB
    /// allowance.
    static let maximumAggregateImageAssetBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
    /// Captures are decoded lazily, but an adversarial package must not be able
    /// to declare an effectively unbounded full-resolution source set.
    static let maximumAggregateDecodedImagePixels: UInt64 = 1_073_741_824
    /// The base image and overlay sources are materialized while opening.
    static let maximumEagerDecodedImagePixels: UInt64 = 402_653_184
    static let maximumStoredPreviewBytes: UInt64 = 512 * 1_024 * 1_024
    static let maximumPersistedFixedOutputDimension = 16_384
    static let maximumPersistedFixedOutputPixels: UInt64 = 134_217_728
    static let maximumComputedPresentationDimension = 131_072
    static let maximumComputedPresentationPixels: UInt64 = 536_870_912
    static let maximumPersistedSceneBytes = 4 * 1_024 * 1_024
    static let maximumManifestBytes = 64 * 1_024 * 1_024
    static let maximumSnapshotCount = 4_096
    static let maximumAggregateCompositionItemReferences = 250_000
    static let maximumAggregateCompositionAnnotations = 250_000
    static let maximumAggregateCompositionPoints = 2_000_000
    static let maximumAggregateTextBytes = 32 * 1_024 * 1_024
    static let maximumGeometryMagnitude: Double = 1_000_000
    static let recoveryCompositionAssetsDirectoryName = "capture-assets"

    nonisolated static func searchableText(
        sourceName: String,
        session: EditorDocumentSession,
        recognizedText: String? = nil,
        uiMap: UIMapSnapshot? = nil,
        includeUIMapSearchText: Bool
    ) -> String {
        let annotationText = annotationSearchText(for: session)
        return buildSearchableText(
            sourceName: sourceName,
            annotationText: annotationText,
            recognizedText: recognizedText,
            uiMapText: includeUIMapSearchText ? uiMap?.searchableText() : nil
        )
    }

    nonisolated static func searchableText(
        for document: EditableScreenshotDocument,
        recognizedText: String? = nil,
        includeUIMapSearchText: Bool
    ) -> String {
        guard !isEffectivelyPrivate(document) else {
            return ""
        }
        return searchableText(
            sourceName: document.capture.sourceName,
            session: document.session,
            recognizedText: recognizedText,
            uiMap: document.capture.uiMap,
            includeUIMapSearchText: includeUIMapSearchText
        )
    }

    nonisolated static func save(
        document: EditableScreenshotDocument,
        previewImage: CGImage,
        to url: URL,
        baseImageStorage: BaseImageStorage = .embedded,
        compositionAssetStorage: CompositionAssetStorage = .embedded,
        includeUIMapSearchText: Bool,
        files: any FileSystemServicing = SystemFileService()
    ) throws {
        var persistedDocument = document
        if persistedDocument.session.currentSnapshot.composition == nil {
            let lifted = try liftLegacySession(
                persistedDocument.session,
                capture: persistedDocument.capture,
                isPrivate: isEffectivelyPrivate(persistedDocument)
            )
            persistedDocument.session = lifted.session
            persistedDocument.compositionStoredAssets.removeAll {
                $0.descriptor.id == lifted.asset.descriptor.id
            }
            persistedDocument.compositionStoredAssets.append(lifted.asset)
        }
        let temporaryDirectoryURL = files.temporaryDirectory
            .appendingPathComponent("\(temporaryDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        let previewData = try ImageExporter.pngData(for: previewImage)
        let compositionAssetRecords = try compositionAssetRecords(
            from: persistedDocument.compositionStoredAssets,
            storage: compositionAssetStorage
        )
        let isPrivate = isEffectivelyPrivate(persistedDocument)
        let baseImageAssetName: String
        let embeddedBaseImageData: Data?

        switch baseImageStorage {
        case .embedded:
            baseImageAssetName = baseImageFilename
            embeddedBaseImageData = try ImageExporter.pngData(for: persistedDocument.capture.image)
        case let .shared(assetName, fileURL):
            baseImageAssetName = assetName
            embeddedBaseImageData = nil

            if !files.fileExists(atPath: fileURL.path) {
                let baseImageData = try ImageExporter.pngData(for: persistedDocument.capture.image)
                try files.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try files.writeData(baseImageData, to: fileURL, options: .atomic)
            }
        }

        let metadata: DocumentMetadata? = isPrivate ? nil : DocumentMetadata(
            search: DocumentSearchMetadata(
                annotationText: annotationSearchText(for: persistedDocument.session),
                recognizedText: nil,
                searchableText: buildSearchableText(
                    sourceName: persistedDocument.capture.sourceName,
                    annotationText: annotationSearchText(for: persistedDocument.session),
                    recognizedText: nil,
                    uiMapText: includeUIMapSearchText ? persistedDocument.capture.uiMap?.searchableText() : nil
                )
            )
        )
        let manifest = DocumentManifest(
            formatIdentifier: formatIdentifier,
            formatVersion: formatVersion,
            savedAt: Date(),
            coordinateContract: persistedDocument.capture.coordinateContract,
            assets: DocumentAssets(
                baseImage: baseImageAssetName,
                previewImage: previewImageFilename,
                imageOverlays: imageOverlayAssetRecords(in: persistedDocument.session),
                captures: compositionAssetRecords.isEmpty ? nil : compositionAssetRecords
            ),
            capture: CaptureRecord(persistedDocument.capture),
            session: SessionRecord(persistedDocument.session),
            workflow: WorkflowResumeRecord(
                persistedDocument.workflowResumeState.normalized(
                    for: persistedDocument.session.currentSnapshot.documentPurpose,
                    composition: persistedDocument.session.currentSnapshot.composition
                )
            ),
            metadata: metadata,
            privacy: DocumentPrivacyRecord(isPrivate: isPrivate)
        )
        try validateManifest(manifest)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)

        defer {
            try? files.removeItem(at: temporaryDirectoryURL)
        }

        try? files.removeItem(at: temporaryDirectoryURL)
        try files.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: false)
        if let embeddedBaseImageData {
            try files.writeData(embeddedBaseImageData, to: temporaryDirectoryURL.appendingPathComponent(baseImageFilename), options: .atomic)
        }
        try writeImageOverlayAssets(
            from: persistedDocument.session,
            to: temporaryDirectoryURL,
            files: files
        )
        try writeCompositionAssets(
            persistedDocument.compositionStoredAssets,
            to: temporaryDirectoryURL,
            storage: compositionAssetStorage,
            files: files
        )
        try files.writeData(previewData, to: temporaryDirectoryURL.appendingPathComponent(previewImageFilename), options: .atomic)
        // Assets are committed before the manifest. A partially written
        // temporary package is never promoted to the destination.
        try files.writeData(manifestData, to: temporaryDirectoryURL.appendingPathComponent(manifestFilename), options: .atomic)

        if files.fileExists(atPath: url.path) {
            try files.replaceItemAt(url, withItemAt: temporaryDirectoryURL)
        } else {
            try files.moveItem(at: temporaryDirectoryURL, to: url)
        }
    }

    nonisolated static func load(
        from url: URL,
        allowsExternalRecoveryBase: Bool = false,
        files: any FileSystemServicing = SystemFileService()
    ) throws -> EditableScreenshotDocument {
        guard files.directoryExists(at: url) else {
            throw SSSDocumentError.invalidPackage
        }

        let manifestURL = url.appendingPathComponent(manifestFilename)

        guard files.fileExists(atPath: manifestURL.path) else {
            throw SSSDocumentError.missingManifest
        }

        let manifestHeader = try loadManifestHeader(from: manifestURL, files: files)

        guard manifestHeader.formatIdentifier == formatIdentifier else {
            throw SSSDocumentError.unsupportedFormatIdentifier(manifestHeader.formatIdentifier)
        }

        guard supportedFormatVersions.contains(manifestHeader.formatVersion) else {
            throw SSSDocumentError.unsupportedFormatVersion(manifestHeader.formatVersion)
        }

        let manifest = try loadManifest(from: manifestURL, files: files)
        try validateManifest(manifest)
        let imagePreflight = try preflightDocumentImages(
            manifest: manifest,
            packageURL: url,
            allowsExternalRecoveryAssets: allowsExternalRecoveryBase,
            files: files
        )
        try validateSnapshotCropBounds(
            manifest.session,
            baseImageSize: imagePreflight.base.pixelSize
        )

        // No image is decoded until the entire manifest, Presentation state,
        // file-size budget, and ImageIO header plan has passed.
        let baseImage = try decodeImage(
            from: imagePreflight.base,
            files: files
        )
        let imageOverlays = try loadImageOverlayAssets(
            imagePreflight.overlays,
            files: files
        )
        var compositionStoredAssets = try loadCompositionAssets(
            manifest.assets.captures ?? [],
            preflight: imagePreflight.composition,
            files: files
        )
        let capture = try manifest.capture.capturedScreenshot(
            with: baseImage,
            coordinateContract: manifest.coordinateContract
        )
        var session = try manifest.session.editorDocumentSession(imageOverlays: imageOverlays)
        let effectivePrivacy = isEffectivelyPrivate(manifest)
        if session.currentSnapshot.composition == nil {
            let lifted = try liftLegacySession(
                session,
                capture: capture,
                isPrivate: effectivePrivacy
            )
            session = lifted.session
            compositionStoredAssets.removeAll {
                $0.descriptor.id == lifted.asset.descriptor.id
            }
            compositionStoredAssets.append(lifted.asset)
        }
        let inferredWorkflow = ScreenshotWorkflowResumeState.inferred(
            for: session.currentSnapshot.documentPurpose,
            composition: session.currentSnapshot.composition
        )
        let workflowResumeState = (
            manifest.workflow?.resumeState ?? inferredWorkflow
        ).normalized(
            for: session.currentSnapshot.documentPurpose,
            composition: session.currentSnapshot.composition
        )
        return EditableScreenshotDocument(
            capture: capture,
            session: session,
            compositionStoredAssets: compositionStoredAssets,
            workflowResumeState: workflowResumeState,
            isPrivate: effectivePrivacy,
            sourceFormatVersion: manifestHeader.formatVersion
        )
    }

    private static let legacyLiftedAssetID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000701"
    )!
    private static let legacyLiftedItemID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000702"
    )!

    nonisolated private static func liftLegacySession(
        _ session: EditorDocumentSession,
        capture: CapturedScreenshot,
        isPrivate: Bool
    ) throws -> (session: EditorDocumentSession, asset: CompositionStoredAsset) {
        let descriptor = CompositionAssetDescriptor(
            id: legacyLiftedAssetID,
            pixelWidth: capture.image.width,
            pixelHeight: capture.image.height,
            sourceName: capture.sourceName,
            capturedAt: capture.capturedAt,
            accessibilityLabel: capture.sourceName,
            captureKind: capture.kind.rawValue,
            sourceRect: capture.sourceRect,
            coordinateContract: capture.coordinateContract,
            isPrivate: isPrivate
        )
        let asset = CompositionStoredAsset(
            descriptor: descriptor,
            encodedPNG: try ImageExporter.pngData(for: capture.image),
            uiMap: capture.uiMap
        )

        func liftedSnapshot(_ snapshot: EditorSnapshot) -> EditorSnapshot {
            guard snapshot.composition == nil else {
                return snapshot
            }
            let item = CompositionItem(
                id: legacyLiftedItemID,
                assetID: legacyLiftedAssetID,
                editState: ScreenshotEditState(
                    cropRect: snapshot.cropRect,
                    annotations: snapshot.annotations,
                    selectedAnnotationIDs: snapshot.selectedAnnotationIDs,
                    nextCalloutNumber: snapshot.nextCalloutNumber,
                    pinnedUIMapElementIDs: snapshot.pinnedUIMapElementIDs
                ),
                title: capture.sourceName,
                accessibilityLabel: capture.sourceName
            )
            var lifted = snapshot
            lifted.composition = CompositionSnapshot(
                items: [item],
                selectedItemIDs: [item.id],
                isActivated: false,
                layout: CompositionLayoutConfiguration(mode: .auto),
                canvas: CompositionCanvasState(appearance: .pixelPreserving)
            )
            lifted.composition?.repairComparisonSelection()
            return lifted
        }

        return (
            EditorDocumentSession(
                initialSnapshot: liftedSnapshot(session.initialSnapshot),
                currentSnapshot: liftedSnapshot(session.currentSnapshot),
                undoStack: session.undoStack.map(liftedSnapshot),
                redoStack: session.redoStack.map(liftedSnapshot),
                toolStyles: session.toolStyles,
                savedPresentations: session.savedPresentations,
                hasTruncatedUndoHistory: session.hasTruncatedUndoHistory
            ),
            asset
        )
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

            guard supportedFormatVersions.contains(manifestHeader.formatVersion) else {
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
        let assetName = (try? loadManifest(from: manifestURL, files: files).assets.previewImage) ?? previewImageFilename
        guard let previewURL = try? validatedAssetURL(named: assetName, in: packageURL) else {
            return nil
        }
        return files.fileExists(atPath: previewURL.path) ? previewURL : nil
    }

    nonisolated static func loadPreviewImage(
        from url: URL,
        files: any FileSystemServicing = SystemFileService()
    ) throws -> CGImage? {
        try loadStoredDisplayPreview(
            from: url,
            maxPixelDimension: nil,
            files: files
        )?.image
    }

    nonisolated static func loadDisplayPreview(
        from url: URL,
        allowsExternalRecoveryBase: Bool = false,
        files: any FileSystemServicing = SystemFileService()
    ) throws -> DisplayPreview? {
        if let storedPreview = try loadStoredDisplayPreview(from: url, maxPixelDimension: nil, files: files) {
            return storedPreview
        }

        let document = try load(
            from: url,
            allowsExternalRecoveryBase: allowsExternalRecoveryBase,
            files: files
        )

        let snapshot = document.session.currentSnapshot
        let pinnedUIMapElements = snapshot.pinnedUIMapElementIDs.compactMap {
            document.capture.uiMap?.element(matching: $0)
        }
        let renderedPreview = try CompositionDocumentPreviewRenderer.render(
            CompositionDocumentPreviewInput(
                baseImage: document.capture.image,
                snapshot: snapshot,
                assetRepository: CompositionAssetRepository(
                    storedAssets: document.compositionStoredAssets
                ),
                pinnedUIMapElements: pinnedUIMapElements,
                isPrivate: document.isPrivate
            )
        )
        return DisplayPreview(image: renderedPreview, source: "rerendered-package")
    }

    nonisolated static func loadThumbnailDisplayPreview(
        from url: URL,
        maxPixelDimension: Int,
        allowsExternalRecoveryBase: Bool = false,
        files: any FileSystemServicing = SystemFileService()
    ) throws -> DisplayPreview? {
        if let storedPreview = try loadStoredDisplayPreview(from: url, maxPixelDimension: maxPixelDimension, files: files) {
            return storedPreview
        }

        guard let displayPreview = try loadDisplayPreview(
            from: url,
            allowsExternalRecoveryBase: allowsExternalRecoveryBase,
            files: files
        ) else {
            return nil
        }

        return DisplayPreview(
            image: downsample(displayPreview.image, maxPixelDimension: maxPixelDimension),
            source: displayPreview.source
        )
    }

    nonisolated static func loadSearchableText(
        from packageURL: URL,
        files: any FileSystemServicing = SystemFileService()
    ) -> String {
        let manifestURL = packageURL.appendingPathComponent(manifestFilename)

        guard let manifest = try? loadManifest(from: manifestURL, files: files) else {
            return ""
        }

        guard !isEffectivelyPrivate(manifest) else {
            return ""
        }

        return manifest.metadata?.search?.searchableText ?? ""
    }

    nonisolated static func updateRecognizedText(
        _ recognizedText: String?,
        in packageURL: URL,
        includeUIMapSearchText: Bool,
        files: any FileSystemServicing = SystemFileService()
    ) throws -> String {
        let manifestURL = packageURL.appendingPathComponent(manifestFilename)
        var manifest = try loadManifest(from: manifestURL, files: files)
        guard !isEffectivelyPrivate(manifest) else {
            // Normalize inconsistent legacy or adversarial manifests while
            // ensuring no searchable private metadata remains on disk.
            manifest.privacy = DocumentPrivacyRecord(isPrivate: true)
            manifest.metadata = nil
            try saveManifest(manifest, to: manifestURL, files: files)
            return ""
        }
        let annotationText = manifest.metadata?.search?.annotationText ?? ""
        let searchableText = buildSearchableText(
            sourceName: manifest.capture.sourceName,
            annotationText: annotationText,
            recognizedText: recognizedText,
            uiMapText: includeUIMapSearchText ? manifest.capture.uiMap?.searchableText() : nil
        )

        manifest.metadata = DocumentMetadata(
            search: DocumentSearchMetadata(
                annotationText: annotationText,
                recognizedText: normalizedSearchText(recognizedText),
                searchableText: searchableText
            )
        )

        try saveManifest(manifest, to: manifestURL, files: files)
        return searchableText
    }

    nonisolated private static func loadManifest(
        from manifestURL: URL,
        files: any FileSystemServicing
    ) throws -> DocumentManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifestSize = try files.fileSize(at: manifestURL)
        guard manifestSize <= UInt64(maximumManifestBytes) else {
            throw SSSDocumentError.invalidManifest
        }
        let manifestData = try files.readData(
            from: manifestURL,
            maximumBytes: maximumManifestBytes
        )

        do {
            return try decoder.decode(DocumentManifest.self, from: manifestData)
        } catch {
            throw SSSDocumentError.invalidManifest
        }
    }

    nonisolated private static func loadManifestHeader(
        from manifestURL: URL,
        files: any FileSystemServicing
    ) throws -> DocumentManifestHeader {
        do {
            let manifestSize = try files.fileSize(at: manifestURL)
            guard manifestSize <= UInt64(maximumManifestBytes) else {
                throw SSSDocumentError.invalidManifest
            }
            let data = try files.readData(
                from: manifestURL,
                maximumBytes: maximumManifestBytes
            )
            return try JSONDecoder().decode(DocumentManifestHeader.self, from: data)
        } catch {
            throw SSSDocumentError.invalidManifest
        }
    }

    nonisolated private static func saveManifest(
        _ manifest: DocumentManifest,
        to manifestURL: URL,
        files: any FileSystemServicing
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try files.writeData(data, to: manifestURL, options: .atomic)
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

    nonisolated private static func compositionAssetRecords(
        from storedAssets: [CompositionStoredAsset],
        storage: CompositionAssetStorage
    ) throws -> [CompositionCaptureAssetRecord] {
        guard storedAssets.count <= maximumCompositionAssetCount else {
            throw SSSDocumentError.tooManyCompositionAssets
        }

        var aggregateBytes: UInt64 = 0
        var aggregatePixels: UInt64 = 0
        var seenIDs: Set<UUID> = []
        return try storedAssets.map { stored in
            guard seenIDs.insert(stored.descriptor.id).inserted else {
                throw SSSDocumentError.invalidManifest
            }
            guard stored.availability == .available,
                  let encodedPNG = stored.encodedPNG else {
                throw SSSDocumentError.missingCompositionAsset(stored.descriptor.id)
            }
            let nextBytes = aggregateBytes.addingReportingOverflow(UInt64(encodedPNG.count))
            guard !nextBytes.overflow,
                  UInt64(encodedPNG.count) <= maximumEncodedImageAssetBytes,
                  nextBytes.partialValue <= maximumAggregateImageAssetBytes else {
                throw SSSDocumentError.compositionAssetsTooLarge
            }
            aggregateBytes = nextBytes.partialValue
            try validateCompositionAssetDescriptor(stored.descriptor)
            let pixelCount = UInt64(stored.descriptor.pixelWidth)
                * UInt64(stored.descriptor.pixelHeight)
            let nextPixels = aggregatePixels.addingReportingOverflow(pixelCount)
            guard !nextPixels.overflow,
                  nextPixels.partialValue <= maximumAggregateDecodedImagePixels else {
                throw SSSDocumentError.compositionAssetsTooLarge
            }
            aggregatePixels = nextPixels.partialValue
            try validateEncodedCompositionAsset(stored)

            let filename: String
            switch storage {
            case .embedded:
                filename = "\(compositionCaptureAssetsDirectoryName)/\(stored.descriptor.id.uuidString).png"
            case .sharedRecovery:
                filename = "../../\(recoveryCompositionAssetsDirectoryName)/\(stored.descriptor.id.uuidString).png"
            }
            return CompositionCaptureAssetRecord(
                id: stored.descriptor.id,
                filename: filename,
                descriptor: stored.descriptor,
                uiMap: stored.uiMap
            )
        }
    }

    nonisolated private static func writeCompositionAssets(
        _ storedAssets: [CompositionStoredAsset],
        to packageURL: URL,
        storage: CompositionAssetStorage,
        files: any FileSystemServicing
    ) throws {
        guard !storedAssets.isEmpty else {
            return
        }

        let directoryURL: URL
        switch storage {
        case .embedded:
            directoryURL = packageURL.appendingPathComponent(
                compositionCaptureAssetsDirectoryName,
                isDirectory: true
            )
        case .sharedRecovery(let sharedDirectoryURL):
            directoryURL = sharedDirectoryURL
        }
        try files.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        for stored in storedAssets {
            guard stored.availability == .available,
                  let encodedPNG = stored.encodedPNG else {
                throw SSSDocumentError.missingCompositionAsset(stored.descriptor.id)
            }
            let destinationURL = directoryURL.appendingPathComponent(
                "\(stored.descriptor.id.uuidString).png"
            )
            if files.fileExists(atPath: destinationURL.path) {
                let existingSize = try files.fileSize(at: destinationURL)
                guard existingSize == UInt64(encodedPNG.count),
                      existingSize <= maximumEncodedImageAssetBytes,
                      try files.readData(
                          from: destinationURL,
                          maximumBytes: encodedPNG.count
                      ) == encodedPNG else {
                    throw SSSDocumentError.compositionAssetConflict(stored.descriptor.id)
                }
            } else {
                try files.writeData(encodedPNG, to: destinationURL, options: .atomic)
            }
        }
    }

    nonisolated private static func writeImageOverlayAssets(
        from session: EditorDocumentSession,
        to packageURL: URL,
        files: any FileSystemServicing
    ) throws {
        let overlays = imageOverlayShapes(in: session)

        guard !overlays.isEmpty else {
            return
        }

        let directoryURL = packageURL.appendingPathComponent(imageOverlayAssetsDirectoryName, isDirectory: true)
        try files.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var writtenIDs: Set<UUID> = []
        for shape in overlays where !writtenIDs.contains(shape.assetID) {
            writtenIDs.insert(shape.assetID)
            let data = try ImageExporter.pngData(for: shape.image)
            try files.writeData(data, to: directoryURL.appendingPathComponent("\(shape.assetID.uuidString).png"), options: .atomic)
        }
    }

    nonisolated private static func imageOverlayShapes(in session: EditorDocumentSession) -> [ImageOverlayShape] {
        let snapshots = [session.initialSnapshot, session.currentSnapshot] + session.undoStack + session.redoStack
        var seenIDs: Set<UUID> = []
        var overlays: [ImageOverlayShape] = []

        for snapshot in snapshots {
            let compositionAnnotations = snapshot.composition.map { composition in
                composition.items.flatMap(\.editState.annotations)
                    + composition.canvas.annotations
            } ?? []
            for annotation in snapshot.annotations + compositionAnnotations {
                guard case let .imageOverlay(shape) = annotation.kind, !seenIDs.contains(shape.assetID) else {
                    continue
                }

                seenIDs.insert(shape.assetID)
                overlays.append(shape)
            }
        }

        return overlays
    }

    private struct ImageFilePreflight {
        var url: URL
        var assetName: String
        var encodedBytes: UInt64
        var pixelWidth: Int
        var pixelHeight: Int

        var pixelSize: CGSize {
            CGSize(width: pixelWidth, height: pixelHeight)
        }

        var pixelCount: UInt64 {
            UInt64(pixelWidth) * UInt64(pixelHeight)
        }
    }

    private enum CompositionImagePreflight {
        case missing
        case corrupt
        case available(ImageFilePreflight)
    }

    private struct DocumentImagePreflight {
        var base: ImageFilePreflight
        var overlays: [UUID: ImageFilePreflight]
        var composition: [UUID: CompositionImagePreflight]
    }

    private struct ImageFileCandidate {
        var url: URL
        var assetName: String
        var encodedBytes: UInt64
        var exceedsIndividualLimit: Bool
    }

    nonisolated private static func preflightDocumentImages(
        manifest: DocumentManifest,
        packageURL: URL,
        allowsExternalRecoveryAssets: Bool,
        files: any FileSystemServicing
    ) throws -> DocumentImagePreflight {
        let baseURL = try validatedAssetURL(
            named: manifest.assets.baseImage,
            in: packageURL,
            allowsLegacyRecoveryBase: allowsExternalRecoveryAssets
                && manifest.assets.baseImage == "../../\(baseImageFilename)"
        )
        guard files.fileExists(atPath: baseURL.path) else {
            throw SSSDocumentError.missingBaseImage
        }

        var aggregateEncodedBytes: UInt64 = 0
        func candidate(
            url: URL,
            assetName: String,
            missingError: SSSDocumentError
        ) throws -> ImageFileCandidate {
            guard files.fileExists(atPath: url.path) else {
                throw missingError
            }
            let byteCount: UInt64
            do {
                byteCount = try files.fileSize(at: url)
            } catch {
                throw SSSDocumentError.invalidImageData
            }
            let next = aggregateEncodedBytes.addingReportingOverflow(byteCount)
            guard !next.overflow,
                  next.partialValue <= maximumAggregateImageAssetBytes else {
                throw SSSDocumentError.compositionAssetsTooLarge
            }
            aggregateEncodedBytes = next.partialValue
            return ImageFileCandidate(
                url: url,
                assetName: assetName,
                encodedBytes: byteCount,
                exceedsIndividualLimit: byteCount == 0
                    || byteCount > maximumEncodedImageAssetBytes
            )
        }

        let baseCandidate = try candidate(
            url: baseURL,
            assetName: manifest.assets.baseImage,
            missingError: .missingBaseImage
        )
        guard !baseCandidate.exceedsIndividualLimit else {
            throw SSSDocumentError.oversizedImage(manifest.assets.baseImage)
        }

        var overlayCandidates: [UUID: ImageFileCandidate] = [:]
        for record in manifest.assets.imageOverlays ?? [] {
            let url = try validatedAssetURL(
                named: record.filename,
                in: packageURL
            )
            let overlayCandidate = try candidate(
                url: url,
                assetName: record.filename,
                missingError: .invalidImageData
            )
            guard !overlayCandidate.exceedsIndividualLimit else {
                throw SSSDocumentError.oversizedImage(record.filename)
            }
            overlayCandidates[record.id] = overlayCandidate
        }

        var captureCandidates: [UUID: ImageFileCandidate?] = [:]
        for record in manifest.assets.captures ?? [] {
            let url = try validatedCompositionAssetURL(
                for: record,
                in: packageURL,
                allowsExternalRecoveryAssets: allowsExternalRecoveryAssets
            )
            guard files.fileExists(atPath: url.path) else {
                captureCandidates[record.id] = .some(nil)
                continue
            }
            captureCandidates[record.id] = try candidate(
                url: url,
                assetName: record.filename,
                missingError: .missingCompositionAsset(record.id)
            )
        }

        // Only after every existing source has passed the encoded-byte
        // preflight do we ask ImageIO for header properties.
        let base = try preflightImageHeader(baseCandidate)
        var overlays: [UUID: ImageFilePreflight] = [:]
        for record in manifest.assets.imageOverlays ?? [] {
            guard let overlayCandidate = overlayCandidates[record.id] else {
                throw SSSDocumentError.invalidManifest
            }
            overlays[record.id] = try preflightImageHeader(overlayCandidate)
        }

        var composition: [UUID: CompositionImagePreflight] = [:]
        for record in manifest.assets.captures ?? [] {
            guard let wrappedCandidate = captureCandidates[record.id] else {
                throw SSSDocumentError.invalidManifest
            }
            guard let captureCandidate = wrappedCandidate else {
                composition[record.id] = .missing
                continue
            }
            guard !captureCandidate.exceedsIndividualLimit,
                  let image = try? preflightImageHeader(captureCandidate),
                  image.pixelWidth == record.descriptor.pixelWidth,
                  image.pixelHeight == record.descriptor.pixelHeight else {
                composition[record.id] = .corrupt
                continue
            }
            composition[record.id] = .available(image)
        }

        var eagerPixels = base.pixelCount
        for overlay in overlays.values {
            let next = eagerPixels.addingReportingOverflow(overlay.pixelCount)
            guard !next.overflow,
                  next.partialValue <= maximumEagerDecodedImagePixels else {
                throw SSSDocumentError.compositionAssetsTooLarge
            }
            eagerPixels = next.partialValue
        }
        var aggregatePixels = eagerPixels
        for state in composition.values {
            guard case .available(let image) = state else {
                continue
            }
            let next = aggregatePixels.addingReportingOverflow(image.pixelCount)
            guard !next.overflow,
                  next.partialValue <= maximumAggregateDecodedImagePixels else {
                throw SSSDocumentError.compositionAssetsTooLarge
            }
            aggregatePixels = next.partialValue
        }

        return DocumentImagePreflight(
            base: base,
            overlays: overlays,
            composition: composition
        )
    }

    nonisolated private static func preflightImageHeader(
        _ candidate: ImageFileCandidate
    ) throws -> ImageFilePreflight {
        guard let source = CGImageSourceCreateWithURL(
            candidate.url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ) as? [CFString: Any],
              let width = imagePropertyInteger(
                properties[kCGImagePropertyPixelWidth]
              ),
              let height = imagePropertyInteger(
                properties[kCGImagePropertyPixelHeight]
              ) else {
            throw SSSDocumentError.invalidImageData
        }
        let multiplication = width.multipliedReportingOverflow(by: height)
        guard width > 0,
              height > 0,
              width <= maximumImageDimension,
              height <= maximumImageDimension,
              !multiplication.overflow,
              multiplication.partialValue <= maximumImagePixels else {
            throw SSSDocumentError.oversizedImage(candidate.assetName)
        }
        return ImageFilePreflight(
            url: candidate.url,
            assetName: candidate.assetName,
            encodedBytes: candidate.encodedBytes,
            pixelWidth: width,
            pixelHeight: height
        )
    }

    nonisolated private static func preflightStandaloneImage(
        at url: URL,
        assetName: String,
        maximumEncodedBytes: UInt64,
        files: any FileSystemServicing
    ) throws -> ImageFilePreflight {
        let encodedBytes: UInt64
        do {
            encodedBytes = try files.fileSize(at: url)
        } catch {
            throw SSSDocumentError.invalidImageData
        }
        guard encodedBytes > 0,
              encodedBytes <= maximumEncodedBytes else {
            throw SSSDocumentError.oversizedImage(assetName)
        }
        return try preflightImageHeader(
            ImageFileCandidate(
                url: url,
                assetName: assetName,
                encodedBytes: encodedBytes,
                exceedsIndividualLimit: false
            )
        )
    }

    nonisolated private static func imagePropertyInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else {
            return nil
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue > 0,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue <= Double(Int.max) else {
            return nil
        }
        return Int(doubleValue)
    }

    nonisolated private static func decodeImage(
        from preflight: ImageFilePreflight,
        maxPixelDimension: Int? = nil,
        files: any FileSystemServicing = SystemFileService()
    ) throws -> CGImage {
        let maximumBytes = Int(preflight.encodedBytes)
        let encodedData: Data
        do {
            encodedData = try files.readData(
                from: preflight.url,
                maximumBytes: maximumBytes
            )
        } catch {
            throw SSSDocumentError.invalidImageData
        }
        guard encodedData.count == maximumBytes,
              maximumBytes > 0 else {
            throw SSSDocumentError.invalidImageData
        }
        guard let source = CGImageSourceCreateWithData(
            encodedData as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw SSSDocumentError.invalidImageData
        }

        let image: CGImage?
        if let maxPixelDimension {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixelDimension, 1),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            )
        } else {
            image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            )
        }
        guard let image else {
            throw SSSDocumentError.invalidImageData
        }
        if maxPixelDimension == nil {
            guard image.width == preflight.pixelWidth,
                  image.height == preflight.pixelHeight else {
                throw SSSDocumentError.invalidImageData
            }
        }
        try validateImageDimensions(image, assetName: preflight.assetName)
        return image
    }

    nonisolated private static func loadImageOverlayAssets(
        _ preflight: [UUID: ImageFilePreflight],
        files: any FileSystemServicing
    ) throws -> [UUID: CGImage] {
        var images: [UUID: CGImage] = [:]

        for (id, imagePreflight) in preflight {
            images[id] = try decodeImage(
                from: imagePreflight,
                files: files
            )
        }

        return images
    }

    nonisolated private static func loadCompositionAssets(
        _ records: [CompositionCaptureAssetRecord],
        preflight: [UUID: CompositionImagePreflight],
        files: any FileSystemServicing
    ) throws -> [CompositionStoredAsset] {
        var result: [CompositionStoredAsset] = []

        for record in records {
            guard let state = preflight[record.id] else {
                throw SSSDocumentError.invalidManifest
            }
            switch state {
            case .missing:
                result.append(
                    CompositionStoredAsset(
                        descriptor: record.descriptor,
                        encodedPNG: nil,
                        uiMap: record.uiMap,
                        availability: .missing
                    )
                )
            case .corrupt:
                result.append(
                    CompositionStoredAsset(
                        descriptor: record.descriptor,
                        encodedPNG: nil,
                        uiMap: record.uiMap,
                        availability: .corrupt
                    )
                )
            case .available(let imagePreflight):
                let maximumBytes = Int(imagePreflight.encodedBytes)
                let data: Data
                do {
                    data = try files.readData(
                        from: imagePreflight.url,
                        maximumBytes: maximumBytes
                    )
                } catch {
                    result.append(
                        CompositionStoredAsset(
                            descriptor: record.descriptor,
                            encodedPNG: nil,
                            uiMap: record.uiMap,
                            availability: .corrupt
                        )
                    )
                    continue
                }
                guard data.count == maximumBytes else {
                    result.append(
                        CompositionStoredAsset(
                            descriptor: record.descriptor,
                            encodedPNG: nil,
                            uiMap: record.uiMap,
                            availability: .corrupt
                        )
                    )
                    continue
                }
                result.append(
                    CompositionStoredAsset(
                        descriptor: record.descriptor,
                        encodedPNG: data,
                        uiMap: record.uiMap,
                        availability: .available
                    )
                )
            }
        }

        return result
    }

    nonisolated private static func validateEncodedCompositionAsset(
        _ stored: CompositionStoredAsset
    ) throws {
        guard let data = stored.encodedPNG,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == stored.descriptor.pixelWidth,
              height == stored.descriptor.pixelHeight else {
            throw SSSDocumentError.missingCompositionAsset(stored.descriptor.id)
        }
    }

    nonisolated private static func validatedCompositionAssetURL(
        for record: CompositionCaptureAssetRecord,
        in packageURL: URL,
        allowsExternalRecoveryAssets: Bool
    ) throws -> URL {
        let expectedRecoveryPath = "../../\(recoveryCompositionAssetsDirectoryName)/\(record.id.uuidString).png"
        if allowsExternalRecoveryAssets, record.filename == expectedRecoveryPath {
            let sessionRoot = packageURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let sharedRoot = sessionRoot
                .appendingPathComponent(recoveryCompositionAssetsDirectoryName, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let candidate = sharedRoot
                .appendingPathComponent("\(record.id.uuidString).png")
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard sharedRoot.path.hasPrefix(sessionRoot.path + "/"),
                  candidate.path.hasPrefix(sharedRoot.path + "/") else {
                throw SSSDocumentError.invalidAssetPath(record.filename)
            }
            return candidate
        }

        return try validatedAssetURL(named: record.filename, in: packageURL)
    }

    nonisolated private static func validatedAssetURL(
        named assetName: String,
        in packageURL: URL,
        allowsLegacyRecoveryBase: Bool = false
    ) throws -> URL {
        if allowsLegacyRecoveryBase, assetName == "../../\(baseImageFilename)" {
            let sessionRoot = packageURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let expected = sessionRoot
                .appendingPathComponent(baseImageFilename)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard expected.deletingLastPathComponent() == sessionRoot else {
                throw SSSDocumentError.invalidAssetPath(assetName)
            }
            return expected
        }

        guard !assetName.isEmpty,
              !assetName.hasPrefix("/"),
              !assetName.contains("\\") else {
            throw SSSDocumentError.invalidAssetPath(assetName)
        }

        let components = assetName.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw SSSDocumentError.invalidAssetPath(assetName)
        }

        let root = packageURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = packageURL
            .appendingPathComponent(assetName)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw SSSDocumentError.invalidAssetPath(assetName)
        }
        return candidate
    }

    nonisolated private static func loadStoredDisplayPreview(
        from url: URL,
        maxPixelDimension: Int?,
        files: any FileSystemServicing
    ) throws -> DisplayPreview? {
        let manifest = try loadManifest(from: url.appendingPathComponent(manifestFilename), files: files)
        try validateManifest(manifest)
        let previewURL = try validatedAssetURL(
            named: manifest.assets.previewImage,
            in: url
        )
        guard files.fileExists(atPath: previewURL.path) else {
            return nil
        }
        let previewPreflight = try preflightStandaloneImage(
            at: previewURL,
            assetName: manifest.assets.previewImage,
            maximumEncodedBytes: maximumStoredPreviewBytes,
            files: files
        )
        let declaredAssets = Dictionary(
            uniqueKeysWithValues: (manifest.assets.captures ?? []).map {
                ($0.id, $0.descriptor)
            }
        )
        let contentSize = try resolvedSnapshotContentSize(
            manifest.session.currentSnapshot,
            declaredAssets: declaredAssets
        )
        let presentation = manifest.session.currentSnapshot.presentation?
            .screenshotPresentation ?? .plain
        let expectedSize = ScreenshotPresentationRenderer.outputSize(
            for: contentSize,
            presentation: presentation
        )

        let isFullSizePreview =
            previewPreflight.pixelWidth == Int(expectedSize.width)
            && previewPreflight.pixelHeight == Int(expectedSize.height)
        let expectedLongestSide = max(
            expectedSize.width,
            expectedSize.height
        )
        let previewLimit = CGFloat(
            CompositionDocumentPreviewRenderer.maximumPixelDimension
        )
        let storedLongestSide = max(
            previewPreflight.pixelWidth,
            previewPreflight.pixelHeight
        )
        let isBoundedPackagePreview =
            expectedLongestSide > previewLimit
            && storedLongestSide <= Int(previewLimit)
            && storedLongestSide >= Int(previewLimit) - 2
        guard isFullSizePreview || isBoundedPackagePreview else {
            return nil
        }

        return DisplayPreview(
            image: try decodeImage(
                from: previewPreflight,
                maxPixelDimension: maxPixelDimension,
                files: files
            ),
            source: "stored-preview"
        )
    }

    nonisolated private static func validateImageDimensions(_ image: CGImage, assetName: String) throws {
        let multiplication = image.width.multipliedReportingOverflow(by: image.height)
        guard image.width > 0,
              image.height > 0,
              image.width <= maximumImageDimension,
              image.height <= maximumImageDimension,
              !multiplication.overflow,
              multiplication.partialValue <= maximumImagePixels else {
            throw SSSDocumentError.oversizedImage(assetName)
        }
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
        let composition = session.currentSnapshot.composition
        let compositionAnnotations = composition.map {
            $0.items.flatMap(\.editState.annotations) + $0.canvas.annotations
        } ?? []
        let annotationSnippets = (session.currentSnapshot.annotations + compositionAnnotations).compactMap { annotation -> String? in
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
        let compositionSnippets = composition.map { composition in
            [composition.canvas.title]
                + composition.items.flatMap { [$0.title, $0.caption ?? ""] }
        } ?? []
        let textSnippets = annotationSnippets + compositionSnippets

        return normalizedSearchText(textSnippets.joined(separator: " ")) ?? ""
    }

    nonisolated private static func buildSearchableText(sourceName: String, annotationText: String, recognizedText: String?, uiMapText: String? = nil) -> String {
        let segments = [
            normalizedSearchText(sourceName),
            normalizedSearchText(annotationText),
            normalizedSearchText(recognizedText),
            normalizedSearchText(uiMapText)
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

    nonisolated private static func validateManifest(
        _ manifest: DocumentManifest
    ) throws {
        let captureRecords = manifest.assets.captures ?? []
        guard captureRecords.count <= maximumCompositionAssetCount else {
            throw SSSDocumentError.tooManyCompositionAssets
        }

        var declaredAssets: [UUID: CompositionAssetDescriptor] = [:]
        var budget = CompositionValidationBudget()
        var overlayIDs: Set<UUID> = []
        for record in manifest.assets.imageOverlays ?? [] {
            guard overlayIDs.insert(record.id).inserted else {
                throw SSSDocumentError.invalidComposition(
                    "duplicate image overlay asset IDs"
                )
            }
        }
        try budget.addText(manifest.capture.sourceName)
        try validateRect(
            manifest.capture.sourceRect.cgRect,
            permitsEmpty: false,
            context: "primary capture source rectangle"
        )
        if let uiMap = manifest.capture.uiMap {
            try validateUIMap(uiMap, budget: &budget)
        }
        for record in captureRecords {
            guard record.id == record.descriptor.id,
                  declaredAssets.updateValue(record.descriptor, forKey: record.id) == nil else {
                throw SSSDocumentError.invalidComposition("duplicate or inconsistent capture asset IDs")
            }
            try validateCompositionAssetDescriptor(record.descriptor)
            try budget.addText(record.descriptor.sourceName)
            try budget.addText(record.descriptor.accessibilityLabel)
            if let uiMap = record.uiMap {
                try validateUIMap(uiMap, budget: &budget)
            }
        }

        let snapshots = [
            manifest.session.initialSnapshot,
            manifest.session.currentSnapshot,
        ] + manifest.session.undoStack + manifest.session.redoStack
        guard snapshots.count <= maximumSnapshotCount else {
            throw SSSDocumentError.invalidComposition("too many undo or redo snapshots")
        }

        for snapshot in snapshots {
            try validateRect(
                snapshot.cropRect.cgRect,
                permitsEmpty: false,
                context: "editor crop rectangle"
            )
            guard snapshot.nextCalloutNumber >= 1,
                  snapshot.nextCalloutNumber <= 1_000_000 else {
                throw SSSDocumentError.invalidComposition(
                    "editor callout sequence is invalid"
                )
            }
            let pinnedIDs = Set(snapshot.pinnedUIMapElementIDs ?? [])
            guard pinnedIDs.count == (snapshot.pinnedUIMapElementIDs ?? []).count else {
                throw SSSDocumentError.invalidComposition(
                    "pinned UI Map selection contains duplicate IDs"
                )
            }
            try validateAnnotations(
                snapshot.annotations,
                selectedIDs: snapshot.selectedAnnotationIDs,
                budget: &budget
            )
            if let composition = snapshot.composition {
                try validateComposition(
                    composition,
                    declaredAssets: declaredAssets,
                    budget: &budget
                )
            }
            let contentSize = try resolvedSnapshotContentSize(
                snapshot,
                declaredAssets: declaredAssets
            )
            if let presentation = snapshot.presentation {
                try validatePresentationRecord(
                    presentation,
                    contentSize: contentSize,
                    budget: &budget
                )
            }
        }

        var toolNames: Set<String> = []
        for toolStyle in manifest.session.toolStyles {
            guard toolNames.insert(toolStyle.tool).inserted else {
                throw SSSDocumentError.invalidComposition(
                    "duplicate editor tool style records"
                )
            }
            try validateStyle(toolStyle.style)
        }
        var savedPresentationIDs: Set<UUID> = []
        let currentContentSize = try resolvedSnapshotContentSize(
            manifest.session.currentSnapshot,
            declaredAssets: declaredAssets
        )
        for presentation in manifest.session.savedPresentations ?? [] {
            guard savedPresentationIDs.insert(presentation.id).inserted else {
                throw SSSDocumentError.invalidComposition(
                    "duplicate saved Presentation IDs"
                )
            }
            try budget.addText(presentation.name)
            try validatePresentation(
                presentation.presentation,
                contentSize: currentContentSize,
                budget: &budget
            )
        }
    }

    nonisolated private static func resolvedSnapshotContentSize(
        _ snapshot: SnapshotRecord,
        declaredAssets: [UUID: CompositionAssetDescriptor]
    ) throws -> CGSize {
        guard let record = snapshot.composition,
              record.isActivated else {
            return snapshot.cropRect.cgRect.size
        }

        let composition = CompositionSnapshot(
            items: record.items.map { item in
                CompositionItem(
                    id: item.id,
                    assetID: item.assetID,
                    editState: ScreenshotEditState(
                        cropRect: item.editState.cropRect?.cgRect
                    ),
                    framing: item.framing,
                    opacity: CGFloat(item.opacity),
                    weight: CGFloat(item.weight),
                    title: item.title,
                    caption: item.caption,
                    accessibilityLabel: item.accessibilityLabel,
                    freeformFrame: item.freeformFrame?.cgRect,
                    isIncluded: item.isIncluded,
                    semanticRole: item.semanticRole ?? .standard,
                    zIndex: item.zIndex ?? 0
                )
            },
            selectedItemIDs: record.selectedItemIDs,
            isActivated: true,
            layout: record.layout,
            comparison: record.comparison,
            steps: record.steps,
            canvas: CompositionCanvasState(
                title: record.canvas.title,
                appearance: record.canvas.appearance
            )
        )

        let layout: CompositionRenderLayout
        do {
            layout = try CompositionLayoutEngine.layout(
                composition: composition,
                assetDescriptors: declaredAssets
            )
        } catch {
            throw SSSDocumentError.invalidComposition(
                "composition layout geometry cannot be resolved"
            )
        }
        try validatePresentationOutputSize(
            layout.canvasSize,
            usesFixedLimit: false
        )
        return layout.canvasSize
    }

    nonisolated private static func validateSnapshotCropBounds(
        _ session: SessionRecord,
        baseImageSize: CGSize
    ) throws {
        let baseBounds = CGRect(origin: .zero, size: baseImageSize)
        let snapshots = [
            session.initialSnapshot,
            session.currentSnapshot,
        ] + session.undoStack + session.redoStack
        for snapshot in snapshots {
            guard baseBounds.contains(snapshot.cropRect.cgRect) else {
                throw SSSDocumentError.invalidComposition(
                    "editor crop rectangle is outside its source image"
                )
            }
        }
    }

    nonisolated private static func validatePresentationRecord(
        _ record: ScreenshotPresentationRecord,
        contentSize: CGSize,
        budget: inout CompositionValidationBudget
    ) throws {
        let requiredNonnegative = [
            record.padding,
            record.cornerRadius,
            record.shadowBlurRadius ?? 0,
        ]
        let signed = [
            record.shadowOffsetX ?? 0,
            record.shadowOffsetY ?? 0,
        ]
        guard requiredNonnegative.allSatisfy({
            $0.isFinite && $0 >= 0 && $0 <= maximumGeometryMagnitude
        }),
              signed.allSatisfy({
                  $0.isFinite && abs($0) <= maximumGeometryMagnitude
              }),
              (record.shadowOpacity.map {
                  $0.isFinite && (0...1).contains($0)
              } ?? true) else {
            throw SSSDocumentError.invalidComposition(
                "Presentation geometry is outside safe bounds"
            )
        }
        try validatePresentationBackgroundRecord(record.background)
        if let style = record.style {
            try validatePresentationStyle(style, budget: &budget)
        }
        if let canvas = record.canvas {
            try validatePresentationCanvas(canvas)
        }
        if let placement = record.subjectPlacement {
            try validatePresentationSubjectPlacement(placement)
        }
        if let frame = record.frame {
            try validatePresentationFrame(frame, budget: &budget)
        }

        try validatePresentation(
            record.screenshotPresentation,
            contentSize: contentSize,
            budget: &budget
        )
    }

    nonisolated private static func validatePresentation(
        _ presentation: ScreenshotPresentation,
        contentSize: CGSize,
        budget: inout CompositionValidationBudget
    ) throws {
        try validateSize(
            contentSize,
            permitsEmpty: false,
            context: "Presentation source size"
        )
        try validatePresentationStyle(
            presentation.style,
            budget: &budget
        )

        var fixedSceneSize: CGSize?
        if let scene = presentation.scene {
            fixedSceneSize = try validatePresentationScene(
                scene,
                contentSize: contentSize,
                budget: &budget
            )
        }

        let outputSize: CGSize
        if presentation.isEnabled, let fixedSceneSize {
            outputSize = fixedSceneSize
        } else {
            outputSize = ScreenshotPresentationRenderer.outputSize(
                for: contentSize,
                presentation: presentation
            )
        }
        let hasFixedCanvas: Bool
        switch presentation.canvas {
        case .custom:
            hasFixedCanvas = presentation.isEnabled
        case .original, .preset:
            hasFixedCanvas = false
        }
        try validatePresentationOutputSize(
            outputSize,
            usesFixedLimit: presentation.isEnabled
                && (fixedSceneSize != nil || hasFixedCanvas)
        )
    }

    nonisolated private static func validatePresentationStyle(
        _ style: PresentationStyle,
        budget: inout CompositionValidationBudget
    ) throws {
        let requiredNonnegative: [CGFloat] = [
            style.padding,
            style.cornerRadius,
            style.shadowBlurRadius,
        ]
        let signed: [CGFloat] = [
            style.shadowOffsetX,
            style.shadowOffsetY,
        ]
        guard requiredNonnegative.allSatisfy({
            $0.isFinite && $0 >= 0
                && Double($0) <= maximumGeometryMagnitude
        }),
              signed.allSatisfy({
                  $0.isFinite
                      && abs(Double($0)) <= maximumGeometryMagnitude
              }),
              style.shadowOpacity.isFinite,
              (0...1).contains(style.shadowOpacity) else {
            throw SSSDocumentError.invalidComposition(
                "Presentation style geometry is outside safe bounds"
            )
        }
        try validatePresentationBackground(style.background)
        try validatePresentationCanvas(style.canvas)
        try validatePresentationSubjectPlacement(style.subjectPlacement)
        try validatePresentationFrame(style.frame, budget: &budget)
    }

    nonisolated private static func validatePresentationBackground(
        _ background: ScreenshotPresentationBackground
    ) throws {
        switch background {
        case .transparent:
            break
        case .solid(let color):
            try validateColor(color, context: "Presentation background")
        case .twoColorGradient(let start, let end):
            try validateColor(start, context: "Presentation gradient")
            try validateColor(end, context: "Presentation gradient")
        case .radialSpotlight(let base, let spotlight):
            try validateColor(base, context: "Presentation spotlight")
            try validateColor(
                spotlight,
                context: "Presentation spotlight"
            )
        case .blurredScreenshot(let tint):
            try validateColor(tint, context: "Presentation blur tint")
        }
    }

    nonisolated private static func validatePresentationBackgroundRecord(
        _ background: ScreenshotPresentationBackgroundRecord
    ) throws {
        for color in [
            background.color,
            background.start,
            background.end,
            background.base,
            background.spotlight,
            background.tint,
        ].compactMap({ $0 }) {
            try validateColor(color, context: "Presentation background")
        }
    }

    nonisolated private static func validatePresentationCanvas(
        _ canvas: PresentationCanvas
    ) throws {
        guard case .custom(let width, let height) = canvas else {
            return
        }
        try validatePresentationOutputSize(
            CGSize(width: width, height: height),
            usesFixedLimit: true
        )
    }

    nonisolated private static func validatePresentationSubjectPlacement(
        _ placement: PresentationSubjectPlacement
    ) throws {
        guard placement.scale.isFinite,
              placement.scale > 0,
              Double(placement.scale) <= maximumGeometryMagnitude else {
            throw SSSDocumentError.invalidComposition(
                "Presentation subject scale is outside safe bounds"
            )
        }
        try validateVector(
            placement.offset,
            context: "Presentation subject offset"
        )
    }

    nonisolated private static func validatePresentationFrame(
        _ frame: PresentationFrame,
        budget: inout CompositionValidationBudget
    ) throws {
        switch frame {
        case .none:
            break
        case .browser(let style):
            try budget.addText(style.title)
            try budget.addText(style.address)
        case .macOSWindow(let style):
            try budget.addText(style.title)
        case .phone(let style), .tablet(let style):
            guard style.screenCornerRadius.isFinite,
                  style.screenCornerRadius >= 0,
                  Double(style.screenCornerRadius)
                    <= maximumGeometryMagnitude else {
                throw SSSDocumentError.invalidComposition(
                    "Presentation device-frame geometry is outside safe bounds"
                )
            }
            try validateColor(
                style.bezelColor,
                context: "Presentation device bezel"
            )
        }
    }

    nonisolated private static func validatePresentationScene(
        _ scene: AppliedPresentationScene,
        contentSize: CGSize,
        budget: inout CompositionValidationBudget
    ) throws -> CGSize {
        let sceneByteCount = scene.sanitizedSVGText.utf8.count
        guard sceneByteCount > 0,
              sceneByteCount <= maximumPersistedSceneBytes,
              scene.version > 0,
              scene.version <= 1_000_000 else {
            throw SSSDocumentError.invalidComposition(
                "Presentation Scene exceeds safe resource bounds"
            )
        }
        try budget.addText(scene.sceneID)
        try budget.addText(scene.name)
        try budget.addText(scene.sanitizedSVGText)
        for (key, value) in scene.textSlotValues {
            try budget.addText(key)
            try budget.addText(value)
        }

        let settings = scene.screenshotSlotSettings
        guard settings.scale.isFinite,
              settings.scale > 0,
              Double(settings.scale) <= maximumGeometryMagnitude else {
            throw SSSDocumentError.invalidComposition(
                "Presentation Scene framing scale is outside safe bounds"
            )
        }
        try validateVector(
            settings.offset,
            context: "Presentation Scene framing offset"
        )

        let source: PresentationSceneSource = scene.sceneID.hasPrefix(
            "builtin."
        ) ? .bundled : .user
        let validated: (
            metadata: PresentationSceneMetadata,
            sanitizedSVGText: String
        )
        do {
            validated = try PresentationSceneValidator.validate(
                svgText: scene.sanitizedSVGText,
                source: source
            )
        } catch {
            throw SSSDocumentError.invalidComposition(
                "Presentation Scene data is invalid"
            )
        }
        let metadata = validated.metadata
        guard metadata.id == scene.sceneID,
              metadata.version == scene.version else {
            throw SSSDocumentError.invalidComposition(
                "Presentation Scene identity is inconsistent"
            )
        }
        try validatePresentationOutputSize(
            metadata.canvas.size,
            usesFixedLimit: true
        )
        let allowedTextSlotIDs = Set(metadata.textSlots.map(\.id))
        guard Set(scene.textSlotValues.keys).isSubset(
            of: allowedTextSlotIDs
        ) else {
            throw SSSDocumentError.invalidComposition(
                "Presentation Scene text values reference unknown slots"
            )
        }
        for slot in metadata.slots {
            try budget.addText(slot.id)
            try budget.addText(slot.label)
            try budget.addText(slot.defaultValue)
            let scaleValues = [
                slot.minScale,
                slot.maxScale,
                slot.maxAutoEnlargement,
            ].compactMap({ $0 })
            guard scaleValues.allSatisfy({
                $0.isFinite && $0 > 0
                    && Double($0) <= maximumGeometryMagnitude
            }),
                  (slot.minScale == nil || slot.maxScale == nil
                      || slot.minScale! <= slot.maxScale!) else {
                throw SSSDocumentError.invalidComposition(
                    "Presentation Scene slot geometry is outside safe bounds"
                )
            }
        }

        guard let framing = PresentationSceneRenderer.framingAnalysis(
            contentSize: contentSize,
            scene: scene
        ) else {
            throw SSSDocumentError.invalidComposition(
                "Presentation Scene screenshot geometry is invalid"
            )
        }
        try validateRect(
            framing.slotRect,
            permitsEmpty: false,
            context: "Presentation Scene screenshot slot"
        )
        try validateRect(
            framing.contentRect,
            permitsEmpty: false,
            context: "Presentation Scene screenshot content"
        )
        guard framing.cropPercentage.isFinite,
              framing.cropPercentage >= 0,
              framing.enlargement.isFinite,
              framing.enlargement >= 0,
              Double(framing.enlargement)
                <= maximumGeometryMagnitude else {
            throw SSSDocumentError.invalidComposition(
                "Presentation Scene framing geometry is outside safe bounds"
            )
        }
        return metadata.canvas.size
    }

    nonisolated private static func validatePresentationOutputSize(
        _ size: CGSize,
        usesFixedLimit: Bool
    ) throws {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            throw SSSDocumentError.invalidComposition(
                "Presentation output size is invalid"
            )
        }
        let maximumDimension = usesFixedLimit
            ? maximumPersistedFixedOutputDimension
            : maximumComputedPresentationDimension
        guard size.width <= CGFloat(maximumDimension),
              size.height <= CGFloat(maximumDimension) else {
            throw SSSDocumentError.invalidComposition(
                "Presentation output dimensions exceed safe bounds"
            )
        }
        let width = UInt64(size.width.rounded(.up))
        let height = UInt64(size.height.rounded(.up))
        let pixels = width.multipliedReportingOverflow(by: height)
        let maximumPixels = usesFixedLimit
            ? maximumPersistedFixedOutputPixels
            : maximumComputedPresentationPixels
        guard !pixels.overflow,
              pixels.partialValue <= maximumPixels else {
            throw SSSDocumentError.invalidComposition(
                "Presentation output pixel count exceeds safe bounds"
            )
        }
    }

    nonisolated private static func validateCompositionAssetDescriptor(
        _ descriptor: CompositionAssetDescriptor
    ) throws {
        let pixels = descriptor.pixelWidth.multipliedReportingOverflow(
            by: descriptor.pixelHeight
        )
        guard descriptor.pixelWidth > 0,
              descriptor.pixelHeight > 0,
              descriptor.pixelWidth <= maximumImageDimension,
              descriptor.pixelHeight <= maximumImageDimension,
              !pixels.overflow,
              pixels.partialValue <= maximumImagePixels else {
            throw SSSDocumentError.oversizedImage(
                "\(descriptor.id.uuidString).png"
            )
        }
        if let sourceRect = descriptor.sourceRect {
            try validateRect(
                sourceRect,
                permitsEmpty: false,
                context: "capture source rectangle"
            )
        }
    }

    nonisolated private static func validateComposition(
        _ record: CompositionSnapshotRecord,
        declaredAssets: [UUID: CompositionAssetDescriptor],
        budget: inout CompositionValidationBudget
    ) throws {
        guard !record.items.isEmpty else {
            throw SSSDocumentError.invalidComposition("an editable composition cannot be empty")
        }
        guard record.items.count <= maximumCompositionAssetCount else {
            throw SSSDocumentError.tooManyCompositionAssets
        }
        try budget.addItems(record.items.count)

        var itemIDs: Set<UUID> = []
        var itemByID: [UUID: CompositionItemRecord] = [:]
        for item in record.items {
            guard itemIDs.insert(item.id).inserted else {
                throw SSSDocumentError.invalidComposition("duplicate composition item IDs")
            }
            guard let descriptor = declaredAssets[item.assetID] else {
                throw SSSDocumentError.invalidComposition(
                    "item \(item.id.uuidString) references undeclared asset \(item.assetID.uuidString)"
                )
            }
            try validateCompositionItem(
                item,
                assetDescriptor: descriptor,
                budget: &budget
            )
            itemByID[item.id] = item
        }

        let selectedIDs = Set(record.selectedItemIDs)
        guard selectedIDs.count == record.selectedItemIDs.count,
              selectedIDs.isSubset(of: itemIDs) else {
            throw SSSDocumentError.invalidComposition("item selection contains duplicate or unknown IDs")
        }

        try validateLayout(record.layout)
        try validateComparison(
            record.comparison,
            layoutMode: record.layout.mode,
            itemsByID: itemByID
        )
        try budget.addText(record.comparison.primaryLabel)
        try budget.addText(record.comparison.secondaryLabel)
        guard (-1_000_000...1_000_000).contains(
            record.steps.startIndex
        ) else {
            throw SSSDocumentError.invalidComposition("step numbering start is outside safe bounds")
        }
        guard (1...maximumCompositionAssetCount).contains(
            record.steps.gridColumns
        ) else {
            throw SSSDocumentError.invalidComposition(
                "step grid column count is outside safe bounds"
            )
        }
        if let itemsPerPage = record.steps.itemsPerPage,
           !(1...maximumCompositionAssetCount).contains(itemsPerPage) {
            throw SSSDocumentError.invalidComposition(
                "step page size is outside safe bounds"
            )
        }
        try validateCanvas(
            record.canvas,
            itemIDs: itemIDs,
            budget: &budget
        )
    }

    nonisolated private static func validateCompositionItem(
        _ item: CompositionItemRecord,
        assetDescriptor: CompositionAssetDescriptor,
        budget: inout CompositionValidationBudget
    ) throws {
        guard item.opacity.isFinite,
              (0...1).contains(item.opacity),
              item.weight.isFinite,
              item.weight > 0,
              item.weight <= maximumGeometryMagnitude else {
            throw SSSDocumentError.invalidComposition("item opacity or section weight is invalid")
        }
        guard item.framing.scale.isFinite,
              item.framing.scale > 0,
              Double(item.framing.scale) <= maximumGeometryMagnitude else {
            throw SSSDocumentError.invalidComposition("item framing scale is invalid")
        }
        try validateVector(
            item.framing.offset,
            context: "item framing offset"
        )
        if let frame = item.freeformFrame?.cgRect {
            try validateRect(frame, permitsEmpty: false, context: "freeform item frame")
        }
        if let zIndex = item.zIndex,
           !(-1_000_000...1_000_000).contains(zIndex) {
            throw SSSDocumentError.invalidComposition(
                "freeform z-order is outside safe bounds"
            )
        }

        try budget.addText(item.title)
        try budget.addText(item.caption)
        try budget.addText(item.accessibilityLabel)
        try validateEditState(
            item.editState,
            assetDescriptor: assetDescriptor,
            budget: &budget
        )
    }

    nonisolated private static func validateEditState(
        _ state: ScreenshotEditStateRecord,
        assetDescriptor: CompositionAssetDescriptor,
        budget: inout CompositionValidationBudget
    ) throws {
        if let cropRect = state.cropRect?.cgRect {
            try validateRect(cropRect, permitsEmpty: false, context: "item crop rectangle")
            let assetBounds = CGRect(
                x: 0,
                y: 0,
                width: assetDescriptor.pixelWidth,
                height: assetDescriptor.pixelHeight
            )
            guard assetBounds.contains(cropRect) else {
                throw SSSDocumentError.invalidComposition(
                    "item crop rectangle is outside its source image"
                )
            }
        }
        guard state.nextCalloutNumber >= 1,
              state.nextCalloutNumber <= 1_000_000 else {
            throw SSSDocumentError.invalidComposition("item callout sequence is invalid")
        }
        try validateAnnotations(
            state.annotations,
            selectedIDs: state.selectedAnnotationIDs,
            budget: &budget
        )
    }

    nonisolated private static func validateCanvas(
        _ canvas: CompositionCanvasStateRecord,
        itemIDs: Set<UUID>,
        budget: inout CompositionValidationBudget
    ) throws {
        try budget.addText(canvas.title)
        guard canvas.nextCalloutNumber >= 1,
              canvas.nextCalloutNumber <= 1_000_000 else {
            throw SSSDocumentError.invalidComposition("composition callout sequence is invalid")
        }
        try validateCanvasAppearance(canvas.appearance, budget: &budget)
        try validateAnnotations(
            canvas.annotations,
            selectedIDs: canvas.selectedAnnotationIDs,
            budget: &budget
        )
        let annotationIDs = Set(canvas.annotations.map(\.id))
        for (annotationID, anchors) in canvas.annotationAnchors ?? [:] {
            guard annotationIDs.contains(annotationID) else {
                throw SSSDocumentError.invalidComposition(
                    "annotation anchors reference an unknown composition annotation"
                )
            }
            try validateAnchor(anchors.primary, itemIDs: itemIDs)
            if let secondary = anchors.secondary {
                try validateAnchor(secondary, itemIDs: itemIDs)
            }
        }
    }

    nonisolated private static func validateLayout(
        _ layout: CompositionLayoutConfiguration
    ) throws {
        guard layout.targetAspectRatio.isFinite,
              layout.targetAspectRatio > 0,
              Double(layout.targetAspectRatio) <= maximumGeometryMagnitude else {
            throw SSSDocumentError.invalidComposition("target aspect ratio is invalid")
        }
        if let columns = layout.gridColumns,
           !(1...maximumCompositionAssetCount).contains(columns) {
            throw SSSDocumentError.invalidComposition("grid column count is outside safe bounds")
        }
        if let canvasSize = layout.freeformCanvasSize {
            try validateSize(
                canvasSize,
                permitsEmpty: false,
                context: "freeform canvas size"
            )
        }
    }

    nonisolated private static func validateComparison(
        _ comparison: CompositionComparisonSettings,
        layoutMode: CompositionLayoutMode,
        itemsByID: [UUID: CompositionItemRecord]
    ) throws {
        let primary = comparison.primaryItemID
        let secondary = comparison.secondaryItemID
        guard (primary == nil) == (secondary == nil) else {
            throw SSSDocumentError.invalidComposition("comparison selectors must be supplied as an A/B pair")
        }
        if let primary, let secondary {
            guard primary != secondary,
                  let primaryItem = itemsByID[primary],
                  let secondaryItem = itemsByID[secondary] else {
                throw SSSDocumentError.invalidComposition("comparison selectors are duplicate or unknown")
            }
            if layoutMode == .compare,
               (!primaryItem.isIncluded || !secondaryItem.isIncluded) {
                throw SSSDocumentError.invalidComposition("comparison selectors must reference included items")
            }
        } else if layoutMode == .compare {
            throw SSSDocumentError.invalidComposition("comparison layout requires explicit A/B selectors")
        }

        guard comparison.wipePosition.isFinite,
              (0...1).contains(comparison.wipePosition),
              comparison.overlayOpacity.isFinite,
              (0...1).contains(comparison.overlayOpacity),
              comparison.blinkInterval.isFinite,
              comparison.blinkInterval > 0,
              comparison.blinkInterval <= 60,
              comparison.differenceIntensity.isFinite,
              comparison.differenceIntensity >= 0,
              Double(comparison.differenceIntensity) <= maximumGeometryMagnitude,
              comparison.changeThreshold.isFinite,
              (0...1).contains(comparison.changeThreshold),
              comparison.registrationSensitivity.isFinite,
              (0...1).contains(comparison.registrationSensitivity),
              comparison.unchangedContentOpacity.isFinite,
              (0...1).contains(comparison.unchangedContentOpacity),
              comparison.blinkCrossfadeDuration.isFinite,
              comparison.blinkCrossfadeDuration >= 0,
              comparison.blinkCrossfadeDuration <= comparison.blinkInterval else {
            throw SSSDocumentError.invalidComposition("comparison settings are outside safe bounds")
        }
        try validateVector(
            comparison.manualRegistrationOffset,
            context: "manual registration offset"
        )
        try validateColor(comparison.changeHighlightColor, context: "comparison color")
    }

    nonisolated private static func validateCanvasAppearance(
        _ appearance: CompositionCanvasAppearance,
        budget: inout CompositionValidationBudget
    ) throws {
        let nonnegativeValues: [CGFloat] = [
            appearance.insets.top,
            appearance.insets.leading,
            appearance.insets.bottom,
            appearance.insets.trailing,
            appearance.itemSpacing,
            appearance.itemBorderWidth,
            appearance.itemCornerRadius,
            appearance.itemShadowBlur,
            appearance.captionFontSize,
            appearance.captionInsets.top,
            appearance.captionInsets.leading,
            appearance.captionInsets.bottom,
            appearance.captionInsets.trailing,
            appearance.titleFontSize,
            appearance.titleInsets.top,
            appearance.titleInsets.leading,
            appearance.titleInsets.bottom,
            appearance.titleInsets.trailing,
            appearance.stepBadgeDiameter,
            appearance.connectorWidth,
            appearance.comparisonDividerWidth,
        ]
        guard nonnegativeValues.allSatisfy({
            $0.isFinite && $0 >= 0 && Double($0) <= maximumGeometryMagnitude
        }) else {
            throw SSSDocumentError.invalidComposition("canvas appearance geometry is outside safe bounds")
        }
        try validateVector(
            appearance.itemShadowOffset,
            context: "item shadow offset"
        )
        try budget.addText(appearance.captionFontName)
        try budget.addText(appearance.titleFontName)

        switch appearance.fill {
        case .transparent:
            break
        case .color(let color):
            try validateColor(color, context: "canvas fill")
        }
        for (color, context) in [
            (appearance.itemFill, "item fill"),
            (appearance.itemBorderColor, "item border"),
            (appearance.itemShadowColor, "item shadow"),
            (appearance.captionColor, "caption"),
            (appearance.captionBackgroundColor, "caption background"),
            (appearance.titleColor, "title"),
            (appearance.titleBackgroundColor, "title background"),
            (appearance.stepBadgeFill, "step badge"),
            (appearance.stepBadgeForeground, "step badge foreground"),
            (appearance.connectorColor, "connector"),
            (appearance.comparisonDividerColor, "comparison divider"),
        ] {
            try validateColor(color, context: context)
        }
    }

    nonisolated private static func validateAnchor(
        _ anchor: CompositionAnnotationAnchor,
        itemIDs: Set<UUID>
    ) throws {
        try validatePoint(
            anchor.lastCanvasPoint,
            context: "annotation anchor canvas point"
        )
        switch anchor.target {
        case .canvasNormalized(let point):
            try validateNormalizedPoint(
                point,
                context: "canvas-normalized annotation anchor"
            )
        case .itemNormalized(let itemID, let point):
            guard itemIDs.contains(itemID) else {
                throw SSSDocumentError.invalidComposition(
                    "annotation anchor references an unknown composition item"
                )
            }
            try validateNormalizedPoint(
                point,
                context: "item-normalized annotation anchor"
            )
        case .detachedCanvas(let point):
            try validatePoint(
                point,
                context: "detached annotation anchor"
            )
        }
    }

    nonisolated private static func validateNormalizedPoint(
        _ point: CGPoint,
        context: String
    ) throws {
        guard point.x.isFinite,
              point.y.isFinite,
              (0...1).contains(point.x),
              (0...1).contains(point.y) else {
            throw SSSDocumentError.invalidComposition(
                "\(context) is outside the unit coordinate space"
            )
        }
    }

    nonisolated private static func validateAnnotations(
        _ annotations: [AnnotationRecord],
        selectedIDs: [UUID],
        budget: inout CompositionValidationBudget
    ) throws {
        try budget.addAnnotations(annotations.count)
        var annotationIDs: Set<UUID> = []
        for annotation in annotations {
            guard annotationIDs.insert(annotation.id).inserted else {
                throw SSSDocumentError.invalidComposition("duplicate annotation IDs")
            }
            try validateAnnotation(annotation, budget: &budget)
        }
        let selection = Set(selectedIDs)
        guard selection.count == selectedIDs.count,
              selection.isSubset(of: annotationIDs) else {
            throw SSSDocumentError.invalidComposition("annotation selection contains duplicate or unknown IDs")
        }
    }

    nonisolated private static func validateAnnotation(
        _ annotation: AnnotationRecord,
        budget: inout CompositionValidationBudget
    ) throws {
        if let rect = annotation.rect?.cgRect {
            try validateRect(rect, permitsEmpty: true, context: "annotation rectangle")
        }
        for point in [annotation.start, annotation.end, annotation.leaderPoint].compactMap({ $0 }) {
            try validatePoint(point.cgPoint, context: "annotation point")
        }
        let points = annotation.points ?? []
        try budget.addPoints(points.count)
        for point in points {
            try validatePoint(point.cgPoint, context: "annotation path point")
        }
        try budget.addText(annotation.text)

        let numericValues = [
            annotation.arrowCurvature,
            annotation.arrowLabelFontSize,
            annotation.opacity,
            annotation.rotationDegrees,
        ].compactMap { $0 }
        guard numericValues.allSatisfy({
            $0.isFinite && abs($0) <= maximumGeometryMagnitude
        }) else {
            throw SSSDocumentError.invalidComposition("annotation settings are outside safe bounds")
        }
        try validateStyle(annotation.style)
        if let color = annotation.arrowLabelBoxColor {
            try validateColor(color, context: "annotation label")
        }
    }

    nonisolated private static func validateStyle(_ style: StyleRecord) throws {
        let values = [
            style.lineWidth,
            style.fontSize,
            style.effectRadius,
            style.cornerRadius ?? 0,
            style.freehandSmoothing ?? 0,
            style.freehandSimplification ?? 0,
        ]
        guard values.allSatisfy({
            $0.isFinite && $0 >= 0 && $0 <= maximumGeometryMagnitude
        }) else {
            throw SSSDocumentError.invalidComposition("annotation style is outside safe bounds")
        }
        try validateColor(style.strokeColor, context: "annotation stroke")
        try validateColor(style.fillColor, context: "annotation fill")
    }

    nonisolated private static func validateColor(
        _ color: RGBAColor,
        context: String
    ) throws {
        let components = [color.red, color.green, color.blue, color.alpha]
        guard components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw SSSDocumentError.invalidComposition("\(context) color is invalid")
        }
    }

    nonisolated private static func validateColor(
        _ color: ColorRecord,
        context: String
    ) throws {
        let components = [color.red, color.green, color.blue, color.alpha]
        guard components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw SSSDocumentError.invalidComposition("\(context) color is invalid")
        }
    }

    nonisolated private static func validateRect(
        _ rect: CGRect,
        permitsEmpty: Bool,
        context: String
    ) throws {
        try validatePoint(rect.origin, context: context)
        try validateSize(rect.size, permitsEmpty: permitsEmpty, context: context)
        guard abs(Double(rect.maxX)) <= maximumGeometryMagnitude,
              abs(Double(rect.maxY)) <= maximumGeometryMagnitude else {
            throw SSSDocumentError.invalidComposition("\(context) is outside safe bounds")
        }
    }

    nonisolated private static func validatePoint(
        _ point: CGPoint,
        context: String
    ) throws {
        guard point.x.isFinite,
              point.y.isFinite,
              abs(Double(point.x)) <= maximumGeometryMagnitude,
              abs(Double(point.y)) <= maximumGeometryMagnitude else {
            throw SSSDocumentError.invalidComposition("\(context) is outside safe bounds")
        }
    }

    nonisolated private static func validateSize(
        _ size: CGSize,
        permitsEmpty: Bool,
        context: String
    ) throws {
        let minimum: CGFloat = permitsEmpty ? 0 : .leastNonzeroMagnitude
        guard size.width.isFinite,
              size.height.isFinite,
              size.width >= minimum,
              size.height >= minimum,
              Double(size.width) <= maximumGeometryMagnitude,
              Double(size.height) <= maximumGeometryMagnitude else {
            throw SSSDocumentError.invalidComposition("\(context) is outside safe bounds")
        }
    }

    nonisolated private static func validateVector(
        _ vector: CGSize,
        context: String
    ) throws {
        guard vector.width.isFinite,
              vector.height.isFinite,
              abs(Double(vector.width)) <= maximumGeometryMagnitude,
              abs(Double(vector.height)) <= maximumGeometryMagnitude else {
            throw SSSDocumentError.invalidComposition("\(context) is outside safe bounds")
        }
    }

    nonisolated private static func validateUIMap(
        _ uiMap: UIMapSnapshot,
        budget: inout CompositionValidationBudget
    ) throws {
        try validateRect(uiMap.sourceRect, permitsEmpty: false, context: "UI Map source rectangle")
        var stack = uiMap.elements
        var seenIDs: Set<UUID> = []
        while let element = stack.popLast() {
            try budget.addUIMapElements(1)
            guard seenIDs.insert(element.id).inserted else {
                throw SSSDocumentError.invalidComposition("UI Map contains duplicate element IDs")
            }
            try validateRect(
                element.documentRect,
                permitsEmpty: true,
                context: "UI Map element rectangle"
            )
            for text in [
                element.name,
                element.accessibilityLabel,
                element.accessibilityIdentifier,
                element.role,
                element.roleDescription,
                element.valueDescription,
                element.owningApplication,
                element.bundleIdentifier,
                element.overlayParentHierarchy,
            ] {
                try budget.addText(text)
            }
            stack.append(contentsOf: element.children)
        }
    }

    /// Document privacy is monotonic provenance. A private source remains
    /// authoritative even if an older or malformed caller forgot to set the
    /// document-level bit.
    nonisolated private static func isEffectivelyPrivate(
        _ document: EditableScreenshotDocument
    ) -> Bool {
        document.isPrivate
            || document.compositionStoredAssets.contains { $0.descriptor.isPrivate }
    }

    nonisolated private static func isEffectivelyPrivate(
        _ manifest: DocumentManifest
    ) -> Bool {
        manifest.privacy?.isPrivate == true
            || (manifest.assets.captures?.contains { $0.descriptor.isPrivate } == true)
    }
}

nonisolated private struct CompositionValidationBudget {
    private(set) var itemReferences = 0
    private(set) var annotations = 0
    private(set) var points = 0
    private(set) var textBytes = 0
    private(set) var uiMapElements = 0

    mutating func addItems(_ count: Int) throws {
        itemReferences = try adding(
            count,
            to: itemReferences,
            limit: SSSDocumentPackage.maximumAggregateCompositionItemReferences,
            reason: "too many composition item references"
        )
    }

    mutating func addAnnotations(_ count: Int) throws {
        annotations = try adding(
            count,
            to: annotations,
            limit: SSSDocumentPackage.maximumAggregateCompositionAnnotations,
            reason: "too many composition annotations"
        )
    }

    mutating func addPoints(_ count: Int) throws {
        points = try adding(
            count,
            to: points,
            limit: SSSDocumentPackage.maximumAggregateCompositionPoints,
            reason: "too many annotation path points"
        )
    }

    mutating func addText(_ text: String?) throws {
        guard let text else {
            return
        }
        textBytes = try adding(
            text.utf8.count,
            to: textBytes,
            limit: SSSDocumentPackage.maximumAggregateTextBytes,
            reason: "composition text exceeds the safe resource limit"
        )
    }

    mutating func addUIMapElements(_ count: Int) throws {
        uiMapElements = try adding(
            count,
            to: uiMapElements,
            limit: SSSDocumentPackage.maximumAggregateCompositionItemReferences,
            reason: "too many UI Map elements"
        )
    }

    private func adding(
        _ count: Int,
        to current: Int,
        limit: Int,
        reason: String
    ) throws -> Int {
        guard count >= 0 else {
            throw SSSDocumentError.invalidComposition(reason)
        }
        let result = current.addingReportingOverflow(count)
        guard !result.overflow, result.partialValue <= limit else {
            throw SSSDocumentError.invalidComposition(reason)
        }
        return result.partialValue
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
    var workflow: WorkflowResumeRecord?
    var metadata: DocumentMetadata?
    var privacy: DocumentPrivacyRecord?
}

nonisolated private struct DocumentManifestHeader: Codable {
    var formatIdentifier: String
    var formatVersion: Int
}

nonisolated private struct DocumentMetadata: Codable {
    var search: DocumentSearchMetadata?
}

nonisolated private struct DocumentPrivacyRecord: Codable {
    var isPrivate: Bool
}

/// String-backed compatibility record so future workflow values fall back to
/// deterministic inference instead of making an otherwise valid v7 package
/// impossible to open.
nonisolated private struct WorkflowResumeRecord: Codable {
    var stage: String?
    var returnStage: String?

    init(_ state: ScreenshotWorkflowResumeState) {
        stage = state.stage.rawValue
        returnStage = state.returnStage?.rawValue
    }

    var resumeState: ScreenshotWorkflowResumeState? {
        guard let stage,
              let decodedStage = ScreenshotWorkflowStage(rawValue: stage) else {
            return nil
        }
        return ScreenshotWorkflowResumeState(
            stage: decodedStage,
            returnStage: returnStage.flatMap(ScreenshotWorkflowStage.init(rawValue:))
        )
    }
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
    var captures: [CompositionCaptureAssetRecord]?
}

nonisolated private struct ImageOverlayAssetRecord: Codable {
    var id: UUID
    var filename: String
}

nonisolated private struct CompositionCaptureAssetRecord: Codable {
    var id: UUID
    var filename: String
    var descriptor: CompositionAssetDescriptor
    var uiMap: UIMapSnapshot?
}

nonisolated private struct CaptureRecord: Codable {
    var kind: String
    var sourceName: String
    var sourceRect: RectRecord
    var capturedAt: Date
    var uiMap: UIMapSnapshot?

    nonisolated init(_ capture: CapturedScreenshot) {
        kind = capture.kind.rawValue
        sourceName = capture.sourceName
        sourceRect = RectRecord(capture.sourceRect)
        capturedAt = capture.capturedAt
        uiMap = capture.uiMap
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
            capturedAt: capturedAt,
            uiMap: uiMap
        )
    }
}

nonisolated private struct SessionRecord: Codable {
    var initialSnapshot: SnapshotRecord
    var currentSnapshot: SnapshotRecord
    var undoStack: [SnapshotRecord]
    var redoStack: [SnapshotRecord]
    var toolStyles: [ToolStyleRecord]
    var savedPresentations: [SavedPresentation]?
    var hasTruncatedUndoHistory: Bool?

    nonisolated init(_ session: EditorDocumentSession) {
        initialSnapshot = SnapshotRecord(session.initialSnapshot)
        currentSnapshot = SnapshotRecord(session.currentSnapshot)
        undoStack = session.undoStack.map(SnapshotRecord.init)
        redoStack = session.redoStack.map(SnapshotRecord.init)
        toolStyles = EditorTool.allCases.map { tool in
            ToolStyleRecord(tool: tool.rawValue, style: StyleRecord(session.toolStyles[tool] ?? .default(for: tool)))
        }
        savedPresentations = session.savedPresentations.isEmpty ? nil : session.savedPresentations
        hasTruncatedUndoHistory = session.hasTruncatedUndoHistory ? true : nil
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
            toolStyles: decodedToolStyles,
            savedPresentations: savedPresentations ?? [],
            hasTruncatedUndoHistory: hasTruncatedUndoHistory ?? false
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
    var pinnedUIMapElementIDs: [UUID]?
    var documentPurpose: String?
    var composition: CompositionSnapshotRecord?

    nonisolated init(_ snapshot: EditorSnapshot) {
        cropRect = RectRecord(snapshot.cropRect)
        annotations = snapshot.annotations.map(AnnotationRecord.init)
        selectedAnnotationIDs = snapshot.selectedAnnotationIDs
        nextCalloutNumber = snapshot.nextCalloutNumber
        presentation = ScreenshotPresentationRecord(snapshot.presentation)
        pinnedUIMapElementIDs = snapshot.pinnedUIMapElementIDs.isEmpty ? nil : snapshot.pinnedUIMapElementIDs
        documentPurpose = snapshot.documentPurpose.rawValue
        composition = snapshot.composition.map(CompositionSnapshotRecord.init)
    }

    nonisolated func editorSnapshot(imageOverlays: [UUID: CGImage] = [:]) throws -> EditorSnapshot {
        let decodedComposition = try composition?.compositionSnapshot(
            imageOverlays: imageOverlays
        )
        let resolvedPurpose = documentPurpose.flatMap(
            ScreenshotDocumentPurpose.init(rawValue:)
        ) ?? ScreenshotDocumentPurpose.inferred(from: decodedComposition)
        return EditorSnapshot(
            cropRect: cropRect.cgRect,
            annotations: try annotations.map { try $0.annotation(imageOverlays: imageOverlays) },
            selectedAnnotationIDs: selectedAnnotationIDs,
            nextCalloutNumber: nextCalloutNumber,
            presentation: presentation?.screenshotPresentation ?? .plain,
            pinnedUIMapElementIDs: pinnedUIMapElementIDs ?? [],
            documentPurpose: resolvedPurpose,
            composition: decodedComposition
        )
    }
}

nonisolated private struct CompositionSnapshotRecord: Codable {
    var items: [CompositionItemRecord]
    var selectedItemIDs: [UUID]
    var isActivated: Bool
    var layout: CompositionLayoutConfiguration
    var comparison: CompositionComparisonSettings
    var steps: CompositionStepsSettings
    var canvas: CompositionCanvasStateRecord

    private enum CodingKeys: String, CodingKey {
        case items
        case selectedItemIDs
        case isActivated
        case layout
        case comparison
        case steps
        case canvas
    }

    init(_ composition: CompositionSnapshot) {
        items = composition.items.map(CompositionItemRecord.init)
        selectedItemIDs = composition.selectedItemIDs
        isActivated = composition.isActivated
        layout = composition.layout
        comparison = composition.comparison
        steps = composition.steps
        canvas = CompositionCanvasStateRecord(composition.canvas)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([CompositionItemRecord].self, forKey: .items)
        selectedItemIDs = try container.decode(
            [UUID].self,
            forKey: .selectedItemIDs
        )
        isActivated = try container.decodeIfPresent(
            Bool.self,
            forKey: .isActivated
        ) ?? true
        layout = try container.decode(
            CompatibleCompositionLayoutConfiguration.self,
            forKey: .layout
        ).current
        comparison = try container.decode(
            CompatibleCompositionComparisonSettings.self,
            forKey: .comparison
        ).current
        steps = try container.decode(
            CompatibleCompositionStepsSettings.self,
            forKey: .steps
        ).current
        canvas = try container.decode(
            CompositionCanvasStateRecord.self,
            forKey: .canvas
        )
    }

    func compositionSnapshot(imageOverlays: [UUID: CGImage]) throws -> CompositionSnapshot {
        CompositionSnapshot(
            items: try items.map { try $0.compositionItem(imageOverlays: imageOverlays) },
            selectedItemIDs: selectedItemIDs,
            isActivated: isActivated,
            layout: layout,
            comparison: comparison,
            steps: steps,
            canvas: try canvas.compositionCanvasState(imageOverlays: imageOverlays)
        )
    }
}

nonisolated private struct CompatibleCompositionLayoutConfiguration: Decodable {
    var mode: CompositionLayoutMode
    var gridColumns: Int?
    var targetAspectRatio: CGFloat
    var freeformCanvasSize: CGSize?
    var sizingMode: CompositionSizingMode?
    var orientation: CompositionCanvasOrientation?

    var current: CompositionLayoutConfiguration {
        CompositionLayoutConfiguration(
            mode: mode,
            gridColumns: gridColumns,
            targetAspectRatio: targetAspectRatio,
            freeformCanvasSize: freeformCanvasSize,
            sizingMode: sizingMode ?? .equal,
            orientation: orientation ?? .automatic
        )
    }
}

nonisolated private struct CompatibleCompositionComparisonSettings: Decodable {
    var mode: CompositionComparisonMode
    var axis: CompositionAxis
    var primaryItemID: UUID?
    var secondaryItemID: UUID?
    var wipePosition: CGFloat
    var overlayOpacity: CGFloat
    var blinkInterval: TimeInterval
    var differenceIntensity: CGFloat
    var changeThreshold: CGFloat
    var changeHighlightColor: RGBAColor
    var primaryLabel: String
    var secondaryLabel: String
    var showsLabels: Bool?
    var keepsViewsLinked: Bool?
    var registrationMode: CompositionRegistrationMode?
    var manualRegistrationOffset: CGSize?
    var registrationSensitivity: CGFloat?
    var unchangedContentOpacity: CGFloat?
    var differenceCueStyle: CompositionDifferenceCueStyle?
    var blinkCrossfadeDuration: TimeInterval?
    var blinkLoops: Bool?
    var posterFrame: CompositionPosterFrame?

    var current: CompositionComparisonSettings {
        CompositionComparisonSettings(
            mode: mode,
            axis: axis,
            primaryItemID: primaryItemID,
            secondaryItemID: secondaryItemID,
            wipePosition: wipePosition,
            overlayOpacity: overlayOpacity,
            blinkInterval: blinkInterval,
            differenceIntensity: differenceIntensity,
            changeThreshold: changeThreshold,
            changeHighlightColor: changeHighlightColor,
            primaryLabel: primaryLabel,
            secondaryLabel: secondaryLabel,
            showsLabels: showsLabels ?? true,
            keepsViewsLinked: keepsViewsLinked ?? true,
            registrationMode: registrationMode ?? .automatic,
            manualRegistrationOffset: manualRegistrationOffset ?? .zero,
            registrationSensitivity: registrationSensitivity ?? 0.5,
            unchangedContentOpacity: unchangedContentOpacity ?? 0.2,
            differenceCueStyle: differenceCueStyle ?? .outlineAndPattern,
            blinkCrossfadeDuration: blinkCrossfadeDuration ?? 0,
            blinkLoops: blinkLoops ?? true,
            posterFrame: posterFrame ?? .secondary
        )
    }
}

nonisolated private struct CompatibleCompositionStepsSettings: Decodable {
    var axis: CompositionAxis
    var flow: CompositionStepFlow?
    var gridColumns: Int?
    var numberingStyle: CompositionStepNumberingStyle
    var startIndex: Int
    var showsCaptions: Bool
    var connectorStyle: CompositionStepConnectorStyle
    var itemsPerPage: Int?

    var current: CompositionStepsSettings {
        CompositionStepsSettings(
            axis: axis,
            flow: flow ?? .column,
            gridColumns: gridColumns ?? 2,
            numberingStyle: numberingStyle,
            startIndex: startIndex,
            showsCaptions: showsCaptions,
            connectorStyle: connectorStyle,
            itemsPerPage: itemsPerPage
        )
    }
}

nonisolated private struct CompositionItemRecord: Codable {
    var id: UUID
    var assetID: UUID
    var editState: ScreenshotEditStateRecord
    var framing: CompositionItemFraming
    var opacity: Double
    var weight: Double
    var title: String
    var caption: String?
    var accessibilityLabel: String?
    var freeformFrame: RectRecord?
    var isIncluded: Bool
    var semanticRole: CompositionItemSemanticRole?
    var zIndex: Int?

    init(_ item: CompositionItem) {
        id = item.id
        assetID = item.assetID
        editState = ScreenshotEditStateRecord(item.editState)
        framing = item.framing
        opacity = Double(item.opacity)
        weight = Double(item.weight)
        title = item.title
        caption = item.caption
        accessibilityLabel = item.accessibilityLabel
        freeformFrame = item.freeformFrame.map(RectRecord.init)
        isIncluded = item.isIncluded
        semanticRole = item.semanticRole
        zIndex = item.zIndex
    }

    func compositionItem(imageOverlays: [UUID: CGImage]) throws -> CompositionItem {
        CompositionItem(
            id: id,
            assetID: assetID,
            editState: try editState.screenshotEditState(imageOverlays: imageOverlays),
            framing: framing,
            opacity: CGFloat(opacity),
            weight: CGFloat(weight),
            title: title,
            caption: caption,
            accessibilityLabel: accessibilityLabel,
            freeformFrame: freeformFrame?.cgRect,
            isIncluded: isIncluded,
            semanticRole: semanticRole ?? .standard,
            zIndex: zIndex ?? 0
        )
    }
}

nonisolated private struct ScreenshotEditStateRecord: Codable {
    var cropRect: RectRecord?
    var annotations: [AnnotationRecord]
    var selectedAnnotationIDs: [UUID]
    var nextCalloutNumber: Int
    var pinnedUIMapElementIDs: [UUID]

    init(_ state: ScreenshotEditState) {
        cropRect = state.cropRect.map(RectRecord.init)
        annotations = state.annotations.map(AnnotationRecord.init)
        selectedAnnotationIDs = state.selectedAnnotationIDs
        nextCalloutNumber = state.nextCalloutNumber
        pinnedUIMapElementIDs = state.pinnedUIMapElementIDs
    }

    func screenshotEditState(imageOverlays: [UUID: CGImage]) throws -> ScreenshotEditState {
        ScreenshotEditState(
            cropRect: cropRect?.cgRect,
            annotations: try annotations.map { try $0.annotation(imageOverlays: imageOverlays) },
            selectedAnnotationIDs: selectedAnnotationIDs,
            nextCalloutNumber: nextCalloutNumber,
            pinnedUIMapElementIDs: pinnedUIMapElementIDs
        )
    }
}

nonisolated private struct CompositionCanvasStateRecord: Codable {
    var title: String
    var appearance: CompositionCanvasAppearance
    var annotations: [AnnotationRecord]
    var selectedAnnotationIDs: [UUID]
    var nextCalloutNumber: Int
    var annotationAnchors: [UUID: CompositionAnnotationAnchors]?

    private enum CodingKeys: String, CodingKey {
        case title
        case appearance
        case annotations
        case selectedAnnotationIDs
        case nextCalloutNumber
        case annotationAnchors
    }

    init(_ canvas: CompositionCanvasState) {
        title = canvas.title
        appearance = canvas.appearance
        annotations = canvas.annotations.map(AnnotationRecord.init)
        selectedAnnotationIDs = canvas.selectedAnnotationIDs
        nextCalloutNumber = canvas.nextCalloutNumber
        annotationAnchors = canvas.annotationAnchors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        appearance = try container.decode(
            CompatibleCompositionCanvasAppearance.self,
            forKey: .appearance
        ).current
        annotations = try container.decode(
            [AnnotationRecord].self,
            forKey: .annotations
        )
        selectedAnnotationIDs = try container.decode(
            [UUID].self,
            forKey: .selectedAnnotationIDs
        )
        nextCalloutNumber = try container.decode(
            Int.self,
            forKey: .nextCalloutNumber
        )
        annotationAnchors = try container.decodeIfPresent(
            [UUID: CompositionAnnotationAnchors].self,
            forKey: .annotationAnchors
        )
    }

    func compositionCanvasState(imageOverlays: [UUID: CGImage]) throws -> CompositionCanvasState {
        CompositionCanvasState(
            title: title,
            appearance: appearance,
            annotations: try annotations.map { try $0.annotation(imageOverlays: imageOverlays) },
            selectedAnnotationIDs: selectedAnnotationIDs,
            nextCalloutNumber: nextCalloutNumber,
            annotationAnchors: annotationAnchors ?? [:]
        )
    }
}

nonisolated private struct CompatibleCompositionCanvasAppearance: Decodable {
    var fill: CompositionCanvasFill
    var insets: CompositionInsets
    var itemSpacing: CGFloat
    var itemFill: RGBAColor
    var itemBorderColor: RGBAColor
    var itemBorderWidth: CGFloat
    var itemCornerRadius: CGFloat
    var itemShadowColor: RGBAColor
    var itemShadowBlur: CGFloat
    var itemShadowOffset: CGSize
    var captionColor: RGBAColor
    var captionBackgroundColor: RGBAColor
    var captionFontSize: CGFloat
    var captionFontName: String?
    var captionFontWeight: CompositionTextWeight?
    var captionTextAlignment: CompositionTextAlignment?
    var captionPlacement: CompositionCaptionPlacement?
    var captionInsets: CompositionInsets
    var titleColor: RGBAColor?
    var titleBackgroundColor: RGBAColor?
    var titleFontSize: CGFloat?
    var titleFontName: String?
    var titleFontWeight: CompositionTextWeight?
    var titleTextAlignment: CompositionTextAlignment?
    var titleInsets: CompositionInsets?
    var stepBadgeFill: RGBAColor
    var stepBadgeForeground: RGBAColor
    var stepBadgeDiameter: CGFloat
    var connectorColor: RGBAColor
    var connectorWidth: CGFloat
    var comparisonDividerColor: RGBAColor
    var comparisonDividerWidth: CGFloat

    var current: CompositionCanvasAppearance {
        CompositionCanvasAppearance(
            fill: fill,
            insets: insets,
            itemSpacing: itemSpacing,
            itemFill: itemFill,
            itemBorderColor: itemBorderColor,
            itemBorderWidth: itemBorderWidth,
            itemCornerRadius: itemCornerRadius,
            itemShadowColor: itemShadowColor,
            itemShadowBlur: itemShadowBlur,
            itemShadowOffset: itemShadowOffset,
            captionColor: captionColor,
            captionBackgroundColor: captionBackgroundColor,
            captionFontSize: captionFontSize,
            captionFontName: captionFontName,
            captionFontWeight: captionFontWeight ?? .regular,
            captionTextAlignment: captionTextAlignment ?? .leading,
            captionPlacement: captionPlacement ?? .below,
            captionInsets: captionInsets,
            titleColor: titleColor
                ?? RGBAColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1),
            titleBackgroundColor: titleBackgroundColor ?? .clear,
            titleFontSize: titleFontSize ?? 28,
            titleFontName: titleFontName,
            titleFontWeight: titleFontWeight ?? .semibold,
            titleTextAlignment: titleTextAlignment ?? .leading,
            titleInsets: titleInsets
                ?? CompositionInsets(
                    top: 8,
                    leading: 4,
                    bottom: 16,
                    trailing: 4
                ),
            stepBadgeFill: stepBadgeFill,
            stepBadgeForeground: stepBadgeForeground,
            stepBadgeDiameter: stepBadgeDiameter,
            connectorColor: connectorColor,
            connectorWidth: connectorWidth,
            comparisonDividerColor: comparisonDividerColor,
            comparisonDividerWidth: comparisonDividerWidth
        )
    }
}

nonisolated private struct ScreenshotPresentationRecord: Codable {
    var isEnabled: Bool
    var style: PresentationStyle?
    var scene: AppliedPresentationScene?
    var background: ScreenshotPresentationBackgroundRecord
    var canvas: PresentationCanvas?
    var subjectPlacement: PresentationSubjectPlacement?
    var frame: PresentationFrame?
    var padding: Double
    var cornerRadius: Double
    var shadow: String
    var shadowBlurRadius: Double?
    var shadowOffsetX: Double?
    var shadowOffsetY: Double?
    var shadowOpacity: Double?

    nonisolated init(_ presentation: ScreenshotPresentation) {
        isEnabled = presentation.isEnabled
        style = presentation.style
        scene = presentation.scene
        background = ScreenshotPresentationBackgroundRecord(presentation.background)
        canvas = presentation.canvas
        subjectPlacement = presentation.subjectPlacement
        frame = presentation.frame
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
            canvas: canvas ?? .original,
            subjectPlacement: subjectPlacement ?? .default,
            frame: frame ?? .none,
            padding: CGFloat(padding),
            cornerRadius: CGFloat(cornerRadius),
            shadow: shadowStyle,
            shadowBlurRadius: shadowBlurRadius.map { CGFloat($0) } ?? shadowStyle.blurRadius,
            shadowOffsetX: shadowOffsetX.map { CGFloat($0) } ?? shadowStyle.offsetX,
            shadowOffsetY: shadowOffsetY.map { CGFloat($0) } ?? shadowStyle.offsetY,
            shadowOpacity: shadowOpacity.map { CGFloat($0) } ?? shadowStyle.opacity,
            scene: scene
        )
    }
}

nonisolated private struct ScreenshotPresentationBackgroundRecord: Codable {
    var kind: String
    var color: ColorRecord?
    var start: ColorRecord?
    var end: ColorRecord?
    var base: ColorRecord?
    var spotlight: ColorRecord?
    var tint: ColorRecord?

    nonisolated init(_ background: ScreenshotPresentationBackground) {
        switch background {
        case .transparent:
            kind = "transparent"
            color = nil
            start = nil
            end = nil
            base = nil
            spotlight = nil
            tint = nil
        case let .solid(fillColor):
            kind = "solid"
            color = ColorRecord(fillColor)
            start = nil
            end = nil
            base = nil
            spotlight = nil
            tint = nil
        case let .twoColorGradient(startColor, endColor):
            kind = "twoColorGradient"
            color = nil
            start = ColorRecord(startColor)
            end = ColorRecord(endColor)
            base = nil
            spotlight = nil
            tint = nil
        case let .radialSpotlight(baseColor, spotlightColor):
            kind = "radialSpotlight"
            color = nil
            start = nil
            end = nil
            base = ColorRecord(baseColor)
            spotlight = ColorRecord(spotlightColor)
            tint = nil
        case let .blurredScreenshot(tintColor):
            kind = "blurredScreenshot"
            color = nil
            start = nil
            end = nil
            base = nil
            spotlight = nil
            tint = ColorRecord(tintColor)
        }
    }

    var screenshotPresentationBackground: ScreenshotPresentationBackground {
        switch kind {
        case "transparent":
            return .transparent
        case "twoColorGradient", "gradient":
            return .twoColorGradient(
                start: start?.rgbaColor ?? RGBAColor(red: 0.32, green: 0.55, blue: 0.94, alpha: 1),
                end: end?.rgbaColor ?? RGBAColor(red: 0.08, green: 0.12, blue: 0.20, alpha: 1)
            )
        case "radialSpotlight":
            return .radialSpotlight(
                base: base?.rgbaColor ?? RGBAColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1),
                spotlight: spotlight?.rgbaColor ?? RGBAColor(red: 0.75, green: 0.86, blue: 1, alpha: 1)
            )
        case "blurredScreenshot":
            return .blurredScreenshot(
                tint: tint?.rgbaColor ?? RGBAColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 0.35)
            )
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
    var automaticallySizesToText: Bool?
    var number: Int?
    var textAlignment: String?
    var arrowHeadStyle: String?
    var arrowHeadShape: String?
    var arrowCurvature: Double?
    var arrowLabelBoxColor: ColorRecord?
    var arrowLabelPlacement: String?
    var arrowLabelFontSize: Double?
    var arrowLabelTextColor: String?
    var numberedArrowBadgeStyle: String?
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
        automaticallySizesToText = nil
        number = nil
        textAlignment = nil
        arrowHeadStyle = nil
        arrowHeadShape = nil
        arrowCurvature = nil
        arrowLabelBoxColor = nil
        arrowLabelPlacement = nil
        arrowLabelFontSize = nil
        arrowLabelTextColor = nil
        numberedArrowBadgeStyle = nil
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
            number = shape.sequenceNumber
            numberedArrowBadgeStyle = shape.badgeStyle.rawValue
        case let .statusMark(shape):
            kind = "statusMark"
            rect = RectRecord(shape.rect)
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
            automaticallySizesToText = shape.automaticallySizesToText
            textAlignment = shape.alignment.rawValue
        case let .callout(shape):
            kind = "callout"
            rect = RectRecord(shape.rect)
            number = shape.number
            text = shape.text
            automaticallySizesToText = shape.automaticallySizesToText
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
                headShape: ArrowHeadShape(rawValue: arrowHeadShape ?? "open") ?? .open,
                sequenceNumber: number,
                badgeStyle: NumberedArrowBadgeStyle(rawValue: numberedArrowBadgeStyle ?? NumberedArrowBadgeStyle.filled.rawValue) ?? .filled
            ))
        case "statusMark":
            guard let rect else {
                throw SSSDocumentError.invalidManifest
            }
            annotationKind = .statusMark(StatusMarkShape(rect: rect.cgRect))
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
            annotationKind = .text(TextShape(
                rect: rect.cgRect,
                text: text,
                alignment: TextAlignmentMode(rawValue: textAlignment ?? "left") ?? .left,
                automaticallySizesToText: automaticallySizesToText ?? false
            ))
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
                leaderPoint: leaderPoint?.cgPoint,
                automaticallySizesToText: automaticallySizesToText ?? false
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
    var statusMarkSymbol: String?
    var statusMarkVisualStyle: String?

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
        statusMarkSymbol = style.statusMarkSymbol.rawValue
        statusMarkVisualStyle = style.statusMarkVisualStyle.rawValue
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
            freehandSimplification: CGFloat(freehandSimplification ?? 1.5),
            statusMarkSymbol: StatusMarkSymbol(rawValue: statusMarkSymbol ?? "checkmark") ?? .checkmark,
            statusMarkVisualStyle: StatusMarkVisualStyle(rawValue: statusMarkVisualStyle ?? "outlined") ?? .outlined
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

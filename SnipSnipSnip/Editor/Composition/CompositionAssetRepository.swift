import CoreGraphics
import Foundation
import ImageIO

/// Product terminology alias retained at the document boundary.
typealias CaptureAssetDescriptor = CompositionAssetDescriptor

nonisolated enum CompositionAssetRepositoryError: LocalizedError, Equatable {
    case missingAsset(UUID)
    case invalidImage(UUID)
    case descriptorMismatch(UUID)

    var errorDescription: String? {
        switch self {
        case .missingAsset(let id):
            return "The composition image \(id.uuidString) is missing."
        case .invalidImage(let id):
            return "The composition image \(id.uuidString) could not be decoded."
        case .descriptorMismatch(let id):
            return "The composition image \(id.uuidString) does not match its saved dimensions."
        }
    }
}

nonisolated enum CompositionAssetAvailability: String, Codable, Equatable, Sendable {
    case available
    case missing
    case corrupt
}

nonisolated struct CompositionAssetRepositoryDiagnostics: Equatable, Sendable {
    var fullResolutionDecodeCount = 0
    var downsampledDecodeCount = 0
    var renderedPreviewCacheHitCount = 0
    var renderedPreviewCacheMissCount = 0
}

/// Encoded, metadata-bearing representation used by document and recovery
/// persistence. The encoded PNG is the source of truth; decoded pixels live
/// only in the repository's cost-bounded caches.
nonisolated struct CompositionStoredAsset: Equatable, @unchecked Sendable {
    let descriptor: CompositionAssetDescriptor
    let encodedPNG: Data?
    let uiMap: UIMapSnapshot?
    let availability: CompositionAssetAvailability

    init(
        descriptor: CompositionAssetDescriptor,
        encodedPNG: Data?,
        uiMap: UIMapSnapshot? = nil,
        availability: CompositionAssetAvailability = .available
    ) {
        self.descriptor = descriptor
        self.encodedPNG = encodedPNG
        self.uiMap = uiMap
        self.availability = availability
    }
}

nonisolated final class CompositionAssetRepository: @unchecked Sendable {
    private final class ImageBox {
        let image: CGImage

        init(_ image: CGImage) {
            self.image = image
        }
    }

    private struct PreviewEditFingerprint: Equatable {
        let cropRect: CGRect?
        let annotations: [Annotation]
        let pinnedUIMapElementIDs: [UUID]

        init(_ state: ScreenshotEditState) {
            cropRect = state.cropRect
            annotations = state.annotations
            pinnedUIMapElementIDs = state.pinnedUIMapElementIDs
        }

        var cacheHash: Int {
            var hasher = Hasher()
            hasher.combine(cropRect?.origin.x)
            hasher.combine(cropRect?.origin.y)
            hasher.combine(cropRect?.size.width)
            hasher.combine(cropRect?.size.height)
            hasher.combine(pinnedUIMapElementIDs)
            hasher.combine(annotations.count)
            for annotation in annotations {
                hasher.combine(annotation.id)
                // `Annotation` intentionally is not Hashable because image
                // overlays compare by immutable asset identity and geometry.
                // Reflection covers that complete Equatable pixel state for a
                // process-local cache; the exact fingerprint below still
                // verifies a hash hit before pixels are reused.
                hasher.combine(String(reflecting: annotation))
            }
            return hasher.finalize()
        }
    }

    private final class PreviewImageBox {
        let image: CGImage
        let editFingerprint: PreviewEditFingerprint
        let appliesItemEdits: Bool
        let uiMapOverlayOptions: UIMapOverlayOptions

        init(
            image: CGImage,
            editFingerprint: PreviewEditFingerprint,
            appliesItemEdits: Bool,
            uiMapOverlayOptions: UIMapOverlayOptions
        ) {
            self.image = image
            self.editFingerprint = editFingerprint
            self.appliesItemEdits = appliesItemEdits
            self.uiMapOverlayOptions = uiMapOverlayOptions
        }
    }

    private let lock = NSRecursiveLock()
    private var entries: [UUID: CompositionStoredAsset]
    private let decodedImages = NSCache<NSUUID, ImageBox>()
    private let thumbnails = NSCache<NSString, ImageBox>()
    private let renderedPreviews = NSCache<NSString, PreviewImageBox>()
    private var diagnosticState = CompositionAssetRepositoryDiagnostics()

    init(storedAssets: [CompositionStoredAsset] = []) {
        entries = Dictionary(uniqueKeysWithValues: storedAssets.map { ($0.descriptor.id, $0) })
        decodedImages.totalCostLimit = 256 * 1024 * 1024
        thumbnails.totalCostLimit = 64 * 1024 * 1024
        renderedPreviews.totalCostLimit = 128 * 1024 * 1024
        renderedPreviews.countLimit = 128
    }

    var assetIDs: [UUID] {
        lock.withLock { Array(entries.keys) }
    }

    var descriptors: [UUID: CompositionAssetDescriptor] {
        lock.withLock {
            entries.mapValues(\.descriptor)
        }
    }

    var diagnostics: CompositionAssetRepositoryDiagnostics {
        lock.withLock { diagnosticState }
    }

    func resetDiagnostics() {
        lock.withLock {
            diagnosticState = CompositionAssetRepositoryDiagnostics()
        }
    }

    func contains(_ assetID: UUID) -> Bool {
        lock.withLock { entries[assetID] != nil }
    }

    @discardableResult
    func add(
        capture: CapturedScreenshot,
        isPrivate: Bool,
        assetID: UUID = UUID(),
        accessibilityLabel: String? = nil
    ) throws -> UUID {
        let descriptor = CompositionAssetDescriptor(
            id: assetID,
            pixelWidth: capture.image.width,
            pixelHeight: capture.image.height,
            sourceName: capture.sourceName,
            capturedAt: capture.capturedAt,
            accessibilityLabel: accessibilityLabel ?? capture.sourceName,
            captureKind: capture.kind.rawValue,
            sourceRect: capture.sourceRect,
            coordinateContract: capture.coordinateContract,
            isPrivate: isPrivate
        )
        let data = try ImageExporter.pngData(for: capture.image)
        let stored = CompositionStoredAsset(
            descriptor: descriptor,
            encodedPNG: data,
            uiMap: capture.uiMap,
            availability: .available
        )

        lock.withLock {
            entries[assetID] = stored
            decodedImages.setObject(
                ImageBox(capture.image),
                forKey: assetID as NSUUID,
                cost: Self.imageCost(capture.image)
            )
            thumbnails.removeAllObjects()
            renderedPreviews.removeAllObjects()
        }
        return assetID
    }

    func insert(_ storedAsset: CompositionStoredAsset) throws {
        try Self.validateEncodedDimensions(storedAsset)
        lock.withLock {
            entries[storedAsset.descriptor.id] = storedAsset
            decodedImages.removeObject(forKey: storedAsset.descriptor.id as NSUUID)
            thumbnails.removeAllObjects()
            renderedPreviews.removeAllObjects()
        }
    }

    func replaceUIMap(for assetID: UUID, with uiMap: UIMapSnapshot?) throws {
        try lock.withLock {
            guard let entry = entries[assetID] else {
                throw CompositionAssetRepositoryError.missingAsset(assetID)
            }
            entries[assetID] = CompositionStoredAsset(
                descriptor: entry.descriptor,
                encodedPNG: entry.encodedPNG,
                uiMap: uiMap,
                availability: entry.availability
            )
            renderedPreviews.removeAllObjects()
        }
    }

    func storedAsset(for assetID: UUID) -> CompositionStoredAsset? {
        lock.withLock { entries[assetID] }
    }

    func availability(for assetID: UUID) -> CompositionAssetAvailability? {
        lock.withLock { entries[assetID]?.availability }
    }

    func storedAssets(referencedBy assetIDs: Set<UUID>? = nil) -> [CompositionStoredAsset] {
        lock.withLock {
            entries.values
                .filter { assetIDs?.contains($0.descriptor.id) ?? true }
                .sorted { $0.descriptor.id.uuidString < $1.descriptor.id.uuidString }
        }
    }

    /// Removes assets created by an operation that failed before its document
    /// mutation committed. Callers must pass exact transaction-owned IDs.
    func removeAssets(_ assetIDs: Set<UUID>) {
        guard !assetIDs.isEmpty else {
            return
        }
        lock.withLock {
            for assetID in assetIDs {
                entries.removeValue(forKey: assetID)
                decodedImages.removeObject(forKey: assetID as NSUUID)
            }
            // Thumbnail keys include both the asset ID and requested size.
            // Clearing the small bounded cache avoids retaining rolled-back
            // transaction pixels without relying on key-prefix enumeration.
            thumbnails.removeAllObjects()
            renderedPreviews.removeAllObjects()
        }
    }

    func asset(for assetID: UUID) throws -> CompositionAsset {
        let entry = try lock.withLock { () throws -> CompositionStoredAsset in
            guard let entry = entries[assetID] else {
                throw CompositionAssetRepositoryError.missingAsset(assetID)
            }
            return entry
        }

        if let cached = decodedImages.object(forKey: assetID as NSUUID) {
            guard let asset = CompositionAsset(
                descriptor: entry.descriptor,
                image: cached.image,
                uiMap: entry.uiMap
            ) else {
                throw CompositionAssetRepositoryError.descriptorMismatch(assetID)
            }
            return asset
        }

        let image = try Self.decode(entry)
        lock.withLock {
            diagnosticState.fullResolutionDecodeCount += 1
        }
        decodedImages.setObject(
            ImageBox(image),
            forKey: assetID as NSUUID,
            cost: Self.imageCost(image)
        )
        guard let asset = CompositionAsset(
            descriptor: entry.descriptor,
            image: image,
            uiMap: entry.uiMap
        ) else {
            throw CompositionAssetRepositoryError.descriptorMismatch(assetID)
        }
        return asset
    }

    func assets(for assetIDs: Set<UUID>) throws -> [UUID: CompositionAsset] {
        try Dictionary(uniqueKeysWithValues: assetIDs.map { id in
            (id, try asset(for: id))
        })
    }

    func thumbnail(for assetID: UUID, maxPixelDimension: Int = 320) throws -> CGImage {
        let resolvedDimension = max(maxPixelDimension, 1)
        let key = "\(assetID.uuidString)-\(resolvedDimension)" as NSString
        if let cached = thumbnails.object(forKey: key) {
            return cached.image
        }

        let stored = try requiredStoredAsset(for: assetID)
        let image = try downsampledImage(
            stored,
            maxPixelDimension: resolvedDimension
        )
        thumbnails.setObject(ImageBox(image), forKey: key, cost: Self.imageCost(image))
        return image
    }

    /// Produces one edited item at approximately the pixels its destination
    /// cell can display. The encoded source is downsampled by ImageIO before
    /// crop/annotation rendering, avoiding a source-resolution intermediate.
    ///
    /// Full-resolution export continues through `asset(for:)`.
    func renderedPreview(
        for item: CompositionItem,
        targetRenderedPixelSize: CGSize,
        appliesItemEdits: Bool,
        uiMapOverlayOptions: UIMapOverlayOptions
    ) throws -> CGImage {
        let stored = try requiredStoredAsset(for: item.assetID)
        let descriptor = stored.descriptor
        let fullRect = CGRect(origin: .zero, size: descriptor.pixelSize)
        let cropRect: CGRect
        if appliesItemEdits, let requestedCrop = item.editState.cropRect {
            cropRect = requestedCrop.standardized.intersection(fullRect).integral
        } else {
            cropRect = fullRect
        }
        guard cropRect.width > 0, cropRect.height > 0 else {
            throw CompositionAssetRepositoryError.invalidImage(item.assetID)
        }

        let targetWidth = max(Int(targetRenderedPixelSize.width.rounded(.up)), 1)
        let targetHeight = max(Int(targetRenderedPixelSize.height.rounded(.up)), 1)
        let requiredScale = min(
            max(
                CGFloat(targetWidth + 2) / cropRect.width,
                CGFloat(targetHeight + 2) / cropRect.height
            ),
            1
        )
        let sourceMaximumDimension = max(
            Int(
                ceil(
                    max(descriptor.pixelSize.width, descriptor.pixelSize.height)
                        * requiredScale
                )
            ),
            1
        )
        let editFingerprint = PreviewEditFingerprint(item.editState)
        let key = [
            item.assetID.uuidString,
            String(targetWidth),
            String(targetHeight),
            String(sourceMaximumDimension),
            appliesItemEdits ? "edited" : "raw",
            String(editFingerprint.cacheHash),
        ].joined(separator: "-") as NSString

        if let cached = renderedPreviews.object(forKey: key),
           cached.editFingerprint == editFingerprint,
           cached.appliesItemEdits == appliesItemEdits,
           cached.uiMapOverlayOptions == uiMapOverlayOptions {
            lock.withLock {
                diagnosticState.renderedPreviewCacheHitCount += 1
            }
            return cached.image
        }
        lock.withLock {
            diagnosticState.renderedPreviewCacheMissCount += 1
        }

        let source = try downsampledImage(
            stored,
            maxPixelDimension: sourceMaximumDimension
        )
        let scaleX = CGFloat(source.width) / max(descriptor.pixelSize.width, 1)
        let scaleY = CGFloat(source.height) / max(descriptor.pixelSize.height, 1)
        let previewFullRect = CGRect(
            x: 0,
            y: 0,
            width: source.width,
            height: source.height
        )
        let rendered: CGImage

        if !appliesItemEdits || item.editState.isPixelIdentity(
            fullPixelSize: descriptor.pixelSize
        ) {
            rendered = source
        } else {
            let scaledCrop = Self.scaledRect(
                cropRect,
                scaleX: scaleX,
                scaleY: scaleY
            )
            let scaledAnnotations = item.editState.annotations.map {
                Self.scaledAnnotation(
                    $0,
                    from: fullRect,
                    to: previewFullRect,
                    styleScale: min(scaleX, scaleY)
                )
            }
            let snapshot = EditorSnapshot(
                cropRect: scaledCrop,
                annotations: scaledAnnotations,
                selectedAnnotationIDs: [],
                nextCalloutNumber: item.editState.nextCalloutNumber,
                presentation: .plain,
                pinnedUIMapElementIDs: item.editState.pinnedUIMapElementIDs
            )
            let pinnedElements = item.editState.pinnedUIMapElementIDs.compactMap {
                stored.uiMap?.element(matching: $0)
            }
            .map {
                Self.scaledUIMapElement($0, scaleX: scaleX, scaleY: scaleY)
            }
            guard let edited = EditorRenderer.render(
                baseImage: source,
                snapshot: snapshot,
                pinnedUIMapElements: pinnedElements,
                uiMapOverlayOptions: uiMapOverlayOptions
            ) else {
                throw CompositionAssetRepositoryError.invalidImage(item.assetID)
            }
            rendered = edited
        }

        let box = PreviewImageBox(
            image: rendered,
            editFingerprint: editFingerprint,
            appliesItemEdits: appliesItemEdits,
            uiMapOverlayOptions: uiMapOverlayOptions
        )
        renderedPreviews.setObject(
            box,
            forKey: key,
            cost: Self.imageCost(rendered)
        )
        return rendered
    }

    func capturedScreenshot(for assetID: UUID) throws -> CapturedScreenshot {
        let stored = try lock.withLock { () throws -> CompositionStoredAsset in
            guard let entry = entries[assetID] else {
                throw CompositionAssetRepositoryError.missingAsset(assetID)
            }
            return entry
        }
        let descriptor = stored.descriptor
        guard let kind = descriptor.captureKind.flatMap(CaptureKind.init(rawValue:)) else {
            throw CompositionAssetRepositoryError.invalidImage(assetID)
        }
        return CapturedScreenshot(
            image: try asset(for: assetID).image,
            kind: kind,
            sourceName: descriptor.sourceName,
            sourceRect: descriptor.sourceRect
                ?? CGRect(origin: .zero, size: descriptor.pixelSize),
            coordinateContract: descriptor.coordinateContract,
            capturedAt: descriptor.capturedAt ?? Date(timeIntervalSince1970: 0),
            uiMap: stored.uiMap
        )
    }

    func removeDecodedImages() {
        decodedImages.removeAllObjects()
        thumbnails.removeAllObjects()
        renderedPreviews.removeAllObjects()
    }

    private func requiredStoredAsset(for assetID: UUID) throws -> CompositionStoredAsset {
        try lock.withLock {
            guard let entry = entries[assetID] else {
                throw CompositionAssetRepositoryError.missingAsset(assetID)
            }
            return entry
        }
    }

    private func downsampledImage(
        _ stored: CompositionStoredAsset,
        maxPixelDimension: Int
    ) throws -> CGImage {
        let image = try Self.decode(
            stored,
            maxPixelDimension: max(maxPixelDimension, 1)
        )
        lock.withLock {
            diagnosticState.downsampledDecodeCount += 1
        }
        return image
    }

    private static func decode(_ stored: CompositionStoredAsset) throws -> CGImage {
        guard stored.availability == .available,
              let encodedPNG = stored.encodedPNG,
              let source = CGImageSourceCreateWithData(encodedPNG as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CompositionAssetRepositoryError.invalidImage(stored.descriptor.id)
        }
        guard image.width == stored.descriptor.pixelWidth,
              image.height == stored.descriptor.pixelHeight else {
            throw CompositionAssetRepositoryError.descriptorMismatch(stored.descriptor.id)
        }
        return image
    }

    private static func decode(
        _ stored: CompositionStoredAsset,
        maxPixelDimension: Int
    ) throws -> CGImage {
        try validateEncodedDimensions(stored)
        guard let encodedPNG = stored.encodedPNG,
              let source = CGImageSourceCreateWithData(encodedPNG as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: false,
                    kCGImageSourceThumbnailMaxPixelSize: max(maxPixelDimension, 1),
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
              ) else {
            throw CompositionAssetRepositoryError.invalidImage(stored.descriptor.id)
        }
        return image
    }

    private static func validateEncodedDimensions(
        _ stored: CompositionStoredAsset
    ) throws {
        guard stored.availability == .available,
              let encodedPNG = stored.encodedPNG,
              let source = CGImageSourceCreateWithData(encodedPNG as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
              ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw CompositionAssetRepositoryError.invalidImage(stored.descriptor.id)
        }
        guard width == stored.descriptor.pixelWidth,
              height == stored.descriptor.pixelHeight else {
            throw CompositionAssetRepositoryError.descriptorMismatch(
                stored.descriptor.id
            )
        }
    }

    private static func scaledRect(
        _ rect: CGRect,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> CGRect {
        CGRect(
            x: rect.minX * scaleX,
            y: rect.minY * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
        .standardized
        .integral
    }

    private static func scaledAnnotation(
        _ annotation: Annotation,
        from sourceBounds: CGRect,
        to destinationBounds: CGRect,
        styleScale: CGFloat
    ) -> Annotation {
        var scaled = annotation.scaled(
            from: sourceBounds,
            to: destinationBounds
        )
        var style = scaled.style.scaledForDisplay(by: styleScale)
        style.effectRadius *= styleScale
        scaled.style = style
        if case .arrow(var shape) = scaled.kind {
            shape.labelFontSize *= styleScale
            scaled.kind = .arrow(shape)
        }
        return scaled
    }

    private static func scaledUIMapElement(
        _ element: UIMapElement,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> UIMapElement {
        var scaled = element
        scaled.documentRect = scaledRect(
            element.documentRect,
            scaleX: scaleX,
            scaleY: scaleY
        )
        scaled.children = element.children.map {
            scaledUIMapElement($0, scaleX: scaleX, scaleY: scaleY)
        }
        return scaled
    }

    private static func imageCost(_ image: CGImage) -> Int {
        let pixels = image.width.multipliedReportingOverflow(by: image.height)
        guard !pixels.overflow else {
            return Int.max
        }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        return bytes.overflow ? Int.max : bytes.partialValue
    }
}

nonisolated private extension NSRecursiveLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

nonisolated private extension ScreenshotEditState {
    func isPixelIdentity(fullPixelSize: CGSize) -> Bool {
        let fullRect = CGRect(origin: .zero, size: fullPixelSize)
        let resolvedCrop = cropRect?.standardized.integral ?? fullRect
        return resolvedCrop == fullRect
            && annotations.isEmpty
            && pinnedUIMapElementIDs.isEmpty
    }
}

nonisolated extension EditorDocumentSession {
    var referencedCompositionAssetIDs: Set<UUID> {
        let snapshots = [initialSnapshot, currentSnapshot] + undoStack + redoStack
        return Set(
            snapshots
                .compactMap(\.composition)
                .flatMap(\.items)
                .map(\.assetID)
        )
    }
}

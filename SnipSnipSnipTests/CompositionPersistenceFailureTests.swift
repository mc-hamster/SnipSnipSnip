import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

final class CompositionPersistenceFailureTests: XCTestCase {
    func testCompositionAnchorsDoNotDriftAcrossOneHundredLayoutFramingReorderAndV7RoundTrips() throws {
        let packageURL = temporaryRootURL()
            .appendingPathComponent("Anchor Drift")
            .appendingPathExtension("sss")
        defer {
            try? FileManager.default.removeItem(
                at: packageURL.deletingLastPathComponent()
            )
        }
        try FileManager.default.createDirectory(
            at: packageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let firstImage = makeCoordinateImage(width: 93, height: 61)
        let secondImage = makeCoordinateImage(width: 71, height: 109)
        let firstAssetID = UUID()
        let secondAssetID = UUID()
        let firstItemID = UUID()
        let secondItemID = UUID()
        let annotation = Annotation.makeArrow(
            from: CGPoint(x: 17, y: 23),
            to: CGPoint(x: 131, y: 47)
        )
        let primaryNormalizedPoint = CGPoint(x: 0.2375, y: 0.71875)
        let secondaryNormalizedPoint = CGPoint(x: 0.8125, y: 0.15625)
        let anchors = CompositionAnnotationAnchors(
            primary: CompositionAnnotationAnchor(
                target: .itemNormalized(
                    itemID: firstItemID,
                    point: primaryNormalizedPoint
                ),
                lastCanvasPoint: CGPoint(x: 17, y: 23)
            ),
            secondary: CompositionAnnotationAnchor(
                target: .itemNormalized(
                    itemID: secondItemID,
                    point: secondaryNormalizedPoint
                ),
                lastCanvasPoint: CGPoint(x: 131, y: 47)
            )
        )
        let firstItem = CompositionItem(
            id: firstItemID,
            assetID: firstAssetID,
            editState: ScreenshotEditState(
                cropRect: CGRect(x: 3, y: 4, width: 83, height: 51)
            ),
            title: "First"
        )
        let secondItem = CompositionItem(
            id: secondItemID,
            assetID: secondAssetID,
            editState: ScreenshotEditState(
                cropRect: CGRect(x: 5, y: 7, width: 59, height: 91)
            ),
            title: "Second"
        )
        var snapshot = makeEditorSnapshot(
            cropRect: CGRect(
                origin: .zero,
                size: CGSize(width: firstImage.width, height: firstImage.height)
            )
        )
        snapshot.composition = CompositionSnapshot(
            items: [firstItem, secondItem],
            selectedItemIDs: [firstItemID],
            layout: CompositionLayoutConfiguration(mode: .row),
            canvas: CompositionCanvasState(
                annotations: [annotation],
                annotationAnchors: [annotation.id: anchors]
            )
        )
        var document = EditableScreenshotDocument(
            capture: makeCapturedScreenshot(
                image: firstImage,
                sourceName: "Anchor source"
            ),
            session: makeEditorDocumentSession(initialSnapshot: snapshot),
            compositionStoredAssets: [
                try storedAsset(
                    id: firstAssetID,
                    image: firstImage,
                    sourceName: "First"
                ),
                try storedAsset(
                    id: secondAssetID,
                    image: secondImage,
                    sourceName: "Second"
                ),
            ]
        )

        let modes: [CompositionLayoutMode] = [
            .row,
            .column,
            .grid,
            .steps,
            .freeform,
            .auto,
        ]

        for cycle in 0..<100 {
            var composition = try XCTUnwrap(
                document.session.currentSnapshot.composition
            )
            composition.items.reverse()
            composition.layout = CompositionLayoutConfiguration(
                mode: modes[cycle % modes.count],
                gridColumns: cycle.isMultiple(of: 2) ? 2 : 1,
                targetAspectRatio: cycle.isMultiple(of: 2) ? 16 / 9 : 3 / 4,
                freeformCanvasSize: CGSize(
                    width: 360 + CGFloat(cycle % 7),
                    height: 260 + CGFloat(cycle % 5)
                ),
                sizingMode: cycle.isMultiple(of: 3) ? .weighted : .equal
            )
            for index in composition.items.indices {
                let itemOrdinal = composition.items[index].id == firstItemID
                    ? 0
                    : 1
                composition.items[index].weight = CGFloat(itemOrdinal + 1)
                    + CGFloat(cycle % 4) / 10
                composition.items[index].framing = CompositionItemFraming(
                    contentMode: cycle.isMultiple(of: 2) ? .fill : .contain,
                    horizontalAlignment: cycle.isMultiple(of: 3)
                        ? .leading
                        : .trailing,
                    verticalAlignment: cycle.isMultiple(of: 4)
                        ? .top
                        : .bottom,
                    scale: 1 + CGFloat((cycle + itemOrdinal) % 5) / 10,
                    offset: CGSize(
                        width: CGFloat((cycle + itemOrdinal) % 7) - 3,
                        height: CGFloat((cycle * 2 + itemOrdinal) % 9) - 4
                    )
                )
                composition.items[index].freeformFrame = CGRect(
                    x: 18 + CGFloat(itemOrdinal * 151) + CGFloat(cycle % 3),
                    y: 22 + CGFloat(itemOrdinal * 37) + CGFloat(cycle % 5),
                    width: 128 + CGFloat((cycle + itemOrdinal) % 11),
                    height: 94 + CGFloat((cycle * 2 + itemOrdinal) % 13)
                )
            }
            document.session.currentSnapshot.composition = composition

            let descriptors = Dictionary(
                uniqueKeysWithValues: document.compositionStoredAssets.map {
                    ($0.descriptor.id, $0.descriptor)
                }
            )
            let beforeLayout = try CompositionLayoutEngine.layout(
                composition: composition,
                assetDescriptors: descriptors
            )
            let beforeShape = try resolvedArrow(
                annotationID: annotation.id,
                composition: composition,
                layout: beforeLayout
            )

            try SSSDocumentPackage.save(
                document: document,
                previewImage: document.capture.image,
                to: packageURL
            )
            document = try SSSDocumentPackage.load(from: packageURL)

            XCTAssertEqual(
                document.sourceFormatVersion,
                SSSDocumentPackage.formatVersion,
                "Cycle \(cycle)"
            )
            let reopenedComposition = try XCTUnwrap(
                document.session.currentSnapshot.composition
            )
            let reopenedAnchors = try XCTUnwrap(
                reopenedComposition.canvas.annotationAnchors[annotation.id]
            )
            assertItemAnchor(
                reopenedAnchors.primary,
                itemID: firstItemID,
                normalizedPoint: primaryNormalizedPoint,
                cycle: cycle
            )
            let reopenedSecondary = try XCTUnwrap(reopenedAnchors.secondary)
            assertItemAnchor(
                reopenedSecondary,
                itemID: secondItemID,
                normalizedPoint: secondaryNormalizedPoint,
                cycle: cycle
            )

            let reopenedDescriptors = Dictionary(
                uniqueKeysWithValues: document.compositionStoredAssets.map {
                    ($0.descriptor.id, $0.descriptor)
                }
            )
            let reopenedLayout = try CompositionLayoutEngine.layout(
                composition: reopenedComposition,
                assetDescriptors: reopenedDescriptors
            )
            let reopenedShape = try resolvedArrow(
                annotationID: annotation.id,
                composition: reopenedComposition,
                layout: reopenedLayout
            )
            assertPoint(
                reopenedShape.start,
                equals: beforeShape.start,
                cycle: cycle,
                endpoint: "primary"
            )
            assertPoint(
                reopenedShape.end,
                equals: beforeShape.end,
                cycle: cycle,
                endpoint: "secondary"
            )

            let firstLayout = try XCTUnwrap(
                reopenedLayout.itemLayout(for: firstItemID)
            )
            let secondLayout = try XCTUnwrap(
                reopenedLayout.itemLayout(for: secondItemID)
            )
            assertPoint(
                reopenedShape.start,
                equals: resolvedPoint(
                    normalizedPoint: primaryNormalizedPoint,
                    in: firstLayout.imageDrawRect
                ),
                cycle: cycle,
                endpoint: "primary source transform"
            )
            assertPoint(
                reopenedShape.end,
                equals: resolvedPoint(
                    normalizedPoint: secondaryNormalizedPoint,
                    in: secondLayout.imageDrawRect
                ),
                cycle: cycle,
                endpoint: "secondary source transform"
            )
        }
    }

    func testV7CommitFailureLeavesExistingCompositionByteForByteIntact() throws {
        let rootURL = temporaryRootURL()
        let packageURL = rootURL
            .appendingPathComponent("Existing")
            .appendingPathExtension("sss")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let originalDocument = try makeCompositionDocument(title: "Original")
        try SSSDocumentPackage.save(
            document: originalDocument,
            previewImage: originalDocument.capture.image,
            to: packageURL
        )
        let originalManifest = try Data(
            contentsOf: packageURL.appendingPathComponent(
                SSSDocumentPackage.manifestFilename
            )
        )
        let failingFiles = FaultInjectingFileService(
            temporaryDirectory: rootURL,
            failure: .replace(
                CocoaError.Code.fileWriteUnknown
            )
        )
        let replacementDocument = try makeCompositionDocument(
            title: "Replacement"
        )

        XCTAssertThrowsError(
            try SSSDocumentPackage.save(
                document: replacementDocument,
                previewImage: replacementDocument.capture.image,
                to: packageURL,
                includeUIMapSearchText: true,
                files: failingFiles
            )
        ) { error in
            XCTAssertEqual(
                (error as NSError).domain,
                NSCocoaErrorDomain
            )
            XCTAssertEqual(
                (error as NSError).code,
                CocoaError.Code.fileWriteUnknown.rawValue
            )
        }

        XCTAssertEqual(
            try Data(
                contentsOf: packageURL.appendingPathComponent(
                    SSSDocumentPackage.manifestFilename
                )
            ),
            originalManifest
        )
        let reopened = try SSSDocumentPackage.load(from: packageURL)
        XCTAssertEqual(
            reopened.session.currentSnapshot.composition?.canvas.title,
            "Original"
        )
        XCTAssertEqual(reopened.sourceFormatVersion, 7)
        XCTAssertEqual(try temporaryPackageNames(in: rootURL), [])
    }

    func testV7LowDiskWriteFailureDoesNotCreateOrLeavePartialCompositionPackage() throws {
        let rootURL = temporaryRootURL()
        let packageURL = rootURL
            .appendingPathComponent("Low Disk")
            .appendingPathExtension("sss")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let document = try makeCompositionDocument(title: "Low Disk")
        let failingFiles = FaultInjectingFileService(
            temporaryDirectory: rootURL,
            failure: .write(
                filename: SSSDocumentPackage.baseImageFilename,
                code: CocoaError.Code.fileWriteOutOfSpace
            )
        )

        XCTAssertThrowsError(
            try SSSDocumentPackage.save(
                document: document,
                previewImage: document.capture.image,
                to: packageURL,
                includeUIMapSearchText: true,
                files: failingFiles
            )
        ) { error in
            XCTAssertEqual(
                (error as NSError).domain,
                NSCocoaErrorDomain
            )
            XCTAssertEqual(
                (error as NSError).code,
                CocoaError.Code.fileWriteOutOfSpace.rawValue
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
        XCTAssertEqual(try temporaryPackageNames(in: rootURL), [])
    }

    private func makeCompositionDocument(
        title: String
    ) throws -> EditableScreenshotDocument {
        let firstImage = makeCoordinateImage(width: 48, height: 32)
        let secondImage = makeCoordinateImage(width: 36, height: 54)
        let firstAssetID = UUID()
        let secondAssetID = UUID()
        let firstItem = CompositionItem(
            assetID: firstAssetID,
            editState: ScreenshotEditState(
                cropRect: CGRect(
                    origin: .zero,
                    size: CGSize(
                        width: firstImage.width,
                        height: firstImage.height
                    )
                )
            ),
            title: "First"
        )
        let secondItem = CompositionItem(
            assetID: secondAssetID,
            editState: ScreenshotEditState(
                cropRect: CGRect(
                    origin: .zero,
                    size: CGSize(
                        width: secondImage.width,
                        height: secondImage.height
                    )
                )
            ),
            title: "Second"
        )
        var snapshot = makeEditorSnapshot(
            cropRect: CGRect(
                origin: .zero,
                size: CGSize(width: firstImage.width, height: firstImage.height)
            )
        )
        snapshot.composition = CompositionSnapshot(
            items: [firstItem, secondItem],
            selectedItemIDs: [firstItem.id],
            layout: CompositionLayoutConfiguration(mode: .grid, gridColumns: 2),
            canvas: CompositionCanvasState(title: title)
        )
        return EditableScreenshotDocument(
            capture: makeCapturedScreenshot(
                image: firstImage,
                sourceName: "\(title) Base"
            ),
            session: makeEditorDocumentSession(initialSnapshot: snapshot),
            compositionStoredAssets: [
                try storedAsset(
                    id: firstAssetID,
                    image: firstImage,
                    sourceName: "\(title) First"
                ),
                try storedAsset(
                    id: secondAssetID,
                    image: secondImage,
                    sourceName: "\(title) Second"
                ),
            ]
        )
    }

    private func storedAsset(
        id: UUID,
        image: CGImage,
        sourceName: String
    ) throws -> CompositionStoredAsset {
        CompositionStoredAsset(
            descriptor: CompositionAssetDescriptor(
                id: id,
                pixelWidth: image.width,
                pixelHeight: image.height,
                sourceName: sourceName
            ),
            encodedPNG: try ImageExporter.pngData(for: image)
        )
    }

    private func resolvedArrow(
        annotationID: UUID,
        composition: CompositionSnapshot,
        layout: CompositionRenderLayout
    ) throws -> ArrowShape {
        let resolved = try XCTUnwrap(
            CompositionRenderer.resolvedCanvasAnnotations(
                composition: composition,
                layout: layout
            ).first(where: { $0.id == annotationID })
        )
        guard case .arrow(let shape) = resolved.kind else {
            throw TestFailure.expectedArrow
        }
        return shape
    }

    private func assertItemAnchor(
        _ anchor: CompositionAnnotationAnchor,
        itemID: UUID,
        normalizedPoint: CGPoint,
        cycle: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .itemNormalized(
            let reopenedItemID,
            let reopenedNormalizedPoint
        ) = anchor.target else {
            return XCTFail(
                "Cycle \(cycle): expected an item-normalized anchor.",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(reopenedItemID, itemID, "Cycle \(cycle)", file: file, line: line)
        assertPoint(
            reopenedNormalizedPoint,
            equals: normalizedPoint,
            cycle: cycle,
            endpoint: "normalized anchor",
            accuracy: 1e-12,
            file: file,
            line: line
        )
    }

    private func assertPoint(
        _ actual: CGPoint,
        equals expected: CGPoint,
        cycle: Int,
        endpoint: String,
        accuracy: CGFloat = 1e-9,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual.x,
            expected.x,
            accuracy: accuracy,
            "Cycle \(cycle), \(endpoint) x",
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.y,
            expected.y,
            accuracy: accuracy,
            "Cycle \(cycle), \(endpoint) y",
            file: file,
            line: line
        )
    }

    private func resolvedPoint(
        normalizedPoint: CGPoint,
        in rect: CGRect
    ) -> CGPoint {
        CGPoint(
            x: rect.minX + normalizedPoint.x * rect.width,
            y: rect.minY + normalizedPoint.y * rect.height
        )
    }

    private func temporaryRootURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CompositionPersistenceFailureTests-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func temporaryPackageNames(in rootURL: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
            .filter {
                $0.hasPrefix(SSSDocumentPackage.temporaryDirectoryPrefix)
            }
            .sorted()
    }
}

private enum TestFailure: Error {
    case expectedArrow
}

private final class FaultInjectingFileService:
    FileSystemServicing,
    @unchecked Sendable
{
    nonisolated enum Failure: Sendable {
        case write(filename: String, code: CocoaError.Code)
        case replace(CocoaError.Code)
    }

    nonisolated let temporaryDirectory: URL
    private let failure: Failure
    private let live = SystemFileService()

    nonisolated init(
        temporaryDirectory: URL,
        failure: Failure
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.failure = failure
    }

    nonisolated func fileExists(atPath path: String) -> Bool {
        live.fileExists(atPath: path)
    }

    nonisolated func directoryExists(at url: URL) -> Bool {
        live.directoryExists(at: url)
    }

    nonisolated func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool
    ) throws {
        try live.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates
        )
    }

    nonisolated func removeItem(at url: URL) throws {
        try live.removeItem(at: url)
    }

    nonisolated func copyItem(
        at sourceURL: URL,
        to destinationURL: URL
    ) throws {
        try live.copyItem(at: sourceURL, to: destinationURL)
    }

    nonisolated func moveItem(
        at sourceURL: URL,
        to destinationURL: URL
    ) throws {
        try live.moveItem(at: sourceURL, to: destinationURL)
    }

    nonisolated func replaceItemAt(
        _ originalURL: URL,
        withItemAt newItemURL: URL
    ) throws {
        if case .replace(let code) = failure {
            throw CocoaError(code)
        }
        try live.replaceItemAt(originalURL, withItemAt: newItemURL)
    }

    nonisolated func fileSize(at url: URL) throws -> UInt64 {
        try live.fileSize(at: url)
    }

    nonisolated func readData(from url: URL) throws -> Data {
        try live.readData(from: url)
    }

    nonisolated func readData(
        from url: URL,
        maximumBytes: Int
    ) throws -> Data {
        try live.readData(from: url, maximumBytes: maximumBytes)
    }

    nonisolated func writeData(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions
    ) throws {
        if case .write(let filename, let code) = failure,
           url.lastPathComponent == filename {
            throw CocoaError(code)
        }
        try live.writeData(data, to: url, options: options)
    }
}

import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

final class SSSDocumentTests: XCTestCase {
    func testPackageResavePreservesLegacyCoordinateDescriptor() throws {
        let baseImage = makeCoordinateImage(width: 20, height: 16)
        let capture = makeCapturedScreenshot(
            image: baseImage,
            bounds: CGRect(x: 80, y: 120, width: 20, height: 16),
            coordinateContract: .legacyDocumentPackageV1ToV3
        )
        let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 20, height: 16))
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")

        try SSSDocumentPackage.save(
            document: makeEditableDocument(capture: capture, session: makeEditorDocumentSession(initialSnapshot: snapshot)),
            previewImage: baseImage,
            to: packageURL
        )
        let loaded = try SSSDocumentPackage.load(from: packageURL)

        XCTAssertEqual(loaded.capture.coordinateContract, .legacyDocumentPackageV1ToV3)

        try? FileManager.default.removeItem(at: packageURL)
    }

    func testPackageRoundTripsScrollingCaptureKind() throws {
        let baseImage = makeCoordinateImage(width: 48, height: 96, pattern: .weighted(xMultiplier: 5, yMultiplier: 7, includeBlueSum: true))
        let capture = makeCapturedScreenshot(
            image: baseImage,
            kind: .scrolling,
            sourceName: "Scrolling Capture - Safari",
            bounds: CGRect(x: 80, y: 120, width: 48, height: 320),
            capturedAt: Date(timeIntervalSince1970: 1_818_000_000)
        )
        let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 48, height: 96))
        let document = makeEditableDocument(capture: capture, session: makeEditorDocumentSession(initialSnapshot: snapshot))
        let previewImage = try XCTUnwrap(EditorRenderer.render(baseImage: baseImage, snapshot: snapshot))
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")

        try SSSDocumentPackage.save(document: document, previewImage: previewImage, to: packageURL)
        let loaded = try SSSDocumentPackage.load(from: packageURL)

        XCTAssertEqual(loaded.capture.kind, .scrolling)
        XCTAssertEqual(loaded.capture.sourceName, "Scrolling Capture - Safari")
        XCTAssertEqual(loaded.capture.sourceRect, capture.sourceRect)
        XCTAssertEqual(loaded.capture.coordinateContract, .current)

        try? FileManager.default.removeItem(at: packageURL)
    }

    func testPackageRoundTripsUIMapMetadata() throws {
        let baseImage = makeCoordinateImage(width: 80, height: 60, pattern: .weighted(xMultiplier: 5, yMultiplier: 7, includeBlueSum: true))
        let pinnedElementID = UUID()
        let uiMap = UIMapSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_818_333_333),
            sourceRect: CGRect(x: 200, y: 300, width: 80, height: 60),
            elements: [
                UIMapElement(
                    name: "Preferences",
                    role: "AXWindow",
                    roleDescription: "Window",
                    documentRect: CGRect(x: 0, y: 0, width: 80, height: 60),
                    owningApplication: "Fixture",
                    bundleIdentifier: "com.example.fixture",
                    children: [
                        UIMapElement(
                            id: pinnedElementID,
                            name: "Enable UI Map",
                            accessibilityLabel: "Enable UI Map",
                            accessibilityIdentifier: "enable-ui-map",
                            role: "AXCheckBox",
                            roleDescription: "Checkbox",
                            documentRect: CGRect(x: 12, y: 14, width: 32, height: 18),
                            owningApplication: "Fixture",
                            bundleIdentifier: "com.example.fixture"
                        )
                    ]
                )
            ]
        )
        let capture = makeCapturedScreenshot(
            image: baseImage,
            sourceName: "Fixture Window",
            bounds: CGRect(x: 200, y: 300, width: 80, height: 60),
            capturedAt: Date(timeIntervalSince1970: 1_818_333_330),
            uiMap: uiMap
        )
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 80, height: 60),
            pinnedUIMapElementIDs: [pinnedElementID]
        )
        let document = makeEditableDocument(capture: capture, session: makeEditorDocumentSession(initialSnapshot: snapshot))
        let previewImage = try XCTUnwrap(EditorRenderer.render(baseImage: baseImage, snapshot: snapshot))
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")

        try SSSDocumentPackage.save(document: document, previewImage: previewImage, to: packageURL)
        let loaded = try SSSDocumentPackage.load(from: packageURL)
        let manifestData = try Data(contentsOf: packageURL.appendingPathComponent("document.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let captureRecord = try XCTUnwrap(manifest["capture"] as? [String: Any])

        XCTAssertNotNil(captureRecord["uiMap"])
        XCTAssertEqual(loaded.capture.uiMap, uiMap)
        XCTAssertEqual(loaded.session.currentSnapshot.pinnedUIMapElementIDs, [pinnedElementID])
        XCTAssertTrue(SSSDocumentPackage.loadSearchableText(from: packageURL).contains("Enable UI Map"))

        try? FileManager.default.removeItem(at: packageURL)
    }

    func testPackagePreservesUIMapMetadataWithoutIndexingWhenDisabled() throws {
        let baseImage = makeCoordinateImage(width: 80, height: 60, pattern: .weighted(xMultiplier: 5, yMultiplier: 7, includeBlueSum: true))
        let uiMap = UIMapSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_818_333_333),
            sourceRect: CGRect(x: 200, y: 300, width: 80, height: 60),
            elements: [
                UIMapElement(
                    name: "Sensitive Toggle",
                    role: "AXCheckBox",
                    roleDescription: "Checkbox",
                    documentRect: CGRect(x: 12, y: 14, width: 32, height: 18),
                    owningApplication: "Fixture",
                    bundleIdentifier: "com.example.fixture"
                )
            ]
        )
        let capture = makeCapturedScreenshot(
            image: baseImage,
            sourceName: "Fixture Window",
            bounds: CGRect(x: 200, y: 300, width: 80, height: 60),
            capturedAt: Date(timeIntervalSince1970: 1_818_333_330),
            uiMap: uiMap
        )
        let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 80, height: 60))
        let document = makeEditableDocument(capture: capture, session: makeEditorDocumentSession(initialSnapshot: snapshot))
        let previewImage = try XCTUnwrap(EditorRenderer.render(baseImage: baseImage, snapshot: snapshot))
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")

        try SSSDocumentPackage.save(
            document: document,
            previewImage: previewImage,
            to: packageURL,
            includeUIMapSearchText: false
        )
        let loaded = try SSSDocumentPackage.load(from: packageURL)

        XCTAssertEqual(loaded.capture.uiMap, uiMap)
        XCTAssertFalse(SSSDocumentPackage.loadSearchableText(from: packageURL).contains("Sensitive Toggle"))

        try? FileManager.default.removeItem(at: packageURL)
    }

    func testPackageRoundTripsCaptureSessionAndHistory() throws {
        let baseImage = makeCoordinateImage(width: 48, height: 32, pattern: .weighted(xMultiplier: 5, yMultiplier: 7, includeBlueSum: true))
        let capture = makeCapturedScreenshot(
            image: baseImage,
            sourceName: "Primary Display",
            bounds: CGRect(x: 80, y: 120, width: 48, height: 32),
            capturedAt: Date(timeIntervalSince1970: 1_717_171_717)
        )

        var rectangleStyle = AnnotationStyle.default(for: .rectangle)
        rectangleStyle.lineWidth = 7
        let rectangle = Annotation.makeRectangle(in: CGRect(x: 4, y: 5, width: 18, height: 10), style: rectangleStyle)
        let callout = Annotation.makeCallout(at: CGPoint(x: 20, y: 12), number: 3).updatingText("Step 3")

        let initialSnapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 48, height: 32),
            annotations: [],
            selectedAnnotationIDs: []
        )
        let intermediateSnapshot = makeEditorSnapshot(
            cropRect: initialSnapshot.cropRect,
            annotations: [rectangle],
            selectedAnnotationIDs: [rectangle.id]
        )
        let currentSnapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 2, y: 3, width: 42, height: 25),
            annotations: [rectangle, callout],
            selectedAnnotationIDs: [rectangle.id, callout.id],
            nextCalloutNumber: 4
        )

        var toolStyles = makeDefaultToolStyles()
        var textStyle = toolStyles[.text] ?? .default(for: .text)
        textStyle.fontSize = 34
        toolStyles[.text] = textStyle

        let session = makeEditorDocumentSession(
            initialSnapshot: initialSnapshot,
            currentSnapshot: currentSnapshot,
            undoStack: [initialSnapshot, intermediateSnapshot],
            redoStack: [intermediateSnapshot],
            toolStyles: toolStyles
        )
        let document = makeEditableDocument(capture: capture, session: session)
        let previewImage = try XCTUnwrap(EditorRenderer.render(baseImage: baseImage, snapshot: currentSnapshot))
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")

        try SSSDocumentPackage.save(document: document, previewImage: previewImage, to: packageURL)
        let loaded = try SSSDocumentPackage.load(from: packageURL)

        XCTAssertEqual(loaded.capture.kind, capture.kind)
        XCTAssertEqual(loaded.capture.sourceName, capture.sourceName)
        XCTAssertEqual(loaded.capture.sourceRect, capture.sourceRect)
        XCTAssertEqual(loaded.capture.coordinateContract, .current)
        XCTAssertEqual(loaded.capture.capturedAt, capture.capturedAt)
        XCTAssertEqual(loaded.capture.image.width, capture.image.width)
        XCTAssertEqual(loaded.capture.image.height, capture.image.height)
        XCTAssertEqual(loaded.session, session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("document.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("base.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("preview.png").path))
        XCTAssertEqual(SSSDocumentPackage.previewAssetURL(in: packageURL), packageURL.appendingPathComponent("preview.png"))

        let loadedPreview = try XCTUnwrap(SSSDocumentPackage.loadPreviewImage(from: packageURL))
        XCTAssertEqual(loadedPreview.width, previewImage.width)
        XCTAssertEqual(loadedPreview.height, previewImage.height)
        XCTAssertEqual(samplePixel(in: loadedPreview, topLeftX: 3, topLeftY: 4), samplePixel(in: previewImage, topLeftX: 3, topLeftY: 4))
        XCTAssertEqual(samplePixel(in: loadedPreview, topLeftX: 20, topLeftY: 10), samplePixel(in: previewImage, topLeftX: 20, topLeftY: 10))
        let loadedCallout = try XCTUnwrap(loaded.session.currentSnapshot.annotations.last)
        XCTAssertEqual(loadedCallout.textAlignmentMode, .left)

        try? FileManager.default.removeItem(at: packageURL)
    }

    func testPackageRoundTripsTextAlignment() throws {
        let baseImage = makeCoordinateImage(width: 40, height: 30, pattern: .weighted(xMultiplier: 5, yMultiplier: 7, includeBlueSum: true))
        let capture = makeCapturedScreenshot(
            image: baseImage,
            sourceName: "Primary Display",
            bounds: CGRect(x: 0, y: 0, width: 40, height: 30),
            capturedAt: Date(timeIntervalSince1970: 1_717_171_717)
        )
        let text = Annotation.makeText(at: CGPoint(x: 6, y: 8)).updatingTextAlignment(.center)
        let callout = Annotation.makeCallout(at: CGPoint(x: 8, y: 10), number: 2).updatingTextAlignment(.right)
        let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 40, height: 30), annotations: [text, callout], selectedAnnotationIDs: [text.id], nextCalloutNumber: 3)
        let document = makeEditableDocument(capture: capture, session: makeEditorDocumentSession(initialSnapshot: snapshot))
        let previewImage = try XCTUnwrap(EditorRenderer.render(baseImage: baseImage, snapshot: snapshot))
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")

        try SSSDocumentPackage.save(document: document, previewImage: previewImage, to: packageURL)
        let loaded = try SSSDocumentPackage.load(from: packageURL)

        XCTAssertEqual(loaded.session.currentSnapshot.annotations[0].textAlignmentMode, .center)
        XCTAssertEqual(loaded.session.currentSnapshot.annotations[1].textAlignmentMode, .right)

        try? FileManager.default.removeItem(at: packageURL)
    }

    func testPackageRoundTripsV4RotationAndImageOverlayAssets() throws {
        let baseImage = makeCoordinateImage(width: 60, height: 44, pattern: .weighted(xMultiplier: 5, yMultiplier: 7, includeBlueSum: true))
        let capture = makeCapturedScreenshot(
            image: baseImage,
            sourceName: "Overlay Source",
            bounds: CGRect(x: 0, y: 0, width: 60, height: 44),
            capturedAt: Date(timeIntervalSince1970: 1_818_181_818)
        )
        let overlayID = UUID()
        let overlayImage = makeSolidImage(width: 8, height: 6, color: PixelSample(red: 210, green: 20, blue: 40, alpha: 255))
        let overlay = Annotation.makeImageOverlay(
            image: overlayImage,
            in: CGRect(x: 12, y: 10, width: 16, height: 12),
            assetID: overlayID,
            role: .capturedCursor
        ).updatingRotationDegrees(30)
        let measurement = Annotation.makeMeasurement(from: CGPoint(x: 4, y: 6), to: CGPoint(x: 34, y: 46))
            .updatingRotationDegrees(-15)
        let spotlight = Annotation.makeSpotlight(in: CGRect(x: 8, y: 8, width: 28, height: 20))
            .updatingRotationDegrees(10)
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 60, height: 44),
            annotations: [overlay, measurement, spotlight],
            selectedAnnotationIDs: [overlay.id]
        )
        let document = makeEditableDocument(capture: capture, session: makeEditorDocumentSession(initialSnapshot: snapshot))
        let previewImage = try XCTUnwrap(EditorRenderer.render(baseImage: baseImage, snapshot: snapshot))
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")

        try SSSDocumentPackage.save(document: document, previewImage: previewImage, to: packageURL)
        let manifestData = try Data(contentsOf: packageURL.appendingPathComponent("document.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let assets = try XCTUnwrap(manifest["assets"] as? [String: Any])
        let imageOverlays = try XCTUnwrap(assets["imageOverlays"] as? [[String: Any]])
        let firstOverlay = try XCTUnwrap(imageOverlays.first)
        let assetFilename = try XCTUnwrap(firstOverlay["filename"] as? String)
        let coordinateContract = try XCTUnwrap(manifest["coordinateContract"] as? [String: String])
        let captureRecord = try XCTUnwrap(manifest["capture"] as? [String: Any])
        let loaded = try SSSDocumentPackage.load(from: packageURL)

        XCTAssertEqual(manifest["formatVersion"] as? Int, 6)
        XCTAssertEqual(coordinateContract["captureSourceRectSpace"], CoordinateSpaceDescriptor.captureGlobalPointsTopLeftYDownV2.rawValue)
        XCTAssertEqual(coordinateContract["overlayScreenSpace"], CoordinateSpaceDescriptor.overlayScreenPointsYUpV1.rawValue)
        XCTAssertEqual(coordinateContract["overlayLocalSpace"], CoordinateSpaceDescriptor.overlayLocalPointsYDownV1.rawValue)
        XCTAssertEqual(coordinateContract["previewPixelSpace"], CoordinateSpaceDescriptor.previewPixelsTopLeftV1.rawValue)
        XCTAssertEqual(coordinateContract["documentImageSpace"], CoordinateSpaceDescriptor.documentPixelsTopLeftV1.rawValue)
        XCTAssertEqual(coordinateContract["annotationGeometrySpace"], CoordinateSpaceDescriptor.documentPixelsTopLeftV1.rawValue)
        XCTAssertEqual(coordinateContract["cropRectSpace"], CoordinateSpaceDescriptor.documentPixelsTopLeftV1.rawValue)
        XCTAssertEqual(coordinateContract["renderOutputSpace"], CoordinateSpaceDescriptor.renderOutputPixelsTopLeftV1.rawValue)
        XCTAssertEqual(coordinateContract["accessibilityScreenSpace"], CoordinateSpaceDescriptor.accessibilityScreenPointsYUpV1.rawValue)
        XCTAssertNotNil(captureRecord["sourceRect"])
        XCTAssertNil(captureRecord["bounds"])
        XCTAssertEqual(firstOverlay["id"] as? String, overlayID.uuidString)
        XCTAssertEqual(assetFilename, "assets/image-overlays/\(overlayID.uuidString).png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent(assetFilename).path))
        XCTAssertEqual(loaded.session.currentSnapshot.annotations.map(\.rotationDegrees), [30, -15, 10])

        guard case let .imageOverlay(loadedOverlay) = loaded.session.currentSnapshot.annotations.first?.kind else {
            return XCTFail("Expected loaded image overlay")
        }

        XCTAssertEqual(loadedOverlay.assetID, overlayID)
        XCTAssertEqual(loadedOverlay.image.width, overlayImage.width)
        XCTAssertEqual(loadedOverlay.image.height, overlayImage.height)
        XCTAssertEqual(loadedOverlay.role, .capturedCursor)

        try? FileManager.default.removeItem(at: packageURL)
    }

    func testPackageRoundTripsPresentationSettings() throws {
        let baseImage = makeCoordinateImage(width: 72, height: 48, pattern: .weighted(xMultiplier: 5, yMultiplier: 7, includeBlueSum: true))
        let capture = makeCapturedScreenshot(
            image: baseImage,
            sourceName: "Presentation Source",
            bounds: CGRect(x: 0, y: 0, width: 72, height: 48),
            capturedAt: Date(timeIntervalSince1970: 1_818_222_222)
        )
        var presentation = ScreenshotPresentationPreset.transparentShadow.settings
        presentation.shadowBlurRadius = 72
        presentation.shadowOffsetY = 34
        presentation.shadowOpacity = 0.48

        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 72, height: 48),
            presentation: presentation
        )
        let document = makeEditableDocument(capture: capture, session: makeEditorDocumentSession(initialSnapshot: snapshot))
        let previewImage = try XCTUnwrap(ScreenshotPresentationRenderer.render(baseImage: baseImage, snapshot: snapshot))
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")

        try SSSDocumentPackage.save(document: document, previewImage: previewImage, to: packageURL)
        let loaded = try SSSDocumentPackage.load(from: packageURL)

        XCTAssertEqual(loaded.session.currentSnapshot.presentation, presentation)

        let loadedPreview = try XCTUnwrap(SSSDocumentPackage.loadPreviewImage(from: packageURL))
        XCTAssertEqual(loadedPreview.width, previewImage.width)
        XCTAssertEqual(loadedPreview.height, previewImage.height)

        try? FileManager.default.removeItem(at: packageURL)
    }

    func testPackageRoundTripsArrowAndCalloutPresentationFields() throws {
        let baseImage = makeCoordinateImage(width: 80, height: 60, pattern: .weighted(xMultiplier: 5, yMultiplier: 7, includeBlueSum: true))
        let capture = makeCapturedScreenshot(
            image: baseImage,
            sourceName: "Markup Window",
            bounds: CGRect(x: 0, y: 0, width: 80, height: 60),
            capturedAt: Date(timeIntervalSince1970: 1_818_111_111)
        )
        let arrow = Annotation.makeArrow(from: CGPoint(x: 8, y: 12), to: CGPoint(x: 64, y: 42))
            .updatingArrow(
                curvature: 42,
                headStyle: .double,
                label: "Sync",
                labelBoxColor: .highlightFill,
                labelPlacement: .parallelAbove,
                labelFontSize: 18,
                labelTextColor: .complementary,
                headShape: .diamond
            )
        let callout = Annotation.makeCallout(at: CGPoint(x: 14, y: 10), number: 2)
            .updatingCalloutStyle(.outlined)
            .updatingText("Review this state")
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 80, height: 60),
            annotations: [arrow, callout],
            selectedAnnotationIDs: [arrow.id]
        )
        let document = makeEditableDocument(capture: capture, session: makeEditorDocumentSession(initialSnapshot: snapshot))
        let previewImage = try XCTUnwrap(EditorRenderer.render(baseImage: baseImage, snapshot: snapshot))
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")

        try SSSDocumentPackage.save(document: document, previewImage: previewImage, to: packageURL)
        let loaded = try SSSDocumentPackage.load(from: packageURL)

        let loadedAnnotations = loaded.session.currentSnapshot.annotations
        XCTAssertEqual(loadedAnnotations.count, 2)

        guard let first = loadedAnnotations.first,
              let second = loadedAnnotations.dropFirst().first,
              case let .arrow(loadedArrow) = first.kind
        else {
            return XCTFail("Expected arrow annotation")
        }
        guard case let .callout(loadedCallout) = second.kind else {
            return XCTFail("Expected callout annotation")
        }

        XCTAssertEqual(loadedArrow.headStyle, .double)
        XCTAssertEqual(loadedArrow.curvature, 42)
        XCTAssertEqual(loadedArrow.label, "Sync")
        XCTAssertEqual(loadedArrow.labelBoxColor, .highlightFill)
        XCTAssertEqual(loadedArrow.labelPlacement, .parallelAbove)
        XCTAssertEqual(loadedArrow.labelFontSize, 18)
        XCTAssertEqual(loadedArrow.labelTextColor, .complementary)
        XCTAssertEqual(loadedArrow.headShape, .diamond)
        XCTAssertEqual(loadedCallout.style, .outlined)
        XCTAssertEqual(loadedCallout.leaderPoint, CGPoint(x: 14, y: 10))

        try? FileManager.default.removeItem(at: packageURL)
    }

    func testPackageRoundTripsHighlighterAnnotations() throws {
        let baseImage = makeCoordinateImage(width: 64, height: 48, pattern: .weighted(xMultiplier: 5, yMultiplier: 7, includeBlueSum: true))
        let capture = makeCapturedScreenshot(
            image: baseImage,
            sourceName: "Highlight Source",
            bounds: CGRect(x: 0, y: 0, width: 64, height: 48),
            capturedAt: Date(timeIntervalSince1970: 1_818_333_333)
        )
        let highlighter = Annotation.makeHighlighter(
            points: [CGPoint(x: 6, y: 16), CGPoint(x: 22, y: 18), CGPoint(x: 42, y: 17)],
            style: .default(for: .highlighter)
        )
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 64, height: 48),
            annotations: [highlighter],
            selectedAnnotationIDs: [highlighter.id]
        )
        let document = makeEditableDocument(capture: capture, session: makeEditorDocumentSession(initialSnapshot: snapshot))
        let previewImage = try XCTUnwrap(EditorRenderer.render(baseImage: baseImage, snapshot: snapshot))
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")

        try SSSDocumentPackage.save(document: document, previewImage: previewImage, to: packageURL)
        let loaded = try SSSDocumentPackage.load(from: packageURL)

        guard case let .highlighter(shape) = loaded.session.currentSnapshot.annotations.first?.kind else {
            return XCTFail("Expected highlighter annotation")
        }

        XCTAssertEqual(shape.points, [CGPoint(x: 6, y: 16), CGPoint(x: 22, y: 18), CGPoint(x: 42, y: 17)])
        XCTAssertEqual(loaded.session.currentSnapshot.annotations.first?.editorTool, .highlighter)

        try? FileManager.default.removeItem(at: packageURL)
    }

    func testDisplayPreviewFallsBackWhenStoredPreviewSizeIsWrong() throws {
        let baseImage = makeCoordinateImage(width: 48, height: 32, pattern: .weighted(xMultiplier: 5, yMultiplier: 7, includeBlueSum: true))
        let capture = makeCapturedScreenshot(
            image: baseImage,
            sourceName: "Primary Display",
            bounds: CGRect(x: 0, y: 0, width: 48, height: 32),
            capturedAt: Date(timeIntervalSince1970: 1_717_171_717)
        )
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 48, height: 32),
            annotations: [],
            selectedAnnotationIDs: []
        )
        let document = makeEditableDocument(capture: capture, session: makeEditorDocumentSession(initialSnapshot: snapshot))
        let correctPreview = try XCTUnwrap(EditorRenderer.render(baseImage: baseImage, snapshot: snapshot))
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")

        try SSSDocumentPackage.save(document: document, previewImage: correctPreview, to: packageURL)

        let mismatchedPreview = makeCoordinateImage(width: 96, height: 64)
        let mismatchedPreviewData = try ImageExporter.pngData(for: mismatchedPreview)
        try mismatchedPreviewData.write(to: packageURL.appendingPathComponent("preview.png"), options: .atomic)

        let loadedDisplayPreview = try XCTUnwrap(SSSDocumentPackage.loadDisplayPreview(from: packageURL))

        XCTAssertEqual(loadedDisplayPreview.source, "rerendered-package")

        XCTAssertEqual(loadedDisplayPreview.image.width, correctPreview.width)
        XCTAssertEqual(loadedDisplayPreview.image.height, correctPreview.height)
        XCTAssertEqual(samplePixel(in: loadedDisplayPreview.image, topLeftX: 4, topLeftY: 5), samplePixel(in: correctPreview, topLeftX: 4, topLeftY: 5))
        XCTAssertEqual(samplePixel(in: loadedDisplayPreview.image, topLeftX: 20, topLeftY: 10), samplePixel(in: correctPreview, topLeftX: 20, topLeftY: 10))

        try? FileManager.default.removeItem(at: packageURL)
    }

    func testPackagePersistsAndUpdatesSearchMetadata() throws {
        let baseImage = makeCoordinateImage(width: 40, height: 30, pattern: .weighted(xMultiplier: 3, yMultiplier: 11, includeBlueSum: true))
        let capture = makeCapturedScreenshot(
            image: baseImage,
            sourceName: "Release Notes Window",
            bounds: CGRect(x: 12, y: 18, width: 40, height: 30),
            capturedAt: Date(timeIntervalSince1970: 1_818_181_818)
        )
        let text = Annotation.makeText(at: CGPoint(x: 4, y: 6)).updatingText("Important heading")
        let callout = Annotation.makeCallout(at: CGPoint(x: 12, y: 10), number: 5).updatingText("Investigate upload flow")
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 40, height: 30),
            annotations: [text, callout],
            selectedAnnotationIDs: [text.id],
            nextCalloutNumber: 6
        )
        let session = makeEditorDocumentSession(initialSnapshot: snapshot)
        let document = makeEditableDocument(capture: capture, session: session)
        let previewImage = try XCTUnwrap(EditorRenderer.render(baseImage: baseImage, snapshot: snapshot))
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")

        try SSSDocumentPackage.save(document: document, previewImage: previewImage, to: packageURL)

        let initialSearchText = SSSDocumentPackage.loadSearchableText(from: packageURL)
        XCTAssertTrue(initialSearchText.contains("Release Notes Window"))
        XCTAssertTrue(initialSearchText.contains("Important heading"))
        XCTAssertTrue(initialSearchText.contains("Investigate upload flow"))
        XCTAssertTrue(initialSearchText.contains("Callout 5"))

        _ = try SSSDocumentPackage.updateRecognizedText("Button Save and Share", in: packageURL)

        let updatedSearchText = SSSDocumentPackage.loadSearchableText(from: packageURL)
        XCTAssertTrue(updatedSearchText.contains("Release Notes Window"))
        XCTAssertTrue(updatedSearchText.contains("Important heading"))
        XCTAssertTrue(updatedSearchText.contains("Button Save and Share"))

        try? FileManager.default.removeItem(at: packageURL)
    }

    func testPackageLoadsLegacyBoundsFieldIntoSourceRectContract() throws {
        let baseImage = makeCoordinateImage(width: 32, height: 24)
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")

        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let baseImageData = try ImageExporter.pngData(for: baseImage)
        try baseImageData.write(to: packageURL.appendingPathComponent("base.png"), options: .atomic)
        try baseImageData.write(to: packageURL.appendingPathComponent("preview.png"), options: .atomic)

        let manifest = """
        {
          "assets" : {
            "baseImage" : "base.png",
            "previewImage" : "preview.png"
          },
          "capture" : {
            "bounds" : {
              "height" : 24,
              "width" : 32,
              "x" : 40,
              "y" : 50
            },
            "capturedAt" : "2027-08-15T17:11:22Z",
            "kind" : "region",
            "sourceName" : "Legacy Bounds"
          },
          "formatIdentifier" : "\(SSSDocumentPackage.formatIdentifier)",
          "formatVersion" : 3,
          "savedAt" : "2027-08-15T17:11:22Z",
          "session" : {
            "currentSnapshot" : {
              "annotations" : [],
              "cropRect" : {
                "height" : 24,
                "width" : 32,
                "x" : 0,
                "y" : 0
              },
              "nextCalloutNumber" : 1,
              "selectedAnnotationIDs" : []
            },
            "initialSnapshot" : {
              "annotations" : [],
              "cropRect" : {
                "height" : 24,
                "width" : 32,
                "x" : 0,
                "y" : 0
              },
              "nextCalloutNumber" : 1,
              "selectedAnnotationIDs" : []
            },
            "redoStack" : [],
            "toolStyles" : [],
            "undoStack" : []
          }
        }
        """
        try Data(manifest.utf8).write(to: packageURL.appendingPathComponent("document.json"), options: .atomic)

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: packageURL)) { error in
            guard case SSSDocumentError.unsupportedFormatVersion(3) = error else {
                return XCTFail("Expected unsupported format version 3, got \(error)")
            }
        }
    }

    func testVersion4PackageWithoutPersistedCoordinateContractIsRejected() throws {
        let baseImage = makeCoordinateImage(width: 32, height: 24)
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")

        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let baseImageData = try ImageExporter.pngData(for: baseImage)
        try baseImageData.write(to: packageURL.appendingPathComponent("base.png"), options: .atomic)
        try baseImageData.write(to: packageURL.appendingPathComponent("preview.png"), options: .atomic)

        let manifest = """
        {
          "assets" : {
            "baseImage" : "base.png",
            "previewImage" : "preview.png"
          },
          "capture" : {
            "capturedAt" : "2027-08-15T17:11:22Z",
            "kind" : "region",
            "sourceName" : "Missing Contract",
            "sourceRect" : {
              "height" : 24,
              "width" : 32,
              "x" : 40,
              "y" : 50
            }
          },
          "formatIdentifier" : "\(SSSDocumentPackage.formatIdentifier)",
          "formatVersion" : 4,
          "savedAt" : "2027-08-15T17:11:22Z",
          "session" : {
            "currentSnapshot" : {
              "annotations" : [],
              "cropRect" : {
                "height" : 24,
                "width" : 32,
                "x" : 0,
                "y" : 0
              },
              "nextCalloutNumber" : 1,
              "selectedAnnotationIDs" : []
            },
            "initialSnapshot" : {
              "annotations" : [],
              "cropRect" : {
                "height" : 24,
                "width" : 32,
                "x" : 0,
                "y" : 0
              },
              "nextCalloutNumber" : 1,
              "selectedAnnotationIDs" : []
            },
            "redoStack" : [],
            "toolStyles" : [],
            "undoStack" : []
          }
        }
        """
        try Data(manifest.utf8).write(to: packageURL.appendingPathComponent("document.json"), options: .atomic)

        XCTAssertThrowsError(try SSSDocumentPackage.load(from: packageURL)) { error in
            guard case SSSDocumentError.unsupportedFormatVersion(4) = error else {
                return XCTFail("Expected unsupported format version 4, got \(error)")
            }
        }
    }

    func testTemporaryPackageCleanupRemovesOnlySnipSnipSnipStagingDirectories() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let screenshotDirectory = tempRoot.appendingPathComponent("\(SSSDocumentPackage.temporaryDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        let videoDirectory = tempRoot.appendingPathComponent("\(SSSVideoDocumentPackage.temporaryDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        let unrelatedDirectory = tempRoot.appendingPathComponent("keep-me", isDirectory: true)
        let recordingFile = tempRoot.appendingPathComponent("\(TemporaryVideoMediaManager.recordingPrefix)\(UUID().uuidString)").appendingPathExtension("mp4")
        let legacyRecordingFile = tempRoot.appendingPathComponent("\(TemporaryVideoMediaManager.recordingPrefix)\(UUID().uuidString)").appendingPathExtension("mov")
        let unrelatedFile = tempRoot.appendingPathComponent("keep-me.mp4")

        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        for directoryURL in [screenshotDirectory, videoDirectory, unrelatedDirectory] {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: directoryURL.appendingPathComponent("marker.txt"), options: .atomic)
        }
        try Data("video".utf8).write(to: recordingFile, options: .atomic)
        try Data("video".utf8).write(to: legacyRecordingFile, options: .atomic)
        try Data("video".utf8).write(to: unrelatedFile, options: .atomic)

        try PackageTemporaryDirectoryJanitor.cleanupStalePackageTemporaryDirectories(fileManager: fileManager, in: tempRoot)

        XCTAssertFalse(fileManager.fileExists(atPath: screenshotDirectory.path))
        XCTAssertFalse(fileManager.fileExists(atPath: videoDirectory.path))
        XCTAssertTrue(fileManager.fileExists(atPath: recordingFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: legacyRecordingFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedDirectory.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedFile.path))
    }
}

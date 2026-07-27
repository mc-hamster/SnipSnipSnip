import CoreGraphics
import Foundation
@testable import SnipSnipSnip

/// Writes the exact package shape emitted by `SSSDocumentPackage` v6.
///
/// This deliberately does not call the current document writer and remove v7
/// fields afterward. Keeping a small legacy writer in the migration tests
/// makes the fixture independent from whatever the current encoder adds next.
nonisolated enum LegacyV6FixtureWriter {
    static func write(
        capture: CapturedScreenshot,
        session: EditorDocumentSession,
        overlayAssets: [UUID: CGImage],
        previewImage: CGImage,
        to packageURL: URL
    ) throws {
        let overlayRecords = overlayAssets.keys
            .sorted { $0.uuidString < $1.uuidString }
            .map {
                LegacyV6ImageOverlayAssetRecord(
                    id: $0,
                    filename:
                        "assets/image-overlays/\($0.uuidString).png"
                )
            }
        let manifest = LegacyV6Manifest(
            formatIdentifier: SSSDocumentPackage.formatIdentifier,
            formatVersion: SSSDocumentPackage.legacyFormatVersion,
            savedAt: Date(timeIntervalSince1970: 1_700_000_063),
            coordinateContract: capture.coordinateContract,
            assets: LegacyV6Assets(
                baseImage: SSSDocumentPackage.baseImageFilename,
                previewImage: SSSDocumentPackage.previewImageFilename,
                imageOverlays: overlayRecords.isEmpty
                    ? nil
                    : overlayRecords
            ),
            capture: LegacyV6CaptureRecord(capture),
            session: LegacyV6SessionRecord(session),
            metadata: LegacyV6Metadata(
                search: LegacyV6SearchMetadata(
                    annotationText: "Legacy text\nLegacy callout\nLegacy arrow",
                    recognizedText: "Version six OCR",
                    searchableText:
                        "Representative Version Six Legacy text Legacy callout Legacy arrow Version six OCR"
                )
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]

        let files = FileManager.default
        try? files.removeItem(at: packageURL)
        try files.createDirectory(
            at: packageURL,
            withIntermediateDirectories: false
        )
        try ImageExporter.pngData(for: capture.image).write(
            to: packageURL.appendingPathComponent(
                SSSDocumentPackage.baseImageFilename
            ),
            options: .atomic
        )
        try ImageExporter.pngData(for: previewImage).write(
            to: packageURL.appendingPathComponent(
                SSSDocumentPackage.previewImageFilename
            ),
            options: .atomic
        )
        if !overlayAssets.isEmpty {
            let overlayDirectory = packageURL.appendingPathComponent(
                SSSDocumentPackage.imageOverlayAssetsDirectoryName,
                isDirectory: true
            )
            try files.createDirectory(
                at: overlayDirectory,
                withIntermediateDirectories: true
            )
            for (assetID, image) in overlayAssets {
                try ImageExporter.pngData(for: image).write(
                    to: overlayDirectory
                        .appendingPathComponent(assetID.uuidString)
                        .appendingPathExtension("png"),
                    options: .atomic
                )
            }
        }
        try encoder.encode(manifest).write(
            to: packageURL.appendingPathComponent(
                SSSDocumentPackage.manifestFilename
            ),
            options: .atomic
        )
    }
}

nonisolated private struct LegacyV6Manifest: Encodable {
    var formatIdentifier: String
    var formatVersion: Int
    var savedAt: Date
    var coordinateContract: DocumentCoordinateContract
    var assets: LegacyV6Assets
    var capture: LegacyV6CaptureRecord
    var session: LegacyV6SessionRecord
    var metadata: LegacyV6Metadata?
}

nonisolated private struct LegacyV6Assets: Encodable {
    var baseImage: String
    var previewImage: String
    var imageOverlays: [LegacyV6ImageOverlayAssetRecord]?
}

nonisolated private struct LegacyV6ImageOverlayAssetRecord: Encodable {
    var id: UUID
    var filename: String
}

nonisolated private struct LegacyV6Metadata: Encodable {
    var search: LegacyV6SearchMetadata?
}

nonisolated private struct LegacyV6SearchMetadata: Encodable {
    var annotationText: String
    var recognizedText: String?
    var searchableText: String
}

nonisolated private struct LegacyV6CaptureRecord: Encodable {
    var kind: String
    var sourceName: String
    var sourceRect: LegacyV6RectRecord
    var capturedAt: Date
    var uiMap: UIMapSnapshot?

    init(_ capture: CapturedScreenshot) {
        kind = capture.kind.rawValue
        sourceName = capture.sourceName
        sourceRect = LegacyV6RectRecord(capture.sourceRect)
        capturedAt = capture.capturedAt
        uiMap = capture.uiMap
    }
}

nonisolated private struct LegacyV6SessionRecord: Encodable {
    var initialSnapshot: LegacyV6SnapshotRecord
    var currentSnapshot: LegacyV6SnapshotRecord
    var undoStack: [LegacyV6SnapshotRecord]
    var redoStack: [LegacyV6SnapshotRecord]
    var toolStyles: [LegacyV6ToolStyleRecord]
    var savedPresentations: [SavedPresentation]?

    init(_ session: EditorDocumentSession) {
        initialSnapshot = LegacyV6SnapshotRecord(session.initialSnapshot)
        currentSnapshot = LegacyV6SnapshotRecord(session.currentSnapshot)
        undoStack = session.undoStack.map(LegacyV6SnapshotRecord.init)
        redoStack = session.redoStack.map(LegacyV6SnapshotRecord.init)
        toolStyles = EditorTool.allCases.map {
            LegacyV6ToolStyleRecord(
                tool: $0.rawValue,
                style: LegacyV6StyleRecord(
                    session.toolStyles[$0] ?? .default(for: $0)
                )
            )
        }
        savedPresentations = session.savedPresentations.isEmpty
            ? nil
            : session.savedPresentations
    }
}

nonisolated private struct LegacyV6ToolStyleRecord: Encodable {
    var tool: String
    var style: LegacyV6StyleRecord
}

nonisolated private struct LegacyV6SnapshotRecord: Encodable {
    var cropRect: LegacyV6RectRecord
    var annotations: [LegacyV6AnnotationRecord]
    var selectedAnnotationIDs: [UUID]
    var nextCalloutNumber: Int
    var presentation: LegacyV6PresentationRecord?
    var pinnedUIMapElementIDs: [UUID]?

    init(_ snapshot: EditorSnapshot) {
        cropRect = LegacyV6RectRecord(snapshot.cropRect)
        annotations = snapshot.annotations.map(LegacyV6AnnotationRecord.init)
        selectedAnnotationIDs = snapshot.selectedAnnotationIDs
        nextCalloutNumber = snapshot.nextCalloutNumber
        presentation = LegacyV6PresentationRecord(snapshot.presentation)
        pinnedUIMapElementIDs = snapshot.pinnedUIMapElementIDs.isEmpty
            ? nil
            : snapshot.pinnedUIMapElementIDs
    }
}

nonisolated private struct LegacyV6PresentationRecord: Encodable {
    var isEnabled: Bool
    var style: PresentationStyle?
    var scene: AppliedPresentationScene?
    var background: LegacyV6PresentationBackgroundRecord
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

    init(_ presentation: ScreenshotPresentation) {
        isEnabled = presentation.isEnabled
        style = presentation.style
        scene = presentation.scene
        background = LegacyV6PresentationBackgroundRecord(
            presentation.background
        )
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
}

nonisolated private struct LegacyV6PresentationBackgroundRecord: Encodable {
    var kind: String
    var color: LegacyV6ColorRecord?
    var start: LegacyV6ColorRecord?
    var end: LegacyV6ColorRecord?
    var base: LegacyV6ColorRecord?
    var spotlight: LegacyV6ColorRecord?
    var tint: LegacyV6ColorRecord?

    init(_ background: ScreenshotPresentationBackground) {
        switch background {
        case .transparent:
            kind = "transparent"
        case let .solid(fillColor):
            kind = "solid"
            color = LegacyV6ColorRecord(fillColor)
        case let .twoColorGradient(startColor, endColor):
            kind = "twoColorGradient"
            start = LegacyV6ColorRecord(startColor)
            end = LegacyV6ColorRecord(endColor)
        case let .radialSpotlight(baseColor, spotlightColor):
            kind = "radialSpotlight"
            base = LegacyV6ColorRecord(baseColor)
            spotlight = LegacyV6ColorRecord(spotlightColor)
        case let .blurredScreenshot(tintColor):
            kind = "blurredScreenshot"
            tint = LegacyV6ColorRecord(tintColor)
        }
    }
}

nonisolated private struct LegacyV6AnnotationRecord: Encodable {
    var id: UUID
    var groupID: UUID?
    var kind: String
    var rect: LegacyV6RectRecord?
    var start: LegacyV6PointRecord?
    var end: LegacyV6PointRecord?
    var points: [LegacyV6PointRecord]?
    var text: String?
    var automaticallySizesToText: Bool?
    var number: Int?
    var textAlignment: String?
    var arrowHeadStyle: String?
    var arrowHeadShape: String?
    var arrowCurvature: Double?
    var arrowLabelBoxColor: LegacyV6ColorRecord?
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
    var leaderPoint: LegacyV6PointRecord?
    var style: LegacyV6StyleRecord

    init(_ annotation: Annotation) {
        id = annotation.id
        groupID = annotation.groupID
        kind = ""
        rotationDegrees = Double(annotation.rotationDegrees)
        style = LegacyV6StyleRecord(annotation.style)

        switch annotation.kind {
        case let .rectangle(shape):
            kind = "rectangle"
            rect = LegacyV6RectRecord(shape.rect)
        case let .ellipse(shape):
            kind = "ellipse"
            rect = LegacyV6RectRecord(shape.rect)
        case let .line(shape):
            kind = "line"
            start = LegacyV6PointRecord(shape.start)
            end = LegacyV6PointRecord(shape.end)
        case let .arrow(shape):
            kind = "arrow"
            start = LegacyV6PointRecord(shape.start)
            end = LegacyV6PointRecord(shape.end)
            text = shape.label
            arrowHeadStyle = shape.headStyle.rawValue
            arrowHeadShape = shape.headShape.rawValue
            arrowCurvature = Double(shape.curvature)
            arrowLabelBoxColor = LegacyV6ColorRecord(
                shape.labelBoxColor
            )
            arrowLabelPlacement = shape.labelPlacement.rawValue
            arrowLabelFontSize = Double(shape.labelFontSize)
            arrowLabelTextColor = shape.labelTextColor.rawValue
        case let .statusMark(shape):
            kind = "statusMark"
            rect = LegacyV6RectRecord(shape.rect)
        case let .freehand(shape):
            kind = "freehand"
            points = shape.points.map(LegacyV6PointRecord.init)
        case let .highlighter(shape):
            kind = "highlighter"
            points = shape.points.map(LegacyV6PointRecord.init)
        case let .highlight(shape):
            kind = "highlight"
            rect = LegacyV6RectRecord(shape.rect)
        case let .text(shape):
            kind = "text"
            rect = LegacyV6RectRecord(shape.rect)
            text = shape.text
            automaticallySizesToText = shape.automaticallySizesToText
            textAlignment = shape.alignment.rawValue
        case let .callout(shape):
            kind = "callout"
            rect = LegacyV6RectRecord(shape.rect)
            number = shape.number
            text = shape.text
            automaticallySizesToText = shape.automaticallySizesToText
            textAlignment = shape.alignment.rawValue
            calloutStyle = shape.style.rawValue
            leaderPoint = shape.leaderPoint.map(
                LegacyV6PointRecord.init
            )
        case let .measurement(shape):
            kind = "measurement"
            start = LegacyV6PointRecord(shape.start)
            end = LegacyV6PointRecord(shape.end)
        case let .spotlight(shape):
            kind = "spotlight"
            rect = LegacyV6RectRecord(shape.rect)
            isEllipse = shape.isEllipse
        case let .imageOverlay(shape):
            kind = "imageOverlay"
            rect = LegacyV6RectRecord(shape.rect)
            assetID = shape.assetID
            opacity = Double(shape.opacity)
            imageOverlayRole = shape.role.rawValue
        case let .redaction(shape):
            kind = "redaction"
            rect = LegacyV6RectRecord(shape.rect)
            redactionMode = shape.mode.rawValue
        }
    }
}

nonisolated private struct LegacyV6StyleRecord: Encodable {
    var strokeColor: LegacyV6ColorRecord
    var fillColor: LegacyV6ColorRecord
    var lineWidth: Double
    var fontSize: Double
    var effectRadius: Double
    var cornerRadius: Double?
    var dashStyle: String?
    var freehandSmoothing: Double?
    var freehandSimplification: Double?
    var statusMarkSymbol: String?
    var statusMarkVisualStyle: String?

    init(_ style: AnnotationStyle) {
        strokeColor = LegacyV6ColorRecord(style.strokeColor)
        fillColor = LegacyV6ColorRecord(style.fillColor)
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
}

nonisolated private struct LegacyV6ColorRecord: Encodable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(_ color: RGBAColor) {
        red = Double(color.red)
        green = Double(color.green)
        blue = Double(color.blue)
        alpha = Double(color.alpha)
    }
}

nonisolated private struct LegacyV6RectRecord: Encodable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.size.width)
        height = Double(rect.size.height)
    }
}

nonisolated private struct LegacyV6PointRecord: Encodable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }
}

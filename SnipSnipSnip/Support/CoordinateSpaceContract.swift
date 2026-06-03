import CoreGraphics
import Foundation

/// Coordinate-space identifiers used by the app and persisted document metadata.
/// The naming is intentionally explicit so future migrations can reason about
/// origin, axis direction, and units without reading call-site math.
nonisolated enum CoordinateSpaceDescriptor: String, Codable {
    case captureGlobalPointsYUpV1 = "capture-global-points-y-up-v1"
    case captureGlobalPointsTopLeftYDownV2 = "capture-global-points-top-left-y-down-v2"
    case overlayScreenPointsYUpV1 = "overlay-screen-points-y-up-v1"
    case overlayLocalPointsYDownV1 = "overlay-local-points-y-down-v1"
    case previewPixelsTopLeftV1 = "preview-pixels-top-left-v1"
    case documentPixelsTopLeftV1 = "document-pixels-top-left-v1"
    case renderOutputPixelsTopLeftV1 = "render-output-pixels-top-left-v1"
    case accessibilityScreenPointsYUpV1 = "accessibility-screen-points-y-up-v1"
}

/// Persisted contract for how geometry is interpreted.
nonisolated struct DocumentCoordinateContract: Codable, Equatable {
    let captureSourceRectSpace: CoordinateSpaceDescriptor
    let overlayScreenSpace: CoordinateSpaceDescriptor
    let overlayLocalSpace: CoordinateSpaceDescriptor
    let previewPixelSpace: CoordinateSpaceDescriptor
    let documentImageSpace: CoordinateSpaceDescriptor
    let annotationGeometrySpace: CoordinateSpaceDescriptor
    let cropRectSpace: CoordinateSpaceDescriptor
    let renderOutputSpace: CoordinateSpaceDescriptor
    let accessibilityScreenSpace: CoordinateSpaceDescriptor

    nonisolated static let current = DocumentCoordinateContract(
        captureSourceRectSpace: .captureGlobalPointsTopLeftYDownV2,
        overlayScreenSpace: .overlayScreenPointsYUpV1,
        overlayLocalSpace: .overlayLocalPointsYDownV1,
        previewPixelSpace: .previewPixelsTopLeftV1,
        documentImageSpace: .documentPixelsTopLeftV1,
        annotationGeometrySpace: .documentPixelsTopLeftV1,
        cropRectSpace: .documentPixelsTopLeftV1,
        renderOutputSpace: .renderOutputPixelsTopLeftV1,
        accessibilityScreenSpace: .accessibilityScreenPointsYUpV1
    )

    /// Versions 1-3 stored the same editor/document geometry but did not yet
    /// persist an explicit contract descriptor in the package manifest.
    nonisolated static let legacyDocumentPackageV1ToV3 = DocumentCoordinateContract(
        captureSourceRectSpace: .captureGlobalPointsYUpV1,
        overlayScreenSpace: .overlayScreenPointsYUpV1,
        overlayLocalSpace: .overlayLocalPointsYDownV1,
        previewPixelSpace: .previewPixelsTopLeftV1,
        documentImageSpace: .documentPixelsTopLeftV1,
        annotationGeometrySpace: .documentPixelsTopLeftV1,
        cropRectSpace: .documentPixelsTopLeftV1,
        renderOutputSpace: .renderOutputPixelsTopLeftV1,
        accessibilityScreenSpace: .accessibilityScreenPointsYUpV1
    )
}

/// Scales points and rects between two top-left, y-down spaces.
nonisolated struct TopLeftRectTransform: Equatable {
    let sourceBounds: CGRect
    let targetBounds: CGRect

    init(sourceBounds: CGRect, targetBounds: CGRect) {
        self.sourceBounds = sourceBounds.standardized
        self.targetBounds = targetBounds.standardized
    }

    func targetPoint(fromSourcePoint point: CGPoint) -> CGPoint {
        gscScaledPoint(point, from: sourceBounds, to: targetBounds)
    }

    func targetRect(fromSourceRect rect: CGRect) -> CGRect {
        gscScaledRect(rect, from: sourceBounds, to: targetBounds)
    }
}

nonisolated struct CaptureGlobalRect: Equatable {
    let cgRect: CGRect

    init(_ rect: CGRect) {
        cgRect = rect.gscIntegralStandardized
    }
}

nonisolated struct DisplayLocalRect: Equatable {
    let cgRect: CGRect

    init(_ rect: CGRect) {
        cgRect = rect.gscIntegralStandardized
    }
}

/// Maps AppKit global screen points into top-left overlay-local points.
nonisolated struct AppKitOverlayTransform: Equatable {
    let overlayFrame: CGRect

    init(overlayFrame: CGRect) {
        self.overlayFrame = overlayFrame.gscFiniteOr(.zero)
    }

    func localPoint(fromGlobalPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - overlayFrame.minX, y: overlayFrame.maxY - point.y)
    }

    func globalPoint(fromLocalPoint point: CGPoint) -> CGPoint {
        CGPoint(x: overlayFrame.minX + point.x, y: overlayFrame.maxY - point.y)
    }
}

/// Maps Quartz/ScreenCaptureKit global points into top-left display-local points.
nonisolated struct CaptureScreenTransform: Equatable {
    let captureFrame: CGRect

    init(captureFrame: CGRect) {
        self.captureFrame = captureFrame.gscFiniteOr(.zero)
    }

    func localPoint(fromGlobalPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - captureFrame.minX, y: point.y - captureFrame.minY)
    }

    func globalPoint(fromLocalPoint point: CGPoint) -> CGPoint {
        CGPoint(x: captureFrame.minX + point.x, y: captureFrame.minY + point.y)
    }

    func localRect(fromGlobalRect rect: CGRect) -> CGRect {
        let normalized = rect.standardized
        return CGRect(
            x: normalized.minX - captureFrame.minX,
            y: normalized.minY - captureFrame.minY,
            width: normalized.width,
            height: normalized.height
        ).gscIntegralStandardized
    }

    func localRect(fromGlobalRect rect: CaptureGlobalRect) -> DisplayLocalRect {
        DisplayLocalRect(localRect(fromGlobalRect: rect.cgRect))
    }

    func globalRect(fromLocalRect rect: CGRect) -> CGRect {
        let normalized = rect.standardized
        return CGRect(
            x: captureFrame.minX + normalized.minX,
            y: captureFrame.minY + normalized.minY,
            width: normalized.width,
            height: normalized.height
        ).gscIntegralStandardized
    }
}

/// Maps between ScreenCaptureKit capture-global points and AppKit overlay points.
///
/// - `captureFrame` is in Quartz global screen points with a top-left origin and y-down axis.
/// - `overlayFrame` is in AppKit screen points with a bottom-left origin.
/// - `captureLocal*` and `overlayLocal*` APIs operate in top-left, y-down local spaces.
nonisolated struct CaptureDisplayTransform: Equatable {
    let captureFrame: CGRect
    let overlayFrame: CGRect

    init(captureFrame: CGRect, overlayFrame: CGRect) {
        let sanitizedCaptureFrame = captureFrame.gscFiniteOr(.zero)
        self.captureFrame = sanitizedCaptureFrame
        self.overlayFrame = overlayFrame.gscFiniteOr(sanitizedCaptureFrame)
    }

    var captureLocalBounds: CGRect {
        CGRect(origin: .zero, size: captureFrame.size)
    }

    var overlayLocalBounds: CGRect {
        CGRect(origin: .zero, size: overlayFrame.size)
    }

    private var captureScreenTransform: CaptureScreenTransform {
        CaptureScreenTransform(captureFrame: captureFrame)
    }

    private var appKitOverlayTransform: AppKitOverlayTransform {
        AppKitOverlayTransform(overlayFrame: overlayFrame)
    }

    private var overlayToCaptureLocalTransform: TopLeftRectTransform {
        TopLeftRectTransform(sourceBounds: overlayLocalBounds, targetBounds: captureLocalBounds)
    }

    private var captureToOverlayLocalTransform: TopLeftRectTransform {
        TopLeftRectTransform(sourceBounds: captureLocalBounds, targetBounds: overlayLocalBounds)
    }

    func overlayLocalPoint(fromOverlayGlobalPoint point: CGPoint) -> CGPoint {
        appKitOverlayTransform.localPoint(fromGlobalPoint: point)
    }

    func overlayGlobalPoint(fromOverlayLocalPoint point: CGPoint) -> CGPoint {
        appKitOverlayTransform.globalPoint(fromLocalPoint: point)
    }

    func captureLocalPoint(fromCaptureGlobalPoint point: CGPoint) -> CGPoint {
        captureScreenTransform.localPoint(fromGlobalPoint: point)
    }

    func captureGlobalPoint(fromCaptureLocalPoint point: CGPoint) -> CGPoint {
        captureScreenTransform.globalPoint(fromLocalPoint: point)
    }

    func captureLocalPoint(fromOverlayLocalPoint point: CGPoint) -> CGPoint {
        overlayToCaptureLocalTransform.targetPoint(fromSourcePoint: point)
    }

    func overlayLocalPoint(fromCaptureLocalPoint point: CGPoint) -> CGPoint {
        captureToOverlayLocalTransform.targetPoint(fromSourcePoint: point)
    }

    func overlayLocalPoint(fromCaptureGlobalPoint point: CGPoint) -> CGPoint {
        overlayLocalPoint(fromCaptureLocalPoint: captureLocalPoint(fromCaptureGlobalPoint: point))
    }

    func captureGlobalPoint(fromOverlayLocalPoint point: CGPoint) -> CGPoint {
        captureGlobalPoint(fromCaptureLocalPoint: captureLocalPoint(fromOverlayLocalPoint: point))
    }

    func captureGlobalPoint(fromOverlayGlobalPoint point: CGPoint) -> CGPoint {
        captureGlobalPoint(fromOverlayLocalPoint: overlayLocalPoint(fromOverlayGlobalPoint: point))
    }

    func overlayGlobalPoint(fromCaptureGlobalPoint point: CGPoint) -> CGPoint {
        overlayGlobalPoint(
            fromOverlayLocalPoint: overlayLocalPoint(
                fromCaptureGlobalPoint: point
            )
        )
    }

    func captureLocalRect(fromCaptureGlobalRect rect: CGRect) -> CGRect {
        captureScreenTransform.localRect(fromGlobalRect: rect)
    }

    func captureGlobalRect(fromCaptureLocalRect rect: CGRect) -> CGRect {
        captureScreenTransform.globalRect(fromLocalRect: rect)
    }

    func captureLocalRect(fromOverlayLocalRect rect: CGRect) -> CGRect {
        overlayToCaptureLocalTransform.targetRect(fromSourceRect: rect)
    }

    func overlayLocalRect(fromCaptureLocalRect rect: CGRect) -> CGRect {
        captureToOverlayLocalTransform.targetRect(fromSourceRect: rect)
    }

    func captureGlobalRect(fromOverlayLocalRect rect: CGRect) -> CGRect {
        captureGlobalRect(fromCaptureLocalRect: captureLocalRect(fromOverlayLocalRect: rect))
    }

    func overlayLocalRect(fromCaptureGlobalRect rect: CGRect) -> CGRect {
        overlayLocalRect(fromCaptureLocalRect: captureLocalRect(fromCaptureGlobalRect: rect))
    }

    func overlayGlobalRect(fromCaptureGlobalRect rect: CGRect) -> CGRect {
        let normalized = rect.standardized
        let minPoint = overlayGlobalPoint(fromCaptureGlobalPoint: CGPoint(x: normalized.minX, y: normalized.maxY))
        let maxPoint = overlayGlobalPoint(fromCaptureGlobalPoint: CGPoint(x: normalized.maxX, y: normalized.minY))
        return CGRect(
            x: min(minPoint.x, maxPoint.x),
            y: min(minPoint.y, maxPoint.y),
            width: abs(maxPoint.x - minPoint.x),
            height: abs(maxPoint.y - minPoint.y)
        ).gscIntegralStandardized
    }
}

/// Maps preview images captured for a display back to capture-space geometry.
nonisolated struct CapturePreviewTransform: Equatable {
    let displayTransform: CaptureDisplayTransform
    let previewPixelSize: CGSize

    init(displayTransform: CaptureDisplayTransform, previewPixelSize: CGSize) {
        self.displayTransform = displayTransform
        self.previewPixelSize = previewPixelSize
    }

    private var previewPixelBounds: CGRect {
        CGRect(origin: .zero, size: previewPixelSize)
    }

    private var captureLocalToPreviewTransform: TopLeftRectTransform {
        TopLeftRectTransform(
            sourceBounds: displayTransform.captureLocalBounds,
            targetBounds: previewPixelBounds
        )
    }

    func previewTopLeftPixelRect(fromCaptureGlobalRect rect: CGRect) -> CGRect {
        captureLocalToPreviewTransform.targetRect(
            fromSourceRect: displayTransform.captureLocalRect(fromCaptureGlobalRect: rect)
        )
    }

    func previewTopLeftPixelRect(fromOverlayLocalRect rect: CGRect) -> CGRect {
        captureLocalToPreviewTransform.targetRect(
            fromSourceRect: displayTransform.captureLocalRect(fromOverlayLocalRect: rect)
        )
    }

    func appKitSourceRect(fromCaptureGlobalRect rect: CGRect) -> CGRect {
        appKitSourceRect(fromTopLeftPixelRect: previewTopLeftPixelRect(fromCaptureGlobalRect: rect))
    }

    func appKitSourceRect(fromOverlayLocalRect rect: CGRect) -> CGRect {
        appKitSourceRect(fromTopLeftPixelRect: previewTopLeftPixelRect(fromOverlayLocalRect: rect))
    }

    private func appKitSourceRect(fromTopLeftPixelRect rect: CGRect) -> CGRect {
        let normalized = rect.standardized.integral
        return CGRect(
            x: normalized.minX,
            y: previewPixelBounds.height - normalized.maxY,
            width: normalized.width,
            height: normalized.height
        ).gscIntegralStandardized
    }
}

/// Maps top-left capture-global rects into top-left composite canvas draw rects.
nonisolated struct CompositeCaptureDrawTransform: Equatable {
    let captureUnionFrame: CGRect
    let outputScale: CGFloat

    init(captureUnionFrame: CGRect, outputScale: CGFloat) {
        self.captureUnionFrame = captureUnionFrame.standardized
        self.outputScale = max(outputScale, 1)
    }

    func destinationRect(fromCaptureGlobalRect rect: CGRect) -> CGRect {
        let normalized = rect.standardized
        return CGRect(
            x: (normalized.minX - captureUnionFrame.minX) * outputScale,
            y: (normalized.minY - captureUnionFrame.minY) * outputScale,
            width: normalized.width * outputScale,
            height: normalized.height * outputScale
        ).gscIntegralStandardized
    }
}

/// Maps capture-global points to Accessibility screen coordinates.
///
/// The transform intentionally scales by relative position instead of assuming
/// the capture and accessibility frames have identical sizes.
nonisolated struct CaptureAccessibilityTransform: Equatable {
    let captureFrame: CGRect
    let accessibilityFrame: CGRect

    init(captureFrame: CGRect, accessibilityFrame: CGRect) {
        self.captureFrame = captureFrame.standardized
        self.accessibilityFrame = accessibilityFrame.standardized
    }

    func containsCapturePoint(_ point: CGPoint) -> Bool {
        captureFrame.insetBy(dx: -1, dy: -1).contains(point)
    }

    func intersectsCaptureRect(_ rect: CGRect) -> Bool {
        captureFrame.intersects(rect.standardized)
    }

    func accessibilityPoint(fromCapturePoint point: CGPoint) -> CGPoint {
        guard captureFrame.width > 0,
              captureFrame.height > 0 else {
            return accessibilityFrame.origin
        }

        let normalizedX = (point.x - captureFrame.minX) / captureFrame.width
        let normalizedY = (point.y - captureFrame.minY) / captureFrame.height
        return CGPoint(
            x: accessibilityFrame.minX + normalizedX * accessibilityFrame.width,
            y: accessibilityFrame.maxY - normalizedY * accessibilityFrame.height
        )
    }

    func capturePoint(fromAccessibilityPoint point: CGPoint) -> CGPoint {
        guard accessibilityFrame.width > 0,
              accessibilityFrame.height > 0 else {
            return captureFrame.origin
        }

        let normalizedX = (point.x - accessibilityFrame.minX) / accessibilityFrame.width
        let normalizedY = (accessibilityFrame.maxY - point.y) / accessibilityFrame.height
        return CGPoint(
            x: captureFrame.minX + normalizedX * captureFrame.width,
            y: captureFrame.minY + normalizedY * captureFrame.height
        )
    }

    func accessibilityRect(fromCaptureRect rect: CGRect) -> CGRect {
        let normalized = rect.standardized
        let minPoint = accessibilityPoint(fromCapturePoint: CGPoint(x: normalized.minX, y: normalized.maxY))
        let maxPoint = accessibilityPoint(fromCapturePoint: CGPoint(x: normalized.maxX, y: normalized.minY))
        return CGRect(
            x: min(minPoint.x, maxPoint.x),
            y: min(minPoint.y, maxPoint.y),
            width: abs(maxPoint.x - minPoint.x),
            height: abs(maxPoint.y - minPoint.y)
        ).gscIntegralStandardized
    }

    func captureRect(fromAccessibilityRect rect: CGRect) -> CGRect {
        let normalized = rect.standardized
        let minPoint = capturePoint(fromAccessibilityPoint: normalized.origin)
        let maxPoint = capturePoint(fromAccessibilityPoint: CGPoint(x: normalized.maxX, y: normalized.maxY))
        return CGRect(
            x: min(minPoint.x, maxPoint.x),
            y: min(minPoint.y, maxPoint.y),
            width: abs(maxPoint.x - minPoint.x),
            height: abs(maxPoint.y - minPoint.y)
        ).gscIntegralStandardized
    }
}

/// Shared projection between document image space and a destination surface.
///
/// Both spaces use top-left, y-down semantics. Export-specific Core Graphics
/// mapping is derived explicitly via `context*` helpers.
nonisolated struct DocumentProjection: Equatable {
    let sourceDocumentRect: CGRect
    let destinationBounds: CGRect

    init(sourceDocumentRect: CGRect, destinationBounds: CGRect) {
        self.sourceDocumentRect = sourceDocumentRect.standardized
        self.destinationBounds = destinationBounds.standardized
    }

    func destinationPoint(fromDocumentPoint point: CGPoint) -> CGPoint {
        guard sourceDocumentRect.width > 0,
              sourceDocumentRect.height > 0 else {
            return destinationBounds.origin
        }

        let normalizedX = (point.x - sourceDocumentRect.minX) / sourceDocumentRect.width
        let normalizedY = (point.y - sourceDocumentRect.minY) / sourceDocumentRect.height
        return CGPoint(
            x: destinationBounds.minX + normalizedX * destinationBounds.width,
            y: destinationBounds.minY + normalizedY * destinationBounds.height
        )
    }

    func destinationRect(fromDocumentRect rect: CGRect) -> CGRect {
        let normalized = rect.standardized
        let minPoint = destinationPoint(fromDocumentPoint: normalized.origin)
        let maxPoint = destinationPoint(fromDocumentPoint: CGPoint(x: normalized.maxX, y: normalized.maxY))
        return CGRect(
            x: min(minPoint.x, maxPoint.x),
            y: min(minPoint.y, maxPoint.y),
            width: abs(maxPoint.x - minPoint.x),
            height: abs(maxPoint.y - minPoint.y)
        )
    }

    func documentPoint(fromDestinationPoint point: CGPoint) -> CGPoint {
        guard destinationBounds.width > 0,
              destinationBounds.height > 0 else {
            return sourceDocumentRect.origin
        }

        let normalizedX = (point.x - destinationBounds.minX) / destinationBounds.width
        let normalizedY = (point.y - destinationBounds.minY) / destinationBounds.height
        return CGPoint(
            x: sourceDocumentRect.minX + normalizedX * sourceDocumentRect.width,
            y: sourceDocumentRect.minY + normalizedY * sourceDocumentRect.height
        )
    }

    func sourceLocalRect(fromDocumentRect rect: CGRect) -> CGRect {
        rect.standardized.offsetBy(dx: -sourceDocumentRect.minX, dy: -sourceDocumentRect.minY)
    }

    func contextPoint(fromDocumentPoint point: CGPoint) -> CGPoint {
        let mapped = destinationPoint(fromDocumentPoint: point)
        return CGPoint(
            x: mapped.x,
            y: destinationBounds.maxY - (mapped.y - destinationBounds.minY)
        )
    }

    func contextRect(fromDocumentRect rect: CGRect) -> CGRect {
        let mapped = destinationRect(fromDocumentRect: rect)
        return CGRect(
            x: mapped.minX,
            y: destinationBounds.maxY - (mapped.maxY - destinationBounds.minY),
            width: mapped.width,
            height: mapped.height
        )
    }
}

extension CGImage {
    /// Crops in the app's canonical image-data space: top-left pixel coordinates.
    ///
    /// `CGImage` instances produced and persisted by the app are treated as row-major
    /// top-left pixel buffers. Any Y-up/Core Graphics source-rect conversion must happen
    /// before calling this helper.
    nonisolated func gscCropped(topLeftPixelRect: CGRect) -> CGImage? {
        let crop = topLeftPixelRect.standardized.integral

        guard crop.width > 0, crop.height > 0 else {
            return nil
        }

        return cropping(to: crop)
    }
}

extension CapturedScreenshot {
    nonisolated var documentRect: CGRect {
        CGRect(origin: .zero, size: pixelSize).gscIntegralStandardized
    }
}

extension DisplaySnapshot {
    nonisolated var captureDisplayTransform: CaptureDisplayTransform {
        CaptureDisplayTransform(captureFrame: frame, overlayFrame: overlayFrame)
    }
}

extension DisplayPreview {
    nonisolated var capturePreviewTransform: CapturePreviewTransform {
        CapturePreviewTransform(
            displayTransform: snapshot.captureDisplayTransform,
            previewPixelSize: CGSize(width: image.width, height: image.height)
        )
    }
}

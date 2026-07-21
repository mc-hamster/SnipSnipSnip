import CoreGraphics

/// Geometry for the source-media stream. It intentionally differs from the
/// still-step framing: the video keeps a little context around a Window or App,
/// while individual Guide cards may use a tighter crop around their target.
nonisolated enum GuideSourceMediaGeometry {
    static func captureFrame(for source: GuideCaptureSource, within displayFrame: CGRect) -> CGRect {
        let displayFrame = displayFrame.standardized
        switch source {
        case .window(_, _, _, let frame), .app(_, _, _, let frame):
            let safeX = frame.width * 0.12
            let safeY = frame.height * 0.12
            return frame
                .insetBy(dx: -safeX, dy: -safeY)
                .intersection(displayFrame)
                .gscIntegralStandardized
        case .region(let rect):
            return rect.intersection(displayFrame).gscIntegralStandardized
        case .displays:
            return displayFrame.gscIntegralStandardized
        }
    }
}

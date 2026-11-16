import CoreGraphics

/// Shared bounds for newly captured and rendered screenshot rasters. Long,
/// narrow images are limited by pixel storage rather than a square canvas cap.
/// At the pixel ceiling one RGBA surface is 512 MiB; export retains its separate
/// working-set preflight because several surfaces may coexist.
nonisolated enum ScreenshotRasterBudget {
    static let maximumDimension = 262_144
    static let maximumPixelCount = 134_217_728

    static func maximumHeight(forWidth width: Int, requestedHeight: Int = maximumDimension) -> Int {
        guard width > 0, width <= maximumDimension, requestedHeight > 0 else { return 0 }
        return min(requestedHeight, maximumDimension, maximumPixelCount / width)
    }

    static func contains(width: Int, height: Int) -> Bool {
        height > 0 && height <= maximumHeight(forWidth: width)
    }

    static func contains(_ size: CGSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width <= CGFloat(maximumDimension),
              size.height <= CGFloat(maximumDimension) else { return false }
        return contains(width: Int(size.width.rounded(.up)), height: Int(size.height.rounded(.up)))
    }
}

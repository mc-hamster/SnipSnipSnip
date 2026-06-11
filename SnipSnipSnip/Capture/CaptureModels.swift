import AppKit
import CoreGraphics
import Foundation

nonisolated enum CaptureKind: String {
    case region
    case window
    case fullscreen
    case scrolling
    case connectedDevice
}

nonisolated enum CaptureDelay: Int, CaseIterable, Identifiable {
    case immediate = 0
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .immediate:
            return "No Timer"
        case .threeSeconds:
            return "3 Seconds"
        case .fiveSeconds:
            return "5 Seconds"
        case .tenSeconds:
            return "10 Seconds"
        }
    }

    var shortLabel: String {
        switch self {
        case .immediate:
            return "Timer: Off"
        case .threeSeconds:
            return "Timer: 3s"
        case .fiveSeconds:
            return "Timer: 5s"
        case .tenSeconds:
            return "Timer: 10s"
        }
    }

    var countdownSeconds: Int {
        rawValue
    }
}

nonisolated enum RegionCaptureOverlayMode: Int, CaseIterable, Identifiable {
    case crosshair = 0
    case magnifyingGlass = 1
    case crosshairAndMagnifyingGlass = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .crosshair:
            return "Cross Hair"
        case .magnifyingGlass:
            return "Magnifying Glass"
        case .crosshairAndMagnifyingGlass:
            return "Cross Hair and Magnifying Glass"
        }
    }

    var showsCrosshair: Bool {
        switch self {
        case .crosshair, .crosshairAndMagnifyingGlass:
            return true
        case .magnifyingGlass:
            return false
        }
    }

    var showsMagnifyingGlass: Bool {
        switch self {
        case .magnifyingGlass, .crosshairAndMagnifyingGlass:
            return true
        case .crosshair:
            return false
        }
    }
}

nonisolated struct RegionCapturePreferences: Equatable {
    var overlayMode: RegionCaptureOverlayMode = .crosshairAndMagnifyingGlass
    var showsActionControls = false

    var autoCapturesOnMouseUp: Bool {
        !showsActionControls
    }
}

nonisolated struct CapturedCursorOverlay: @unchecked Sendable {
    let image: CGImage
    let rect: CGRect
}

nonisolated enum CursorCaptureGeometry {
    static func captureGlobalPoint(
        fromAppKitGlobalPoint point: CGPoint,
        captureFrame: CGRect,
        appKitFrame: CGRect
    ) -> CGPoint {
        CaptureDisplayTransform(captureFrame: captureFrame, overlayFrame: appKitFrame)
            .captureGlobalPoint(fromOverlayGlobalPoint: point)
    }

    @MainActor
    static func captureGlobalPoint(fromAppKitGlobalPoint point: CGPoint) -> CGPoint? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let displayID = screen.gscDisplayID else {
            return nil
        }

        return captureGlobalPoint(
            fromAppKitGlobalPoint: point,
            captureFrame: CGDisplayBounds(displayID),
            appKitFrame: screen.frame
        )
    }

    static func overlayRect(
        cursorCaptureGlobalLocation: CGPoint,
        cursorHotSpot: CGPoint,
        cursorSize: CGSize,
        captureSourceRect: CGRect,
        capturePixelSize: CGSize
    ) -> CGRect? {
        let sourceRect = captureSourceRect.gscIntegralStandardized
        guard sourceRect.width > 0,
              sourceRect.height > 0,
              sourceRect.contains(cursorCaptureGlobalLocation),
              cursorSize.width > 0,
              cursorSize.height > 0 else {
            return nil
        }

        let scaleX = capturePixelSize.width / sourceRect.width
        let scaleY = capturePixelSize.height / sourceRect.height
        return CGRect(
            x: (cursorCaptureGlobalLocation.x - sourceRect.minX - cursorHotSpot.x) * scaleX,
            y: (cursorCaptureGlobalLocation.y - sourceRect.minY - cursorHotSpot.y) * scaleY,
            width: cursorSize.width * scaleX,
            height: cursorSize.height * scaleY
        ).integral
    }
}

nonisolated struct CaptureSourceWindowIdentity: Equatable, Hashable, @unchecked Sendable {
    let windowID: CGWindowID
    let ownerName: String
    let ownerPID: pid_t
    let bundleIdentifier: String?
    let title: String
    let frame: CGRect

    init(
        windowID: CGWindowID,
        ownerName: String,
        ownerPID: pid_t,
        bundleIdentifier: String?,
        title: String,
        frame: CGRect
    ) {
        self.windowID = windowID
        self.ownerName = ownerName
        self.ownerPID = ownerPID
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.frame = frame.gscIntegralStandardized
    }

    init(window: CaptureWindowSummary, bundleIdentifier: String? = nil, frame: CGRect? = nil) {
        self.init(
            windowID: window.id,
            ownerName: window.ownerName,
            ownerPID: window.ownerPID,
            bundleIdentifier: bundleIdentifier,
            title: window.title,
            frame: frame ?? window.frame
        )
    }
}

nonisolated struct CapturedScreenshot: Identifiable, @unchecked Sendable {
    let id = UUID()
    let image: CGImage
    let kind: CaptureKind
    let sourceName: String
    let sourceRect: CGRect
    let sourceWindowIdentity: CaptureSourceWindowIdentity?
    let coordinateContract: DocumentCoordinateContract
    let capturedAt: Date
    let cursorOverlay: CapturedCursorOverlay?
    let uiMap: UIMapSnapshot?

    init(
        image: CGImage,
        kind: CaptureKind,
        sourceName: String,
        sourceRect: CGRect,
        sourceWindowIdentity: CaptureSourceWindowIdentity? = nil,
        coordinateContract: DocumentCoordinateContract = .current,
        capturedAt: Date,
        cursorOverlay: CapturedCursorOverlay? = nil,
        uiMap: UIMapSnapshot? = nil
    ) {
        self.image = image
        self.kind = kind
        self.sourceName = sourceName
        self.sourceRect = sourceRect.gscIntegralStandardized
        self.sourceWindowIdentity = sourceWindowIdentity
        self.coordinateContract = coordinateContract
        self.capturedAt = capturedAt
        self.cursorOverlay = cursorOverlay
        self.uiMap = uiMap
    }

    func attachingCursorOverlay(_ cursorOverlay: CapturedCursorOverlay?) -> CapturedScreenshot {
        CapturedScreenshot(
            image: image,
            kind: kind,
            sourceName: sourceName,
            sourceRect: sourceRect,
            sourceWindowIdentity: sourceWindowIdentity,
            coordinateContract: coordinateContract,
            capturedAt: capturedAt,
            cursorOverlay: cursorOverlay,
            uiMap: uiMap
        )
    }

    func attachingUIMap(_ uiMap: UIMapSnapshot?) -> CapturedScreenshot {
        CapturedScreenshot(
            image: image,
            kind: kind,
            sourceName: sourceName,
            sourceRect: sourceRect,
            sourceWindowIdentity: sourceWindowIdentity,
            coordinateContract: coordinateContract,
            capturedAt: capturedAt,
            cursorOverlay: cursorOverlay,
            uiMap: uiMap
        )
    }

    var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    var defaultFilename: String {
        ScreenshotFilenameTemplate.default.resolvedFilename(for: self, formatExtension: nil)
    }
}

nonisolated struct ScreenshotFilenameTemplate: Equatable {
    nonisolated static let defaultPattern = "SnipSnipSnip-{source}-{yyyy-MM-dd-HH-mm-ss}"
    nonisolated static let `default` = ScreenshotFilenameTemplate(pattern: defaultPattern)

    var pattern: String

    func resolvedFilename(for capture: CapturedScreenshot, formatExtension: String?) -> String {
        let dateFormatter = DateFormatter()
        let source = sanitizedFilenameComponent(capture.sourceName)
        var resolved = pattern
            .replacingOccurrences(of: "{kind}", with: capture.kind.rawValue)
            .replacingOccurrences(of: "{source}", with: source)
            .replacingOccurrences(of: "{width}", with: "\(capture.image.width)")
            .replacingOccurrences(of: "{height}", with: "\(capture.image.height)")
            .replacingOccurrences(of: "{format}", with: formatExtension ?? "")

        let datePattern = #/\{([^{}]+)\}/#
        resolved = resolved.replacing(datePattern) { match in
            dateFormatter.dateFormat = String(match.1)
            return dateFormatter.string(from: capture.capturedAt)
        }

        let baseName = sanitizedFilenameComponent(resolved).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return baseName.isEmpty ? ScreenshotFilenameTemplate.defaultPattern : baseName
    }

    private func sanitizedFilenameComponent(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return value.components(separatedBy: forbidden)
            .joined(separator: "-")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

nonisolated struct ScrollingCaptureRequest: Equatable {
    static let defaultMaxSegmentCount = 80
    static let defaultMaxOutputHeight = 60_000

    let viewportRect: CGRect
    let sourceName: String
    let maxSegmentCount: Int
    let maxOutputHeight: Int

    init(
        viewportRect: CGRect,
        sourceName: String = "Scrolling Capture",
        maxSegmentCount: Int = Self.defaultMaxSegmentCount,
        maxOutputHeight: Int = Self.defaultMaxOutputHeight
    ) {
        self.viewportRect = viewportRect.gscIntegralStandardized
        self.sourceName = sourceName
        self.maxSegmentCount = max(maxSegmentCount, 2)
        self.maxOutputHeight = max(maxOutputHeight, 1)
    }
}

nonisolated struct ScrollingCaptureResult {
    let image: CGImage
    let sourceViewportRect: CGRect
    let sourceName: String
    let capturedAt: Date
    let warnings: [String]
    let coordinateContract: DocumentCoordinateContract

    init(
        image: CGImage,
        sourceViewportRect: CGRect,
        sourceName: String,
        capturedAt: Date,
        warnings: [String],
        coordinateContract: DocumentCoordinateContract = .current
    ) {
        self.image = image
        self.sourceViewportRect = sourceViewportRect.gscIntegralStandardized
        self.sourceName = sourceName
        self.capturedAt = capturedAt
        self.warnings = warnings
        self.coordinateContract = coordinateContract
    }

    var outputPixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    var outputDocumentRect: CGRect {
        CGRect(origin: .zero, size: outputPixelSize).gscIntegralStandardized
    }

    var capturedScreenshot: CapturedScreenshot {
        CapturedScreenshot(
            image: image,
            kind: .scrolling,
            sourceName: sourceName,
            sourceRect: sourceViewportRect,
            coordinateContract: coordinateContract,
            capturedAt: capturedAt
        )
    }
}

nonisolated struct CaptureWindowSummary: Identifiable, Hashable {
    let id: CGWindowID
    let ownerName: String
    let ownerPID: pid_t
    let title: String
    let frame: CGRect
    let layer: Int
    let focusRank: Int
    let thumbnail: CGImage?

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ownerName : "\(ownerName) - \(trimmed)"
    }

    static func == (lhs: CaptureWindowSummary, rhs: CaptureWindowSummary) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

nonisolated enum RegionCaptureSelection {
    case region(CGRect, cursorCaptureGlobalLocation: CGPoint?)
    case window(CaptureWindowSummary)
}

nonisolated struct DisplaySnapshot {
    let displayID: CGDirectDisplayID
    let name: String
    // ScreenCaptureKit display-space frame used for screenshot capture and crop math.
    let frame: CGRect
    // AppKit screen-space frame used only for positioning overlay windows.
    let overlayFrame: CGRect
    let scale: CGFloat

    init(displayID: CGDirectDisplayID, name: String, frame: CGRect, overlayFrame: CGRect? = nil, scale: CGFloat) {
        let sanitizedFrame = frame.gscFiniteOr(.zero)
        let sanitizedOverlayFrame = (overlayFrame ?? sanitizedFrame).gscFiniteOr(sanitizedFrame)

        self.displayID = displayID
        self.name = name
        self.frame = sanitizedFrame
        self.overlayFrame = sanitizedOverlayFrame
        self.scale = scale.isFinite && scale > 0 ? scale : 1
    }
}

nonisolated struct DisplayPreview {
    let snapshot: DisplaySnapshot
    let image: CGImage
}

nonisolated struct DesktopCompositeSnapshot {
    let previewImage: CGImage?
    let globalFrame: CGRect
    let displays: [DisplaySnapshot]
    let displayPreviews: [DisplayPreview]
}

nonisolated func gscAppKitScreenRect(fromCGWindowBounds bounds: CGRect, desktopFrame: CGRect) -> CGRect {
    let normalizedBounds = bounds.standardized
    let normalizedDesktopFrame = desktopFrame.standardized

    guard normalizedDesktopFrame.height > 0 else {
        return normalizedBounds.gscIntegralStandardized
    }

    return CGRect(
        x: normalizedBounds.minX,
        y: normalizedDesktopFrame.maxY - normalizedBounds.maxY,
        width: normalizedBounds.width,
        height: normalizedBounds.height
    ).gscIntegralStandardized
}

nonisolated func gscWindowBoundsByID(from windowInfo: [[String: Any]], desktopFrame: CGRect) -> [CGWindowID: CGRect] {
    let normalizedDesktopFrame = desktopFrame.standardized

    return windowInfo.reduce(into: [:]) { partialResult, info in
        guard let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
              let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any] else {
            return
        }

        var bounds = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsDictionary as CFDictionary, &bounds) else {
            return
        }

        partialResult[CGWindowID(windowNumber.uint32Value)] = gscAppKitScreenRect(
            fromCGWindowBounds: bounds,
            desktopFrame: normalizedDesktopFrame
        )
    }
}

nonisolated func gscWindowBoundsByID(from windowInfo: [[String: Any]]) -> [CGWindowID: CGRect] {
    let desktopFrame = NSScreen.screens.reduce(CGRect.null) { partialResult, screen in
        partialResult.union(screen.frame)
    }.standardized

    return gscWindowBoundsByID(from: windowInfo, desktopFrame: desktopFrame)
}

func gscVisibleWindowBoundsByID() -> [CGWindowID: CGRect] {
    guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return [:]
    }

    return gscWindowBoundsByID(from: windowInfo)
}

nonisolated func gscWindowBounds(
    for window: CaptureWindowSummary,
    using visibleBoundsByID: [CGWindowID: CGRect]
) -> CGRect {
    visibleBoundsByID[window.id] ?? window.frame.gscIntegralStandardized
}

nonisolated func gscPreferredHighlightRect(primary: CGRect, alternate: CGRect) -> CGRect {
    let normalizedPrimary = primary.gscIntegralStandardized
    let normalizedAlternate = alternate.gscIntegralStandardized
    let primaryArea = max(normalizedPrimary.width, 0) * max(normalizedPrimary.height, 0)
    let alternateArea = max(normalizedAlternate.width, 0) * max(normalizedAlternate.height, 0)
    let smallerArea = min(primaryArea, alternateArea)

    guard smallerArea > 0 else {
        return normalizedPrimary
    }

    let intersection = normalizedPrimary.intersection(normalizedAlternate).gscIntegralStandardized
    let intersectionArea = max(intersection.width, 0) * max(intersection.height, 0)
    guard intersectionArea / smallerArea >= 0.8 else {
        return normalizedPrimary
    }

    return intersection
}

nonisolated func gscBestWindowMatch(
    for previous: CaptureWindowSummary,
    in candidates: [CaptureWindowSummary],
    frontmostOwnerPID: pid_t? = nil
) -> CaptureWindowSummary? {
    if let exact = candidates.first(where: { $0.id == previous.id }) {
        return exact
    }

    if let sameProcessAndTitle = candidates.first(where: {
        $0.ownerPID == previous.ownerPID && $0.title == previous.title && !$0.title.isEmpty
    }) {
        return sameProcessAndTitle
    }

    if let sameOwnerAndTitle = candidates.first(where: {
        $0.ownerName == previous.ownerName && $0.title == previous.title && !$0.title.isEmpty
    }) {
        return sameOwnerAndTitle
    }

    if let sameProcess = candidates.first(where: { $0.ownerPID == previous.ownerPID }) {
        return sameProcess
    }

    if let frontmostOwnerPID,
       let frontmostWindow = candidates
        .filter({ $0.ownerPID == frontmostOwnerPID })
        .min(by: { $0.focusRank < $1.focusRank }) {
        return frontmostWindow
    }

    return candidates.min(by: { $0.focusRank < $1.focusRank })
}

nonisolated func gscTopmostWindow(
    at point: CGPoint,
    in windows: [CaptureWindowSummary],
    visibleBoundsByID: [CGWindowID: CGRect] = [:]
) -> CaptureWindowSummary? {
    windows
        .filter { gscWindowBounds(for: $0, using: visibleBoundsByID).contains(point) }
        .min { left, right in
            if left.focusRank != right.focusRank {
                return left.focusRank < right.focusRank
            }

            let leftBounds = gscWindowBounds(for: left, using: visibleBoundsByID)
            let rightBounds = gscWindowBounds(for: right, using: visibleBoundsByID)
            let leftArea = max(leftBounds.width, 0) * max(leftBounds.height, 0)
            let rightArea = max(rightBounds.width, 0) * max(rightBounds.height, 0)
            if leftArea != rightArea {
                return leftArea < rightArea
            }

            return left.id < right.id
        }
}

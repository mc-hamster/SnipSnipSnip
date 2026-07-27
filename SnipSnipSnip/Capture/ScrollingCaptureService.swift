#if !APP_STORE_BUILD
import AppKit
import CoreGraphics
import Foundation

enum ScrollingCaptureError: LocalizedError {
    case accessibilityPermissionDenied
    case invalidViewport
    case noScrollableTarget
    case firstFrameUnavailable
    case stitchingFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Scrolling Capture needs Accessibility access so \(AppBranding.displayName) can scroll the selected app while capturing."
        case .invalidViewport:
            return "The selected scrolling area was too small to capture."
        case .noScrollableTarget:
            return "No scrollable area was found at the selected location. Select inside a scrollable page, document, or list and try again."
        case .firstFrameUnavailable:
            return "The first scrolling capture frame could not be captured."
        case .stitchingFailed:
            return "\(AppBranding.displayName) could not stitch the scrolling capture with enough confidence."
        case .cancelled:
            return "Scrolling capture was cancelled."
        }
    }
}

final class ScrollingCaptureCancellation: @unchecked Sendable {
    private enum RequestedAction {
        case none
        case cancel
        case finish
    }

    private let lock = NSLock()
    private var requestedAction = RequestedAction.none

    func cancel() {
        lock.lock()
        requestedAction = .cancel
        lock.unlock()
    }

    func finish() {
        lock.lock()
        if requestedAction == .none {
            requestedAction = .finish
        }
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let action = requestedAction
        lock.unlock()

        if action == .cancel || Task.isCancelled {
            throw ScrollingCaptureError.cancelled
        }
    }

    func shouldFinish() -> Bool {
        lock.lock()
        let action = requestedAction
        lock.unlock()

        return action == .finish
    }
}

struct ScrollingCaptureProgress: @unchecked Sendable {
    let segmentCount: Int
    let outputHeight: Int
    let maxOutputHeight: Int
    let warning: String?
    let previewImage: CGImage?

    /// Fraction of the maximum capture capacity consumed, clamped to 0…1.
    var capacityFraction: Double {
        guard maxOutputHeight > 0 else { return 0 }
        return min(Double(outputHeight) / Double(maxOutputHeight), 1.0)
    }
}

protocol ScrollDriver {
    var sourceName: String { get }
    func snapshotPosition() -> Double?
    func restorePosition(_ position: Double)
    func scrollDown(logicalDistance: CGFloat)
    func isAtEnd(previousPosition: Double?) -> Bool
}

struct AccessibilityScrollDriver: ScrollDriver {
    private let element: AccessibilityElementHandle
    private let scrollBar: AccessibilityElementHandle?
    private let centerPoint: CGPoint
    private let accessibility: any AccessibilityPlatform
    private let screens: any ScreenTopologyProviding
    let sourceName: String

    private struct ResolvedTarget {
        let element: AccessibilityElementHandle
        let scrollBar: AccessibilityElementHandle?
        let capturePoint: CGPoint
        let accessibilityPoint: CGPoint
    }

    private struct WindowTarget {
        let ownerPID: pid_t
        let ownerName: String
        let bundleIdentifier: String?
        let frame: CGRect
        let focusRank: Int
    }

    init(
        point: CGPoint,
        permissions: any CapturePermissionServicing,
        accessibility: any AccessibilityPlatform = LiveAccessibilityPlatform(),
        screens: any ScreenTopologyProviding = SystemScreenTopologyService()
    ) throws {
        try self.init(
            viewportRect: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2),
            permissions: permissions,
            accessibility: accessibility,
            screens: screens
        )
    }

    init(
        viewportRect: CGRect,
        permissions: any CapturePermissionServicing,
        accessibility: any AccessibilityPlatform = LiveAccessibilityPlatform(),
        screens: any ScreenTopologyProviding = SystemScreenTopologyService()
    ) throws {
        guard permissions.currentStatus().hasAccessibility else {
            ScrollingCaptureDiagnostics.error("Accessibility permission missing before resolving scroll target")
            throw ScrollingCaptureError.accessibilityPermissionDenied
        }

        self.accessibility = accessibility
        self.screens = screens
        ScrollingCaptureDiagnostics.info(
            "Resolving scroll target rect=\(Self.describe(viewportRect))"
        )

        let coordinateMappings = Self.currentCoordinateMappings(screens: screens)
        let accessibilityRect = Self.accessibilityRect(
            fromCaptureRect: viewportRect,
            mappings: coordinateMappings
        )

        ScrollingCaptureDiagnostics.info(
            "Accessibility target rect=\(Self.describe(accessibilityRect)) mappings=\(coordinateMappings.count)"
        )

        guard let target = Self.resolveTarget(
            in: viewportRect,
            accessibilityRect: accessibilityRect,
            coordinateMappings: coordinateMappings,
            accessibility: accessibility
        ) else {
            ScrollingCaptureDiagnostics.error(
                "No scroll target resolved rect=\(Self.describe(viewportRect))"
            )
            throw ScrollingCaptureError.noScrollableTarget
        }

        element = target.element
        scrollBar = target.scrollBar
        centerPoint = target.capturePoint
        sourceName = Self.sourceName(for: target.element, accessibility: accessibility)

        ScrollingCaptureDiagnostics.info(
            "Resolved scroll target role=\(Self.roleDescription(for: target.element, accessibility: accessibility)) bundle=\(Self.bundleIdentifier(for: target.element, accessibility: accessibility) ?? "unknown") hasScrollBar=\(target.scrollBar != nil) capturePoint=\(Self.describe(target.capturePoint)) axPoint=\(Self.describe(target.accessibilityPoint)) source=\(sourceName)"
        )
    }

    private static func resolveTarget(
        in viewportRect: CGRect,
        accessibilityRect: CGRect,
        coordinateMappings: [CaptureAccessibilityTransform],
        accessibility: any AccessibilityPlatform
    ) -> ResolvedTarget? {
        let systemElement = accessibility.systemWideElement()
        var fallbackTarget: ResolvedTarget?

        for point in candidatePoints(in: viewportRect) {
            let hitTestPoints = axHitTestPoints(
                forCapturePoint: point,
                coordinateMappings: coordinateMappings
            )

            for hitTestPoint in hitTestPoints {
                let hitResult = accessibility.element(at: hitTestPoint.accessibilityPoint, from: systemElement)
                let hitElement = hitResult.element

                guard hitResult.status == .success, let hitElement else {
                    ScrollingCaptureDiagnostics.info(
                        "AX hit test failed mode=\(hitTestPoint.mode) capturePoint=\(describe(point)) axPoint=\(describe(hitTestPoint.accessibilityPoint)) error=\(hitResult.status.rawValue)"
                    )
                    continue
                }

                ScrollingCaptureDiagnostics.info(
                    "AX hit mode=\(hitTestPoint.mode) capturePoint=\(describe(point)) axPoint=\(describe(hitTestPoint.accessibilityPoint)) role=\(roleDescription(for: hitElement, accessibility: accessibility)) bundle=\(bundleIdentifier(for: hitElement, accessibility: accessibility) ?? "unknown")"
                )

                if let scrollable = Self.scrollableElement(
                    startingAt: hitElement,
                    containing: hitTestPoint.accessibilityPoint,
                    accessibility: accessibility
                ) {
                    ScrollingCaptureDiagnostics.info(
                        "AX scrollable target found mode=\(hitTestPoint.mode) axPoint=\(describe(hitTestPoint.accessibilityPoint)) role=\(roleDescription(for: scrollable.element, accessibility: accessibility)) hasScrollBar=\(scrollable.scrollBar != nil)"
                    )
                    return ResolvedTarget(
                        element: scrollable.element,
                        scrollBar: scrollable.scrollBar,
                        capturePoint: point,
                        accessibilityPoint: hitTestPoint.accessibilityPoint
                    )
                }

                if fallbackTarget == nil, allowsWheelFallback(for: hitElement, accessibility: accessibility) {
                    ScrollingCaptureDiagnostics.info(
                        "Using browser wheel fallback mode=\(hitTestPoint.mode) capturePoint=\(describe(point)) axPoint=\(describe(hitTestPoint.accessibilityPoint)) bundle=\(bundleIdentifier(for: hitElement, accessibility: accessibility) ?? "unknown") role=\(roleDescription(for: hitElement, accessibility: accessibility))"
                    )
                    fallbackTarget = ResolvedTarget(
                        element: hitElement,
                        scrollBar: nil,
                        capturePoint: point,
                        accessibilityPoint: hitTestPoint.accessibilityPoint
                    )
                }
            }
        }

        if let fallbackTarget {
            return fallbackTarget
        }

        return resolveWindowTarget(
            in: viewportRect,
            accessibilityRect: accessibilityRect,
            coordinateMappings: coordinateMappings,
            accessibility: accessibility
        )
    }

    private static func candidatePoints(in viewportRect: CGRect) -> [CGPoint] {
        let rect = viewportRect.gscIntegralStandardized
        let insetX = min(max(rect.width * 0.2, 12), max(rect.width / 2 - 1, 1))
        let insetY = min(max(rect.height * 0.2, 12), max(rect.height / 2 - 1, 1))

        return [
            CGPoint(x: rect.midX, y: rect.midY),
            CGPoint(x: rect.midX, y: rect.minY + insetY),
            CGPoint(x: rect.midX, y: rect.maxY - insetY),
            CGPoint(x: rect.minX + insetX, y: rect.midY),
            CGPoint(x: rect.maxX - insetX, y: rect.midY)
        ]
    }

    private struct AXHitTestPoint {
        let mode: String
        let accessibilityPoint: CGPoint
    }

    private static func axHitTestPoints(
        forCapturePoint capturePoint: CGPoint,
        coordinateMappings: [CaptureAccessibilityTransform]
    ) -> [AXHitTestPoint] {
        let mappedPoint = Self.accessibilityPoint(
            fromCapturePoint: capturePoint,
            mappings: coordinateMappings
        )
        var points = [AXHitTestPoint(mode: "mapped", accessibilityPoint: mappedPoint)]

        if hypot(mappedPoint.x - capturePoint.x, mappedPoint.y - capturePoint.y) > 0.5 {
            points.append(AXHitTestPoint(mode: "capture", accessibilityPoint: capturePoint))
        }

        return points
    }

    func snapshotPosition() -> Double? {
        guard let scrollBar,
              let value = Self.attribute("AXValue", from: scrollBar, accessibility: accessibility) as? NSNumber else {
            return nil
        }

        return value.doubleValue
    }

    func restorePosition(_ position: Double) {
        guard let scrollBar else {
            ScrollingCaptureDiagnostics.debug("Skipping scroll position restore because AX scroll value is unavailable")
            return
        }

        ScrollingCaptureDiagnostics.debug("Restoring scroll position to \(position)")
        accessibility.setNumberAttribute("AXValue", value: position, on: scrollBar)
    }

    func scrollDown(logicalDistance: CGFloat) {
        let cursorLocationBeforeScroll = CGEvent(source: nil)?.location
        let magnitude = max(Int32(abs(logicalDistance).rounded()), 24)
        let wheelDelta = logicalDistance >= 0 ? -magnitude : magnitude
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: wheelDelta,
            wheel2: 0,
            wheel3: 0
        )

        event?.location = centerPoint
        event?.post(tap: .cghidEventTap)
        if let cursorLocationBeforeScroll {
            CGWarpMouseCursorPosition(cursorLocationBeforeScroll)
        }
        ScrollingCaptureDiagnostics.debug(
            "Posted scroll wheel distance=\(logicalDistance) wheelDelta=\(wheelDelta) point=\(Self.describe(centerPoint))"
        )
    }

    func isAtEnd(previousPosition: Double?) -> Bool {
        guard let previousPosition, let current = snapshotPosition() else {
            return false
        }

        return abs(current - previousPosition) < 0.0001
    }

    private static func scrollableElement(
        startingAt element: AccessibilityElementHandle,
        containing point: CGPoint,
        accessibility: any AccessibilityPlatform
    ) -> (element: AccessibilityElementHandle, scrollBar: AccessibilityElementHandle?)? {
        var current: AccessibilityElementHandle? = element
        var ancestors: [AccessibilityElementHandle] = []

        for _ in 0..<16 {
            guard let candidate = current else {
                break
            }

            ancestors.append(candidate)
            let scrollBar = elementAttribute("AXVerticalScrollBar", from: candidate, accessibility: accessibility)
            if scrollBar != nil || looksScrollable(candidate, accessibility: accessibility) {
                return (candidate, scrollBar)
            }

            current = elementAttribute("AXParent", from: candidate, accessibility: accessibility)
        }

        for ancestor in ancestors {
            if let descendant = scrollableDescendant(in: ancestor, containing: point, accessibility: accessibility) {
                return descendant
            }
        }

        return nil
    }

    private static func looksScrollable(_ element: AccessibilityElementHandle, accessibility: any AccessibilityPlatform) -> Bool {
        let role = attribute("AXRole", from: element, accessibility: accessibility) as? String
        if role == "AXScrollArea" || role == "AXWebArea" || role == "AXTable" || role == "AXOutline" || role == "AXList" || role == "AXBrowser" {
            return true
        }

        let result = accessibility.copyActionNames(from: element)
        guard result.status == .success else {
            return false
        }

        return result.names.contains("AXScrollDown") || result.names.contains("AXScrollToVisible")
    }

    private static func scrollableDescendant(
        in root: AccessibilityElementHandle,
        containing point: CGPoint,
        accessibility: any AccessibilityPlatform
    ) -> (element: AccessibilityElementHandle, scrollBar: AccessibilityElementHandle?)? {
        var queue = elementChildren(of: root, accessibility: accessibility)
        var inspectedCount = 0

        while let candidate = queue.first, inspectedCount < 240 {
            queue.removeFirst()
            inspectedCount += 1

            if let frame = accessibility.frame(of: candidate), !frame.insetBy(dx: -2, dy: -2).contains(point) {
                continue
            }

            let scrollBar = elementAttribute("AXVerticalScrollBar", from: candidate, accessibility: accessibility)
            if scrollBar != nil || looksScrollable(candidate, accessibility: accessibility) {
                return (candidate, scrollBar)
            }

            queue.append(contentsOf: elementChildren(of: candidate, accessibility: accessibility))
        }

        return nil
    }

    private static func allowsWheelFallback(for element: AccessibilityElementHandle, accessibility: any AccessibilityPlatform) -> Bool {
        guard let bundleIdentifier = bundleIdentifier(for: element, accessibility: accessibility) else {
            return false
        }

        return allowsBrowserWheelFallback(bundleIdentifier: bundleIdentifier)
    }

    private static func allowsBrowserWheelFallback(bundleIdentifier: String) -> Bool {
        return [
            "com.apple.Safari",
            "com.apple.SafariTechnologyPreview",
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "org.mozilla.firefox",
            "com.brave.Browser"
        ].contains(bundleIdentifier)
    }

    private static func resolveWindowTarget(
        in viewportRect: CGRect,
        accessibilityRect: CGRect,
        coordinateMappings: [CaptureAccessibilityTransform],
        accessibility: any AccessibilityPlatform
    ) -> ResolvedTarget? {
        guard let windowTarget = windowTarget(under: viewportRect) else {
            ScrollingCaptureDiagnostics.info("Window fallback found no candidate under rect=\(describe(viewportRect))")
            return nil
        }

        let point = CGPoint(x: viewportRect.midX, y: viewportRect.midY)
        let accessibilityPoint = Self.accessibilityPoint(
            fromCapturePoint: point,
            mappings: coordinateMappings
        )
        let appElement = accessibility.applicationElement(processID: windowTarget.ownerPID)
        ScrollingCaptureDiagnostics.info(
            "Window fallback candidate owner=\(windowTarget.ownerName) pid=\(windowTarget.ownerPID) bundle=\(windowTarget.bundleIdentifier ?? "unknown") frame=\(describe(windowTarget.frame)) rank=\(windowTarget.focusRank)"
        )

        if let scrollable = scrollableDescendant(
            in: appElement,
            containing: accessibilityPoint,
            accessibility: accessibility
        ) {
            ScrollingCaptureDiagnostics.info(
                "Window fallback resolved AX descendant role=\(roleDescription(for: scrollable.element, accessibility: accessibility)) hasScrollBar=\(scrollable.scrollBar != nil) axRect=\(describe(accessibilityRect))"
            )
            return ResolvedTarget(
                element: scrollable.element,
                scrollBar: scrollable.scrollBar,
                capturePoint: point,
                accessibilityPoint: accessibilityPoint
            )
        }

        if let bundleIdentifier = windowTarget.bundleIdentifier,
           allowsBrowserWheelFallback(bundleIdentifier: bundleIdentifier) {
            ScrollingCaptureDiagnostics.info(
                "Window fallback using browser wheel target owner=\(windowTarget.ownerName) bundle=\(bundleIdentifier) capturePoint=\(describe(point)) axPoint=\(describe(accessibilityPoint))"
            )
            return ResolvedTarget(
                element: appElement,
                scrollBar: nil,
                capturePoint: point,
                accessibilityPoint: accessibilityPoint
            )
        }

        ScrollingCaptureDiagnostics.info(
            "Window fallback using generic wheel target owner=\(windowTarget.ownerName) bundle=\(windowTarget.bundleIdentifier ?? "unknown") capturePoint=\(describe(point)) axPoint=\(describe(accessibilityPoint))"
        )
        return ResolvedTarget(
            element: appElement,
            scrollBar: nil,
            capturePoint: point,
            accessibilityPoint: accessibilityPoint
        )
    }

    private static func currentCoordinateMappings(screens: any ScreenTopologyProviding) -> [CaptureAccessibilityTransform] {
        screens.screens.compactMap { screen in
            let captureFrame = CGDisplayBounds(screen.displayID)
            guard captureFrame.width > 0, captureFrame.height > 0 else {
                return nil
            }

            return CaptureAccessibilityTransform(
                captureFrame: captureFrame,
                accessibilityFrame: screen.frame
            )
        }
    }

    private static func accessibilityPoint(
        fromCapturePoint point: CGPoint,
        mappings: [CaptureAccessibilityTransform]
    ) -> CGPoint {
        if let mapping = mappings.first(where: { $0.containsCapturePoint(point) }) {
            return mapping.accessibilityPoint(fromCapturePoint: point)
        }

        return point
    }

    private static func accessibilityRect(
        fromCaptureRect rect: CGRect,
        mappings: [CaptureAccessibilityTransform]
    ) -> CGRect {
        if let mapping = mappings.first(where: { $0.intersectsCaptureRect(rect) }) {
            return mapping.accessibilityRect(fromCaptureRect: rect)
        }

        return rect.gscIntegralStandardized
    }

    private static func windowTarget(under viewportRect: CGRect) -> WindowTarget? {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let processID = ProcessInfo.processInfo.processIdentifier
        let viewportCenter = CGPoint(x: viewportRect.midX, y: viewportRect.midY)

        return windowInfo.enumerated().compactMap { index, info -> WindowTarget? in
            guard let ownerPIDNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPIDNumber.int32Value != processID,
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  frame.width >= 60,
                  frame.height >= 40 else {
                return nil
            }

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else {
                return nil
            }

            let containsCenter = frame.contains(viewportCenter)
            let intersectsViewport = frame.intersects(viewportRect)
            guard containsCenter || intersectsViewport else {
                return nil
            }

            let ownerPID = ownerPIDNumber.int32Value
            let app = NSRunningApplication(processIdentifier: ownerPID)
            let ownerName = (info[kCGWindowOwnerName as String] as? String)
                ?? app?.localizedName
                ?? "Window"

            return WindowTarget(
                ownerPID: ownerPID,
                ownerName: ownerName,
                bundleIdentifier: app?.bundleIdentifier,
                frame: frame,
                focusRank: index
            )
        }.min { left, right in
            let leftContainsCenter = left.frame.contains(viewportCenter)
            let rightContainsCenter = right.frame.contains(viewportCenter)

            if leftContainsCenter != rightContainsCenter {
                return leftContainsCenter
            }

            return left.focusRank < right.focusRank
        }
    }

    private static func sourceName(
        for element: AccessibilityElementHandle,
        accessibility: any AccessibilityPlatform
    ) -> String {
        let processResult = accessibility.processIdentifier(for: element)
        if processResult.status == .success,
           let appName = NSRunningApplication(processIdentifier: processResult.processID)?.localizedName,
           !appName.isEmpty {
            return "Scrolling Capture - \(appName)"
        }

        return "Scrolling Capture"
    }

    private static func roleDescription(
        for element: AccessibilityElementHandle,
        accessibility: any AccessibilityPlatform
    ) -> String {
        attribute("AXRole", from: element, accessibility: accessibility) as? String ?? "unknown"
    }

    private static func describe(_ point: CGPoint) -> String {
        "(\(Int(point.x)),\(Int(point.y)))"
    }

    private static func describe(_ rect: CGRect) -> String {
        "x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height))"
    }

    private static func bundleIdentifier(
        for element: AccessibilityElementHandle,
        accessibility: any AccessibilityPlatform
    ) -> String? {
        let processResult = accessibility.processIdentifier(for: element)
        guard processResult.status == .success else {
            return nil
        }

        return NSRunningApplication(processIdentifier: processResult.processID)?.bundleIdentifier
    }

    private static func attribute(
        _ name: String,
        from element: AccessibilityElementHandle,
        accessibility: any AccessibilityPlatform
    ) -> Any? {
        let result = accessibility.copyAttribute(name, from: element)
        return result.status == .success ? result.value : nil
    }

    private static func elementAttribute(
        _ name: String,
        from element: AccessibilityElementHandle,
        accessibility: any AccessibilityPlatform
    ) -> AccessibilityElementHandle? {
        attribute(name, from: element, accessibility: accessibility) as? AccessibilityElementHandle
    }

    private static func elementChildren(
        of element: AccessibilityElementHandle,
        accessibility: any AccessibilityPlatform
    ) -> [AccessibilityElementHandle] {
        let attributeNames = ["AXVisibleChildren", "AXChildren", "AXRows"]

        for attributeName in attributeNames {
            if let children = attribute(
                attributeName,
                from: element,
                accessibility: accessibility
            ) as? [AccessibilityElementHandle],
                !children.isEmpty {
                return children
            }
        }

        return []
    }
}

struct ScrollingCaptureService {
    private static let primaryScrollFraction: CGFloat = 0.75
    private static let retryScrollFraction: CGFloat = 0.45
    private static let postScrollSettleDelayNanoseconds: UInt64 = 220_000_000
    private static let cursorSettleDelayNanoseconds: UInt64 = 160_000_000

    var captureService: any ScreenCaptureServiceType
    let permissions: any CapturePermissionServicing
    let accessibility: any AccessibilityPlatform
    let screens: any ScreenTopologyProviding
    let scheduler: any Scheduling
    let clock: any ClockProviding
    var driverFactory: (CGRect) throws -> any ScrollDriver
    var stitcher: ScrollingStitcher

    init(
        captureService: any ScreenCaptureServiceType,
        permissions: any CapturePermissionServicing,
        accessibility: any AccessibilityPlatform = LiveAccessibilityPlatform(),
        screens: any ScreenTopologyProviding = SystemScreenTopologyService(),
        scheduler: any Scheduling = SystemScheduler(),
        clock: any ClockProviding = SystemClock(),
        driverFactory: ((CGRect) throws -> any ScrollDriver)? = nil,
        stitcher: ScrollingStitcher = ScrollingStitcher()
    ) {
        self.captureService = captureService
        self.permissions = permissions
        self.accessibility = accessibility
        self.screens = screens
        self.scheduler = scheduler
        self.clock = clock
        self.driverFactory = driverFactory ?? { viewportRect in
            try AccessibilityScrollDriver(
                viewportRect: viewportRect,
                permissions: permissions,
                accessibility: accessibility,
                screens: screens
            )
        }
        self.stitcher = stitcher
    }

    func resolveTarget(for request: ScrollingCaptureRequest) throws -> ScrollingCaptureTarget {
        try CaptureContentDiagnostics.$current.withValue(
            CaptureContentDiagnostics(
                isPrivateCapture: request.isPrivateCapture
            )
        ) {
            try resolveTargetWithDiagnostics(for: request)
        }
    }

    private func resolveTargetWithDiagnostics(
        for request: ScrollingCaptureRequest
    ) throws -> ScrollingCaptureTarget {
        guard request.viewportRect.width > 8, request.viewportRect.height > 8 else {
            throw ScrollingCaptureError.invalidViewport
        }
        guard permissions.currentStatus().hasAccessibility else {
            throw ScrollingCaptureError.accessibilityPermissionDenied
        }

        let driver = try driverFactory(request.viewportRect)
        return ScrollingCaptureTarget(sourceName: driver.sourceName, viewportRect: request.viewportRect)
    }

    func capture(
        request: ScrollingCaptureRequest,
        cancellation: ScrollingCaptureCancellation,
        progressHandler: (@MainActor (ScrollingCaptureProgress) -> Void)? = nil
    ) async throws -> ScrollingCaptureResult {
        try await CaptureContentDiagnostics.$current.withValue(
            CaptureContentDiagnostics(
                isPrivateCapture: request.isPrivateCapture
            )
        ) {
            try await captureWithDiagnostics(
                request: request,
                cancellation: cancellation,
                progressHandler: progressHandler
            )
        }
    }

    private func captureWithDiagnostics(
        request: ScrollingCaptureRequest,
        cancellation: ScrollingCaptureCancellation,
        progressHandler: (@MainActor (ScrollingCaptureProgress) -> Void)?
    ) async throws -> ScrollingCaptureResult {
        ScrollingCaptureDiagnostics.reset()
        ScrollingCaptureDiagnostics.info(
            "Starting capture rect=\(Self.describe(request.viewportRect)) maxSegments=\(request.maxSegmentCount) maxHeight=\(request.maxOutputHeight)"
        )

        guard request.viewportRect.width > 8, request.viewportRect.height > 8 else {
            ScrollingCaptureDiagnostics.error("Invalid viewport rect=\(Self.describe(request.viewportRect))")
            throw ScrollingCaptureError.invalidViewport
        }

        guard permissions.currentStatus().hasAccessibility else {
            ScrollingCaptureDiagnostics.error("Accessibility permission missing at capture preflight")
            throw ScrollingCaptureError.accessibilityPermissionDenied
        }

        let driver = try driverFactory(request.viewportRect)
        let originalPosition = driver.snapshotPosition()
        let originalPositionDescription = originalPosition.map { String($0) } ?? "unavailable"
        let parkedCursorLocation = parkCursorAwayFromViewport(request.viewportRect)
        ScrollingCaptureDiagnostics.info(
            "Scroll driver ready source=\(driver.sourceName) originalPosition=\(originalPositionDescription)"
        )

        do {
            let result = try await captureLoop(
                request: request,
                sourceName: driver.sourceName,
                driver: driver,
                cancellation: cancellation,
                progressHandler: progressHandler
            )

            if let originalPosition {
                driver.restorePosition(originalPosition)
            }
            restoreCursor(to: parkedCursorLocation)

            ScrollingCaptureDiagnostics.info(
                "Finished capture segmentsResultHeight=\(result.image.height) warnings=\(result.warnings.count)"
            )
            return result
        } catch {
            ScrollingCaptureDiagnostics.error("Capture failed error=\(error.localizedDescription)")
            if let originalPosition {
                driver.restorePosition(originalPosition)
            }
            restoreCursor(to: parkedCursorLocation)
            throw error
        }
    }

    private func captureLoop(
        request: ScrollingCaptureRequest,
        sourceName: String,
        driver: any ScrollDriver,
        cancellation: ScrollingCaptureCancellation,
        progressHandler: (@MainActor (ScrollingCaptureProgress) -> Void)?
    ) async throws -> ScrollingCaptureResult {
        var warnings: [String] = []
        try await scheduler.sleep(nanoseconds: Self.cursorSettleDelayNanoseconds)
        let firstCaptureStart = DispatchTime.now()
        let firstCapture = try await captureService.captureRegionWithinSingleDisplayDirect(in: request.viewportRect)
        let firstCaptureDuration = Self.elapsedMilliseconds(since: firstCaptureStart)
        var stitched = try stitcher.initialState(with: firstCapture.image, maxOutputHeight: request.maxOutputHeight)
        var previousImage = firstCapture.image
        var previousGray = stitcher.makeGrayImage(for: firstCapture.image)
        ScrollingCaptureDiagnostics.info(
            "Captured first segment pixels=\(firstCapture.image.width)x\(firstCapture.image.height) captureMs=\(firstCaptureDuration)"
        )
        await MainActor.run {
            progressHandler?(ScrollingCaptureProgress(
                segmentCount: stitched.segmentCount,
                outputHeight: stitched.outputHeight,
                maxOutputHeight: request.maxOutputHeight,
                warning: nil,
                previewImage: stitched.makeImage()
            ))
        }

        do {
        for segmentIndex in 1..<request.maxSegmentCount {
            try cancellation.checkCancellation()
            if cancellation.shouldFinish() {
                ScrollingCaptureDiagnostics.info("Stopping capture because user chose Done before segment=\(segmentIndex + 1)")
                break
            }

            let previousPosition = driver.snapshotPosition()
            let previousPositionDescription = previousPosition.map { String($0) } ?? "unavailable"
            ScrollingCaptureDiagnostics.debug(
                "Preparing segment=\(segmentIndex + 1) previousPosition=\(previousPositionDescription)"
            )
            let scrollStart = DispatchTime.now()
            driver.scrollDown(logicalDistance: request.viewportRect.height * Self.primaryScrollFraction)
            try await scheduler.sleep(nanoseconds: Self.postScrollSettleDelayNanoseconds)
            let scrollWaitDuration = Self.elapsedMilliseconds(since: scrollStart)
            try cancellation.checkCancellation()
            if cancellation.shouldFinish() {
                ScrollingCaptureDiagnostics.info(
                    "Stopping capture because user chose Done after scroll segment=\(segmentIndex + 1) scrollWaitMs=\(scrollWaitDuration)"
                )
                break
            }

            let captureStart = DispatchTime.now()
            var nextImage = try await captureService.captureRegionWithinSingleDisplayDirect(in: request.viewportRect).image
            let captureDuration = Self.elapsedMilliseconds(since: captureStart)
            let nextGray = stitcher.makeGrayImage(for: nextImage)

            let duplicateStart = DispatchTime.now()
            let duplicateFrame = stitcher.imagesAreDuplicate(previousImage, nextImage, lhsGray: previousGray, rhsGray: nextGray)
            let atEnd = driver.isAtEnd(previousPosition: previousPosition)
            let duplicateDuration = Self.elapsedMilliseconds(since: duplicateStart)
            if duplicateFrame || atEnd {
                ScrollingCaptureDiagnostics.info(
                    "Stopping capture at segment=\(segmentIndex + 1) duplicateFrame=\(duplicateFrame) atEnd=\(atEnd) scrollWaitMs=\(scrollWaitDuration) captureMs=\(captureDuration) duplicateMs=\(duplicateDuration)"
                )
                break
            }

            let stitchStart = DispatchTime.now()
            let appendResult: ScrollingStitchAppendResult
            if let previousGray, let nextGray {
                appendResult = stitcher.append(nextImage, after: previousImage, previousGray: previousGray, nextGray: nextGray, to: &stitched)
            } else {
                appendResult = stitcher.append(nextImage, after: previousImage, to: &stitched)
            }
            let stitchDuration = Self.elapsedMilliseconds(since: stitchStart)
            switch appendResult {
            case .appended:
                previousImage = nextImage
                previousGray = nextGray
                ScrollingCaptureDiagnostics.info(
                    "Appended segment=\(segmentIndex + 1) stitchedSegments=\(stitched.segmentCount) outputHeight=\(stitched.outputHeight) scrollWaitMs=\(scrollWaitDuration) captureMs=\(captureDuration) duplicateMs=\(duplicateDuration) stitchMs=\(stitchDuration)"
                )
            case .reachedMaximumHeight:
                warnings.append("The scrolling capture reached the maximum output height and was stopped early.")
                ScrollingCaptureDiagnostics.info(
                    "Stopping at max output height segment=\(segmentIndex + 1) outputHeight=\(stitched.outputHeight) scrollWaitMs=\(scrollWaitDuration) captureMs=\(captureDuration) duplicateMs=\(duplicateDuration) stitchMs=\(stitchDuration)"
                )
                guard let outputImage = stitched.makeImage() else {
                    ScrollingCaptureDiagnostics.error("Failed to compose stitched image at max output height")
                    throw ScrollingCaptureError.stitchingFailed
                }
                return ScrollingCaptureResult(
                    image: outputImage,
                    sourceViewportRect: request.viewportRect,
                    sourceName: sourceName,
                    capturedAt: clock.now(),
                    warnings: warnings
                )
            case .lowConfidence:
                ScrollingCaptureDiagnostics.info(
                    "Low stitch confidence segment=\(segmentIndex + 1); retrying with smaller scroll step scrollWaitMs=\(scrollWaitDuration) captureMs=\(captureDuration) duplicateMs=\(duplicateDuration) stitchMs=\(stitchDuration)"
                )
                let retryScrollStart = DispatchTime.now()
                driver.scrollDown(logicalDistance: -(request.viewportRect.height * Self.retryScrollFraction))
                try await scheduler.sleep(nanoseconds: Self.postScrollSettleDelayNanoseconds)
                driver.scrollDown(logicalDistance: request.viewportRect.height * Self.retryScrollFraction)
                try await scheduler.sleep(nanoseconds: Self.postScrollSettleDelayNanoseconds)
                let retryScrollDuration = Self.elapsedMilliseconds(since: retryScrollStart)
                let retryCaptureStart = DispatchTime.now()
                nextImage = try await captureService.captureRegionWithinSingleDisplayDirect(in: request.viewportRect).image
                let retryCaptureDuration = Self.elapsedMilliseconds(since: retryCaptureStart)
                let retryGray = stitcher.makeGrayImage(for: nextImage)

                if stitcher.imagesAreDuplicate(previousImage, nextImage, lhsGray: previousGray, rhsGray: retryGray) {
                    ScrollingCaptureDiagnostics.info(
                        "Stopping after retry because frame duplicated segment=\(segmentIndex + 1) retryScrollMs=\(retryScrollDuration) retryCaptureMs=\(retryCaptureDuration)"
                    )
                    break
                }

                let retryStitchStart = DispatchTime.now()
                let retryResult: ScrollingStitchAppendResult
                if let previousGray, let retryGray {
                    retryResult = stitcher.append(nextImage, after: previousImage, previousGray: previousGray, nextGray: retryGray, to: &stitched)
                } else {
                    retryResult = stitcher.append(nextImage, after: previousImage, to: &stitched)
                }
                let retryStitchDuration = Self.elapsedMilliseconds(since: retryStitchStart)
                switch retryResult {
                case .appended:
                    previousImage = nextImage
                    previousGray = retryGray
                    warnings.append("\(AppBranding.displayName) reduced one scroll step to keep stitching aligned.")
                    ScrollingCaptureDiagnostics.info(
                        "Retry append succeeded segment=\(segmentIndex + 1) stitchedSegments=\(stitched.segmentCount) retryScrollMs=\(retryScrollDuration) retryCaptureMs=\(retryCaptureDuration) retryStitchMs=\(retryStitchDuration)"
                    )
                case .reachedMaximumHeight:
                    warnings.append("The scrolling capture reached the maximum output height and was stopped early.")
                    ScrollingCaptureDiagnostics.info(
                        "Retry append reached max output height segment=\(segmentIndex + 1) outputHeight=\(stitched.outputHeight) retryScrollMs=\(retryScrollDuration) retryCaptureMs=\(retryCaptureDuration) retryStitchMs=\(retryStitchDuration)"
                    )
                    guard let outputImage = stitched.makeImage() else {
                        ScrollingCaptureDiagnostics.error("Failed to compose stitched image after retry max output height")
                        throw ScrollingCaptureError.stitchingFailed
                    }
                    return ScrollingCaptureResult(
                        image: outputImage,
                        sourceViewportRect: request.viewportRect,
                        sourceName: sourceName,
                        capturedAt: clock.now(),
                        warnings: warnings
                    )
                case .lowConfidence:
                    if stitched.segmentCount >= 2 {
                        warnings.append("Scrolling capture stopped early because later frames could not be stitched confidently.")
                        ScrollingCaptureDiagnostics.info(
                            "Returning partial result after low-confidence retry stitchedSegments=\(stitched.segmentCount) retryScrollMs=\(retryScrollDuration) retryCaptureMs=\(retryCaptureDuration) retryStitchMs=\(retryStitchDuration)"
                        )
                        guard let outputImage = stitched.makeImage() else {
                            ScrollingCaptureDiagnostics.error("Failed to compose partial stitched image")
                            throw ScrollingCaptureError.stitchingFailed
                        }
                        throw ScrollingCaptureInterruptedError(
                            partialResult: ScrollingCaptureResult(
                                image: outputImage,
                                sourceViewportRect: request.viewportRect,
                                sourceName: sourceName,
                                capturedAt: clock.now(),
                                warnings: warnings
                            ),
                            reason: "Later frames could not be stitched confidently."
                        )
                    }

                    ScrollingCaptureDiagnostics.error("Stitching failed before useful partial result")
                    throw ScrollingCaptureError.stitchingFailed
                }
            }

            await MainActor.run {
                progressHandler?(ScrollingCaptureProgress(
                    segmentCount: stitched.segmentCount,
                    outputHeight: stitched.outputHeight,
                    maxOutputHeight: request.maxOutputHeight,
                    warning: warnings.last,
                    previewImage: stitched.makeImage()
                ))
            }
        }
        } catch ScrollingCaptureError.cancelled {
            throw ScrollingCaptureError.cancelled
        } catch let interruption as ScrollingCaptureInterruptedError {
            throw interruption
        } catch {
            guard let partialImage = stitched.makeImage() else {
                throw error
            }
            throw ScrollingCaptureInterruptedError(
                partialResult: ScrollingCaptureResult(
                    image: partialImage,
                    sourceViewportRect: request.viewportRect,
                    sourceName: sourceName,
                    capturedAt: clock.now(),
                    warnings: warnings + ["Capture stopped before reaching the end."]
                ),
                reason: error.localizedDescription
            )
        }

        guard stitched.segmentCount > 0 else {
            ScrollingCaptureDiagnostics.error("No stitched segments were available at end of loop")
            throw ScrollingCaptureError.firstFrameUnavailable
        }

        let composeStart = DispatchTime.now()
        guard let outputImage = stitched.makeImage() else {
            ScrollingCaptureDiagnostics.error("Failed to compose final stitched image")
            throw ScrollingCaptureError.stitchingFailed
        }
        let composeDuration = Self.elapsedMilliseconds(since: composeStart)

        ScrollingCaptureDiagnostics.info(
            "Returning stitched capture segments=\(stitched.segmentCount) outputPixels=\(outputImage.width)x\(outputImage.height) composeMs=\(composeDuration) warnings=\(warnings.count)"
        )
        return ScrollingCaptureResult(
            image: outputImage,
            sourceViewportRect: request.viewportRect,
            sourceName: sourceName,
            capturedAt: clock.now(),
            warnings: warnings
        )
    }

    private static func describe(_ rect: CGRect) -> String {
        "x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height))"
    }

    private static func describe(_ point: CGPoint) -> String {
        "x=\(Int(point.x)) y=\(Int(point.y))"
    }

    private func parkCursorAwayFromViewport(_ viewportRect: CGRect) -> CGPoint? {
        let originalLocation = CGEvent(source: nil)?.location
        guard let originalLocation else {
            return nil
        }

        let parkingLocation = MainActor.assumeIsolated {
            let screen = screens.screens.first(where: { $0.frame.intersects(viewportRect) }) ?? screens.mainScreen
            return Self.cursorParkingLocation(avoiding: viewportRect, on: screen?.visibleFrame)
        }

        guard let parkingLocation, parkingLocation != originalLocation else {
            return originalLocation
        }

        CGWarpMouseCursorPosition(parkingLocation)
        ScrollingCaptureDiagnostics.debug(
            "Parked cursor original=\(Self.describe(originalLocation)) parked=\(Self.describe(parkingLocation))"
        )
        return originalLocation
    }

    private func restoreCursor(to originalLocation: CGPoint?) {
        guard let originalLocation else {
            return
        }

        CGWarpMouseCursorPosition(originalLocation)
    }

    nonisolated static func cursorParkingLocation(avoiding viewportRect: CGRect, on visibleFrame: CGRect?) -> CGPoint? {
        let viewport = viewportRect.gscIntegralStandardized
        guard viewport.width > 0, viewport.height > 0 else {
            return nil
        }

        let bounds = (visibleFrame ?? viewport.insetBy(dx: -80, dy: -80)).gscIntegralStandardized
        let margin: CGFloat = 24
        let candidates = [
            CGPoint(x: viewport.maxX + margin, y: viewport.maxY + margin),
            CGPoint(x: viewport.minX - margin, y: viewport.maxY + margin),
            CGPoint(x: viewport.maxX + margin, y: viewport.minY - margin),
            CGPoint(x: viewport.minX - margin, y: viewport.minY - margin)
        ]

        for candidate in candidates where bounds.contains(candidate) && !viewport.contains(candidate) {
            return candidate
        }

        let clamped = CGPoint(
            x: min(max(viewport.maxX + margin, bounds.minX + margin), bounds.maxX - margin),
            y: min(max(viewport.maxY + margin, bounds.minY + margin), bounds.maxY - margin)
        )

        return viewport.contains(clamped) ? nil : clamped
    }

    private static func elapsedMilliseconds(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}

private final class ScrollingCaptureDiagnosticsClock: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var startNanoseconds = DispatchTime.now().uptimeNanoseconds

    nonisolated func reset() {
        lock.lock()
        startNanoseconds = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    nonisolated func timestamped(_ message: String) -> String {
        lock.lock()
        let start = startNanoseconds
        lock.unlock()

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        return String(format: "[+%.3fs] %@", elapsed, message)
    }
}

private enum ScrollingCaptureDiagnostics {
    nonisolated private static let clock = ScrollingCaptureDiagnosticsClock()

    nonisolated static func reset() {
        clock.reset()
    }

    nonisolated static func debug(
        _ message: @autoclosure () -> String
    ) {
        CaptureContentDiagnostics.current.debug(
            category: "ScrollingCapture",
            clock.timestamped(message())
        )
    }

    nonisolated static func info(
        _ message: @autoclosure () -> String
    ) {
        CaptureContentDiagnostics.current.info(
            category: "ScrollingCapture",
            clock.timestamped(message())
        )
    }

    nonisolated static func error(
        _ message: @autoclosure () -> String
    ) {
        CaptureContentDiagnostics.current.error(
            category: "ScrollingCapture",
            clock.timestamped(message())
        )
    }
}
#endif

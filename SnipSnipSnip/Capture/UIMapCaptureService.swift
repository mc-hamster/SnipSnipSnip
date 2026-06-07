import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

private enum UIMapCaptureDiagnostics {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.oontz.SnipSnipSnip",
        category: "UIMapCapture"
    )

    nonisolated static func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    nonisolated static func failure(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

@MainActor
protocol UIMapCaptureServiceType {
    func captureUIMap(for capture: CapturedScreenshot) -> UIMapSnapshot?
}

@MainActor
struct AccessibilityUIMapCaptureService: UIMapCaptureServiceType {
    private struct WindowCandidate {
        let ownerPID: pid_t
        let ownerName: String
        let bundleIdentifier: String?
        let frame: CGRect
        let focusRank: Int
    }

    private struct CaptureMapping {
        let captureSourceRect: CGRect
        let documentRect: CGRect
        let accessibilityMappings: [CaptureAccessibilityTransform]

        func documentRect(fromAccessibilityRect rect: CGRect) -> CGRect? {
            let captureRect = captureRect(fromAccessibilityRect: rect)
            let visibleCaptureRect = captureRect.intersection(captureSourceRect)

            guard visibleCaptureRect.width > 0,
                  visibleCaptureRect.height > 0 else {
                return nil
            }

            return TopLeftRectTransform(sourceBounds: captureSourceRect, targetBounds: documentRect)
                .targetRect(fromSourceRect: visibleCaptureRect)
                .gscIntegralStandardized
        }

        private func captureRect(fromAccessibilityRect rect: CGRect) -> CGRect {
            if let mapping = accessibilityMappings.first(where: { $0.intersectsAccessibilityRect(rect) }) {
                return mapping.captureRect(fromAccessibilityRect: rect)
            }

            return rect.gscIntegralStandardized
        }
    }

    private struct WindowRelativeMapping {
        let rootAccessibilityRect: CGRect
        let candidateDocumentRect: CGRect

        func documentRect(fromAccessibilityRect rect: CGRect) -> CGRect? {
            guard rootAccessibilityRect.width > 0,
                  rootAccessibilityRect.height > 0,
                  candidateDocumentRect.width > 0,
                  candidateDocumentRect.height > 0 else {
                return nil
            }

            let documentRect = TopLeftRectTransform(
                sourceBounds: rootAccessibilityRect,
                targetBounds: candidateDocumentRect
            )
                .targetRect(fromSourceRect: rect)
                .gscIntegralStandardized

            guard documentRect.width > 0,
                  documentRect.height > 0 else {
                return nil
            }

            return documentRect
        }
    }

    private let maxDepth = 12
    private let maxElementCount = 900

    func captureUIMap(for capture: CapturedScreenshot) -> UIMapSnapshot? {
        UIMapCaptureDiagnostics.notice(
            "[UIMap] capture requested sourceName='\(capture.sourceName)' kind='\(capture.kind.rawValue)' sourceRect=\(Self.describe(capture.sourceRect)) documentRect=\(Self.describe(capture.documentRect)) pixelSize=\(Int(capture.pixelSize.width))x\(Int(capture.pixelSize.height)) featureFlag=\(FeatureFlags.uiMapEnabled) axTrusted=\(AXIsProcessTrusted())"
        )

        guard FeatureFlags.uiMapEnabled else {
            UIMapCaptureDiagnostics.failure("[UIMap] capture skipped: feature flag disabled")
            return nil
        }

        guard AXIsProcessTrusted() else {
            UIMapCaptureDiagnostics.failure("[UIMap] capture skipped: Accessibility trust is false")
            return nil
        }

        let mapping = CaptureMapping(
            captureSourceRect: capture.sourceRect,
            documentRect: capture.documentRect,
            accessibilityMappings: Self.currentCoordinateMappings()
        )
        var remainingElementBudget = maxElementCount
        var visited = Set<CFHashCode>()
        let candidates = windowCandidates(intersecting: capture.sourceRect)
        UIMapCaptureDiagnostics.notice(
            "[UIMap] window candidate count=\(candidates.count) captureSourceRect=\(Self.describe(capture.sourceRect)) displayMappings=\(mapping.accessibilityMappings.count)"
        )
        for candidate in candidates.prefix(12) {
            UIMapCaptureDiagnostics.notice(
                "[UIMap] candidate owner='\(candidate.ownerName)' pid=\(candidate.ownerPID) bundle='\(candidate.bundleIdentifier ?? "nil")' frame=\(Self.describe(candidate.frame))"
            )
        }

        let elements = candidates
            .compactMap { candidate -> UIMapElement? in
                guard remainingElementBudget > 0 else {
                    return nil
                }

                return captureWindowElement(
                    for: candidate,
                    mapping: mapping,
                    visited: &visited,
                    remainingElementBudget: &remainingElementBudget
                )
            }

        guard !elements.isEmpty else {
            UIMapCaptureDiagnostics.failure(
                "[UIMap] capture produced no elements candidates=\(candidates.count) visitedAXElements=\(visited.count) remainingBudget=\(remainingElementBudget)"
            )
            return nil
        }

        let snapshot = UIMapSnapshot(capturedAt: Date(), sourceRect: capture.sourceRect, elements: elements)
        UIMapCaptureDiagnostics.notice(
            "[UIMap] capture succeeded rootElements=\(elements.count) flattenedElements=\(snapshot.elementCount) visitedAXElements=\(visited.count) remainingBudget=\(remainingElementBudget)"
        )
        return snapshot
    }

    private func captureWindowElement(
        for candidate: WindowCandidate,
        mapping: CaptureMapping,
        visited: inout Set<CFHashCode>,
        remainingElementBudget: inout Int
    ) -> UIMapElement? {
        let appElement = AXUIElementCreateApplication(candidate.ownerPID)
        let windowsResult = attributeResult("AXWindows", from: appElement)
        let windows = (windowsResult.value as? [AXUIElement]) ?? []
        UIMapCaptureDiagnostics.notice(
            "[UIMap] AX app owner='\(candidate.ownerName)' pid=\(candidate.ownerPID) windows=\(windows.count) AXWindowsStatus=\(windowsResult.status.rawValue)"
        )
        let matchingWindows = windows
            .filter { element in
                guard let frame = accessibilityFrame(of: element),
                      let documentRect = mapping.documentRect(fromAccessibilityRect: frame) else {
                    return false
                }

                let candidateDocumentRect = TopLeftRectTransform(
                    sourceBounds: mapping.captureSourceRect,
                    targetBounds: mapping.documentRect
                )
                    .targetRect(fromSourceRect: candidate.frame.intersection(mapping.captureSourceRect))
                    .gscIntegralStandardized
                let overlap = gscIntersectionArea(documentRect, candidateDocumentRect)
                return overlap > 0 || documentRect.intersects(candidateDocumentRect)
            }
        UIMapCaptureDiagnostics.notice(
            "[UIMap] AX app owner='\(candidate.ownerName)' matchingWindows=\(matchingWindows.count)"
        )

        let roots = matchingWindows.isEmpty ? [appElement] : matchingWindows

        let children = roots.compactMap {
            let windowRelativeMapping = windowRelativeMapping(
                forRoot: $0,
                candidate: candidate,
                mapping: mapping
            )
            return captureElement(
                $0,
                ownerName: candidate.ownerName,
                bundleIdentifier: candidate.bundleIdentifier,
                mapping: mapping,
                windowRelativeMapping: windowRelativeMapping,
                depth: 0,
                visited: &visited,
                remainingElementBudget: &remainingElementBudget
            )
        }

        if children.isEmpty {
            let hitTestChildren = captureHitTestElements(
                for: candidate,
                mapping: mapping,
                visited: &visited,
                remainingElementBudget: &remainingElementBudget
            )

            if !hitTestChildren.isEmpty {
                if hitTestChildren.count == 1 {
                    return hitTestChildren[0]
                }

                guard let documentRect = mapping.documentRect(fromAccessibilityRect: accessibilityRect(fromCaptureRect: candidate.frame, using: mapping)) else {
                    return nil
                }

                return UIMapElement(
                    name: candidate.ownerName,
                    role: "AXApplication",
                    roleDescription: "Application",
                    documentRect: documentRect,
                    owningApplication: candidate.ownerName,
                    bundleIdentifier: candidate.bundleIdentifier,
                    children: hitTestChildren
                )
            }
        }

        if children.count == 1 {
            return children[0]
        }

        guard !children.isEmpty,
              let documentRect = mapping.documentRect(fromAccessibilityRect: accessibilityRect(fromCaptureRect: candidate.frame, using: mapping)) else {
            UIMapCaptureDiagnostics.failure(
                "[UIMap] candidate produced no mapped children owner='\(candidate.ownerName)' children=\(children.count) frame=\(Self.describe(candidate.frame))"
            )
            return nil
        }

        return UIMapElement(
            name: candidate.ownerName,
            role: "AXApplication",
            roleDescription: "Application",
            documentRect: documentRect,
            owningApplication: candidate.ownerName,
            bundleIdentifier: candidate.bundleIdentifier,
            children: children
        )
    }

    private func captureHitTestElements(
        for candidate: WindowCandidate,
        mapping: CaptureMapping,
        visited: inout Set<CFHashCode>,
        remainingElementBudget: inout Int
    ) -> [UIMapElement] {
        let systemElement = AXUIElementCreateSystemWide()
        var roots = [AXUIElement]()
        var rootHashes = Set<CFHashCode>()
        let points = candidatePoints(in: candidate.frame.intersection(mapping.captureSourceRect))

        UIMapCaptureDiagnostics.notice(
            "[UIMap] hit-test fallback owner='\(candidate.ownerName)' samplePoints=\(points.count)"
        )

        for point in points {
            for hitTestPoint in axHitTestPoints(forCapturePoint: point, mapping: mapping) {
                var hitElement: AXUIElement?
                let hitError = AXUIElementCopyElementAtPosition(
                    systemElement,
                    Float(hitTestPoint.accessibilityPoint.x),
                    Float(hitTestPoint.accessibilityPoint.y),
                    &hitElement
                )

                guard hitError == .success, let hitElement else {
                    UIMapCaptureDiagnostics.notice(
                        "[UIMap] hit-test failed owner='\(candidate.ownerName)' mode=\(hitTestPoint.mode) capturePoint=\(Self.describePoint(point)) axPoint=\(Self.describePoint(hitTestPoint.accessibilityPoint)) error=\(hitError.rawValue)"
                    )
                    continue
                }

                let root = accessibilityWindowElement(startingAt: hitElement) ?? hitElement
                let rootHash = CFHash(root)
                guard rootHashes.insert(rootHash).inserted else {
                    continue
                }

                UIMapCaptureDiagnostics.notice(
                    "[UIMap] hit-test root owner='\(candidate.ownerName)' mode=\(hitTestPoint.mode) capturePoint=\(Self.describePoint(point)) axPoint=\(Self.describePoint(hitTestPoint.accessibilityPoint)) rootRole='\(stringAttribute("AXRole", from: root) ?? "unknown")'"
                )
                roots.append(root)
            }
        }

        let elements = roots.compactMap {
            let windowRelativeMapping = windowRelativeMapping(
                forRoot: $0,
                candidate: candidate,
                mapping: mapping
            )
            return captureElement(
                $0,
                ownerName: candidate.ownerName,
                bundleIdentifier: candidate.bundleIdentifier,
                mapping: mapping,
                windowRelativeMapping: windowRelativeMapping,
                depth: 0,
                visited: &visited,
                remainingElementBudget: &remainingElementBudget
            )
        }

        UIMapCaptureDiagnostics.notice(
            "[UIMap] hit-test fallback owner='\(candidate.ownerName)' roots=\(roots.count) capturedElements=\(elements.count)"
        )
        return elements
    }

    private func captureElement(
        _ element: AXUIElement,
        ownerName: String,
        bundleIdentifier: String?,
        mapping: CaptureMapping,
        windowRelativeMapping: WindowRelativeMapping?,
        depth: Int,
        visited: inout Set<CFHashCode>,
        remainingElementBudget: inout Int
    ) -> UIMapElement? {
        guard remainingElementBudget > 0,
              depth <= maxDepth else {
            return nil
        }

        let hash = CFHash(element)
        guard visited.insert(hash).inserted else {
            return nil
        }

        let capturedChildren = elementChildren(of: element).compactMap {
            captureElement(
                $0,
                ownerName: ownerName,
                bundleIdentifier: bundleIdentifier,
                mapping: mapping,
                windowRelativeMapping: windowRelativeMapping,
                depth: depth + 1,
                visited: &visited,
                remainingElementBudget: &remainingElementBudget
            )
        }

        guard let accessibilityFrame = accessibilityFrame(of: element),
              let documentRect = documentRect(
                fromAccessibilityFrame: accessibilityFrame,
                mapping: mapping,
                windowRelativeMapping: windowRelativeMapping
              ) else {
            return capturedChildren.isEmpty ? nil : UIMapElement(
                name: stringAttribute("AXTitle", from: element) ?? stringAttribute("AXDescription", from: element),
                accessibilityLabel: stringAttribute("AXDescription", from: element),
                accessibilityIdentifier: stringAttribute("AXIdentifier", from: element),
                role: stringAttribute("AXRole", from: element),
                roleDescription: stringAttribute("AXRoleDescription", from: element),
                valueDescription: valueDescription(from: element),
                documentRect: gscBoundingRect(of: capturedChildren.map(\.documentRect)),
                owningApplication: ownerName,
                bundleIdentifier: bundleIdentifier,
                children: capturedChildren
            )
        }

        remainingElementBudget -= 1
        return UIMapElement(
            name: stringAttribute("AXTitle", from: element) ?? stringAttribute("AXDescription", from: element),
            accessibilityLabel: stringAttribute("AXDescription", from: element),
            accessibilityIdentifier: stringAttribute("AXIdentifier", from: element),
            role: stringAttribute("AXRole", from: element),
            roleDescription: stringAttribute("AXRoleDescription", from: element),
            valueDescription: valueDescription(from: element),
            documentRect: documentRect,
            owningApplication: ownerName,
            bundleIdentifier: bundleIdentifier,
            children: capturedChildren
        )
    }

    private func documentRect(
        fromAccessibilityFrame accessibilityFrame: CGRect,
        mapping: CaptureMapping,
        windowRelativeMapping: WindowRelativeMapping?
    ) -> CGRect? {
        if let windowRelativeDocumentRect = windowRelativeMapping?.documentRect(fromAccessibilityRect: accessibilityFrame) {
            return windowRelativeDocumentRect
        }

        return mapping.documentRect(fromAccessibilityRect: accessibilityFrame)
    }

    private func windowRelativeMapping(
        forRoot root: AXUIElement,
        candidate: WindowCandidate,
        mapping: CaptureMapping
    ) -> WindowRelativeMapping? {
        guard let rootAccessibilityRect = accessibilityFrame(of: root),
              rootAccessibilityRect.width > 0,
              rootAccessibilityRect.height > 0 else {
            return nil
        }

        let candidateCaptureRect = candidate.frame.intersection(mapping.captureSourceRect)
        guard candidateCaptureRect.width > 0,
              candidateCaptureRect.height > 0 else {
            return nil
        }

        let candidateDocumentRect = TopLeftRectTransform(
            sourceBounds: mapping.captureSourceRect,
            targetBounds: mapping.documentRect
        )
            .targetRect(fromSourceRect: candidateCaptureRect)
            .gscIntegralStandardized

        UIMapCaptureDiagnostics.notice(
            "[UIMap] window-relative mapping owner='\(candidate.ownerName)' rootRole='\(stringAttribute("AXRole", from: root) ?? "unknown")' rootAXRect=\(Self.describe(rootAccessibilityRect)) candidateDocRect=\(Self.describe(candidateDocumentRect))"
        )

        return WindowRelativeMapping(
            rootAccessibilityRect: rootAccessibilityRect,
            candidateDocumentRect: candidateDocumentRect
        )
    }

    private func windowCandidates(intersecting captureRect: CGRect) -> [WindowCandidate] {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            UIMapCaptureDiagnostics.failure("[UIMap] CGWindowListCopyWindowInfo returned nil")
            return []
        }

        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        return windowInfo.enumerated().compactMap { index, info -> WindowCandidate? in
            guard let ownerPIDNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPIDNumber.int32Value != currentProcessID,
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  frame.width >= 2,
                  frame.height >= 2,
                  frame.intersects(captureRect) else {
                return nil
            }

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else {
                return nil
            }

            let ownerPID = ownerPIDNumber.int32Value
            let app = NSRunningApplication(processIdentifier: ownerPID)
            let ownerName = (info[kCGWindowOwnerName as String] as? String)
                ?? app?.localizedName
                ?? "Application"

            return WindowCandidate(
                ownerPID: ownerPID,
                ownerName: ownerName,
                bundleIdentifier: app?.bundleIdentifier,
                frame: frame.gscIntegralStandardized,
                focusRank: index
            )
        }
        .sorted { $0.focusRank < $1.focusRank }
    }

    private func accessibilityRect(fromCaptureRect rect: CGRect, using mapping: CaptureMapping) -> CGRect {
        if let displayMapping = mapping.accessibilityMappings.first(where: { $0.intersectsCaptureRect(rect) }) {
            return displayMapping.accessibilityRect(fromCaptureRect: rect)
        }

        return rect.gscIntegralStandardized
    }

    private struct AXHitTestPoint {
        let mode: String
        let accessibilityPoint: CGPoint
    }

    private func axHitTestPoints(forCapturePoint capturePoint: CGPoint, mapping: CaptureMapping) -> [AXHitTestPoint] {
        let accessibilityPoint = accessibilityPoint(fromCapturePoint: capturePoint, mapping: mapping)
        var points = [AXHitTestPoint(mode: "mapped", accessibilityPoint: accessibilityPoint)]

        if hypot(accessibilityPoint.x - capturePoint.x, accessibilityPoint.y - capturePoint.y) > 0.5 {
            points.append(AXHitTestPoint(mode: "capture", accessibilityPoint: capturePoint))
        }

        return points
    }

    private func accessibilityPoint(fromCapturePoint capturePoint: CGPoint, mapping: CaptureMapping) -> CGPoint {
        if let displayMapping = mapping.accessibilityMappings.first(where: { $0.captureFrame.insetBy(dx: -1, dy: -1).contains(capturePoint) }) {
            return displayMapping.accessibilityPoint(fromCapturePoint: capturePoint)
        }

        return capturePoint
    }

    private func candidatePoints(in rect: CGRect) -> [CGPoint] {
        let rect = rect.gscIntegralStandardized
        guard rect.width > 0, rect.height > 0 else {
            return []
        }

        let insetX = min(max(rect.width * 0.2, 12), max(rect.width / 2 - 1, 1))
        let insetY = min(max(rect.height * 0.2, 12), max(rect.height / 2 - 1, 1))
        let xs = [rect.minX + insetX, rect.midX, rect.maxX - insetX]
        let ys = [rect.minY + insetY, rect.midY, rect.maxY - insetY]

        return ys.flatMap { y in
            xs.map { x in CGPoint(x: x, y: y) }
        }
    }

    private func accessibilityWindowElement(startingAt element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var visited = Set<CFHashCode>()

        while let candidate = current {
            let identifier = CFHash(candidate)
            guard visited.insert(identifier).inserted else {
                return nil
            }

            if let window = elementAttribute("AXWindow", from: candidate) {
                return window
            }

            if stringAttribute("AXRole", from: candidate) == "AXWindow" {
                return candidate
            }

            current = elementAttribute("AXParent", from: candidate)
        }

        return nil
    }

    private func accessibilityFrame(of element: AXUIElement) -> CGRect? {
        guard let positionObject = attribute("AXPosition", from: element),
              let sizeObject = attribute("AXSize", from: element) else {
            return nil
        }

        let positionCFValue = positionObject as CFTypeRef
        let sizeCFValue = sizeObject as CFTypeRef

        guard CFGetTypeID(positionCFValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeCFValue) == AXValueGetTypeID() else {
            return nil
        }

        let positionValue = positionCFValue as! AXValue
        let sizeValue = sizeCFValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        return CGRect(origin: position, size: size).gscIntegralStandardized
    }

    private func attribute(_ name: String, from element: AXUIElement) -> AnyObject? {
        attributeResult(name, from: element).value
    }

    private func attributeResult(_ name: String, from element: AXUIElement) -> (status: AXError, value: AnyObject?) {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (status, value as AnyObject?)
    }

    private func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        attribute(name, from: element) as? String
    }

    private func elementAttribute(_ name: String, from element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, from: element) else {
            return nil
        }

        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func valueDescription(from element: AXUIElement) -> String? {
        guard let value = attribute("AXValue", from: element) else {
            return nil
        }

        if let stringValue = value as? String {
            return stringValue
        }

        if let numberValue = value as? NSNumber {
            return numberValue.stringValue
        }

        return nil
    }

    private func elementChildren(of element: AXUIElement) -> [AXUIElement] {
        for attributeName in ["AXVisibleChildren", "AXChildren", "AXRows", "AXColumns", "AXMenuItems"] {
            if let children = attribute(attributeName, from: element) as? [AXUIElement], !children.isEmpty {
                return children
            }
        }

        return []
    }

    private static func currentCoordinateMappings() -> [CaptureAccessibilityTransform] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.gscDisplayID else {
                return nil
            }

            let captureFrame = CGDisplayBounds(displayID)
            guard captureFrame.width > 0,
                  captureFrame.height > 0 else {
                return nil
            }

            return CaptureAccessibilityTransform(captureFrame: captureFrame, accessibilityFrame: screen.frame)
        }
    }

    private static func describe(_ rect: CGRect) -> String {
        "x:\(rounded(rect.origin.x)) y:\(rounded(rect.origin.y)) w:\(rounded(rect.size.width)) h:\(rounded(rect.size.height))"
    }

    private static func describePoint(_ point: CGPoint) -> String {
        "x:\(rounded(point.x)) y:\(rounded(point.y))"
    }

    private static func rounded(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}

private func gscIntersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    return max(intersection.width, 0) * max(intersection.height, 0)
}

private extension CaptureAccessibilityTransform {
    func intersectsAccessibilityRect(_ rect: CGRect) -> Bool {
        accessibilityFrame.intersects(rect.standardized)
    }
}

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
@preconcurrency import Vision

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

nonisolated struct UIMapWindowRelativeMapping: Equatable {
    let rootAccessibilityRect: CGRect
    let candidateDocumentRect: CGRect

    func documentRect(fromAccessibilityRect rect: CGRect) -> CGRect? {
        guard rootAccessibilityRect.width > 0,
              rootAccessibilityRect.height > 0,
              candidateDocumentRect.width > 0,
              candidateDocumentRect.height > 0 else {
            return nil
        }

        let mappedDocumentRect = TopLeftRectTransform(
            sourceBounds: rootAccessibilityRect,
            targetBounds: candidateDocumentRect
        )
            .targetRect(fromSourceRect: rect)
            .gscIntegralStandardized
        let documentRect = mappedDocumentRect.intersection(candidateDocumentRect).gscIntegralStandardized

        guard documentRect.width > 0,
              documentRect.height > 0 else {
            return nil
        }

        return documentRect
    }
}

nonisolated enum UIMapTextRecognitionGeometry {
    static func documentRect(
        fromNormalizedBoundingBox boundingBox: CGRect,
        imageSize: CGSize,
        documentRect: CGRect
    ) -> CGRect? {
        guard imageSize.width > 0,
              imageSize.height > 0,
              documentRect.width > 0,
              documentRect.height > 0 else {
            return nil
        }

        let imageBounds = CGRect(origin: .zero, size: imageSize).standardized
        let topLeftImageRect = CGRect(
            x: boundingBox.minX * imageSize.width,
            y: (1 - boundingBox.maxY) * imageSize.height,
            width: boundingBox.width * imageSize.width,
            height: boundingBox.height * imageSize.height
        ).standardized
        let clippedImageRect = topLeftImageRect.intersection(imageBounds).standardized

        guard clippedImageRect.width > 1,
              clippedImageRect.height > 1 else {
            return nil
        }

        let xScale = documentRect.width / imageBounds.width
        let yScale = documentRect.height / imageBounds.height
        let mappedDocumentRect = roundedRect(
            CGRect(
                x: documentRect.minX + clippedImageRect.minX * xScale,
                y: documentRect.minY + clippedImageRect.minY * yScale,
                width: clippedImageRect.width * xScale,
                height: clippedImageRect.height * yScale
            )
            .intersection(documentRect)
        )

        guard mappedDocumentRect.width > 1,
              mappedDocumentRect.height > 1 else {
            return nil
        }

        return mappedDocumentRect
    }

    private static func roundedRect(_ rect: CGRect) -> CGRect {
        let standardized = rect.standardized
        let minX = standardized.minX.rounded()
        let minY = standardized.minY.rounded()
        let maxX = standardized.maxX.rounded()
        let maxY = standardized.maxY.rounded()

        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
    }
}

@MainActor
struct AccessibilityUIMapCaptureService: UIMapCaptureServiceType {
    private struct WindowCandidate {
        let windowID: CGWindowID?
        let ownerPID: pid_t
        let ownerName: String
        let bundleIdentifier: String?
        let frame: CGRect
        let layer: Int
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
        let candidates = windowCandidates(for: capture)
        UIMapCaptureDiagnostics.notice(
            "[UIMap] window candidate count=\(candidates.count) captureSourceRect=\(Self.describe(capture.sourceRect)) displayMappings=\(mapping.accessibilityMappings.count)"
        )
        for candidate in candidates.prefix(12) {
            UIMapCaptureDiagnostics.notice(
                "[UIMap] candidate windowID=\(candidate.windowID.map(String.init) ?? "nil") owner='\(candidate.ownerName)' pid=\(candidate.ownerPID) bundle='\(candidate.bundleIdentifier ?? "nil")' layer=\(candidate.layer) frame=\(Self.describe(candidate.frame))"
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
                    allowsHitTestPIDMismatch: capture.kind == .window,
                    visited: &visited,
                    remainingElementBudget: &remainingElementBudget
                )
            }

        guard !elements.isEmpty else {
            if let textFallbackSnapshot = textRecognitionFallbackSnapshot(
                for: capture,
                candidates: candidates
            ) {
                return textFallbackSnapshot
            }

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

    private func textRecognitionFallbackSnapshot(
        for capture: CapturedScreenshot,
        candidates: [WindowCandidate]
    ) -> UIMapSnapshot? {
        UIMapCaptureDiagnostics.notice(
            "[UIMap] AX capture produced no elements; attempting text-recognition fallback imageSize=\(Int(capture.pixelSize.width))x\(Int(capture.pixelSize.height))"
        )

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: capture.image, options: [:])

        do {
            try handler.perform([request])
        } catch {
            UIMapCaptureDiagnostics.failure(
                "[UIMap] text-recognition fallback failed error='\(error.localizedDescription)'"
            )
            return nil
        }

        let ownerName = candidates.first?.ownerName ?? capture.sourceName
        let bundleIdentifier = candidates.first?.bundleIdentifier
        let imageSize = CGSize(width: capture.image.width, height: capture.image.height)
        let textElements = (request.results ?? []).compactMap { observation -> UIMapElement? in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }

            let text = CaptureTextRecognizer.normalizedRecognizedText(candidate.string)
            guard !text.isEmpty,
                  let documentRect = UIMapTextRecognitionGeometry.documentRect(
                    fromNormalizedBoundingBox: observation.boundingBox,
                    imageSize: imageSize,
                    documentRect: capture.documentRect
                  ) else {
                return nil
            }

            return UIMapElement(
                name: text,
                accessibilityLabel: text,
                role: "AXStaticText",
                roleDescription: "recognized text",
                valueDescription: "Generated from screenshot text recognition because Accessibility metadata was unavailable.",
                documentRect: documentRect,
                owningApplication: ownerName,
                bundleIdentifier: bundleIdentifier
            )
        }

        guard !textElements.isEmpty else {
            UIMapCaptureDiagnostics.failure("[UIMap] text-recognition fallback produced no elements")
            return nil
        }

        let rootElement = UIMapElement(
            name: capture.sourceName,
            accessibilityLabel: "Text recognition fallback",
            role: "AXWindow",
            roleDescription: "window",
            valueDescription: "Accessibility metadata was unavailable; visible text was recognized from the screenshot pixels.",
            documentRect: capture.documentRect,
            owningApplication: ownerName,
            bundleIdentifier: bundleIdentifier,
            children: textElements
        )
        let snapshot = UIMapSnapshot(
            capturedAt: Date(),
            sourceRect: capture.sourceRect,
            elements: [rootElement]
        )
        UIMapCaptureDiagnostics.notice(
            "[UIMap] text-recognition fallback succeeded elements=\(textElements.count) flattenedElements=\(snapshot.elementCount)"
        )
        return snapshot
    }

    private func captureWindowElement(
        for candidate: WindowCandidate,
        mapping: CaptureMapping,
        allowsHitTestPIDMismatch: Bool,
        visited: inout Set<CFHashCode>,
        remainingElementBudget: inout Int
    ) -> UIMapElement? {
        let appElement = AXUIElementCreateApplication(candidate.ownerPID)
        AXUIElementSetMessagingTimeout(appElement, 2.0)
        let windowsResult = attributeResult("AXWindows", from: appElement)
        let windows = (windowsResult.value as? [AXUIElement]) ?? []
        UIMapCaptureDiagnostics.notice(
            "[UIMap] AX app owner='\(candidate.ownerName)' pid=\(candidate.ownerPID) windows=\(windows.count) AXWindowsStatus=\(windowsResult.status.rawValue)"
        )
        if windowsResult.status != .success {
            let attributeNamesResult = attributeNamesResult(from: appElement)
            UIMapCaptureDiagnostics.notice(
                "[UIMap] AX app owner='\(candidate.ownerName)' attributeNamesStatus=\(attributeNamesResult.status.rawValue) attributeNames=\(attributeNamesResult.names.count)"
            )
        }
        let matchingWindows = windows
            .filter { windowElement($0, matches: candidate, mapping: mapping) }
        UIMapCaptureDiagnostics.notice(
            "[UIMap] AX app owner='\(candidate.ownerName)' matchingWindows=\(matchingWindows.count)"
        )

        let fallbackRoots = applicationWindowRoots(
            from: appElement,
            candidate: candidate,
            mapping: mapping
        )
        let roots = deduplicatedAXElements(matchingWindows + fallbackRoots)
        UIMapCaptureDiagnostics.notice(
            "[UIMap] AX app owner='\(candidate.ownerName)' rootWindows=\(roots.count) fallbackRoots=\(fallbackRoots.count)"
        )

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
                allowsPIDMismatch: allowsHitTestPIDMismatch,
                visited: &visited,
                remainingElementBudget: &remainingElementBudget
            )

            if !hitTestChildren.isEmpty {
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
        allowsPIDMismatch: Bool,
        visited: inout Set<CFHashCode>,
        remainingElementBudget: inout Int
    ) -> [UIMapElement] {
        let systemElement = AXUIElementCreateSystemWide()
        let appElement = AXUIElementCreateApplication(candidate.ownerPID)
        AXUIElementSetMessagingTimeout(systemElement, 2.0)
        AXUIElementSetMessagingTimeout(appElement, 2.0)
        var roots = [AXUIElement]()
        var rootHashes = Set<CFHashCode>()
        let points = candidatePoints(in: candidate.frame.intersection(mapping.captureSourceRect))

        UIMapCaptureDiagnostics.notice(
            "[UIMap] hit-test fallback owner='\(candidate.ownerName)' samplePoints=\(points.count)"
        )

        for point in points {
            for hitTestPoint in axHitTestPoints(forCapturePoint: point, mapping: mapping) {
                let hitResults = hitTestElements(
                    at: hitTestPoint.accessibilityPoint,
                    appElement: appElement,
                    systemElement: systemElement
                )

                if hitResults.isEmpty {
                    UIMapCaptureDiagnostics.notice(
                        "[UIMap] hit-test failed owner='\(candidate.ownerName)' mode=\(hitTestPoint.mode) capturePoint=\(Self.describePoint(point)) axPoint=\(Self.describePoint(hitTestPoint.accessibilityPoint))"
                    )
                    continue
                }

                for hitResult in hitResults {
                    let root = accessibilityWindowElement(startingAt: hitResult.element) ?? hitResult.element
                    let rootPID = elementPID(root)
                    let acceptsPIDMismatch = allowsPIDMismatch
                        && helperRootOwnerMatchesCapture(rootPID: rootPID, candidate: candidate)
                        && helperRootFrameMatchesCapture(root, candidate: candidate)
                    guard rootPID == candidate.ownerPID || acceptsPIDMismatch else {
                        UIMapCaptureDiagnostics.notice(
                            "[UIMap] hit-test root rejected owner='\(candidate.ownerName)' source=\(hitResult.source) expectedPID=\(candidate.ownerPID) actualPID=\(rootPID ?? -1) mode=\(hitTestPoint.mode) rootRole='\(stringAttribute("AXRole", from: root) ?? "unknown")'"
                        )
                        continue
                    }

                    if rootPID != candidate.ownerPID {
                        UIMapCaptureDiagnostics.notice(
                            "[UIMap] hit-test root accepted helper PID owner='\(candidate.ownerName)' source=\(hitResult.source) expectedPID=\(candidate.ownerPID) actualPID=\(rootPID ?? -1) mode=\(hitTestPoint.mode) rootRole='\(stringAttribute("AXRole", from: root) ?? "unknown")'"
                        )
                    }

                    let rootHash = CFHash(root)
                    guard rootHashes.insert(rootHash).inserted else {
                        continue
                    }

                    UIMapCaptureDiagnostics.notice(
                        "[UIMap] hit-test root owner='\(candidate.ownerName)' source=\(hitResult.source) mode=\(hitTestPoint.mode) capturePoint=\(Self.describePoint(point)) axPoint=\(Self.describePoint(hitTestPoint.accessibilityPoint)) rootRole='\(stringAttribute("AXRole", from: root) ?? "unknown")'"
                    )
                    roots.append(root)
                }
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

    private func applicationWindowRoots(
        from appElement: AXUIElement,
        candidate: WindowCandidate,
        mapping: CaptureMapping
    ) -> [AXUIElement] {
        var roots = [AXUIElement]()

        for attributeName in ["AXFocusedWindow", "AXMainWindow"] {
            let result = attributeResult(attributeName, from: appElement)
            guard result.status == .success else {
                UIMapCaptureDiagnostics.notice(
                    "[UIMap] AX app owner='\(candidate.ownerName)' \(attributeName)Status=\(result.status.rawValue)"
                )
                continue
            }

            guard let root = axElement(from: result.value) else {
                UIMapCaptureDiagnostics.notice(
                    "[UIMap] AX app owner='\(candidate.ownerName)' \(attributeName)Status=\(result.status.rawValue) nonElement=true"
                )
                continue
            }

            if windowElement(root, matches: candidate, mapping: mapping) {
                UIMapCaptureDiagnostics.notice(
                    "[UIMap] AX app owner='\(candidate.ownerName)' \(attributeName) accepted role='\(stringAttribute("AXRole", from: root) ?? "unknown")' frame=\(Self.describe(accessibilityFrame(of: root) ?? .zero))"
                )
                roots.append(root)
            } else {
                UIMapCaptureDiagnostics.notice(
                    "[UIMap] AX app owner='\(candidate.ownerName)' \(attributeName) rejected role='\(stringAttribute("AXRole", from: root) ?? "unknown")' frame=\(Self.describe(accessibilityFrame(of: root) ?? .zero))"
                )
            }
        }

        let childrenResult = attributeResult("AXChildren", from: appElement)
        let childRoots = (childrenResult.value as? [AXUIElement]) ?? []
        let matchingChildRoots = childRoots.filter { windowElement($0, matches: candidate, mapping: mapping) }
        UIMapCaptureDiagnostics.notice(
            "[UIMap] AX app owner='\(candidate.ownerName)' AXChildrenStatus=\(childrenResult.status.rawValue) childRoots=\(childRoots.count) matchingChildRoots=\(matchingChildRoots.count)"
        )
        roots.append(contentsOf: matchingChildRoots)

        return deduplicatedAXElements(roots)
    }

    private func windowElement(
        _ element: AXUIElement,
        matches candidate: WindowCandidate,
        mapping: CaptureMapping
    ) -> Bool {
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

    private func deduplicatedAXElements(_ elements: [AXUIElement]) -> [AXUIElement] {
        var seen = Set<CFHashCode>()
        var deduplicated = [AXUIElement]()

        for element in elements {
            let hash = CFHash(element)
            guard seen.insert(hash).inserted else {
                continue
            }
            deduplicated.append(element)
        }

        return deduplicated
    }

    private struct HitTestElement {
        let source: String
        let element: AXUIElement
    }

    private func hitTestElements(
        at point: CGPoint,
        appElement: AXUIElement,
        systemElement: AXUIElement
    ) -> [HitTestElement] {
        var results = [HitTestElement]()

        if let appHitElement = hitTestElement(in: appElement, at: point, source: "app") {
            results.append(appHitElement)
        }

        if let systemHitElement = hitTestElement(in: systemElement, at: point, source: "system") {
            let systemHash = CFHash(systemHitElement.element)
            if !results.contains(where: { CFHash($0.element) == systemHash }) {
                results.append(systemHitElement)
            }
        }

        return results
    }

    private func hitTestElement(in root: AXUIElement, at point: CGPoint, source: String) -> HitTestElement? {
        let (hitError, hitElement) = hitTestResult(in: root, at: point)

        guard hitError == .success, let hitElement else {
            UIMapCaptureDiagnostics.notice(
                "[UIMap] hit-test source=\(source) failed axPoint=\(Self.describePoint(point)) error=\(hitError.rawValue)"
            )
            return nil
        }

        return HitTestElement(source: source, element: hitElement)
    }

    private func hitTestResult(in root: AXUIElement, at point: CGPoint) -> (status: AXError, element: AXUIElement?) {
        var lastStatus = AXError.failure
        var lastElement: AXUIElement?

        for attempt in 0..<3 {
            var hitElement: AXUIElement?
            let status = AXUIElementCopyElementAtPosition(
                root,
                Float(point.x),
                Float(point.y),
                &hitElement
            )
            if status == .success {
                return (status, hitElement)
            }

            lastStatus = status
            lastElement = hitElement

            guard status == .cannotComplete,
                  attempt < 2 else {
                break
            }

            Thread.sleep(forTimeInterval: 0.08)
        }

        return (lastStatus, lastElement)
    }

    private func captureElement(
        _ element: AXUIElement,
        ownerName: String,
        bundleIdentifier: String?,
        mapping: CaptureMapping,
        windowRelativeMapping: UIMapWindowRelativeMapping?,
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
            guard let childBoundingRect = clippedDocumentRect(
                gscBoundingRect(of: capturedChildren.map(\.documentRect)),
                mapping: mapping,
                windowRelativeMapping: windowRelativeMapping
            ) else {
                return nil
            }

            return capturedChildren.isEmpty ? nil : UIMapElement(
                name: stringAttribute("AXTitle", from: element) ?? stringAttribute("AXDescription", from: element),
                accessibilityLabel: stringAttribute("AXDescription", from: element),
                accessibilityIdentifier: stringAttribute("AXIdentifier", from: element),
                role: stringAttribute("AXRole", from: element),
                roleDescription: stringAttribute("AXRoleDescription", from: element),
                valueDescription: valueDescription(from: element),
                documentRect: childBoundingRect,
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
        windowRelativeMapping: UIMapWindowRelativeMapping?
    ) -> CGRect? {
        if let windowRelativeDocumentRect = windowRelativeMapping?.documentRect(fromAccessibilityRect: accessibilityFrame) {
            return clippedDocumentRect(
                windowRelativeDocumentRect,
                mapping: mapping,
                windowRelativeMapping: windowRelativeMapping
            )
        }

        guard let documentRect = mapping.documentRect(fromAccessibilityRect: accessibilityFrame) else {
            return nil
        }

        return clippedDocumentRect(
            documentRect,
            mapping: mapping,
            windowRelativeMapping: windowRelativeMapping
        )
    }

    private func clippedDocumentRect(
        _ documentRect: CGRect,
        mapping: CaptureMapping,
        windowRelativeMapping: UIMapWindowRelativeMapping?
    ) -> CGRect? {
        let clippingRect = windowRelativeMapping?.candidateDocumentRect ?? mapping.documentRect
        let clipped = documentRect.intersection(clippingRect).intersection(mapping.documentRect).gscIntegralStandardized
        guard clipped.width > 0,
              clipped.height > 0 else {
            return nil
        }

        return clipped
    }

    private func windowRelativeMapping(
        forRoot root: AXUIElement,
        candidate: WindowCandidate,
        mapping: CaptureMapping
    ) -> UIMapWindowRelativeMapping? {
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

        return UIMapWindowRelativeMapping(
            rootAccessibilityRect: rootAccessibilityRect,
            candidateDocumentRect: candidateDocumentRect
        )
    }

    private func windowCandidates(for capture: CapturedScreenshot) -> [WindowCandidate] {
        if capture.kind == .window, let identity = capture.sourceWindowIdentity {
            let candidate = WindowCandidate(
                windowID: identity.windowID,
                ownerPID: identity.ownerPID,
                ownerName: identity.ownerName,
                bundleIdentifier: identity.bundleIdentifier
                    ?? NSRunningApplication(processIdentifier: identity.ownerPID)?.bundleIdentifier,
                frame: identity.frame,
                layer: 0,
                focusRank: -1
            )
            let relatedCandidates = relatedWindowCandidates(for: identity, captureSourceRect: capture.sourceRect)
            UIMapCaptureDiagnostics.notice(
                "[UIMap] window capture using source identity windowID=\(identity.windowID) owner='\(identity.ownerName)' pid=\(identity.ownerPID) frame=\(Self.describe(identity.frame)) sourceName='\(capture.sourceName)' relatedCandidates=\(relatedCandidates.count)"
            )
            return [candidate] + relatedCandidates
        }

        let visibleCandidates = windowCandidates(intersecting: capture.sourceRect)

        guard capture.kind == .window else {
            return visibleCandidates
        }

        guard let selectedCandidate = bestWindowCaptureCandidate(from: visibleCandidates, capture: capture) else {
            UIMapCaptureDiagnostics.failure(
                "[UIMap] window capture candidate filter found no selected window sourceName='\(capture.sourceName)' sourceRect=\(Self.describe(capture.sourceRect)) visibleCandidates=\(visibleCandidates.count)"
            )
            return []
        }

        UIMapCaptureDiagnostics.notice(
            "[UIMap] window capture candidate selected owner='\(selectedCandidate.ownerName)' pid=\(selectedCandidate.ownerPID) frame=\(Self.describe(selectedCandidate.frame)) sourceName='\(capture.sourceName)'"
        )
        return [selectedCandidate]
    }

    private func bestWindowCaptureCandidate(from candidates: [WindowCandidate], capture: CapturedScreenshot) -> WindowCandidate? {
        candidates
            .map { candidate in
                (
                    candidate: candidate,
                    score: windowCaptureMatchScore(candidate: candidate, capture: capture)
                )
            }
            .filter { $0.score > 0 }
            .max { $0.score < $1.score }?
            .candidate
    }

    private func windowCaptureMatchScore(candidate: WindowCandidate, capture: CapturedScreenshot) -> CGFloat {
        let intersection = candidate.frame.intersection(capture.sourceRect)
        let intersectionArea = area(of: intersection)
        let captureArea = area(of: capture.sourceRect)
        let candidateArea = area(of: candidate.frame)
        guard captureArea > 0,
              candidateArea > 0,
              intersectionArea > 0 else {
            return 0
        }

        let overlap = intersectionArea / min(captureArea, candidateArea)
        let nameMatches = capture.sourceName.localizedCaseInsensitiveContains(candidate.ownerName)
            || candidate.ownerName.localizedCaseInsensitiveContains(capture.sourceName)
        let nameBonus: CGFloat = nameMatches ? 1 : 0
        let frameDelta = abs(candidate.frame.minX - capture.sourceRect.minX)
            + abs(candidate.frame.minY - capture.sourceRect.minY)
            + abs(candidate.frame.width - capture.sourceRect.width)
            + abs(candidate.frame.height - capture.sourceRect.height)
        let framePenalty = min(frameDelta / 10_000, 0.25)
        return overlap + nameBonus - framePenalty
    }

    private func windowCandidates(intersecting captureRect: CGRect) -> [WindowCandidate] {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            UIMapCaptureDiagnostics.failure("[UIMap] CGWindowListCopyWindowInfo returned nil")
            return []
        }

        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let candidates = windowInfo.enumerated().compactMap { index, info -> WindowCandidate? in
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
                windowID: (info[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) },
                ownerPID: ownerPID,
                ownerName: ownerName,
                bundleIdentifier: app?.bundleIdentifier,
                frame: frame.gscIntegralStandardized,
                layer: layer,
                focusRank: index
            )
        }
        .sorted { $0.focusRank < $1.focusRank }

        return visibleWindowCandidates(candidates, in: captureRect)
    }

    private func relatedWindowCandidates(
        for identity: CaptureSourceWindowIdentity,
        captureSourceRect: CGRect
    ) -> [WindowCandidate] {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            UIMapCaptureDiagnostics.failure("[UIMap] related window probe failed: CGWindowListCopyWindowInfo returned nil")
            return []
        }

        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let targetFrame = identity.frame.intersection(captureSourceRect).gscIntegralStandardized
        let targetArea = area(of: targetFrame)

        guard targetArea > 0 else {
            return []
        }

        let candidates = windowInfo.enumerated().compactMap { index, info -> (candidate: WindowCandidate, sharedCoverage: CGFloat, targetCoverage: CGFloat)? in
            guard let ownerPIDNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPIDNumber.int32Value != currentProcessID,
                  let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                  CGWindowID(windowNumber.uint32Value) != identity.windowID,
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)?.gscIntegralStandardized,
                  frame.width >= 2,
                  frame.height >= 2 else {
                return nil
            }

            let intersection = frame.intersection(targetFrame).gscIntegralStandardized
            let intersectionArea = area(of: intersection)
            let candidateArea = area(of: frame)
            guard intersectionArea >= 16,
                  candidateArea > 0 else {
                return nil
            }

            let sharedCoverage = intersectionArea / min(candidateArea, targetArea)
            let targetCoverage = intersectionArea / targetArea
            let candidateCoverage = intersectionArea / candidateArea
            let originDelta = hypot(frame.minX - targetFrame.minX, frame.minY - targetFrame.minY)
            let sizeDelta = abs(frame.width - targetFrame.width) + abs(frame.height - targetFrame.height)
            let isTightSibling = targetCoverage >= 0.65
                && candidateCoverage >= 0.65
                && originDelta <= 80
                && sizeDelta <= 220
            guard isTightSibling else {
                return nil
            }

            let ownerPID = ownerPIDNumber.int32Value
            let app = NSRunningApplication(processIdentifier: ownerPID)
            let ownerName = (info[kCGWindowOwnerName as String] as? String)
                ?? app?.localizedName
                ?? "Application"
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let candidate = WindowCandidate(
                windowID: CGWindowID(windowNumber.uint32Value),
                ownerPID: ownerPID,
                ownerName: ownerName,
                bundleIdentifier: app?.bundleIdentifier,
                frame: frame,
                layer: layer,
                focusRank: index
            )
            return (candidate, sharedCoverage, targetCoverage)
        }
        .sorted {
            if $0.candidate.layer != $1.candidate.layer {
                return abs($0.candidate.layer) < abs($1.candidate.layer)
            }
            if $0.sharedCoverage != $1.sharedCoverage {
                return $0.sharedCoverage > $1.sharedCoverage
            }
            return $0.candidate.focusRank < $1.candidate.focusRank
        }

        for related in candidates.prefix(12) {
            UIMapCaptureDiagnostics.notice(
                "[UIMap] related window candidate windowID=\(related.candidate.windowID.map(String.init) ?? "nil") owner='\(related.candidate.ownerName)' pid=\(related.candidate.ownerPID) bundle='\(related.candidate.bundleIdentifier ?? "nil")' layer=\(related.candidate.layer) sharedCoverage=\(Self.rounded(related.sharedCoverage)) targetCoverage=\(Self.rounded(related.targetCoverage)) frame=\(Self.describe(related.candidate.frame))"
            )
        }

        var seen = Set<String>()
        return candidates.compactMap { related -> WindowCandidate? in
            let candidate = related.candidate
            let key = "\(candidate.ownerPID)-\(candidate.windowID.map(String.init) ?? "nil")-\(Int(candidate.frame.minX))-\(Int(candidate.frame.minY))-\(Int(candidate.frame.width))-\(Int(candidate.frame.height))"
            guard seen.insert(key).inserted else {
                return nil
            }
            return candidate
        }
        .prefix(8)
        .map { $0 }
    }

    private func helperRootFrameMatchesCapture(_ root: AXUIElement, candidate: WindowCandidate) -> Bool {
        guard let rootFrame = accessibilityFrame(of: root) else {
            UIMapCaptureDiagnostics.notice(
                "[UIMap] helper PID candidate rejected: missing root frame owner='\(candidate.ownerName)'"
            )
            return false
        }

        let candidateFrame = candidate.frame.gscIntegralStandardized
        let rootArea = area(of: rootFrame)
        let candidateArea = area(of: candidateFrame)
        let intersectionArea = area(of: rootFrame.intersection(candidateFrame))
        guard rootArea > 0,
              candidateArea > 0,
              intersectionArea > 0 else {
            UIMapCaptureDiagnostics.notice(
                "[UIMap] helper PID candidate rejected: no frame overlap owner='\(candidate.ownerName)' rootFrame=\(Self.describe(rootFrame)) candidateFrame=\(Self.describe(candidateFrame))"
            )
            return false
        }

        let rootToCandidateAreaRatio = rootArea / candidateArea
        let candidateCoverage = intersectionArea / candidateArea
        let sharedCoverage = intersectionArea / min(rootArea, candidateArea)
        let originDelta = hypot(rootFrame.minX - candidateFrame.minX, rootFrame.minY - candidateFrame.minY)
        let sizeDelta = abs(rootFrame.width - candidateFrame.width) + abs(rootFrame.height - candidateFrame.height)
        let matches = (candidateCoverage >= 0.45 || sharedCoverage >= 0.45)
            && rootToCandidateAreaRatio >= 0.5
            && rootToCandidateAreaRatio <= 2.0
            && originDelta <= 350
            && sizeDelta <= 350

        UIMapCaptureDiagnostics.notice(
            "[UIMap] helper PID candidate frame check owner='\(candidate.ownerName)' matches=\(matches) coverage=\(Self.rounded(candidateCoverage)) sharedCoverage=\(Self.rounded(sharedCoverage)) areaRatio=\(Self.rounded(rootToCandidateAreaRatio)) originDelta=\(Self.rounded(originDelta)) sizeDelta=\(Self.rounded(sizeDelta)) rootFrame=\(Self.describe(rootFrame)) candidateFrame=\(Self.describe(candidateFrame))"
        )
        return matches
    }

    private func helperRootOwnerMatchesCapture(rootPID: pid_t?, candidate: WindowCandidate) -> Bool {
        guard let rootPID else {
            UIMapCaptureDiagnostics.notice(
                "[UIMap] helper PID candidate rejected: missing root PID owner='\(candidate.ownerName)'"
            )
            return false
        }

        guard let rootApplication = NSRunningApplication(processIdentifier: rootPID) else {
            UIMapCaptureDiagnostics.notice(
                "[UIMap] helper PID candidate rejected: missing running app owner='\(candidate.ownerName)' actualPID=\(rootPID)"
            )
            return false
        }

        let rootBundleIdentifier = rootApplication.bundleIdentifier
        let rootName = rootApplication.localizedName
        let bundleMatches = candidate.bundleIdentifier != nil && candidate.bundleIdentifier == rootBundleIdentifier
        let nameMatches = rootName?.localizedCaseInsensitiveCompare(candidate.ownerName) == .orderedSame

        guard bundleMatches || nameMatches else {
            UIMapCaptureDiagnostics.notice(
                "[UIMap] helper PID candidate rejected: owner mismatch expectedOwner='\(candidate.ownerName)' expectedBundle='\(candidate.bundleIdentifier ?? "nil")' actualName='\(rootName ?? "nil")' actualBundle='\(rootBundleIdentifier ?? "nil")' actualPID=\(rootPID)"
            )
            return false
        }

        return true
    }

    private func visibleWindowCandidates(_ candidates: [WindowCandidate], in captureRect: CGRect) -> [WindowCandidate] {
        var coveredRects = [CGRect]()
        var visibleCandidates = [WindowCandidate]()

        for candidate in candidates {
            let candidateCaptureRect = candidate.frame.intersection(captureRect).gscIntegralStandardized
            let candidateArea = area(of: candidateCaptureRect)
            guard candidateArea > 0 else {
                continue
            }

            let visibleArea = visibleArea(of: candidateCaptureRect, coveredBy: coveredRects)
            let visibilityRatio = visibleArea / candidateArea
            UIMapCaptureDiagnostics.notice(
                "[UIMap] candidate visibility owner='\(candidate.ownerName)' visibleArea=\(Self.rounded(visibleArea)) candidateArea=\(Self.rounded(candidateArea)) ratio=\(Self.rounded(visibilityRatio)) frame=\(Self.describe(candidate.frame))"
            )

            if visibleArea >= 16, visibilityRatio >= 0.01 {
                visibleCandidates.append(candidate)
            }

            coveredRects.append(candidateCaptureRect)
        }

        return visibleCandidates
    }

    private func visibleArea(of rect: CGRect, coveredBy coveredRects: [CGRect]) -> CGFloat {
        var visibleFragments = [rect.gscIntegralStandardized]

        for coveredRect in coveredRects {
            visibleFragments = visibleFragments.flatMap { fragment in
                subtract(coveredRect, from: fragment)
            }

            if visibleFragments.isEmpty {
                return 0
            }
        }

        return visibleFragments.reduce(0) { $0 + area(of: $1) }
    }

    private func subtract(_ coveredRect: CGRect, from rect: CGRect) -> [CGRect] {
        let intersection = rect.intersection(coveredRect).gscIntegralStandardized
        guard area(of: intersection) > 0 else {
            return [rect]
        }

        var fragments = [CGRect]()

        if intersection.minY > rect.minY {
            fragments.append(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: intersection.minY - rect.minY))
        }

        if intersection.maxY < rect.maxY {
            fragments.append(CGRect(x: rect.minX, y: intersection.maxY, width: rect.width, height: rect.maxY - intersection.maxY))
        }

        if intersection.minX > rect.minX {
            fragments.append(CGRect(x: rect.minX, y: intersection.minY, width: intersection.minX - rect.minX, height: intersection.height))
        }

        if intersection.maxX < rect.maxX {
            fragments.append(CGRect(x: intersection.maxX, y: intersection.minY, width: rect.maxX - intersection.maxX, height: intersection.height))
        }

        return fragments.filter { area(of: $0) > 0 }.map(\.gscIntegralStandardized)
    }

    private func area(of rect: CGRect) -> CGFloat {
        max(rect.width, 0) * max(rect.height, 0)
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
        var lastStatus = AXError.failure
        var lastValue: CFTypeRef?

        for attempt in 0..<3 {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            if status == .success {
                return (status, value as AnyObject?)
            }

            lastStatus = status
            lastValue = value

            guard status == .cannotComplete,
                  attempt < 2 else {
                break
            }

            Thread.sleep(forTimeInterval: 0.08)
        }

        return (lastStatus, lastValue as AnyObject?)
    }

    private func attributeNamesResult(from element: AXUIElement) -> (status: AXError, names: [String]) {
        var names: CFArray?
        let status = AXUIElementCopyAttributeNames(element, &names)
        return (status, (names as? [String]) ?? [])
    }

    private func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        attribute(name, from: element) as? String
    }

    private func elementAttribute(_ name: String, from element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, from: element) else {
            return nil
        }

        return axElement(from: value)
    }

    private func axElement(from value: AnyObject?) -> AXUIElement? {
        guard let value else {
            return nil
        }

        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func elementPID(_ element: AXUIElement) -> pid_t? {
        var pid = pid_t(0)
        guard AXUIElementGetPid(element, &pid) == .success else {
            return nil
        }

        return pid
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

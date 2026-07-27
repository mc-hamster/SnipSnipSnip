import AppKit
import CoreGraphics
import Foundation
import Vision

#if !APP_STORE_BUILD
private enum UIMapCaptureDiagnostics {
    nonisolated static func notice(
        _ message: @autoclosure () -> String
    ) {
        CaptureContentDiagnostics.current.notice(
            category: "UIMapCapture",
            message()
        )
    }

    nonisolated static func failure(
        _ message: @autoclosure () -> String
    ) {
        CaptureContentDiagnostics.current.error(
            category: "UIMapCapture",
            message()
        )
    }
}
#endif

protocol UIMapCaptureServiceType: Sendable {
    nonisolated func captureUIMap(
        for capture: CapturedScreenshot,
        isPrivateCapture: Bool
    ) async -> UIMapSnapshot?
}

extension UIMapCaptureServiceType {
    nonisolated func captureUIMap(
        for capture: CapturedScreenshot
    ) async -> UIMapSnapshot? {
        await captureUIMap(for: capture, isPrivateCapture: false)
    }
}

nonisolated struct UnavailableUIMapCaptureService: UIMapCaptureServiceType {
    nonisolated func captureUIMap(
        for capture: CapturedScreenshot,
        isPrivateCapture: Bool
    ) async -> UIMapSnapshot? {
        _ = capture
        _ = isPrivateCapture
        return nil
    }
}

nonisolated struct UIMapWindowRelativeMapping: Equatable {
    let rootAccessibilityRect: CGRect
    let candidateDocumentRect: CGRect
    let visibleDocumentRects: [CGRect]

    init(
        rootAccessibilityRect: CGRect,
        candidateDocumentRect: CGRect,
        visibleDocumentRects: [CGRect] = []
    ) {
        self.rootAccessibilityRect = rootAccessibilityRect.gscIntegralStandardized
        self.candidateDocumentRect = candidateDocumentRect.gscIntegralStandardized
        self.visibleDocumentRects = visibleDocumentRects
            .map(\.gscIntegralStandardized)
            .filter { $0.width > 0 && $0.height > 0 }
    }

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

    func visibleDocumentRect(fromDocumentRect rect: CGRect) -> CGRect? {
        let visibilityRects = visibleDocumentRects.isEmpty ? [candidateDocumentRect] : visibleDocumentRects
        let intersections = visibilityRects
            .map { rect.intersection($0).gscIntegralStandardized }
            .filter { $0.width > 0 && $0.height > 0 }

        return intersections.max {
            ($0.width * $0.height) < ($1.width * $1.height)
        }
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

nonisolated enum UIMapAccessibilityPrivacy {
    static func isSensitive(role: String?, subrole: String?, ancestorIsSensitive: Bool) -> Bool {
        ancestorIsSensitive || role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    static func readValueIfAllowed(
        isSensitive: Bool,
        _ readValue: () -> String?
    ) -> String? {
        guard !isSensitive else { return nil }
        return readValue()
    }
}

#if !APP_STORE_BUILD
nonisolated struct AccessibilityUIMapCaptureService: UIMapCaptureServiceType {
    private let capabilities: AppCapabilitySnapshot
    private let accessibility: any AccessibilityPlatform
    private let screens: any ScreenTopologyProviding
    private let clock: any ClockProviding
    private let diagnosticSink: any CaptureContentDiagnosticSink

    init(
        capabilities: AppCapabilitySnapshot,
        accessibility: any AccessibilityPlatform = LiveAccessibilityPlatform(),
        screens: any ScreenTopologyProviding = SystemScreenTopologyService(),
        clock: any ClockProviding = SystemClock(),
        diagnosticSink: any CaptureContentDiagnosticSink =
            SystemCaptureContentDiagnosticSink()
    ) {
        self.capabilities = capabilities
        self.accessibility = accessibility
        self.screens = screens
        self.clock = clock
        self.diagnosticSink = diagnosticSink
    }

    private struct WindowCandidate {
        let windowID: CGWindowID?
        let ownerPID: pid_t
        let ownerName: String
        let bundleIdentifier: String?
        let frame: CGRect
        let visibleCaptureRects: [CGRect]
        let layer: Int
        let focusRank: Int

        func withVisibleCaptureRects(_ rects: [CGRect]) -> WindowCandidate {
            WindowCandidate(
                windowID: windowID,
                ownerPID: ownerPID,
                ownerName: ownerName,
                bundleIdentifier: bundleIdentifier,
                frame: frame,
                visibleCaptureRects: rects
                    .map(\.gscIntegralStandardized)
                    .filter { $0.width > 0 && $0.height > 0 },
                layer: layer,
                focusRank: focusRank
            )
        }
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
    private let maxVisitedElementCount = 1_800
    private let captureDeadlineSeconds: TimeInterval = 2.5
    private let minimumAXWindowMatchScore: CGFloat = 0.35

    nonisolated func captureUIMap(
        for capture: CapturedScreenshot,
        isPrivateCapture: Bool
    ) async -> UIMapSnapshot? {
        await CaptureContentDiagnostics.$current.withValue(
            CaptureContentDiagnostics(
                isPrivateCapture: isPrivateCapture,
                sink: diagnosticSink
            )
        ) {
            await captureUIMapWithDiagnostics(for: capture)
        }
    }

    private func captureUIMapWithDiagnostics(
        for capture: CapturedScreenshot
    ) async -> UIMapSnapshot? {
        UIMapCaptureDiagnostics.notice(
            "[UIMap] capture requested sourceName='\(capture.sourceName)' kind='\(capture.kind.rawValue)' sourceRect=\(Self.describe(capture.sourceRect)) documentRect=\(Self.describe(capture.documentRect)) pixelSize=\(Int(capture.pixelSize.width))x\(Int(capture.pixelSize.height)) featureEnabled=\(capabilities.isEnabled(.uiMap)) axTrusted=\(accessibility.isProcessTrusted())"
        )

        guard capabilities.isEnabled(.uiMap) else {
            UIMapCaptureDiagnostics.failure("[UIMap] capture skipped: feature flag disabled")
            return nil
        }

        guard capture.kind == .window else {
            UIMapCaptureDiagnostics.notice("[UIMap] capture skipped: UI Map is limited to Window captures kind='\(capture.kind.rawValue)'")
            return nil
        }

        guard capture.sourceWindowIdentity != nil else {
            UIMapCaptureDiagnostics.failure("[UIMap] capture skipped: window capture has no selected source window identity")
            return nil
        }

        guard accessibility.isProcessTrusted() else {
            UIMapCaptureDiagnostics.failure("[UIMap] capture skipped: Accessibility trust is false")
            return nil
        }

        let mapping = CaptureMapping(
            captureSourceRect: capture.sourceRect,
            documentRect: capture.documentRect,
            accessibilityMappings: currentCoordinateMappings()
        )
        var remainingElementBudget = maxElementCount
        var remainingVisitBudget = maxVisitedElementCount
        var visited = Set<AccessibilityElementHandle>()
        var didHitTimeLimit = false
        var bestAXWindowMatchScore: CGFloat?
        let deadline = clock.now().addingTimeInterval(captureDeadlineSeconds)
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
                    visited: &visited,
                    remainingVisitBudget: &remainingVisitBudget,
                    remainingElementBudget: &remainingElementBudget,
                    bestAXWindowMatchScore: &bestAXWindowMatchScore,
                    deadline: deadline,
                    didHitTimeLimit: &didHitTimeLimit
                )
            }

        guard !elements.isEmpty else {
            UIMapCaptureDiagnostics.failure(
                "[UIMap] capture produced no elements candidates=\(candidates.count) visitedAXElements=\(visited.count) remainingBudget=\(remainingElementBudget) timedOut=\(didHitTimeLimit)"
            )
            return nil
        }

        let supplementedElements: [UIMapElement]
        if clock.now() < deadline {
            supplementedElements = await elementsWithTextRecognitionSupplement(
                for: capture,
                candidates: candidates,
                elements: elements
            )
        } else {
            UIMapCaptureDiagnostics.notice("[UIMap] text-recognition supplement skipped: AX traversal reached time budget")
            supplementedElements = elements
            didHitTimeLimit = true
        }
        let accessibilityElementCount = elements.reduce(0) { $0 + $1.flattenedCount }
        let ocrSupplementElementCount = supplementedElements
            .flatMap(\.flattened)
            .filter(\.isRecognizedTextSupplement)
            .count
        let didHitBudgetLimit = remainingElementBudget <= 0 || remainingVisitBudget <= 0
        let snapshot = UIMapSnapshot(
            capturedAt: clock.now(),
            sourceRect: capture.sourceRect,
            elements: supplementedElements,
            diagnostics: UIMapCaptureDiagnosticsSummary(
                axWindowMatchConfidence: bestAXWindowMatchScore,
                accessibilityElementCount: accessibilityElementCount,
                ocrSupplementElementCount: ocrSupplementElementCount,
                didHitBudgetLimit: didHitBudgetLimit,
                didHitTimeLimit: didHitTimeLimit
            )
        )
        UIMapCaptureDiagnostics.notice(
            "[UIMap] capture succeeded rootElements=\(supplementedElements.count) axRootElements=\(elements.count) flattenedElements=\(snapshot.elementCount) visitedAXElements=\(visited.count) remainingBudget=\(remainingElementBudget) remainingVisitBudget=\(remainingVisitBudget) bestAXWindowMatchScore=\(Self.rounded(bestAXWindowMatchScore ?? 0)) timedOut=\(didHitTimeLimit)"
        )
        return snapshot
    }

    private func elementsWithTextRecognitionSupplement(
        for capture: CapturedScreenshot,
        candidates: [WindowCandidate],
        elements: [UIMapElement]
    ) async -> [UIMapElement] {
        guard let recognizedElements = await recognizedTextElements(
            for: capture,
            candidates: candidates,
            valueDescription: "Generated from screenshot text recognition because Accessibility metadata was incomplete."
        ) else {
            return elements
        }

        guard !recognizedElements.isEmpty else {
            UIMapCaptureDiagnostics.notice("[UIMap] text-recognition supplement skipped: no recognized text")
            return elements
        }

        let documentArea = area(of: capture.documentRect)
        let existingOverlayRects = elements
            .flatMap(\.flattened)
            .filter {
                $0.isShowAllOverlayCandidate
                    && area(of: $0.documentRect) < documentArea * 0.25
            }
            .map(\.documentRect)
        let supplementalTextElements = recognizedElements.filter { recognizedElement in
            !existingOverlayRects.contains { existingRect in
                existingRect.coversRecognizedTextRect(recognizedElement.documentRect)
            }
        }

        guard !supplementalTextElements.isEmpty else {
            UIMapCaptureDiagnostics.notice(
                "[UIMap] text-recognition supplement skipped: all recognized text overlapped AX elements recognized=\(recognizedElements.count)"
            )
            return elements
        }

        let ownerName = candidates.first?.ownerName ?? capture.sourceName
        let bundleIdentifier = candidates.first?.bundleIdentifier
        let supplementalRoot = UIMapElement(
            name: "Recognized Text",
            accessibilityLabel: "Text recognition supplement",
            role: "AXGroup",
            roleDescription: "recognized text group",
            valueDescription: "Visible text recognized from screenshot pixels where Accessibility metadata was incomplete.",
            source: .ocrSupplement,
            documentRect: capture.documentRect,
            owningApplication: ownerName,
            bundleIdentifier: bundleIdentifier,
            children: supplementalTextElements
        )
        UIMapCaptureDiagnostics.notice(
            "[UIMap] text-recognition supplement added elements=\(supplementalTextElements.count) recognized=\(recognizedElements.count) existingOverlayRects=\(existingOverlayRects.count)"
        )
        return elements + [supplementalRoot]
    }

    private func recognizedTextElements(
        for capture: CapturedScreenshot,
        candidates: [WindowCandidate],
        valueDescription: String
    ) async -> [UIMapElement]? {
        var request = RecognizeTextRequest(.revision3)
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let observations: [RecognizedTextObservation]
        do {
            observations = try await ImageRequestHandler(capture.image).perform(request)
        } catch {
            UIMapCaptureDiagnostics.failure(
                "[UIMap] text recognition failed error='\(error.localizedDescription)'"
            )
            return nil
        }

        let ownerName = candidates.first?.ownerName ?? capture.sourceName
        let bundleIdentifier = candidates.first?.bundleIdentifier
        let imageSize = CGSize(width: capture.image.width, height: capture.image.height)
        return observations.compactMap { observation -> UIMapElement? in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }

            let text = CaptureTextRecognizer.normalizedRecognizedText(candidate.string)
            guard text.isUsefulUIMapRecognizedText,
                  let documentRect = UIMapTextRecognitionGeometry.documentRect(
                    fromNormalizedBoundingBox: observation.boundingBox.cgRect,
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
                valueDescription: valueDescription,
                source: .ocrSupplement,
                documentRect: documentRect,
                owningApplication: ownerName,
                bundleIdentifier: bundleIdentifier
            )
        }
    }

    private func captureWindowElement(
        for candidate: WindowCandidate,
        mapping: CaptureMapping,
        visited: inout Set<AccessibilityElementHandle>,
        remainingVisitBudget: inout Int,
        remainingElementBudget: inout Int,
        bestAXWindowMatchScore: inout CGFloat?,
        deadline: Date,
        didHitTimeLimit: inout Bool
    ) -> UIMapElement? {
        let appElement = accessibility.applicationElement(processID: candidate.ownerPID)
        accessibility.setMessagingTimeout(2.0, for: appElement)
        let windowsResult = attributeResult("AXWindows", from: appElement)
        let windows = (windowsResult.value as? [AccessibilityElementHandle]) ?? []
        UIMapCaptureDiagnostics.notice(
            "[UIMap] AX app owner='\(candidate.ownerName)' pid=\(candidate.ownerPID) windows=\(windows.count) AXWindowsStatus=\(windowsResult.status.rawValue)"
        )
        if windowsResult.status != .success {
            let attributeNamesResult = attributeNamesResult(from: appElement)
            UIMapCaptureDiagnostics.notice(
                "[UIMap] AX app owner='\(candidate.ownerName)' attributeNamesStatus=\(attributeNamesResult.status.rawValue) attributeNames=\(attributeNamesResult.names.count)"
            )
        }
        let scoredWindows = windows
            .map { (element: $0, score: axWindowMatchScore($0, candidate: candidate, mapping: mapping)) }
            .filter { $0.score >= minimumAXWindowMatchScore }
            .sorted { $0.score > $1.score }
        let matchingWindows = scoredWindows.map(\.element)
        if let score = scoredWindows.first?.score {
            bestAXWindowMatchScore = max(bestAXWindowMatchScore ?? 0, score)
        }
        UIMapCaptureDiagnostics.notice(
            "[UIMap] AX app owner='\(candidate.ownerName)' matchingWindows=\(matchingWindows.count) bestScore=\(Self.rounded(scoredWindows.first?.score ?? 0)) threshold=\(Self.rounded(minimumAXWindowMatchScore))"
        )

        let fallbackRoots = applicationWindowRoots(
            from: appElement,
            candidate: candidate,
            mapping: mapping,
            bestAXWindowMatchScore: &bestAXWindowMatchScore
        )
        let roots = deduplicatedAccessibilityElements(matchingWindows + fallbackRoots)
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
                ancestorIsSensitive: false,
                visited: &visited,
                remainingVisitBudget: &remainingVisitBudget,
                remainingElementBudget: &remainingElementBudget,
                deadline: deadline,
                didHitTimeLimit: &didHitTimeLimit
            )
        }

        if children.isEmpty {
            UIMapCaptureDiagnostics.notice(
                "[UIMap] AX root traversal produced no children owner='\(candidate.ownerName)'; skipping hit-test fallback for background capture"
            )
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

    private func applicationWindowRoots(
        from appElement: AccessibilityElementHandle,
        candidate: WindowCandidate,
        mapping: CaptureMapping,
        bestAXWindowMatchScore: inout CGFloat?
    ) -> [AccessibilityElementHandle] {
        var roots = [AccessibilityElementHandle]()

        for attributeName in ["AXFocusedWindow", "AXMainWindow"] {
            let result = attributeResult(attributeName, from: appElement)
            guard result.status == .success else {
                UIMapCaptureDiagnostics.notice(
                    "[UIMap] AX app owner='\(candidate.ownerName)' \(attributeName)Status=\(result.status.rawValue)"
                )
                continue
            }

            guard let root = element(from: result.value) else {
                UIMapCaptureDiagnostics.notice(
                    "[UIMap] AX app owner='\(candidate.ownerName)' \(attributeName)Status=\(result.status.rawValue) nonElement=true"
                )
                continue
            }

            let score = axWindowMatchScore(root, candidate: candidate, mapping: mapping)
            if score >= minimumAXWindowMatchScore {
                bestAXWindowMatchScore = max(bestAXWindowMatchScore ?? 0, score)
                UIMapCaptureDiagnostics.notice(
                    "[UIMap] AX app owner='\(candidate.ownerName)' \(attributeName) accepted score=\(Self.rounded(score)) role='\(stringAttribute("AXRole", from: root) ?? "unknown")' frame=\(Self.describe(accessibilityFrame(of: root) ?? .zero))"
                )
                roots.append(root)
            } else {
                UIMapCaptureDiagnostics.notice(
                    "[UIMap] AX app owner='\(candidate.ownerName)' \(attributeName) rejected score=\(Self.rounded(score)) role='\(stringAttribute("AXRole", from: root) ?? "unknown")' frame=\(Self.describe(accessibilityFrame(of: root) ?? .zero))"
                )
            }
        }

        let childrenResult = attributeResult("AXChildren", from: appElement)
        let childRoots = (childrenResult.value as? [AccessibilityElementHandle]) ?? []
        let matchingChildRoots = childRoots.filter { childRoot in
            let score = axWindowMatchScore(childRoot, candidate: candidate, mapping: mapping)
            if score >= minimumAXWindowMatchScore {
                bestAXWindowMatchScore = max(bestAXWindowMatchScore ?? 0, score)
                return true
            }

            return false
        }
        UIMapCaptureDiagnostics.notice(
            "[UIMap] AX app owner='\(candidate.ownerName)' AXChildrenStatus=\(childrenResult.status.rawValue) childRoots=\(childRoots.count) matchingChildRoots=\(matchingChildRoots.count)"
        )
        roots.append(contentsOf: matchingChildRoots)

        return deduplicatedAccessibilityElements(roots)
    }

    private func axWindowMatchScore(
        _ element: AccessibilityElementHandle,
        candidate: WindowCandidate,
        mapping: CaptureMapping
    ) -> CGFloat {
        if let pid = elementPID(element),
           pid != candidate.ownerPID {
            return 0
        }

        guard let frame = accessibilityFrame(of: element),
              let documentRect = mapping.documentRect(fromAccessibilityRect: frame) else {
            return 0
        }

        let candidateDocumentRect = TopLeftRectTransform(
            sourceBounds: mapping.captureSourceRect,
            targetBounds: mapping.documentRect
        )
            .targetRect(fromSourceRect: candidate.frame.intersection(mapping.captureSourceRect))
            .gscIntegralStandardized
        let overlap = gscIntersectionArea(documentRect, candidateDocumentRect)
        let overlapDenominator = min(area(of: documentRect), area(of: candidateDocumentRect))
        guard overlapDenominator > 0 else {
            return 0
        }

        let overlapRatio = overlap / overlapDenominator
        let frameDelta = abs(documentRect.minX - candidateDocumentRect.minX)
            + abs(documentRect.minY - candidateDocumentRect.minY)
            + abs(documentRect.width - candidateDocumentRect.width)
            + abs(documentRect.height - candidateDocumentRect.height)
        let framePenalty = min(frameDelta / max(mapping.documentRect.width + mapping.documentRect.height, 1), 0.35)
        let roleBonus: CGFloat = (stringAttribute("AXRole", from: element) == "AXWindow") ? 0.1 : 0
        return max(0, overlapRatio + roleBonus - framePenalty)
    }

    private func deduplicatedAccessibilityElements(
        _ elements: [AccessibilityElementHandle]
    ) -> [AccessibilityElementHandle] {
        var seen = Set<AccessibilityElementHandle>()
        var deduplicated = [AccessibilityElementHandle]()

        for element in elements {
            guard seen.insert(element).inserted else {
                continue
            }
            deduplicated.append(element)
        }

        return deduplicated
    }

    private func captureElement(
        _ element: AccessibilityElementHandle,
        ownerName: String,
        bundleIdentifier: String?,
        mapping: CaptureMapping,
        windowRelativeMapping: UIMapWindowRelativeMapping?,
        depth: Int,
        ancestorIsSensitive: Bool,
        visited: inout Set<AccessibilityElementHandle>,
        remainingVisitBudget: inout Int,
        remainingElementBudget: inout Int,
        deadline: Date,
        didHitTimeLimit: inout Bool
    ) -> UIMapElement? {
        guard clock.now() <= deadline else {
            didHitTimeLimit = true
            return nil
        }

        guard remainingElementBudget > 0,
              remainingVisitBudget > 0,
              depth <= maxDepth else {
            return nil
        }

        guard visited.insert(element).inserted else {
            return nil
        }
        remainingVisitBudget -= 1

        let role = stringAttribute("AXRole", from: element)
        let subrole = stringAttribute("AXSubrole", from: element)
        let isSensitive = UIMapAccessibilityPrivacy.isSensitive(
            role: role,
            subrole: subrole,
            ancestorIsSensitive: ancestorIsSensitive
        )

        let capturedChildren = elementChildren(of: element).compactMap {
            captureElement(
                $0,
                ownerName: ownerName,
                bundleIdentifier: bundleIdentifier,
                mapping: mapping,
                windowRelativeMapping: windowRelativeMapping,
                depth: depth + 1,
                ancestorIsSensitive: isSensitive,
                visited: &visited,
                remainingVisitBudget: &remainingVisitBudget,
                remainingElementBudget: &remainingElementBudget,
                deadline: deadline,
                didHitTimeLimit: &didHitTimeLimit
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
                role: role,
                roleDescription: stringAttribute("AXRoleDescription", from: element),
                valueDescription: UIMapAccessibilityPrivacy.readValueIfAllowed(isSensitive: isSensitive) {
                    valueDescription(from: element)
                },
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
            role: role,
            roleDescription: stringAttribute("AXRoleDescription", from: element),
            valueDescription: UIMapAccessibilityPrivacy.readValueIfAllowed(isSensitive: isSensitive) {
                valueDescription(from: element)
            },
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

        if let windowRelativeMapping {
            return windowRelativeMapping.visibleDocumentRect(fromDocumentRect: clipped)
        }

        return clipped
    }

    private func windowRelativeMapping(
        forRoot root: AccessibilityElementHandle,
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
        let visibleDocumentRects = candidate.visibleCaptureRects.compactMap { visibleCaptureRect -> CGRect? in
            let rect = TopLeftRectTransform(
                sourceBounds: mapping.captureSourceRect,
                targetBounds: mapping.documentRect
            )
                .targetRect(fromSourceRect: visibleCaptureRect)
                .intersection(candidateDocumentRect)
                .intersection(mapping.documentRect)
                .gscIntegralStandardized

            guard rect.width > 0,
                  rect.height > 0 else {
                return nil
            }

            return rect
        }

        UIMapCaptureDiagnostics.notice(
            "[UIMap] window-relative mapping owner='\(candidate.ownerName)' rootRole='\(stringAttribute("AXRole", from: root) ?? "unknown")' rootAXRect=\(Self.describe(rootAccessibilityRect)) candidateDocRect=\(Self.describe(candidateDocumentRect)) visibleDocFragments=\(visibleDocumentRects.count)"
        )

        return UIMapWindowRelativeMapping(
            rootAccessibilityRect: rootAccessibilityRect,
            candidateDocumentRect: candidateDocumentRect,
            visibleDocumentRects: visibleDocumentRects
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
                visibleCaptureRects: [identity.frame.intersection(capture.sourceRect).gscIntegralStandardized],
                layer: 0,
                focusRank: -1
            )
            UIMapCaptureDiagnostics.notice(
                "[UIMap] window capture using source identity windowID=\(identity.windowID) owner='\(identity.ownerName)' pid=\(identity.ownerPID) frame=\(Self.describe(identity.frame)) sourceName='\(capture.sourceName)'"
            )
            return [candidate]
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
                visibleCaptureRects: [frame.intersection(captureRect).gscIntegralStandardized],
                layer: layer,
                focusRank: index
            )
        }
        .sorted { $0.focusRank < $1.focusRank }

        return visibleWindowCandidates(candidates, in: captureRect)
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

            let visibleFragments = visibleFragments(of: candidateCaptureRect, coveredBy: coveredRects)
            let visibleArea = visibleFragments.reduce(0) { $0 + area(of: $1) }
            let visibilityRatio = visibleArea / candidateArea
            UIMapCaptureDiagnostics.notice(
                "[UIMap] candidate visibility owner='\(candidate.ownerName)' visibleArea=\(Self.rounded(visibleArea)) candidateArea=\(Self.rounded(candidateArea)) ratio=\(Self.rounded(visibilityRatio)) fragments=\(visibleFragments.count) frame=\(Self.describe(candidate.frame))"
            )

            if UIMapWindowVisibilityPolicy.shouldCaptureWindow(visibleArea: visibleArea) {
                visibleCandidates.append(candidate.withVisibleCaptureRects(visibleFragments))
            }

            coveredRects.append(candidateCaptureRect)
        }

        return visibleCandidates
    }

    private func visibleFragments(of rect: CGRect, coveredBy coveredRects: [CGRect]) -> [CGRect] {
        var visibleFragments = [rect.gscIntegralStandardized]

        for coveredRect in coveredRects {
            visibleFragments = visibleFragments.flatMap { fragment in
                subtract(coveredRect, from: fragment)
            }

            if visibleFragments.isEmpty {
                return []
            }
        }

        return visibleFragments
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

    private func accessibilityFrame(of element: AccessibilityElementHandle) -> CGRect? {
        guard let frame = accessibility.frame(of: element),
              frame.width > 0,
              frame.height > 0 else {
            return nil
        }

        return frame.gscIntegralStandardized
    }

    private func attribute(_ name: String, from element: AccessibilityElementHandle) -> Any? {
        attributeResult(name, from: element).value
    }

    private func attributeResult(
        _ name: String,
        from element: AccessibilityElementHandle
    ) -> (status: AccessibilityPlatformStatus, value: Any?) {
        var lastStatus = AccessibilityPlatformStatus.failure(-1)
        var lastValue: Any?

        for attempt in 0..<3 {
            let result = accessibility.copyAttribute(name, from: element)
            let status = result.status
            if status == .success {
                return result
            }

            lastStatus = status
            lastValue = result.value

            guard status.isCannotComplete,
                  attempt < 2 else {
                break
            }

            accessibility.wait(seconds: 0.08)
        }

        return (lastStatus, lastValue)
    }

    private func attributeNamesResult(
        from element: AccessibilityElementHandle
    ) -> (status: AccessibilityPlatformStatus, names: [String]) {
        accessibility.copyAttributeNames(from: element)
    }

    private func stringAttribute(_ name: String, from element: AccessibilityElementHandle) -> String? {
        attribute(name, from: element) as? String
    }

    private func elementAttribute(
        _ name: String,
        from element: AccessibilityElementHandle
    ) -> AccessibilityElementHandle? {
        self.element(from: attribute(name, from: element))
    }

    private func element(from value: Any?) -> AccessibilityElementHandle? {
        value as? AccessibilityElementHandle
    }

    private func elementPID(_ element: AccessibilityElementHandle) -> pid_t? {
        let result = accessibility.processIdentifier(for: element)
        guard result.status == .success else {
            return nil
        }

        return result.processID
    }

    private func valueDescription(from element: AccessibilityElementHandle) -> String? {
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

    private func elementChildren(of element: AccessibilityElementHandle) -> [AccessibilityElementHandle] {
        for attributeName in ["AXVisibleChildren", "AXChildren", "AXRows", "AXColumns", "AXMenuItems"] {
            if let children = attribute(attributeName, from: element) as? [AccessibilityElementHandle],
               !children.isEmpty {
                return children
            }
        }

        return []
    }

    private func currentCoordinateMappings() -> [CaptureAccessibilityTransform] {
        screens.screens.compactMap { screen in
            let captureFrame = CGDisplayBounds(screen.displayID)
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
#endif

nonisolated enum UIMapWindowVisibilityPolicy {
    static let minimumVisibleArea: CGFloat = 16

    static func shouldCaptureWindow(visibleArea: CGFloat) -> Bool {
        visibleArea >= minimumVisibleArea
    }
}

nonisolated private func gscIntersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    return max(intersection.width, 0) * max(intersection.height, 0)
}

private extension CGRect {
    nonisolated func coversRecognizedTextRect(_ recognizedRect: CGRect) -> Bool {
        let recognizedArea = max(recognizedRect.width, 0) * max(recognizedRect.height, 0)
        guard recognizedArea > 0 else {
            return true
        }

        let intersection = intersection(recognizedRect)
        let intersectionArea = max(intersection.width, 0) * max(intersection.height, 0)
        if intersectionArea / recognizedArea >= 0.65 {
            return true
        }

        return insetBy(dx: -3, dy: -3).contains(
            CGPoint(x: recognizedRect.midX, y: recognizedRect.midY)
        )
    }
}

private extension String {
    nonisolated var isUsefulUIMapRecognizedText: Bool {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count > 1
            && value.rangeOfCharacter(from: .alphanumerics) != nil
    }
}

private extension CaptureAccessibilityTransform {
    nonisolated func intersectsAccessibilityRect(_ rect: CGRect) -> Bool {
        accessibilityFrame.intersects(rect.standardized)
    }
}

#if !APP_STORE_BUILD
import ApplicationServices
#endif
import CoreGraphics
import Foundation

#if APP_STORE_BUILD
nonisolated struct AccessibilityElementHandle: Hashable, Sendable {
    fileprivate let unavailableToken: Int

    fileprivate static let unavailable = AccessibilityElementHandle(unavailableToken: 0)
}
#else
nonisolated struct AccessibilityElementHandle: Hashable, @unchecked Sendable {
    fileprivate let rawElement: AXUIElement

    static func == (lhs: AccessibilityElementHandle, rhs: AccessibilityElementHandle) -> Bool {
        CFEqual(lhs.rawElement, rhs.rawElement)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(rawElement))
    }
}
#endif

nonisolated struct AccessibilityWindowIdentity: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
}

nonisolated enum AccessibilityPlatformStatus: Equatable, Sendable {
    case success
    case failure(Int32)

#if !APP_STORE_BUILD
    init(_ error: AXError) {
        self = error == .success ? .success : .failure(error.rawValue)
    }
#endif

    var rawValue: Int32 {
        switch self {
        case .success:
            return 0
        case .failure(let value):
            return value
        }
    }

    var isCannotComplete: Bool {
        rawValue == -25204
    }
}

protocol AccessibilityPlatform: Sendable {
    nonisolated func isProcessTrusted() -> Bool
    nonisolated func systemWideElement() -> AccessibilityElementHandle
    nonisolated func applicationElement(processID: pid_t) -> AccessibilityElementHandle
    nonisolated func setMessagingTimeout(_ timeout: TimeInterval, for element: AccessibilityElementHandle)
    nonisolated func element(
        at point: CGPoint,
        from systemElement: AccessibilityElementHandle
    ) -> (status: AccessibilityPlatformStatus, element: AccessibilityElementHandle?)
    nonisolated func copyAttribute(
        _ name: String,
        from element: AccessibilityElementHandle
    ) -> (status: AccessibilityPlatformStatus, value: Any?)
    nonisolated func copyAttributeNames(
        from element: AccessibilityElementHandle
    ) -> (status: AccessibilityPlatformStatus, names: [String])
    nonisolated func copyActionNames(
        from element: AccessibilityElementHandle
    ) -> (status: AccessibilityPlatformStatus, names: [String])
    nonisolated func setNumberAttribute(_ name: String, value: Double, on element: AccessibilityElementHandle)
    nonisolated func processIdentifier(for element: AccessibilityElementHandle) -> (status: AccessibilityPlatformStatus, processID: pid_t)
    nonisolated func frame(of element: AccessibilityElementHandle) -> CGRect?
    nonisolated func windowIdentity(for element: AccessibilityElementHandle) -> AccessibilityWindowIdentity?
    nonisolated func wait(seconds: TimeInterval)
}

nonisolated enum AccessibilityPlatformFactory {
    static func defaultPlatform() -> any AccessibilityPlatform {
        #if APP_STORE_BUILD
        UnavailableAccessibilityPlatform()
        #else
        LiveAccessibilityPlatform()
        #endif
    }
}

extension AccessibilityPlatform {
    /// Returns the current keyboard focus when the platform exposes it. Keeping
    /// this on the abstraction lets workflows reason about typed input without
    /// guessing from the pointer location.
    nonisolated func focusedElement() -> AccessibilityElementHandle? {
        let result = copyAttribute("AXFocusedUIElement", from: systemWideElement())
        guard result.status == .success else { return nil }
        return result.value as? AccessibilityElementHandle
    }
}

#if !APP_STORE_BUILD
nonisolated struct AccessibilityWindowCandidate: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let title: String?
    let frame: CGRect
    let layer: Int
    let order: Int
}

nonisolated enum AccessibilityWindowResolver {
    static func resolve(
        processID: pid_t,
        title: String?,
        accessibilityFrame: CGRect,
        candidates: [AccessibilityWindowCandidate]
    ) -> AccessibilityWindowIdentity? {
        let normalizedFrame = accessibilityFrame.gscIntegralStandardized
        guard normalizedFrame.width > 0, normalizedFrame.height > 0 else {
            return nil
        }

        let scored = candidates
            .filter {
                $0.ownerPID == processID
                    && $0.layer == 0
                    && $0.frame.width > 0
                    && $0.frame.height > 0
            }
            .map { candidate in
                (candidate: candidate, score: matchScore(
                    title: title,
                    accessibilityFrame: normalizedFrame,
                    candidate: candidate
                ))
            }
            .filter { $0.score >= 0.55 }
            .sorted {
                if abs($0.score - $1.score) > 0.000_1 {
                    return $0.score > $1.score
                }
                return $0.candidate.order < $1.candidate.order
            }

        guard let best = scored.first else {
            return nil
        }

        if scored.count > 1,
           best.score - scored[1].score < 0.05 {
            return nil
        }

        return AccessibilityWindowIdentity(
            windowID: best.candidate.windowID,
            ownerPID: best.candidate.ownerPID
        )
    }

    private static func matchScore(
        title: String?,
        accessibilityFrame: CGRect,
        candidate: AccessibilityWindowCandidate
    ) -> CGFloat {
        let candidateFrame = candidate.frame.gscIntegralStandardized
        let intersection = accessibilityFrame.intersection(candidateFrame)
        let intersectionArea = max(intersection.width, 0) * max(intersection.height, 0)
        let referenceArea = min(
            accessibilityFrame.width * accessibilityFrame.height,
            candidateFrame.width * candidateFrame.height
        )
        guard referenceArea > 0 else {
            return 0
        }

        let overlapScore = intersectionArea / referenceArea
        let frameDelta = abs(accessibilityFrame.minX - candidateFrame.minX)
            + abs(accessibilityFrame.minY - candidateFrame.minY)
            + abs(accessibilityFrame.width - candidateFrame.width)
            + abs(accessibilityFrame.height - candidateFrame.height)
        let normalizedDelta = min(
            frameDelta / max(accessibilityFrame.width + accessibilityFrame.height, 1),
            1
        )
        let normalizedTitle = normalized(title)
        let normalizedCandidateTitle = normalized(candidate.title)
        let titleBonus: CGFloat = normalizedTitle != nil && normalizedTitle == normalizedCandidateTitle ? 0.12 : 0

        return overlapScore - normalizedDelta * 0.25 + titleBonus
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

struct LiveAccessibilityPlatform: AccessibilityPlatform {
    nonisolated func isProcessTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    nonisolated func systemWideElement() -> AccessibilityElementHandle {
        AccessibilityElementHandle(rawElement: AXUIElementCreateSystemWide())
    }

    nonisolated func applicationElement(processID: pid_t) -> AccessibilityElementHandle {
        AccessibilityElementHandle(rawElement: AXUIElementCreateApplication(processID))
    }

    nonisolated func setMessagingTimeout(_ timeout: TimeInterval, for element: AccessibilityElementHandle) {
        AXUIElementSetMessagingTimeout(element.rawElement, Float(timeout))
    }

    nonisolated func element(
        at point: CGPoint,
        from systemElement: AccessibilityElementHandle
    ) -> (status: AccessibilityPlatformStatus, element: AccessibilityElementHandle?) {
        var element: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(
            systemElement.rawElement,
            Float(point.x),
            Float(point.y),
            &element
        )
        return (AccessibilityPlatformStatus(status), element.map(AccessibilityElementHandle.init(rawElement:)))
    }

    nonisolated func copyAttribute(
        _ name: String,
        from element: AccessibilityElementHandle
    ) -> (status: AccessibilityPlatformStatus, value: Any?) {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element.rawElement, name as CFString, &value)
        return (AccessibilityPlatformStatus(status), Self.wrapAccessibilityValue(value))
    }

    nonisolated func copyAttributeNames(
        from element: AccessibilityElementHandle
    ) -> (status: AccessibilityPlatformStatus, names: [String]) {
        var names: CFArray?
        let status = AXUIElementCopyAttributeNames(element.rawElement, &names)
        return (AccessibilityPlatformStatus(status), (names as? [String]) ?? [])
    }

    nonisolated func copyActionNames(
        from element: AccessibilityElementHandle
    ) -> (status: AccessibilityPlatformStatus, names: [String]) {
        var names: CFArray?
        let status = AXUIElementCopyActionNames(element.rawElement, &names)
        return (AccessibilityPlatformStatus(status), (names as? [String]) ?? [])
    }

    nonisolated func setNumberAttribute(_ name: String, value: Double, on element: AccessibilityElementHandle) {
        AXUIElementSetAttributeValue(element.rawElement, name as CFString, NSNumber(value: value))
    }

    nonisolated func processIdentifier(for element: AccessibilityElementHandle) -> (status: AccessibilityPlatformStatus, processID: pid_t) {
        var processID: pid_t = 0
        let status = AXUIElementGetPid(element.rawElement, &processID)
        return (AccessibilityPlatformStatus(status), processID)
    }

    nonisolated func frame(of element: AccessibilityElementHandle) -> CGRect? {
        guard let positionObject = rawAttribute("AXPosition", from: element),
              let sizeObject = rawAttribute("AXSize", from: element) else {
            return nil
        }

        guard CFGetTypeID(positionObject) == AXValueGetTypeID(),
              CFGetTypeID(sizeObject) == AXValueGetTypeID() else {
            return nil
        }

        let positionValue = positionObject as! AXValue
        let sizeValue = sizeObject as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width.isFinite,
              size.height.isFinite else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    nonisolated func windowIdentity(for element: AccessibilityElementHandle) -> AccessibilityWindowIdentity? {
        let pidResult = processIdentifier(for: element)
        guard pidResult.status == .success,
              let accessibilityFrame = frame(of: element),
              let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                CGWindowID(0)
              ) as? [[String: Any]] else {
            return nil
        }

        let title = rawAttribute("AXTitle", from: element) as? String
        let candidates = windowInfo.enumerated().compactMap { order, info -> AccessibilityWindowCandidate? in
            guard let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any] else {
                return nil
            }

            guard let frame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
                return nil
            }

            return AccessibilityWindowCandidate(
                windowID: CGWindowID(windowNumber.uint32Value),
                ownerPID: pid_t(ownerPID.int32Value),
                title: info[kCGWindowName as String] as? String,
                frame: frame,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                order: order
            )
        }

        return AccessibilityWindowResolver.resolve(
            processID: pidResult.processID,
            title: title,
            accessibilityFrame: accessibilityFrame,
            candidates: candidates
        )
    }

    nonisolated func wait(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    nonisolated private func rawAttribute(_ name: String, from element: AccessibilityElementHandle) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element.rawElement, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    nonisolated private static func wrapAccessibilityValue(_ value: CFTypeRef?) -> Any? {
        guard let value else {
            return nil
        }

        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            return AccessibilityElementHandle(rawElement: unsafeDowncast(value, to: AXUIElement.self))
        }

        if CFGetTypeID(value) == CFArrayGetTypeID(),
           let values = value as? [AnyObject] {
            return values.map { candidate -> Any in
                let cfCandidate = candidate as CFTypeRef
                if CFGetTypeID(cfCandidate) == AXUIElementGetTypeID() {
                    return AccessibilityElementHandle(rawElement: unsafeDowncast(candidate, to: AXUIElement.self))
                }
                return candidate
            }
        }

        return value
    }
}
#else
struct UnavailableAccessibilityPlatform: AccessibilityPlatform {
    nonisolated func isProcessTrusted() -> Bool { false }
    nonisolated func systemWideElement() -> AccessibilityElementHandle { .unavailable }
    nonisolated func applicationElement(processID: pid_t) -> AccessibilityElementHandle {
        _ = processID
        return .unavailable
    }
    nonisolated func setMessagingTimeout(_ timeout: TimeInterval, for element: AccessibilityElementHandle) {
        _ = timeout
        _ = element
    }
    nonisolated func element(
        at point: CGPoint,
        from systemElement: AccessibilityElementHandle
    ) -> (status: AccessibilityPlatformStatus, element: AccessibilityElementHandle?) {
        _ = point
        _ = systemElement
        return (.failure(-1), nil)
    }
    nonisolated func copyAttribute(
        _ name: String,
        from element: AccessibilityElementHandle
    ) -> (status: AccessibilityPlatformStatus, value: Any?) {
        _ = name
        _ = element
        return (.failure(-1), nil)
    }
    nonisolated func copyAttributeNames(
        from element: AccessibilityElementHandle
    ) -> (status: AccessibilityPlatformStatus, names: [String]) {
        _ = element
        return (.failure(-1), [])
    }
    nonisolated func copyActionNames(
        from element: AccessibilityElementHandle
    ) -> (status: AccessibilityPlatformStatus, names: [String]) {
        _ = element
        return (.failure(-1), [])
    }
    nonisolated func setNumberAttribute(_ name: String, value: Double, on element: AccessibilityElementHandle) {
        _ = name
        _ = value
        _ = element
    }
    nonisolated func processIdentifier(
        for element: AccessibilityElementHandle
    ) -> (status: AccessibilityPlatformStatus, processID: pid_t) {
        _ = element
        return (.failure(-1), 0)
    }
    nonisolated func frame(of element: AccessibilityElementHandle) -> CGRect? {
        _ = element
        return nil
    }
    nonisolated func windowIdentity(for element: AccessibilityElementHandle) -> AccessibilityWindowIdentity? {
        _ = element
        return nil
    }
    nonisolated func wait(seconds: TimeInterval) {
        _ = seconds
    }
}
#endif

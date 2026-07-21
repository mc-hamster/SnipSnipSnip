import ApplicationServices
import Foundation

nonisolated struct AccessibilityElementHandle: Hashable, @unchecked Sendable {
    fileprivate let rawElement: AXUIElement

    static func == (lhs: AccessibilityElementHandle, rhs: AccessibilityElementHandle) -> Bool {
        CFEqual(lhs.rawElement, rhs.rawElement)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(rawElement))
    }
}

nonisolated struct AccessibilityWindowIdentity: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
}

nonisolated enum AccessibilityPlatformStatus: Equatable, Sendable {
    case success
    case failure(Int32)

    init(_ error: AXError) {
        self = error == .success ? .success : .failure(error.rawValue)
    }

    var rawValue: Int32 {
        switch self {
        case .success:
            return AXError.success.rawValue
        case .failure(let value):
            return value
        }
    }

    var isCannotComplete: Bool {
        rawValue == AXError.cannotComplete.rawValue
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
        var windowID = CGWindowID(0)
        guard _AXUIElementGetWindow(element.rawElement, &windowID) == .success,
              windowID != 0 else {
            return nil
        }

        let pidResult = processIdentifier(for: element)
        guard pidResult.status == .success else {
            return nil
        }

        return AccessibilityWindowIdentity(windowID: windowID, ownerPID: pidResult.processID)
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

@_silgen_name("_AXUIElementGetWindow")
nonisolated private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

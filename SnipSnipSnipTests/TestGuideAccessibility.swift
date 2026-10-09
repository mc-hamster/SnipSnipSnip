#if !APP_STORE_BUILD
import CoreGraphics
import Foundation
@testable import SnipSnipSnip

nonisolated struct TestGuideAccessibility: AccessibilityPlatform {
    var isTrusted = true
    private let base = LiveAccessibilityPlatform()
    init(isTrusted: Bool = true) { self.isTrusted = isTrusted }
    func isProcessTrusted() -> Bool { isTrusted }
    func systemWideElement() -> AccessibilityElementHandle { base.systemWideElement() }
    func applicationElement(processID: pid_t) -> AccessibilityElementHandle { base.applicationElement(processID: processID) }
    func setMessagingTimeout(_ timeout: TimeInterval, for element: AccessibilityElementHandle) {}
    func element(at point: CGPoint, from systemElement: AccessibilityElementHandle) -> (status: AccessibilityPlatformStatus, element: AccessibilityElementHandle?) { (.failure(-1), nil) }
    func copyAttribute(_ name: String, from element: AccessibilityElementHandle) -> (status: AccessibilityPlatformStatus, value: Any?) { (.failure(-1), nil) }
    func copyAttributeNames(from element: AccessibilityElementHandle) -> (status: AccessibilityPlatformStatus, names: [String]) { (.failure(-1), []) }
    func copyActionNames(from element: AccessibilityElementHandle) -> (status: AccessibilityPlatformStatus, names: [String]) { (.failure(-1), []) }
    func setNumberAttribute(_ name: String, value: Double, on element: AccessibilityElementHandle) {}
    func processIdentifier(for element: AccessibilityElementHandle) -> (status: AccessibilityPlatformStatus, processID: pid_t) { (.failure(-1), 0) }
    func frame(of element: AccessibilityElementHandle) -> CGRect? { nil }
    func windowIdentity(for element: AccessibilityElementHandle) -> AccessibilityWindowIdentity? { nil }
    func wait(seconds: TimeInterval) {}
}
#endif

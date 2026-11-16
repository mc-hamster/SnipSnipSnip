import AppKit
import SwiftUI
import XCTest

/// Shared native hosting, accessibility lookup and image attachments for layout tests.
@MainActor
enum HostedViewTestSupport {
    private static var hasEnabledHostedAccessibility = false

    static func host<Content: View>(_ view: NSHostingView<Content>, size: CGSize) -> NSWindow {
        enableHostedAccessibility()
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 40, y: 100), size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = CGRect(origin: .zero, size: size)
        window.contentView = view
        window.orderFront(nil)
        return window
    }

    static func find(_ identifier: String, in object: Any, depth: Int = 0) -> (any NSAccessibilityProtocol)? {
        guard depth < 50, let element = accessibilityElement(for: object) else { return nil }
        if element.accessibilityIdentifier() == identifier { return element }
        for child in element.accessibilityChildren() ?? [] {
            if let match = find(identifier, in: child, depth: depth + 1) { return match }
        }
        return nil
    }

    private static func enableHostedAccessibility() {
        guard !hasEnabledHostedAccessibility else { return }
        hasEnabledHostedAccessibility = true
        // SwiftUI builds its accessibility tree on demand. App-hosted tests
        // have no external AX client, so request the tree inside this process.
        NSApp.accessibilitySetValue(
            true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
    }

    private static func accessibilityElement(for object: Any) -> (any NSAccessibilityProtocol)? {
        if let element = object as? any NSAccessibilityProtocol { return element }
        guard let object = object as? NSObject,
              object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
              object.responds(to: NSSelectorFromString("accessibilityChildren")),
              object.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
        // macOS 27 SwiftUI AccessibilityNode implements the public getters but
        // does not declare formal NSAccessibility protocol conformance.
        return HostedAccessibilityNodeAdapter(object: object)
    }

    static func attachment(of view: NSView, name: String) throws -> XCTAttachment {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                       uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }

    static func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        let own = (view as? T).map { [$0] } ?? []
        return own + view.subviews.flatMap { descendants(type, in: $0) }
    }
}

/// Exposes an existing SwiftUI AX node through the formal protocol expected by
/// tests. Values and actions always come from the original node.
nonisolated private final class HostedAccessibilityNodeAdapter: NSAccessibilityElement {
    private let object: NSObject

    init(object: NSObject) {
        self.object = object
        super.init()
    }

    override func accessibilityIdentifier() -> String? {
        value(for: "accessibilityIdentifier") as? String
    }

    override func accessibilityChildren() -> [Any]? {
        value(for: "accessibilityChildren") as? [Any]
    }

    override func accessibilityFrame() -> CGRect {
        // KVC boxes the node's CGRect getter without changing its screen space.
        (value(for: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
    }

    override func accessibilityLabel() -> String? {
        value(for: "accessibilityLabel") as? String
    }

    override func accessibilityValue() -> Any? {
        value(for: "accessibilityValue")
    }

    override func accessibilityHelp() -> String? {
        value(for: "accessibilityHelp") as? String
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        (value(for: "accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:))
    }

    override func isAccessibilityEnabled() -> Bool {
        value(for: "accessibilityEnabled", getter: "isAccessibilityEnabled") as? Bool ?? false
    }

    override func accessibilityPerformPress() -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias PressImplementation = @convention(c) (AnyObject, Selector) -> Bool
        let press = unsafeBitCast(object.method(for: selector), to: PressImplementation.self)
        return press(object, selector)
    }

    private func value(for key: String, getter: String? = nil) -> Any? {
        guard object.responds(to: NSSelectorFromString(getter ?? key)) else { return nil }
        return object.value(forKey: key)
    }
}

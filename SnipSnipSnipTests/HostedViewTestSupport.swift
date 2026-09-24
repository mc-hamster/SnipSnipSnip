import AppKit
import SwiftUI
import XCTest

/// Shared native hosting, accessibility lookup and image attachments for layout tests.
@MainActor
enum HostedViewTestSupport {
    static func host<Content: View>(_ view: NSHostingView<Content>, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 40, y: 100), size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = CGRect(origin: .zero, size: size)
        window.contentView = view
        window.orderFront(nil)
        return window
    }

    static func find(_ identifier: String, in object: Any, depth: Int = 0) -> (any NSAccessibilityProtocol)? {
        guard depth < 50, let element = object as? any NSAccessibilityProtocol else { return nil }
        if element.accessibilityIdentifier() == identifier { return element }
        for child in element.accessibilityChildren() ?? [] {
            if let match = find(identifier, in: child, depth: depth + 1) { return match }
        }
        return nil
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

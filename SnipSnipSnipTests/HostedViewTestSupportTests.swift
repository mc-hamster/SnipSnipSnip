import AppKit
import SwiftUI
import XCTest

@MainActor
final class HostedViewTestSupportTests: XCTestCase {
    func testSwiftUIAccessibilityTreePreservesIdentifiersFramesAndActions() async throws {
        var presses = 0
        let view = NSHostingView(rootView: VStack {
            Button("Fixture Action") { presses += 1 }
                .accessibilityIdentifier("fixture.action")
            Button("Unavailable Action") {}
                .disabled(true)
                .accessibilityIdentifier("fixture.disabled")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fixture.group"))
        let window = HostedViewTestSupport.host(view, size: CGSize(width: 400, height: 300))
        defer { window.close() }
        await waitUntil { HostedViewTestSupport.find("fixture.action", in: view) != nil }
        view.layoutSubtreeIfNeeded()

        XCTAssertNotNil(HostedViewTestSupport.find("fixture.group", in: view))
        let action = try XCTUnwrap(HostedViewTestSupport.find("fixture.action", in: view))
        let frame = action.accessibilityFrame()
        let visible = window.convertToScreen(view.convert(view.bounds, to: nil))
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertTrue(visible.contains(frame))
        XCTAssertTrue(action.isAccessibilityEnabled())
        XCTAssertTrue(action.accessibilityPerformPress())
        XCTAssertEqual(presses, 1)
        let disabled = try XCTUnwrap(HostedViewTestSupport.find("fixture.disabled", in: view))
        XCTAssertFalse(disabled.isAccessibilityEnabled())
    }
}

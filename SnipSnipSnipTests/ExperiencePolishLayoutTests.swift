import AppKit
import SwiftUI
import XCTest
@testable import SnipSnipSnip

@MainActor
final class ExperiencePolishLayoutTests: XCTestCase {
    func testOutputControlsKeepTheirFramesDuringPendingProgress() async throws {
        let activity = ScreenshotOutputActivity(progressDelay: .milliseconds(1))
        let view = NSHostingView(rootView: HStack {
            ScreenshotCopyButton(activity: activity, outputDescription: "Current output", action: {})
            ScreenshotExportMenu(activity: activity, outputDescription: "Current output") {
                Button("PNG…", action: {})
            }
        })
        let window = HostedViewTestSupport.host(view, size: CGSize(width: 500, height: 100))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let identifiers = ["editor.output.copy.current", "editor.output.export.current"]
        let frames = try identifiers.map {
            try XCTUnwrap(HostedViewTestSupport.find($0, in: view)).accessibilityFrame()
        }

        var resumeCopy: CheckedContinuation<Data, Never>?
        defer { resumeCopy?.resume(returning: Data()) }
        activity.copy(key: .init(contentRevision: 1, appearance: .plain, outputSize: .original),
                      render: { await withCheckedContinuation { resumeCopy = $0 } },
                      deliver: { _ in }, didSucceed: {}, didFail: { _ in XCTFail() }, completion: nil)
        let exportID = try XCTUnwrap(activity.beginExport())
        defer { activity.finishExport(id: exportID) }
        activity.beginExportRendering(id: exportID)
        await waitUntil { resumeCopy != nil && activity.showsCopyProgress && activity.showsExportProgress }
        view.layoutSubtreeIfNeeded()
        for (identifier, frame) in zip(identifiers, frames) {
            let control = try XCTUnwrap(HostedViewTestSupport.find(identifier, in: view))
            XCTAssertEqual(control.accessibilityFrame(), frame, identifier)
            XCTAssertFalse(control.isAccessibilityEnabled())
        }
        resumeCopy?.resume(returning: Data())
        resumeCopy = nil
        activity.finishExport(id: exportID)
        await waitUntil { !activity.isCopying }
        view.layoutSubtreeIfNeeded()
        for (identifier, frame) in zip(identifiers, frames) {
            let control = try XCTUnwrap(HostedViewTestSupport.find(identifier, in: view))
            XCTAssertEqual(control.accessibilityFrame(), frame, identifier)
            XCTAssertTrue(control.isAccessibilityEnabled())
        }
    }

    func testSplitToolVariantsKeepIdenticalWidths() {
        for family: [EditorTool] in [
            [.arrow, .numberedArrow], [.rectangle, .ellipse, .line, .statusMark],
            [.freehand, .highlighter], [.spotlight, .measure], [.callout, .ocrText, .colorPicker]
        ] {
            let sizes = family.map { tool in
                NSHostingView(rootView: StableEditorToolLabel(tool: tool, family: family)
                    .font(.subheadline.weight(.medium))).fittingSize
            }
            for size in sizes {
                XCTAssertGreaterThan(size.width, 0)
                XCTAssertEqual(size.width, sizes[0].width, accuracy: 0.5)
                XCTAssertEqual(size.height, sizes[0].height, accuracy: 0.5)
            }
        }
    }
}

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

    func testScreenshotNoticeDoesNotResizeCroppedCanvasOrHideScrollbars() async throws {
        let controller = retainForTestLifetime(EditorController(capture: makeCapturedScreenshot()))
        controller.previewCropRect(CGRect(x: 8, y: 6, width: 40, height: 30))
        let view = NSHostingView(rootView: EditorView(
            controller: controller, isInspectorPresented: .constant(false),
            historyEntries: [], recycleBinEntries: [],
            historyActions: EditorHistoryActions(
                onPresentSnipLibrary: { _ in }, onPresentHistoryPreview: { _ in },
                onCloseHistoryPreview: { _ in }, onRestoreHistoryEntry: { _ in },
                onRestoreRecentSnipEntry: { _ in }, onFloatHistoryEntry: { _ in },
                onDeleteHistoryEntry: { _ in }, onDeleteAllHistoryEntries: {},
                onDeleteRecentSnipEntry: { _ in }, onDeleteAllRecentSnipEntries: {},
                onRestoreRecycledHistoryEntry: { _ in },
                onPermanentlyDeleteRecycledHistoryEntry: { _ in }, onEmptyRecycleBin: {})))
        let window = HostedViewTestSupport.host(view, size: CGSize(width: 800, height: 400))
        defer { controller.dismissNotice(); window.close() }
        let identifiers = ["editor.scrollbar.horizontal", "editor.scrollbar.vertical"]

        for size in [CGSize(width: 800, height: 400), CGSize(width: 360, height: 160)] {
            window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            controller.zoomIn()
            let viewport = controller.viewport
            let crop = controller.snapshot.cropRect
            let minimumSize = view.fittingSize
            let frames = try identifiers.map {
                try XCTUnwrap(HostedViewTestSupport.find($0, in: view)).accessibilityFrame()
            }
            for message in ["Copied screenshot. Ready to paste.",
                            "Copied screenshot with redactions applied. Ready to paste."] {
                controller.showNotice(EditorNotice(message: message, dismissalDelaySeconds: nil))
                try await Task.sleep(for: .milliseconds(150))
                view.layoutSubtreeIfNeeded()
                XCTAssertNotNil(HostedViewTestSupport.find("editor.notice", in: view))
                XCTAssertEqual(view.fittingSize.width, minimumSize.width, accuracy: 0.5)
                XCTAssertEqual(view.fittingSize.height, minimumSize.height, accuracy: 0.5)
                XCTAssertEqual(controller.viewport, viewport)
                XCTAssertEqual(controller.snapshot.cropRect, crop)
                for (identifier, frame) in zip(identifiers, frames) {
                    let scrollbar = try XCTUnwrap(HostedViewTestSupport.find(identifier, in: view))
                    XCTAssertEqual(scrollbar.accessibilityFrame(), frame, identifier)
                    XCTAssertTrue(window.frame.contains(frame), identifier)
                }
                controller.dismissNotice()
                try await Task.sleep(for: .milliseconds(150))
                view.layoutSubtreeIfNeeded()
                XCTAssertEqual(controller.viewport, viewport)
                XCTAssertNil(HostedViewTestSupport.find("editor.notice", in: view))
            }
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

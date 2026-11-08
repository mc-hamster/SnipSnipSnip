import XCTest
@testable import SnipSnipSnip

@MainActor
final class ScreenshotOutputActivityTests: XCTestCase {
    func testDuplicateCopyRendersAndWritesOnceAndCompletesAllCallers() async {
        let activity = ScreenshotOutputActivity()
        let gate = RenderGate()
        var deliveries = 0
        var notices = 0
        var results: [Bool] = []
        for _ in 0..<3 {
            activity.copy(key: key(1), render: gate.render,
                          deliver: { _ in deliveries += 1 },
                          didSucceed: { notices += 1 }, didFail: { _ in XCTFail() },
                          completion: { results.append($0) })
        }
        XCTAssertTrue(activity.isCopying)
        XCTAssertFalse(activity.showsCopyProgress)
        await waitUntil { gate.calls == 1 }
        gate.finish()
        await waitUntil { !activity.isCopying }
        XCTAssertEqual(gate.calls, 1)
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(notices, 1)
        XCTAssertEqual(results, [true, true, true])
        XCTAssertFalse(activity.showsCopyProgress)
    }

    func testChangedCopySupersedesOlderRenderWithoutWritingItsPixels() async {
        let activity = ScreenshotOutputActivity()
        let first = RenderGate()
        let latest = RenderGate()
        var writes: [Data] = []
        var results: [Int: Bool] = [:]
        activity.copy(key: key(1), render: first.render,
                      deliver: { writes.append($0) }, didSucceed: {}, didFail: { _ in XCTFail() },
                      completion: { results[1] = $0 })
        await waitUntil { first.calls == 1 }
        activity.copy(key: key(2), render: latest.render,
                      deliver: { writes.append($0) }, didSucceed: {}, didFail: { _ in XCTFail() },
                      completion: { results[2] = $0 })
        first.finish(Data([1]))
        await waitUntil { latest.calls == 1 }
        XCTAssertTrue(writes.isEmpty)
        latest.finish(Data([2]))
        await waitUntil { !activity.isCopying }
        XCTAssertEqual(writes, [Data([2])])
        XCTAssertEqual(results[1], false)
        XCTAssertEqual(results[2], true)
    }

    func testFailedWriteNeverShowsSuccessAndAllowsRetry() async {
        let activity = ScreenshotOutputActivity()
        var failures = 0
        var success = 0
        var result: Bool?
        activity.copy(key: key(1), render: { Data() },
                      deliver: { _ in throw TestError.write }, didSucceed: { success += 1 },
                      didFail: { _ in failures += 1 }, completion: { result = $0 })
        await waitUntil { !activity.isCopying }
        XCTAssertEqual(result, false)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(success, 0)
        activity.copy(key: key(1), render: { Data() }, deliver: { _ in },
                      didSucceed: { success += 1 }, didFail: { _ in XCTFail() }, completion: nil)
        await waitUntil { !activity.isCopying }
        XCTAssertEqual(success, 1)
    }

    func testSlowCopyAndExportHaveProgressButDestinationSelectionDoesNot() async throws {
        let activity = ScreenshotOutputActivity(progressDelay: .milliseconds(1))
        let gate = RenderGate()
        activity.copy(key: key(1), render: gate.render, deliver: { _ in },
                      didSucceed: {}, didFail: { _ in XCTFail() }, completion: nil)
        await waitUntil { activity.showsCopyProgress && gate.calls == 1 }
        gate.finish()
        await waitUntil { !activity.isCopying }
        XCTAssertFalse(activity.showsCopyProgress)

        let id = try XCTUnwrap(activity.beginExport())
        XCTAssertNil(activity.beginExport())
        XCTAssertFalse(activity.showsExportProgress)
        activity.beginExportRendering(id: id)
        await waitUntil { activity.showsExportProgress }
        activity.finishExport(id: UUID())
        XCTAssertTrue(activity.isExporting)
        activity.finishExport(id: id)
        XCTAssertFalse(activity.isExporting)
        XCTAssertFalse(activity.showsExportProgress)
    }

    private func key(_ revision: Int) -> ScreenshotCopyRequestKey {
        .init(contentRevision: revision, appearance: .plain, outputSize: .original)
    }

    private enum TestError: Error { case write }

    @MainActor
    private final class RenderGate {
        var calls = 0
        private var continuation: CheckedContinuation<Data, Never>?
        func render() async -> Data {
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        func finish(_ data: Data = Data()) {
            continuation?.resume(returning: data)
            continuation = nil
        }
    }
}

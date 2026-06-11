import Foundation
import XCTest
@testable import SnipSnipSnip

private struct ProUpdateFixtureFetcher: ProUpdateReleaseFetching {
    let data: Data

    func releaseData(from url: URL) async throws -> Data {
        data
    }
}

final class ProUpdateCheckerTests: XCTestCase {
    func testVersionParsingHandlesPrefixedReleaseTags() {
        XCTAssertEqual(ProUpdateVersion("v1.2.3")?.components, [1, 2, 3])
        XCTAssertEqual(ProUpdateVersion("SnipSnipSnip Pro 1.2.3 (99) Self Release")?.components, [1, 2, 3])
        XCTAssertNil(ProUpdateVersion("latest"))
    }

    func testVersionComparisonPadsMissingComponents() {
        let shortVersion = ProUpdateVersion("1.2")!
        let paddedVersion = ProUpdateVersion("1.2.0")!
        XCTAssertFalse(shortVersion < paddedVersion)
        XCTAssertFalse(paddedVersion < shortVersion)
        XCTAssertLessThan(ProUpdateVersion("1.2.9")!, ProUpdateVersion("1.3")!)
        XCTAssertLessThan(ProUpdateVersion("1.9.9")!, ProUpdateVersion("1.10")!)
    }

    func testCheckReportsAvailableUpdateFromLatestGitHubRelease() async throws {
        let result = try await ProUpdateChecker.check(
            currentVersionString: "1.0.20",
            fetcher: ProUpdateFixtureFetcher(data: releaseJSON(tag: "pro-v1.0.21", name: "SnipSnipSnip Pro 1.0.21"))
        )

        XCTAssertTrue(result.updateIsAvailable)
        XCTAssertEqual(result.currentDisplayVersion, "1.0.20")
        XCTAssertEqual(result.latestRelease.name, "SnipSnipSnip Pro 1.0.21")
        XCTAssertEqual(result.latestRelease.displayVersion, "pro-v1.0.21")
        XCTAssertEqual(result.latestRelease.pageURL.absoluteString, "https://github.com/mc-hamster/SnipSnipSnip/releases/tag/pro-v1.0.21")
    }

    func testCheckReportsCurrentBuildIsUpToDate() async throws {
        let result = try await ProUpdateChecker.check(
            currentVersionString: "1.0.20",
            fetcher: ProUpdateFixtureFetcher(data: releaseJSON(tag: "pro-v1.0.20", name: "SnipSnipSnip Pro 1.0.20"))
        )

        XCTAssertFalse(result.updateIsAvailable)
    }

    private func releaseJSON(tag: String, name: String?) -> Data {
        let fields: [String: Any?] = [
            "tag_name": tag,
            "name": name,
            "html_url": "https://github.com/mc-hamster/SnipSnipSnip/releases/tag/\(tag)"
        ]
        let json = fields.compactMapValues { $0 }
        return try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }
}

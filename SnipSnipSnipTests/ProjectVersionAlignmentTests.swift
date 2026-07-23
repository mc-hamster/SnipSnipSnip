import XCTest

final class ProjectVersionAlignmentTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testVersionBuildSettingsAreDefinedOnlyAtProjectLevel() throws {
        let projectURL = repositoryRoot
            .appendingPathComponent("SnipSnipSnip.xcodeproj")
            .appendingPathComponent("project.pbxproj")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        assertSharedProjectSetting(
            "MARKETING_VERSION",
            in: project,
            message: "Keep MARKETING_VERSION only on the project Debug and Release configurations so app targets inherit one shared version."
        )
        assertSharedProjectSetting(
            "CURRENT_PROJECT_VERSION",
            in: project,
            message: "Keep CURRENT_PROJECT_VERSION only on the project Debug and Release configurations so app targets inherit one shared build number."
        )
    }

    func testShippedInfoPlistsUseSharedVersionBuildSettings() throws {
        let appInfo = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip-Info.plist"),
            encoding: .utf8
        )
        let shareExtensionInfo = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnipShareExtension/Info.plist"),
            encoding: .utf8
        )
        let commandLineHelperInfo = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnipCLI/Info.plist"),
            encoding: .utf8
        )

        for plist in [appInfo, shareExtensionInfo, commandLineHelperInfo] {
            XCTAssertTrue(plist.contains("<key>CFBundleShortVersionString</key>\n\t<string>$(MARKETING_VERSION)</string>"))
            XCTAssertTrue(plist.contains("<key>CFBundleVersion</key>\n\t<string>$(CURRENT_PROJECT_VERSION)</string>"))
        }
    }

    func testReleaseAutomationRunsTheCompleteSuiteAndRequiresHumanConfirmations() throws {
        let ciWorkflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/ci-tests.yml"),
            encoding: .utf8
        )
        let releaseWorkflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-app-store.yml"),
            encoding: .utf8
        )
        let fastfile = try String(
            contentsOf: repositoryRoot.appendingPathComponent("fastlane/Fastfile"),
            encoding: .utf8
        )

        XCTAssertFalse(ciWorkflow.contains("-only-testing"))
        XCTAssertFalse(releaseWorkflow.contains("-only-testing"))
        XCTAssertTrue(fastfile.contains("RELEASE_TEST_TARGETS_DEFAULT = [].freeze"))
        XCTAssertTrue(releaseWorkflow.contains("RELEASE_METADATA_READY: ${{ inputs.metadata_ready }}"))
        XCTAssertTrue(releaseWorkflow.contains("RELEASE_MANUAL_QA_CONFIRMED: ${{ inputs.manual_qa_confirmed }}"))
        XCTAssertFalse(releaseWorkflow.contains("RELEASE_METADATA_READY: true"))
        XCTAssertFalse(releaseWorkflow.contains("RELEASE_MANUAL_QA_CONFIRMED: true"))
    }

    private func buildSettingValues(named settingName: String, in project: String) -> [String] {
        let pattern = #"\#(settingName) = ([^;]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(project.startIndex..<project.endIndex, in: project)
        return regex.matches(in: project, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: project) else {
                return nil
            }

            return String(project[valueRange])
        }
    }

    private func assertSharedProjectSetting(
        _ settingName: String,
        in project: String,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let values = buildSettingValues(named: settingName, in: project)
        XCTAssertEqual(values.count, 2, message, file: file, line: line)
        XCTAssertEqual(Set(values).count, 1, message, file: file, line: line)
    }
}

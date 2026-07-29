import XCTest

final class ProjectVersionAlignmentTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testBuildNumberIsDefinedOnlyAtProjectLevel() throws {
        let projectURL = repositoryRoot
            .appendingPathComponent("SnipSnipSnip.xcodeproj")
            .appendingPathComponent("project.pbxproj")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

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

    func testFastlaneBuildNumberBumpsPreserveSharedBuildSettingReferences() throws {
        let fastfile = try String(
            contentsOf: repositoryRoot.appendingPathComponent("fastlane/Fastfile"),
            encoding: .utf8
        )
        let incrementCallCount = fastfile.components(separatedBy: "increment_build_number(").count - 1
        let preservingOptionCount = fastfile.components(separatedBy: "skip_info_plist: true").count - 1

        XCTAssertGreaterThan(incrementCallCount, 0)
        XCTAssertEqual(
            preservingOptionCount,
            incrementCallCount,
            "Every Fastlane build-number bump must preserve Info.plist references to CURRENT_PROJECT_VERSION."
        )
    }

    func testFastlaneTreatsXcodeMarketingVersionAsReadOnlyAndAppliesItToEveryTarget() throws {
        let fastfile = try String(
            contentsOf: repositoryRoot.appendingPathComponent("fastlane/Fastfile"),
            encoding: .utf8
        )

        XCTAssertFalse(
            fastfile.contains("increment_version_number("),
            "Fastlane must never change the Xcode-owned x.y.z marketing version."
        )
        XCTAssertFalse(
            fastfile.contains("Auto-incrementing release version"),
            "Release automation must not invent a marketing version."
        )
        XCTAssertTrue(
            fastfile.contains("ensure_xcode_owned_marketing_version!(options)"),
            "Build-number preparation must reject Fastlane marketing-version overrides."
        )
        XCTAssertTrue(
            fastfile.contains("MARKETING_VERSION=#{Shellwords.escape(marketing_version)}"),
            "Archives must apply the app's Xcode marketing version to every shipped target."
        )

        let appStoreWorkflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                ".github/workflows/release-app-store.yml"
            ),
            encoding: .utf8
        )
        let selfReleaseWorkflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                ".github/workflows/release-self-release.yml"
            ),
            encoding: .utf8
        )

        for workflow in [appStoreWorkflow, selfReleaseWorkflow] {
            XCTAssertFalse(
                workflow.contains("inputs.version"),
                "Release workflows must use the marketing version checked into Xcode."
            )
        }
    }

    func testAppInfoPlistProhibitsMultipleInstances() throws {
        let appInfo = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip-Info.plist"),
            encoding: .utf8
        )

        XCTAssertTrue(
            appInfo.contains("<key>LSMultipleInstancesProhibited</key>\n\t<true/>"),
            "Keep Launch Services configured to reject a second SnipSnipSnip process."
        )
    }

    func testBuiltAppProhibitsMultipleInstances() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "LSMultipleInstancesProhibited") as? Bool,
            true,
            "The generated app bundle must prohibit multiple instances, not just its source plist."
        )
    }

    func testSingleInstanceEnforcementPrecedesAppModelCreation() throws {
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/SnipSnipSnipApp.swift"),
            encoding: .utf8
        )
        let enforcement = try XCTUnwrap(
            appSource.range(of: "SingleInstanceCoordinator.enforceAtLaunch()")
        )
        let modelCreation = try XCTUnwrap(
            appSource.range(of: "let model = AppModel()")
        )

        XCTAssertLessThan(
            enforcement.lowerBound,
            modelCreation.lowerBound,
            "Reject duplicate processes before constructing app services or shared-state stores."
        )
    }

    func testAppHostedUnitTestsDoNotConfigureLiveMenuBarCaptureServices() throws {
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("SnipSnipSnip/SnipSnipSnipApp.swift"),
            encoding: .utf8
        )
        let testGuard = try XCTUnwrap(
            appSource.range(of: "if !AppModel.isRunningUnitTests")
        )
        let menuBarConfiguration = try XCTUnwrap(
            appSource.range(of: "MenuBarStatusController.shared.configure(")
        )

        XCTAssertLessThan(
            testGuard.lowerBound,
            menuBarConfiguration.lowerBound,
            "The XCTest app host must not start the menu bar's live window-thumbnail refresh."
        )
    }

    func testAppHostedUnitTestsUseIsolatedClipboardAndRecoveryStores() throws {
        let launchSupport = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "SnipSnipSnip/Support/CompositionUITestLaunchSupport.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(launchSupport.contains("makeUnitTestHostAppModel()"))
        XCTAssertTrue(launchSupport.contains("SnipSnipSnip-UnitTestHost-"))
        XCTAssertTrue(launchSupport.contains("clipboardHistoryStore: ClipboardHistoryStore("))
        XCTAssertTrue(launchSupport.contains("loadStoredHistory: false"))
        XCTAssertTrue(launchSupport.contains("shouldStartArchiveMaintenance: false"))
    }

    func testWorkspaceInstructionsDocumentSingleInstanceDevelopmentRules() throws {
        let agents = try String(
            contentsOf: repositoryRoot.appendingPathComponent("AGENTS.md"),
            encoding: .utf8
        )
        let contributing = try String(
            contentsOf: repositoryRoot.appendingPathComponent("CONTRIBUTING.md"),
            encoding: .utf8
        )
        let sharedScheme = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("SnipSnipSnip.xcodeproj")
                .appendingPathComponent("xcshareddata/xcschemes/SnipSnipSnip.xcscheme"),
            encoding: .utf8
        )

        for requiredInstruction in [
            "## Single-Instance Development",
            "`LSMultipleInstancesProhibited`",
            "`SingleInstanceCoordinator`",
            "`xcodebuild build-for-testing`",
            "Run app-hosted XCTest suites in one host process",
            "Do not use `open -n`"
        ] {
            XCTAssertTrue(
                agents.contains(requiredInstruction),
                "AGENTS.md must retain the single-instance instruction: \(requiredInstruction)"
            )
        }

        XCTAssertTrue(contributing.contains("only one app process at a time"))
        XCTAssertTrue(contributing.contains("Quit any running copy"))
        XCTAssertTrue(contributing.contains("`xcodebuild build-for-testing`"))
        XCTAssertTrue(contributing.contains("Do not use `open -n`"))
        XCTAssertTrue(
            sharedScheme.contains(#"parallelizable = "NO""#),
            "The app-hosted test target must use one process because the app is single-instance."
        )
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
        let selfReleaseWorkflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release-self-release.yml"),
            encoding: .utf8
        )
        let releaseTestGate = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Tools/run-release-test-gate.sh"),
            encoding: .utf8
        )
        let sharedScheme = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("SnipSnipSnip.xcodeproj")
                .appendingPathComponent("xcshareddata/xcschemes/SnipSnipSnip.xcscheme"),
            encoding: .utf8
        )
        let fastfile = try String(
            contentsOf: repositoryRoot.appendingPathComponent("fastlane/Fastfile"),
            encoding: .utf8
        )

        XCTAssertFalse(ciWorkflow.contains("-only-testing"))
        XCTAssertFalse(releaseWorkflow.contains("-only-testing"))
        XCTAssertFalse(selfReleaseWorkflow.contains("-only-testing"))
        XCTAssertTrue(fastfile.contains("RELEASE_TEST_TARGETS_DEFAULT = [].freeze"))
        for workflow in [ciWorkflow, releaseWorkflow, selfReleaseWorkflow] {
            XCTAssertTrue(workflow.contains("Tools/run-release-test-gate.sh"))
            XCTAssertTrue(workflow.contains("SSS_RUN_EXTERNAL_HTML_BROWSER_TESTS"))
            XCTAssertTrue(workflow.contains("SSS_REQUIRE_EXTERNAL_HTML_BROWSERS"))
            XCTAssertFalse(workflow.contains("CODE_SIGNING_ALLOWED=NO"))
        }
        XCTAssertTrue(selfReleaseWorkflow.contains("needs: preflight"))
        XCTAssertTrue(releaseTestGate.contains("build-for-testing"))
        XCTAssertTrue(releaseTestGate.contains("test-without-building"))
        XCTAssertTrue(releaseTestGate.contains("codesign --force --sign -"))
        XCTAssertTrue(releaseTestGate.contains("-parallel-testing-enabled NO"))
        XCTAssertTrue(releaseTestGate.contains("pgrep -x"))
        for browserEnvironmentName in [
            "SSS_RUN_EXTERNAL_HTML_BROWSER_TESTS",
            "SSS_REQUIRE_EXTERNAL_HTML_BROWSERS",
            "SSS_GOOGLE_CHROME_BINARY",
            "SSS_FIREFOX_BINARY",
        ] {
            XCTAssertTrue(releaseTestGate.contains(browserEnvironmentName))
            XCTAssertTrue(
                sharedScheme.contains(#"key = "\#(browserEnvironmentName)""#)
            )
            XCTAssertTrue(
                sharedScheme.contains(#"value = "$(\#(browserEnvironmentName))""#)
            )
        }
        XCTAssertEqual(
            fastfile.components(separatedBy: "run_release_test_gate(options)").count - 1,
            2,
            "App Store and Self Release lanes must both run the complete release test gate."
        )
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

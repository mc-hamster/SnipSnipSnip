import XCTest
@testable import SnipSnipSnip

@MainActor
final class AppModelTests: XCTestCase {
    private func makeDefaults(named suiteName: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeHistoryEntry(
        title: String = "Snapshot.sss",
        label: String = "Capture",
        changeSummary: String? = nil,
        searchableText: String,
        hasUnsavedChanges: Bool = true
    ) -> DocumentHistoryEntry {
        DocumentHistoryEntry(
            id: UUID(),
            sessionID: UUID(),
            title: title,
            label: label,
            changeSummary: changeSummary,
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            packageURL: URL(fileURLWithPath: "/tmp/checkpoint.sss"),
            previewAssetURL: nil,
            sourceDocumentURL: nil,
            hasUnsavedChanges: hasUnsavedChanges,
            searchableText: searchableText,
            packageSizeBytes: nil,
            deletedAt: nil
        )
    }

    private func writeScreenshotPackageManifestVersion(_ version: Int, at packageURL: URL) throws {
        let manifestURL = packageURL.appendingPathComponent(SSSDocumentPackage.manifestFilename)
        let data = try Data(contentsOf: manifestURL)
        var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        manifest?["formatVersion"] = version
        let updatedData = try JSONSerialization.data(withJSONObject: manifest ?? [:], options: [.prettyPrinted, .sortedKeys])
        try updatedData.write(to: manifestURL, options: .atomic)
    }

    func testScreenshotCaptureRequiresAccessibilityOnlyForWindowUIMapRequests() {
        let suiteName = "AppModelTests.screenshotCaptureUIMapRequirements"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        model.uiMapEnabled = true
        XCTAssertEqual(model.screenshotCapturePermissionRequirements, [.screenRecording])
        XCTAssertEqual(model.screenshotCapturePermissionRequirements(for: .region(.zero)), [.screenRecording])
        XCTAssertEqual(model.screenshotCapturePermissionRequirements(for: .fullscreen), [.screenRecording])
        XCTAssertEqual(model.screenshotCapturePermissionRequirements(for: .scrolling(.zero)), [.screenRecording])
        XCTAssertEqual(model.screenshotCapturePermissionRequirements(for: .connectedDevice(ConnectedAppleDevice(id: "fixture", name: "iPhone", modelName: nil))), [.screenRecording])
        XCTAssertEqual(model.screenshotCapturePermissionRequirements(for: .frontmostWindow), [.screenRecording, .accessibility])
        XCTAssertEqual(model.screenshotCapturePermissionRequirements(for: .window(makeCaptureWindow(id: 1))), [.screenRecording, .accessibility])
        XCTAssertEqual(model.screenshotCaptureFeatureName(for: .window(makeCaptureWindow(id: 1))), "Window Capture with UI Map")

        model.uiMapEnabled = false
        XCTAssertEqual(model.screenshotCapturePermissionRequirements, [.screenRecording])
        XCTAssertEqual(model.screenshotCaptureFeatureName, "Capture")
        XCTAssertEqual(model.screenshotCapturePermissionRequirements(for: .window(makeCaptureWindow(id: 1))), [.screenRecording])
    }

    func testEverydayWorkflowPreferencesDefaultPersistAndReset() {
        let suiteName = "AppModelTests.everydayWorkflowPreferences"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        XCTAssertEqual(model.screenshotFullscreenDisplayMode, .currentDisplay)
        XCTAssertNil(model.selectedScreenshotFullscreenDisplayID)
        XCTAssertEqual(model.screenshotJPEGQuality, ImageExportOptions.default.jpegQuality)
        XCTAssertTrue(model.editorSingleKeyToolShortcutsEnabled)
        XCTAssertFalse(model.regionCapturePreferences.advancedControlsEnabled)

        model.screenshotFullscreenDisplayMode = .selectedDisplay
        model.selectedScreenshotFullscreenDisplayID = 42
        model.screenshotJPEGQuality = 0.66
        model.editorSingleKeyToolShortcutsEnabled = false
        var regionPreferences = model.regionCapturePreferences
        regionPreferences.advancedControlsEnabled = true
        model.regionCapturePreferences = regionPreferences

        let reloaded = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        XCTAssertEqual(reloaded.screenshotFullscreenDisplayMode, .selectedDisplay)
        XCTAssertEqual(reloaded.selectedScreenshotFullscreenDisplayID, 42)
        XCTAssertEqual(reloaded.screenshotJPEGQuality, 0.66, accuracy: 0.001)
        XCTAssertFalse(reloaded.editorSingleKeyToolShortcutsEnabled)
        XCTAssertTrue(reloaded.regionCapturePreferences.advancedControlsEnabled)

        reloaded.resetPreferencesToDefaults()

        XCTAssertEqual(reloaded.screenshotFullscreenDisplayMode, .currentDisplay)
        XCTAssertNil(reloaded.selectedScreenshotFullscreenDisplayID)
        XCTAssertEqual(reloaded.screenshotJPEGQuality, ImageExportOptions.default.jpegQuality)
        XCTAssertTrue(reloaded.editorSingleKeyToolShortcutsEnabled)
        XCTAssertFalse(reloaded.regionCapturePreferences.advancedControlsEnabled)
    }

    func testEditableRedactionSaveGateSkipsPromptWithoutRedactions() {
        let suiteName = "AppModelTests.editableRedactionSaveGateNoRedactions"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        let controller = EditorController(capture: makeCapturedScreenshot())
        var promptCount = 0
        model.editableRedactionSaveConfirmationHandler = {
            promptCount += 1
            return .cancel
        }

        XCTAssertTrue(model.handleEditableRedactionSaveIfNeeded(for: controller))
        XCTAssertEqual(promptCount, 0)
    }

    func testEditableRedactionSaveGatePromptsOnceWhenEditableSaveIsAllowed() {
        let suiteName = "AppModelTests.editableRedactionSaveGatePromptsOnce"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        let redaction = Annotation.makeSolidRedaction(in: CGRect(x: 10, y: 10, width: 40, height: 30))
        let snapshot = makeEditorSnapshot(annotations: [redaction])
        let controller = EditorController(
            capture: makeCapturedScreenshot(),
            session: makeEditorDocumentSession(initialSnapshot: snapshot, currentSnapshot: snapshot)
        )
        var promptCount = 0
        model.editableRedactionSaveConfirmationHandler = {
            promptCount += 1
            return .saveEditable
        }

        XCTAssertTrue(model.handleEditableRedactionSaveIfNeeded(for: controller))
        XCTAssertTrue(model.handleEditableRedactionSaveIfNeeded(for: controller))
        XCTAssertEqual(promptCount, 1)
    }

    func testEditableRedactionSaveGateCancelsOrExportsWithoutAllowingEditableSave() {
        let suiteName = "AppModelTests.editableRedactionSaveGateCancelExport"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        let redaction = Annotation.makeSolidRedaction(in: CGRect(x: 10, y: 10, width: 40, height: 30))
        let snapshot = makeEditorSnapshot(annotations: [redaction])
        let controller = EditorController(
            capture: makeCapturedScreenshot(),
            session: makeEditorDocumentSession(initialSnapshot: snapshot, currentSnapshot: snapshot)
        )
        var decisions: [EditableRedactionSaveDecision] = [.cancel, .exportFlattenedPNG]
        model.editableRedactionSaveConfirmationHandler = {
            decisions.removeFirst()
        }

        XCTAssertFalse(model.handleEditableRedactionSaveIfNeeded(for: controller))
        XCTAssertFalse(model.handleEditableRedactionSaveIfNeeded(for: controller))
        XCTAssertTrue(decisions.isEmpty)
    }

    func testAutosaveStyleEditableDocumentWriteDoesNotPromptForRedactions() async {
        let suiteName = "AppModelTests.autosaveStyleRedactionWrite"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathExtension("sss")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        let redaction = Annotation.makeSolidRedaction(in: CGRect(x: 10, y: 10, width: 40, height: 30))
        let snapshot = makeEditorSnapshot(annotations: [redaction])
        let controller = EditorController(
            capture: makeCapturedScreenshot(),
            session: makeEditorDocumentSession(initialSnapshot: snapshot, currentSnapshot: snapshot)
        )
        var promptCount = 0
        model.editableRedactionSaveConfirmationHandler = {
            promptCount += 1
            return .cancel
        }

        let didSave = await model.saveDocument(controller, to: outputURL)

        XCTAssertTrue(didSave)
        XCTAssertEqual(promptCount, 0)
    }

    func testUIMapCaptureEligibilityRequiresWindowIdentityAndAccessibility() {
        let suiteName = "AppModelTests.uiMapEligibility"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        model.uiMapEnabled = true
        model.permissionStatus = CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true)

        let window = makeCaptureWindow(id: 5)
        let eligibleWindowCapture = makeCapturedScreenshot(
            kind: .window,
            sourceWindowIdentity: CaptureSourceWindowIdentity(window: window)
        )
        XCTAssertTrue(model.uiMapCaptureEligibility(for: eligibleWindowCapture).shouldCapture)

        let windowWithoutIdentity = makeCapturedScreenshot(kind: .window)
        XCTAssertFalse(model.uiMapCaptureEligibility(for: windowWithoutIdentity).shouldCapture)
        XCTAssertEqual(model.uiMapCaptureEligibility(for: windowWithoutIdentity).skipReason, "window capture has no source window identity")

        let regionCapture = makeCapturedScreenshot(kind: .region)
        XCTAssertFalse(model.uiMapCaptureEligibility(for: regionCapture).shouldCapture)
        XCTAssertEqual(model.uiMapCaptureEligibility(for: regionCapture).skipReason, "UI Map is limited to Window captures")

        model.permissionStatus = CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false)
        let missingAccessibilityEligibility = model.uiMapCaptureEligibility(for: eligibleWindowCapture)
        XCTAssertFalse(missingAccessibilityEligibility.shouldCapture)
        XCTAssertTrue(missingAccessibilityEligibility.needsAccessibilityAccess)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

        while !condition() && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: () async -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

        while !(await condition()) && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testWindowRefreshStagesThumbnailUpdateWhenExistingWindowsAreVisible() async {
        let suiteName = "AppModelTests.windowRefreshStagesThumbnailUpdate"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let captureService = WindowRefreshCaptureService()
        let model = retainForTestLifetime(
            AppModel(
                defaults: defaults,
                recoveryStore: DocumentRecoveryStore(baseURL: nil),
                captureService: captureService,
                shouldCheckCompatibilityOnLaunch: false,
                shouldStartArchiveMaintenance: false
            )
        )
        model.permissionStatus = CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true)
        model.availableWindows = [
            makeCaptureWindow(
                id: 1,
                thumbnailSize: CGSize(width: 20, height: 20),
                thumbnailColor: PixelSample(red: 20, green: 40, blue: 60, alpha: 255)
            )
        ]
        let startingGeneration = model.windowThumbnailRefreshGeneration

        await model.loadAvailableWindows(requestAccessIfNeeded: false, presentPicker: false, showErrors: false, includeThumbnails: true)

        let immediateRequests = await captureService.includeThumbnailRequests()
        XCTAssertEqual(immediateRequests.first, false)
        XCTAssertEqual(model.windowThumbnailRefreshGeneration, startingGeneration)
        XCTAssertEqual(model.availableWindows.first?.thumbnail?.width, 20)
        XCTAssertEqual(
            model.availableWindows.first?.thumbnail.map { samplePixel(in: $0, topLeftX: 0, topLeftY: 0) },
            PixelSample(red: 20, green: 40, blue: 60, alpha: 255)
        )

        await waitUntil {
            model.windowThumbnailRefreshGeneration == startingGeneration + 1
        }

        let finishedRequests = await captureService.includeThumbnailRequests()
        XCTAssertEqual(finishedRequests, [false, true])
        XCTAssertEqual(model.availableWindows.first?.thumbnail?.width, 20)
        XCTAssertEqual(
            model.availableWindows.first?.thumbnail.map { samplePixel(in: $0, topLeftX: 0, topLeftY: 0) },
            PixelSample(red: 80, green: 120, blue: 180, alpha: 255)
        )
    }

    func testAutoWindowRefreshDoesNotCancelPendingThumbnailUpdate() async {
        let suiteName = "AppModelTests.autoWindowRefreshDoesNotCancelPendingThumbnailUpdate"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let captureService = WindowRefreshCaptureService(thumbnailDelayNanoseconds: 300_000_000)
        let model = retainForTestLifetime(
            AppModel(
                defaults: defaults,
                recoveryStore: DocumentRecoveryStore(baseURL: nil),
                captureService: captureService,
                shouldCheckCompatibilityOnLaunch: false,
                shouldStartArchiveMaintenance: false
            )
        )
        model.permissionStatus = CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true)
        model.availableWindows = [makeCaptureWindow(id: 1, thumbnailSize: CGSize(width: 20, height: 20))]

        await model.loadAvailableWindows(requestAccessIfNeeded: false, presentPicker: false, showErrors: false, includeThumbnails: true)
        await waitUntil {
            await captureService.includeThumbnailRequests().count == 2
        }

        model.refreshAvailableWindows(
            includeThumbnails: true,
            allowsCancellingPendingThumbnailRefresh: false
        )

        try? await Task.sleep(nanoseconds: 75_000_000)
        let requestsWhileThumbnailIsPending = await captureService.includeThumbnailRequests()
        XCTAssertEqual(requestsWhileThumbnailIsPending, [false, true])

        await waitUntil {
            model.windowThumbnailRefreshGeneration == 1
        }

        let finishedRequests = await captureService.includeThumbnailRequests()
        XCTAssertEqual(finishedRequests, [false, true])
        XCTAssertEqual(model.availableWindows.first?.thumbnail?.width, 20)
    }

    func testApplicationForegroundRefreshesWindowsWhenAutoRefreshIsDisabled() async {
        let suiteName = "AppModelTests.applicationForegroundRefreshesWindowsWhenAutoRefreshIsDisabled"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let captureService = WindowRefreshCaptureService()
        let model = retainForTestLifetime(
            AppModel(
                defaults: defaults,
                recoveryStore: DocumentRecoveryStore(baseURL: nil),
                captureService: captureService,
                shouldCheckCompatibilityOnLaunch: false,
                shouldStartArchiveMaintenance: false
            )
        )
        model.permissionStatus = CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true)
        model.autoRefreshWindowsEnabled = false
        model.availableWindows = [makeCaptureWindow(id: 1, thumbnailSize: CGSize(width: 20, height: 20))]

        model.handleApplicationDidBecomeActive()

        await waitUntil {
            await captureService.includeThumbnailRequests().count == 1
        }

        let requests = await captureService.includeThumbnailRequests()
        XCTAssertEqual(requests.first, false)
    }

    func testScreenRulerPreferencesLoadSanitizedValues() throws {
        let suiteName = "AppModelTests.screenRulerPreferencesLoadSanitizedValues"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = ScreenRulerPreferences(
            opacity: 3,
            tickSpacing: 1,
            majorTickEvery: 100,
            showsHalfMarkers: false,
            showsMouseDistance: false,
            horizontalTickEdge: .top,
            verticalTickEdge: .right,
            horizontalOrigin: .right,
            verticalOrigin: .bottom
        )
        defaults.set(try JSONEncoder().encode(preferences), forKey: AppModelPreferenceKey.screenRulerPreferences)

        let loadedPreferences = AppModel.loadScreenRulerPreferences(from: defaults)

        XCTAssertEqual(loadedPreferences.opacity, 1)
        XCTAssertEqual(loadedPreferences.tickSpacing, 4)
        XCTAssertEqual(loadedPreferences.majorTickEvery, 20)
        XCTAssertFalse(loadedPreferences.showsHalfMarkers)
        XCTAssertFalse(loadedPreferences.showsMouseDistance)
        XCTAssertEqual(loadedPreferences.horizontalTickEdge, .top)
        XCTAssertEqual(loadedPreferences.verticalTickEdge, .right)
        XCTAssertEqual(loadedPreferences.horizontalOrigin, .right)
        XCTAssertEqual(loadedPreferences.verticalOrigin, .bottom)
    }

    func testScreenRulerPreferencesLoadDefaultsForOlderPayloads() throws {
        let suiteName = "AppModelTests.screenRulerPreferencesLoadDefaultsForOlderPayloads"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyPayload: [String: Any] = [
            "opacity": 0.74,
            "tickSpacing": 18,
            "majorTickEvery": 4,
            "showsHalfMarkers": true,
            "showsMouseDistance": false
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacyPayload), forKey: AppModelPreferenceKey.screenRulerPreferences)

        let loadedPreferences = AppModel.loadScreenRulerPreferences(from: defaults)

        XCTAssertEqual(loadedPreferences.opacity, 0.74)
        XCTAssertEqual(loadedPreferences.tickSpacing, 18)
        XCTAssertEqual(loadedPreferences.majorTickEvery, 4)
        XCTAssertTrue(loadedPreferences.showsHalfMarkers)
        XCTAssertFalse(loadedPreferences.showsMouseDistance)
        XCTAssertEqual(loadedPreferences.horizontalTickEdge, .bottom)
        XCTAssertEqual(loadedPreferences.verticalTickEdge, .left)
        XCTAssertEqual(loadedPreferences.horizontalOrigin, .left)
        XCTAssertEqual(loadedPreferences.verticalOrigin, .top)
    }

    func testResetPreferencesRestoresScreenRulerDefaults() {
        let suiteName = "AppModelTests.resetPreferencesRestoresScreenRulerDefaults"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = retainForTestLifetime(
            AppModel(
                defaults: defaults,
                recoveryStore: DocumentRecoveryStore(baseURL: nil),
                shouldCheckCompatibilityOnLaunch: false,
                shouldStartArchiveMaintenance: false
            )
        )
        model.screenRulerPreferences = ScreenRulerPreferences(
            opacity: 0.42,
            tickSpacing: 24,
            majorTickEvery: 8,
            showsHalfMarkers: false,
            showsMouseDistance: false,
            horizontalTickEdge: .top,
            verticalTickEdge: .right,
            horizontalOrigin: .right,
            verticalOrigin: .bottom
        )

        model.resetPreferencesToDefaults()

        XCTAssertEqual(model.screenRulerPreferences, .default)
    }

    func testScreenInspectorPreferencesPersistAndReload() {
        let suiteName = "AppModelTests.screenInspectorPreferencesPersistAndReload"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = retainForTestLifetime(
            AppModel(
                defaults: defaults,
                recoveryStore: DocumentRecoveryStore(baseURL: nil),
                shouldCheckCompatibilityOnLaunch: false,
                shouldStartArchiveMaintenance: false
            )
        )
        model.screenInspectorPreferences = ScreenInspectorPreferences(
            zoomLevel: .sixteen,
            showsPixelGrid: false,
            showsCrosshair: false
        )

        let reloadedModel = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        XCTAssertEqual(reloadedModel.screenInspectorPreferences.zoomLevel, .sixteen)
        XCTAssertFalse(reloadedModel.screenInspectorPreferences.showsPixelGrid)
        XCTAssertFalse(reloadedModel.screenInspectorPreferences.showsCrosshair)
    }

    func testResetPreferencesRestoresScreenInspectorDefaults() {
        let suiteName = "AppModelTests.resetPreferencesRestoresScreenInspectorDefaults"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = retainForTestLifetime(
            AppModel(
                defaults: defaults,
                recoveryStore: DocumentRecoveryStore(baseURL: nil),
                shouldCheckCompatibilityOnLaunch: false,
                shouldStartArchiveMaintenance: false
            )
        )
        model.screenInspectorPreferences = ScreenInspectorPreferences(
            zoomLevel: .two,
            showsPixelGrid: true,
            showsCrosshair: true
        )

        model.resetPreferencesToDefaults()

        XCTAssertEqual(model.screenInspectorPreferences, .default)
        XCTAssertFalse(model.screenInspectorPreferences.showsPixelGrid)
        XCTAssertFalse(model.screenInspectorPreferences.showsCrosshair)
    }

    func testRefreshPermissionsClearsReadyWhenShareableContentProbeFails() async {
        let suiteName = "AppModelTests.refreshPermissionsClearsReadyWhenShareableContentProbeFails"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let originalScreenRecordingStatusProvider = ScreenCapturePermissions.screenRecordingStatusProvider
        let originalAccessibilityStatusProvider = ScreenCapturePermissions.accessibilityStatusProvider
        let originalScreenRecordingAccessVerifier = ScreenCapturePermissions.screenRecordingAccessVerifier
        defer {
            ScreenCapturePermissions.screenRecordingStatusProvider = originalScreenRecordingStatusProvider
            ScreenCapturePermissions.accessibilityStatusProvider = originalAccessibilityStatusProvider
            ScreenCapturePermissions.screenRecordingAccessVerifier = originalScreenRecordingAccessVerifier
        }

        ScreenCapturePermissions.screenRecordingStatusProvider = { true }
        ScreenCapturePermissions.accessibilityStatusProvider = { false }
        ScreenCapturePermissions.screenRecordingAccessVerifier = { false }

        let model = retainForTestLifetime(
            AppModel(
                defaults: defaults,
                recoveryStore: DocumentRecoveryStore(baseURL: nil),
                captureService: ScreenCaptureService(),
                shouldCheckCompatibilityOnLaunch: false,
                shouldStartArchiveMaintenance: false
            )
        )
        model.permissionStatus = CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false)

        model.refreshPermissions()

        await waitUntil {
            model.permissionStatus == CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false)
        }

        XCTAssertFalse(model.permissionStatus.isCaptureReady(for: .release))
        XCTAssertEqual(model.permissionStatus.missingRequirements(for: .release), [.screenRecording])
    }

    func testPresentPermissionDeniedClearsScreenRecordingAccessImmediately() {
        let suiteName = "AppModelTests.presentPermissionDeniedClearsScreenRecordingAccessImmediately"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let originalScreenRecordingStatusProvider = ScreenCapturePermissions.screenRecordingStatusProvider
        let originalAccessibilityStatusProvider = ScreenCapturePermissions.accessibilityStatusProvider
        defer {
            ScreenCapturePermissions.screenRecordingStatusProvider = originalScreenRecordingStatusProvider
            ScreenCapturePermissions.accessibilityStatusProvider = originalAccessibilityStatusProvider
        }

        ScreenCapturePermissions.screenRecordingStatusProvider = { true }
        ScreenCapturePermissions.accessibilityStatusProvider = { false }

        let model = retainForTestLifetime(
            AppModel(
                defaults: defaults,
                recoveryStore: DocumentRecoveryStore(baseURL: nil),
                captureService: ScreenCaptureService(),
                shouldCheckCompatibilityOnLaunch: false,
                shouldStartArchiveMaintenance: false
            )
        )
        model.permissionStatus = CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false)

        model.present(ScreenCaptureError.permissionDenied)

        XCTAssertEqual(
            model.permissionStatus,
            CapturePermissionStatus(hasScreenRecording: false, hasAccessibility: false)
        )
        XCTAssertEqual(model.errorMessage, ScreenCaptureError.permissionDenied.errorDescription)
    }

    func testEditorCropOutsideOverlayDimmingDescriptionUsesCurrentAlpha() {
        let suiteName = "AppModelTests.editorCropOutsideOverlayDimmingDescription"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        model.updateEditorCropOutsideOverlayAlpha(0.32)

        XCTAssertEqual(model.editorCropOutsideOverlayAlpha, 0.32, accuracy: 0.001)
        XCTAssertEqual(model.editorCropOutsideOverlayDimmingDescription, "32% dimming")
    }

    func testDocumentHistoryEntryHistorySummarySkipsGenericCaptureLabels() {
        let entry = makeHistoryEntry(searchableText: "Display 1\nProfile settings")

        XCTAssertEqual(entry.historySummary, "Profile settings")
    }

    func testDocumentHistoryEntryHistorySummaryFallsBackToLabel() {
        let entry = makeHistoryEntry(searchableText: "Display 1\nCapture")

        XCTAssertEqual(entry.historySummary, "Capture")
    }

    func testSaveCheckpointPersistsArrowLabelChangeSummary() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let capture = makeCapturedScreenshot(sourceName: "Built-in Retina Display")
        let originalSnapshot = makeEditorSnapshot(
            cropRect: CGRect(origin: .zero, size: CGSize(width: capture.image.width, height: capture.image.height))
        )
        let arrow = Annotation.makeArrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 80, y: 60)).updatingArrow(label: "API key")
        let updatedSnapshot = makeEditorSnapshot(
            cropRect: originalSnapshot.cropRect,
            annotations: [arrow]
        )
        let session = makeEditorDocumentSession(
            initialSnapshot: originalSnapshot,
            currentSnapshot: updatedSnapshot,
            undoStack: [originalSnapshot]
        )
        let document = makeEditableDocument(capture: capture, session: session)
        let sessionID = try store.createSession(title: "Summary.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Summary.sss",
            sourceDocumentURL: nil,
            label: "Autosave",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let entry = try XCTUnwrap(store.historyEntries(for: sessionID).first)
        XCTAssertEqual(entry.changeSummary, "Arrow label: API key")
        XCTAssertEqual(entry.historySummary, "Arrow label: API key")
    }

    func testResetPreferencesToDefaultsRestoresDefaultCropOutsideDimming() {
        let suiteName = "AppModelTests.resetPreferencesToDefaults"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        model.updateEditorCropOutsideOverlayAlpha(0.72)
        model.screenshotIncludesCursor = true
        XCTAssertEqual(model.editorCropOutsideOverlayAlpha, 0.72, accuracy: 0.001)

        model.resetPreferencesToDefaults()

        XCTAssertEqual(model.editorCropOutsideOverlayAlpha, AppModel.defaultEditorCropOutsideOverlayAlpha, accuracy: 0.001)
        XCTAssertEqual(model.editorCropOutsideOverlayDimmingDescription, "80% dimming")
        XCTAssertEqual(model.editorOutOfCapturePatternSettings, .default)
        XCTAssertFalse(model.screenshotIncludesCursor)
    }

    func testUIMapPinnedOverlayDefaultsPersistAndApplyToNewEditorControllers() throws {
        let suiteName = "AppModelTests.uiMapPinnedOverlayDefaults"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuredOptions = UIMapOverlayOptions(
            showsOutline: true,
            showsLabel: true,
            showsIdentifier: true,
            showsRole: false,
            showsCoordinates: true,
            showsDimensions: false
        )
        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        model.uiMapPinnedOverlayDefaults = configuredOptions

        let reloaded = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        XCTAssertEqual(reloaded.uiMapPinnedOverlayDefaults, configuredOptions)

        try reloaded.completeCapture(
            makeCapturedScreenshot(),
            request: .region(.zero),
            isPrivateCapture: true,
            shouldAttemptUIMapCapture: false
        )

        XCTAssertEqual(reloaded.editorController?.uiMapOverlayOptions, configuredOptions)

        reloaded.resetPreferencesToDefaults()

        XCTAssertEqual(reloaded.uiMapPinnedOverlayDefaults, UIMapOverlayOptions())
    }

    func testFreshInstallRequestsOnboardingPresentationOnce() {
        let suiteName = "AppModelTests.freshInstallOnboarding"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        XCTAssertTrue(model.consumeOnboardingWindowPresentationFlag())
        XCTAssertFalse(model.consumeOnboardingWindowPresentationFlag())
    }

    func testCompleteOnboardingSuppressesFutureInitialPresentation() {
        let suiteName = "AppModelTests.completeOnboarding"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        _ = model.consumeOnboardingWindowPresentationFlag()
        model.completeOnboarding()

        let reloadedModel = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        XCTAssertFalse(reloadedModel.consumeOnboardingWindowPresentationFlag())
    }

    func testLegacyWelcomePreferencesSuppressOnboardingMigration() {
        let suiteName = "AppModelTests.legacyWelcomeMigration"
        let defaults = makeDefaults(named: suiteName)
        defaults.set(true, forKey: AppModelPreferenceKey.hasPresentedWelcomeWindow)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        XCTAssertFalse(model.consumeOnboardingWindowPresentationFlag())
    }

    func testResetPreferencesToDefaultsPreservesCompletedOnboardingVersion() {
        let suiteName = "AppModelTests.resetDefaultsKeepsOnboarding"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        _ = model.consumeOnboardingWindowPresentationFlag()
        model.completeOnboarding()
        model.resetPreferencesToDefaults()

        let reloadedModel = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        XCTAssertFalse(reloadedModel.consumeOnboardingWindowPresentationFlag())
    }

    func testEditorOutOfCapturePatternSettingsPersistAndClamp() {
        let suiteName = "AppModelTests.editorOutOfCapturePatternSettings"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        model.updateEditorOutOfCapturePatternSettings(
            EditorOutOfCapturePatternSettings(
                isEnabled: false,
                spacing: 4,
                lineOpacity: 1.5,
                dotOpacity: 0,
                dotDiameter: 30
            )
        )

        XCTAssertFalse(model.editorOutOfCapturePatternSettings.isEnabled)
        XCTAssertEqual(model.editorOutOfCapturePatternSettings.spacing, 16, accuracy: 0.001)
        XCTAssertEqual(model.editorOutOfCapturePatternSettings.lineOpacity, 0.9, accuracy: 0.001)
        XCTAssertEqual(model.editorOutOfCapturePatternSettings.dotOpacity, 0.05, accuracy: 0.001)
        XCTAssertEqual(model.editorOutOfCapturePatternSettings.dotDiameter, 12, accuracy: 0.001)

        let reloadedModel = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        XCTAssertEqual(reloadedModel.editorOutOfCapturePatternSettings, model.editorOutOfCapturePatternSettings)
    }

    func testAutomationPreferencesPersistCustomHotkeys() {
        let suiteName = "AppModelTests.automationPreferencesHotkeys"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        model.automationPreferences = CaptureAutomationPreferences(
            globalHotkeysEnabled: true,
            regionHotkey: .five,
            windowHotkey: .six,
            fullscreenHotkey: .seven,
            frontmostWindowHotkey: .eight,
            repeatLastCaptureHotkey: .t,
            screenInspectorHotkey: .f
        )

        let reloadedModel = AppModel(
            defaults: defaults,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )

        XCTAssertEqual(reloadedModel.automationPreferences.regionHotkey, .five)
        XCTAssertEqual(reloadedModel.automationPreferences.windowHotkey, .six)
        XCTAssertEqual(reloadedModel.automationPreferences.fullscreenHotkey, .seven)
        XCTAssertEqual(reloadedModel.automationPreferences.frontmostWindowHotkey, .eight)
        XCTAssertEqual(reloadedModel.automationPreferences.repeatLastCaptureHotkey, .t)
        XCTAssertEqual(reloadedModel.automationPreferences.screenInspectorHotkey, .f)
    }

    func testInitialCaptureHistoryIndexImageUsesFullCaptureImage() {
        let model = AppModel(
            defaults: UserDefaults(suiteName: #function)!,
            recoveryStore: DocumentRecoveryStore(baseURL: nil),
            captureService: ScreenCaptureService(),
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        let image = makeCoordinateImage(width: 80, height: 240)
        let capture = CapturedScreenshot(
            image: image,
            kind: .scrolling,
            sourceName: "Scrolling Capture",
            sourceRect: CGRect(x: 10, y: 20, width: 80, height: 60),
            capturedAt: Date()
        )
        let session = EditorDocumentSession(
            initialSnapshot: EditorSnapshot(
                cropRect: CGRect(x: 0, y: 40, width: 80, height: 120),
                annotations: [],
                selectedAnnotationIDs: [],
                nextCalloutNumber: 1
            ),
            currentSnapshot: EditorSnapshot(
                cropRect: CGRect(x: 0, y: 40, width: 80, height: 120),
                annotations: [],
                selectedAnnotationIDs: [],
                nextCalloutNumber: 1
            ),
            undoStack: [],
            redoStack: [],
            toolStyles: Dictionary(uniqueKeysWithValues: EditorTool.allCases.map { ($0, AnnotationStyle.default(for: $0)) })
        )
        let controller = EditorController(capture: capture, session: session)

        let indexedImage = model.initialCaptureHistoryIndexImage(for: controller)

        XCTAssertEqual(indexedImage.width, image.width)
        XCTAssertEqual(indexedImage.height, image.height)
    }

    func testClearingCaptureHistorySearchRestoresRecentEntries() async throws {
        let suiteName = "AppModelTests.clearingCaptureHistorySearchRestoresRecentEntries"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeEditableDocument()
        let sessionID = try store.createSession(title: "Searchable.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Searchable.sss",
            sourceDocumentURL: nil,
            label: "Capture",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let model = retainForTestLifetime(
            AppModel(
                defaults: defaults,
                recoveryStore: store,
                captureService: ScreenCaptureService(),
                shouldCheckCompatibilityOnLaunch: false,
                shouldStartArchiveMaintenance: false
            )
        )

        XCTAssertEqual(model.allCaptureHistoryEntries.count, 1)

        model.captureSearchQuery = "missing"
        await waitUntil {
            model.allCaptureHistoryEntries.isEmpty
        }

        XCTAssertTrue(model.allCaptureHistoryEntries.isEmpty)

        model.captureSearchQuery = ""

        XCTAssertEqual(model.allCaptureHistoryEntries.count, 1)
        XCTAssertEqual(model.allCaptureHistoryEntries.first?.sessionID, sessionID)
    }

    func testInitTrashesIncompatibleRecoveryEntriesWhenConfirmed() throws {
        let suiteName = "AppModelTests.initTrashesIncompatibleRecoveryEntriesWhenConfirmed"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeEditableDocument()
        let sessionID = try store.createSession(title: "Legacy.sss", sourceDocumentURL: nil)

        try store.saveCheckpoint(
            sessionID: sessionID,
            title: "Legacy.sss",
            sourceDocumentURL: nil,
            label: "Capture",
            document: document,
            previewImage: document.capture.image,
            pendingRecovery: true,
            hasUnsavedChanges: true
        )

        let entry = try XCTUnwrap(store.historyEntries(for: sessionID).first)
        try writeScreenshotPackageManifestVersion(5, at: entry.packageURL)

        var trashedURLs: [URL] = []
        let coordinator = IncompatibleDocumentCoordinator(
            confirmationHandler: { _ in true },
            trashHandler: { urls in trashedURLs = urls },
            cancellationNoticeHandler: { _ in XCTFail("Did not expect cancellation notice") },
            terminationHandler: { XCTFail("Did not expect termination") }
        )

        let model = retainForTestLifetime(
            AppModel(
                defaults: defaults,
                recoveryStore: store,
                captureService: ScreenCaptureService(),
                incompatibleDocumentCoordinator: coordinator,
                shouldCheckCompatibilityOnLaunch: true,
                shouldStartArchiveMaintenance: false
            )
        )

        XCTAssertEqual(trashedURLs, [entry.packageURL])
        XCTAssertTrue(model.allCaptureHistoryEntries.isEmpty)
        XCTAssertNil(model.pendingRecoverySession)
    }

    func testLoadDocumentCancelsAndTerminatesForIncompatiblePackage() throws {
        let suiteName = "AppModelTests.loadDocumentCancelsAndTerminatesForIncompatiblePackage"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let document = makeEditableDocument()
        try SSSDocumentPackage.save(document: document, previewImage: document.capture.image, to: packageURL)
        try writeScreenshotPackageManifestVersion(5, at: packageURL)

        var didTerminate = false
        let coordinator = IncompatibleDocumentCoordinator(
            confirmationHandler: { _ in false },
            trashHandler: { _ in XCTFail("Did not expect trash on cancellation") },
            cancellationNoticeHandler: { _ in },
            terminationHandler: { didTerminate = true }
        )

        let model = retainForTestLifetime(
            AppModel(
                defaults: defaults,
                recoveryStore: DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)),
                captureService: ScreenCaptureService(),
                incompatibleDocumentCoordinator: coordinator,
                shouldCheckCompatibilityOnLaunch: false,
                shouldStartArchiveMaintenance: false
            )
        )

        model.loadDocument(from: packageURL)

        XCTAssertTrue(didTerminate)
        XCTAssertNil(model.editorController)
    }
}

nonisolated private final class WindowRefreshCaptureService: ScreenCaptureServiceType, @unchecked Sendable {
    private let recorder = WindowRefreshRequestRecorder()
    private let thumbnailDelayNanoseconds: UInt64

    init(thumbnailDelayNanoseconds: UInt64 = 150_000_000) {
        self.thumbnailDelayNanoseconds = thumbnailDelayNanoseconds
    }

    func includeThumbnailRequests() async -> [Bool] {
        await recorder.requests()
    }

    func listWindows(excluding processID: pid_t, includeThumbnails: Bool) async throws -> [CaptureWindowSummary] {
        await recorder.append(includeThumbnails)

        if includeThumbnails {
            try? await Task.sleep(nanoseconds: thumbnailDelayNanoseconds)
        }

        return [
            makeCaptureWindow(
                id: 1,
                thumbnailSize: includeThumbnails ? CGSize(width: 20, height: 20) : nil,
                thumbnailColor: PixelSample(red: 80, green: 120, blue: 180, alpha: 255)
            )
        ]
    }

    func frontmostWindow(excluding processID: pid_t) async throws -> CaptureWindowSummary {
        makeCaptureWindow(id: 1)
    }

    func resolveWindowTarget(_ window: CaptureWindowSummary, excluding processID: pid_t) async throws -> CaptureWindowSummary {
        window
    }

    func captureCurrentDisplay() async throws -> CapturedScreenshot {
        makeCapturedScreenshot(kind: .fullscreen)
    }

    func captureDesktopOverlaySnapshot() async throws -> DesktopCompositeSnapshot {
        throw ScreenCaptureError.noDisplays
    }

    func captureRegion(from snapshot: DesktopCompositeSnapshot, selection: CGRect) async throws -> CapturedScreenshot {
        throw ScreenCaptureError.invalidRegion
    }

    func captureRegion(in selection: CGRect) async throws -> CapturedScreenshot {
        throw ScreenCaptureError.invalidRegion
    }

    func captureRegionDirect(in selection: CGRect) async throws -> CapturedScreenshot {
        throw ScreenCaptureError.invalidRegion
    }

    func captureWindow(_ window: CaptureWindowSummary) async throws -> CapturedScreenshot {
        makeCapturedScreenshot(
            kind: .window,
            sourceName: window.displayTitle,
            sourceRect: window.frame,
            sourceWindowIdentity: CaptureSourceWindowIdentity(window: window)
        )
    }
}

private actor WindowRefreshRequestRecorder {
    private var values: [Bool] = []

    func append(_ value: Bool) {
        values.append(value)
    }

    func requests() -> [Bool] {
        values
    }
}

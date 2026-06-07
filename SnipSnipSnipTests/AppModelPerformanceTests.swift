import XCTest
@testable import SnipSnipSnip

@MainActor
final class AppModelPerformanceTests: XCTestCase {
    private final class VisibilityTrackingWindow: NSWindow {
        var trackedIsVisible = true

        override var isVisible: Bool { trackedIsVisible }

        override func orderFront(_ sender: Any?) {
            trackedIsVisible = true
            super.orderFront(sender)
        }

        override func orderOut(_ sender: Any?) {
            trackedIsVisible = false
            super.orderOut(sender)
        }

        override func makeKeyAndOrderFront(_ sender: Any?) {
            trackedIsVisible = true
            super.makeKeyAndOrderFront(sender)
        }
    }

    func testInteractiveCaptureSuspensionCancelsAndReschedulesAutosave() {
        let model = makeModel()
        Self.retainedModels.append(model)
        let controller = EditorController(capture: makeCapturedScreenshot())
        model.editorController = controller

        model.scheduleAutosave(for: controller)
        XCTAssertNotNil(model.pendingAutosaveTask)

        let suspension = model.suspendEditorAutosaveForInteractiveCapture()
        XCTAssertNil(model.pendingAutosaveTask)

        model.resumeEditorAutosaveAfterInteractiveCapture(suspension)
        XCTAssertNotNil(model.pendingAutosaveTask)

        model.pendingAutosaveTask?.cancel()
        model.pendingAutosaveTask = nil
        model.editorController = nil
    }

    func testHideAndRestoreAppWindowRoundTripsVisibleMainWindow() {
        let model = makeModel()
        Self.retainedModels.append(model)
        let window = retainForTestLifetime(VisibilityTrackingWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        ))
        window.identifier = NSUserInterfaceItemIdentifier(AppSceneID.mainWindow)
        window.trackedIsVisible = true

        XCTAssertTrue(window.isVisible)

        let hiddenWindow = model.hideAppWindowIfNeeded(in: [window])
        XCTAssertTrue(hiddenWindow === window)
        XCTAssertFalse(window.isVisible)

        model.restoreAppWindowIfNeeded(hiddenWindow)
        XCTAssertTrue(window.isVisible)

        window.orderOut(nil)
    }

    private static var retainedModels: [AppModel] = []

    private struct MockScreenCaptureService: ScreenCaptureServiceType {
        func listWindows(excluding processID: pid_t = ProcessInfo.processInfo.processIdentifier, includeThumbnails: Bool = true) async throws -> [CaptureWindowSummary] {
            let windowCount = 6
            return (0..<windowCount).map { index in
                makeCaptureWindow(
                    id: CGWindowID(index + 1),
                    ownerPID: pid_t(index + 1),
                    ownerName: "App \(index + 1)",
                    title: "Window \(index + 1)",
                    focusRank: index,
                    frame: CGRect(x: 20 + (index * 20), y: 20, width: 240, height: 180)
                )
            }
        }

        func frontmostWindow(excluding processID: pid_t = ProcessInfo.processInfo.processIdentifier) async throws -> CaptureWindowSummary {
            let windows = try await listWindows(excluding: processID, includeThumbnails: false)
            guard let frontmost = windows.first else {
                throw ScreenCaptureError.noWindowsAvailable
            }

            return frontmost
        }

        func resolveWindowTarget(_ window: CaptureWindowSummary, excluding processID: pid_t = ProcessInfo.processInfo.processIdentifier) async throws -> CaptureWindowSummary {
            window
        }

        func captureCurrentDisplay() async throws -> CapturedScreenshot {
            makeCapturedScreenshot(kind: .fullscreen, sourceName: "Display", sourceRect: CGRect(x: 0, y: 0, width: 640, height: 480))
        }

        func captureDesktopOverlaySnapshot() async throws -> DesktopCompositeSnapshot {
            let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
            let display = DisplaySnapshot(displayID: 1, name: "Mock Display", frame: frame, overlayFrame: frame, scale: 1)
            let preview = DisplayPreview(snapshot: display, image: makeCoordinateImage(width: Int(frame.width), height: Int(frame.height)))
            return DesktopCompositeSnapshot(previewImage: nil, globalFrame: frame, displays: [display], displayPreviews: [preview])
        }

        func captureRegion(from snapshot: DesktopCompositeSnapshot, selection: CGRect) async throws -> CapturedScreenshot {
            let region = selection.standardized.integral
            let image = makeCoordinateImage(width: max(1, Int(region.width)), height: max(1, Int(region.height)))
            return CapturedScreenshot(
                image: image,
                kind: .region,
                sourceName: "Region",
                sourceRect: region,
                capturedAt: Date()
            )
        }

        func captureRegion(in selection: CGRect) async throws -> CapturedScreenshot {
            let snapshot = try await captureDesktopOverlaySnapshot()
            return try await captureRegion(from: snapshot, selection: selection)
        }

        func captureRegionDirect(in selection: CGRect) async throws -> CapturedScreenshot {
            makeCapturedScreenshot(kind: .region, sourceName: "Region", sourceRect: selection.standardized.integral)
        }

        func captureWindow(_ window: CaptureWindowSummary) async throws -> CapturedScreenshot {
            makeCapturedScreenshot(kind: .window, sourceName: window.displayTitle, sourceRect: window.frame)
        }
    }

    private func makeModel() -> AppModel {
        let suiteName = "AppModelPerformanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let recoveryStore = DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let model = AppModel(defaults: defaults, recoveryStore: recoveryStore, captureService: MockScreenCaptureService(), shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
        model.permissionStatus = CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true)
        model.captureDelay = .immediate
        model.autoCopyEnabled = false
        return model
    }

    private func waitForCapture(
        on model: AppModel,
        request: LastCaptureRequest,
        minimizeAppWindow: Bool = false,
        action: @escaping @Sendable () async throws -> CapturedScreenshot
    ) {
        let expectation = expectation(description: "capture completed")

        Task.detached {
            await model.performCapture(request: request, minimizeAppWindow: minimizeAppWindow, action)
            await model.waitForPendingRecoveryWriteTasks()
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    private func waitForWindowPickerLoad(on model: AppModel, includeThumbnails: Bool) {
        let expectation = expectation(description: "window picker loaded")

        Task.detached {
            await model.loadAvailableWindows(requestAccessIfNeeded: false, presentPicker: false, showErrors: false, includeThumbnails: includeThumbnails)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testCaptureEntryPointPerformance() async {
        let model = makeModel()
        Self.retainedModels.append(model)

        let elapsed = await PerformanceBudgetTimer.measure {
            await model.performCapture(request: .fullscreen, minimizeAppWindow: false) {
                try await model.captureService.captureCurrentDisplay()
            }
            await model.waitForPendingRecoveryWriteTasks()
        }

        XCTAssertTrue(
            PerformanceBudgetCatalog.captureEntryPoint.contains(elapsed),
            "Capture entry point took \(elapsed)s, over \(PerformanceBudgetCatalog.captureEntryPoint.maximumSeconds)s"
        )
    }

    func testWindowPickerPerformance() {
        let model = makeModel()
        Self.retainedModels.append(model)

        let options = XCTMeasureOptions.default
        options.iterationCount = 8

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            waitForWindowPickerLoad(on: model, includeThumbnails: false)
        }
    }

    func testEditorInspectorStylePerformance() {
        let controller = EditorController(capture: makeCapturedScreenshot())
        let rectangle = Annotation.makeRectangle(in: CGRect(x: 12, y: 10, width: 120, height: 80))
        let text = Annotation.makeText(at: CGPoint(x: 18, y: 110))
        let callout = Annotation.makeCallout(at: CGPoint(x: 12, y: 220), number: 1)
        let arrow = Annotation.makeArrow(from: CGPoint(x: 20, y: 330), to: CGPoint(x: 140, y: 380))
        let redaction = Annotation.makeSolidRedaction(in: CGRect(x: 32, y: 420, width: 120, height: 56))

        controller.addAnnotation(rectangle)
        controller.addAnnotation(text)
        controller.addAnnotation(callout)
        controller.addAnnotation(arrow)
        controller.addAnnotation(redaction)

        let options = XCTMeasureOptions.default
        options.iterationCount = 12

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            controller.select(annotationIDs: [rectangle.id])
            controller.updateStrokeColor(RGBAColor(red: 1, green: 0.2, blue: 0.1, alpha: 1))
            controller.updateFillColor(RGBAColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 0.35))
            controller.updateLineWidth(6)
            controller.updateFontSize(18)
            controller.updateEffectRadius(8)
            controller.updateCornerRadius(10)
            controller.updateDashStyle(.dashed)

            controller.select(annotationIDs: [text.id])
            controller.updateText("Performance test")
            controller.updateTextAlignment(.center)

            controller.select(annotationIDs: [callout.id])
            controller.updateCalloutStyle(.outlined)

            controller.select(annotationIDs: [arrow.id])
            controller.updateArrowLabel("Go")
            controller.updateArrowHeadShape(.open)

            controller.select(annotationIDs: [redaction.id])
            controller.updateRedactionMode(.pixelate)

            controller.activateToolbarTool(.highlight)
            controller.cancelImageColorSampling()
        }
    }

    func testPerformanceBudgetCatalogCoversMajorScalablePaths() {
        XCTAssertGreaterThan(PerformanceBudgetCatalog.captureEntryPoint.maximumSeconds, 0)
        XCTAssertGreaterThan(PerformanceBudgetCatalog.screenshotRenderAndExport.maximumSeconds, 0)
        XCTAssertGreaterThan(PerformanceBudgetCatalog.archiveIndexedSearch.maximumSeconds, 0)
        XCTAssertGreaterThan(PerformanceBudgetCatalog.videoExportPlanning.maximumSeconds, 0)
        XCTAssertGreaterThan(PerformanceBudgetCatalog.videoStoragePressureCheck.maximumSeconds, 0)
    }

    func testScreenshotRenderAndStreamingExportBudget() async throws {
        let image = makeCoordinateImage(width: 960, height: 540, pattern: .weighted(xMultiplier: 5, yMultiplier: 11, includeBlueSum: true))
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 960, height: 540),
            annotations: [
                Annotation.makeRectangle(in: CGRect(x: 40, y: 40, width: 320, height: 180)),
                Annotation.makeArrow(from: CGPoint(x: 80, y: 280), to: CGPoint(x: 520, y: 320)),
                Annotation.makeText(at: CGPoint(x: 120, y: 360)).updatingText("Export budget"),
                Annotation.makeSolidRedaction(in: CGRect(x: 600, y: 120, width: 180, height: 80))
            ]
        )
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let elapsed = try await PerformanceBudgetTimer.measure {
            guard let rendered = EditorRenderer.render(baseImage: image, snapshot: snapshot) else {
                throw ImageExportError.encodingFailed
            }

            try await ImageExporter.write(rendered, format: .png, to: outputURL)
        }

        XCTAssertTrue(
            PerformanceBudgetCatalog.screenshotRenderAndExport.contains(elapsed),
            "Screenshot render/export took \(elapsed)s, over \(PerformanceBudgetCatalog.screenshotRenderAndExport.maximumSeconds)s"
        )
    }

    func testArchiveIndexedSearchBudget() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = retainForTestLifetime(DocumentRecoveryStore(baseURL: rootURL))
        let document = makeEditableDocument()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for index in 0..<32 {
            let sessionID = try store.createSession(title: "Archive Search \(index).sss", sourceDocumentURL: nil)
            try store.saveCheckpoint(
                sessionID: sessionID,
                title: "Archive Search \(index).sss",
                sourceDocumentURL: nil,
                label: index.isMultiple(of: 2) ? "Needle Capture" : "Capture",
                document: document,
                previewImage: document.capture.image,
                pendingRecovery: true,
                hasUnsavedChanges: true
            )
        }

        let elapsed = PerformanceBudgetTimer.measure {
            let matches = store.searchHistoryEntries(matching: "needle", limit: 50)
            XCTAssertEqual(matches.count, 16)
        }

        XCTAssertTrue(
            PerformanceBudgetCatalog.archiveIndexedSearch.contains(elapsed),
            "Archive indexed search took \(elapsed)s, over \(PerformanceBudgetCatalog.archiveIndexedSearch.maximumSeconds)s"
        )
    }

    func testVideoExportPlanningAndStorageBudget() throws {
        let preferences = VideoRecordingPreferences(quality: .high, frameRate: .sixty)
        let elapsed = try PerformanceBudgetTimer.measure {
            for _ in 0..<100 {
                _ = try VideoExporter.sizeConstrainedPlan(
                    duration: 45,
                    maximumBytes: VideoExportSizeLimit.under100MB.maximumBytes,
                    hasAudio: true,
                    attemptIndex: 0
                )
                _ = VideoStorageGuardrails.liveRecordingHeadroomBytes(
                    width: 3840,
                    height: 2160,
                    preferences: preferences
                )
            }
        }

        XCTAssertTrue(
            PerformanceBudgetCatalog.videoExportPlanning.contains(elapsed),
            "Video export planning/storage budgeting took \(elapsed)s, over \(PerformanceBudgetCatalog.videoExportPlanning.maximumSeconds)s"
        )
    }
}

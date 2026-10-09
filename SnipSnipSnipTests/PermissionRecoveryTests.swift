import AppKit
import SwiftUI
import XCTest
@testable import SnipSnipSnip

@MainActor
final class PermissionRecoveryTests: XCTestCase {
    func testMediaSetupRequestsOnlyUndeterminedAccessAndDoesNotOpenSettingsAfterDenial() async {
        let media = TestMediaPermissionService()
        let model = makePermissions(media: media)
        model.setUpMediaPermission(.microphone)
        for _ in 0..<100 where model.activeMediaPermissionRequest != nil { await Task.yield() }
        XCTAssertEqual(media.requests, [.microphone])
        XCTAssertEqual(model.mediaPermissionStatuses[.microphone], .denied)
        XCTAssertTrue(media.settings.isEmpty)
        model.setUpMediaPermission(.microphone)
        XCTAssertEqual(media.requests, [.microphone])
        XCTAssertEqual(media.settings, [.microphone])
    }

    func testAppStorePermissionOverviewCannotRequestCamera() {
        let media = TestMediaPermissionService()
        let model = makePermissions(media: media, capabilities: BuildTargetCapabilityProvider().snapshot(for: .release))
        model.refreshPermissions()
        model.setUpMediaPermission(.camera)
        model.openMediaPermissionSettings(.camera)
        XCTAssertEqual(model.availableMediaPermissions, [.microphone])
        XCTAssertNil(model.mediaPermissionStatuses[.camera])
        XCTAssertTrue(media.requests.isEmpty)
        XCTAssertTrue(media.settings.isEmpty)
    }

    func testPermissionRecoveryRemainsAccessibleAtCompactWidth() async throws {
        let model = makePermissions(media: TestMediaPermissionService(), status: CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: false))
        model.requestPermission(.accessibility)
        var guide = try XCTUnwrap(model.permissionSetupGuide)
        guide.featureName = "Scrolling Capture"
        for (name, appearance) in [("Light", NSAppearance.Name.aqua), ("Dark", NSAppearance.Name.darkAqua)] {
            let view = NSHostingView(rootView: PermissionSetupView(permissions: model, guide: guide)
                .frame(width: 460, height: 310, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)))
            view.sizingOptions = []
            let window = HostedViewTestSupport.host(view, size: CGSize(width: 460, height: 310))
            window.appearance = NSAppearance(named: appearance)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.bounds.width, 460, accuracy: 0.5)
            XCTAssertEqual(view.bounds.height, 310, accuracy: 0.5)
            for id in ["permissions.setup.openSettings", "permissions.setup.checkAgain", "permissions.setup.cancel"] {
                let element = try XCTUnwrap(HostedViewTestSupport.find(id, in: view))
                XCTAssertTrue(window.frame.contains(element.accessibilityFrame()), "\(id) must remain fully visible")
            }
            add(try HostedViewTestSupport.attachment(of: view, name: "Permission recovery — \(name)"))
        }
        model.dismissPermissionSetupGuide()
    }

    func testDeniedVideoNarrationRetriesVideoWithoutChangingPreferencesOrInvokingScreenshotRecovery() async throws {
        let name = "PermissionRecoveryTests.video.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let capture = PermissionTestVideoCapturePort()
        let platform = TestScreenRecordingPlatform(microphoneAccess: { throw ScreenRecordingError.microphonePermissionDenied })
        let video = makeVideo(defaults: defaults, platform: platform, capture: capture)
        video.recordingPreferences.recordsMicrophone = true
        var starts = 0
        var microphoneAtStart: Bool?
        video.reserveAndPrepareRecording { [weak video] generation in
            starts += 1
            microphoneAtStart = video?.currentRecordingPreferences.recordsMicrophone
            video?.recordingLifecycle.reset(generation: generation)
        }
        for _ in 0..<100 where video.recordingStartRecovery == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(try XCTUnwrap(video.recordingStartRecovery).needsMicrophoneAccess)
        XCTAssertEqual(capture.presentedErrors, 0)
        video.retryVideoStart(withoutMicrophone: true)
        for _ in 0..<100 where starts == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(microphoneAtStart, false)
        XCTAssertTrue(video.recordingPreferences.recordsMicrophone)
        XCTAssertEqual(capture.presentedErrors, 0)
        video.dismissVideoStartRecovery()
    }

    func testRestartCheckpointExpiresAndRejectsPrivateCaptureAndMalformedData() throws {
        let name = "PermissionRecoveryTests.checkpoint.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PermissionRestartStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_000)
        var options = CaptureOneShotOptions(captureDelay: .immediate, includesCursor: true, privateCapture: false, windowUIMapEnabled: false)
        store.save(.screenshot(.region, options), now: now)
        guard case .screenshot(.region, let saved) = store.load(now: now.addingTimeInterval(10)) else { return XCTFail("Expected fresh Region checkpoint") }
        XCTAssertEqual(saved, options)
        XCTAssertNil(store.load(now: now.addingTimeInterval(1_801)))
        XCTAssertNil(defaults.data(forKey: PermissionRestartStore.key))
        options.privateCapture = true
        store.save(.screenshot(.region, options), now: now)
        XCTAssertNil(store.load(now: now))
        defaults.set(Data("invalid".utf8), forKey: PermissionRestartStore.key)
        XCTAssertNil(store.load(now: now))
    }

    func testCancelledMicrophoneRequestCannotPresentRecoveryOverANewerAttempt() async throws {
        let name = "PermissionRecoveryTests.cancelledMicrophone.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let barrier = DeferredBoolVerifier()
        let platform = TestScreenRecordingPlatform(microphoneAccess: {
            _ = await barrier.value()
            throw ScreenRecordingError.microphonePermissionDenied
        })
        let video = makeVideo(defaults: defaults, platform: platform, capture: PermissionTestVideoCapturePort())
        video.recordingPreferences.recordsMicrophone = true
        video.reserveAndPrepareRecording { _ in XCTFail("Cancelled recording must not start") }
        await barrier.waitForRequest()
        video.cancelPendingVideoRecording()
        video.recordingPreferences.recordsMicrophone = false
        var starts = 0
        video.reserveAndPrepareRecording { [weak video] generation in
            starts += 1
            video?.recordingLifecycle.reset(generation: generation)
        }
        for _ in 0..<100 where starts == 0 { try await Task.sleep(for: .milliseconds(10)) }
        await barrier.resume(returning: false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(starts, 1)
        XCTAssertNil(video.recordingStartRecovery)
        video.dismissVideoStartRecovery()
    }

    func testDeniedConnectedDeviceRecordingRetriesRecordingInsteadOfScreenshot() async throws {
        let name = "PermissionRecoveryTests.connectedRecording.\(UUID())"
        let defaults = makeDefaults(named: name)
        let service = DeniedConnectedDeviceService()
        let model = AppModel(defaults: defaults,
            environment: AppEnvironment(defaults: defaults, buildTarget: .dev, permissions: TestCapturePermissionService()),
            recoveryStore: DocumentRecoveryStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent(name)),
            connectedDeviceCaptureService: service,
            shouldCheckCompatibilityOnLaunch: false, shouldStartArchiveMaintenance: false)
        defer {
            model.capture.dismissCaptureRecovery()
            defaults.removePersistentDomain(forName: name)
        }
        model.capture.recordConnectedDevice(ConnectedAppleDevice(id: "test-device", name: "Test iPad"))
        for _ in 0..<100 where model.capture.captureRecovery == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.capture.pendingConnectedDevicePreviewIntent, .recording)
        XCTAssertTrue(try XCTUnwrap(model.capture.captureRecovery).actions.contains(.openCameraSettings))
        model.capture.performCaptureRecovery(.retryLastCapture)
        for _ in 0..<100 where model.capture.captureRecovery == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.capture.pendingConnectedDevicePreviewIntent, .recording)
        let checks = await service.statusChecks
        XCTAssertEqual(checks, 2)
    }

    private func makeVideo(defaults: UserDefaults, platform: TestScreenRecordingPlatform, capture: PermissionTestVideoCapturePort) -> VideoWorkflowModel {
        VideoWorkflowModel(
            dependencies: VideoWorkflowDependencies(capabilities: testCapabilities,
                systemServices: AppSystemServices.live(permissions: TestCapturePermissionService()),
                appWindowPresenter: LiveAppWindowPresenter {}, permissions: makePermissions(media: TestMediaPermissionService()),
                lifecycle: TestWorkflowLifecyclePresenter(), capture: capture),
            recordingService: ScreenRecordingService(permissions: TestCapturePermissionService(), platform: platform),
            preferenceStore: VideoPreferenceStore(storage: defaults)
        )
    }

    private func makePermissions(media: TestMediaPermissionService, capabilities: AppCapabilitySnapshot = testCapabilities, status: CapturePermissionStatus = CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true)) -> PermissionWorkflowModel {
        PermissionWorkflowModel(dependencies: PermissionWorkflowDependencies(
            capabilities: capabilities, permissions: TestCapturePermissionService(status: status), scheduler: SystemScheduler(),
            lifecycle: TestWorkflowLifecyclePresenter(), mediaPermissions: media
        ))
    }
}

@MainActor
private final class TestMediaPermissionService: MediaPermissionServicing {
    var states: [MediaPermissionKind: MediaPermissionStatus] = [.microphone: .notRequested, .camera: .notRequested]
    var requests: [MediaPermissionKind] = []
    var settings: [MediaPermissionKind] = []
    func status(for kind: MediaPermissionKind) -> MediaPermissionStatus { states[kind] ?? .notRequested }
    func request(_ kind: MediaPermissionKind) async { requests.append(kind); states[kind] = .denied }
    func openSettings(for kind: MediaPermissionKind) { settings.append(kind) }
}

@MainActor
private final class PermissionTestVideoCapturePort: VideoCaptureWorkflowPort {
    var privateCaptureEnabled = false
    var availableWindows: [CaptureWindowSummary] = []
    var regionCapturePreferences = RegionCapturePreferences()
    var presentedErrors = 0
    func beginVideoWindowSelection() {}
    func dismissWindowPicker() {}
    func beginWindowPickerPresentation() {}
    func beginCapturePrivacyLock() -> Bool { false }
    func endCapturePrivacyLock() {}
    func desktopSnapshotForVideoSelection() async throws -> DesktopCompositeSnapshot { throw ScreenCaptureError.noDisplays }
    func videoWindowSelectionSnapshot() async throws -> (windows: [CaptureWindowSummary], snapshot: DesktopCompositeSnapshot) { throw ScreenCaptureError.noDisplays }
    func performVideoWork<Result>(message: String, _ operation: nonisolated(nonsending) () async throws -> Result) async rethrows -> Result { try await operation() }
    func present(_ error: Error) { presentedErrors += 1 }
}

private actor DeniedConnectedDeviceService: ConnectedDeviceCaptureServiceType {
    private(set) var statusChecks = 0
    func listDevices() async -> [ConnectedAppleDevice] { [] }
    func unavailableReason() async -> ConnectedDeviceCaptureError { .cameraPermissionDenied }
    func videoAuthorizationStatus() async -> ConnectedDeviceVideoAuthorizationStatus {
        statusChecks += 1
        return .denied
    }
    func makePreviewSession(for device: ConnectedAppleDevice, preferences: VideoRecordingPreferences) async throws -> ConnectedDevicePreviewSession {
        XCTFail("Denied Camera access must stop before preview or temporary-storage preparation")
        throw ConnectedDeviceCaptureError.cameraPermissionDenied
    }
}

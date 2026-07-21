import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

let testCapabilities = BuildTargetCapabilityProvider().snapshot(for: .dev)

nonisolated struct StaticAppCapabilityProvider: AppCapabilityProvider {
    let capabilitySnapshot: AppCapabilitySnapshot

    func snapshot(for target: BuildTarget) -> AppCapabilitySnapshot {
        capabilitySnapshot
    }
}

nonisolated struct TestCapturePermissionService: CapturePermissionServicing {
    var statusProvider: @Sendable () -> CapturePermissionStatus = {
        CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true)
    }
    var screenRecordingVerifier: @Sendable () async -> Bool = { true }
    var requestHandler: @Sendable (CapturePermissionRequirement) -> Bool = { _ in true }
    var settingsHandler: @Sendable (CapturePermissionRequirement) -> Void = { _ in }
    var canRequestHandler: @Sendable (CapturePermissionRequirement) -> Bool = { _ in true }
    var failureDetector: @Sendable (Error) -> Bool = { error in
        ScreenCapturePermissions.indicatesScreenRecordingPermissionFailure(error)
    }
    var appName = "SnipSnipSnip"
    var appPath = "/Applications/SnipSnipSnip.app"

    init(
        status: CapturePermissionStatus = CapturePermissionStatus(hasScreenRecording: true, hasAccessibility: true)
    ) {
        self.statusProvider = { status }
    }

    init(
        statusProvider: @escaping @Sendable () -> CapturePermissionStatus,
        screenRecordingVerifier: @escaping @Sendable () async -> Bool = { true },
        requestHandler: @escaping @Sendable (CapturePermissionRequirement) -> Bool = { _ in true },
        settingsHandler: @escaping @Sendable (CapturePermissionRequirement) -> Void = { _ in },
        canRequestHandler: @escaping @Sendable (CapturePermissionRequirement) -> Bool = { _ in true },
        failureDetector: @escaping @Sendable (Error) -> Bool = { error in
            ScreenCapturePermissions.indicatesScreenRecordingPermissionFailure(error)
        },
        appName: String = "SnipSnipSnip",
        appPath: String = "/Applications/SnipSnipSnip.app"
    ) {
        self.statusProvider = statusProvider
        self.screenRecordingVerifier = screenRecordingVerifier
        self.requestHandler = requestHandler
        self.settingsHandler = settingsHandler
        self.canRequestHandler = canRequestHandler
        self.failureDetector = failureDetector
        self.appName = appName
        self.appPath = appPath
    }

    var currentAppName: String { appName }
    var currentAppPath: String { appPath }

    func currentStatus() -> CapturePermissionStatus {
        statusProvider()
    }

    func availableSetupRequirements() -> [CapturePermissionRequirement] {
        CapturePermissionRequirement.availableCases(for: testCapabilities)
    }

    func canRequest(_ requirement: CapturePermissionRequirement) -> Bool {
        canRequestHandler(requirement)
    }

    @discardableResult
    func requestAccess(for requirement: CapturePermissionRequirement) -> Bool {
        requestHandler(requirement)
    }

    func verifyScreenRecordingAccess() async -> Bool {
        await screenRecordingVerifier()
    }

    func openSystemSettings(for requirement: CapturePermissionRequirement) {
        settingsHandler(requirement)
    }

    func revealCurrentAppInFinder() {}

    func copyCurrentAppPathToPasteboard() {}

    func indicatesScreenRecordingPermissionFailure(_ error: Error) -> Bool {
        failureDetector(error)
    }
}

nonisolated struct TestWorkspaceService: WorkspaceServicing {
    var frontmostApplicationProcessIdentifier: pid_t?
    var frontmostApplication: WorkspaceRunningApplicationSnapshot?
    var runningApplications: [WorkspaceRunningApplicationSnapshot] = []
    var applicationURLsByBundleIdentifier: [String: URL] = [:]
    var openedURLs: @Sendable (URL) -> Void = { _ in }
    var revealedURLs: @Sendable ([URL]) -> Void = { _ in }

    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        applicationURLsByBundleIdentifier[bundleIdentifier]
    }

    func open(_ url: URL) {
        openedURLs(url)
    }

    @discardableResult
    func activateApplication(processIdentifier: pid_t) -> Bool { true }

    func activateFileViewerSelecting(_ urls: [URL]) {
        revealedURLs(urls)
    }
}

nonisolated struct TestMouseLocationService: MouseLocationProviding {
    var appKitGlobalLocation: CGPoint = .zero
}

nonisolated struct TestApplicationWindowFocusService: ApplicationWindowFocusProviding {
    var displayID: CGDirectDisplayID?

    func preferredDisplayID() async -> CGDirectDisplayID? {
        displayID
    }
}

nonisolated struct TestScreenTopologyService: ScreenTopologyProviding {
    var screens: [ScreenDisplaySnapshot] = []
    var mainScreen: ScreenDisplaySnapshot?

    func screen(containing point: CGPoint) -> ScreenDisplaySnapshot? {
        screens.first { $0.frame.contains(point) }
    }

    func screen(withDisplayID displayID: CGDirectDisplayID) -> ScreenDisplaySnapshot? {
        screens.first { $0.displayID == displayID }
    }
}

nonisolated struct TestClock: ClockProviding {
    var date = Date(timeIntervalSince1970: 1_700_000_000)

    func now() -> Date {
        date
    }
}

nonisolated struct TestScreenCapturePlatform: ScreenCapturePlatform {
    var content = ScreenContentSnapshot(displays: [], windows: [], applications: [])
    var imageProvider: @Sendable (ScreenCaptureRequest) throws -> CGImage = { request in
        makeCoordinateImage(
            width: request.configuration.width,
            height: request.configuration.height,
            pattern: .weighted(xMultiplier: 3, yMultiplier: 5, includeBlueSum: true)
        )
    }

    func shareableContent() async throws -> ScreenContentSnapshot {
        content
    }

    func captureScreenshot(_ request: ScreenCaptureRequest) async throws -> CGImage {
        try imageProvider(request)
    }
}

@MainActor
final class TestScreenRecordingPlatformSession: ScreenRecordingPlatformSession {
    private weak var eventSink: (any ScreenRecordingPlatformEventSink)?
    private(set) var isCapturing = false
    private(set) var configurationUpdates: [ScreenRecordingConfiguration] = []
    private(set) var targetUpdates: [ScreenRecordingTarget] = []
    private(set) var segmentOutputURLs: [ScreenRecordingSegmentToken: URL] = [:]

    func setEventSink(_ sink: (any ScreenRecordingPlatformEventSink)?) {
        eventSink = sink
    }

    func startCapture() async throws {
        isCapturing = true
    }

    func stopCapture() async throws {
        isCapturing = false
    }

    func updateConfiguration(_ configuration: ScreenRecordingConfiguration) async throws {
        configurationUpdates.append(configuration)
    }

    func updateTarget(_ target: ScreenRecordingTarget, configuration: ScreenRecordingConfiguration) async throws {
        targetUpdates.append(target)
        configurationUpdates.append(configuration)
    }

    func startRecordingSegment(to outputURL: URL) throws -> ScreenRecordingSegmentToken {
        let token = ScreenRecordingSegmentToken()
        segmentOutputURLs[token] = outputURL
        return token
    }

    func removeRecordingSegment(_ token: ScreenRecordingSegmentToken) throws {
        segmentOutputURLs[token] = nil
    }

    func finish(_ token: ScreenRecordingSegmentToken) {
        eventSink?.recordingPlatformSession(self, didFinishSegment: token)
    }

    func fail(_ token: ScreenRecordingSegmentToken, error: Error) {
        eventSink?.recordingPlatformSession(self, segment: token, didFailWith: error)
    }

    func stopWithError(_ error: Error) {
        isCapturing = false
        eventSink?.recordingPlatformSession(self, didStopWith: error)
    }
}

nonisolated struct TestScreenRecordingPlatform: ScreenRecordingPlatform {
    var content = ScreenContentSnapshot(displays: [], windows: [], applications: [])
    var microphoneAccess: @Sendable () async throws -> Void = {}
    var makeSessionHandler: @MainActor (
        ScreenRecordingTarget,
        ScreenRecordingConfiguration
    ) async throws -> any ScreenRecordingPlatformSession = { _, _ in
        TestScreenRecordingPlatformSession()
    }

    func shareableContent() async throws -> ScreenContentSnapshot {
        content
    }

    func requestMicrophoneAccess() async throws {
        try await microphoneAccess()
    }

    @MainActor
    func makeSession(
        target: ScreenRecordingTarget,
        configuration: ScreenRecordingConfiguration
    ) async throws -> any ScreenRecordingPlatformSession {
        try await makeSessionHandler(target, configuration)
    }
}

extension ScreenCaptureService {
    nonisolated init() {
        self.init(permissions: TestCapturePermissionService())
    }

    nonisolated init(permissions: any CapturePermissionServicing) {
        self.init(
            permissions: permissions,
            platform: TestScreenCapturePlatform(),
            workspace: TestWorkspaceService(),
            screens: TestScreenTopologyService(),
            mouse: TestMouseLocationService(),
            windowFocus: TestApplicationWindowFocusService(),
            clock: TestClock()
        )
    }
}

extension ScreenRecordingService {
    @MainActor
    init() {
        self.init(permissions: TestCapturePermissionService())
    }

    @MainActor
    init(permissions: any CapturePermissionServicing) {
        self.init(
            permissions: permissions,
            platform: TestScreenRecordingPlatform(),
            capturePlatform: TestScreenCapturePlatform(),
            workspace: TestWorkspaceService(),
            screens: TestScreenTopologyService(),
            files: SystemFileService(),
            mouse: TestMouseLocationService(),
            clock: TestClock()
        )
    }
}

extension AccessibilityUIMapCaptureService {
    nonisolated init() {
        self.init(capabilities: testCapabilities)
    }
}

extension EditorController {
    convenience init(
        capture: CapturedScreenshot,
        defaults: UserDefaults = .standard,
        textRecognizer: any CaptureTextRecognizing = VisionCaptureTextRecognizer(),
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions()
    ) {
        self.init(
            capture: capture,
            defaults: defaults,
            capabilities: testCapabilities,
            textRecognizer: textRecognizer,
            uiMapOverlayOptions: uiMapOverlayOptions
        )
    }

    convenience init(
        capture: CapturedScreenshot,
        session: EditorDocumentSession,
        defaults: UserDefaults = .standard,
        textRecognizer: any CaptureTextRecognizing = VisionCaptureTextRecognizer(),
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions()
    ) {
        self.init(
            capture: capture,
            session: session,
            defaults: defaults,
            capabilities: testCapabilities,
            textRecognizer: textRecognizer,
            uiMapOverlayOptions: uiMapOverlayOptions
        )
    }
}

extension SSSDocumentPackage {
    static func save(
        document: EditableScreenshotDocument,
        previewImage: CGImage,
        to url: URL,
        baseImageStorage: BaseImageStorage = .embedded
    ) throws {
        try save(
            document: document,
            previewImage: previewImage,
            to: url,
            baseImageStorage: baseImageStorage,
            includeUIMapSearchText: testCapabilities.isEnabled(.uiMap)
        )
    }

    static func updateRecognizedText(_ recognizedText: String?, in packageURL: URL) throws -> String {
        try updateRecognizedText(
            recognizedText,
            in: packageURL,
            includeUIMapSearchText: testCapabilities.isEnabled(.uiMap)
        )
    }
}

extension DocumentRecoveryStore {
    func saveCheckpoint(
        sessionID: UUID,
        title: String,
        sourceDocumentURL: URL?,
        label: String,
        document: EditableScreenshotDocument,
        previewImage: CGImage,
        pendingRecovery: Bool,
        hasUnsavedChanges: Bool
    ) throws {
        try saveCheckpoint(
            sessionID: sessionID,
            title: title,
            sourceDocumentURL: sourceDocumentURL,
            label: label,
            document: document,
            previewImage: previewImage,
            pendingRecovery: pendingRecovery,
            hasUnsavedChanges: hasUnsavedChanges,
            includeUIMapSearchText: testCapabilities.isEnabled(.uiMap)
        )
    }
}

nonisolated struct PixelSample: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8
}

private enum TestLifetimeRetainer {
    static let lock = NSLock()
    nonisolated(unsafe) static var objects: [AnyObject] = []
}

enum CoordinateImagePattern {
    case cartesian
    case weighted(xMultiplier: Int, yMultiplier: Int, includeBlueSum: Bool)
}

func makeCoordinateImage(width: Int, height: Int, pattern: CoordinateImagePattern = .cartesian) -> CGImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * bytesPerRow) + (x * bytesPerPixel)

            switch pattern {
            case .cartesian:
                pixels[offset] = UInt8(truncatingIfNeeded: x)
                pixels[offset + 1] = UInt8(truncatingIfNeeded: y)
                pixels[offset + 2] = 0
            case let .weighted(xMultiplier, yMultiplier, includeBlueSum):
                pixels[offset] = UInt8((x * xMultiplier) % 255)
                pixels[offset + 1] = UInt8((y * yMultiplier) % 255)
                pixels[offset + 2] = includeBlueSum ? UInt8((x + y) % 255) : 0
            }

            pixels[offset + 3] = 255
        }
    }

    let provider = CGDataProvider(data: Data(pixels) as CFData)

    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider!,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

func makeSolidImage(width: Int, height: Int, color: PixelSample) -> CGImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * bytesPerRow) + (x * bytesPerPixel)
            pixels[offset] = color.red
            pixels[offset + 1] = color.green
            pixels[offset + 2] = color.blue
            pixels[offset + 3] = color.alpha
        }
    }

    let provider = CGDataProvider(data: Data(pixels) as CFData)

    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider!,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

func samplePixel(
    in image: CGImage,
    topLeftX: Int,
    topLeftY: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) -> PixelSample {
    guard let data = image.dataProvider?.data else {
        XCTFail("Missing pixel data", file: file, line: line)
        return PixelSample(red: 0, green: 0, blue: 0, alpha: 0)
    }

    let bytes = CFDataGetBytePtr(data)!
    let bytesPerPixel = image.bitsPerPixel / 8
    let bytesPerRow = image.bytesPerRow
    let x = max(0, min(topLeftX, image.width - 1))
    let y = max(0, min(topLeftY, image.height - 1))
    let offset = (y * bytesPerRow) + (x * bytesPerPixel)

    return PixelSample(
        red: bytes[offset],
        green: bytes[offset + 1],
        blue: bytes[offset + 2],
        alpha: bytes[offset + 3]
    )
}

func pixelSample(for color: RGBAColor) -> PixelSample {
    PixelSample(
        red: UInt8((color.red * 255).rounded()),
        green: UInt8((color.green * 255).rounded()),
        blue: UInt8((color.blue * 255).rounded()),
        alpha: UInt8((color.alpha * 255).rounded())
    )
}

@discardableResult
func retainForTestLifetime<T: AnyObject>(_ object: T) -> T {
    TestLifetimeRetainer.lock.lock()
    defer { TestLifetimeRetainer.lock.unlock() }
    TestLifetimeRetainer.objects.append(object)
    return object
}

func makeDefaultToolStyles() -> [EditorTool: AnnotationStyle] {
    Dictionary(uniqueKeysWithValues: EditorTool.allCases.map { ($0, AnnotationStyle.default(for: $0)) })
}

func makeEditorSnapshot(
    cropRect: CGRect = CGRect(x: 0, y: 0, width: 400, height: 300),
    annotations: [Annotation] = [],
    selectedAnnotationIDs: [UUID] = [],
    nextCalloutNumber: Int = 1,
    presentation: ScreenshotPresentation = .plain,
    pinnedUIMapElementIDs: [UUID] = []
) -> EditorSnapshot {
    EditorSnapshot(
        cropRect: cropRect,
        annotations: annotations,
        selectedAnnotationIDs: selectedAnnotationIDs,
        nextCalloutNumber: nextCalloutNumber,
        presentation: presentation,
        pinnedUIMapElementIDs: pinnedUIMapElementIDs
    )
}

func makeEditorDocumentSession(
    initialSnapshot: EditorSnapshot? = nil,
    currentSnapshot: EditorSnapshot? = nil,
    undoStack: [EditorSnapshot] = [],
    redoStack: [EditorSnapshot] = [],
    toolStyles: [EditorTool: AnnotationStyle] = makeDefaultToolStyles(),
    savedPresentations: [SavedPresentation] = []
) -> EditorDocumentSession {
    let initial = initialSnapshot ?? makeEditorSnapshot()
    let current = currentSnapshot ?? initial

    return EditorDocumentSession(
        initialSnapshot: initial,
        currentSnapshot: current,
        undoStack: undoStack,
        redoStack: redoStack,
        toolStyles: toolStyles,
        savedPresentations: savedPresentations
    )
}

func makeCapturedScreenshot(
    image: CGImage? = nil,
    kind: CaptureKind = .region,
    sourceName: String = "Display",
    sourceRect: CGRect? = nil,
    bounds: CGRect? = nil,
    sourceWindowIdentity: CaptureSourceWindowIdentity? = nil,
    coordinateContract: DocumentCoordinateContract = .current,
    capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    uiMap: UIMapSnapshot? = nil
) -> CapturedScreenshot {
    let resolvedImage = image ?? makeCoordinateImage(width: 64, height: 48)

    return CapturedScreenshot(
        image: resolvedImage,
        kind: kind,
        sourceName: sourceName,
        sourceRect: sourceRect ?? bounds ?? CGRect(origin: .zero, size: CGSize(width: resolvedImage.width, height: resolvedImage.height)),
        sourceWindowIdentity: sourceWindowIdentity,
        coordinateContract: coordinateContract,
        capturedAt: capturedAt,
        uiMap: uiMap
    )
}

func makeEditableDocument(
    capture: CapturedScreenshot? = nil,
    session: EditorDocumentSession? = nil
) -> EditableScreenshotDocument {
    let resolvedCapture = capture ?? makeCapturedScreenshot()
    let resolvedSession = session ?? makeEditorDocumentSession(
        initialSnapshot: makeEditorSnapshot(
            cropRect: CGRect(origin: .zero, size: CGSize(width: resolvedCapture.image.width, height: resolvedCapture.image.height))
        )
    )

    return EditableScreenshotDocument(capture: resolvedCapture, session: resolvedSession)
}

func makeCaptureWindow(
    id: CGWindowID = 0,
    ownerPID: pid_t = 0,
    ownerName: String = "App",
    title: String = "Window",
    focusRank: Int = 0,
    frame: CGRect = CGRect(x: 20, y: 20, width: 240, height: 180),
    thumbnail: CGImage? = nil,
    thumbnailSize: CGSize? = nil,
    thumbnailColor: PixelSample = PixelSample(red: 20, green: 40, blue: 60, alpha: 255)
) -> CaptureWindowSummary {
    let resolvedThumbnail = thumbnail ?? thumbnailSize.map {
        makeSolidImage(
            width: Int($0.width),
            height: Int($0.height),
            color: thumbnailColor
        )
    }

    return CaptureWindowSummary(
        id: id,
        ownerName: ownerName,
        ownerPID: ownerPID,
        title: title,
        frame: frame,
        layer: 0,
        focusRank: focusRank,
        thumbnail: resolvedThumbnail
    )
}

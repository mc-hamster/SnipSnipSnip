import AppKit
import Foundation

protocol FileSystemServicing: Sendable {
    nonisolated var temporaryDirectory: URL { get }
    nonisolated func fileExists(atPath path: String) -> Bool
    nonisolated func directoryExists(at url: URL) -> Bool
    nonisolated func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws
    nonisolated func removeItem(at url: URL) throws
    nonisolated func copyItem(at sourceURL: URL, to destinationURL: URL) throws
    nonisolated func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    nonisolated func replaceItemAt(_ originalURL: URL, withItemAt newItemURL: URL) throws
    nonisolated func readData(from url: URL) throws -> Data
    nonisolated func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws
}

protocol WorkspaceServicing: Sendable {
    nonisolated var frontmostApplicationProcessIdentifier: pid_t? { get }
    nonisolated var frontmostApplication: WorkspaceRunningApplicationSnapshot? { get }
    nonisolated var runningApplications: [WorkspaceRunningApplicationSnapshot] { get }
    nonisolated func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL?
    nonisolated func open(_ url: URL)
    @MainActor func activateApplication(processIdentifier: pid_t)
    nonisolated func activateFileViewerSelecting(_ urls: [URL])
}

nonisolated struct WorkspaceRunningApplicationSnapshot: Sendable, Equatable {
    let processIdentifier: pid_t
    let activationPolicy: NSApplication.ActivationPolicy
    let bundleIdentifier: String?
    let localizedName: String?
    let bundleURL: URL?
}

protocol ScreenTopologyProviding: Sendable {
    nonisolated var screens: [ScreenDisplaySnapshot] { get }
    nonisolated var mainScreen: ScreenDisplaySnapshot? { get }
    nonisolated func screen(containing point: CGPoint) -> ScreenDisplaySnapshot?
    nonisolated func screen(withDisplayID displayID: CGDirectDisplayID) -> ScreenDisplaySnapshot?
}

protocol MouseLocationProviding: Sendable {
    nonisolated var appKitGlobalLocation: CGPoint { get }
}

protocol ApplicationWindowFocusProviding: Sendable {
    nonisolated func preferredDisplayID() async -> CGDirectDisplayID?
}

protocol BundleIdentityProviding: Sendable {
    nonisolated var bundleIdentifier: String? { get }
    nonisolated var bundlePath: String { get }
}

protocol PasteboardServicing: Sendable {
    @MainActor var changeCount: Int { get }
    @MainActor var typeNames: [String] { get }
    @MainActor func clearContents()
    @MainActor func fileAndWebURLs() -> [URL]
    @MainActor func data(forType type: NSPasteboard.PasteboardType) -> Data?
    @MainActor func string(forType type: NSPasteboard.PasteboardType) -> String?
    @MainActor func setString(_ string: String, forType type: NSPasteboard.PasteboardType)
    @MainActor func setData(_ data: Data, forType type: NSPasteboard.PasteboardType)
    @MainActor func writeFileURLs(_ urls: [URL])
}

protocol ClockProviding: Sendable {
    nonisolated func now() -> Date
}

protocol IDGenerating: Sendable {
    nonisolated func uuid() -> UUID
}

protocol Scheduling: Sendable {
    nonisolated func sleep(nanoseconds: UInt64) async throws
}

nonisolated struct ScreenDisplaySnapshot: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let backingScaleFactor: CGFloat
}

struct AppSystemServices: Sendable {
    let files: any FileSystemServicing
    let workspace: any WorkspaceServicing
    let screens: any ScreenTopologyProviding
    let mouse: any MouseLocationProviding
    let windowFocus: any ApplicationWindowFocusProviding
    let bundle: any BundleIdentityProviding
    let pasteboard: any PasteboardServicing
    let clock: any ClockProviding
    let ids: any IDGenerating
    let scheduler: any Scheduling
    let permissions: any CapturePermissionServicing
    let accessibility: any AccessibilityPlatform
    let screenCapturePlatform: any ScreenCapturePlatform
    let screenRecordingPlatform: any ScreenRecordingPlatform
    let connectedDevicePlatform: any ConnectedDevicePlatform

    static func live(permissions: any CapturePermissionServicing) -> AppSystemServices {
        AppSystemServices(
            files: SystemFileService(),
            workspace: SystemWorkspaceService(),
            screens: SystemScreenTopologyService(),
            mouse: SystemMouseLocationService(),
            windowFocus: SystemApplicationWindowFocusService(),
            bundle: SystemBundleIdentityService(),
            pasteboard: SystemPasteboardService(),
            clock: SystemClock(),
            ids: SystemIDGenerator(),
            scheduler: SystemScheduler(),
            permissions: permissions,
            accessibility: LiveAccessibilityPlatform(),
            screenCapturePlatform: LiveScreenCapturePlatform(),
            screenRecordingPlatform: LiveScreenRecordingPlatform(),
            connectedDevicePlatform: LiveConnectedDevicePlatform()
        )
    }
}

struct SystemFileService: FileSystemServicing, @unchecked Sendable {
    nonisolated(unsafe) private let fileManager: FileManager

    nonisolated init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    nonisolated var temporaryDirectory: URL {
        fileManager.temporaryDirectory
    }

    nonisolated func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    nonisolated func directoryExists(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    nonisolated func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: createIntermediates)
    }

    nonisolated func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    nonisolated func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    nonisolated func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    nonisolated func replaceItemAt(_ originalURL: URL, withItemAt newItemURL: URL) throws {
        _ = try fileManager.replaceItemAt(originalURL, withItemAt: newItemURL)
    }

    nonisolated func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    nonisolated func writeData(_ data: Data, to url: URL, options: Data.WritingOptions = []) throws {
        try data.write(to: url, options: options)
    }
}

struct SystemWorkspaceService: WorkspaceServicing {
    nonisolated var frontmostApplicationProcessIdentifier: pid_t? {
        frontmostApplication?.processIdentifier
    }

    nonisolated var frontmostApplication: WorkspaceRunningApplicationSnapshot? {
        NSWorkspace.shared.frontmostApplication.map(Self.snapshot)
    }

    nonisolated var runningApplications: [WorkspaceRunningApplicationSnapshot] {
        NSWorkspace.shared.runningApplications.map(Self.snapshot)
    }

    nonisolated func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    nonisolated func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    @MainActor
    func activateApplication(processIdentifier: pid_t) {
        NSRunningApplication(processIdentifier: processIdentifier)?.activate(options: [])
    }

    nonisolated func activateFileViewerSelecting(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    nonisolated private static func snapshot(_ application: NSRunningApplication) -> WorkspaceRunningApplicationSnapshot {
        WorkspaceRunningApplicationSnapshot(
            processIdentifier: application.processIdentifier,
            activationPolicy: application.activationPolicy,
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName,
            bundleURL: application.bundleURL
        )
    }
}

struct SystemScreenTopologyService: ScreenTopologyProviding {
    nonisolated var screens: [ScreenDisplaySnapshot] {
        NSScreen.screens.map(ScreenDisplaySnapshot.init(screen:))
    }

    nonisolated var mainScreen: ScreenDisplaySnapshot? {
        NSScreen.main.map(ScreenDisplaySnapshot.init(screen:))
    }

    nonisolated func screen(containing point: CGPoint) -> ScreenDisplaySnapshot? {
        screens.first { $0.frame.contains(point) }
    }

    nonisolated func screen(withDisplayID displayID: CGDirectDisplayID) -> ScreenDisplaySnapshot? {
        screens.first { $0.displayID == displayID }
    }
}

struct SystemMouseLocationService: MouseLocationProviding {
    nonisolated var appKitGlobalLocation: CGPoint {
        NSEvent.mouseLocation
    }
}

struct SystemApplicationWindowFocusService: ApplicationWindowFocusProviding {
    nonisolated func preferredDisplayID() async -> CGDirectDisplayID? {
        await MainActor.run {
            NSApp.keyWindow?.screen?.gscDisplayID
                ?? NSApp.mainWindow?.screen?.gscDisplayID
                ?? NSApp.windows.first { $0.isVisible && !$0.isMiniaturized }?.screen?.gscDisplayID
        }
    }
}

struct NullApplicationWindowFocusService: ApplicationWindowFocusProviding {
    nonisolated func preferredDisplayID() async -> CGDirectDisplayID? { nil }
}

struct SystemBundleIdentityService: BundleIdentityProviding {
    nonisolated var bundleIdentifier: String? {
        Bundle.main.bundleIdentifier
    }

    nonisolated var bundlePath: String {
        Bundle.main.bundlePath
    }
}

struct SystemPasteboardService: PasteboardServicing {
    @MainActor
    var changeCount: Int {
        NSPasteboard.general.changeCount
    }

    @MainActor
    var typeNames: [String] {
        NSPasteboard.general.types?.map(\.rawValue) ?? []
    }

    @MainActor
    func clearContents() {
        NSPasteboard.general.clearContents()
    }

    @MainActor
    func fileAndWebURLs() -> [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    }

    @MainActor
    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        NSPasteboard.general.data(forType: type)
    }

    @MainActor
    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        NSPasteboard.general.string(forType: type)
    }

    @MainActor
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) {
        NSPasteboard.general.setString(string, forType: type)
    }

    @MainActor
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) {
        NSPasteboard.general.setData(data, forType: type)
    }

    @MainActor
    func writeFileURLs(_ urls: [URL]) {
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }
}

struct SystemClock: ClockProviding {
    nonisolated func now() -> Date {
        Date()
    }
}

struct SystemIDGenerator: IDGenerating {
    nonisolated func uuid() -> UUID {
        UUID()
    }
}

struct SystemScheduler: Scheduling {
    nonisolated func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

private extension ScreenDisplaySnapshot {
    nonisolated init(screen: NSScreen) {
        self.init(
            displayID: screen.gscDisplayID ?? 0,
            name: screen.localizedName.isEmpty ? "Display" : screen.localizedName,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            backingScaleFactor: screen.backingScaleFactor
        )
    }
}

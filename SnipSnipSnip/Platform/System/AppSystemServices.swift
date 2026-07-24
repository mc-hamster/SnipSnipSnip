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
    @MainActor @discardableResult func activateApplication(processIdentifier: pid_t) -> Bool
    nonisolated func activateFileViewerSelecting(_ urls: [URL])
}

nonisolated struct WorkspaceRunningApplicationSnapshot: Sendable, Equatable {
    let processIdentifier: pid_t
    let activationPolicy: NSApplication.ActivationPolicy
    let bundleIdentifier: String?
    let localizedName: String?
    let bundleURL: URL?
}

nonisolated struct PasteboardRepresentationSnapshot: Equatable, Sendable {
    let typeIdentifier: String
    let data: Data
}

nonisolated struct PasteboardItemSnapshot: Equatable, Sendable {
    let representations: [PasteboardRepresentationSnapshot]
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
    @MainActor @discardableResult func clearContents() -> Bool
    @MainActor func fileAndWebURLs() -> [URL]
    @MainActor func data(forType type: NSPasteboard.PasteboardType) -> Data?
    @MainActor func string(forType type: NSPasteboard.PasteboardType) -> String?
    @MainActor func itemSnapshots(acceptedTypeIdentifiers: Set<String>) -> [PasteboardItemSnapshot]
    @MainActor @discardableResult func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool
    @MainActor @discardableResult func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool
    @MainActor @discardableResult func writeFileURLs(_ urls: [URL]) -> Bool
    @MainActor @discardableResult func writeItemSnapshots(_ items: [PasteboardItemSnapshot]) -> Bool
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
#if APP_STORE_BUILD
        let accessibilityPlatform: any AccessibilityPlatform = UnavailableAccessibilityPlatform()
#else
        let accessibilityPlatform: any AccessibilityPlatform = LiveAccessibilityPlatform()
#endif
        return AppSystemServices(
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
            accessibility: accessibilityPlatform,
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
    @discardableResult
    func activateApplication(processIdentifier: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: processIdentifier)?.activate(options: []) ?? false
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
    @discardableResult
    func clearContents() -> Bool {
        NSPasteboard.general.clearContents()
        return true
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
    func itemSnapshots(acceptedTypeIdentifiers: Set<String>) -> [PasteboardItemSnapshot] {
        (NSPasteboard.general.pasteboardItems ?? []).compactMap { item in
            let representations = item.types.compactMap { type -> PasteboardRepresentationSnapshot? in
                guard acceptedTypeIdentifiers.contains(type.rawValue),
                      let data = item.data(forType: type),
                      !data.isEmpty else {
                    return nil
                }
                return PasteboardRepresentationSnapshot(typeIdentifier: type.rawValue, data: data)
            }
            return representations.isEmpty ? nil : PasteboardItemSnapshot(representations: representations)
        }
    }

    @MainActor
    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        NSPasteboard.general.setString(string, forType: type)
    }

    @MainActor
    @discardableResult
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool {
        NSPasteboard.general.setData(data, forType: type)
    }

    @MainActor
    @discardableResult
    func writeFileURLs(_ urls: [URL]) -> Bool {
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    @MainActor
    @discardableResult
    func writeItemSnapshots(_ items: [PasteboardItemSnapshot]) -> Bool {
        guard !items.isEmpty else { return false }
        let pasteboardItems = items.compactMap { snapshot -> NSPasteboardItem? in
            let item = NSPasteboardItem()
            var wroteRepresentation = false
            for representation in snapshot.representations {
                let type = NSPasteboard.PasteboardType(representation.typeIdentifier)
                wroteRepresentation = item.setData(representation.data, forType: type) || wroteRepresentation
            }
            return wroteRepresentation ? item : nil
        }
        guard pasteboardItems.count == items.count else { return false }
        return NSPasteboard.general.writeObjects(pasteboardItems)
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

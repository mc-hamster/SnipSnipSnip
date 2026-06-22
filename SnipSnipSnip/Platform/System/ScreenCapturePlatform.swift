import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

nonisolated struct ScreenRunningApplicationSnapshot: Equatable, Sendable {
    let processID: pid_t
}

nonisolated struct ScreenWindowSnapshot: Identifiable, Equatable, Sendable {
    let id: CGWindowID
    let ownerName: String
    let ownerPID: pid_t
    let bundleIdentifier: String?
    let title: String
    let frame: CGRect
    let layer: Int
    let isOnScreen: Bool
}

nonisolated struct ScreenContentSnapshot: Equatable, Sendable {
    let displays: [DisplaySnapshot]
    let windows: [ScreenWindowSnapshot]
    let applications: [ScreenRunningApplicationSnapshot]
}

nonisolated enum ScreenCaptureTarget: Equatable, Sendable {
    case screenRect(CGRect)
    case window(CGWindowID)
    case display(CGDirectDisplayID, excludingProcessID: pid_t?)
}

nonisolated struct ScreenCaptureConfiguration: Equatable, Sendable {
    var width: Int
    var height: Int
    var showsCursor: Bool
    var sourceRect: CGRect?
    var ignoreShadows: Bool
    var ignoreClipping: Bool

    init(
        width: Int,
        height: Int,
        showsCursor: Bool = false,
        sourceRect: CGRect? = nil,
        ignoreShadows: Bool = false,
        ignoreClipping: Bool = false
    ) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.showsCursor = showsCursor
        self.sourceRect = sourceRect?.gscIntegralStandardized
        self.ignoreShadows = ignoreShadows
        self.ignoreClipping = ignoreClipping
    }
}

nonisolated struct ScreenCaptureRequest: Equatable, Sendable {
    let target: ScreenCaptureTarget
    let configuration: ScreenCaptureConfiguration
}

nonisolated enum ScreenCapturePlatformError: LocalizedError, Equatable {
    case noDisplays
    case windowUnavailable
    case displayUnavailable
    case imageUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            return "No active displays were found for capture."
        case .windowUnavailable:
            return "The selected window could not be captured."
        case .displayUnavailable:
            return "The selected display could not be captured."
        case .imageUnavailable:
            return "The capture image buffer could not be created."
        }
    }
}

protocol ScreenCapturePlatform: Sendable {
    nonisolated func shareableContent() async throws -> ScreenContentSnapshot
    nonisolated func captureScreenshot(_ request: ScreenCaptureRequest) async throws -> CGImage
}

struct LiveScreenCapturePlatform: ScreenCapturePlatform {
    nonisolated func shareableContent() async throws -> ScreenContentSnapshot {
        let result: ScreenCaptureShareableContentResult = try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let content else {
                    continuation.resume(throwing: ScreenCapturePlatformError.noDisplays)
                    return
                }

                continuation.resume(returning: ScreenCaptureShareableContentResult(content: content))
            }
        }
        return Self.snapshot(from: result.content)
    }

    nonisolated func captureScreenshot(_ request: ScreenCaptureRequest) async throws -> CGImage {
        let configuration = makeScreenshotConfiguration(from: request.configuration)

        switch request.target {
        case .screenRect(let rect):
            return try await captureScreenshot(rect: rect, configuration: configuration)
        case .window(let windowID):
            let content = try await rawShareableContent()
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenCapturePlatformError.windowUnavailable
            }
            return try await captureScreenshot(
                filter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration,
                missingImageError: .windowUnavailable
            )
        case .display(let displayID, let excludedProcessID):
            let content = try await rawShareableContent()
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenCapturePlatformError.displayUnavailable
            }
            return try await captureScreenshot(
                filter: Self.displayCaptureFilter(for: display, content: content, excludingProcessID: excludedProcessID),
                configuration: configuration,
                missingImageError: .imageUnavailable
            )
        }
    }

    nonisolated private func rawShareableContent() async throws -> SCShareableContent {
        let result: ScreenCaptureShareableContentResult = try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let content else {
                    continuation.resume(throwing: ScreenCapturePlatformError.noDisplays)
                    return
                }

                continuation.resume(returning: ScreenCaptureShareableContentResult(content: content))
            }
        }
        return result.content
    }

    nonisolated private func captureScreenshot(
        rect: CGRect,
        configuration: SCScreenshotConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
            SCScreenshotManager.captureScreenshot(rect: rect, configuration: configuration) { output, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let image = output?.sdrImage else {
                    continuation.resume(throwing: ScreenCapturePlatformError.imageUnavailable)
                    return
                }

                continuation.resume(returning: image)
            }
        }
    }

    nonisolated private func captureScreenshot(
        filter: SCContentFilter,
        configuration: SCScreenshotConfiguration,
        missingImageError: ScreenCapturePlatformError
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
            SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration) { output, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let image = output?.sdrImage else {
                    continuation.resume(throwing: missingImageError)
                    return
                }

                continuation.resume(returning: image)
            }
        }
    }

    nonisolated private func makeScreenshotConfiguration(
        from configuration: ScreenCaptureConfiguration
    ) -> SCScreenshotConfiguration {
        let scConfiguration = SCScreenshotConfiguration()
        scConfiguration.width = configuration.width
        scConfiguration.height = configuration.height
        scConfiguration.showsCursor = configuration.showsCursor
        scConfiguration.dynamicRange = .sdr
        if let sourceRect = configuration.sourceRect {
            scConfiguration.sourceRect = sourceRect
        }
        scConfiguration.ignoreShadows = configuration.ignoreShadows
        scConfiguration.ignoreClipping = configuration.ignoreClipping
        return scConfiguration
    }

    nonisolated private static func displayCaptureFilter(
        for display: SCDisplay,
        content: SCShareableContent,
        excludingProcessID processID: pid_t?
    ) -> SCContentFilter {
        guard let processID else {
            return SCContentFilter(display: display, excludingWindows: [])
        }

        let excludedApplications = content.applications.filter { $0.processID == processID }
        if excludedApplications.isEmpty {
            let excludedWindows = content.windows.filter { $0.owningApplication?.processID == processID }
            return SCContentFilter(display: display, excludingWindows: excludedWindows)
        }

        return SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
    }

    nonisolated private static func snapshot(from content: SCShareableContent) -> ScreenContentSnapshot {
        let displays = content.displays.map { display in
            return DisplaySnapshot(
                displayID: display.displayID,
                name: "Display",
                frame: display.frame,
                scale: 2
            )
        }

        let windows = content.windows.map { window in
            ScreenWindowSnapshot(
                id: window.windowID,
                ownerName: window.owningApplication?.applicationName ?? "Window",
                ownerPID: window.owningApplication?.processID ?? 0,
                bundleIdentifier: window.owningApplication?.bundleIdentifier,
                title: window.title ?? "",
                frame: window.frame,
                layer: window.windowLayer,
                isOnScreen: window.isOnScreen
            )
        }

        let applications = content.applications.map {
            ScreenRunningApplicationSnapshot(processID: $0.processID)
        }

        return ScreenContentSnapshot(displays: displays, windows: windows, applications: applications)
    }
}

nonisolated private struct ScreenCaptureShareableContentResult: @unchecked Sendable {
    let content: SCShareableContent
}

import AppKit
import CoreGraphics
import Foundation
import OSLog
@preconcurrency import ScreenCaptureKit

protocol ScreenCaptureServiceType: Sendable {
    func listWindows(excluding processID: pid_t, includeThumbnails: Bool) async throws -> [CaptureWindowSummary]
    func frontmostWindow(excluding processID: pid_t) async throws -> CaptureWindowSummary
    func resolveWindowTarget(_ window: CaptureWindowSummary, excluding processID: pid_t) async throws -> CaptureWindowSummary
    func captureCurrentDisplay() async throws -> CapturedScreenshot
    func captureFullscreen(mode: ScreenshotFullscreenDisplayMode, selectedDisplayID: CGDirectDisplayID?) async throws -> CapturedScreenshot
    func captureDesktopOverlaySnapshot() async throws -> DesktopCompositeSnapshot
    func captureRegion(from snapshot: DesktopCompositeSnapshot, selection: CGRect) async throws -> CapturedScreenshot
    func captureRegion(in selection: CGRect) async throws -> CapturedScreenshot
    func captureRegionDirect(in selection: CGRect) async throws -> CapturedScreenshot
    func captureRegionWithinSingleDisplayDirect(in selection: CGRect) async throws -> CapturedScreenshot
    func captureWindow(_ window: CaptureWindowSummary) async throws -> CapturedScreenshot
}

private enum CapturePlanDiagnostics {
    nonisolated private static let logger = Logger(
        subsystem: "com.oontz.SnipSnipSnip",
        category: "CapturePlan"
    )

    nonisolated static let isEnabled = false

    nonisolated static func log(_ message: String) {
        guard isEnabled else {
            return
        }

        logger.debug("\(message, privacy: .public)")
    }
}

extension ScreenCaptureServiceType {
    func listWindows(includeThumbnails: Bool = true) async throws -> [CaptureWindowSummary] {
        try await listWindows(excluding: ProcessInfo.processInfo.processIdentifier, includeThumbnails: includeThumbnails)
    }

    func frontmostWindow() async throws -> CaptureWindowSummary {
        try await frontmostWindow(excluding: ProcessInfo.processInfo.processIdentifier)
    }

    func resolveWindowTarget(_ window: CaptureWindowSummary) async throws -> CaptureWindowSummary {
        try await resolveWindowTarget(window, excluding: ProcessInfo.processInfo.processIdentifier)
    }

    func captureRegionWithinSingleDisplayDirect(in selection: CGRect) async throws -> CapturedScreenshot {
        try await captureRegionDirect(in: selection)
    }

    func captureFullscreen(
        mode: ScreenshotFullscreenDisplayMode,
        selectedDisplayID: CGDirectDisplayID?
    ) async throws -> CapturedScreenshot {
        try await captureCurrentDisplay()
    }
}

nonisolated enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noDisplays
    case noWindowsAvailable
    case currentDisplayUnavailable
    case invalidRegion
    case regionSpansMultipleDisplays
    case windowImageUnavailable
    case bitmapContextCreationFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording access is required before capture can begin."
        case .noDisplays:
            return "No active displays were found for capture."
        case .noWindowsAvailable:
            return "No shareable windows are currently available."
        case .currentDisplayUnavailable:
            return "The current display could not be resolved."
        case .invalidRegion:
            return "The selected region was too small to capture."
        case .regionSpansMultipleDisplays:
            return "Scrolling Capture must stay within one display."
        case .windowImageUnavailable:
            return "The selected window could not be captured."
        case .bitmapContextCreationFailed:
            return "The capture image buffer could not be created."
        }
    }
}

nonisolated struct DirectDisplayCaptureRequest: Equatable {
    let displayID: CGDirectDisplayID
    let sourceRect: DisplayLocalRect
    let outputSize: CGSize
}

nonisolated enum RegionCapturePlan: Equatable {
    case screenRect(rect: CGRect, scale: CGFloat)
    case filteredDisplay(DirectDisplayCaptureRequest)
    case rejectedSingleDisplay
}

struct ScreenCaptureService: ScreenCaptureServiceType {
    func listWindows(excluding processID: pid_t = ProcessInfo.processInfo.processIdentifier, includeThumbnails: Bool = true) async throws -> [CaptureWindowSummary] {
        guard CapturePermissionStatus.current().hasScreenRecording else {
            throw ScreenCaptureError.permissionDenied
        }

        let content = try await fetchShareableContent()
        let focusOrder = windowFocusOrder()

        let displays = content.displays
        let candidates = content.windows.compactMap { window -> WindowCaptureCandidate? in
            let ownerName = window.owningApplication?.applicationName ?? "Window"
            let ownerPID = window.owningApplication?.processID ?? 0
            let title = window.title ?? ""
            let scale = displayScale(forCaptureFrame: window.frame, displays: displays)

            guard ownerPID != processID else {
                return nil
            }

            guard window.windowLayer == 0, window.frame.width >= 60, window.frame.height >= 40, window.isOnScreen else {
                return nil
            }

            return WindowCaptureCandidate(
                window: window,
                id: window.windowID,
                ownerName: ownerName,
                ownerPID: ownerPID,
                title: title,
                frame: window.frame,
                layer: window.windowLayer,
                focusRank: focusOrder[window.windowID] ?? Int.max,
                scale: scale
            )
        }
        let summaries = includeThumbnails
            ? await windowSummariesWithThumbnails(for: candidates)
            : candidates.map { $0.summary(thumbnail: nil) }

        return summaries.sorted { left, right in
            if left.focusRank != right.focusRank {
                return left.focusRank < right.focusRank
            }

            if left.ownerName == right.ownerName {
                return left.displayTitle.localizedStandardCompare(right.displayTitle) == .orderedAscending
            }

            return left.ownerName.localizedStandardCompare(right.ownerName) == .orderedAscending
        }
    }

    private func windowSummariesWithThumbnails(for candidates: [WindowCaptureCandidate]) async -> [CaptureWindowSummary] {
        guard !candidates.isEmpty else {
            return []
        }

        let maxConcurrentCaptures = min(4, candidates.count)
        var nextIndex = 0
        var summaries: [CaptureWindowSummary] = []

        await withTaskGroup(of: CaptureWindowSummary?.self) { group in
            func enqueueNext() {
                guard nextIndex < candidates.count else {
                    return
                }

                let candidate = candidates[nextIndex]
                nextIndex += 1

                group.addTask {
                    let thumbnail = try? await captureThumbnail(for: candidate.window, scale: candidate.scale)
                    return candidate.summary(thumbnail: thumbnail)
                }
            }

            for _ in 0..<maxConcurrentCaptures {
                enqueueNext()
            }

            while let summary = await group.next() {
                if let summary {
                    summaries.append(summary)
                }

                enqueueNext()
            }
        }

        return summaries
    }

    func frontmostWindow(excluding processID: pid_t = ProcessInfo.processInfo.processIdentifier) async throws -> CaptureWindowSummary {
        let windows = try await listWindows(excluding: processID, includeThumbnails: true)
        let frontmostOwnerPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        if let frontmostOwnerPID,
           let frontmostWindow = windows
            .filter({ $0.ownerPID == frontmostOwnerPID })
            .min(by: { $0.focusRank < $1.focusRank }) {
            return frontmostWindow
        }

        guard let fallback = windows.first else {
            throw ScreenCaptureError.noWindowsAvailable
        }

        return fallback
    }

    func resolveWindowTarget(
        _ window: CaptureWindowSummary,
        excluding processID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) async throws -> CaptureWindowSummary {
        let windows = try await listWindows(excluding: processID, includeThumbnails: true)

        guard let resolved = gscBestWindowMatch(
            for: window,
            in: windows,
            frontmostOwnerPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ) else {
            throw ScreenCaptureError.noWindowsAvailable
        }

        return resolved
    }

    func captureCurrentDisplay() async throws -> CapturedScreenshot {
        let displays = try await captureDisplaySnapshots()
        guard let display = currentDisplay(from: displays) else {
            throw ScreenCaptureError.currentDisplayUnavailable
        }

        return try await captureDisplay(display)
    }

    func captureFullscreen(
        mode: ScreenshotFullscreenDisplayMode,
        selectedDisplayID: CGDirectDisplayID?
    ) async throws -> CapturedScreenshot {
        switch mode {
        case .currentDisplay:
            return try await captureCurrentDisplay()
        case .selectedDisplay:
            let displays = try await captureDisplaySnapshots()
            guard let display = fullscreenDisplay(
                mode: mode,
                selectedDisplayID: selectedDisplayID,
                displays: displays,
                preferredDisplayID: nil,
                preferredPoint: nil
            ) else {
                throw ScreenCaptureError.currentDisplayUnavailable
            }
            return try await captureDisplay(display)
        case .allDisplays:
            return makeFullscreenCapture(from: try await captureDesktopComposite())
        }
    }

    private func captureDisplay(_ display: DisplaySnapshot) async throws -> CapturedScreenshot {
        let image = try await captureScreenshot(in: display.frame, scale: display.scale)

        return CapturedScreenshot(
            image: image,
            kind: .fullscreen,
            sourceName: display.name,
            sourceRect: display.frame,
            capturedAt: Date()
        )
    }

    nonisolated func makeFullscreenCapture(from snapshot: DesktopCompositeSnapshot, capturedAt: Date = Date()) -> CapturedScreenshot {
        let image = snapshot.previewImage
            ?? (try? buildDesktopPreview(from: snapshot.displayPreviews, globalFrame: snapshot.globalFrame))
            ?? snapshot.displayPreviews.first?.image

        precondition(image != nil, "Fullscreen capture snapshots require at least one display preview.")

        return CapturedScreenshot(
            image: image!,
            kind: .fullscreen,
            sourceName: fullscreenSourceName(for: snapshot.displays),
            sourceRect: snapshot.globalFrame,
            capturedAt: capturedAt
        )
    }

    func captureDesktopComposite() async throws -> DesktopCompositeSnapshot {
        try await captureDesktopSnapshot(buildCompositePreview: true)
    }

    func captureDesktopOverlaySnapshot() async throws -> DesktopCompositeSnapshot {
        try await captureDesktopSnapshot(buildCompositePreview: false)
    }

    private func captureDesktopSnapshot(buildCompositePreview: Bool) async throws -> DesktopCompositeSnapshot {
        let displays = try await captureDisplaySnapshots()
        let globalFrame = desktopFrame(for: displays)

        let displayPreviews = try await captureDisplayPreviews(from: displays)
        let previewImage = buildCompositePreview ? try buildDesktopPreview(from: displayPreviews, globalFrame: globalFrame) : nil

        return DesktopCompositeSnapshot(
            previewImage: previewImage,
            globalFrame: globalFrame,
            displays: displays,
            displayPreviews: displayPreviews
        )
    }

    func captureRegion(from snapshot: DesktopCompositeSnapshot, selection: CGRect) async throws -> CapturedScreenshot {
        let region = selection.gscIntegralStandardized.gscClamped(to: snapshot.globalFrame)

        guard region.width > 2, region.height > 2 else {
            throw ScreenCaptureError.invalidRegion
        }

        let image = try buildRegionImage(from: snapshot.displayPreviews, region: region)

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
        let region = selection.gscIntegralStandardized

        guard region.width > 2, region.height > 2 else {
            throw ScreenCaptureError.invalidRegion
        }

        let content = try await fetchShareableContent()
        let displays = makeDisplaySnapshots(from: content.displays)
        guard case let .screenRect(rect, scale) = regionCapturePlan(
            for: region,
            displays: displays,
            requiresSingleDisplay: false
        ) else {
            throw ScreenCaptureError.invalidRegion
        }
        debugCapturePlan(strategy: "screen-rect", region: rect, displays: displays)
        let image = try await captureScreenshot(in: rect, scale: scale)

        return CapturedScreenshot(
            image: image,
            kind: .region,
            sourceName: "Region",
            sourceRect: region,
            capturedAt: Date()
        )
    }

    func captureRegionWithinSingleDisplayDirect(in selection: CGRect) async throws -> CapturedScreenshot {
        let region = selection.gscIntegralStandardized
        guard region.width > 2, region.height > 2 else {
            throw ScreenCaptureError.invalidRegion
        }

        let content = try await fetchShareableContent()
        let displays = makeDisplaySnapshots(from: content.displays)
        guard case let .filteredDisplay(request) = regionCapturePlan(
            for: region,
            displays: displays,
            requiresSingleDisplay: true
        ),
              let scDisplay = content.displays.first(where: { $0.displayID == request.displayID }),
              let displaySnapshot = displays.first(where: { $0.displayID == request.displayID }) else {
            throw ScreenCaptureError.regionSpansMultipleDisplays
        }

        let filter = makeDisplayCaptureFilter(for: scDisplay, content: content)
        debugCapturePlan(strategy: "filtered-display-local", region: region, displays: displays, request: request)
        let image = try await captureDisplayRegion(
            filter: filter,
            displaySnapshot: displaySnapshot,
            cropRegion: region,
            primaryRequest: request
        )

        return CapturedScreenshot(
            image: image,
            kind: .region,
            sourceName: "Region",
            sourceRect: region,
            capturedAt: Date()
        )
    }

    /// Captures a region within a single display. Tries the `sourceRect` path first (fastest),
    /// then falls back to capturing the full display and cropping. The full-display path avoids a
    /// known SCKit failure where `SCScreenshotConfiguration.sourceRect` causes "Failed to start
    /// stream" on secondary displays regardless of filter or configuration.
    private func captureDisplayRegion(
        filter: SCContentFilter,
        displaySnapshot: DisplaySnapshot,
        cropRegion: CGRect,
        primaryRequest: DirectDisplayCaptureRequest
    ) async throws -> CGImage {
        do {
            return try await captureScreenshot(
                filter: filter,
                sourceRect: primaryRequest.sourceRect,
                outputSize: primaryRequest.outputSize
            )
        } catch {
            return try await captureFullDisplayAndCrop(
                filter: filter,
                display: displaySnapshot,
                cropRegion: cropRegion
            )
        }
    }

    /// Captures the entire display using a content filter (no `sourceRect`), then crops to the
    /// requested region. Used when setting `sourceRect` on the configuration causes SCKit to fail.
    private func captureFullDisplayAndCrop(
        filter: SCContentFilter,
        display: DisplaySnapshot,
        cropRegion: CGRect
    ) async throws -> CGImage {
        let scale = display.scale
        let frame = display.frame
        let fullW = max(Int((frame.width * scale).rounded(.up)), 1)
        let fullH = max(Int((frame.height * scale).rounded(.up)), 1)

        let configuration = SCScreenshotConfiguration()
        configuration.width = fullW
        configuration.height = fullH
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr

        let fullImage = try await captureScreenshot(filter: filter, configuration: configuration)

        // Quartz global and image crop coordinates are both top-left, y-down.
        let localRect = CaptureScreenTransform(captureFrame: frame)
            .localRect(fromGlobalRect: CaptureGlobalRect(cropRegion))
            .cgRect
        let pixelX = (localRect.minX * scale).rounded()
        let pixelY = (localRect.minY * scale).rounded()
        let pixelW = (cropRegion.width * scale).rounded()
        let pixelH = (cropRegion.height * scale).rounded()
        let cropRect = CGRect(x: pixelX, y: pixelY, width: pixelW, height: pixelH).integral

        guard let cropped = fullImage.cropping(to: cropRect), cropped.width > 0, cropped.height > 0 else {
            throw ScreenCaptureError.bitmapContextCreationFailed
        }
        return repairTransparentArtifactRows(in: cropped)
    }

    func captureWindow(_ window: CaptureWindowSummary) async throws -> CapturedScreenshot {
        guard CapturePermissionStatus.current().hasScreenRecording else {
            throw ScreenCaptureError.permissionDenied
        }

        let content = try await fetchShareableContent()

        guard let sourceWindow = content.windows.first(where: { $0.windowID == window.id }) else {
            throw ScreenCaptureError.windowImageUnavailable
        }

        let filter = SCContentFilter(desktopIndependentWindow: sourceWindow)
        let configuration = SCScreenshotConfiguration()
        let scale = displayScale(forCaptureFrame: sourceWindow.frame, displays: content.displays)
        configuration.width = max(Int((sourceWindow.frame.width * scale).rounded(.up)), 1)
        configuration.height = max(Int((sourceWindow.frame.height * scale).rounded(.up)), 1)
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        let image = try await captureScreenshot(filter: filter, configuration: configuration)
        let sourceFrame = sourceWindow.frame.gscIntegralStandardized
        let sourceOwnerPID = sourceWindow.owningApplication?.processID ?? window.ownerPID
        let sourceOwnerName = sourceWindow.owningApplication?.applicationName ?? window.ownerName
        let sourceTitle = sourceWindow.title ?? window.title
        let sourceWindowIdentity = CaptureSourceWindowIdentity(
            windowID: sourceWindow.windowID,
            ownerName: sourceOwnerName,
            ownerPID: sourceOwnerPID,
            bundleIdentifier: NSRunningApplication(processIdentifier: sourceOwnerPID)?.bundleIdentifier,
            title: sourceTitle,
            frame: sourceFrame
        )

        return CapturedScreenshot(
            image: image,
            kind: .window,
            sourceName: CaptureWindowSummary(
                id: sourceWindow.windowID,
                ownerName: sourceOwnerName,
                ownerPID: sourceOwnerPID,
                title: sourceTitle,
                frame: sourceFrame,
                layer: sourceWindow.windowLayer,
                focusRank: window.focusRank,
                thumbnail: nil
            ).displayTitle,
            sourceRect: sourceFrame,
            sourceWindowIdentity: sourceWindowIdentity,
            capturedAt: Date()
        )
    }

    private func captureDisplaySnapshots() async throws -> [DisplaySnapshot] {
        guard CapturePermissionStatus.current().hasScreenRecording else {
            throw ScreenCaptureError.permissionDenied
        }

        let content = try await fetchShareableContent()
        let displays = makeDisplaySnapshots(from: content.displays)

        guard !displays.isEmpty else {
            throw ScreenCaptureError.noDisplays
        }

        return displays
    }

    private func fetchShareableContent() async throws -> SCShareableContent {
        let result: ShareableContentResult = try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let content else {
                    continuation.resume(throwing: ScreenCaptureError.noDisplays)
                    return
                }

                continuation.resume(returning: ShareableContentResult(content: content))
            }
        }
        return result.content
    }

    nonisolated func directDisplayCaptureRequest(for region: CGRect, displays: [DisplaySnapshot]) -> DirectDisplayCaptureRequest? {
        let normalizedRegion = region.gscIntegralStandardized
        guard normalizedRegion.width > 2, normalizedRegion.height > 2 else {
            return nil
        }

        guard let display = displays.first(where: { $0.frame.gscIntegralStandardized.contains(normalizedRegion) }) else {
            return nil
        }

        let sourceRect = CaptureScreenTransform(captureFrame: display.frame)
            .localRect(fromGlobalRect: CaptureGlobalRect(normalizedRegion))

        return DirectDisplayCaptureRequest(
            displayID: display.displayID,
            sourceRect: sourceRect,
            outputSize: CGSize(
                width: normalizedRegion.width * display.scale,
                height: normalizedRegion.height * display.scale
            )
        )
    }

    nonisolated func regionCapturePlan(
        for region: CGRect,
        displays: [DisplaySnapshot],
        requiresSingleDisplay: Bool
    ) -> RegionCapturePlan {
        let normalizedRegion = region.gscIntegralStandardized
        guard normalizedRegion.width > 2, normalizedRegion.height > 2 else {
            return .rejectedSingleDisplay
        }

        if requiresSingleDisplay {
            guard let request = directDisplayCaptureRequest(for: normalizedRegion, displays: displays) else {
                return .rejectedSingleDisplay
            }
            return .filteredDisplay(request)
        }

        return .screenRect(rect: normalizedRegion, scale: captureScale(for: normalizedRegion, displays: displays))
    }

    private func makeDisplayCaptureFilter(for display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let processID = ProcessInfo.processInfo.processIdentifier
        let excludedApplications = content.applications.filter { $0.processID == processID }
        if excludedApplications.isEmpty {
            let excludedWindows = content.windows.filter { $0.owningApplication?.processID == processID }
            return SCContentFilter(display: display, excludingWindows: excludedWindows)
        } else {
            return SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
        }
    }

    private func debugCapturePlan(
        strategy: String,
        region: CGRect,
        displays: [DisplaySnapshot],
        request: DirectDisplayCaptureRequest? = nil
    ) {
        #if DEBUG
        let displayInventory = displays.map {
            "id=\($0.displayID) quartz=\($0.frame) appKit=\($0.overlayFrame) scale=\($0.scale)"
        }.joined(separator: " | ")
        let requestDescription = request.map {
            " displayID=\($0.displayID) localSourceRect=\($0.sourceRect.cgRect) outputSize=\($0.outputSize)"
        } ?? ""
        CapturePlanDiagnostics.log("[CapturePlan] strategy=\(strategy) region=\(region)\(requestDescription) displays=[\(displayInventory)]")
        #endif
    }

    private func captureScreenshot(in rect: CGRect, scale: CGFloat) async throws -> CGImage {
        let configuration = SCScreenshotConfiguration()
        configuration.width = max(Int((rect.width * scale).rounded(.up)), 1)
        configuration.height = max(Int((rect.height * scale).rounded(.up)), 1)
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
            SCScreenshotManager.captureScreenshot(rect: rect, configuration: configuration) { output, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let image = output?.sdrImage else {
                    continuation.resume(throwing: ScreenCaptureError.bitmapContextCreationFailed)
                    return
                }

                continuation.resume(returning: self.repairTransparentArtifactRows(in: image))
            }
        }
    }

    private func captureScreenshot(
        filter: SCContentFilter,
        sourceRect: DisplayLocalRect,
        outputSize: CGSize
    ) async throws -> CGImage {
        let configuration = SCScreenshotConfiguration()
        configuration.width = max(Int(outputSize.width.rounded(.up)), 1)
        configuration.height = max(Int(outputSize.height.rounded(.up)), 1)
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        configuration.sourceRect = sourceRect.cgRect
        configuration.ignoreShadows = true
        configuration.ignoreClipping = true

        let image = try await captureScreenshot(filter: filter, configuration: configuration)
        return repairTransparentArtifactRows(in: image)
    }

    nonisolated func repairTransparentArtifactRows(in image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        guard width > 0,
              height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return image
        }

        var rgba = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let alphaThreshold: UInt8 = 1
        let maxRepairRunLength = 8
        var transparentRows = [Bool](repeating: false, count: height)
        var hasTransparentRows = false

        for row in 0..<height {
            let rowOffset = row * bytesPerRow
            var isTransparent = true

            for column in 0..<width {
                if rgba[rowOffset + (column * bytesPerPixel) + 3] > alphaThreshold {
                    isTransparent = false
                    break
                }
            }

            transparentRows[row] = isTransparent
            hasTransparentRows = hasTransparentRows || isTransparent
        }

        guard hasTransparentRows else {
            return image
        }

        var repaired = false
        var rowIndex = 0

        while rowIndex < height {
            guard transparentRows[rowIndex] else {
                rowIndex += 1
                continue
            }

            let startRow = rowIndex
            while rowIndex < height, transparentRows[rowIndex] {
                rowIndex += 1
            }

            let endRow = rowIndex - 1
            let runLength = endRow - startRow + 1
            guard runLength <= maxRepairRunLength,
                  let donorRow = donorRowIndex(
                    before: startRow,
                    after: endRow,
                    transparentRows: transparentRows
                  ) else {
                continue
            }

            let donorStart = donorRow * bytesPerRow
            let donorBytes = Array(rgba[donorStart..<(donorStart + bytesPerRow)])
            for repairedRow in startRow...endRow {
                let targetStart = repairedRow * bytesPerRow
                rgba.replaceSubrange(targetStart..<(targetStart + bytesPerRow), with: donorBytes)
            }
            repaired = true
        }

        guard repaired,
              let provider = CGDataProvider(data: Data(rgba) as CFData) else {
            return image
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) ?? image
    }

    nonisolated private func donorRowIndex(before startRow: Int, after endRow: Int, transparentRows: [Bool]) -> Int? {
        if startRow > 0, !transparentRows[startRow - 1] {
            return startRow - 1
        }

        let nextRow = endRow + 1
        if nextRow < transparentRows.count, !transparentRows[nextRow] {
            return nextRow
        }

        return nil
    }

    private func captureScreenshot(filter: SCContentFilter, configuration: SCScreenshotConfiguration) async throws -> CGImage {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
            SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration) { output, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let image = output?.sdrImage else {
                    continuation.resume(throwing: ScreenCaptureError.windowImageUnavailable)
                    return
                }

                continuation.resume(returning: image)
            }
        }
    }

    private func captureThumbnail(for window: SCWindow, scale: CGFloat) async throws -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCScreenshotConfiguration()
        let maxThumbnailSize = CGSize(width: 320, height: 200)
        let widthScale = maxThumbnailSize.width / max(window.frame.width, 1)
        let heightScale = maxThumbnailSize.height / max(window.frame.height, 1)
        let thumbnailScale = min(widthScale, heightScale, 1)

        configuration.width = max(Int((window.frame.width * scale * thumbnailScale).rounded(.up)), 1)
        configuration.height = max(Int((window.frame.height * scale * thumbnailScale).rounded(.up)), 1)
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr

        return try await captureScreenshot(filter: filter, configuration: configuration)
    }

    private func captureDisplayPreviews(from displays: [DisplaySnapshot]) async throws -> [DisplayPreview] {
        try await withThrowingTaskGroup(of: IndexedDisplayPreview.self) { group in
            for (index, display) in displays.enumerated() {
                group.addTask {
                    let image = try await captureScreenshot(in: display.frame, scale: display.scale)
                    return IndexedDisplayPreview(index: index, preview: DisplayPreview(snapshot: display, image: image))
                }
            }

            var previews: [IndexedDisplayPreview] = []

            for try await preview in group {
                previews.append(preview)
            }

            return previews
                .sorted { $0.index < $1.index }
                .map(\.preview)
        }
    }

    nonisolated func buildRegionImage(from displayPreviews: [DisplayPreview], region: CGRect) throws -> CGImage {
        let normalizedRegion = region.gscIntegralStandardized
        let intersectingPreviews = displayPreviews.filter { $0.snapshot.frame.intersects(normalizedRegion) }

        guard !intersectingPreviews.isEmpty else {
            throw ScreenCaptureError.invalidRegion
        }

        let outputScale = max(intersectingPreviews.map(\.snapshot.scale).max() ?? 1, 1)
        let pixelWidth = max(Int((normalizedRegion.width * outputScale).rounded(.up)), 1)
        let pixelHeight = max(Int((normalizedRegion.height * outputScale).rounded(.up)), 1)

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenCaptureError.bitmapContextCreationFailed
        }

        context.interpolationQuality = .high

        for displayPreview in intersectingPreviews {
            let intersection = displayPreview.snapshot.frame.intersection(normalizedRegion).gscIntegralStandardized

            guard intersection.width > 0, intersection.height > 0 else {
                continue
            }

            let sourceRect = displayPreview.capturePreviewTransform.previewTopLeftPixelRect(fromCaptureGlobalRect: intersection)
            let destinationRect = CompositeCaptureDrawTransform(
                captureUnionFrame: normalizedRegion,
                outputScale: outputScale
            ).destinationRect(fromCaptureGlobalRect: intersection)

            guard let cropped = displayPreview.image.gscCropped(topLeftPixelRect: sourceRect) else {
                continue
            }

            context.draw(cropped, in: destinationRect)
        }

        guard let image = context.makeImage() else {
            throw ScreenCaptureError.bitmapContextCreationFailed
        }

        return image
    }

    nonisolated private func buildDesktopPreview(from displayPreviews: [DisplayPreview], globalFrame: CGRect) throws -> CGImage {
        let previewScale = max(displayPreviews.map(\.snapshot.scale).max() ?? 1, 1)
        let pixelWidth = max(Int((globalFrame.width * previewScale).rounded(.up)), 1)
        let pixelHeight = max(Int((globalFrame.height * previewScale).rounded(.up)), 1)

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenCaptureError.bitmapContextCreationFailed
        }

        context.interpolationQuality = .high

        for displayPreview in displayPreviews {
            let drawRect = CompositeCaptureDrawTransform(
                captureUnionFrame: globalFrame,
                outputScale: previewScale
            ).destinationRect(fromCaptureGlobalRect: displayPreview.snapshot.frame)
            context.draw(displayPreview.image, in: drawRect)
        }

        guard let image = context.makeImage() else {
            throw ScreenCaptureError.bitmapContextCreationFailed
        }

        return image
    }

    private func windowFocusOrder() -> [CGWindowID: Int] {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var ordering: [CGWindowID: Int] = [:]

        for (index, info) in windowInfo.enumerated() {
            guard let windowNumber = info[kCGWindowNumber as String] as? NSNumber else {
                continue
            }

            ordering[CGWindowID(windowNumber.uint32Value)] = index
        }

        return ordering
    }

    private func displayName(for displayID: CGDirectDisplayID) -> String {
        NSScreen.screens.first(where: { $0.gscDisplayID == displayID })?.gscDisplayName ?? "Display"
    }

    private func makeDisplaySnapshots(from displays: [SCDisplay]) -> [DisplaySnapshot] {
        displays.compactMap { display -> DisplaySnapshot? in
            let screen = NSScreen.screens.first(where: { $0.gscDisplayID == display.displayID })

            return DisplaySnapshot(
                displayID: display.displayID,
                name: screen?.gscDisplayName ?? displayName(for: display.displayID),
                frame: display.frame,
                overlayFrame: screen?.frame,
                scale: screen?.backingScaleFactor ?? displayScale(for: display.frame, displayID: display.displayID)
            )
        }
    }

    private func currentDisplay(from displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        let preferredDisplayID = NSApp.keyWindow?.screen?.gscDisplayID
            ?? NSApp.mainWindow?.screen?.gscDisplayID
            ?? NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized })?.screen?.gscDisplayID

        let mouseLocation = NSEvent.mouseLocation

        return currentDisplay(
            from: displays,
            preferredDisplayID: preferredDisplayID,
            preferredPoint: mouseLocation
        )
    }

    nonisolated func currentDisplay(
        from displays: [DisplaySnapshot],
        preferredDisplayID: CGDirectDisplayID?,
        preferredPoint: CGPoint?
    ) -> DisplaySnapshot? {
        if let preferredPoint,
           let matchingDisplay = displays.first(where: { $0.overlayFrame.contains(preferredPoint) }) {
            return matchingDisplay
        }

        if let preferredDisplayID,
           let matchingDisplay = displays.first(where: { $0.displayID == preferredDisplayID }) {
            return matchingDisplay
        }

        return displays.first
    }

    nonisolated func fullscreenDisplay(
        mode: ScreenshotFullscreenDisplayMode,
        selectedDisplayID: CGDirectDisplayID?,
        displays: [DisplaySnapshot],
        preferredDisplayID: CGDirectDisplayID?,
        preferredPoint: CGPoint?
    ) -> DisplaySnapshot? {
        switch mode {
        case .currentDisplay, .allDisplays:
            return currentDisplay(
                from: displays,
                preferredDisplayID: preferredDisplayID,
                preferredPoint: preferredPoint
            )
        case .selectedDisplay:
            return displays.first { $0.displayID == selectedDisplayID }
                ?? currentDisplay(
                    from: displays,
                    preferredDisplayID: preferredDisplayID,
                    preferredPoint: preferredPoint
                )
        }
    }

    private func desktopFrame(for displays: [DisplaySnapshot]) -> CGRect {
        displays.reduce(CGRect.null) { partial, display in
            partial.union(display.frame)
        }.integral
    }

    nonisolated private func fullscreenSourceName(for displays: [DisplaySnapshot]) -> String {
        displays.count == 1 ? (displays.first?.name ?? "Display") : "All Displays"
    }

    nonisolated private func captureScale(for frame: CGRect, displays: [DisplaySnapshot]) -> CGFloat {
        let intersectingScales = displays.compactMap { display -> CGFloat? in
            display.frame.intersects(frame) ? display.scale : nil
        }

        return max(intersectingScales.max() ?? 1, 1)
    }

    private func displayScale(forCaptureFrame frame: CGRect, displays: [SCDisplay]) -> CGFloat {
        let displayIDs = displays
            .filter { $0.frame.intersects(frame) }
            .map(\.displayID)

        let scales = displayIDs.compactMap { displayID in
            NSScreen.screens.first(where: { $0.gscDisplayID == displayID })?.backingScaleFactor
        }

        return max(scales.max() ?? 2, 1)
    }

    private func displayScale(for _: CGRect, displayID: CGDirectDisplayID? = nil) -> CGFloat {
        if let displayID,
           let scale = NSScreen.screens.first(where: { $0.gscDisplayID == displayID })?.backingScaleFactor {
            return scale
        }

        return 2
    }
}

nonisolated private struct ShareableContentResult: @unchecked Sendable {
    let content: SCShareableContent
}

private struct WindowCaptureCandidate: @unchecked Sendable {
    let window: SCWindow
    let id: CGWindowID
    let ownerName: String
    let ownerPID: pid_t
    let title: String
    let frame: CGRect
    let layer: Int
    let focusRank: Int
    let scale: CGFloat

    nonisolated func summary(thumbnail: CGImage?) -> CaptureWindowSummary {
        CaptureWindowSummary(
            id: id,
            ownerName: ownerName,
            ownerPID: ownerPID,
            title: title,
            frame: frame,
            layer: layer,
            focusRank: focusRank,
            thumbnail: thumbnail
        )
    }
}

private struct IndexedDisplayPreview: @unchecked Sendable {
    let index: Int
    let preview: DisplayPreview
}

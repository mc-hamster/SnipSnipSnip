import CoreGraphics
import Foundation
import OSLog

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
    let permissions: any CapturePermissionServicing
    let platform: any ScreenCapturePlatform
    let workspace: any WorkspaceServicing
    let screens: any ScreenTopologyProviding
    let mouse: any MouseLocationProviding
    let windowFocus: any ApplicationWindowFocusProviding
    let clock: any ClockProviding

    nonisolated init(
        permissions: any CapturePermissionServicing,
        platform: any ScreenCapturePlatform,
        workspace: any WorkspaceServicing,
        screens: any ScreenTopologyProviding,
        mouse: any MouseLocationProviding,
        windowFocus: any ApplicationWindowFocusProviding,
        clock: any ClockProviding
    ) {
        self.permissions = permissions
        self.platform = platform
        self.workspace = workspace
        self.screens = screens
        self.mouse = mouse
        self.windowFocus = windowFocus
        self.clock = clock
    }

    func listWindows(excluding processID: pid_t = ProcessInfo.processInfo.processIdentifier, includeThumbnails: Bool = true) async throws -> [CaptureWindowSummary] {
        guard permissions.currentStatus().hasScreenRecording else {
            throw ScreenCaptureError.permissionDenied
        }

        let content = try await fetchShareableContent()
        let focusOrder = windowFocusOrder()

        let displays = content.displays
        let candidates = content.windows.compactMap { window -> WindowCaptureCandidate? in
            let scale = gscDisplayScale(
                forCaptureFrame: window.frame,
                displays: displays,
                fallbackScale: 2
            )

            guard window.ownerPID != processID else {
                return nil
            }

            guard window.layer == 0, window.frame.width >= 60, window.frame.height >= 40, window.isOnScreen else {
                return nil
            }

            return WindowCaptureCandidate(
                window: window,
                id: window.id,
                ownerName: window.ownerName,
                ownerPID: window.ownerPID,
                title: window.title,
                frame: window.frame,
                layer: window.layer,
                focusRank: focusOrder[window.id] ?? Int.max,
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
        let windows = try await listWindows(excluding: processID, includeThumbnails: false)
        let frontmostOwnerPID = workspace.frontmostApplicationProcessIdentifier

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
        let windows = try await listWindows(excluding: processID, includeThumbnails: false)

        guard let resolved = gscBestWindowMatch(
            for: window,
            in: windows,
            frontmostOwnerPID: workspace.frontmostApplicationProcessIdentifier
        ) else {
            throw ScreenCaptureError.noWindowsAvailable
        }

        return resolved
    }

    func captureCurrentDisplay() async throws -> CapturedScreenshot {
        let displays = try await captureDisplaySnapshots()
        guard let display = await currentDisplay(from: displays) else {
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
            capturedAt: clock.now()
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
            capturedAt: clock.now()
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
        let displays = content.displays
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
            capturedAt: clock.now()
        )
    }

    func captureRegionWithinSingleDisplayDirect(in selection: CGRect) async throws -> CapturedScreenshot {
        let region = selection.gscIntegralStandardized
        guard region.width > 2, region.height > 2 else {
            throw ScreenCaptureError.invalidRegion
        }

        let content = try await fetchShareableContent()
        let displays = content.displays
        guard case let .filteredDisplay(request) = regionCapturePlan(
            for: region,
            displays: displays,
            requiresSingleDisplay: true
        ),
              let displaySnapshot = displays.first(where: { $0.displayID == request.displayID }) else {
            throw ScreenCaptureError.regionSpansMultipleDisplays
        }

        debugCapturePlan(strategy: "filtered-display-local", region: region, displays: displays, request: request)
        let image = try await captureDisplayRegion(
            displaySnapshot: displaySnapshot,
            cropRegion: region,
            primaryRequest: request
        )

        return CapturedScreenshot(
            image: image,
            kind: .region,
            sourceName: "Region",
            sourceRect: region,
            capturedAt: clock.now()
        )
    }

    /// Captures a region within a single display. Tries the `sourceRect` path first (fastest),
    /// then falls back to capturing the full display and cropping. The full-display path avoids a
    /// known capture backend failure where source-rect capture can fail on secondary displays.
    private func captureDisplayRegion(
        displaySnapshot: DisplaySnapshot,
        cropRegion: CGRect,
        primaryRequest: DirectDisplayCaptureRequest
    ) async throws -> CGImage {
        do {
            return try await captureScreenshot(
                target: .display(primaryRequest.displayID, excludingProcessID: ProcessInfo.processInfo.processIdentifier),
                sourceRect: primaryRequest.sourceRect,
                outputSize: primaryRequest.outputSize
            )
        } catch {
            return try await captureFullDisplayAndCrop(
                display: displaySnapshot,
                cropRegion: cropRegion
            )
        }
    }

    /// Captures the entire display using a content filter (no `sourceRect`), then crops to the
    /// requested region. Used when setting `sourceRect` on the configuration causes SCKit to fail.
    private func captureFullDisplayAndCrop(
        display: DisplaySnapshot,
        cropRegion: CGRect
    ) async throws -> CGImage {
        let scale = display.scale
        let frame = display.frame
        let fullW = max(Int((frame.width * scale).rounded(.up)), 1)
        let fullH = max(Int((frame.height * scale).rounded(.up)), 1)

        let fullImage = try await platform.captureScreenshot(
            ScreenCaptureRequest(
                target: .display(display.displayID, excludingProcessID: ProcessInfo.processInfo.processIdentifier),
                configuration: ScreenCaptureConfiguration(width: fullW, height: fullH)
            )
        )

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
        guard permissions.currentStatus().hasScreenRecording else {
            throw ScreenCaptureError.permissionDenied
        }

        let content = try await fetchShareableContent()

        guard let sourceWindow = content.windows.first(where: { $0.id == window.id }) else {
            throw ScreenCaptureError.windowImageUnavailable
        }

        let scale = gscDisplayScale(
            forCaptureFrame: sourceWindow.frame,
            displays: content.displays,
            fallbackScale: 2
        )
        let image = try await platform.captureScreenshot(
            ScreenCaptureRequest(
                target: .window(sourceWindow.id),
                configuration: ScreenCaptureConfiguration(
                    width: max(Int((sourceWindow.frame.width * scale).rounded(.up)), 1),
                    height: max(Int((sourceWindow.frame.height * scale).rounded(.up)), 1),
                    ignoreShadows: true,
                    ignoreClipping: true
                )
            )
        )
        let sourceFrame = sourceWindow.frame.gscIntegralStandardized
        let sourceOwnerPID = sourceWindow.ownerPID
        let sourceOwnerName = sourceWindow.ownerName
        let sourceTitle = sourceWindow.title
        let sourceWindowIdentity = CaptureSourceWindowIdentity(
            windowID: sourceWindow.id,
            ownerName: sourceOwnerName,
            ownerPID: sourceOwnerPID,
            bundleIdentifier: sourceWindow.bundleIdentifier,
            title: sourceTitle,
            frame: sourceFrame
        )

        return CapturedScreenshot(
            image: image,
            kind: .window,
            sourceName: CaptureWindowSummary(
                id: sourceWindow.id,
                ownerName: sourceOwnerName,
                ownerPID: sourceOwnerPID,
                title: sourceTitle,
                frame: sourceFrame,
                layer: sourceWindow.layer,
                focusRank: window.focusRank,
                thumbnail: nil
            ).displayTitle,
            sourceRect: sourceFrame,
            sourceWindowIdentity: sourceWindowIdentity,
            capturedAt: clock.now()
        )
    }

    private func captureDisplaySnapshots() async throws -> [DisplaySnapshot] {
        guard permissions.currentStatus().hasScreenRecording else {
            throw ScreenCaptureError.permissionDenied
        }

        let content = try await fetchShareableContent()
        let displays = content.displays

        guard !displays.isEmpty else {
            throw ScreenCaptureError.noDisplays
        }

        return displays
    }

    private func fetchShareableContent() async throws -> ScreenContentSnapshot {
        let content = try await platform.shareableContent()
        return content.resolvingDisplayMetadata(using: screens)
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

        return .screenRect(
            rect: normalizedRegion,
            scale: gscDisplayScale(
                forCaptureFrame: normalizedRegion,
                displays: displays,
                fallbackScale: 1
            )
        )
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
        let image = try await platform.captureScreenshot(
            ScreenCaptureRequest(
                target: .screenRect(rect),
                configuration: ScreenCaptureConfiguration(
                    width: max(Int((rect.width * scale).rounded(.up)), 1),
                    height: max(Int((rect.height * scale).rounded(.up)), 1)
                )
            )
        )
        return repairTransparentArtifactRows(in: image)
    }

    private func captureScreenshot(
        target: ScreenCaptureTarget,
        sourceRect: DisplayLocalRect,
        outputSize: CGSize
    ) async throws -> CGImage {
        let image = try await platform.captureScreenshot(
            ScreenCaptureRequest(
                target: target,
                configuration: ScreenCaptureConfiguration(
                    width: max(Int(outputSize.width.rounded(.up)), 1),
                    height: max(Int(outputSize.height.rounded(.up)), 1),
                    sourceRect: sourceRect.cgRect,
                    ignoreShadows: true,
                    ignoreClipping: true
                )
            )
        )
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

    private func captureThumbnail(for window: ScreenWindowSnapshot, scale: CGFloat) async throws -> CGImage? {
        let maxThumbnailSize = CGSize(width: 320, height: 200)
        let widthScale = maxThumbnailSize.width / max(window.frame.width, 1)
        let heightScale = maxThumbnailSize.height / max(window.frame.height, 1)
        let thumbnailScale = min(widthScale, heightScale, 1)

        return try await platform.captureScreenshot(
            ScreenCaptureRequest(
                target: .window(window.id),
                configuration: ScreenCaptureConfiguration(
                    width: max(Int((window.frame.width * scale * thumbnailScale).rounded(.up)), 1),
                    height: max(Int((window.frame.height * scale * thumbnailScale).rounded(.up)), 1)
                )
            )
        )
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

    private func currentDisplay(from displays: [DisplaySnapshot]) async -> DisplaySnapshot? {
        let preferredDisplayID = await windowFocus.preferredDisplayID()
        return currentDisplay(
            from: displays,
            preferredDisplayID: preferredDisplayID,
            preferredPoint: mouse.appKitGlobalLocation
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
}

private struct WindowCaptureCandidate: @unchecked Sendable {
    let window: ScreenWindowSnapshot
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

import AppKit
import Foundation

@MainActor
extension CaptureWorkflowModel {
    func capturePresetRegion(
        presetID: CapturePreset.ID,
        savedRegion: SavedCaptureRegion,
        options: CaptureRunOptions,
        captureContext: CaptureCompletionContext
    ) {
        Task {
            defer { resetPreparedCaptureContext(ifMatching: captureContext) }
            guard ensureScreenshotCaptureAccess(for: .region(savedRegion.rect), runOptions: options) else {
                return
            }

            let isPrivateCapture = beginCapturePrivacyLock(
                latchedPrivateCapture:
                    captureContext.oneShotOptions?.privateCapture
                    ?? privateCaptureEnabled
            )
            defer { endCapturePrivacyLock() }
            let hiddenWindow = hideAppWindowIfNeeded(
                for: captureContext.presentationContext
            )
            defer { restoreAppWindowIfNeeded(hiddenWindow) }

            if hiddenWindow != nil {
                try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)
            }

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage("Capture Preset")
            defer { isWorking = false }

            do {
                let snapshot = try await captureService.captureDesktopOverlaySnapshot()
                guard isSavedRegionAvailable(savedRegion.rect, in: snapshot) else {
                    isWorking = false
                    beginPresetRegionFallback(
                        presetID: presetID,
                        savedRegion: savedRegion,
                        options: options,
                        captureContext: captureContext
                    )
                    return
                }

                try await runCaptureDelayIfNeeded(actionName: "Capture Preset", delay: options.captureDelay)
                let capture: CapturedScreenshot
                do {
                    capture = try await captureService.captureRegionDirect(in: savedRegion.rect)
                } catch {
                    let fallbackSnapshot = try await captureService.captureDesktopOverlaySnapshot()
                    capture = try await captureService.captureRegion(from: fallbackSnapshot, selection: savedRegion.rect)
                }

                try completeCapture(
                    capture,
                    request: .region(capture.sourceRect),
                    isPrivateCapture: isPrivateCapture,
                    runOptions: options,
                    completionContext: captureContext
                )
            } catch {
                present(
                    error,
                    recovering: nil,
                    captureContext: captureContext
                )
            }
        }
    }

    private func beginPresetRegionFallback(
        presetID: CapturePreset.ID,
        savedRegion: SavedCaptureRegion,
        options: CaptureRunOptions,
        captureContext: CaptureCompletionContext
    ) {
        Task {
            defer {
                resetPreparedCaptureContext(ifMatching: captureContext)
            }
            guard ensureScreenshotCaptureAccess(for: .region(savedRegion.rect), runOptions: options) else {
                return
            }

            let isPrivateCapture = beginCapturePrivacyLock(
                latchedPrivateCapture:
                    captureContext.oneShotOptions?.privateCapture
                    ?? privateCaptureEnabled
            )
            defer { endCapturePrivacyLock() }
            let autosaveSuspension = suspendEditorAutosaveForInteractiveCapture()
            defer { resumeEditorAutosaveAfterInteractiveCapture(autosaveSuspension) }
            let hiddenWindow = hideAppWindowIfNeeded(
                for: captureContext.presentationContext
            )
            defer { restoreAppWindowIfNeeded(hiddenWindow) }

            if hiddenWindow != nil {
                try? await dependencies.systemServices.scheduler.sleep(nanoseconds: 200_000_000)
            }

            isWorking = true
            dependencies.lifecycle.updateWorkingMessage("Reposition Preset")
            defer { isWorking = false }

            do {
                let snapshot = try await captureService.captureDesktopOverlaySnapshot()
                let initialRect = fallbackRegionRect(for: savedRegion, in: snapshot)
                var fallbackPreferences = options.regionPreferences
                fallbackPreferences.showsActionControls = true
                fallbackPreferences.advancedControlsEnabled = true
                let session = RegionSelectionSession(
                    snapshot: snapshot,
                    preferences: fallbackPreferences,
                    initialSelectionRect: initialRect,
                    livePreviewCapturePlatform: dependencies.systemServices.screenCapturePlatform
                )

                guard let selection = await session.begin() else {
                    resetPreparedCaptureContext(ifMatching: captureContext)
                    return
                }

                guard case let .region(region, cursorCaptureGlobalLocation) = selection else {
                    return
                }

                try await runCaptureDelayIfNeeded(actionName: "Capture Preset", delay: options.captureDelay)
                let capture: CapturedScreenshot
                do {
                    capture = try await captureService.captureRegionDirect(in: region)
                } catch {
                    let fallbackSnapshot = try await captureService.captureDesktopOverlaySnapshot()
                    capture = try await captureService.captureRegion(from: fallbackSnapshot, selection: region)
                }

                updateRegionTarget(forPresetID: presetID, rect: capture.sourceRect)
                try completeCapture(
                    capture,
                    request: .region(capture.sourceRect),
                    isPrivateCapture: isPrivateCapture,
                    cursorCaptureGlobalLocation: cursorCaptureGlobalLocation,
                    runOptions: options,
                    completionContext: captureContext
                )
            } catch {
                present(
                    error,
                    recovering: nil,
                    captureContext: captureContext
                )
            }
        }
    }

    private func updateRegionTarget(forPresetID presetID: CapturePreset.ID, rect: CGRect) {
        guard let index = capturePresets.firstIndex(where: { $0.id == presetID }) else {
            return
        }

        var preset = capturePresets[index]
        preset.target = .region(savedCaptureRegion(for: rect))
        preset.updatedAt = dependencies.systemServices.clock.now()
        capturePresets[index] = preset
    }

    private func isSavedRegionAvailable(_ rect: CGRect, in snapshot: DesktopCompositeSnapshot) -> Bool {
        let region = rect.gscIntegralStandardized
        guard region.width > 2,
              region.height > 2,
              snapshot.globalFrame.contains(region) else {
            return false
        }

        let coveredArea = snapshot.displays.reduce(CGFloat.zero) { partial, display in
            partial + rectArea(display.frame.intersection(region))
        }

        return coveredArea >= max(rectArea(region) - 0.5, 0)
    }

    private func rectArea(_ rect: CGRect) -> CGFloat {
        let standardized = rect.gscIntegralStandardized
        guard !standardized.isNull else {
            return 0
        }

        return max(standardized.width, 0) * max(standardized.height, 0)
    }

    private func fallbackRegionRect(
        for savedRegion: SavedCaptureRegion,
        in snapshot: DesktopCompositeSnapshot
    ) -> CGRect {
        let display = currentPresetFallbackDisplay(in: snapshot, preferredID: savedRegion.displayID)
        let size = CGSize(
            width: min(max(savedRegion.rect.width, RegionPrecisionGeometry.minimumDimension), display.frame.width),
            height: min(max(savedRegion.rect.height, RegionPrecisionGeometry.minimumDimension), display.frame.height)
        )
        let origin = CGPoint(
            x: display.frame.midX - size.width / 2,
            y: display.frame.midY - size.height / 2
        )

        return CGRect(origin: origin, size: size)
            .gscIntegralStandardized
            .gscClamped(to: display.frame)
    }

    private func currentPresetFallbackDisplay(
        in snapshot: DesktopCompositeSnapshot,
        preferredID: CGDirectDisplayID?
    ) -> DisplaySnapshot {
        let currentCapturePoint = CursorCaptureGeometry.captureGlobalPoint(
            fromAppKitGlobalPoint: dependencies.systemServices.mouse.appKitGlobalLocation
        )
        if let currentCapturePoint,
           let display = snapshot.displays.first(where: { $0.frame.contains(currentCapturePoint) }) {
            return display
        }

        if let preferredID,
           let display = snapshot.displays.first(where: { $0.displayID == preferredID }) {
            return display
        }

        return snapshot.displays.first ?? DisplaySnapshot(
            displayID: 0,
            name: "Display",
            frame: CGRect(origin: .zero, size: savedFallbackDisplaySize),
            scale: 1
        )
    }

    private var savedFallbackDisplaySize: CGSize {
        CGSize(width: 800, height: 600)
    }
}

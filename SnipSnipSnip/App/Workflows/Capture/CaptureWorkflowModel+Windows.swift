import Foundation

@MainActor
extension CaptureWorkflowModel {
    func refreshAvailableWindows(
        includeThumbnails: Bool = true,
        allowsCancellingPendingThumbnailRefresh: Bool = true
    ) {
        Task {
            guard !isLoadingWindowChoices else {
                return
            }

            if !allowsCancellingPendingThumbnailRefresh, pendingWindowThumbnailTask != nil {
                return
            }

            await loadAvailableWindows(
                requestAccessIfNeeded: false,
                presentPicker: false,
                showErrors: false,
                includeThumbnails: includeThumbnails,
                allowsCancellingPendingThumbnailRefresh: allowsCancellingPendingThumbnailRefresh
            )
        }
    }

    func refreshAvailableWindowsOrRequestAccess() {
        dependencies.permissions.refreshPermissions()

        guard dependencies.permissions.permissionStatus.hasScreenRecording else {
            dependencies.permissions.requestScreenRecordingAccess()
            return
        }

        refreshAvailableWindows()
    }

    func loadAvailableWindows(
        requestAccessIfNeeded: Bool,
        presentPicker: Bool,
        showErrors: Bool,
        includeThumbnails: Bool,
        allowsCancellingPendingThumbnailRefresh: Bool = true
    ) async {
        if isLoadingWindowChoices {
            if presentPicker {
                isShowingWindowPicker = true
            }

            return
        }

        dependencies.permissions.refreshPermissions()

        guard dependencies.permissions.permissionStatus.hasScreenRecording else {
            availableWindows = []

            if requestAccessIfNeeded {
                dependencies.permissions.requestPermission(.screenRecording)
                dependencies.permissions.refreshPermissions()

                if !dependencies.permissions.permissionStatus.hasScreenRecording {
                    dependencies.lifecycle.clearError()
                    dependencies.lifecycle.requestMainWindowPresentation()
                }
            }

            return
        }

        if allowsCancellingPendingThumbnailRefresh {
            pendingWindowThumbnailTask?.cancel()
            pendingWindowThumbnailTask = nil
        }

        isLoadingWindowChoices = true

        if presentPicker {
            isWorking = true
        }

        defer {
            isLoadingWindowChoices = false

            if presentPicker {
                isWorking = false
            }
        }

        do {
            let shouldStageThumbnails = includeThumbnails && (presentPicker || !availableWindows.isEmpty)
            let windows = try await captureService.listWindows(includeThumbnails: shouldStageThumbnails ? false : includeThumbnails)
            availableWindows = mergedWindowSummaries(windows)
            if includeThumbnails && !shouldStageThumbnails {
                windowThumbnailRefreshGeneration += 1
            }

            if presentPicker {
                isShowingWindowPicker = true
            }

            if shouldStageThumbnails {
                scheduleWindowThumbnailRefresh(showErrors: showErrors)
            }
        } catch {
            if presentPicker {
                availableWindows = []
            }

            if showErrors {
                present(error)
            }
        }
    }

    func scheduleWindowThumbnailRefresh(showErrors: Bool) {
        pendingWindowThumbnailTask?.cancel()

        pendingWindowThumbnailTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                let windows = try await self.captureService.listWindows(includeThumbnails: true)

                guard !Task.isCancelled else {
                    return
                }

                self.availableWindows = self.mergedWindowSummaries(windows)
                self.windowThumbnailRefreshGeneration += 1
                self.pendingWindowThumbnailTask = nil
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                self.pendingWindowThumbnailTask = nil

                if showErrors {
                    self.present(error)
                }
            }
        }
    }

    func mergedWindowSummaries(_ windows: [CaptureWindowSummary]) -> [CaptureWindowSummary] {
        let existingWindows = Dictionary(uniqueKeysWithValues: availableWindows.map { ($0.id, $0) })

        return windows.map { window in
            CaptureWindowSummary(
                id: window.id,
                ownerName: window.ownerName,
                ownerPID: window.ownerPID,
                title: window.title,
                frame: window.frame,
                layer: window.layer,
                focusRank: window.focusRank,
                thumbnail: window.thumbnail ?? existingWindows[window.id]?.thumbnail
            )
        }
    }
}

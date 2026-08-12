#if DEBUG
import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import SwiftUI

/// Debug-only launch support for isolated app-hosted unit and composition UI tests.
///
/// The app still acquires its normal lifetime lock before this support creates
/// an `AppModel`. The launch mode replaces only external capture/permission
/// inputs and stores test state under a run-specific temporary directory.
@MainActor
enum CompositionUITestLaunchSupport {
    static let launchArgument = "--snipsnipsnip-composition-ui-testing"
    static let runIdentifierEnvironmentKey = "SNIPSNIPSNIP_UI_TEST_RUN_ID"
    static let artifactDirectoryEnvironmentKey =
        "SNIPSNIPSNIP_UI_TEST_ARTIFACT_DIRECTORY"

    static let savedDocumentName = "composition-round-trip.sss"
    static let saveReopenMarkerName = "composition-round-trip.complete"
    static let comparisonExportName = "comparison-blink.gif"
    static let comparisonExportMarkerName = "comparison-blink.complete"
    static let comparisonPosterExportName = "comparison-poster.png"
    static let comparisonPosterExportMarkerName =
        "comparison-poster.complete"
    static let stepsPDFExportName = "steps-paginated.pdf"
    static let stepsHTMLExportName = "steps-interactive.html"
    static let stepsExportMarkerName = "steps-export.complete"
    static let addDropMarkerName = "drop-add.complete"
    static let replaceDropMarkerName = "drop-replace.complete"

    private static var nextCaptureOrdinal = 1
    private static var nextRegionCaptureBehavior:
        CompositionUITestRegionCaptureBehavior = .capture

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func makeAppModel() -> AppModel {
        guard isEnabled else {
            if AppModel.isRunningUnitTests {
                return makeUnitTestHostAppModel()
            }
            return AppModel()
        }

        let runIdentifier = sanitizedRunIdentifier(
            ProcessInfo.processInfo.environment[runIdentifierEnvironmentKey]
                ?? UUID().uuidString
        )
        let suiteName = "com.oontz.SnipSnipSnip.UITests.\(runIdentifier)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Unable to create isolated UI-test defaults.")
        }
        defaults.removePersistentDomain(forName: suiteName)

        let preferences = AppPreferenceStores(storage: defaults)
        preferences.lifecycle.saveCompletedOnboardingVersion(
            AppLifecycleConstants.currentOnboardingVersion
        )
        preferences.lifecycle.saveOnboardingResumeCheckpoint(nil)
        preferences.clipboard.saveAutoCopyEnabled(false)
        var clipboardPreferences = ClipboardPreferences.default
        clipboardPreferences.isEnabled = true
        preferences.clipboard.savePreferences(clipboardPreferences)
        preferences.capture.saveAutoRefreshWindowsEnabled(false)
        preferences.capture.saveUIMapEnabled(false)
        preferences.screenTools.saveInspectorPreferences(
            ScreenInspectorPreferences(
                zoomLevel: .eight,
                showsPixelGrid: true,
                showsCrosshair: true
            )
        )

        let permissions = CompositionUITestPermissionService()
        let environment = AppEnvironment(
            defaults: defaults,
            permissions: permissions
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SnipSnipSnip-CompositionUITests-\(runIdentifier)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        if let artifactDirectoryURL {
            try? FileManager.default.createDirectory(
                at: artifactDirectoryURL,
                withIntermediateDirectories: true
            )
        }
        let clipboardHistoryStore = ClipboardHistoryStore(
            baseURL: rootURL.appendingPathComponent("Clipboard", isDirectory: true),
            keyProvider: CompositionUITestClipboardEncryptionKeyProvider(),
            loadStoredHistory: false
        )
        clipboardHistoryStore.activateStorage()
        seedClipboardHistory(
            in: clipboardHistoryStore,
            preferences: clipboardPreferences
        )

        let overrides = AppModelCompositionOverrides(
            recoveryStore: DocumentRecoveryStore(
                baseURL: rootURL.appendingPathComponent("Recovery", isDirectory: true)
            ),
            clipboardHistoryStore: clipboardHistoryStore,
            captureService: CompositionUITestCaptureService(),
            screenInspectorCapturePlatform: CompositionUITestScreenCapturePlatform()
        )
        let model = AppModel(
            defaults: defaults,
            environment: environment,
            compositionOverrides: overrides,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
        model.lifecycle.confirmsBeforeQuitting = false
        return model
    }

    private static func seedClipboardHistory(
        in store: ClipboardHistoryStore,
        preferences: ClipboardPreferences
    ) {
        let now = Date()
        store.recordText(
            "Ship 1.1.3: verify screenshots, release notes, and metadata.",
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes"),
            preferences: preferences,
            copiedAt: now.addingTimeInterval(-300)
        )
        store.recordText(
            "#EF741B",
            sourceApp: ClipboardSourceApp(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode"),
            preferences: preferences,
            copiedAt: now.addingTimeInterval(-240)
        )
        store.recordText(
            "{\"version\":\"1.1.3\",\"build\":156,\"channel\":\"App Store\"}",
            sourceApp: ClipboardSourceApp(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode"),
            preferences: preferences,
            copiedAt: now.addingTimeInterval(-180)
        )
        store.recordLink(
            "https://snipsnipsnip.com",
            title: "SnipSnipSnip",
            searchableText: "SnipSnipSnip product website",
            sourceApp: ClipboardSourceApp(name: "Safari", bundleIdentifier: "com.apple.Safari"),
            preferences: preferences,
            copiedAt: now.addingTimeInterval(-120)
        )
        store.recordFileURLs(
            [URL(fileURLWithPath: "/Users/demo/Desktop/SnipSnipSnip-1.1.3-release-notes.pdf")],
            sourceApp: ClipboardSourceApp(name: "Finder", bundleIdentifier: "com.apple.finder"),
            preferences: preferences,
            copiedAt: now.addingTimeInterval(-60)
        )

        if let pngData = try? ImageExporter.pngData(
            for: CompositionUITestFixture.capture(ordinal: 0).image
        ) {
            store.recordSnip(
                pngData: pngData,
                title: "Release comparison – 1.1.3",
                searchableText: "App Store release comparison 1.1.3",
                sessionID: nil,
                preferences: preferences,
                copiedAt: now
            )
        }

        if let newestItem = store.items.first {
            store.togglePinned(newestItem)
            store.toggleCollection("Launch", for: newestItem)
        }
    }

    private static func makeUnitTestHostAppModel() -> AppModel {
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        let suiteName = "com.oontz.SnipSnipSnip.UnitTestHost.\(processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Unable to create isolated unit-test host defaults.")
        }
        defaults.removePersistentDomain(forName: suiteName)

        let preferences = AppPreferenceStores(storage: defaults)
        preferences.lifecycle.saveCompletedOnboardingVersion(
            AppLifecycleConstants.currentOnboardingVersion
        )
        preferences.clipboard.savePreferences(.default)

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SnipSnipSnip-UnitTestHost-\(processIdentifier)",
                isDirectory: true
            )
        let overrides = AppModelCompositionOverrides(
            recoveryStore: DocumentRecoveryStore(
                baseURL: rootURL.appendingPathComponent(
                    "Recovery",
                    isDirectory: true
                )
            ),
            clipboardHistoryStore: ClipboardHistoryStore(
                baseURL: rootURL.appendingPathComponent(
                    "Clipboard",
                    isDirectory: true
                ),
                loadStoredHistory: false
            )
        )
        return AppModel(
            defaults: defaults,
            compositionOverrides: overrides,
            shouldCheckCompatibilityOnLaunch: false,
            shouldStartArchiveMaintenance: false
        )
    }

    static func installInitialDocumentIfNeeded(in model: AppModel) {
        guard isEnabled, model.documents.editorController == nil else {
            return
        }

        nextCaptureOrdinal = 1
        nextRegionCaptureBehavior = .capture
        let capture = CompositionUITestFixture.capture(ordinal: 0)
        let controller = EditorController(
            capture: capture,
            defaults: model.environment.defaults,
            capabilities: model.capabilities,
            uiMapOverlayOptions: model.documents.uiMapPinnedOverlayDefaults
        )
        model.documents.installEditorController(
            controller,
            documentURL: nil,
            savedSession: nil,
            shouldCreateRecoverySession: false
        )
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            forceMainWindowFront()
        }
    }

    /// Keeps deterministic UI tests on the active Space. Without this,
    /// macOS can expose an off-Space accessibility tree while sending the
    /// synthesized pointer event to whichever application is actually front.
    static func forceMainWindowFront() {
        guard isEnabled,
              let window = NSApp.windows.first(where: {
                  $0.identifier?.rawValue == AppSceneID.mainWindow
              }) else {
            return
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
    }

    static func consumeRegionCaptureOutcome()
        -> CompositionUITestRegionCaptureOutcome?
    {
        guard isEnabled else {
            return nil
        }

        let behavior = nextRegionCaptureBehavior
        nextRegionCaptureBehavior = .capture
        guard behavior != .cancel else {
            return .cancelled
        }
        let capture = CompositionUITestFixture.capture(
            ordinal: nextCaptureOrdinal
        )
        nextCaptureOrdinal += 1
        switch behavior {
        case .capture:
            return .captured(capture)
        case .cancel:
            return .cancelled
        case .staleDestination:
            return .staleDestination(capture)
        }
    }

    static func cancelNextRegionCapture() {
        guard isEnabled else {
            return
        }
        nextRegionCaptureBehavior = .cancel
    }

    static func makeNextRegionCaptureDestinationStale() {
        guard isEnabled else {
            return
        }
        nextRegionCaptureBehavior = .staleDestination
    }

    static func saveAndReopenComposition(
        in documents: DocumentWorkflowModel
    ) async {
        do {
            guard let originalController = documents.editorController else {
                throw CompositionUITestActionError.noActiveDocument
            }
            let directory = try requiredArtifactDirectory()
            let documentURL = directory.appendingPathComponent(
                savedDocumentName,
                isDirectory: true
            )
            let didSave = await documents.saveDocument(
                originalController,
                to: documentURL
            )
            guard didSave else {
                throw CompositionUITestActionError.saveFailed
            }

            documents.loadDocument(from: documentURL)
            guard let reloadedController = documents.editorController,
                  reloadedController !== originalController,
                  documents.currentDocumentURL?.standardizedFileURL
                    == documentURL.standardizedFileURL else {
                throw CompositionUITestActionError.reopenFailed
            }

            let composition = reloadedController.snapshot.composition
            try writeCompletionMarker(
                named: saveReopenMarkerName,
                value: [
                    "items=\(composition?.items.count ?? 1)",
                    "layout=\(composition?.layout.mode.rawValue ?? "none")",
                    "private=\(reloadedController.isPrivateDocument)",
                ].joined(separator: "\n"),
                in: directory
            )
            reloadedController.showNotice(
                "UI test saved and reopened the editable composition."
            )
        } catch {
            report(action: "Save and reopen", error: error, in: documents)
        }
    }

    static func exportBlinkComparison(
        in documents: DocumentWorkflowModel
    ) async {
        do {
            guard let controller = documents.editorController else {
                throw CompositionUITestActionError.noActiveDocument
            }
            guard controller.supportsAnimatedCompositionOutput else {
                throw CompositionUITestActionError.blinkComparisonRequired
            }

            let directory = try requiredArtifactDirectory()
            let destination = directory.appendingPathComponent(
                comparisonExportName,
                isDirectory: false
            )
            let result = try await controller.exportComposition(
                format: .gif,
                appearance: .plain,
                to: destination
            )
            let byteCount = try FileManager.default
                .attributesOfItem(atPath: destination.path)[.size] as? NSNumber
            guard result.url.standardizedFileURL
                    == destination.standardizedFileURL,
                  (byteCount?.intValue ?? 0) > 0 else {
                throw CompositionUITestActionError.exportFailed
            }

            try writeCompletionMarker(
                named: comparisonExportMarkerName,
                value: "bytes=\(byteCount?.intValue ?? 0)",
                in: directory
            )
            controller.showNotice(
                "UI test exported the Blink comparison as GIF."
            )
        } catch {
            report(action: "Comparison export", error: error, in: documents)
        }
    }

    static func exportComparisonPoster(
        in documents: DocumentWorkflowModel
    ) async {
        do {
            guard let controller = documents.editorController else {
                throw CompositionUITestActionError.noActiveDocument
            }
            guard let composition = controller.snapshot.composition,
                  composition.layout.mode == .compare,
                  composition.comparison.mode == .blink else {
                throw CompositionUITestActionError.blinkComparisonRequired
            }

            let directory = try requiredArtifactDirectory()
            let destination = directory.appendingPathComponent(
                comparisonPosterExportName,
                isDirectory: false
            )
            let result = try await controller.exportComposition(
                format: .png,
                appearance: .plain,
                to: destination
            )
            let byteCount = try fileByteCount(at: destination)
            guard result.url.standardizedFileURL
                    == destination.standardizedFileURL,
                  byteCount > 0 else {
                throw CompositionUITestActionError.exportFailed
            }

            try writeCompletionMarker(
                named: comparisonPosterExportMarkerName,
                value: [
                    "poster=\(composition.comparison.posterFrame.rawValue)",
                    "bytes=\(byteCount)",
                ].joined(separator: "\n"),
                in: directory
            )
            controller.showNotice(
                "UI test exported the selected static comparison poster."
            )
        } catch {
            report(action: "Comparison poster export", error: error, in: documents)
        }
    }

    static func exportStepsOutputs(
        in documents: DocumentWorkflowModel
    ) async {
        do {
            guard let controller = documents.editorController else {
                throw CompositionUITestActionError.noActiveDocument
            }
            guard let composition = controller.snapshot.composition,
                  composition.layout.mode == .steps,
                  composition.steps.itemsPerPage != nil else {
                throw CompositionUITestActionError.paginatedStepsRequired
            }

            let directory = try requiredArtifactDirectory()
            let pdfDestination = directory.appendingPathComponent(
                stepsPDFExportName,
                isDirectory: false
            )
            let htmlDestination = directory.appendingPathComponent(
                stepsHTMLExportName,
                isDirectory: false
            )
            let pdfResult = try await controller.exportComposition(
                format: .pdf,
                appearance: .plain,
                to: pdfDestination
            )
            let htmlResult = try await controller.exportComposition(
                format: .html,
                appearance: .plain,
                to: htmlDestination
            )
            let pdfByteCount = try fileByteCount(at: pdfDestination)
            let htmlByteCount = try fileByteCount(at: htmlDestination)
            guard pdfResult.pageCount > 1,
                  htmlResult.pageCount == 1,
                  pdfByteCount > 0,
                  htmlByteCount > 0 else {
                throw CompositionUITestActionError.exportFailed
            }

            try writeCompletionMarker(
                named: stepsExportMarkerName,
                value: [
                    "pdfPages=\(pdfResult.pageCount)",
                    "pdfBytes=\(pdfByteCount)",
                    "htmlBytes=\(htmlByteCount)",
                ].joined(separator: "\n"),
                in: directory
            )
            controller.showNotice(
                "UI test exported paginated Steps PDF and interactive HTML."
            )
        } catch {
            report(action: "Steps export", error: error, in: documents)
        }
    }

    static func simulateFileDrop(
        replacingSelectedItem: Bool,
        in documents: DocumentWorkflowModel
    ) {
        do {
            guard let controller = documents.editorController,
                  let composition = controller.snapshot.composition else {
                throw CompositionUITestActionError.noActiveDocument
            }
            let directory = try requiredArtifactDirectory()
            let ordinal = nextCaptureOrdinal
            nextCaptureOrdinal += 1
            let stem = replacingSelectedItem
                ? "UI Test Dropped Replacement \(ordinal)"
                : "UI Test Dropped Addition \(ordinal)"
            let sourceURL = directory.appendingPathComponent(
                "\(stem).png",
                isDirectory: false
            )
            let capture = CompositionUITestFixture.capture(ordinal: ordinal)
            try ImageExporter.pngData(for: capture.image).write(
                to: sourceURL,
                options: .atomic
            )

            let destination: CompositionFileDropDestination
            if replacingSelectedItem {
                guard let itemID = composition.selectedItemIDs.last else {
                    throw CompositionUITestActionError.noSelectedItem
                }
                destination = .replace(itemID: itemID)
            } else {
                destination = .insert(
                    afterItemID: composition.selectedItemIDs.last
                )
            }
            let priorCount = composition.items.count
            documents.handleCompositionFileDrop(
                [sourceURL],
                destination: destination
            )
            guard let updated = controller.snapshot.composition else {
                throw CompositionUITestActionError.importFailed
            }
            let expectedCount = replacingSelectedItem
                ? priorCount
                : priorCount + 1
            guard updated.items.count == expectedCount,
                  updated.items.contains(where: { $0.title == stem }) else {
                throw CompositionUITestActionError.importFailed
            }

            let markerName = replacingSelectedItem
                ? replaceDropMarkerName
                : addDropMarkerName
            try writeCompletionMarker(
                named: markerName,
                value: [
                    "items=\(updated.items.count)",
                    "title=\(stem)",
                ].joined(separator: "\n"),
                in: directory
            )
            controller.showNotice(
                replacingSelectedItem
                    ? "UI test replaced the drop target item."
                    : "UI test added the dropped image at the insertion target."
            )
        } catch {
            report(
                action: replacingSelectedItem ? "Drop replace" : "Drop add",
                error: error,
                in: documents
            )
        }
    }

    private static var artifactDirectoryURL: URL? {
        guard isEnabled,
              let path = ProcessInfo.processInfo.environment[
                artifactDirectoryEnvironmentKey
              ],
              !path.isEmpty else {
            return nil
        }
        return URL(
            fileURLWithPath: path,
            isDirectory: true
        ).standardizedFileURL
    }

    private static func requiredArtifactDirectory() throws -> URL {
        guard let artifactDirectoryURL else {
            throw CompositionUITestActionError.missingArtifactDirectory
        }
        try FileManager.default.createDirectory(
            at: artifactDirectoryURL,
            withIntermediateDirectories: true
        )
        return artifactDirectoryURL
    }

    private static func writeCompletionMarker(
        named name: String,
        value: String,
        in directory: URL
    ) throws {
        try Data(value.utf8).write(
            to: directory.appendingPathComponent(name),
            options: .atomic
        )
    }

    private static func fileByteCount(at url: URL) throws -> Int {
        let value = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return value?.intValue ?? 0
    }

    private static func report(
        action: String,
        error: Error,
        in documents: DocumentWorkflowModel
    ) {
        let message = "\(action) failed: \(error.localizedDescription)"
        documents.editorController?.showNotice(message)
        if let directory = artifactDirectoryURL {
            try? Data(message.utf8).write(
                to: directory.appendingPathComponent(
                    "\(action.lowercased().replacingOccurrences(of: " ", with: "-")).failure"
                ),
                options: .atomic
            )
        }
    }

    private static func sanitizedRunIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        let scalars = value.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "-"
        }
        let result = String(scalars).prefix(80)
        return result.isEmpty ? UUID().uuidString : String(result)
    }
}

private enum CompositionUITestActionError: LocalizedError {
    case noActiveDocument
    case missingArtifactDirectory
    case saveFailed
    case reopenFailed
    case blinkComparisonRequired
    case paginatedStepsRequired
    case noSelectedItem
    case importFailed
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noActiveDocument:
            "No screenshot document is open."
        case .missingArtifactDirectory:
            "The UI-test artifact directory was not supplied."
        case .saveFailed:
            "The editable document was not saved."
        case .reopenFailed:
            "The saved document was not reopened."
        case .blinkComparisonRequired:
            "The composition is not configured for Blink comparison."
        case .paginatedStepsRequired:
            "The composition is not configured for paginated Steps."
        case .noSelectedItem:
            "No composition item is selected."
        case .importFailed:
            "The deterministic composition drop was not applied."
        case .exportFailed:
            "The comparison export was not written."
        }
    }
}

@MainActor
struct CompositionUITestCommands: Commands {
    @ObservedObject var documents: DocumentWorkflowModel
    @ObservedObject var capture: CaptureWorkflowModel

    var body: some Commands {
        if CompositionUITestLaunchSupport.isEnabled {
            CommandMenu("UI Testing") {
                Button("Enable Private Capture for UI Test") {
                    capture.updatePrivateCaptureEnabled(true)
                }

                Divider()

                Button("Cancel Next Add Capture for UI Test") {
                    CompositionUITestLaunchSupport.cancelNextRegionCapture()
                }

                Button("Make Next Add Capture Stale for UI Test") {
                    CompositionUITestLaunchSupport
                        .makeNextRegionCaptureDestinationStale()
                }

                Divider()

                Button("Save and Reopen Composition for UI Test") {
                    Task {
                        await CompositionUITestLaunchSupport
                            .saveAndReopenComposition(in: documents)
                    }
                }
                .disabled(documents.editorController == nil)

                Button("Export Blink Comparison for UI Test") {
                    Task {
                        await CompositionUITestLaunchSupport
                            .exportBlinkComparison(in: documents)
                    }
                }
                .disabled(documents.editorController == nil)

                Button("Export Comparison Poster for UI Test") {
                    Task {
                        await CompositionUITestLaunchSupport
                            .exportComparisonPoster(in: documents)
                    }
                }
                .disabled(documents.editorController == nil)

                Button("Export Steps Outputs for UI Test") {
                    Task {
                        await CompositionUITestLaunchSupport
                            .exportStepsOutputs(in: documents)
                    }
                }
                .disabled(documents.editorController == nil)

                Divider()

                Button("Simulate Add-Here Drop for UI Test") {
                    CompositionUITestLaunchSupport.simulateFileDrop(
                        replacingSelectedItem: false,
                        in: documents
                    )
                }
                .disabled(documents.editorController == nil)

                Button("Simulate Replace-Item Drop for UI Test") {
                    CompositionUITestLaunchSupport.simulateFileDrop(
                        replacingSelectedItem: true,
                        in: documents
                    )
                }
                .disabled(documents.editorController == nil)
            }
        }
    }
}

private enum CompositionUITestRegionCaptureBehavior: Equatable {
    case capture
    case cancel
    case staleDestination
}

enum CompositionUITestRegionCaptureOutcome {
    case captured(CapturedScreenshot)
    case cancelled
    case staleDestination(CapturedScreenshot)
}

nonisolated enum CompositionUITestFixture {
    nonisolated static func capture(ordinal: Int) -> CapturedScreenshot {
        let width = ordinal.isMultiple(of: 2) ? 960 : 720
        let height = ordinal.isMultiple(of: 2) ? 600 : 760
        let rect = CGRect(x: 120, y: 80, width: width, height: height)
        return CapturedScreenshot(
            image: image(width: width, height: height, ordinal: ordinal),
            kind: .region,
            sourceName: ordinal == 0
                ? "UI Test Initial"
                : "UI Test Added \(ordinal)",
            sourceRect: rect,
            capturedAt: Date(
                timeIntervalSince1970: 1_700_000_000 + TimeInterval(ordinal)
            )
        )
    }

    nonisolated static func image(
        width: Int,
        height: Int,
        ordinal: Int
    ) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            preconditionFailure("Unable to create deterministic UI-test image.")
        }

        let palettes: [[CGFloat]] = [
            [0.11, 0.25, 0.52, 1.0],
            [0.64, 0.18, 0.20, 1.0],
            [0.10, 0.48, 0.31, 1.0],
        ]
        let accentPalettes: [[CGFloat]] = [
            [0.34, 0.72, 1.00, 1.0],
            [1.00, 0.64, 0.26, 1.0],
            [0.50, 0.88, 0.58, 1.0],
        ]
        let background = palettes[ordinal % palettes.count]
        let accent = accentPalettes[ordinal % accentPalettes.count]

        context.setFillColor(
            red: background[0],
            green: background[1],
            blue: background[2],
            alpha: background[3]
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.setFillColor(
            red: accent[0],
            green: accent[1],
            blue: accent[2],
            alpha: accent[3]
        )
        let inset = CGFloat(min(width, height)) * 0.10
        context.fill(
            CGRect(
                x: inset,
                y: inset,
                width: CGFloat(width) - inset * 2,
                height: CGFloat(height) * 0.15
            )
        )

        context.setFillColor(
            red: 1,
            green: 1,
            blue: 1,
            alpha: 0.84
        )
        for index in 0..<3 {
            let rowY = inset + CGFloat(height) * (0.28 + CGFloat(index) * 0.18)
            context.fill(
                CGRect(
                    x: inset,
                    y: rowY,
                    width: CGFloat(width) * (0.72 - CGFloat(index) * 0.08),
                    height: CGFloat(height) * 0.075
                )
            )
        }

        context.setFillColor(
            red: accent[0],
            green: accent[1],
            blue: accent[2],
            alpha: 0.72
        )
        let badgeSide = CGFloat(min(width, height)) * 0.16
        context.fill(
            CGRect(
                x: CGFloat(width) - inset - badgeSide,
                y: CGFloat(height) - inset - badgeSide,
                width: badgeSide,
                height: badgeSide
            )
        )

        guard let image = context.makeImage() else {
            preconditionFailure("Unable to finish deterministic UI-test image.")
        }
        return image
    }
}

nonisolated private struct CompositionUITestClipboardEncryptionKeyProvider:
    ClipboardEncryptionKeyProviding
{
    func encryptionKey() throws -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 0x53, count: 32))
    }
}

nonisolated private struct CompositionUITestScreenCapturePlatform:
    ScreenCapturePlatform
{
    func shareableContent() async throws -> ScreenContentSnapshot {
        ScreenContentSnapshot(displays: [], windows: [], applications: [])
    }

    func captureScreenshot(_ request: ScreenCaptureRequest) async throws -> CGImage {
        CompositionUITestFixture.image(
            width: request.configuration.width,
            height: request.configuration.height,
            ordinal: 1
        )
    }
}

nonisolated struct CompositionUITestCaptureService: ScreenCaptureServiceType {
    nonisolated func listWindows(
        excluding _: pid_t,
        includeThumbnails _: Bool
    ) async throws -> [CaptureWindowSummary] {
        []
    }

    nonisolated func frontmostWindow(
        excluding _: pid_t
    ) async throws -> CaptureWindowSummary {
        throw ScreenCaptureError.noWindowsAvailable
    }

    nonisolated func resolveWindowTarget(
        _ window: CaptureWindowSummary,
        excluding _: pid_t
    ) async throws -> CaptureWindowSummary {
        window
    }

    nonisolated func captureCurrentDisplay() async throws -> CapturedScreenshot {
        CompositionUITestFixture.capture(ordinal: 1)
    }

    nonisolated func captureFullscreen(
        mode _: ScreenshotFullscreenDisplayMode,
        selectedDisplayID _: CGDirectDisplayID?
    ) async throws -> CapturedScreenshot {
        CompositionUITestFixture.capture(ordinal: 1)
    }

    nonisolated func captureDesktopOverlaySnapshot() async throws -> DesktopCompositeSnapshot {
        throw ScreenCaptureError.noDisplays
    }

    nonisolated func captureRegion(
        from _: DesktopCompositeSnapshot,
        selection _: CGRect
    ) async throws -> CapturedScreenshot {
        CompositionUITestFixture.capture(ordinal: 1)
    }

    nonisolated func captureRegion(
        in _: CGRect
    ) async throws -> CapturedScreenshot {
        CompositionUITestFixture.capture(ordinal: 1)
    }

    nonisolated func captureRegionDirect(
        in _: CGRect
    ) async throws -> CapturedScreenshot {
        CompositionUITestFixture.capture(ordinal: 1)
    }

    nonisolated func captureRegionWithinSingleDisplayDirect(
        in _: CGRect
    ) async throws -> CapturedScreenshot {
        CompositionUITestFixture.capture(ordinal: 1)
    }

    nonisolated func captureWindow(
        _: CaptureWindowSummary
    ) async throws -> CapturedScreenshot {
        CompositionUITestFixture.capture(ordinal: 1)
    }
}

nonisolated struct CompositionUITestPermissionService: CapturePermissionServicing {
    @MainActor
    var currentAppName: String { "SnipSnipSnip UI Tests" }

    @MainActor
    var currentAppPath: String { Bundle.main.bundlePath }

    nonisolated func currentStatus() -> CapturePermissionStatus {
        CapturePermissionStatus(
            hasScreenRecording: true,
            hasAccessibility: true
        )
    }

    nonisolated func availableSetupRequirements() -> [CapturePermissionRequirement] {
        CapturePermissionRequirement.allCases
    }

    nonisolated func canRequest(
        _: CapturePermissionRequirement
    ) -> Bool {
        true
    }

    @MainActor
    @discardableResult
    func requestAccess(
        for _: CapturePermissionRequirement
    ) -> Bool {
        true
    }

    nonisolated func verifyScreenRecordingAccess() async -> Bool {
        true
    }

    @MainActor
    func openSystemSettings(
        for _: CapturePermissionRequirement
    ) {}

    @MainActor
    func revealCurrentAppInFinder() {}

    @MainActor
    func copyCurrentAppPathToPasteboard() {}

    nonisolated func indicatesScreenRecordingPermissionFailure(
        _: Error
    ) -> Bool {
        false
    }
}
#endif

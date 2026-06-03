import AVFoundation
import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

final class SSSVideoDocumentTests: XCTestCase {
        func testVersion1VideoPackageIsRejected() throws {
                let packageURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("sssvideo")

                try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: packageURL) }

                let manifest = """
                {
                    "assets" : {
                        "media" : "media.mp4",
                        "posterImage" : "poster.png"
                    },
                    "formatIdentifier" : "\(SSSVideoDocumentPackage.formatIdentifier)",
                    "formatVersion" : 1,
                    "recording" : {
                        "bounds" : {
                            "height" : 360,
                            "width" : 640,
                            "x" : 20,
                            "y" : 30
                        },
                        "duration" : 17,
                        "kind" : "window",
                        "preferences" : {
                            "frameRate" : "fifteen",
                            "fullscreenDisplayMode" : "allDisplays",
                            "quality" : "compact",
                            "recordsMicrophone" : false,
                            "recordsSystemAudio" : true,
                            "selectedFullscreenDisplayID" : null,
                            "showsCursor" : true,
                            "showsMouseClicks" : false
                        },
                        "recordedAt" : "2027-08-15T17:11:22Z",
                        "sourceName" : "Release Notes Window"
                    },
                    "savedAt" : "2027-08-15T17:11:22Z",
                    "session" : {
                        "posterTimeSeconds" : 4,
                        "trimEndSeconds" : 11,
                        "trimStartSeconds" : 2
                    }
                }
                """
                try Data(manifest.utf8).write(to: packageURL.appendingPathComponent("document.json"), options: .atomic)
                try Data().write(to: packageURL.appendingPathComponent("media.mp4"), options: .atomic)

                XCTAssertThrowsError(try SSSVideoDocumentPackage.load(from: packageURL)) { error in
                        guard case SSSVideoDocumentError.unsupportedFormatVersion(1) = error else {
                                return XCTFail("Expected unsupported format version 1, got \(error)")
                        }
                }
        }

    func testVideoEditorSessionNormalizationClampsToDurationAndTrimRange() {
        let session = VideoEditorSession(
            trimStartSeconds: -4,
            trimEndSeconds: 99,
            posterTimeSeconds: 18
        )

        XCTAssertEqual(
            session.normalized(for: 12),
            VideoEditorSession(trimStartSeconds: 0, trimEndSeconds: 12, posterTimeSeconds: 12)
        )

        let invertedSession = VideoEditorSession(
            trimStartSeconds: 8,
            trimEndSeconds: 3,
            posterTimeSeconds: 1
        )

        XCTAssertEqual(
            invertedSession.normalized(for: 20),
            VideoEditorSession(trimStartSeconds: 8, trimEndSeconds: 8, posterTimeSeconds: 8)
        )
    }

    func testVideoRecordingPreferencesRoundTrip() throws {
        let preferences = VideoRecordingPreferences(
            quality: .high,
            frameRate: .sixty,
            fullscreenDisplayMode: .selectedDisplay,
            selectedFullscreenDisplayID: 77,
            recordsSystemAudio: true,
            recordsMicrophone: true,
            showsCursor: false,
            showsMouseClicks: false
        )

        let encoded = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(VideoRecordingPreferences.self, from: encoded)

        XCTAssertEqual(decoded, preferences)
        XCTAssertEqual(preferences.quality.outputScale(for: 2), 2)
        XCTAssertEqual(preferences.frameRate.frameInterval, CMTime(value: 1, timescale: 60))
        XCTAssertEqual(preferences.fullscreenDisplayMode.label, "Selected Display")
    }

    func testVideoExportFormatsMapToExpectedContainers() {
        XCTAssertEqual(VideoExportFormat.mp4.fileExtension, "mp4")
        XCTAssertEqual(VideoExportFormat.mp4.fileType, .mp4)
    }

    func testVideoExportPreferencesRoundTripAndStickyLabel() throws {
        let preferences = VideoExportPreferences(
            format: .mp4,
            target: .sizeLimit(.under25MB)
        )

        let encoded = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(VideoExportPreferences.self, from: encoded)

        XCTAssertEqual(decoded, preferences)
        XCTAssertEqual(decoded.menuLabel, "MP4 • Under 25 MB")
    }

    func testVideoExportTargetsRespectFormatSupportAndSafetyBudget() {
        let qualityTarget = VideoExportTarget.quality(.balanced)
        let cappedTarget = VideoExportTarget.sizeLimit(.under25MB)

        XCTAssertTrue(qualityTarget.supports(.mp4))
        XCTAssertTrue(cappedTarget.supports(.mp4))
        XCTAssertEqual(VideoExportSizeLimit.under25MB.maximumBytes, 25_000_000)
        XCTAssertEqual(VideoExportSizeLimit.under25MB.firstPassTargetBytes, 23_750_000)
        XCTAssertEqual(cappedTarget.menuLabel(format: .mp4), "MP4 • Under 25 MB")
    }

    func testSizeConstrainedPlanStartsFivePercentUnderAndStepsDown() throws {
        let firstPlan = try VideoExporter.sizeConstrainedPlan(
            duration: 30,
            maximumBytes: VideoExportSizeLimit.under25MB.maximumBytes,
            hasAudio: true,
            attemptIndex: 0
        )
        let secondPlan = try VideoExporter.sizeConstrainedPlan(
            duration: 30,
            maximumBytes: VideoExportSizeLimit.under25MB.maximumBytes,
            hasAudio: true,
            attemptIndex: 1
        )

        XCTAssertEqual(firstPlan.targetBytes, 23_750_000)
        XCTAssertEqual(firstPlan.overheadBytes, 500_000)
        XCTAssertEqual(firstPlan.audioBitRate, 128_000)
        XCTAssertEqual(firstPlan.videoBitRate, 6_072_000)
        XCTAssertEqual(secondPlan.targetBytes, 22_750_000)
        XCTAssertLessThan(secondPlan.videoBitRate, firstPlan.videoBitRate)
    }

    func testPreferredSizeConstrainedTargetBytesAimsForNinetyFivePercent() {
        XCTAssertEqual(VideoExporter.preferredSizeConstrainedTargetBytes(maximumBytes: 25_000_000), 23_750_000)
        XCTAssertEqual(VideoExporter.preferredSizeConstrainedTargetBytes(maximumBytes: 100_000_000), 95_000_000)
        XCTAssertEqual(VideoExporter.preferredSizeConstrainedTargetBytes(maximumBytes: 250_000_000), 237_500_000)
    }

    func testPlannedTotalBitRateUsesTrimmedDuration() {
        let targetBytes: Int64 = 22_500_000
        let overheadBytes: Int64 = 500_000
        let thirtySecondBitRate = VideoExporter.plannedTotalBitRate(
            targetBytes: targetBytes,
            overheadBytes: overheadBytes,
            duration: 30
        )
        let sixtySecondBitRate = VideoExporter.plannedTotalBitRate(
            targetBytes: targetBytes,
            overheadBytes: overheadBytes,
            duration: 60
        )

        XCTAssertEqual(thirtySecondBitRate, 5_866_666)
        XCTAssertEqual(sixtySecondBitRate, 2_933_333)
    }

    func testAdaptiveRetryBitrateDropsWhenAttemptOvershootsTarget() {
        let nextBitRate = VideoExporter.nextSizeConstrainedVideoBitRate(
            previousVideoBitRate: 6_000_000,
            actualFileSize: 30_000_000,
            targetFileSize: 22_500_000,
            hasAudio: true
        )

        XCTAssertGreaterThan(nextBitRate, 4_100_000)
        XCTAssertLessThan(nextBitRate, 4_300_000)
        XCTAssertLessThan(nextBitRate, 6_000_000)
    }

    func testSizeConstrainedAttemptRetriesOnSingleByteOvershoot() {
        XCTAssertTrue(VideoExporter.needsAnotherSizeConstrainedAttempt(fileSize: 25_000_001, maximumBytes: 25_000_000))
        XCTAssertFalse(VideoExporter.needsAnotherSizeConstrainedAttempt(fileSize: 25_000_000, maximumBytes: 25_000_000))
    }

    func testEstimatedTrimmedFileSizeScalesWithTrimDuration() {
        XCTAssertEqual(
            VideoExporter.estimatedTrimmedFileSize(
                sourceFileSize: 40_000_000,
                sourceDuration: 80,
                trimmedDuration: 20
            ),
            10_000_000
        )
        XCTAssertEqual(
            VideoExporter.estimatedTrimmedFileSize(
                sourceFileSize: 40_000_000,
                sourceDuration: 80,
                trimmedDuration: 120
            ),
            40_000_000
        )
    }

    func testSizeConstrainedPlanStillFollowsRuntimeTargetWhenSourceAverageIsLower() throws {
        let plan = try VideoExporter.sizeConstrainedPlan(
            duration: 30,
            maximumBytes: VideoExportSizeLimit.under25MB.maximumBytes,
            hasAudio: true,
            attemptIndex: 0,
            sourceAverageBitRate: 2_000_000
        )

        XCTAssertEqual(plan.audioBitRate, 128_000)
        XCTAssertEqual(plan.videoBitRate, 6_072_000)
    }

    func testOwnedTemporaryMediaCleanupKeepsExcludedAndUnrelatedFiles() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let excludedURL = rootURL.appendingPathComponent(TemporaryVideoMediaManager.recordingOutputURL().lastPathComponent)
        let staleRecordingURL = rootURL.appendingPathComponent(TemporaryVideoMediaManager.recordingOutputURL().lastPathComponent)
        let staleExportURL = rootURL.appendingPathComponent(TemporaryVideoMediaManager.exportAttemptURL(format: .mp4).lastPathComponent)
        let unrelatedURL = rootURL.appendingPathComponent("keep-me.mp4")

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for url in [excludedURL, staleRecordingURL, staleExportURL, unrelatedURL] {
            try Data("video".utf8).write(to: url, options: .atomic)
        }

        let deletedBytes = try VideoStorageGuardrails.cleanupOwnedTemporaryMedia(in: rootURL, excluding: [excludedURL])

        XCTAssertGreaterThan(deletedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: excludedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRecordingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleExportURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    func testRecordingHeadroomIncreasesForLargerAndHigherQualityCaptures() {
        let compact = VideoStorageGuardrails.recommendedRecordingHeadroomBytes(
            width: 1280,
            height: 720,
            preferences: VideoRecordingPreferences(quality: .compact, frameRate: .thirty)
        )
        let high = VideoStorageGuardrails.recommendedRecordingHeadroomBytes(
            width: 3840,
            height: 2160,
            preferences: VideoRecordingPreferences(quality: .high, frameRate: .sixty)
        )

        XCTAssertGreaterThan(high, compact)
        XCTAssertGreaterThanOrEqual(compact, VideoStorageGuardrails.minimumRecordingFreeBytes)
    }

    func testLiveRecordingHeadroomUsesLowerButNonzeroSafetyFloor() {
        let preferences = VideoRecordingPreferences(quality: .compact, frameRate: .fifteen)
        let startHeadroom = VideoStorageGuardrails.recommendedRecordingHeadroomBytes(
            width: 1280,
            height: 720,
            preferences: preferences
        )
        let liveHeadroom = VideoStorageGuardrails.liveRecordingHeadroomBytes(
            width: 1280,
            height: 720,
            preferences: preferences
        )

        XCTAssertLessThan(liveHeadroom, startHeadroom)
        XCTAssertGreaterThanOrEqual(liveHeadroom, VideoStorageGuardrails.minimumLiveRecordingFreeBytes)
    }

    func testPackageRoundTripsRecordingSessionMediaAndPoster() throws {
        let sourceURL = try writeTemporaryMediaFile()
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sssvideo")
        let posterImage = makeCoordinateImage(width: 16, height: 12, pattern: .weighted(xMultiplier: 11, yMultiplier: 13, includeBlueSum: true))
        let recording = CapturedVideoRecording(
            sourceURL: sourceURL,
            kind: .window,
            sourceName: "Release Notes Window",
            bounds: CGRect(x: 20, y: 30, width: 640, height: 360),
            recordedAt: Date(timeIntervalSince1970: 1_818_181_818),
            duration: 17,
            preferences: VideoRecordingPreferences(
                quality: .compact,
                frameRate: .fifteen,
                recordsSystemAudio: true,
                recordsMicrophone: false,
                showsCursor: true,
                showsMouseClicks: false
            )
        )
        let session = VideoEditorSession(
            trimStartSeconds: 2,
            trimEndSeconds: 11,
            posterTimeSeconds: 4
        )
        let document = EditableVideoDocument(recording: recording, session: session)

        try SSSVideoDocumentPackage.save(document: document, posterImage: posterImage, to: packageURL)
        let loaded = try SSSVideoDocumentPackage.load(from: packageURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("document.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("media.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("poster.png").path))
        XCTAssertEqual(SSSVideoDocumentPackage.previewAssetURL(in: packageURL), packageURL.appendingPathComponent("poster.png"))

        XCTAssertEqual(loaded.recording.sourceURL, packageURL.appendingPathComponent("media.mp4"))
        XCTAssertEqual(loaded.recording.kind, recording.kind)
        XCTAssertEqual(loaded.recording.sourceName, recording.sourceName)
        XCTAssertEqual(loaded.recording.bounds, recording.bounds)
        XCTAssertEqual(loaded.recording.recordedAt, recording.recordedAt)
        XCTAssertEqual(loaded.recording.duration, recording.duration)
        XCTAssertEqual(loaded.recording.preferences, recording.preferences)
        XCTAssertEqual(loaded.session, session)

        let loadedPoster = try XCTUnwrap(SSSVideoDocumentPackage.loadPosterImage(from: packageURL))
        XCTAssertEqual(loadedPoster.width, posterImage.width)
        XCTAssertEqual(loadedPoster.height, posterImage.height)
        XCTAssertEqual(samplePixel(in: loadedPoster, topLeftX: 3, topLeftY: 4), samplePixel(in: posterImage, topLeftX: 3, topLeftY: 4))

        try? FileManager.default.removeItem(at: packageURL)
        try? FileManager.default.removeItem(at: sourceURL)
    }

    @MainActor
    func testDiscardCurrentDocumentDeletesOwnedTemporaryRecordingFile() throws {
        let sourceURL = try writeTemporaryMediaFile(named: TemporaryVideoMediaManager.recordingOutputURL().lastPathComponent)
        let recoveryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let defaultsSuiteName = "SSSVideoDocumentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        let model = AppModel(defaults: defaults, recoveryStore: DocumentRecoveryStore(baseURL: recoveryRoot), shouldCheckCompatibilityOnLaunch: false)
        let controller = VideoEditorController(recording: makeRecording(sourceURL: sourceURL), posterImage: makeCoordinateImage(width: 16, height: 12))

        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: recoveryRoot)
        }

        model.installVideoController(controller, documentURL: nil, savedSession: nil)
        model.discardCurrentDocument()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertNil(model.videoEditorController)
    }

    @MainActor
    func testSavingTemporaryRecordingSwitchesControllerToPackageMediaAndDeletesTempFile() async throws {
        let sourceURL = try writeTemporaryMediaFile(named: TemporaryVideoMediaManager.recordingOutputURL().lastPathComponent)
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sssvideo")
        let recoveryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let defaultsSuiteName = "SSSVideoDocumentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        let model = AppModel(defaults: defaults, recoveryStore: DocumentRecoveryStore(baseURL: recoveryRoot), shouldCheckCompatibilityOnLaunch: false)
        let session = VideoEditorSession(trimStartSeconds: 1, trimEndSeconds: 9, posterTimeSeconds: 4)
        let posterImage = makeCoordinateImage(width: 16, height: 12, pattern: .weighted(xMultiplier: 11, yMultiplier: 13, includeBlueSum: true))
        let controller = VideoEditorController(recording: makeRecording(sourceURL: sourceURL), session: session, posterImage: posterImage)

        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: recoveryRoot)
            try? FileManager.default.removeItem(at: packageURL)
            try? FileManager.default.removeItem(at: sourceURL)
        }

        model.installVideoController(controller, documentURL: nil, savedSession: nil)

        let didSave = await model.saveVideoDocument(controller, to: packageURL)

        XCTAssertTrue(didSave, model.errorMessage ?? "Expected video document save to succeed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(model.currentDocumentURL, packageURL)
        XCTAssertEqual(model.videoEditorController?.recording.sourceURL, packageURL.appendingPathComponent(SSSVideoDocumentPackage.mediaFilename))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent(SSSVideoDocumentPackage.mediaFilename).path))
    }

    @MainActor
    func testTrimHandleUpdatesPreviewBoundaryFrame() throws {
        let sourceURL = try writeTemporaryMediaFile()
        let controller = VideoEditorController(
            recording: makeRecording(sourceURL: sourceURL),
            session: VideoEditorSession(trimStartSeconds: 2, trimEndSeconds: 12, posterTimeSeconds: 4),
            posterImage: makeCoordinateImage(width: 16, height: 12)
        )

        defer {
            try? FileManager.default.removeItem(at: sourceURL)
        }

        controller.scrub(to: 6)
        controller.updateTrimStart(4)

        XCTAssertEqual(controller.session.trimStartSeconds, 4)
        XCTAssertEqual(controller.currentTimeSeconds, 4)

        controller.scrub(to: 5)
        controller.updateTrimEnd(9)

        XCTAssertEqual(controller.session.trimEndSeconds, 9)
        XCTAssertEqual(controller.currentTimeSeconds, 9)
    }

    private func writeTemporaryMediaFile(named fileName: String? = nil) throws -> URL {
        let url = fileName.map { FileManager.default.temporaryDirectory.appendingPathComponent($0) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp4")
        try Data("test movie bytes".utf8).write(to: url, options: .atomic)
        return url
    }

    private func makeRecording(sourceURL: URL) -> CapturedVideoRecording {
        CapturedVideoRecording(
            sourceURL: sourceURL,
            kind: .window,
            sourceName: "Release Notes Window",
            bounds: CGRect(x: 20, y: 30, width: 640, height: 360),
            recordedAt: Date(timeIntervalSince1970: 1_818_181_818),
            duration: 17,
            preferences: VideoRecordingPreferences(
                quality: .compact,
                frameRate: .fifteen,
                recordsSystemAudio: true,
                recordsMicrophone: false,
                showsCursor: true,
                showsMouseClicks: false
            )
        )
    }
}

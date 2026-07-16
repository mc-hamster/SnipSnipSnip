import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import XCTest
@testable import SnipSnipSnip

final class GuideWorkflowTests: XCTestCase {
    func testSourceMediaCursorConvertsTopLeftCaptureCoordinatesForCoreAnimation() throws {
        let crop = CGRect(x: -100, y: 50, width: 400, height: 200)
        let output = CGSize(width: 800, height: 600)

        XCTAssertEqual(
            try XCTUnwrap(GuideMediaCursorGeometry.renderPoint(
                fromCaptureGlobalPoint: CGPoint(x: -100, y: 50),
                cropRect: crop,
                renderSize: output,
                coordinateContract: .current
            )),
            CGPoint(x: 0, y: 600)
        )
        XCTAssertEqual(
            try XCTUnwrap(GuideMediaCursorGeometry.renderPoint(
                fromCaptureGlobalPoint: CGPoint(x: 300, y: 250),
                cropRect: crop,
                renderSize: output,
                coordinateContract: .current
            )),
            CGPoint(x: 800, y: 0)
        )
    }

    func testGuideWideNumberedMarkerSettingPreservesAVisibleStyle() {
        var theme = GuideTheme()
        theme.markerNumberStyle = "square"

        theme.showsNumberedMarkers = false
        XCTAssertFalse(theme.showsNumberedMarkers)
        XCTAssertEqual(theme.markerNumberStyle, "none")

        theme.showsNumberedMarkers = true
        XCTAssertTrue(theme.showsNumberedMarkers)
        XCTAssertEqual(theme.markerNumberStyle, "circle")
    }

    func testVideoClickHighlightIsInvisibleOutsideItsShortPulse() {
        let animation = GuideExporter.clickHighlightOpacityAnimation(eventTime: 2.5)

        XCTAssertEqual(animation.beginTime, AVCoreAnimationBeginTimeAtZero + 2.5)
        XCTAssertEqual(animation.duration, 0.45)
        XCTAssertEqual(animation.fillMode, .both)
        XCTAssertFalse(animation.isRemovedOnCompletion)
        XCTAssertEqual(animation.values as? [Int], [0, 1, 0])
    }

    func testGuideSetupIntentDerivesVideoAndAudioPreferences() {
        let base = GuideCapturePreferences(
            sourceVideoEnabled: false,
            framesPerSecond: 60,
            capturesSystemAudio: false,
            capturesMicrophone: false,
            showsSmoothVideoCursor: true,
            showsCursorInSteps: true,
            hidesDesktopIcons: false,
            masksSecureFields: true,
            automaticCaptions: true,
            aiCaptionRefinement: true,
            menuBarIncludedForDisplays: false,
            hudCorner: "topRight",
            hudPreviewsEnabled: true
        )

        let narratedVideo = GuideCaptureSetupIntent(
            output: .stepsAndVideo,
            audio: .narrationAndAppAudio
        ).applying(to: base)

        XCTAssertTrue(narratedVideo.sourceVideoEnabled)
        XCTAssertTrue(narratedVideo.capturesMicrophone)
        XCTAssertTrue(narratedVideo.capturesSystemAudio)
        XCTAssertEqual(narratedVideo.framesPerSecond, 60)
        XCTAssertTrue(narratedVideo.showsCursorInSteps)
        XCTAssertFalse(narratedVideo.hidesDesktopIcons)
        XCTAssertEqual(
            GuideCaptureSetupIntent(preferences: narratedVideo),
            GuideCaptureSetupIntent(output: .stepsAndVideo, audio: .narrationAndAppAudio)
        )
    }

    func testStepsOnlyIntentDisablesUnusedSourceMediaAndAudio() {
        var base = GuideCapturePreferences()
        base.sourceVideoEnabled = true
        base.capturesMicrophone = true
        base.capturesSystemAudio = true

        let stepsOnly = GuideCaptureSetupIntent(
            output: .stepsOnly,
            audio: .narrationAndAppAudio
        ).applying(to: base)

        XCTAssertFalse(stepsOnly.sourceVideoEnabled)
        XCTAssertFalse(stepsOnly.capturesMicrophone)
        XCTAssertFalse(stepsOnly.capturesSystemAudio)
    }

    func testEventClassifierCapturesSupportedActionsAndCoalescibleTextEntry() {
        let classifier = GuideEventClassifier()
        let point = CGPoint(x: 10, y: 20)
        XCTAssertEqual(classifier.classify(.init(timestamp: 1, location: point, payload: .mouseDown(button: 0, clickCount: 1))), .click)
        XCTAssertEqual(classifier.classify(.init(timestamp: 1, location: point, payload: .mouseDown(button: 0, clickCount: 2))), .doubleClick)
        XCTAssertEqual(classifier.classify(.init(timestamp: 1, location: point, payload: .selection)), .selection)
        XCTAssertEqual(classifier.classify(.init(timestamp: 1, location: point, payload: .scroll(deltaX: 0, deltaY: -12))), .scroll(direction: "down", distance: 12))
        XCTAssertEqual(classifier.classify(.init(timestamp: 1, location: point, payload: .swipe(deltaX: 1, deltaY: 0))), .gesture(direction: "left"))
        XCTAssertEqual(classifier.classify(.init(timestamp: 1, location: point, payload: .swipe(deltaX: -1, deltaY: 0))), .gesture(direction: "right"))
        XCTAssertEqual(classifier.classify(.init(timestamp: 1, location: point, payload: .swipe(deltaX: 0, deltaY: 1))), .gesture(direction: "up"))
        XCTAssertEqual(classifier.classify(.init(timestamp: 1, location: point, payload: .swipe(deltaX: 0, deltaY: -1))), .gesture(direction: "down"))
        XCTAssertEqual(classifier.classify(.init(timestamp: 1, location: point, payload: .swipe(deltaX: 0, deltaY: 0))), .ignored)
        XCTAssertEqual(
            classifier.classify(.init(timestamp: 1, location: point, payload: .keyDown(
                keyCode: 40,
                modifiers: UInt64(NSEvent.ModifierFlags.command.rawValue),
                characters: "k",
                isRepeat: false
            ))),
            .shortcut("Command-K")
        )
        XCTAssertEqual(classifier.classify(.init(timestamp: 1, location: point, payload: .keyDown(keyCode: 0, modifiers: 0, characters: "a", isRepeat: false))), .textEntry)
        XCTAssertEqual(classifier.classify(.init(timestamp: 1, location: point, payload: .keyDown(keyCode: 0, modifiers: UInt64(NSEvent.ModifierFlags.shift.rawValue), characters: "A", isRepeat: true))), .textEntry)
        XCTAssertEqual(classifier.classify(.init(timestamp: 1, location: point, payload: .textChanged)), .textEntry)
        XCTAssertEqual(classifier.classify(.init(timestamp: 1, location: point, payload: .keyDown(keyCode: 123, modifiers: 0, characters: nil, isRepeat: false))), .ignored)
        XCTAssertEqual(classifier.classify(.init(timestamp: 1, location: point, payload: .keyDown(keyCode: 0, modifiers: UInt64(NSEvent.ModifierFlags.command.rawValue), characters: "a", isRepeat: true))), .ignored)
        let guideModifiers = UInt64(NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue)
        XCTAssertEqual(
            classifier.classify(
                .init(timestamp: 1, location: point, payload: .keyDown(keyCode: 5, modifiers: guideModifiers, characters: "g", isRepeat: false)),
                guideShortcutKeyCode: 5
            ),
            .ignored
        )
        XCTAssertEqual(
            classifier.classify(
                .init(timestamp: 1, location: point, payload: .keyDown(keyCode: 5, modifiers: UInt64(NSEvent.ModifierFlags.option.rawValue), characters: "g", isRepeat: false)),
                guideShortcutKeyCode: 5
            ),
            .shortcut("Option-G")
        )
    }

    func testTextEntryChangeDetectorCapturesValueChangesAfterEstablishingFieldBaseline() {
        var detector = GuideTextEntryChangeDetector()
        let target = GuideTextEntryTargetIdentity(
            processID: 42,
            windowID: 7,
            role: "AXTextArea",
            identifier: "editor",
            frame: CGRect(x: 10, y: 20, width: 300, height: 120)
        )
        let caption = GuideCaptionResult(
            metadata: GuideTargetMetadata(role: "AXTextArea", label: "Comment", isSecure: false),
            deterministicCaption: "Enter text in Comment."
        )

        XCTAssertFalse(detector.consume(.init(target: target, valueFingerprint: 1, caption: caption)))
        XCTAssertFalse(detector.consume(.init(target: target, valueFingerprint: 1, caption: caption)))
        XCTAssertTrue(detector.consume(.init(target: target, valueFingerprint: 2, caption: caption)))

        var otherTarget = target
        otherTarget.identifier = "search"
        XCTAssertFalse(detector.consume(.init(target: otherTarget, valueFingerprint: 10, caption: caption)))
        XCTAssertTrue(detector.consume(.init(target: otherTarget, valueFingerprint: 11, caption: caption)))

        detector.reset()
        XCTAssertFalse(detector.consume(.init(target: otherTarget, valueFingerprint: 12, caption: caption)))
    }

    func testPrintableTypingSupportsCustomEditorsButNeverSecureFields() {
        let customEditor = GuideTargetMetadata(role: "AXWebArea", label: "Document")
        let secureField = GuideTargetMetadata(role: "AXSecureTextField", isSecure: true)

        XCTAssertFalse(GuideCaptionGenerator.allowsTextEntryCapture(
            metadata: customEditor,
            fromPrintableKeyEvent: false
        ))
        XCTAssertTrue(GuideCaptionGenerator.allowsTextEntryCapture(
            metadata: customEditor,
            fromPrintableKeyEvent: true
        ))
        XCTAssertTrue(GuideCaptionGenerator.allowsTextEntryCapture(
            metadata: nil,
            fromPrintableKeyEvent: true
        ))
        XCTAssertFalse(GuideCaptionGenerator.allowsTextEntryCapture(
            metadata: secureField,
            fromPrintableKeyEvent: true
        ))
    }

    func testFrameBufferSelectsNewestPreEventFrameAndHonorsMemoryBudget() throws {
        let buffer = GuideFrameBuffer()
        for index in 0..<5 {
            buffer.append(GuideBufferedFrame(timestamp: CMTime(value: Int64(index), timescale: 10), pixelBuffer: try pixelBuffer(width: 8, height: 8)))
        }
        XCTAssertEqual(buffer.newestFrame(before: CMTime(value: 25, timescale: 100))?.timestamp, CMTime(value: 2, timescale: 10))
        XCTAssertLessThanOrEqual(buffer.memoryUsage, GuideFrameBuffer.maximumBytes)
        buffer.flush()
        XCTAssertNil(buffer.newestFrame(before: .positiveInfinity))
    }

    func testSourceMediaUsesItsNativeGuideCropRatherThanTheWholeDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let window = CGRect(x: 100, y: 200, width: 500, height: 300)

        XCTAssertEqual(
            GuideSourceMediaGeometry.captureFrame(
                for: .window(id: 1, ownerPID: 42, name: "Example", frame: window),
                within: display
            ),
            CGRect(x: 40, y: 164, width: 620, height: 372)
        )
        XCTAssertEqual(
            GuideSourceMediaGeometry.captureFrame(
                for: .region(CGRect(x: -20, y: 850, width: 160, height: 100)),
                within: display
            ),
            CGRect(x: 0, y: 850, width: 140, height: 50)
        )
        XCTAssertEqual(
            GuideSourceMediaGeometry.captureFrame(for: .displays(.current), within: display),
            display
        )
    }

    func testGuideDisplayTargetDoesNotExcludeTheAppBeingDemonstrated() {
        let screen = ScreenDisplaySnapshot(
            displayID: 7,
            name: "Studio Display",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 875),
            backingScaleFactor: 2
        )
        let target = GuideMediaCaptureSession.recordingTarget(
            screen: screen,
            displayFrame: screen.frame,
            scale: 2,
            sourceRect: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            includeMenuBar: true
        )

        XCTAssertEqual(target.contentBounds, screen.frame)
        XCTAssertEqual(target.sourceRect, screen.frame)
        XCTAssertEqual(target.pointPixelScale, 2)
        XCTAssertEqual(target.source, .display(7, excludingProcessID: nil, includeMenuBar: true))
    }

    @MainActor
    func testDiscardStopsCaptureWithoutWaitingForSegmentFinalization() async throws {
        let platformSession = TestScreenRecordingPlatformSession()
        let media = GuideMediaCaptureSession(
            source: .displays(.current),
            capturedDisplayFrame: CGRect(x: 0, y: 0, width: 1280, height: 720),
            captureDisplayID: 1,
            platformSession: platformSession,
            files: SystemFileService(),
            sourceVideoEnabled: true
        )

        try await media.start()
        XCTAssertTrue(platformSession.isCapturing)
        XCTAssertEqual(platformSession.segmentOutputURLs.count, 1)

        await media.discard()

        XCTAssertFalse(platformSession.isCapturing)
        XCTAssertTrue(platformSession.segmentOutputURLs.isEmpty)
    }

    func testGuidePackageV1RoundTripsNonDestructiveStateAndMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GuidePackageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let packageURL = root.appendingPathComponent("Example.sssguide", isDirectory: true)
        let mediaURL = root.appendingPathComponent("segment.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let stepID = UUID()
        let segment = GuideTimelineSegment(asset: "unused.mp4", startedAt: Date(timeIntervalSince1970: 100), duration: 2)
        var project = GuideProject(source: .region(CGRect(x: 10, y: 20, width: 320, height: 200)))
        project.title = "Export a Report"
        project.steps = [GuideStep(
            id: stepID,
            sequence: 1,
            eventKind: .click,
            caption: "Click Export.",
            targetMetadata: GuideTargetMetadata(role: "AXButton", label: "Export", isSecure: false),
            session: GuideStepSession(
                marker: GuideMarker(target: CGPoint(x: 80, y: 60), tail: CGPoint(x: 20, y: 20)),
                redactions: [GuideRedaction(kind: .solid, rect: CGRect(x: 1, y: 2, width: 30, height: 20))],
                sourceCoordinateRect: CGRect(x: 10, y: 20, width: 320, height: 200),
                sourcePixelSize: CGSize(width: 640, height: 400)
            )
        )]
        project.timeline.segments = [segment]
        let document = EditableGuideDocument(
            project: project,
            stepImages: [stepID: try image(width: 64, height: 40)],
            previewImage: try image(width: 32, height: 20),
            logoImage: try image(width: 12, height: 12),
            mediaSegmentURLs: [segment.id: mediaURL]
        )

        try SSSGuideDocumentPackage.save(document: document, to: packageURL)
        let manifestURL = packageURL.appendingPathComponent("document.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let persistedProject = try XCTUnwrap(manifest["project"] as? [String: Any])
        XCTAssertNotNil(persistedProject["coordinateContract"])

        // Files saved before Guide adopted the shared contract have no field.
        // They retain the established top-left capture convention.
        var legacyProject = persistedProject
        legacyProject.removeValue(forKey: "coordinateContract")
        manifest["project"] = legacyProject
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)
        let decoded = try SSSGuideDocumentPackage.load(from: packageURL)

        XCTAssertEqual(decoded.project.title, project.title)
        XCTAssertNil(decoded.project.coordinateContract)
        XCTAssertEqual(decoded.project.resolvedCoordinateContract, .current)
        XCTAssertEqual(decoded.project.steps.first?.id, project.steps.first?.id)
        XCTAssertEqual(decoded.project.steps.first?.caption, project.steps.first?.caption)
        XCTAssertEqual(decoded.project.steps.first?.session, project.steps.first?.session)
        XCTAssertLessThan(abs(try XCTUnwrap(decoded.project.steps.first?.capturedAt.timeIntervalSince(project.steps[0].capturedAt))), 0.001)
        XCTAssertEqual(decoded.project.timeline.segments.first?.id, segment.id)
        XCTAssertEqual(decoded.project.timeline.segments.first?.duration, segment.duration)
        XCTAssertEqual(decoded.stepImages[stepID]?.width, 64)
        XCTAssertNotNil(decoded.previewImage)
        XCTAssertNotNil(decoded.logoImage)
        XCTAssertNotNil(decoded.mediaSegmentURLs[segment.id])
        XCTAssertEqual(SSSGuideDocumentPackage.compatibilityStatus(at: packageURL), .compatible)
    }

    func testGuidePackageRejectsFutureVersionsAndPathTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GuideSafetyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let packageURL = root.appendingPathComponent("Example.sssguide", isDirectory: true)
        let stepID = UUID()
        var project = GuideProject(source: .displays(.current))
        project.steps = [GuideStep(
            id: stepID,
            sequence: 1,
            eventKind: .manual,
            caption: "Review this screen.",
            session: GuideStepSession(sourceCoordinateRect: CGRect(x: 0, y: 0, width: 10, height: 10), sourcePixelSize: CGSize(width: 10, height: 10))
        )]
        try SSSGuideDocumentPackage.save(
            document: EditableGuideDocument(project: project, stepImages: [stepID: try image(width: 10, height: 10)], previewImage: nil, logoImage: nil, mediaSegmentURLs: [:]),
            to: packageURL
        )
        let manifestURL = packageURL.appendingPathComponent("document.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        json["formatVersion"] = 999
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL, options: .atomic)
        XCTAssertThrowsError(try SSSGuideDocumentPackage.load(from: packageURL)) { error in
            XCTAssertEqual(error as? SSSGuideDocumentError, .unsupportedFormatVersion(999))
        }

        json["formatVersion"] = 1
        var assets = try XCTUnwrap(json["assets"] as? [String: Any])
        var steps = try XCTUnwrap(assets["steps"] as? [[String: Any]])
        steps[0]["baseImage"] = "../outside.png"
        assets["steps"] = steps
        json["assets"] = assets
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL, options: .atomic)
        XCTAssertThrowsError(try SSSGuideDocumentPackage.load(from: packageURL)) { error in
            XCTAssertEqual(error as? SSSGuideDocumentError, .invalidAssetPath("../outside.png"))
        }
    }

    func testEveryGuideExportProducesUsableOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GuideExportTests-\(UUID().uuidString)", isDirectory: true)
        let keepOutputs = ProcessInfo.processInfo.environment["KEEP_GUIDE_EXPORTS"] != nil
        defer {
            if !keepOutputs {
                try? FileManager.default.removeItem(at: root)
            }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let createdAt = Date()
        let stepID = UUID()
        let step = GuideStep(
            id: stepID,
            sequence: 1,
            eventKind: .click,
            capturedAt: createdAt.addingTimeInterval(1),
            sourceTimestampSeconds: 1,
            caption: "Click Continue.",
            note: "Use the primary action to continue.",
            session: GuideStepSession(
                marker: GuideMarker(target: CGPoint(x: 40, y: 24), tail: CGPoint(x: 8, y: 8)),
                sourceCoordinateRect: CGRect(x: 0, y: 0, width: 80, height: 48),
                sourcePixelSize: CGSize(width: 80, height: 48)
            )
        )
        var project = GuideProject(source: .region(CGRect(x: 0, y: 0, width: 80, height: 48)))
        project.createdAt = createdAt
        project.modifiedAt = createdAt
        project.title = "Export Test"
        project.steps = [step]
        project.exportSettings.formats = [.pdf]
        let baseDocument = EditableGuideDocument(
            project: project,
            stepImages: [stepID: try image(width: 80, height: 48)],
            previewImage: nil,
            logoImage: nil,
            mediaSegmentURLs: [:]
        )

        for format in [GuideExportFormat.pdf, .docx, .gif, .apng, .stepImages, .slideshowMP4, .zip] {
            let url = try await GuideExporter.export(document: baseDocument, format: format, directory: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing \(format.rawValue) output")
            if url.hasDirectoryPath {
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
            } else {
                XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0, 0)
            }
        }

        let sourceURL = try await GuideExporter.export(document: baseDocument, format: .slideshowMP4, directory: root)
        let segment = GuideTimelineSegment(asset: "media/segments/source.mp4", startedAt: createdAt, duration: 2)
        project.timeline.sourceVideoEnabled = true
        project.timeline.segments = [segment]
        project.timeline.cursorSamples = [
            GuideCursorSample(timestampSeconds: 0, point: CGPoint(x: 10, y: 10)),
            GuideCursorSample(timestampSeconds: 1, point: CGPoint(x: 40, y: 24))
        ]
        let mediaDocument = EditableGuideDocument(
            project: project,
            stepImages: baseDocument.stepImages,
            previewImage: nil,
            logoImage: nil,
            mediaSegmentURLs: [segment.id: sourceURL]
        )
        for format in [GuideExportFormat.fullMotionMP4, .highlightMP4] {
            let url = try await GuideExporter.export(document: mediaDocument, format: format, directory: root)
            XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0, 0)
        }
    }

    func testGuideAutomationCLIAndURLRoutesHaveProcedureParity() throws {
        let commands: [[String]] = [
            ["guide", "start", "--target", "window"], ["guide", "pause"], ["guide", "resume"],
            ["guide", "add-step"], ["guide", "stop"], ["guide", "export", "--format", "pdf"]
        ]
        for command in commands { XCTAssertNotNil(AutomationCLIParser.parse(command).request) }
        XCTAssertNotNil(AutomationURLRouter.request(from: try XCTUnwrap(URL(string: "snipsnipsnip://v1/guide/start?target=window"))))
        XCTAssertNotNil(AutomationURLRouter.request(from: try XCTUnwrap(URL(string: "snipsnipsnip://v1/guide/pause"))))
        XCTAssertNotNil(AutomationURLRouter.request(from: try XCTUnwrap(URL(string: "snipsnipsnip://v1/guide/resume"))))
        XCTAssertNotNil(AutomationURLRouter.request(from: try XCTUnwrap(URL(string: "snipsnipsnip://v1/guide/add-step"))))
        XCTAssertNotNil(AutomationURLRouter.request(from: try XCTUnwrap(URL(string: "snipsnipsnip://v1/guide/stop"))))
        XCTAssertNotNil(AutomationURLRouter.request(from: try XCTUnwrap(URL(string: "snipsnipsnip://v1/guide/export?format=pdf"))))
    }

    private func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        XCTAssertEqual(result, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}

import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import XCTest
@testable import SnipSnipSnip

final class GuideWorkflowTests: XCTestCase {
    @MainActor
    func testGuideEditorDeleteMarksStepsAndSelectsNextActiveStep() throws {
        let steps = (1...3).map { sequence in
            GuideStep(
                sequence: sequence,
                eventKind: .manual,
                caption: "Step \(sequence)",
                session: GuideStepSession(
                    sourceCoordinateRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                    sourcePixelSize: CGSize(width: 10, height: 10)
                )
            )
        }
        var project = GuideProject(source: .displays(.current))
        project.steps = steps
        let image = try image(width: 10, height: 10)
        let controller = GuideEditorController(document: EditableGuideDocument(
            project: project,
            stepImages: Dictionary(uniqueKeysWithValues: steps.map { ($0.id, image) }),
            previewImage: nil,
            logoImage: nil,
            mediaSegmentURLs: [:]
        ))
        controller.selection = [steps[1].id]

        controller.deleteSelected()

        XCTAssertTrue(controller.project.steps[1].isDeleted)
        XCTAssertEqual(controller.selection, [steps[2].id])
        XCTAssertEqual(controller.includedSteps.map { $0.id }, [steps[0].id, steps[2].id])
        XCTAssertEqual(controller.displayNumber(for: steps[0].id), 1)
        XCTAssertNil(controller.displayNumber(for: steps[1].id))
        XCTAssertEqual(controller.displayNumber(for: steps[2].id), 2)
    }

    func testGuideStepNumberingSkipsDeletedAndExcludedStepsWithoutChangingStoredSequence() {
        var steps = (1...4).map { sequence in
            GuideStep(
                sequence: sequence,
                eventKind: .manual,
                caption: "Step \(sequence)",
                session: GuideStepSession(
                    sourceCoordinateRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                    sourcePixelSize: CGSize(width: 10, height: 10)
                )
            )
        }
        steps[0].isDeleted = true
        steps[2].isIncluded = false

        XCTAssertNil(GuideStepNumbering.activeNumber(for: steps[0].id, in: steps))
        XCTAssertEqual(GuideStepNumbering.activeNumber(for: steps[1].id, in: steps), 1)
        XCTAssertEqual(GuideStepNumbering.activeNumber(for: steps[2].id, in: steps), 2)
        XCTAssertEqual(GuideStepNumbering.activeNumber(for: steps[3].id, in: steps), 3)

        let exported = GuideStepNumbering.exportSteps(from: steps)
        XCTAssertEqual(exported.map { $0.id }, [steps[1].id, steps[3].id])
        XCTAssertEqual(exported.map { $0.sequence }, [1, 2])
        XCTAssertEqual(steps.map { $0.sequence }, [1, 2, 3, 4])
    }

    func testGuideStorageGuardrailsRejectLowDiskBeforeCaptureAndExport() throws {
        XCTAssertThrowsError(try GuideStorageGuardrails.ensureCanStartCapture(
            pixelWidth: 3_840,
            pixelHeight: 2_160,
            framesPerSecond: 60,
            sourceVideoEnabled: true,
            temporaryDirectory: URL(fileURLWithPath: "/tmp"),
            availableCapacity: { _ in 100_000_000 }
        )) { error in
            guard case GuideStorageError.insufficientAvailableSpace = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertGreaterThan(
            GuideStorageGuardrails.captureHeadroomBytes(
                pixelWidth: 3_840,
                pixelHeight: 2_160,
                framesPerSecond: 60,
                sourceVideoEnabled: true
            ),
            GuideStorageGuardrails.minimumVideoCaptureFreeBytes
        )
        XCTAssertEqual(
            GuideStorageGuardrails.captureHeadroomBytes(
                pixelWidth: 1,
                pixelHeight: 1,
                framesPerSecond: 1,
                sourceVideoEnabled: false
            ),
            GuideStorageGuardrails.minimumStepCaptureFreeBytes
        )
    }

    func testRotatedVideoTrackGeometryNormalizesIntoUprightRenderSpace() throws {
        let preferred = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1_080, ty: 0)
        let geometry = try XCTUnwrap(GuideVideoTrackGeometry.orientedGeometry(
            naturalSize: CGSize(width: 1_920, height: 1_080),
            preferredTransform: preferred
        ))

        XCTAssertEqual(geometry.renderSize, CGSize(width: 1_080, height: 1_920))
        let outputRect = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
            .applying(geometry.layerTransform)
            .standardized
        XCTAssertEqual(outputRect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(outputRect.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(outputRect.size.width, 1_080, accuracy: 0.001)
        XCTAssertEqual(outputRect.size.height, 1_920, accuracy: 0.001)
    }

    func testMixedOrientationVideoSegmentsFitWithoutStretching() throws {
        let portraitTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1_080, ty: 0)
        let canvas = CGSize(width: 1_920, height: 1_920)
        let portrait = try XCTUnwrap(GuideVideoTrackGeometry.fittedGeometry(
            naturalSize: CGSize(width: 1_920, height: 1_080),
            preferredTransform: portraitTransform,
            renderSize: canvas
        ))
        let landscape = try XCTUnwrap(GuideVideoTrackGeometry.fittedGeometry(
            naturalSize: CGSize(width: 1_920, height: 1_080),
            preferredTransform: .identity,
            renderSize: canvas
        ))

        XCTAssertEqual(portrait.contentRect, CGRect(x: 420, y: 0, width: 1_080, height: 1_920))
        XCTAssertEqual(landscape.contentRect, CGRect(x: 0, y: 420, width: 1_920, height: 1_080))
        let portraitOutput = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
            .applying(portrait.layerTransform)
            .standardized
        XCTAssertEqual(portraitOutput.minX, portrait.contentRect.minX, accuracy: 0.001)
        XCTAssertEqual(portraitOutput.minY, portrait.contentRect.minY, accuracy: 0.001)
        XCTAssertEqual(portraitOutput.width, portrait.contentRect.width, accuracy: 0.001)
        XCTAssertEqual(portraitOutput.height, portrait.contentRect.height, accuracy: 0.001)
    }

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

    @MainActor
    func testGuideMarkerDragUpdatesLiveAndCreatesOneUndoableMove() throws {
        let originalTarget = CGPoint(x: 50, y: 40)
        let originalTail = CGPoint(x: 120, y: 100)
        let step = GuideStep(
            sequence: 1,
            eventKind: .click,
            caption: "Click Continue.",
            session: GuideStepSession(
                marker: GuideMarker(target: originalTarget, tail: originalTail),
                sourceCoordinateRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                sourcePixelSize: CGSize(width: 400, height: 300)
            )
        )
        var project = GuideProject(source: .region(CGRect(x: 0, y: 0, width: 400, height: 300)))
        project.steps = [step]
        let controller = GuideEditorController(document: EditableGuideDocument(
            project: project,
            stepImages: [step.id: try image(width: 400, height: 300)],
            previewImage: nil,
            logoImage: nil,
            mediaSegmentURLs: [:]
        ))

        controller.beginMarkerDrag(stepID: step.id)
        controller.updateMarkerDuringDrag(stepID: step.id, tail: CGPoint(x: 180, y: 140))
        XCTAssertEqual(controller.selectedStep?.session.marker?.tail, CGPoint(x: 180, y: 140))

        controller.updateMarkerDuringDrag(stepID: step.id, tail: CGPoint(x: 220, y: 160))
        controller.endMarkerDrag(stepID: step.id, tail: CGPoint(x: 240, y: 180))
        XCTAssertEqual(controller.selectedStep?.session.marker?.tail, CGPoint(x: 240, y: 180))
        XCTAssertTrue(controller.canUndo)

        controller.undo()
        XCTAssertEqual(controller.selectedStep?.session.marker?.target, originalTarget)
        XCTAssertEqual(controller.selectedStep?.session.marker?.tail, originalTail)
        XCTAssertFalse(controller.canUndo)
    }

    func testAutomaticGuideMarkerPlacementAvoidsClickedElementAndCanvasEdges() {
        let canvas = CGSize(width: 600, height: 400)
        let targetRect = CGRect(x: 200, y: 150, width: 200, height: 100)
        let tail = GuideMarkerGeometry.automaticTail(
            for: CGPoint(x: 300, y: 200),
            avoiding: targetRect,
            in: canvas,
            preferredLength: 80,
            badgeRadius: 18,
            targetClearance: 22
        )
        let badgeRect = CGRect(x: tail.x - 18, y: tail.y - 18, width: 36, height: 36)

        XCTAssertFalse(badgeRect.intersects(targetRect))
        XCTAssertTrue(CGRect(x: 22, y: 22, width: 556, height: 356).contains(tail))

        let cornerTail = GuideMarkerGeometry.automaticTail(
            for: CGPoint(x: 390, y: 290),
            avoiding: CGRect(x: 360, y: 260, width: 40, height: 40),
            in: CGSize(width: 400, height: 300),
            preferredLength: 80,
            badgeRadius: 18,
            targetClearance: 22
        )
        XCTAssertTrue(CGRect(x: 22, y: 22, width: 356, height: 256).contains(cornerTail))
    }

    func testGuideMarkerConnectorStopsBeforeBadgeAndClickTarget() throws {
        let badge = CGPoint(x: 20, y: 20)
        let target = CGPoint(x: 120, y: 120)
        let connector = try XCTUnwrap(GuideMarkerGeometry.connector(
            from: badge,
            to: target
        ))

        XCTAssertEqual(hypot(connector.start.x - badge.x, connector.start.y - badge.y), 21, accuracy: 0.001)
        XCTAssertEqual(hypot(connector.end.x - target.x, connector.end.y - target.y), 25, accuracy: 0.001)
    }

    func testRenderedGuideTargetLeavesClickedPixelVisible() throws {
        let sourceColor = PixelSample(red: 51, green: 128, blue: 204, alpha: 255)
        let source = makeSolidImage(width: 100, height: 100, color: sourceColor)
        var step = GuideStep(
            sequence: 1,
            eventKind: .click,
            caption: "Click the control.",
            session: GuideStepSession(
                marker: GuideMarker(
                    target: CGPoint(x: 50, y: 50),
                    tail: CGPoint(x: 10, y: 10)
                ),
                sourceCoordinateRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                sourcePixelSize: CGSize(width: 100, height: 100)
            )
        )

        let rendered = try XCTUnwrap(GuideRenderer.renderStepCard(
            step: step,
            image: source,
            theme: GuideTheme(),
            cardWidth: 400
        ))

        XCTAssertEqual(samplePixel(in: rendered, topLeftX: 122, topLeftY: 122), sourceColor)
        XCTAssertNotEqual(samplePixel(in: rendered, topLeftX: 144, topLeftY: 122), sourceColor)

        step.session.showsActionTarget = false
        let withoutCrosshairs = try XCTUnwrap(GuideRenderer.renderStepCard(
            step: step,
            image: source,
            theme: GuideTheme(),
            cardWidth: 400
        ))

        XCTAssertEqual(samplePixel(in: withoutCrosshairs, topLeftX: 144, topLeftY: 122), sourceColor)
    }

    func testPerStepNumberVisibilityOverridesLegacyThemeBehavior() {
        var theme = GuideTheme()
        var step = GuideStep(
            sequence: 1,
            eventKind: .click,
            caption: "Click the control.",
            session: GuideStepSession(
                sourceCoordinateRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                sourcePixelSize: CGSize(width: 100, height: 100)
            )
        )

        XCTAssertTrue(step.showsStepNumber(using: theme))

        theme.showsNumberedMarkers = false
        XCTAssertFalse(step.showsStepNumber(using: theme))

        step.session.showsStepNumber = true
        XCTAssertTrue(step.showsStepNumber(using: theme))

        theme.showsNumberedMarkers = true
        step.session.showsStepNumber = false
        XCTAssertFalse(step.showsStepNumber(using: theme))

        XCTAssertTrue(step.showsActionTarget(using: theme))
        theme.showsClickHighlight = false
        XCTAssertFalse(step.showsActionTarget(using: theme))
        step.session.showsActionTarget = true
        XCTAssertTrue(step.showsActionTarget(using: theme))
        theme.showsClickHighlight = true
        step.session.showsActionTarget = false
        XCTAssertFalse(step.showsActionTarget(using: theme))
    }

    func testRendererHidesNumberForOnlyTheSelectedStep() throws {
        let sourceColor = PixelSample(red: 51, green: 128, blue: 204, alpha: 255)
        let source = makeSolidImage(width: 100, height: 100, color: sourceColor)
        var step = GuideStep(
            sequence: 1,
            eventKind: .click,
            caption: "Click the control.",
            session: GuideStepSession(
                marker: GuideMarker(
                    target: CGPoint(x: 50, y: 50),
                    tail: CGPoint(x: 10, y: 10)
                ),
                sourceCoordinateRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                sourcePixelSize: CGSize(width: 100, height: 100),
                showsStepNumber: true
            )
        )

        let numbered = try XCTUnwrap(GuideRenderer.renderStepCard(
            step: step,
            image: source,
            theme: GuideTheme(),
            cardWidth: 400
        ))
        step.session.showsStepNumber = false
        let unnumbered = try XCTUnwrap(GuideRenderer.renderStepCard(
            step: step,
            image: source,
            theme: GuideTheme(),
            cardWidth: 400
        ))

        XCTAssertNotEqual(samplePixel(in: numbered, topLeftX: 82, topLeftY: 82), sourceColor)
        XCTAssertEqual(samplePixel(in: unnumbered, topLeftX: 82, topLeftY: 82), sourceColor)
    }

    func testLegacyGuideCapturePreferencesDefaultToNumberedSteps() throws {
        var preferences = GuideCapturePreferences()
        preferences.showsStepNumbers = false
        preferences.showsActionTargets = false
        let encoded = try JSONEncoder().encode(preferences)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "showsStepNumbers")
        json.removeValue(forKey: "showsActionTargets")

        let decoded = try JSONDecoder().decode(
            GuideCapturePreferences.self,
            from: JSONSerialization.data(withJSONObject: json)
        )

        XCTAssertTrue(decoded.resolvedShowsStepNumbers)
        XCTAssertTrue(decoded.resolvedShowsActionTargets)
    }

    func testLegacyGuideThemeWithoutLegalStatementStillDecodes() throws {
        let encoded = try JSONEncoder().encode(GuideTheme())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "legalStatement")

        let decoded = try JSONDecoder().decode(
            GuideTheme.self,
            from: JSONSerialization.data(withJSONObject: json)
        )

        XCTAssertNil(decoded.legalStatement)
    }

    @MainActor
    func testGuideBrandLogoDataPersistsAcrossPreferenceStores() {
        let suiteName = "GuideWorkflowTests.brandLogo.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expected = Data([0x89, 0x50, 0x4E, 0x47])

        GuidePreferenceStore(storage: defaults).saveBrandLogoData(expected)

        XCTAssertEqual(GuidePreferenceStore(storage: defaults).loadBrandLogoData(), expected)
    }

    func testLegalStatementReservesSpaceOnRenderedGuideCards() throws {
        let step = GuideStep(
            sequence: 1,
            eventKind: .manual,
            caption: "Review the result.",
            session: GuideStepSession(
                sourceCoordinateRect: CGRect(x: 0, y: 0, width: 80, height: 48),
                sourcePixelSize: CGSize(width: 80, height: 48)
            )
        )
        let source = try image(width: 80, height: 48)
        let plain = try XCTUnwrap(GuideRenderer.renderStepCard(step: step, image: source, theme: GuideTheme()))
        var brandedTheme = GuideTheme()
        brandedTheme.footer = "© 2026 Example Company"
        brandedTheme.legalStatement = Array(
            repeating: "Confidential. For authorized recipients only. Do not redistribute without written permission.",
            count: 8
        ).joined(separator: " ")

        let branded = try XCTUnwrap(GuideRenderer.renderStepCard(step: step, image: source, theme: brandedTheme))

        XCTAssertGreaterThan(branded.height, plain.height)
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
            audio: .narrationAndAppAudio,
            showsStepNumbers: false,
            showsActionTargets: false
        ).applying(to: base)

        XCTAssertTrue(narratedVideo.sourceVideoEnabled)
        XCTAssertTrue(narratedVideo.capturesMicrophone)
        XCTAssertTrue(narratedVideo.capturesSystemAudio)
        XCTAssertEqual(narratedVideo.framesPerSecond, 60)
        XCTAssertTrue(narratedVideo.showsCursorInSteps)
        XCTAssertFalse(narratedVideo.hidesDesktopIcons)
        XCTAssertFalse(narratedVideo.resolvedShowsStepNumbers)
        XCTAssertFalse(narratedVideo.resolvedShowsActionTargets)
        XCTAssertEqual(
            GuideCaptureSetupIntent(preferences: narratedVideo),
            GuideCaptureSetupIntent(
                output: .stepsAndVideo,
                audio: .narrationAndAppAudio,
                showsStepNumbers: false,
                showsActionTargets: false
            )
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

    func testGuideTargetKindBuildsWindowAndAppSourcesFromLiveSelection() {
        let window = CaptureWindowSummary(
            id: 42,
            ownerName: "Example App",
            ownerPID: 7,
            title: "Settings",
            frame: CGRect(x: 10, y: 20, width: 800, height: 600),
            layer: 0,
            focusRank: 1,
            thumbnail: nil
        )

        XCTAssertEqual(
            GuideTargetPickerKind.window.source(for: window),
            .window(
                id: 42,
                ownerPID: 7,
                name: "Example App - Settings",
                frame: window.frame
            )
        )
        XCTAssertEqual(
            GuideTargetPickerKind.app.source(for: window),
            .app(
                processID: 7,
                bundleIdentifier: nil,
                name: "Example App",
                initialFrame: window.frame
            )
        )
    }

    func testGuideRequestsInitialMicrophoneAccessOnlyWhenRecordingNarration() async throws {
        let recorder = GuideMicrophoneAccessRecorder()
        let platform = TestScreenRecordingPlatform(
            microphoneAccess: {
                await recorder.recordRequest()
            }
        )
        var preferences = GuideCapturePreferences()

        preferences.sourceVideoEnabled = true
        preferences.capturesMicrophone = true
        try await GuideMediaCaptureSession.requestMicrophoneAccessIfNeeded(
            preferences: preferences,
            platform: platform
        )
        var requestCount = await recorder.requestCount
        XCTAssertEqual(requestCount, 1)

        preferences.sourceVideoEnabled = false
        try await GuideMediaCaptureSession.requestMicrophoneAccessIfNeeded(
            preferences: preferences,
            platform: platform
        )
        preferences.sourceVideoEnabled = true
        preferences.capturesMicrophone = false
        try await GuideMediaCaptureSession.requestMicrophoneAccessIfNeeded(
            preferences: preferences,
            platform: platform
        )
        requestCount = await recorder.requestCount
        XCTAssertEqual(requestCount, 1)
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
        // Frame delivery can be delayed relative to input handling. Selection
        // must follow the frame timestamp rather than callback arrival order.
        for index in [0, 4, 1, 3, 2] {
            buffer.append(GuideBufferedFrame(timestamp: CMTime(value: Int64(index), timescale: 100), pixelBuffer: try pixelBuffer(width: 8, height: 8)))
        }
        XCTAssertEqual(buffer.newestFrame(before: CMTime(value: 25, timescale: 1_000))?.timestamp, CMTime(value: 2, timescale: 100))
        XCTAssertEqual(buffer.newestFrame(before: .positiveInfinity)?.timestamp, CMTime(value: 4, timescale: 100))
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

    func testGuideChoosesScreenCaptureKitDisplayForMixedScaleWindowGeometry() throws {
        let displays = [
            DisplaySnapshot(
                displayID: 1,
                name: "Retina",
                frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                overlayFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                scale: 2
            ),
            DisplaySnapshot(
                displayID: 2,
                name: "Rotated",
                frame: CGRect(x: -1_080, y: 0, width: 1_080, height: 1_920),
                overlayFrame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
                scale: 1
            )
        ]
        let source = GuideCaptureSource.window(
            id: 42,
            ownerPID: 7,
            name: "Mixed Scale",
            frame: CGRect(x: -900, y: 200, width: 600, height: 800)
        )

        let selected = try XCTUnwrap(GuideMediaCaptureSession.captureDisplay(
            for: source,
            in: displays,
            fallbackDisplayID: 1
        ))

        XCTAssertEqual(selected.displayID, 2)
        XCTAssertEqual(selected.frame, CGRect(x: -1_080, y: 0, width: 1_080, height: 1_920))
        XCTAssertEqual(selected.scale, 1)
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

    @MainActor
    func testCaptureStreamInterruptionPreservesCompletedWorkAndMakesStopResponsive() async throws {
        let platformSession = TestScreenRecordingPlatformSession()
        let media = GuideMediaCaptureSession(
            source: .displays(.current),
            capturedDisplayFrame: CGRect(x: -1_080, y: 0, width: 1_080, height: 1_920),
            captureDisplayID: 2,
            platformSession: platformSession,
            files: SystemFileService(),
            sourceVideoEnabled: true
        )
        var interruptionMessage: String?
        media.interruptionHandler = { interruptionMessage = $0.localizedDescription }
        try await media.start()

        platformSession.stopWithError(NSError(
            domain: "GuideTests",
            code: 17,
            userInfo: [NSLocalizedDescriptionKey: "Permission changed"]
        ))

        XCTAssertTrue(media.isInterrupted)
        XCTAssertEqual(interruptionMessage, "Permission changed")
        XCTAssertTrue(platformSession.segmentOutputURLs.isEmpty)
        let preservedSegments = try await media.stop()
        XCTAssertTrue(preservedSegments.isEmpty)
    }

    func testIncrementalRecoveryReusesOldStepAssetsAcrossHundredsOfSteps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GuideIncrementalRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Long.sssguide", isDirectory: true)
        let firstID = UUID()
        let firstStep = GuideStep(
            id: firstID,
            sequence: 1,
            eventKind: .manual,
            caption: "First",
            session: GuideStepSession(
                sourceCoordinateRect: CGRect(x: -1_080, y: 0, width: 1_080, height: 1_920),
                sourcePixelSize: CGSize(width: 8, height: 8)
            )
        )
        var project = GuideProject(source: .displays(.selected([2])))
        project.steps = [firstStep]
        var images: [UUID: CGImage] = [firstID: try solidImage(width: 8, height: 8, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))]
        try SSSGuideDocumentPackage.saveRecoveryCheckpoint(
            document: EditableGuideDocument(project: project, stepImages: images, previewImage: nil, logoImage: nil, mediaSegmentURLs: [:]),
            to: package
        )
        let firstAsset = package
            .appendingPathComponent("steps/\(firstID.uuidString.lowercased())/base.png")
        let originalData = try Data(contentsOf: firstAsset)

        for sequence in 2...250 {
            let id = UUID()
            project.steps.append(GuideStep(
                id: id,
                sequence: sequence,
                eventKind: .manual,
                caption: "Step \(sequence)",
                session: GuideStepSession(
                    sourceCoordinateRect: CGRect(x: 0, y: 0, width: 8, height: 8),
                    sourcePixelSize: CGSize(width: 8, height: 8)
                )
            ))
            images[id] = try image(width: 8, height: 8)
        }
        // Recovery treats captured base images as immutable and must not rewrite
        // the first 249 assets when only the manifest or final step changes.
        images[firstID] = try solidImage(width: 8, height: 8, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        try SSSGuideDocumentPackage.saveRecoveryCheckpoint(
            document: EditableGuideDocument(project: project, stepImages: images, previewImage: nil, logoImage: nil, mediaSegmentURLs: [:]),
            to: package
        )

        XCTAssertEqual(try Data(contentsOf: firstAsset), originalData)
        let recovered = try SSSGuideDocumentPackage.load(from: package)
        XCTAssertEqual(recovered.project.steps.count, 250)
        XCTAssertEqual(recovered.stepImages.count, 250)
    }

    @MainActor
    func testLongGuideCaptionTypingCoalescesIntoOneUndoCommand() throws {
        var project = GuideProject(source: .region(CGRect(x: 0, y: 0, width: 8, height: 8)))
        var images: [UUID: CGImage] = [:]
        let sharedImage = try image(width: 8, height: 8)
        for sequence in 1...300 {
            let id = UUID()
            project.steps.append(GuideStep(
                id: id,
                sequence: sequence,
                eventKind: .manual,
                caption: sequence == 1 ? "Initial" : "Step \(sequence)",
                session: GuideStepSession(
                    sourceCoordinateRect: CGRect(x: 0, y: 0, width: 8, height: 8),
                    sourcePixelSize: CGSize(width: 8, height: 8)
                )
            ))
            images[id] = sharedImage
        }
        let controller = GuideEditorController(document: EditableGuideDocument(
            project: project,
            stepImages: images,
            previewImage: nil,
            logoImage: nil,
            mediaSegmentURLs: [:]
        ))
        let firstID = try XCTUnwrap(project.steps.first?.id)
        for index in 1...80 {
            controller.updateCaption(stepID: firstID, caption: "Edited \(index)")
        }
        XCTAssertEqual(controller.project.steps[0].caption, "Edited 80")
        controller.undo()
        XCTAssertEqual(controller.project.steps[0].caption, "Initial")
        XCTAssertFalse(controller.canUndo)
    }

    func testGuideImageMemoryUsesBoundedThumbnailsAndPreservesFullResolution() throws {
        let source = try image(width: 1_200, height: 800)
        let thumbnail = try XCTUnwrap(GuideImageMemory.thumbnail(of: source, maximumPixelDimension: 200))
        XCTAssertEqual(max(thumbnail.width, thumbnail.height), 200)
        let compressed = try XCTUnwrap(GuideImageMemory.compressedCopy(of: source))
        XCTAssertEqual(compressed.width, 1_200)
        XCTAssertEqual(compressed.height, 800)
    }

    func testResolvedWindowSourceFollowsMixedScaleAndRotatedDisplayGeometry() throws {
        let displays = [
            DisplaySnapshot(displayID: 1, name: "Retina", frame: CGRect(x: 0, y: 0, width: 1_440, height: 900), scale: 2),
            DisplaySnapshot(displayID: 2, name: "Portrait", frame: CGRect(x: -1_080, y: 0, width: 1_080, height: 1_920), scale: 1)
        ]
        let movedFrame = CGRect(x: -900, y: 240, width: 600, height: 900)
        let content = ScreenContentSnapshot(
            displays: displays,
            windows: [ScreenWindowSnapshot(
                id: 42,
                ownerName: "Example",
                ownerPID: 7,
                bundleIdentifier: "com.example.app",
                title: "Document",
                frame: movedFrame,
                layer: 0,
                isOnScreen: true
            )],
            applications: []
        )
        let screens = TestScreenTopologyService(
            screens: [
                ScreenDisplaySnapshot(displayID: 1, name: "Retina", frame: displays[0].frame, visibleFrame: displays[0].frame, backingScaleFactor: 2),
                ScreenDisplaySnapshot(displayID: 2, name: "Portrait", frame: displays[1].frame, visibleFrame: displays[1].frame, backingScaleFactor: 1)
            ],
            mainScreen: nil
        )

        let resolved = try GuideMediaCaptureSession.resolve(
            source: .window(id: 42, ownerPID: 7, name: "Document", frame: CGRect(x: 20, y: 20, width: 500, height: 300)),
            content: content,
            screens: screens,
            preferredWindowID: 42,
            previousFrame: nil,
            includeMenuBar: false
        )

        XCTAssertEqual(resolved.windowID, 42)
        XCTAssertEqual(resolved.captureFrame, movedFrame)
        XCTAssertEqual(resolved.displayID, 2)
        XCTAssertEqual(resolved.pointPixelScale, 1)
        XCTAssertEqual(resolved.target.source, .window(42))
        XCTAssertNil(resolved.target.sourceRect)
    }

    func testResolvedAppSourcePrefersInteractionWindowThenPreviousOverlap() throws {
        let display = DisplaySnapshot(displayID: 1, name: "Display", frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000), scale: 2)
        let first = ScreenWindowSnapshot(id: 10, ownerName: "App", ownerPID: 99, bundleIdentifier: "com.example.app", title: "First", frame: CGRect(x: 40, y: 40, width: 500, height: 500), layer: 0, isOnScreen: true)
        let second = ScreenWindowSnapshot(id: 11, ownerName: "App", ownerPID: 99, bundleIdentifier: "com.example.app", title: "Second", frame: CGRect(x: 900, y: 100, width: 600, height: 700), layer: 0, isOnScreen: true)
        let content = ScreenContentSnapshot(displays: [display], windows: [first, second], applications: [])
        let screens = TestScreenTopologyService(
            screens: [ScreenDisplaySnapshot(displayID: 1, name: "Display", frame: display.frame, visibleFrame: display.frame, backingScaleFactor: 2)],
            mainScreen: nil
        )

        let exact = try GuideMediaCaptureSession.resolve(
            source: .app(processID: 99, bundleIdentifier: "com.example.app", name: "App", initialFrame: first.frame),
            content: content,
            screens: screens,
            preferredWindowID: 11,
            previousFrame: first.frame,
            includeMenuBar: false
        )
        let overlap = try GuideMediaCaptureSession.resolve(
            source: .app(processID: 99, bundleIdentifier: "com.example.app", name: "App", initialFrame: first.frame),
            content: content,
            screens: screens,
            preferredWindowID: nil,
            previousFrame: first.frame,
            includeMenuBar: false
        )

        XCTAssertEqual(exact.windowID, 11)
        XCTAssertEqual(overlap.windowID, 10)
    }

    func testGuideRegionResolutionRejectsCrossDisplayRectangle() {
        let content = ScreenContentSnapshot(
            displays: [
                DisplaySnapshot(displayID: 1, name: "Left", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800), scale: 2),
                DisplaySnapshot(displayID: 2, name: "Right", frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800), scale: 1)
            ],
            windows: [],
            applications: []
        )
        XCTAssertThrowsError(try GuideMediaCaptureSession.resolve(
            source: .region(CGRect(x: 900, y: 100, width: 300, height: 300)),
            content: content,
            screens: TestScreenTopologyService(),
            preferredWindowID: nil,
            previousFrame: nil,
            includeMenuBar: false
        )) { error in
            XCTAssertEqual(error as? GuideSourceResolutionError, .regionSpansDisplays)
        }
    }

    @MainActor
    func testLongGuidePublishesThumbnailsProgressivelyAndRejectsRemovedStepResult() async throws {
        var project = GuideProject(source: .displays(.current))
        var images: [UUID: CGImage] = [:]
        let source = try image(width: 1_200, height: 800)
        for sequence in 1...120 {
            let step = GuideStep(
                sequence: sequence,
                eventKind: .manual,
                caption: "Step \(sequence)",
                session: GuideStepSession(
                    sourceCoordinateRect: CGRect(x: 0, y: 0, width: 1_200, height: 800),
                    sourcePixelSize: CGSize(width: 1_200, height: 800)
                )
            )
            project.steps.append(step)
            images[step.id] = source
        }
        let controller = GuideEditorController(document: EditableGuideDocument(
            project: project,
            stepImages: images,
            previewImage: nil,
            logoImage: nil,
            mediaSegmentURLs: [:]
        ))
        XCTAssertLessThanOrEqual(controller.stepThumbnails.count, 7)

        let lastID = try XCTUnwrap(project.steps.last?.id)
        controller.requestThumbnail(for: lastID, priority: .userInitiated)
        for _ in 0..<100 where controller.stepThumbnails[lastID] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(controller.stepThumbnails[lastID])

        let removedID = project.steps[60].id
        controller.requestThumbnail(for: removedID, priority: .userInitiated)
        controller.removeStepWithoutCommand(id: removedID)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(controller.stepThumbnails[removedID])
    }

    func testZIP64EndRecordsUseClassicFieldsWhenPossibleAndZIP64ForLargeOffsets() {
        let classic = GuideZIPWriter.endRecords(recordCount: 3, centralSize: 120, centralOffset: 2_048)
        XCTAssertNil(classic.range(of: littleEndianData(UInt32(0x06064b50))))
        XCTAssertNotNil(classic.range(of: littleEndianData(UInt32(0x06054b50))))

        let zip64 = GuideZIPWriter.endRecords(
            recordCount: 3,
            centralSize: 120,
            centralOffset: UInt64(UInt32.max)
        )
        XCTAssertNotNil(zip64.range(of: littleEndianData(UInt32(0x06064b50))))
        XCTAssertNotNil(zip64.range(of: littleEndianData(UInt32(0x07064b50))))
        XCTAssertNotNil(zip64.range(of: littleEndianData(UInt32(0x06054b50))))
    }

    func testZIPNestedExportFailurePreservesPreviousGoodArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GuideZIPFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stepID = UUID()
        var project = GuideProject(source: .displays(.current))
        project.steps = [GuideStep(
            id: stepID,
            sequence: 1,
            eventKind: .manual,
            caption: "Step",
            session: GuideStepSession(
                sourceCoordinateRect: CGRect(x: 0, y: 0, width: 80, height: 50),
                sourcePixelSize: CGSize(width: 80, height: 50)
            )
        )]
        project.exportSettings.formats = [.zip, .fullMotionMP4]
        project.exportSettings.filenameTemplate = "Guide-ZIP-Failure"
        let document = EditableGuideDocument(
            project: project,
            stepImages: [stepID: try image(width: 80, height: 50)],
            previewImage: nil,
            logoImage: nil,
            mediaSegmentURLs: [:]
        )
        let destination = root.appendingPathComponent("Guide-ZIP-Failure.zip")
        let original = Data("previous-good-archive".utf8)
        try original.write(to: destination)

        do {
            _ = try await GuideExporter.export(document: document, format: .zip, directory: root)
            XCTFail("Expected the nested Full Motion export to fail.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Full Motion"))
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testZIPMissingRequestedSourceMediaPreservesPreviousGoodArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GuideZIPMissingMedia-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stepID = UUID()
        var project = GuideProject(source: .displays(.current))
        project.steps = [GuideStep(
            id: stepID,
            sequence: 1,
            eventKind: .manual,
            caption: "Step",
            session: GuideStepSession(
                sourceCoordinateRect: CGRect(x: 0, y: 0, width: 80, height: 50),
                sourcePixelSize: CGSize(width: 80, height: 50)
            )
        )]
        project.timeline.segments = [GuideTimelineSegment(asset: "missing.mp4", startedAt: Date(), duration: 1)]
        project.exportSettings.formats = [.zip]
        project.exportSettings.includesSourceMediaInZIP = true
        project.exportSettings.filenameTemplate = "Guide-ZIP-Missing-Media"
        let document = EditableGuideDocument(
            project: project,
            stepImages: [stepID: try image(width: 80, height: 50)],
            previewImage: nil,
            logoImage: nil,
            mediaSegmentURLs: [:]
        )
        let destination = root.appendingPathComponent("Guide-ZIP-Missing-Media.zip")
        let original = Data("previous-good-archive".utf8)
        try original.write(to: destination)

        do {
            _ = try await GuideExporter.export(document: document, format: .zip, directory: root)
            XCTFail("Expected missing requested source media to fail the ZIP export.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("source media segment 1"))
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testGuideExportProgressReportsStepDetailsAndMonotonicFractions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GuideProgress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var project = GuideProject(source: .displays(.current))
        var images: [UUID: CGImage] = [:]
        for sequence in 1...3 {
            let step = GuideStep(
                sequence: sequence,
                eventKind: .manual,
                caption: "Step \(sequence)",
                session: GuideStepSession(
                    sourceCoordinateRect: CGRect(x: 0, y: 0, width: 80, height: 50),
                    sourcePixelSize: CGSize(width: 80, height: 50)
                )
            )
            project.steps.append(step)
            images[step.id] = try image(width: 80, height: 50)
        }
        let recorder = GuideProgressRecorder()
        let result = await GuideExporter.exportAll(
            document: EditableGuideDocument(project: project, stepImages: images, previewImage: nil, logoImage: nil, mediaSegmentURLs: [:]),
            formats: [.pdf, .stepImages],
            directory: root,
            progress: recorder.record
        )

        XCTAssertTrue(result.failures.isEmpty)
        let updates = recorder.updates
        XCTAssertTrue(updates.contains { $0.detail.contains("step 3 of 3") })
        let fractions = updates.compactMap(\.overallFraction)
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertEqual(fractions.last, 1)
    }

    func testZIPStorageEstimateIncludesSourceMediaAndAtomicReplacementHeadroom() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GuideZIPEstimate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mediaURL = root.appendingPathComponent("large-source.mp4")
        FileManager.default.createFile(atPath: mediaURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: mediaURL)
        try handle.truncate(atOffset: 320_000_000)
        try handle.close()

        let stepID = UUID()
        let segment = GuideTimelineSegment(asset: "source.mp4", startedAt: Date(), duration: 1)
        var project = GuideProject(source: .displays(.current))
        project.steps = [GuideStep(
            id: stepID,
            sequence: 1,
            eventKind: .manual,
            caption: "Step",
            session: GuideStepSession(
                sourceCoordinateRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                sourcePixelSize: CGSize(width: 10, height: 10)
            )
        )]
        project.timeline.segments = [segment]
        project.exportSettings.formats = [.zip]
        let image = try image(width: 10, height: 10)
        project.exportSettings.includesSourceMediaInZIP = false
        let withoutMedia = GuideStorageGuardrails.exportHeadroomBytes(
            document: EditableGuideDocument(project: project, stepImages: [stepID: image], previewImage: nil, logoImage: nil, mediaSegmentURLs: [segment.id: mediaURL]),
            format: .zip
        )
        project.exportSettings.includesSourceMediaInZIP = true
        let withMedia = GuideStorageGuardrails.exportHeadroomBytes(
            document: EditableGuideDocument(project: project, stepImages: [stepID: image], previewImage: nil, logoImage: nil, mediaSegmentURLs: [segment.id: mediaURL]),
            format: .zip
        )

        XCTAssertEqual(withoutMedia, GuideStorageGuardrails.minimumExportFreeBytes)
        XCTAssertGreaterThanOrEqual(withMedia, 640_000_000)
    }

    func testGuidePackageV1RoundTripsNonDestructiveStateAndMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GuidePackageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let packageURL = root.appendingPathComponent("Example.sssguide", isDirectory: true)
        let mediaURL = root.appendingPathComponent("segment.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let stepID = UUID()
        let segment = GuideTimelineSegment(
            asset: "unused.mp4",
            startedAt: Date(timeIntervalSince1970: 100),
            duration: 2,
            sourceCoordinateRect: CGRect(x: -1_080, y: 0, width: 1_080, height: 1_920)
        )
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
        XCTAssertEqual(decoded.project.timeline.segments.first?.sourceCoordinateRect, segment.sourceCoordinateRect)
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

    private func littleEndianData<T: FixedWidthInteger>(_ input: T) -> Data {
        var value = input.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        XCTAssertEqual(result, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        try solidImage(width: width, height: height, color: CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    }

    private func solidImage(width: Int, height: Int, color: CGColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}

private actor GuideMicrophoneAccessRecorder {
    private(set) var requestCount = 0

    func recordRequest() {
        requestCount += 1
    }
}

nonisolated private final class GuideProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GuideExportProgressUpdate] = []

    var updates: [GuideExportProgressUpdate] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(_ update: GuideExportProgressUpdate) {
        lock.lock(); defer { lock.unlock() }
        storage.append(update)
    }
}

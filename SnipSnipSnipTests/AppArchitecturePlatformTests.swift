import CoreGraphics
import XCTest
@testable import SnipSnipSnip

@MainActor
final class AppArchitecturePlatformTests: XCTestCase {
    func testCapabilityProviderMatchesFeatureFlagCompatibilityFacade() {
        let provider = BuildTargetCapabilityProvider()

        for target in [BuildTarget.dev, .internalTesting, .externalTesting, .release, .selfRelease] {
            let snapshot = provider.snapshot(for: target)

            XCTAssertEqual(snapshot.isEnabled(.scrollingCapture), FeatureFlags.scrollingCaptureEnabled(for: target))
            XCTAssertEqual(snapshot.isEnabled(.accessibilityAutomation), FeatureFlags.accessibilityAutomationEnabled(for: target))
            XCTAssertEqual(snapshot.isEnabled(.connectedDeviceCapture), FeatureFlags.connectedDeviceCaptureEnabled(for: target))
            XCTAssertEqual(snapshot.isEnabled(.uiMap), FeatureFlags.uiMapEnabled(for: target))
            XCTAssertEqual(snapshot.isEnabled(.proUpdateCheck), FeatureFlags.proUpdateCheckEnabled(for: target))

            XCTAssertTrue(snapshot.isEnabled(.regionCapture))
            XCTAssertTrue(snapshot.isEnabled(.windowCapture))
            XCTAssertTrue(snapshot.isEnabled(.fullscreenCapture))
            XCTAssertTrue(snapshot.isEnabled(.editor))
            XCTAssertTrue(snapshot.isEnabled(.automation))
            XCTAssertTrue(snapshot.isEnabled(.export))
        }
    }

    func testPreferenceStoresPreserveLegacyKeysAndFallbacks() throws {
        let defaults = makeDefaults()
        let stores = AppPreferenceStores(storage: defaults)

        defaults.set(Data([0xFF, 0x00]), forKey: AppModelPreferenceKey.capturePresets)
        defaults.set(0.25, forKey: AppModelPreferenceKey.screenshotJPEGQuality)
        defaults.set(true, forKey: AppModelPreferenceKey.autoCopyEnabled)
        defaults.set(Data([0x01]), forKey: AppModelPreferenceKey.screenRulerPreferences)

        XCTAssertTrue(stores.capture.loadCapturePresets().isEmpty)
        XCTAssertEqual(stores.capture.loadScreenshotJPEGQuality(), ImageExportOptions.sanitizedJPEGQuality(0.25))
        XCTAssertTrue(stores.clipboard.loadAutoCopyEnabled())
        XCTAssertEqual(stores.screenTools.loadRulerPreferences(), .default)

        let presets = [
            CapturePreset(
                name: "Full",
                target: .fullscreen,
                options: CaptureRunOptions()
            )
        ]
        stores.capture.saveCapturePresets(presets)
        XCTAssertEqual(AppModel.loadCapturePresets(from: defaults), presets)
    }

    func testAutomationPresetResolverFindsByIDAndCaseInsensitiveName() {
        let preset = CapturePreset(
            name: "Design Review",
            target: .fullscreen,
            options: CaptureRunOptions()
        )
        let resolver = AutomationPresetResolver(presets: [preset])

        XCTAssertEqual(resolver.resolve(RunPresetAutomationCommand(id: preset.id)), preset)
        XCTAssertEqual(resolver.resolve(RunPresetAutomationCommand(name: "design review")), preset)
        XCTAssertNil(resolver.resolve(RunPresetAutomationCommand(name: "missing")))
    }

    func testAnnotationDescriptorsCoverEveryKind() {
        let image = makeImage()
        let kinds: [AnnotationKind] = [
            .rectangle(RectangleShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10))),
            .ellipse(EllipseShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10))),
            .line(LineShape(start: .zero, end: CGPoint(x: 10, y: 10))),
            .arrow(ArrowShape(start: .zero, end: CGPoint(x: 10, y: 10))),
            .freehand(FreehandShape(points: [.zero, CGPoint(x: 10, y: 10)])),
            .highlighter(HighlighterShape(points: [.zero, CGPoint(x: 10, y: 10)])),
            .highlight(HighlightShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10))),
            .text(TextShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10), text: "A")),
            .callout(CalloutShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10), number: 1, text: "A")),
            .measurement(MeasurementShape(start: .zero, end: CGPoint(x: 10, y: 10))),
            .spotlight(SpotlightShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10))),
            .imageOverlay(ImageOverlayShape(assetID: UUID(), rect: CGRect(x: 0, y: 0, width: 10, height: 10), image: image)),
            .redaction(RedactionShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10), mode: .solid)),
        ]

        for kind in kinds {
            let descriptor = kind.descriptor
            XCTAssertFalse(descriptor.displayName.isEmpty)
            XCTAssertEqual(kind.editorTool, descriptor.editorTool)
            XCTAssertEqual(kind.supportsFillEditing, descriptor.supportsFillEditing)
        }
        XCTAssertTrue(AnnotationKind.text(TextShape(rect: .zero, text: "")).isTextEditable)
        XCTAssertEqual(AnnotationKind.redaction(RedactionShape(rect: .zero, mode: .blur)).redactionMode, .blur)
    }

    func testExtractedRenderGeometryPreservesArrowBodyAndLabelBasics() {
        let shape = ArrowShape(
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 110, y: 30),
            curvature: 24,
            label: "Step 1",
            labelPlacement: .parallelAbove
        )

        XCTAssertFalse(EditorRenderGeometry.arrowBodyPath(for: shape).boundingBoxOfPath.isEmpty)
        XCTAssertFalse(AnnotationGeometry.arrowLabelRect(for: shape).isEmpty)
        XCTAssertFalse(EditorRenderGeometry.arrowLabelGeometry(for: shape, yAxisPointsDown: false).rect.isEmpty)
        XCTAssertNotEqual(
            EditorRenderGeometry.arrowLabelGeometry(for: shape, yAxisPointsDown: false).rect,
            EditorRenderGeometry.arrowLabelGeometry(for: shape, yAxisPointsDown: true).rect
        )
    }

    func testAppModelBoundariesDoNotReachBackToGlobalFlagsOrDefaults() throws {
        let guardedFiles = [
            "SnipSnipSnip/App/AppModel.swift",
            "SnipSnipSnip/App/AppModel+Archive.swift",
            "SnipSnipSnip/App/AppModel+Capture.swift",
            "SnipSnipSnip/App/AppModel+Clipboard.swift",
            "SnipSnipSnip/App/AppModel+ConnectedDeviceCapture.swift",
            "SnipSnipSnip/Automation/AppModel+AutomationHost.swift",
        ]
        let disallowedFragments = [
            "FeatureFlags.",
            "UserDefaults.standard",
        ]

        for file in guardedFiles {
            let contents = try String(contentsOf: repositoryRoot.appendingPathComponent(file), encoding: .utf8)
            for fragment in disallowedFragments {
                XCTAssertFalse(
                    contents.contains(fragment),
                    "\(file) should use AppEnvironment capabilities and preference stores instead of \(fragment)"
                )
            }
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppArchitecturePlatformTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeImage() -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()!
    }
}

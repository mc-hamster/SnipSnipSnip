import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

final class PresentationSceneTests: XCTestCase {
    func testBundledExampleScenesValidate() throws {
        for url in bundledSceneSourceURLs() {
            let svgText = try String(contentsOf: url, encoding: .utf8)
            let validated = try PresentationSceneValidator.validate(svgText: svgText, source: .bundled, fileURL: url)

            XCTAssertTrue(validated.metadata.id.hasPrefix("builtin."), url.lastPathComponent)
            XCTAssertEqual(validated.metadata.primaryScreenshotSlot?.id, PresentationSceneStore.primaryScreenshotSlotID)
            XCTAssertGreaterThan(validated.metadata.canvas.width, 0)
            XCTAssertGreaterThan(validated.metadata.canvas.height, 0)
        }
    }

    func testSceneValidatorRejectsUnsafeOrIncompleteSVG() {
        assertInvalid(#"<svg xmlns="http://www.w3.org/2000/svg"></svg>"#, contains: "missing metadata")
        assertInvalid(sceneSVG(extraElements: "<script>alert(1)</script>"), contains: "unsupported")
        assertInvalid(sceneSVG(extraElements: "<foreignObject><p>HTML</p></foreignObject>"), contains: "unsupported")
        assertInvalid(sceneSVG(imageHref: "https://example.com/image.png"), contains: "remote")
        assertInvalid(sceneSVG(metadataSlots: []), contains: "primaryScreenshot")
        assertInvalid(sceneSVG(id: "builtin.user-scene"), source: .user, contains: "must not use")
        assertInvalid(sceneSVG(imageSlotReference: "snipsnipsnip:unknownSlot"), contains: "unknown slot")
    }

    func testSceneMetadataDecodesScreenshotFramingDefaults() throws {
        let validated = try PresentationSceneValidator.validate(
            svgText: sceneSVG(metadataSlots: [
                #"{"id":"primaryScreenshot","type":"image","required":true,"label":"Screenshot","defaultFraming":"focusTop","allowUserOverride":false,"minScale":0.5,"maxScale":2.5,"maxAutoEnlargement":1.2}"#,
                #"{"id":"title","type":"text","label":"Title","defaultValue":"Hello"}"#,
            ]),
            source: .bundled
        )
        let slot = try XCTUnwrap(validated.metadata.primaryScreenshotSlot)

        XCTAssertEqual(slot.defaultFraming, .focusTop)
        XCTAssertFalse(slot.allowUserOverride)
        XCTAssertEqual(slot.minScale, 0.5)
        XCTAssertEqual(slot.maxScale, 2.5)
        XCTAssertEqual(slot.maxAutoEnlargement, 1.2)
    }

    func testSceneValidatorRejectsExternalCSSAndRelativeResources() {
        for href in ["//example.com/image.png", "../image.png", "/tmp/image.png"] {
            assertInvalid(sceneSVG(imageHref: href), contains: "external")
        }
        for css in [#"image { filter: url(//example.com/filter.svg#filter); }"#,
                    #"image { filter: url('../filter.svg#filter'); }"#,
                    #"@import 'theme.css';"#,
                    #"image { filter: u\72l(\2f\2f example.com/filter); }"#,
                    #"@im\70ort 'theme.css';"#] {
            assertInvalid(sceneSVG(extraElements: "<style>\(css)</style>"), contains: "external")
        }
        assertInvalid(sceneSVG(extraElements: #"<rect style="fill: url('../fill.svg#fill')"/>"#), contains: "external")
        assertInvalid(sceneSVG(extraElements: #"<use href="../objects.svg#object"/>"#), contains: "external")
        assertInvalid(sceneSVG().replacingOccurrences(of: "<svg ", with: #"<svg xml:base="//example.com/" "#), contains: "external")
        assertInvalid("<?xml-stylesheet href=\"theme.css\"?>\n" + sceneSVG(), contains: "external")
    }

    func testSceneValidatorKeepsLocalCSSReferencesAndSlotResources() throws {
        let svg = sceneSVG(extraElements: ##"<defs><linearGradient id="local-fill"><stop stop-color="#fff"/></linearGradient></defs><style>rect { fill: url('#local-fill'); }</style><use href="#primary-screenshot"/>"##)
        XCTAssertNoThrow(try PresentationSceneValidator.validate(svgText: svg, source: .bundled))
    }

    func testFitOnlyAppliedSceneSettingsMigrateToFramingPresets() throws {
        let contain = try JSONDecoder().decode(
            PresentationSceneScreenshotSlotSettings.self,
            from: Data(#"{"fit":"contain"}"#.utf8)
        )
        let cover = try JSONDecoder().decode(
            PresentationSceneScreenshotSlotSettings.self,
            from: Data(#"{"fit":"cover"}"#.utf8)
        )

        XCTAssertEqual(contain.framingPreset, .showFull)
        XCTAssertEqual(contain.fit, .contain)
        XCTAssertEqual(contain.alignment, .center)
        XCTAssertEqual(contain.scale, 1)
        XCTAssertEqual(contain.offset, .zero)
        XCTAssertFalse(contain.hasManualAdjustment)

        XCTAssertEqual(cover.framingPreset, .fillFrame)
        XCTAssertEqual(cover.fit, .cover)
    }

    func testSceneStoreSeedsAndUpdatesBundledScenes() throws {
        let rootURL = temporaryDirectory()
        let resourceURL = temporaryDirectory().appendingPathComponent("browser.svg")
        try sceneSVG(id: "builtin.store-test", name: "Store Test", version: 1)
            .write(to: resourceURL, atomically: true, encoding: .utf8)

        let initial = try PresentationSceneStore(
            rootURL: rootURL,
            bundledResourceURLs: [resourceURL],
            appVersion: "1.0",
            fileManager: .default
        ).reload()

        XCTAssertEqual(initial.scenes.map(\.id), ["builtin.store-test"])
        XCTAssertEqual(initial.scenes.first?.version, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL
            .appendingPathComponent(PresentationSceneStore.bundledDirectoryName, isDirectory: true)
            .appendingPathComponent("browser.svg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL
            .appendingPathComponent(PresentationSceneStore.userDirectoryName, isDirectory: true).path))

        try sceneSVG(id: "builtin.store-test", name: "Store Test", version: 2)
            .write(to: resourceURL, atomically: true, encoding: .utf8)
        let updated = try PresentationSceneStore(
            rootURL: rootURL,
            bundledResourceURLs: [resourceURL],
            appVersion: "2.0",
            fileManager: .default
        ).reload()

        XCTAssertEqual(updated.scenes.first?.version, 2)
        try? FileManager.default.removeItem(at: rootURL)
        try? FileManager.default.removeItem(at: resourceURL.deletingLastPathComponent())
    }

    func testSceneStorePreservesUserModifiedBundledSceneAndWritesUpdateBesideIt() throws {
        let rootURL = temporaryDirectory()
        let resourceRoot = temporaryDirectory()
        let resourceURL = resourceRoot.appendingPathComponent("browser.svg")
        try sceneSVG(id: "builtin.modified-test", name: "Modified Test", version: 1)
            .write(to: resourceURL, atomically: true, encoding: .utf8)

        _ = try PresentationSceneStore(
            rootURL: rootURL,
            bundledResourceURLs: [resourceURL],
            appVersion: "1.0",
            fileManager: .default
        ).reload()

        let mirroredURL = rootURL
            .appendingPathComponent(PresentationSceneStore.bundledDirectoryName, isDirectory: true)
            .appendingPathComponent("browser.svg")
        let modifiedText = sceneSVG(
            id: "builtin.modified-test",
            name: "Modified Test",
            version: 1,
            marker: "locally modified"
        )
        try modifiedText.write(to: mirroredURL, atomically: true, encoding: .utf8)

        try sceneSVG(id: "builtin.modified-test", name: "Modified Test", version: 2)
            .write(to: resourceURL, atomically: true, encoding: .utf8)
        let result = try PresentationSceneStore(
            rootURL: rootURL,
            bundledResourceURLs: [resourceURL],
            appVersion: "2.0",
            fileManager: .default
        ).reload()

        let preservedText = try String(contentsOf: mirroredURL, encoding: .utf8)
        let bundledFiles = try FileManager.default.contentsOfDirectory(
            at: mirroredURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "svg" }

        XCTAssertTrue(preservedText.contains("locally modified"))
        XCTAssertGreaterThanOrEqual(bundledFiles.count, 2)
        XCTAssertEqual(result.scenes.first { $0.id == "builtin.modified-test" }?.version, 2)
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("modified") })

        try? FileManager.default.removeItem(at: rootURL)
        try? FileManager.default.removeItem(at: resourceRoot)
    }

    func testSceneRendererUsesMetadataCanvasAndSlotSettings() throws {
        let validated = try PresentationSceneValidator.validate(
            svgText: sceneSVG(id: "builtin.render-test", name: "Render Test", version: 1, width: 240, height: 135),
            source: .bundled
        )
        var scene = AppliedPresentationScene(definition: PresentationSceneDefinition(
            metadata: validated.metadata,
            sanitizedSVGText: validated.sanitizedSVGText,
            source: .bundled,
            fileURL: URL(fileURLWithPath: "/tmp/render-test.svg"),
            isUserModifiedBundled: false
        ))
        scene.textSlotValues["title"] = "Rendered Title"
        scene.screenshotSlotSettings = PresentationSceneScreenshotSlotSettings(fit: .contain)

        let image = makeSolidImage(width: 48, height: 32, color: PixelSample(red: 80, green: 120, blue: 180, alpha: 255))
        let result = try XCTUnwrap(PresentationSceneRenderer.renderWithLayout(contentImage: image, scene: scene))

        XCTAssertEqual(result.image.width, 240)
        XCTAssertEqual(result.image.height, 135)
        XCTAssertEqual(result.layout.subjectRect, CGRect(x: 20, y: 30, width: 200, height: 80))
        XCTAssertEqual(result.layout.contentRect, CGRect(x: 60, y: 30, width: 120, height: 80))
        XCTAssertEqual(PresentationSceneRenderer.outputSize(for: scene), CGSize(width: 240, height: 135))
    }

    func testSceneRendererKeepsScreenshotTopToBottomOrientation() throws {
        let validated = try PresentationSceneValidator.validate(
            svgText: sceneSVG(id: "builtin.orientation-test", name: "Orientation Test", version: 1, width: 120, height: 120),
            source: .bundled
        )
        var scene = AppliedPresentationScene(definition: PresentationSceneDefinition(
            metadata: validated.metadata,
            sanitizedSVGText: validated.sanitizedSVGText,
            source: .bundled,
            fileURL: URL(fileURLWithPath: "/tmp/orientation-test.svg"),
            isUserModifiedBundled: false
        ))
        scene.screenshotSlotSettings = PresentationSceneScreenshotSlotSettings(framingPreset: .fillFrame)

        let image = makeCoordinateImage(width: 80, height: 80)
        let result = try XCTUnwrap(PresentationSceneRenderer.renderWithLayout(contentImage: image, scene: scene))
        let topSample = samplePixel(in: result.image, topLeftX: 60, topLeftY: 31)
        let bottomSample = samplePixel(in: result.image, topLeftX: 60, topLeftY: 108)

        XCTAssertLessThan(topSample.green, bottomSample.green)
    }

    func testSceneFramingAutoAndPresetPlacementMath() throws {
        let validated = try PresentationSceneValidator.validate(
            svgText: sceneSVG(id: "builtin.framing-test", name: "Framing Test", version: 1, width: 240, height: 135),
            source: .bundled
        )
        var scene = AppliedPresentationScene(definition: PresentationSceneDefinition(
            metadata: validated.metadata,
            sanitizedSVGText: validated.sanitizedSVGText,
            source: .bundled,
            fileURL: URL(fileURLWithPath: "/tmp/framing-test.svg"),
            isUserModifiedBundled: false
        ))

        scene.screenshotSlotSettings = PresentationSceneScreenshotSlotSettings(framingPreset: .auto)
        let closeAuto = try XCTUnwrap(PresentationSceneRenderer.framingAnalysis(
            contentSize: CGSize(width: 200, height: 80),
            scene: scene
        ))
        XCTAssertEqual(closeAuto.fit, .cover)

        let mismatchedAuto = try XCTUnwrap(PresentationSceneRenderer.framingAnalysis(
            contentSize: CGSize(width: 40, height: 120),
            scene: scene
        ))
        XCTAssertEqual(mismatchedAuto.fit, .contain)

        scene.screenshotSlotSettings = PresentationSceneScreenshotSlotSettings(framingPreset: .fillFrame)
        let fill = try XCTUnwrap(PresentationSceneRenderer.framingAnalysis(
            contentSize: CGSize(width: 80, height: 80),
            scene: scene
        ))
        XCTAssertEqual(fill.fit, .cover)
        XCTAssertEqual(fill.contentRect, CGRect(x: 20, y: -30, width: 200, height: 200))
        XCTAssertEqual(fill.cropPercentage, 0.6, accuracy: 0.001)

        scene.screenshotSlotSettings = PresentationSceneScreenshotSlotSettings(framingPreset: .actualSize)
        let actualSize = try XCTUnwrap(PresentationSceneRenderer.framingAnalysis(
            contentSize: CGSize(width: 48, height: 32),
            scene: scene
        ))
        XCTAssertEqual(actualSize.fit, .actualSize)
        XCTAssertEqual(actualSize.enlargement, 1)
        XCTAssertEqual(actualSize.contentRect, CGRect(x: 96, y: 54, width: 48, height: 32))
    }

    func testSceneFramingManualAlignmentScaleAndOffset() throws {
        let validated = try PresentationSceneValidator.validate(
            svgText: sceneSVG(id: "builtin.manual-framing-test", name: "Manual Framing Test", version: 1, width: 240, height: 135),
            source: .bundled
        )
        var scene = AppliedPresentationScene(definition: PresentationSceneDefinition(
            metadata: validated.metadata,
            sanitizedSVGText: validated.sanitizedSVGText,
            source: .bundled,
            fileURL: URL(fileURLWithPath: "/tmp/manual-framing-test.svg"),
            isUserModifiedBundled: false
        ))
        scene.screenshotSlotSettings = PresentationSceneScreenshotSlotSettings(
            framingPreset: .showFull,
            fit: .contain,
            alignment: .bottomRight,
            scale: 1.2,
            offset: CGSize(width: 10, height: -5),
            hasManualAdjustment: true
        )

        let analysis = try XCTUnwrap(PresentationSceneRenderer.framingAnalysis(
            contentSize: CGSize(width: 40, height: 40),
            scene: scene
        ))

        XCTAssertEqual(analysis.fit, .contain)
        XCTAssertEqual(analysis.alignment, .bottomRight)
        XCTAssertEqual(analysis.contentRect, CGRect(x: 134, y: 9, width: 96, height: 96))
        XCTAssertTrue(analysis.hasManualAdjustment)
    }

    func testSceneRendererTreatsManualVerticalOffsetAsTopLeftYDown() throws {
        let validated = try PresentationSceneValidator.validate(
            svgText: sceneSVG(id: "builtin.offset-render-test", name: "Offset Render Test", version: 1, width: 120, height: 120),
            source: .bundled
        )
        var scene = AppliedPresentationScene(definition: PresentationSceneDefinition(
            metadata: validated.metadata,
            sanitizedSVGText: validated.sanitizedSVGText,
            source: .bundled,
            fileURL: URL(fileURLWithPath: "/tmp/offset-render-test.svg"),
            isUserModifiedBundled: false
        ))
        scene.screenshotSlotSettings = PresentationSceneScreenshotSlotSettings(
            framingPreset: .actualSize,
            fit: .actualSize,
            alignment: .topLeft,
            scale: 1,
            offset: CGSize(width: 0, height: 10),
            hasManualAdjustment: true
        )

        let content = makeSolidImage(
            width: 40,
            height: 40,
            color: PixelSample(red: 8, green: 12, blue: 16, alpha: 255)
        )
        let result = try XCTUnwrap(PresentationSceneRenderer.renderWithLayout(contentImage: content, scene: scene))

        XCTAssertEqual(result.layout.contentRect.minY, 40)
        XCTAssertGreaterThan(samplePixel(in: result.image, topLeftX: 25, topLeftY: 35).red, 240)
        XCTAssertLessThan(samplePixel(in: result.image, topLeftX: 25, topLeftY: 45).red, 20)
    }

    func testAppliedSceneStateRoundTripsInsideSSSDocument() throws {
        let validated = try PresentationSceneValidator.validate(
            svgText: sceneSVG(id: "builtin.document-test", name: "Document Test", version: 3),
            source: .bundled
        )
        var presentation = ScreenshotPresentationPreset.lifted.settings
        presentation.scene = AppliedPresentationScene(
            sceneID: validated.metadata.id,
            name: validated.metadata.name,
            version: validated.metadata.version,
            sanitizedSVGText: validated.sanitizedSVGText,
            textSlotValues: ["title": "Saved Scene"],
            screenshotSlotSettings: PresentationSceneScreenshotSlotSettings(fit: .contain)
        )

        let baseImage = makeCoordinateImage(width: 80, height: 60)
        let snapshot = makeEditorSnapshot(
            cropRect: CGRect(x: 0, y: 0, width: 80, height: 60),
            presentation: presentation
        )
        let document = makeEditableDocument(
            capture: makeCapturedScreenshot(image: baseImage),
            session: makeEditorDocumentSession(initialSnapshot: snapshot)
        )
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sss")

        try SSSDocumentPackage.save(document: document, previewImage: baseImage, to: packageURL)
        let loaded = try SSSDocumentPackage.load(from: packageURL)

        XCTAssertEqual(loaded.session.currentSnapshot.presentation.style, presentation.style)
        XCTAssertEqual(loaded.session.currentSnapshot.presentation.scene, presentation.scene)
        try? FileManager.default.removeItem(at: packageURL)
    }

    func testCappedScenePreviewKeepsLogicalFramingForEveryPreset() throws {
        let validated = try PresentationSceneValidator.validate(
            svgText: sceneSVG(width: 240, height: 135), source: .bundled)
        var scene = AppliedPresentationScene(definition: PresentationSceneDefinition(
            metadata: validated.metadata, sanitizedSVGText: validated.sanitizedSVGText,
            source: .bundled, fileURL: URL(fileURLWithPath: "/tmp/logical-framing.svg"), isUserModifiedBundled: false))
        let logicalSize = CGSize(width: 400, height: 160)
        let thumbnail = makeCoordinateImage(width: 40, height: 16)
        for preset in PresentationSceneFramingPreset.allCases {
            scene.screenshotSlotSettings = PresentationSceneScreenshotSlotSettings(framingPreset: preset)
            let analysis = try XCTUnwrap(PresentationSceneRenderer.framingAnalysis(contentSize: logicalSize, scene: scene))
            let preview = try XCTUnwrap(PresentationSceneRenderer.renderWithLayout(contentImage: thumbnail,
                scene: scene, maxPixelDimension: 120, logicalContentSize: logicalSize))
            XCTAssertEqual(preview.pixelScale, 0.5)
            XCTAssertEqual(preview.image.width, 120)
            XCTAssertEqual(preview.layout.screenRect, analysis.slotRect.applying(CGAffineTransform(scaleX: 0.5, y: 0.5)))
            XCTAssertEqual(preview.layout.contentRect, analysis.contentRect.applying(CGAffineTransform(scaleX: 0.5, y: 0.5)), preset.rawValue)
            XCTAssertEqual(preview.layout.subjectScale, analysis.enlargement * 0.5, accuracy: 0.0001)
        }
    }

    func testAutoFramingDoesNotExceedMaximumEnlargementWhenFillNeedsMoreScaling() throws {
        let validated = try PresentationSceneValidator.validate(svgText: sceneSVG(width: 240, metadataSlots: [
            #"{"id":"primaryScreenshot","type":"image","required":true,"label":"Screenshot","maxAutoEnlargement":1.45}"#,
            #"{"id":"title","type":"text","label":"Title"}"#,
        ]), source: .bundled)
        let scene = AppliedPresentationScene(definition: PresentationSceneDefinition(
            metadata: validated.metadata, sanitizedSVGText: validated.sanitizedSVGText, source: .bundled,
            fileURL: URL(fileURLWithPath: "/tmp/auto-enlargement.svg"), isUserModifiedBundled: false))
        let analysis = try XCTUnwrap(PresentationSceneRenderer.framingAnalysis(contentSize: CGSize(width: 140, height: 54), scene: scene))
        XCTAssertEqual(analysis.fit, .contain)
        XCTAssertLessThanOrEqual(analysis.enlargement, 1.45)
        XCTAssertEqual(analysis.cropPercentage, 0)
    }

    func testActualSizeWarnsWhenManualOffsetExposesEmptySlotSpace() throws {
        let validated = try PresentationSceneValidator.validate(svgText: sceneSVG(width: 240), source: .bundled)
        var scene = AppliedPresentationScene(definition: PresentationSceneDefinition(
            metadata: validated.metadata, sanitizedSVGText: validated.sanitizedSVGText, source: .bundled,
            fileURL: URL(fileURLWithPath: "/tmp/offset-letterbox.svg"), isUserModifiedBundled: false))
        scene.screenshotSlotSettings = PresentationSceneScreenshotSlotSettings(framingPreset: .actualSize)
        scene.screenshotSlotSettings.applyManualAdjustment(offset: CGSize(width: 10, height: 0))
        let analysis = try XCTUnwrap(PresentationSceneRenderer.framingAnalysis(contentSize: CGSize(width: 200, height: 80), scene: scene))
        XCTAssertTrue(analysis.hasLetterbox)
        XCTAssertTrue(analysis.warningMessages.contains { $0.contains("empty space") })
    }

    func testSceneAffineMappingMatchesTranslatedScaledAndRotatedPixels() throws {
        let base = sceneSVG(width: 200, height: 180)
            .replacingOccurrences(of: #"width="160" height="80""#, with: #"width="40" height="20""#)
        let variants: [(String, String, CGRect)] = [
            ("translate(40 10)", "scale(2)", CGRect(x: 80, y: 70, width: 80, height: 40)),
            ("", "rotate(90 40 40)", CGRect(x: 30, y: 20, width: 20, height: 40)),
        ]
        let content = makeSolidImage(width: 40, height: 20, color: PixelSample(red: 200, green: 20, blue: 30, alpha: 255))
        for (parentTransform, imageTransform, expected) in variants {
            let svg = base.replacingOccurrences(of: "<image id=", with: "<g transform=\"\(parentTransform)\"><image transform=\"\(imageTransform)\" id=")
                .replacingOccurrences(of: #"preserveAspectRatio="xMidYMid slice"/>"#, with: #"preserveAspectRatio="xMidYMid slice"/></g>"#)
            let scene = try appliedScene(svg)
            let result = try XCTUnwrap(PresentationSceneRenderer.renderWithLayout(contentImage: content, scene: scene))
            let geometry = try XCTUnwrap(result.sceneGeometry)
            XCTAssertFalse(result.sceneMappingUnavailable)
            XCTAssertEqual(geometry.localSlotRect, CGRect(x: 20, y: 30, width: 40, height: 20))
            XCTAssertEqual(result.layout.screenRect.minX, expected.minX, accuracy: 0.0001)
            XCTAssertEqual(result.layout.screenRect.minY, expected.minY, accuracy: 0.0001)
            XCTAssertEqual(result.layout.screenRect.width, expected.width, accuracy: 0.0001)
            XCTAssertEqual(result.layout.screenRect.height, expected.height, accuracy: 0.0001)
            let center = CGPoint(x: geometry.localSlotRect.midX, y: geometry.localSlotRect.midY).applying(geometry.localToLogicalCanvas)
            let pixel = samplePixel(in: result.image, topLeftX: Int(center.x), topLeftY: Int(center.y))
            XCTAssertGreaterThan(pixel.red, 150)
            XCTAssertLessThan(pixel.green, 60)
            let local = center.applying(geometry.localToLogicalCanvas.inverted())
            XCTAssertEqual(local.x, geometry.localSlotRect.midX, accuracy: 0.0001)
            XCTAssertEqual(local.y, geometry.localSlotRect.midY, accuracy: 0.0001)
        }
    }

    func testSceneTransformParserHandlesEveryStandardAffineOperation() throws {
        let point = CGPoint(x: 10, y: 20)
        let cases: [(String, CGPoint)] = [
            ("matrix(1 0 0 1 4 5)", CGPoint(x: 14, y: 25)),
            ("translate(4 5) scale(2 3)", CGPoint(x: 24, y: 65)),
            ("rotate(90)", CGPoint(x: -20, y: 10)),
            ("rotate(90 10 10)", CGPoint(x: 0, y: 10)),
            ("skewX(45)", CGPoint(x: 30, y: 20)),
            ("skewY(45)", CGPoint(x: 10, y: 30)),
            ("translate(1e1,-2e1)", CGPoint(x: 20, y: 0)),
        ]
        for (source, expected) in cases {
            let transform = try XCTUnwrap(PresentationSceneGeometryResolver.transform(source))
            let actual = point.applying(transform)
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.0001, source)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.0001, source)
        }
        for invalid in ["translate(no)", "scale(1 2 3)", "perspective(1)", "translate(2) trailing", "matrix(1e999 0 0 1 0 0)"] {
            XCTAssertNil(PresentationSceneGeometryResolver.transform(invalid), invalid)
        }
    }

    func testRootViewBoxMappingHonorsPreserveAspectRatio() throws {
        let variants: [(String, CGRect)] = [
            ("none", CGRect(x: 24, y: 13.5, width: 480, height: 108)),
            ("xMidYMid meet", CGRect(x: 66, y: 13.5, width: 270, height: 108)),
            ("xMinYMax meet", CGRect(x: 13.5, y: 13.5, width: 270, height: 108)),
            ("xMaxYMin slice", CGRect(x: 24, y: 24, width: 480, height: 192)),
        ]
        for (preserve, expected) in variants {
            let svg = sceneSVG(width: 240, height: 135)
                .replacingOccurrences(of: #"viewBox="0 0 240 135""#, with: "viewBox=\"10 20 100 100\" preserveAspectRatio=\"\(preserve)\"")
            let document = try XMLDocument(xmlString: svg, options: [.nodeLoadExternalEntitiesNever])
            let geometry = try XCTUnwrap(PresentationSceneGeometryResolver.geometry(in: document, canvasSize: CGSize(width: 240, height: 135)))
            XCTAssertEqual(geometry.logicalSlotBounds.minX, expected.minX, accuracy: 0.0001)
            XCTAssertEqual(geometry.logicalSlotBounds.minY, expected.minY, accuracy: 0.0001)
            XCTAssertEqual(geometry.logicalSlotBounds.width, expected.width, accuracy: 0.0001)
            XCTAssertEqual(geometry.logicalSlotBounds.height, expected.height, accuracy: 0.0001)
        }
    }

    func testUnsupportedSceneCoordinateSystemsKeepRenderingButDisablePreciseMapping() throws {
        let nested = sceneSVG().replacingOccurrences(of: "<image id=", with: "<svg width=\"200\" height=\"120\"><image id=")
            .replacingOccurrences(of: #"preserveAspectRatio="xMidYMid slice"/>"#, with: #"preserveAspectRatio="xMidYMid slice"/></svg>"#)
        let css = sceneSVG(extraElements: "<style>image { transform: translate(10px, 20px); }</style>")
        let content = makeCoordinateImage(width: 40, height: 20)
        for svg in [nested, css] {
            let result = try XCTUnwrap(PresentationSceneRenderer.renderWithLayout(contentImage: content, scene: try appliedScene(svg)))
            XCTAssertNil(result.sceneGeometry)
            XCTAssertTrue(result.sceneMappingUnavailable)
            XCTAssertEqual(result.layout.screenRect, CGRect(origin: .zero, size: result.layout.canvasSize))
        }
    }

    private func appliedScene(_ svg: String) throws -> AppliedPresentationScene {
        let validated = try PresentationSceneValidator.validate(svgText: svg, source: .bundled)
        return AppliedPresentationScene(definition: PresentationSceneDefinition(metadata: validated.metadata,
            sanitizedSVGText: validated.sanitizedSVGText, source: .bundled,
            fileURL: URL(fileURLWithPath: "/tmp/affine-scene.svg"), isUserModifiedBundled: false))
    }

    private func assertInvalid(
        _ svgText: String,
        source: PresentationSceneSource = .bundled,
        contains expectedText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try PresentationSceneValidator.validate(svgText: svgText, source: source), file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.contains(expectedText), error.localizedDescription, file: file, line: line)
        }
    }

    private func bundledSceneSourceURLs() -> [URL] {
        let repoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scenesURL = repoURL.appendingPathComponent("SnipSnipSnip/PresentationScenes", isDirectory: true)
        return PresentationSceneStore.bundledSceneResourceFilenames.map { scenesURL.appendingPathComponent($0) }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sceneSVG(
        id: String = "builtin.test-scene",
        name: String = "Test Scene",
        version: Int = 1,
        width: Int = 200,
        height: Int = 120,
        imageHref: String = "snipsnipsnip:primaryScreenshot",
        imageSlotReference: String? = nil,
        metadataSlots: [String]? = nil,
        metadata: String? = nil,
        extraElements: String = "",
        marker: String = ""
    ) -> String {
        let slots = metadataSlots ?? [
            #"{"id":"primaryScreenshot","type":"image","required":true,"label":"Screenshot"}"#,
            #"{"id":"title","type":"text","label":"Title","defaultValue":"Hello"}"#,
        ]
        let metadataText = metadata ?? """
        {
          "schema": "\(PresentationSceneMetadata.schema)",
          "schemaVersion": \(PresentationSceneMetadata.supportedSchemaVersion),
          "id": "\(id)",
          "name": "\(name)",
          "version": \(version),
          "canvas": { "width": \(width), "height": \(height) },
          "slots": [\(slots.joined(separator: ","))]
        }
        """
        let slotReference = imageSlotReference ?? imageHref

        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">
          <metadata id="snipsnipsnip-scene">
        \(metadataText)
          </metadata>
          <rect x="0" y="0" width="\(width)" height="\(height)" fill="#f8fafc"/>
          <image id="primary-screenshot" data-sss-slot="primaryScreenshot" href="\(slotReference)" x="20" y="30" width="\(max(width - 40, 1))" height="80" preserveAspectRatio="xMidYMid slice"/>
          <text id="title-text" data-sss-slot="title" x="\(width / 2)" y="20" text-anchor="middle">Hello</text>
          <desc>\(marker)</desc>
          \(extraElements)
        </svg>
        """
    }
}

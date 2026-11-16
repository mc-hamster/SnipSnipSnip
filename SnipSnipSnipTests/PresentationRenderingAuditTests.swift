import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

@MainActor
final class PresentationRenderingAuditTests: XCTestCase {
    func testPlainUncappedRenderingKeepsOriginalImageIdentity() throws {
        let image = makeCoordinateImage(width: 100, height: 80)
        let result = try XCTUnwrap(ScreenshotPresentationRenderer.renderWithLayout(contentImage: image, presentation: .plain))
        XCTAssertTrue(result.image === image)
        XCTAssertEqual(result.pixelScale, 1)
    }

    func testInvisibleShadowsDoNotReserveCanvasMargins() {
        var presentation = ScreenshotPresentationPreset.lifted.settings
        presentation.padding = 12
        for disabledSetting in 0..<3 {
            var candidate = presentation
            switch disabledSetting {
            case 0: candidate.shadow = .off
            case 1: candidate.shadowOpacity = 0
            default: candidate.shadowBlurRadius = 0
            }
            let layout = ScreenshotPresentationRenderer.layout(contentSize: CGSize(width: 200, height: 100), presentation: candidate)
            XCTAssertEqual(layout.canvasSize, CGSize(width: 224, height: 124))
            XCTAssertEqual(layout.subjectRect, CGRect(x: 12, y: 12, width: 200, height: 100))
        }
    }

    func testOversizedSubjectsHonorEveryAlignmentAndOffset() {
        for fit in PresentationSubjectFit.allCases {
            for alignment in PresentationSubjectAlignment.allCases {
                let placement = PresentationSubjectPlacement(fit: fit, alignment: alignment,
                    scale: fit == .contain ? 2 : 1, offset: CGSize(width: 7, height: -3))
                let presentation = ScreenshotPresentation(isEnabled: true, background: .transparent,
                    canvas: .custom(width: 100, height: 80), subjectPlacement: placement,
                    padding: 0, cornerRadius: 0, shadow: .off)
                let layout = ScreenshotPresentationRenderer.layout(contentSize: CGSize(width: 200, height: 160), presentation: presentation)
                XCTAssertEqual(layout.subjectRect, CGRect(x: -100 * alignment.xFactor + 7,
                    y: -80 * alignment.yFactor - 3, width: 200, height: 160), "\(fit) / \(alignment)")
            }
        }
    }

    func testCappedNativePreviewPreservesLogicalLayoutAcrossEveryFrameAndCanvas() throws {
        let frames: [PresentationFrame] = [.none, .browser(.default), .macOSWindow(.default), .phone(.phone), .tablet(.tablet)]
        let canvases: [PresentationCanvas] = [.original, .preset(.story), .custom(width: 800, height: 500)]
        let logicalSize = CGSize(width: 400, height: 260)
        let thumbnail = makeCoordinateImage(width: 100, height: 65)
        for frame in frames {
            for canvas in canvases {
                let presentation = ScreenshotPresentation(isEnabled: true, background: .transparent,
                    canvas: canvas, frame: frame, padding: 31, cornerRadius: 24, shadow: .drop)
                let expected = ScreenshotPresentationRenderer.layout(contentSize: logicalSize, presentation: presentation)
                let preview = try XCTUnwrap(ScreenshotPresentationRenderer.renderWithLayout(contentImage: thumbnail,
                    presentation: presentation, maxPixelDimension: 130, logicalContentSize: logicalSize))
                let scale = 130 / max(expected.canvasSize.width, expected.canvasSize.height)
                XCTAssertEqual(preview.pixelScale, scale, accuracy: 0.00001)
                XCTAssertLessThanOrEqual(max(preview.image.width, preview.image.height), 130)
                assertRect(preview.layout.subjectRect, equals: expected.subjectRect, scaledBy: scale)
                assertRect(preview.layout.screenRect, equals: expected.screenRect, scaledBy: scale)
                assertRect(preview.layout.contentRect, equals: expected.contentRect, scaledBy: scale)
            }
        }
    }

    func testEveryCanvasPresetRetainsItsAspectRatio() {
        for preset in PresentationCanvasPreset.allCases {
            let presentation = ScreenshotPresentation(isEnabled: true, background: .transparent,
                canvas: .preset(preset), padding: 23, cornerRadius: 12, shadow: .drop)
            let size = ScreenshotPresentationRenderer.outputSize(for: CGSize(width: 400, height: 260), presentation: presentation)
            XCTAssertEqual(size.width / size.height, preset.aspectRatio, accuracy: 0.005, preset.rawValue)
        }
    }

    func testPhoneSensorHousingRemainsAboveScreenshotPixels() throws {
        for orientation in PresentationDeviceOrientation.allCases {
            for showsSensor in [false, true] {
                let content = makeSolidImage(width: 180, height: 390, color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
                let style = PresentationDeviceFrameStyle(orientation: orientation, showsSensorHousing: showsSensor, castsDeviceShadow: false)
                let presentation = ScreenshotPresentation(isEnabled: true, background: .transparent,
                    frame: .phone(style), padding: 20, cornerRadius: 0, shadow: .off)
                let result = try XCTUnwrap(ScreenshotPresentationRenderer.renderWithLayout(contentImage: content, presentation: presentation))
                let screen = result.layout.screenRect
                let thickness = min(screen.height * (orientation == .portrait ? 0.030 : 0.070), 18)
                let point = orientation == .portrait
                    ? CGPoint(x: screen.midX, y: screen.minY + screen.height * 0.012 + thickness / 2)
                    : CGPoint(x: screen.maxX - screen.width * 0.012 - thickness / 2, y: screen.midY)
                let pixel = samplePixel(in: result.image, topLeftX: Int(point.x), topLeftY: Int(point.y))
                if showsSensor { XCTAssertLessThan(pixel.red, 100) }
                else if result.layout.contentRect.contains(point) { XCTAssertGreaterThan(pixel.red, 240) }
            }
        }
    }

    func testDeviceHomeIndicatorsRemainAboveScreenshotPixels() throws {
        for isTablet in [false, true] {
            for orientation in PresentationDeviceOrientation.allCases {
                let style = PresentationDeviceFrameStyle(orientation: orientation, showsSensorHousing: false, castsDeviceShadow: false)
                let presentation = ScreenshotPresentation(isEnabled: true, background: .transparent,
                    frame: isTablet ? .tablet(style) : .phone(style), padding: 20, cornerRadius: 0, shadow: .off)
                let content = makeSolidImage(width: 180, height: 390, color: PixelSample(red: 0, green: 0, blue: 0, alpha: 255))
                let result = try XCTUnwrap(ScreenshotPresentationRenderer.renderWithLayout(contentImage: content, presentation: presentation))
                let screen = result.layout.screenRect
                let length = min((orientation == .portrait ? screen.width : screen.height) * (isTablet ? 0.20 : 0.28), isTablet ? 78 : 92)
                let thickness = max(min(length * 0.045, 4), 2)
                let point = orientation == .portrait
                    ? CGPoint(x: screen.midX, y: screen.maxY - screen.height * 0.025 - thickness / 2)
                    : CGPoint(x: screen.minX + screen.width * 0.025 + thickness / 2, y: screen.midY)
                XCTAssertGreaterThan(samplePixel(in: result.image, topLeftX: Int(point.x), topLeftY: Int(point.y)).red, 70)
            }
        }
    }

    func testAllNativeBackgroundsKeepScreenshotContentAndBoundedPreview() throws {
        let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
        let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        let backgrounds: [ScreenshotPresentationBackground] = [.transparent,
            .solid(RGBAColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)),
            .twoColorGradient(start: black, end: white), .radialSpotlight(base: black, spotlight: white),
            .blurredScreenshot(tint: RGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.35))]
        let content = makeSolidImage(width: 200, height: 100, color: PixelSample(red: 200, green: 80, blue: 40, alpha: 255))
        for background in backgrounds {
            let presentation = ScreenshotPresentation(isEnabled: true, background: background,
                padding: 40, cornerRadius: 12, shadow: .off)
            let result = try XCTUnwrap(ScreenshotPresentationRenderer.renderWithLayout(contentImage: content,
                presentation: presentation, maxPixelDimension: 140))
            let center = CGPoint(x: result.layout.contentRect.midX, y: result.layout.contentRect.midY)
            let pixel = samplePixel(in: result.image, topLeftX: Int(center.x), topLeftY: Int(center.y))
            XCTAssertEqual(Double(pixel.red), 200, accuracy: 2)
            XCTAssertEqual(Double(pixel.green), 80, accuracy: 2)
            XCTAssertEqual(Double(pixel.blue), 40, accuracy: 2)
            XCTAssertEqual(pixel.alpha, 255)
            XCTAssertLessThanOrEqual(max(result.image.width, result.image.height), 140)
        }
    }

    func testNativeFrameTextRendersInsideTopChrome() throws {
        let content = makeSolidImage(width: 300, height: 180, color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
        for isBrowser in [false, true] {
            for scheme in PresentationAppearanceScheme.allCases {
                func frame(text: String) -> PresentationFrame {
                    isBrowser
                        ? .browser(PresentationBrowserFrameStyle(title: "", address: text, scheme: scheme, showsTrafficLights: false))
                        : .macOSWindow(PresentationMacWindowFrameStyle(title: text, scheme: scheme, showsTrafficLights: false))
                }
                var presentation = ScreenshotPresentation(isEnabled: true, background: .transparent,
                    frame: frame(text: "MMMMMMMM"), padding: 20, cornerRadius: 0, shadow: .off)
                let labeled = try XCTUnwrap(ScreenshotPresentationRenderer.renderWithLayout(contentImage: content, presentation: presentation))
                presentation.frame = frame(text: "")
                let empty = try XCTUnwrap(ScreenshotPresentationRenderer.renderWithLayout(contentImage: content, presentation: presentation))
                var changedChromePixels = 0
                for y in Int(labeled.layout.subjectRect.minY)..<Int(labeled.layout.screenRect.minY) {
                    for x in Int(labeled.layout.subjectRect.minX)..<Int(labeled.layout.subjectRect.maxX) {
                        if samplePixel(in: labeled.image, topLeftX: x, topLeftY: y) != samplePixel(in: empty.image, topLeftX: x, topLeftY: y) {
                            changedChromePixels += 1
                        }
                    }
                }
                XCTAssertGreaterThan(changedChromePixels, 8, "\(isBrowser ? "Browser" : "Window") / \(scheme)")
            }
        }
    }

    private func assertRect(_ actual: CGRect, equals logical: CGRect, scaledBy scale: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, logical.minX * scale, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.minY, logical.minY * scale, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.width, logical.width * scale, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.height, logical.height * scale, accuracy: 0.0001, file: file, line: line)
    }
}

import AppKit
import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class CompositionRenderingRegressionTests: XCTestCase {
    func testWeightedRowAndComparisonMeasureCaptionsAtAllocatedWidths() throws {
        let descriptor = CompositionAssetDescriptor(pixelWidth: 100, pixelHeight: 40)
        let items = [
            CompositionItem(assetID: descriptor.id, weight: 1, caption: String(repeating: "W", count: 20)),
            CompositionItem(assetID: descriptor.id, weight: 3),
        ]
        var appearance = CompositionCanvasAppearance.pixelPreserving
        appearance.captionFontSize = 10
        appearance.captionInsets = .zero
        for mode in [CompositionLayoutMode.row, .compare] {
            let composition = CompositionSnapshot(items: items,
                layout: CompositionLayoutConfiguration(mode: mode, sizingMode: .weighted),
                canvas: CompositionCanvasState(appearance: appearance))
            let layout = try CompositionLayoutEngine.layout(composition: composition,
                assetDescriptors: [descriptor.id: descriptor])
            let first = try XCTUnwrap(layout.items.first)
            XCTAssertEqual(first.imageClipRect.width, 50)
            XCTAssertEqual(try XCTUnwrap(first.captionRect).height, 39,
                "The 50-pixel card needs three caption lines in \(mode)")
            XCTAssertEqual(layout.canvasSize.height, 79)
        }
    }

    func testColumnMeasuresCaptionAtSharedViewportWidth() throws {
        let narrow = CompositionAssetDescriptor(pixelWidth: 50, pixelHeight: 40)
        let wide = CompositionAssetDescriptor(pixelWidth: 150, pixelHeight: 40)
        var appearance = CompositionCanvasAppearance.pixelPreserving
        appearance.captionFontSize = 10
        appearance.captionInsets = .zero
        let composition = CompositionSnapshot(items: [
            CompositionItem(assetID: narrow.id, caption: String(repeating: "W", count: 20)),
            CompositionItem(assetID: wide.id),
        ], layout: CompositionLayoutConfiguration(mode: .column),
            canvas: CompositionCanvasState(appearance: appearance))
        let layout = try CompositionLayoutEngine.layout(composition: composition,
            assetDescriptors: [narrow.id: narrow, wide.id: wide])
        XCTAssertEqual(try XCTUnwrap(layout.items.first?.captionRect).height, 13)
        XCTAssertEqual(layout.canvasSize.height, 93)
    }

    func testAboveCaptionsMoveWipeGeometryWithImageForBothAxes() throws {
        let primary = solidAsset(red: 255, green: 0, blue: 0, width: 100, height: 80)
        let secondary = solidAsset(red: 0, green: 0, blue: 255, width: 100, height: 80)
        var appearance = CompositionCanvasAppearance.pixelPreserving
        appearance.captionPlacement = .above
        appearance.captionColor = .clear
        appearance.captionFontSize = 10
        appearance.captionInsets = .zero
        for axis in CompositionAxis.allCases {
            let composition = CompositionSnapshot(items: [
                CompositionItem(assetID: primary.descriptor.id, caption: "Caption"),
                CompositionItem(assetID: secondary.descriptor.id),
            ], layout: CompositionLayoutConfiguration(mode: .compare),
                comparison: CompositionComparisonSettings(mode: .wipe, axis: axis, showsLabels: false,
                    registrationMode: .disabled),
                canvas: CompositionCanvasState(appearance: appearance))
            let result = try CompositionRenderer.render(composition: composition,
                assets: [primary.descriptor.id: primary, secondary.descriptor.id: secondary])
            let imageRect = try XCTUnwrap(result.layout.items.first).imageClipRect
            let comparison = try XCTUnwrap(result.layout.comparison)
            XCTAssertEqual(comparison.sharedFrame, imageRect)
            let divider = try XCTUnwrap(comparison.dividerRect)
            if axis == .horizontal {
                XCTAssertEqual(divider.minY, imageRect.minY)
                XCTAssertEqual(divider.maxY, imageRect.maxY)
                XCTAssertEqual(samplePixel(in: result.image, topLeftX: 20, topLeftY: Int(imageRect.maxY - 4)),
                    PixelSample(red: 0, green: 0, blue: 255, alpha: 255))
            } else {
                XCTAssertEqual(divider.midY, imageRect.midY)
                XCTAssertEqual(samplePixel(in: result.image, topLeftX: 20, topLeftY: Int(imageRect.midY - 4)),
                    PixelSample(red: 0, green: 0, blue: 255, alpha: 255))
            }
        }
    }

    func testAboveStepCaptionsKeepBadgesInsideTheirImagesForEveryFlow() throws {
        let descriptor = CompositionAssetDescriptor(pixelWidth: 100, pixelHeight: 80)
        var appearance = CompositionCanvasAppearance.pixelPreserving
        appearance.captionPlacement = .above
        for flow in CompositionStepFlow.allCases {
            let composition = CompositionSnapshot(items: [
                CompositionItem(assetID: descriptor.id, caption: "Step caption"),
                CompositionItem(assetID: descriptor.id, caption: "Next caption"),
            ], layout: CompositionLayoutConfiguration(mode: .steps),
                steps: CompositionStepsSettings(flow: flow),
                canvas: CompositionCanvasState(appearance: appearance))
            let layout = try CompositionLayoutEngine.layout(composition: composition,
                assetDescriptors: [descriptor.id: descriptor])
            for item in layout.items {
                let badge = try XCTUnwrap(item.badgeRect)
                XCTAssertEqual(badge.minY, item.imageClipRect.minY + 8)
                XCTAssertTrue(item.imageClipRect.contains(badge))
                XCTAssertEqual(layout.hitTest(CGPoint(x: badge.midX, y: badge.midY))?.region, .stepBadge)
            }
        }
    }

    func testCaptionBackgroundAndTextStayInCaptionAtPreviewScale() throws {
        let asset = solidAsset(red: 0, green: 0, blue: 0, width: 200, height: 100)
        var appearance = CompositionCanvasAppearance.pixelPreserving
        appearance.captionBackgroundColor = RGBAColor(red: 0, green: 1, blue: 0, alpha: 1)
        appearance.captionColor = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        appearance.captionFontSize = 20
        let expectedBackground = try renderedSwatch(for: appearance.captionBackgroundColor.cgColor)
        let composition = CompositionSnapshot(items: [CompositionItem(assetID: asset.descriptor.id, caption: "Caption")],
            layout: CompositionLayoutConfiguration(mode: .row),
            canvas: CompositionCanvasState(appearance: appearance))
        for cap in [nil, 100] as [Int?] {
            let result = try CompositionRenderer.render(composition: composition,
                assets: [asset.descriptor.id: asset],
                options: CompositionRenderOptions(targetMaximumPixelDimension: cap))
            let rect = try XCTUnwrap(result.layout.items.first?.captionRect)
            XCTAssertEqual(samplePixel(in: result.image, topLeftX: Int(rect.maxX - 3), topLeftY: Int(rect.midY)),
                expectedBackground)
            XCTAssertGreaterThan(redPixelCount(in: result.image, rect: rect), 5)
            XCTAssertEqual(result.logicalCanvasSize.width, 200)
        }
    }

    func testTitleTextUsesTopLeftLayoutCoordinates() throws {
        let asset = solidAsset(red: 0, green: 0, blue: 0, width: 200, height: 160)
        var appearance = CompositionCanvasAppearance.pixelPreserving
        appearance.titleColor = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let composition = CompositionSnapshot(items: [CompositionItem(assetID: asset.descriptor.id)],
            layout: CompositionLayoutConfiguration(mode: .row),
            canvas: CompositionCanvasState(title: "Title", appearance: appearance))
        for cap in [nil, 100] as [Int?] {
            let result = try CompositionRenderer.render(composition: composition,
                assets: [asset.descriptor.id: asset],
                options: CompositionRenderOptions(targetMaximumPixelDimension: cap))
            let title = try XCTUnwrap(result.layout.titleRect)
            XCTAssertGreaterThan(redPixelCount(in: result.image, rect: title), 5)
            XCTAssertEqual(redPixelCount(in: result.image, rect: CGRect(x: title.minX,
                y: CGFloat(result.image.height) - title.maxY, width: title.width, height: title.height)), 0)
        }
    }

    func testStepBadgePixelsMatchHitGeometryAtBothRenderScales() throws {
        let asset = solidAsset(red: 0, green: 0, blue: 0, width: 200, height: 160)
        var appearance = CompositionCanvasAppearance.pixelPreserving
        appearance.stepBadgeFill = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        appearance.stepBadgeForeground = .clear
        let expectedBadge = try renderedSwatch(for: appearance.stepBadgeFill.nsColor.cgColor)
        let composition = CompositionSnapshot(items: [CompositionItem(assetID: asset.descriptor.id)],
            layout: CompositionLayoutConfiguration(mode: .steps),
            canvas: CompositionCanvasState(appearance: appearance))
        for cap in [nil, 100] as [Int?] {
            let result = try CompositionRenderer.render(composition: composition,
                assets: [asset.descriptor.id: asset],
                options: CompositionRenderOptions(targetMaximumPixelDimension: cap))
            let badge = try XCTUnwrap(result.layout.items.first?.badgeRect)
            XCTAssertEqual(samplePixel(in: result.image, topLeftX: Int(badge.midX), topLeftY: Int(badge.midY)),
                expectedBadge)
            XCTAssertEqual(samplePixel(in: result.image, topLeftX: Int(badge.midX),
                topLeftY: result.image.height - Int(badge.midY)), PixelSample(red: 0, green: 0, blue: 0, alpha: 255))
        }
    }

    func testDifferenceCuesRemainActiveAtZeroThresholdAndRespectRoundedCards() throws {
        let primary = solidAsset(red: 0, green: 0, blue: 0, width: 80, height: 80)
        let secondary = solidAsset(red: 255, green: 255, blue: 255, width: 80, height: 80)
        var appearance = CompositionCanvasAppearance.pixelPreserving
        appearance.itemCornerRadius = 20
        var composition = CompositionSnapshot(items: [
            CompositionItem(assetID: primary.descriptor.id),
            CompositionItem(assetID: secondary.descriptor.id),
        ], layout: CompositionLayoutConfiguration(mode: .compare),
            comparison: CompositionComparisonSettings(mode: .difference, changeThreshold: 0,
                showsLabels: false, registrationMode: .disabled, unchangedContentOpacity: 0,
                differenceCueStyle: .luminance),
            canvas: CompositionCanvasState(appearance: appearance))
        let assets = [primary.descriptor.id: primary, secondary.descriptor.id: secondary]
        let luminance = try CompositionRenderer.render(composition: composition, assets: assets)
        for mode in [CompositionComparisonMode.difference, .changeHighlight] {
            composition.comparison.mode = mode
            for cue in CompositionDifferenceCueStyle.allCases {
                composition.comparison.differenceCueStyle = cue
                let result = try CompositionRenderer.render(composition: composition, assets: assets)
                XCTAssertEqual(samplePixel(in: result.image, topLeftX: 0, topLeftY: 0).alpha, 0,
                    "\(mode) / \(cue) must preserve the rounded card corner")
                if mode == .difference, cue != .luminance {
                    XCTAssertNotEqual(samplePixel(in: result.image, topLeftX: 40, topLeftY: 40),
                        samplePixel(in: luminance.image, topLeftX: 40, topLeftY: 40),
                        "\(cue) must remain enabled when threshold is zero")
                }
            }
        }
    }

    func testDifferencePreservesUnchangedContextAndSupportsIntensityAboveOne() throws {
        let primary = solidAsset(red: 80, green: 80, blue: 80, width: 40, height: 40)
        let secondary = solidAsset(red: 112, green: 112, blue: 112, width: 40, height: 40)
        var composition = CompositionSnapshot(items: [
            CompositionItem(assetID: primary.descriptor.id),
            CompositionItem(assetID: primary.descriptor.id),
        ], layout: CompositionLayoutConfiguration(mode: .compare),
            comparison: CompositionComparisonSettings(mode: .difference, changeThreshold: 0,
                showsLabels: false, registrationMode: .disabled, unchangedContentOpacity: 1,
                differenceCueStyle: .luminance),
            canvas: CompositionCanvasState(appearance: .pixelPreserving))
        let assets = [primary.descriptor.id: primary, secondary.descriptor.id: secondary]
        let unchanged = try CompositionRenderer.render(composition: composition, assets: assets)
        XCTAssertEqual(samplePixel(in: unchanged.image, topLeftX: 20, topLeftY: 20),
            PixelSample(red: 80, green: 80, blue: 80, alpha: 255))

        composition.items[1] = CompositionItem(assetID: secondary.descriptor.id)
        composition.comparison.unchangedContentOpacity = 0
        let normal = try CompositionRenderer.render(composition: composition, assets: assets)
        composition.comparison.differenceIntensity = 2
        let amplified = try CompositionRenderer.render(composition: composition, assets: assets)
        XCTAssertGreaterThan(samplePixel(in: amplified.image, topLeftX: 20, topLeftY: 20).red,
            samplePixel(in: normal.image, topLeftX: 20, topLeftY: 20).red)
    }

    func testCombinedDifferenceCueRetainsPatternAwayFromEdges() throws {
        let primary = solidAsset(red: 0, green: 0, blue: 0, width: 80, height: 80)
        let secondary = solidAsset(red: 255, green: 255, blue: 255, width: 80, height: 80)
        let composition = CompositionSnapshot(items: [
            CompositionItem(assetID: primary.descriptor.id),
            CompositionItem(assetID: secondary.descriptor.id),
        ], layout: CompositionLayoutConfiguration(mode: .compare),
            comparison: CompositionComparisonSettings(mode: .difference, changeThreshold: 0.1,
                showsLabels: false, registrationMode: .disabled, unchangedContentOpacity: 0,
                differenceCueStyle: .outlineAndPattern),
            canvas: CompositionCanvasState(appearance: .pixelPreserving))
        let result = try CompositionRenderer.render(composition: composition,
            assets: [primary.descriptor.id: primary, secondary.descriptor.id: secondary])
        let values = (20..<60).map { samplePixel(in: result.image, topLeftX: $0, topLeftY: 40).red }
        XCTAssertGreaterThan(try XCTUnwrap(values.max()), 100)
        XCTAssertLessThan(try XCTUnwrap(values.min()), 100)
    }

    func testFreeformOverlayCaptionsDoNotAddInvisibleCanvasPadding() throws {
        let descriptor = CompositionAssetDescriptor(pixelWidth: 100, pixelHeight: 80)
        for placement in [CompositionCaptionPlacement.overlayTop, .overlayBottom] {
            var appearance = CompositionCanvasAppearance.pixelPreserving
            appearance.captionPlacement = placement
            let composition = CompositionSnapshot(items: [
                CompositionItem(assetID: descriptor.id, caption: "Caption",
                    freeformFrame: CGRect(x: -20, y: -10, width: 100, height: 80)),
            ], layout: CompositionLayoutConfiguration(mode: .freeform),
                canvas: CompositionCanvasState(appearance: appearance))
            let layout = try CompositionLayoutEngine.layout(composition: composition,
                assetDescriptors: [descriptor.id: descriptor])
            XCTAssertEqual(layout.canvasSize, CGSize(width: 100, height: 80))
            XCTAssertEqual(layout.contentRect, layout.canvasRect)
            XCTAssertTrue(layout.canvasRect.contains(try XCTUnwrap(layout.items.first?.captionRect)))
        }
    }

    private func solidAsset(red: UInt8, green: UInt8, blue: UInt8, width: Int, height: Int) -> CompositionAsset {
        CompositionAsset(image: makeSolidImage(width: width, height: height,
            color: PixelSample(red: red, green: green, blue: blue, alpha: 255)))
    }

    private func renderedSwatch(for color: CGColor) throws -> PixelSample {
        // AppKit calibrated colors and Quartz device colors are converted into
        // the renderer's sRGB output; raw channel literals are not its pixels.
        let context = try XCTUnwrap(SRGBBitmapContext.make(width: 1, height: 1))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return samplePixel(in: try XCTUnwrap(context.makeImage()), topLeftX: 0, topLeftY: 0)
    }

    private func redPixelCount(in image: CGImage, rect: CGRect) -> Int {
        let bounds = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !bounds.isNull else { return 0 }
        var count = 0
        for y in Int(bounds.minY)..<Int(bounds.maxY) {
            for x in Int(bounds.minX)..<Int(bounds.maxX) {
                let pixel = samplePixel(in: image, topLeftX: x, topLeftY: y)
                if pixel.red > 150, pixel.green < 100, pixel.blue < 100 { count += 1 }
            }
        }
        return count
    }
}

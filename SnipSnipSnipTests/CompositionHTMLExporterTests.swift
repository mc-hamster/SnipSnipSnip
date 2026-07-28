import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import SnipSnipSnip

final class CompositionHTMLExporterTests: XCTestCase {
    func testSingleFileExportIsOfflineAndUsesHashPinnedCSP() throws {
        let html = try CompositionHTMLExporter.html(for: CompositionHTMLDocument(
            title: "Release Review",
            layout: .grid(columns: 2),
            items: [
                item("Before", color: PixelSample(red: 220, green: 40, blue: 40, alpha: 255)),
                item("After", color: PixelSample(red: 40, green: 100, blue: 220, alpha: 255)),
            ]
        ))

        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("<html lang=\"en\" dir=\"auto\">"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("img-src data:"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertTrue(html.contains("object-src 'none'"))
        XCTAssertTrue(html.contains("base-uri 'none'"))
        XCTAssertFalse(html.contains("'unsafe-inline'"))
        XCTAssertFalse(html.contains("'unsafe-eval'"))
        XCTAssertFalse(html.contains("style="))
        XCTAssertFalse(html.contains(".style."))
        XCTAssertFalse(html.contains("<link"))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertFalse(html.contains("file://"))
        XCTAssertEqual(html.components(separatedBy: "src=\"data:image/png;base64,").count - 1, 2)

        let style = try content(between: "<style>", and: "</style>", in: html)
        let script = try content(between: "<script>", and: "</script>", in: html)
        XCTAssertTrue(html.contains("style-src '\(hashSource(for: style))'"))
        XCTAssertTrue(html.contains("script-src '\(hashSource(for: script))'"))
    }

    func testLanguageTagIsLocalizedSanitizedAndDirectionIsAutomatic() throws {
        let arabic = try CompositionHTMLExporter.html(for: CompositionHTMLDocument(
            title: "الخطوات",
            layout: .steps,
            items: [item("افتح")],
            languageTag: "ar_SA"
        ))
        let hostile = try CompositionHTMLExporter.html(for: CompositionHTMLDocument(
            title: "Safe",
            layout: .grid(columns: 1),
            items: [item("Safe")],
            languageTag: #"en" onload="alert(1)"#
        ))

        XCTAssertTrue(arabic.contains("<html lang=\"ar-SA\" dir=\"auto\">"))
        XCTAssertTrue(hostile.contains("<html lang=\"en\" dir=\"auto\">"))
        XCTAssertFalse(hostile.contains("onload="))
    }

    func testUserTextIsEscapedAndEncodedImageCarriesNoSourceMetadata() throws {
        let hostileTitle = #"<script>alert("title")</script> & "quoted""#
        let hostileCaption = #"<img src=x onerror=alert("caption")> 'caption'"#
        let html = try CompositionHTMLExporter.html(for: CompositionHTMLDocument(
            title: hostileTitle,
            layout: .grid(columns: 1),
            items: [
                CompositionHTMLItem(
                    image: makeSolidImage(
                        width: 3,
                        height: 2,
                        color: PixelSample(red: 90, green: 180, blue: 120, alpha: 255)
                    ),
                    title: hostileTitle,
                    caption: hostileCaption,
                    accessibilityLabel: #""Preview" <unsafe> & private"#
                ),
            ]
        ))

        XCTAssertFalse(html.contains(#"<script>alert("title")</script>"#))
        XCTAssertFalse(html.contains(#"<img src=x onerror=alert("caption")>"#))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(&quot;title&quot;)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("&lt;img src=x onerror=alert(&quot;caption&quot;)&gt;"))
        XCTAssertTrue(html.contains("&quot;Preview&quot; &lt;unsafe&gt; &amp; private"))
        XCTAssertFalse(html.contains("/Users/"))
        XCTAssertFalse(html.contains("kCGImageProperty"))

        let encodedPNG = try firstEmbeddedPNG(in: html)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encodedPNG as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        for metadataKey in [
            kCGImagePropertyExifDictionary,
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyTIFFDictionary,
            kCGImagePropertyIPTCDictionary,
        ] {
            XCTAssertNil(
                userAuthoredMetadata(in: properties[metadataKey]),
                "Unexpected source metadata for \(metadataKey)"
            )
        }
    }

    private func userAuthoredMetadata(in value: Any?) -> [AnyHashable: Any]? {
        guard let dictionary = value as? [AnyHashable: Any] else {
            return nil
        }
        let generatedKeys: Set<String> = [
            kCGImagePropertyExifColorSpace as String,
            kCGImagePropertyExifPixelXDimension as String,
            kCGImagePropertyExifPixelYDimension as String,
            kCGImagePropertyTIFFCompression as String,
            kCGImagePropertyTIFFPhotometricInterpretation as String,
            kCGImagePropertyTIFFResolutionUnit as String,
            kCGImagePropertyTIFFXResolution as String,
            kCGImagePropertyTIFFYResolution as String,
        ]
        let userAuthored = dictionary.filter { key, _ in
            !generatedKeys.contains(String(describing: key))
        }
        return userAuthored.isEmpty ? nil : userAuthored
    }

    func testComparisonModesExposeTheirStaticFallbackAndAccessibleControls() throws {
        let cases: [(CompositionHTMLComparisonMode, String, [String])] = [
            (
                .wipe(axis: .vertical, positionPercent: 38),
                "wipe",
                ["data-axis=\"vertical\"", "data-wipe-range", "value=\"38\""]
            ),
            (
                .overlay(afterOpacityPercent: 62),
                "overlay",
                ["data-overlay-range", "value=\"62\""]
            ),
            (
                .blink(intervalMilliseconds: 850, poster: .after),
                "blink",
                ["data-blink-before", "data-blink-toggle", "data-blink-after", "data-blink-interval"]
            ),
            (
                .difference(intensityPercent: 74),
                "difference",
                ["data-difference-range", "value=\"74\""]
            ),
        ]

        for (mode, name, markers) in cases {
            let html = try comparisonHTML(mode: mode)
            XCTAssertTrue(html.contains("data-comparison-mode=\"\(name)\""))
            XCTAssertTrue(html.contains("aria-label=\"Original and Revised comparison\""))
            XCTAssertEqual(html.components(separatedBy: "src=\"data:image/png;base64,").count - 1, 2)
            for marker in markers {
                XCTAssertTrue(html.contains(marker), "\(name) is missing \(marker)")
            }
        }
    }

    func testSideBySideComparisonIncludesInteractiveViewControls() throws {
        let html = try comparisonHTML(mode: .sideBySide)

        XCTAssertTrue(html.contains("data-comparison-mode=\"side-by-side\""))
        XCTAssertTrue(html.contains(">Compare Using"))
        XCTAssertTrue(html.contains("<option value=\"side-by-side\" selected>Side by Side</option>"))
        XCTAssertTrue(html.contains("<option value=\"wipe\">Wipe</option>"))
        XCTAssertTrue(html.contains("<option value=\"overlay\">Overlay</option>"))
        XCTAssertTrue(html.contains("<option value=\"blink\">Blink</option>"))
        XCTAssertTrue(html.contains("<option value=\"difference\">Difference</option>"))
        XCTAssertTrue(
            html.contains(
                "data-side-by-side-view=\"both\" aria-pressed=\"true\""
            )
        )
        XCTAssertTrue(html.contains("data-side-by-side-view=\"before\""))
        XCTAssertTrue(html.contains("data-side-by-side-view=\"after\""))
        XCTAssertTrue(html.contains("data-comparison-status"))
        XCTAssertTrue(
            html.contains(
                ".comparison[data-active-mode=\"side-by-side\"].show-before .comparison-after"
            )
        )
        XCTAssertTrue(
            html.contains(
                "modeSelect.addEventListener(\"change\""
            )
        )
    }

    func testComparisonViewerExposesAllModesDirectWipeZoomAndRestorableState() throws {
        let html = try CompositionHTMLExporter.html(for: CompositionHTMLDocument(
            title: "Comparison",
            layout: .comparison(CompositionHTMLComparison(
                mode: .sideBySide,
                beforeLabel: "Original",
                afterLabel: "Revised"
            )),
            items: [item("Original"), item("Revised")],
            renderedDifference: item("Rendered Difference"),
            renderedChangeHighlight: item("Rendered Highlight")
        ))

        XCTAssertTrue(html.contains("<option value=\"change-highlight\">Highlight Changes</option>"))
        XCTAssertTrue(html.contains("data-comparison-stage"))
        XCTAssertTrue(html.contains("data-wipe-axis"))
        XCTAssertTrue(html.contains("data-zoom-out"))
        XCTAssertTrue(html.contains("data-zoom-fit"))
        XCTAssertTrue(html.contains("data-zoom-in"))
        XCTAssertTrue(html.contains("stage.addEventListener(\"pointerdown\""))
        XCTAssertTrue(html.contains("new URLSearchParams(location.hash"))
        XCTAssertTrue(html.contains("history.replaceState"))
        XCTAssertEqual(
            html.components(separatedBy: "src=\"data:image/png;base64,").count - 1,
            4
        )
    }

    func testStepsHaveStaticAnchorNavigationAndEnhancedPreviousNextControls() throws {
        let html = try CompositionHTMLExporter.html(for: CompositionHTMLDocument(
            title: "Publish a Release",
            layout: .steps,
            items: [
                item("Open Settings", caption: "Choose the project.", stepLabel: "C"),
                item("Review Build", caption: "Confirm the version.", stepLabel: "D"),
                item("Publish", caption: "Submit the release.", stepLabel: "E"),
            ]
        ))

        XCTAssertTrue(html.contains("<nav class=\"step-navigation\" aria-label=\"Steps\">"))
        XCTAssertTrue(html.contains("href=\"#step-1\""))
        XCTAssertTrue(html.contains("href=\"#step-2\""))
        XCTAssertTrue(html.contains("href=\"#step-3\""))
        XCTAssertTrue(html.contains("id=\"step-1\""))
        XCTAssertTrue(html.contains("id=\"step-2\""))
        XCTAssertTrue(html.contains("id=\"step-3\""))
        XCTAssertTrue(html.contains("data-step-previous"))
        XCTAssertTrue(html.contains("data-step-next"))
        XCTAssertTrue(html.contains("aria-live=\"polite\" data-step-status"))
        XCTAssertTrue(html.contains("<noscript><p>Use the step links"))
        XCTAssertTrue(html.contains("data-step-label=\"C\""))
        XCTAssertTrue(html.contains(">Step C<"))
        XCTAssertTrue(html.contains("list-style: none"))
        XCTAssertTrue(html.contains("status.textContent = label ? `${label} (${progress})` : progress"))
        XCTAssertTrue(html.contains("@media print"))
        XCTAssertTrue(html.contains(".is-enhanced .step-card[hidden] { display: block !important; }"))
        XCTAssertTrue(html.contains("Open Settings"))
        XCTAssertTrue(html.contains("Confirm the version."))
    }

    func testRenderedDifferenceIsEmbeddedAsRedactionSafePoster() throws {
        let html = try CompositionHTMLExporter.html(for: CompositionHTMLDocument(
            title: "Visual changes",
            layout: .comparison(CompositionHTMLComparison(
                mode: .renderedDifference
            )),
            items: [item("Before"), item("After")],
            renderedDifference: item("Rendered Difference")
        ))

        XCTAssertEqual(
            html.components(separatedBy: "src=\"data:image/png;base64,").count - 1,
            3
        )
        XCTAssertTrue(html.contains("comparison-difference-rendered"))
        let comparisonClasses = try content(
            between: "<section class=\"",
            and: "\" data-comparison",
            in: html
        )
        XCTAssertFalse(comparisonClasses.contains("difference-fallback"))
        XCTAssertTrue(html.contains("Result Visibility"))
        XCTAssertTrue(html.contains("value=\"100\" data-difference-range"))
    }

    func testRenderedChangeHighlightRetainsItsModeAndAccessibleName() throws {
        let html = try CompositionHTMLExporter.html(for: CompositionHTMLDocument(
            title: "Highlighted changes",
            layout: .comparison(CompositionHTMLComparison(
                mode: .renderedChangeHighlight
            )),
            items: [item("Before"), item("After")],
            renderedChangeHighlight: item("Rendered Highlight")
        ))

        XCTAssertTrue(html.contains("data-comparison-mode=\"change-highlight\""))
        XCTAssertTrue(html.contains("<figcaption>Highlight Changes</figcaption>"))
        XCTAssertFalse(html.contains("Difference intensity"))
    }

    func testRenderedComparisonRequiresItsFlattenedRedactionSafeResult() {
        XCTAssertThrowsError(try CompositionHTMLExporter.html(for: CompositionHTMLDocument(
            title: "Missing result",
            layout: .comparison(CompositionHTMLComparison(
                mode: .renderedDifference
            )),
            items: [item("Before"), item("After")]
        ))) { error in
            XCTAssertEqual(
                error as? CompositionHTMLExportError,
                .renderedComparisonResultRequired
            )
        }
    }

    func testStepsCanExplicitlyOmitNumberingWithoutLosingProgressStatus() throws {
        let html = try CompositionHTMLExporter.html(for: CompositionHTMLDocument(
            title: "Unnumbered",
            layout: .steps,
            items: [
                item("Open", stepLabel: nil, showsStepNumber: false),
                item("Finish", stepLabel: nil, showsStepNumber: false),
            ]
        ))

        XCTAssertFalse(html.contains("class=\"step-number\""))
        XCTAssertFalse(html.contains("class=\"step-link-label\""))
        XCTAssertTrue(html.contains("data-step-label=\"\""))
        XCTAssertTrue(html.contains(">1 of 2</p>"))
    }

    func testComparisonRejectsAnythingOtherThanTwoItems() {
        XCTAssertThrowsError(try CompositionHTMLExporter.html(for: CompositionHTMLDocument(
            title: "Incomplete",
            layout: .comparison(CompositionHTMLComparison(mode: .sideBySide)),
            items: [item("Only")]
        ))) { error in
            XCTAssertEqual(
                error as? CompositionHTMLExportError,
                .comparisonRequiresExactlyTwoItems
            )
        }
    }

    private func comparisonHTML(mode: CompositionHTMLComparisonMode) throws -> String {
        try CompositionHTMLExporter.html(for: CompositionHTMLDocument(
            title: "Comparison",
            layout: .comparison(CompositionHTMLComparison(
                mode: mode,
                beforeLabel: "Original",
                afterLabel: "Revised"
            )),
            items: [item("Original"), item("Revised")]
        ))
    }

    private func item(
        _ title: String,
        caption: String? = nil,
        stepLabel: String? = nil,
        showsStepNumber: Bool = true,
        color: PixelSample = PixelSample(red: 80, green: 120, blue: 180, alpha: 255)
    ) -> CompositionHTMLItem {
        CompositionHTMLItem(
            image: makeSolidImage(width: 4, height: 3, color: color),
            title: title,
            caption: caption,
            accessibilityLabel: "\(title) screenshot",
            stepLabel: stepLabel,
            showsStepNumber: showsStepNumber
        )
    }

    private func content(
        between opening: String,
        and closing: String,
        in value: String
    ) throws -> String {
        let openingRange = try XCTUnwrap(value.range(of: opening))
        let closingRange = try XCTUnwrap(
            value.range(of: closing, range: openingRange.upperBound..<value.endIndex)
        )
        return String(value[openingRange.upperBound..<closingRange.lowerBound])
    }

    private func hashSource(for source: String) -> String {
        let digest = SHA256.hash(data: Data(source.utf8))
        return "sha256-\(Data(digest).base64EncodedString())"
    }

    private func firstEmbeddedPNG(in html: String) throws -> Data {
        let prefix = "src=\"data:image/png;base64,"
        let prefixRange = try XCTUnwrap(html.range(of: prefix))
        let end = try XCTUnwrap(
            html[prefixRange.upperBound...].firstIndex(of: "\"")
        )
        let encoded = String(html[prefixRange.upperBound..<end])
        return try XCTUnwrap(Data(base64Encoded: encoded))
    }
}

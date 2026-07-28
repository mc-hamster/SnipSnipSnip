import CoreGraphics
import CryptoKit
import Foundation

/// A rendered image and the user-authored text that may appear beside it in an
/// exported interactive composition. The exporter deliberately accepts a
/// `CGImage`, rather than encoded source-file data, so it can re-encode pixels
/// without carrying EXIF, GPS, TIFF, IPTC, filenames, or source URLs forward.
nonisolated struct CompositionHTMLItem: @unchecked Sendable {
    let image: CGImage
    var title: String
    var caption: String?
    var accessibilityLabel: String
    /// The already-formatted label used by Steps (for example `A`, `iv`, or
    /// `12`). Keeping formatting outside JavaScript makes the static, printed,
    /// and enhanced variants agree exactly.
    var stepLabel: String?
    var showsStepNumber: Bool

    init(
        image: CGImage,
        title: String,
        caption: String? = nil,
        accessibilityLabel: String? = nil,
        stepLabel: String? = nil,
        showsStepNumber: Bool = true
    ) {
        self.image = image
        self.title = title
        self.caption = caption
        self.accessibilityLabel = accessibilityLabel ?? title
        self.stepLabel = stepLabel
        self.showsStepNumber = showsStepNumber
    }
}

nonisolated enum CompositionHTMLComparisonAxis: String, Sendable {
    case horizontal
    case vertical
}

nonisolated enum CompositionHTMLComparisonSide: String, Sendable {
    case before
    case after
}

nonisolated enum CompositionHTMLComparisonMode: Sendable {
    case sideBySide
    case wipe(axis: CompositionHTMLComparisonAxis, positionPercent: Int)
    case overlay(afterOpacityPercent: Int)
    case blink(intervalMilliseconds: Int, poster: CompositionHTMLComparisonSide)
    /// Compatibility fallback for callers that provide only Before and After
    /// frames. Product exports use one of the rendered-result cases below.
    case difference(intensityPercent: Int)
    case renderedDifference
    case renderedChangeHighlight
}

nonisolated private extension CompositionHTMLComparisonMode {
    var usesRenderedResult: Bool {
        switch self {
        case .renderedDifference, .renderedChangeHighlight:
            true
        case .sideBySide, .wipe, .overlay, .blink, .difference:
            false
        }
    }

    var isRenderedChangeHighlight: Bool {
        if case .renderedChangeHighlight = self {
            return true
        }
        return false
    }
}

nonisolated struct CompositionHTMLComparison: Sendable {
    var mode: CompositionHTMLComparisonMode
    var beforeLabel: String
    var afterLabel: String

    init(
        mode: CompositionHTMLComparisonMode,
        beforeLabel: String = "Before",
        afterLabel: String = "After"
    ) {
        self.mode = mode
        self.beforeLabel = beforeLabel
        self.afterLabel = afterLabel
    }
}

nonisolated enum CompositionHTMLLayout: Sendable {
    case grid(columns: Int)
    case steps
    case comparison(CompositionHTMLComparison)
}

nonisolated struct CompositionHTMLDocument: @unchecked Sendable {
    var title: String
    var layout: CompositionHTMLLayout
    var items: [CompositionHTMLItem]
    var languageTag: String
    /// Difference and Change Highlight export their fully rendered,
    /// redaction-safe result. The two ordinary items remain available for the
    /// Before/After fallbacks and do not need source pixels or metadata.
    var renderedDifference: CompositionHTMLItem?

    init(
        title: String,
        layout: CompositionHTMLLayout,
        items: [CompositionHTMLItem],
        renderedDifference: CompositionHTMLItem? = nil,
        languageTag: String = "en"
    ) {
        self.title = title
        self.layout = layout
        self.items = items
        self.renderedDifference = renderedDifference
        self.languageTag = languageTag
    }
}

nonisolated enum CompositionHTMLExportError: LocalizedError, Equatable {
    case emptyComposition
    case comparisonRequiresExactlyTwoItems
    case imageTooLarge(index: Int)
    case aggregateImagesTooLarge(maximumPixels: Int)
    case imageEncodingFailed(index: Int)
    case differenceImageEncodingFailed
    case renderedComparisonResultRequired
    case documentTooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .emptyComposition:
            return "The composition has no images to export."
        case .comparisonRequiresExactlyTwoItems:
            return "Interactive comparison export requires exactly two images."
        case .imageTooLarge(let index):
            return "Image \(index + 1) is too large for safe interactive HTML export."
        case .aggregateImagesTooLarge(let maximumPixels):
            return "The rendered images exceed the \(maximumPixels) pixel interactive HTML safety budget."
        case .imageEncodingFailed(let index):
            return "Image \(index + 1) could not be encoded for interactive HTML export."
        case .differenceImageEncodingFailed:
            return "The rendered difference could not be encoded for interactive HTML export."
        case .renderedComparisonResultRequired:
            return "The rendered comparison result is missing."
        case .documentTooLarge(let maximumBytes):
            return "The interactive HTML would exceed the \(maximumBytes / 1_048_576) MB safety limit."
        }
    }
}

/// Produces a portable, single-file, offline HTML composition.
///
/// The result has a deny-by-default Content Security Policy. Its only embedded
/// resources are metadata-stripped PNG data URLs plus exporter-owned CSS and
/// JavaScript whose exact SHA-256 hashes are listed in the policy. User text is
/// emitted only as escaped HTML text or attributes; it is never interpolated
/// into CSS or JavaScript.
nonisolated enum CompositionHTMLExporter {
    static let maximumImagePixelCount = 100_000_000
    static let maximumAggregateImagePixelCount = 134_217_728
    static let maximumDocumentBytes = 256 * 1_048_576

    static func data(for document: CompositionHTMLDocument) throws -> Data {
        let html = try html(for: document)
        let data = Data(html.utf8)
        guard data.count <= maximumDocumentBytes else {
            throw CompositionHTMLExportError.documentTooLarge(maximumBytes: maximumDocumentBytes)
        }
        return data
    }

    static func html(for document: CompositionHTMLDocument) throws -> String {
        try validate(document)

        let encodedItems = try document.items.enumerated().map { index, item in
            try encode(item, at: index)
        }
        let encodedDifference: EncodedItem?
        if let renderedDifference = document.renderedDifference {
            do {
                encodedDifference = try encode(renderedDifference, at: document.items.count)
            } catch {
                throw CompositionHTMLExportError.differenceImageEncodingFailed
            }
        } else {
            encodedDifference = nil
        }
        let body = renderBody(
            title: document.title,
            layout: document.layout,
            items: encodedItems,
            renderedDifference: encodedDifference
        )
        let csp = contentSecurityPolicy

        return """
        <!doctype html>
        <html lang="\(safeLanguageTag(document.languageTag))" dir="auto">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="referrer" content="no-referrer">
        <meta name="robots" content="noindex, nofollow, noarchive">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>\(escape(document.title.isEmpty ? "Composition" : document.title))</title>
        <style>\(styleSource)</style>
        </head>
        <body>
        \(body)
        <script>\(scriptSource)</script>
        </body>
        </html>
        """
    }

    private struct EncodedItem {
        let title: String
        let caption: String?
        let accessibilityLabel: String
        let stepLabel: String?
        let showsStepNumber: Bool
        let pngDataURL: String
    }

    private static func validate(_ document: CompositionHTMLDocument) throws {
        guard !document.items.isEmpty else {
            throw CompositionHTMLExportError.emptyComposition
        }
        if case .comparison(let comparison) = document.layout {
            guard document.items.count == 2 else {
                throw CompositionHTMLExportError.comparisonRequiresExactlyTwoItems
            }
            if comparison.mode.usesRenderedResult,
               document.renderedDifference == nil {
                throw CompositionHTMLExportError.renderedComparisonResultRequired
            }
        }
        var aggregatePixels = 0
        for (index, item) in (document.items + [document.renderedDifference].compactMap { $0 })
            .enumerated() {
            let pixels = item.image.width.multipliedReportingOverflow(by: item.image.height)
            guard !pixels.overflow, pixels.partialValue <= maximumImagePixelCount else {
                throw CompositionHTMLExportError.imageTooLarge(index: index)
            }
            let nextAggregate = aggregatePixels.addingReportingOverflow(pixels.partialValue)
            guard !nextAggregate.overflow,
                  nextAggregate.partialValue <= maximumAggregateImagePixelCount else {
                throw CompositionHTMLExportError.aggregateImagesTooLarge(
                    maximumPixels: maximumAggregateImagePixelCount
                )
            }
            aggregatePixels = nextAggregate.partialValue
        }
    }

    private static func encode(_ item: CompositionHTMLItem, at index: Int) throws -> EncodedItem {
        do {
            let pngData = try ImageExporter.pngData(for: item.image)
            return EncodedItem(
                title: item.title,
                caption: item.caption,
                accessibilityLabel: item.accessibilityLabel,
                stepLabel: item.stepLabel,
                showsStepNumber: item.showsStepNumber,
                pngDataURL: "data:image/png;base64,\(pngData.base64EncodedString())"
            )
        } catch {
            throw CompositionHTMLExportError.imageEncodingFailed(index: index)
        }
    }

    private static func renderBody(
        title: String,
        layout: CompositionHTMLLayout,
        items: [EncodedItem],
        renderedDifference: EncodedItem?
    ) -> String {
        let resolvedTitle = title.isEmpty ? "Composition" : title
        let content: String
        let layoutName: String

        switch layout {
        case .grid(let requestedColumns):
            let columns = min(max(requestedColumns, 1), 12)
            layoutName = "grid"
            content = renderGrid(items: items, columns: columns)
        case .steps:
            layoutName = "steps"
            content = renderSteps(items: items)
        case .comparison(let comparison):
            layoutName = "comparison"
            content = renderComparison(
                items: items,
                comparison: comparison,
                renderedDifference: renderedDifference
            )
        }

        return """
        <header class="document-header">
          <h1 dir="auto">\(escape(resolvedTitle))</h1>
        </header>
        <main class="composition layout-\(layoutName)">
        \(content)
        </main>
        <footer class="document-footer">
          <p>Created with SnipSnipSnip</p>
        </footer>
        """
    }

    private static func renderGrid(items: [EncodedItem], columns: Int) -> String {
        let cards = items.enumerated().map { index, item in
            renderFigure(item, index: index, className: "composition-card")
        }.joined(separator: "\n")

        return """
        <section class="composition-grid columns-\(columns)" aria-label="Composition images">
        \(cards)
        </section>
        """
    }

    private static func renderSteps(items: [EncodedItem]) -> String {
        let links = items.enumerated().map { index, item in
            let label = item.stepLabel ?? "\(index + 1)"
            let prefix = item.showsStepNumber
                ? "<span class=\"step-link-label\">\(escape(label)).</span> "
                : ""
            return """
            <li><a href="#step-\(index + 1)" data-step-link="\(index)" dir="auto">\(prefix)\(escape(item.title))</a></li>
            """
        }.joined(separator: "\n")

        let steps = items.enumerated().map { index, item in
            let caption = optionalParagraph(item.caption)
            let label = item.stepLabel ?? "\(index + 1)"
            let number = item.showsStepNumber
                ? "<p class=\"step-number\" dir=\"auto\">Step \(escape(label))</p>"
                : ""
            return """
            <section id="step-\(index + 1)" class="step-card" data-step="\(index)" data-step-label="\(item.showsStepNumber ? escape(label) : "")" aria-labelledby="step-title-\(index + 1)">
              \(number)
              <h2 id="step-title-\(index + 1)" dir="auto">\(escape(item.title))</h2>
              <img src="\(item.pngDataURL)" alt="\(escape(item.accessibilityLabel))">
              \(caption)
            </section>
            """
        }.joined(separator: "\n")

        return """
        <div class="steps-layout" data-step-layout>
          <nav class="step-navigation" aria-label="Steps">
            <ol>
            \(links)
            </ol>
          </nav>
          <div class="step-deck" data-step-deck data-step-count="\(items.count)">
          \(steps)
          </div>
          <div class="step-controls" aria-label="Step controls">
            <button type="button" data-step-previous>Previous</button>
            <p aria-live="polite" data-step-status>\(initialStepStatus(items))</p>
            <button type="button" data-step-next>Next</button>
          </div>
          <noscript><p>Use the step links to move through this composition.</p></noscript>
        </div>
        """
    }

    private static func renderComparison(
        items: [EncodedItem],
        comparison: CompositionHTMLComparison,
        renderedDifference: EncodedItem?
    ) -> String {
        let before = items[0]
        let after = items[1]
        let beforeLabel = escape(comparison.beforeLabel)
        let afterLabel = escape(comparison.afterLabel)
        let modeName: String
        let attributes: String
        let controls: String
        let valueClass: String

        switch comparison.mode {
        case .sideBySide:
            modeName = "side-by-side"
            attributes = ""
            controls = """
            <div class="comparison-buttons comparison-view-buttons" aria-label="Comparison view">
              <button type="button" data-side-by-side-view="both" aria-pressed="true">Show Both</button>
              <button type="button" data-side-by-side-view="before" aria-pressed="false">\(beforeLabel)</button>
              <button type="button" data-side-by-side-view="after" aria-pressed="false">\(afterLabel)</button>
            </div>
            <p class="comparison-status" aria-live="polite" data-side-by-side-status>Showing \(beforeLabel) and \(afterLabel)</p>
            """
            valueClass = ""
        case .wipe(let axis, let requestedPosition):
            let position = min(max(requestedPosition, 0), 100)
            modeName = "wipe"
            attributes = " data-axis=\"\(axis.rawValue)\" data-initial-value=\"\(position)\""
            valueClass = "comparison-value-\(position)"
            controls = """
            <label class="comparison-control">Reveal
              <input type="range" min="0" max="100" value="\(position)" data-wipe-range aria-label="Reveal \(afterLabel)">
            </label>
            """
        case .overlay(let requestedOpacity):
            let opacity = min(max(requestedOpacity, 0), 100)
            modeName = "overlay"
            attributes = " data-initial-value=\"\(opacity)\""
            valueClass = "comparison-value-\(opacity)"
            controls = """
            <label class="comparison-control">After opacity
              <input type="range" min="0" max="100" value="\(opacity)" data-overlay-range>
            </label>
            """
        case .blink(let requestedInterval, let poster):
            let interval = min(max(requestedInterval, 250), 10_000)
            modeName = "blink"
            attributes = " data-interval=\"\(interval)\" data-poster=\"\(poster.rawValue)\""
            valueClass = ""
            controls = """
            <div class="comparison-buttons" aria-label="Blink controls">
              <button type="button" data-blink-before>\(beforeLabel)</button>
              <button type="button" data-blink-toggle aria-pressed="false">Play</button>
              <button type="button" data-blink-after>\(afterLabel)</button>
            </div>
            <p class="comparison-status" aria-live="polite" data-blink-status>\(poster == .before ? beforeLabel : afterLabel)</p>
            """
        case .difference(let requestedIntensity):
            let intensity = min(max(requestedIntensity, 0), 100)
            modeName = "difference"
            attributes = " data-initial-value=\"\(intensity)\""
            valueClass = "comparison-value-\(intensity)"
            controls = """
            <label class="comparison-control">Difference intensity
              <input type="range" min="0" max="100" value="\(intensity)" data-difference-range>
            </label>
            """
        case .renderedDifference, .renderedChangeHighlight:
            modeName = comparison.mode.isRenderedChangeHighlight
                ? "change-highlight"
                : "difference"
            attributes = " data-initial-value=\"100\""
            valueClass = "comparison-value-100"
            controls = """
            <label class="comparison-control">Result visibility
              <input type="range" min="0" max="100" value="100" data-result-range>
            </label>
            """
        }

        let pairMarkup: String
        var stateClasses = valueClass.isEmpty ? [] : [valueClass]
        if case .difference = comparison.mode, renderedDifference == nil {
            stateClasses.append("difference-fallback")
        }
        if case .sideBySide = comparison.mode {
            pairMarkup = """
            <figure class="comparison-side comparison-side-before">
              <figcaption>\(beforeLabel)</figcaption>
              <img src="\(before.pngDataURL)" alt="\(escape(before.accessibilityLabel))">
            </figure>
            <figure class="comparison-side comparison-side-after">
              <figcaption>\(afterLabel)</figcaption>
              <img src="\(after.pngDataURL)" alt="\(escape(after.accessibilityLabel))">
            </figure>
            """
        } else {
            if case .blink(_, let poster) = comparison.mode, poster == .after {
                stateClasses.append("show-after")
            }
            if case .blink(_, let poster) = comparison.mode {
                stateClasses.append(poster == .after ? "poster-after" : "poster-before")
            }
            let differenceMarkup: String
            if comparison.mode.usesRenderedResult, let renderedDifference {
                let resultLabel = comparison.mode.isRenderedChangeHighlight
                    ? "Change Highlight"
                    : "Difference"
                differenceMarkup = """
                <figure class="comparison-layer comparison-difference-rendered">
                  <figcaption>\(resultLabel)</figcaption>
                  <img src="\(renderedDifference.pngDataURL)" alt="\(escape(renderedDifference.accessibilityLabel))">
                </figure>
                """
            } else {
                differenceMarkup = ""
            }
            pairMarkup = """
            <div class="comparison-stage">
              <figure class="comparison-layer comparison-before">
                <figcaption>\(beforeLabel)</figcaption>
                <img src="\(before.pngDataURL)" alt="\(escape(before.accessibilityLabel))">
              </figure>
              <figure class="comparison-layer comparison-after">
                <figcaption>\(afterLabel)</figcaption>
                <img src="\(after.pngDataURL)" alt="\(escape(after.accessibilityLabel))">
              </figure>
              \(differenceMarkup)
            </div>
            """
        }

        let classNames = (["comparison", "comparison-\(modeName)"] + stateClasses)
            .joined(separator: " ")
        return """
        <section class="\(classNames)" data-comparison data-comparison-mode="\(modeName)"\(attributes) aria-label="\(beforeLabel) and \(afterLabel) comparison">
          <div class="comparison-pair">
          \(pairMarkup)
          </div>
          \(controls)
        </section>
        """
    }

    private static func renderFigure(
        _ item: EncodedItem,
        index: Int,
        className: String
    ) -> String {
        """
        <figure class="\(className)" aria-labelledby="item-title-\(index + 1)">
          <img src="\(item.pngDataURL)" alt="\(escape(item.accessibilityLabel))">
          <figcaption>
            <h2 id="item-title-\(index + 1)" dir="auto">\(escape(item.title))</h2>
            \(optionalParagraph(item.caption))
          </figcaption>
        </figure>
        """
    }

    private static func optionalParagraph(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return ""
        }
        return "<p dir=\"auto\">\(escape(value))</p>"
    }

    private static func initialStepStatus(_ items: [EncodedItem]) -> String {
        guard let first = items.first else { return "" }
        let progress = "1 of \(items.count)"
        guard first.showsStepNumber else {
            return progress
        }
        return "\(escape(first.stepLabel ?? "1")) (\(progress))"
    }

    private static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for character in value {
            switch character {
            case "&":
                result += "&amp;"
            case "<":
                result += "&lt;"
            case ">":
                result += "&gt;"
            case "\"":
                result += "&quot;"
            case "'":
                result += "&#39;"
            default:
                result.append(character)
            }
        }
        return result
    }

    private static func safeLanguageTag(_ value: String) -> String {
        let candidate = value
            .replacingOccurrences(of: "_", with: "-")
            .prefix(35)
        guard !candidate.isEmpty,
              candidate.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
              }) else {
            return "en"
        }
        return String(candidate)
    }

    private static var contentSecurityPolicy: String {
        [
            "default-src 'none'",
            "img-src data:",
            "style-src '\(hashSource(for: styleSource))'",
            "script-src '\(hashSource(for: scriptSource))'",
            "connect-src 'none'",
            "font-src 'none'",
            "media-src 'none'",
            "object-src 'none'",
            "frame-src 'none'",
            "child-src 'none'",
            "worker-src 'none'",
            "manifest-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
        ].joined(separator: "; ")
    }

    private static func hashSource(for source: String) -> String {
        let digest = SHA256.hash(data: Data(source.utf8))
        return "sha256-\(Data(digest).base64EncodedString())"
    }

    private static let baseStyleSource = #"""
:root {
  color-scheme: light dark;
  font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif;
  line-height: 1.45;
  --background: #f4f4f6;
  --surface: #ffffff;
  --text: #1d1d1f;
  --secondary: #5e5e63;
  --border: #c7c7cc;
  --accent: #0066cc;
  --focus: #005fcc;
  --shadow: 0 12px 36px rgba(0, 0, 0, 0.14);
}
@media (prefers-color-scheme: dark) {
  :root {
    --background: #1c1c1e;
    --surface: #2c2c2e;
    --text: #f5f5f7;
    --secondary: #aeaeb2;
    --border: #545458;
    --accent: #64a8ff;
    --focus: #8fc1ff;
    --shadow: 0 12px 36px rgba(0, 0, 0, 0.45);
  }
}
* { box-sizing: border-box; }
html { background: var(--background); color: var(--text); }
body { margin: 0; min-width: 280px; }
img { display: block; max-width: 100%; height: auto; }
button, input { font: inherit; }
button, a {
  color: var(--accent);
}
button {
  min-height: 2.25rem;
  border: 1px solid var(--border);
  border-radius: 0.55rem;
  background: var(--surface);
  padding: 0.45rem 0.8rem;
  cursor: pointer;
}
button:disabled { color: var(--secondary); cursor: default; }
:focus-visible {
  outline: 3px solid var(--focus);
  outline-offset: 3px;
}
.document-header, .composition, .document-footer {
  width: min(1200px, calc(100% - 2rem));
  margin-inline: auto;
}
.document-header { padding: 2rem 0 1rem; }
.document-header h1 { margin: 0; font-size: clamp(1.65rem, 4vw, 2.5rem); }
.document-footer {
  color: var(--secondary);
  font-size: 0.875rem;
  padding: 2rem 0;
  text-align: center;
}
.composition-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 1rem;
}
.composition-grid.columns-1 { grid-template-columns: 1fr; }
.composition-grid.columns-3 { grid-template-columns: repeat(3, minmax(0, 1fr)); }
.composition-grid.columns-4 { grid-template-columns: repeat(4, minmax(0, 1fr)); }
.composition-grid.columns-5 { grid-template-columns: repeat(5, minmax(0, 1fr)); }
.composition-grid.columns-6 { grid-template-columns: repeat(6, minmax(0, 1fr)); }
.composition-grid.columns-7 { grid-template-columns: repeat(7, minmax(0, 1fr)); }
.composition-grid.columns-8 { grid-template-columns: repeat(8, minmax(0, 1fr)); }
.composition-grid.columns-9 { grid-template-columns: repeat(9, minmax(0, 1fr)); }
.composition-grid.columns-10 { grid-template-columns: repeat(10, minmax(0, 1fr)); }
.composition-grid.columns-11 { grid-template-columns: repeat(11, minmax(0, 1fr)); }
.composition-grid.columns-12 { grid-template-columns: repeat(12, minmax(0, 1fr)); }
.composition-card, .step-card, .comparison {
  margin: 0;
  border: 1px solid var(--border);
  border-radius: 0.85rem;
  background: var(--surface);
  box-shadow: var(--shadow);
  overflow: hidden;
}
.composition-card img { width: 100%; }
.composition-card figcaption { padding: 1rem; }
.composition-card h2, .step-card h2 { margin: 0; font-size: 1.1rem; }
.composition-card p, .step-card p { color: var(--secondary); }
.steps-layout {
  display: grid;
  grid-template-columns: minmax(12rem, 18rem) minmax(0, 1fr);
  gap: 1rem;
  align-items: start;
}
.step-navigation {
  position: sticky;
  top: 1rem;
  max-height: calc(100vh - 2rem);
  overflow: auto;
  border: 1px solid var(--border);
  border-radius: 0.85rem;
  background: var(--surface);
  padding: 0.75rem;
}
.step-navigation ol {
  margin: 0;
  padding-inline-start: 0;
  list-style: none;
}
.step-navigation li + li { margin-top: 0.45rem; }
.step-navigation a[aria-current="step"] { font-weight: 700; }
.step-deck { min-width: 0; }
.step-card { padding: 1rem; scroll-margin-top: 1rem; }
.step-card + .step-card { margin-top: 1rem; }
.step-card img { width: 100%; margin-top: 0.75rem; border-radius: 0.45rem; }
.step-number { margin: 0 0 0.2rem; font-weight: 700; color: var(--accent) !important; }
.step-controls {
  grid-column: 2;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 1rem;
  padding: 0.5rem;
}
.step-controls p { min-width: 7rem; text-align: center; }
.is-enhanced .step-card[hidden] { display: none; }
.comparison { padding: 1rem; }
.comparison-pair { min-width: 0; }
.comparison-side-by-side .comparison-pair {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 1rem;
}
.comparison-side-by-side.show-before .comparison-pair,
.comparison-side-by-side.show-after .comparison-pair {
  grid-template-columns: minmax(0, 1fr);
}
.comparison-side-by-side.show-before .comparison-side-after,
.comparison-side-by-side.show-after .comparison-side-before {
  display: none;
}
.comparison-side { margin: 0; min-width: 0; }
.comparison-side figcaption, .comparison-layer figcaption {
  font-weight: 700;
  margin-bottom: 0.45rem;
}
.comparison-stage {
  display: grid;
  position: relative;
  overflow: hidden;
  border-radius: 0.55rem;
  background: #000;
}
.comparison-wipe { --comparison-value: 50%; }
.comparison-overlay, .comparison-difference, .comparison-change-highlight { --comparison-value: 0.5; }
.comparison-layer {
  grid-area: 1 / 1;
  margin: 0;
  min-width: 0;
}
.comparison-layer img { width: 100%; }
.comparison-layer figcaption {
  position: absolute;
  z-index: 3;
  top: 0.7rem;
  padding: 0.3rem 0.55rem;
  border-radius: 0.35rem;
  color: #fff;
  background: rgba(0, 0, 0, 0.76);
}
.comparison-before figcaption { inset-inline-start: 0.7rem; }
.comparison-after figcaption { inset-inline-end: 0.7rem; }
.comparison-wipe[data-axis="horizontal"] .comparison-after {
  clip-path: inset(0 calc(100% - var(--comparison-value)) 0 0);
}
.comparison-wipe[data-axis="vertical"] .comparison-after {
  clip-path: inset(0 0 calc(100% - var(--comparison-value)) 0);
}
.comparison-overlay .comparison-after { opacity: var(--comparison-value); }
.comparison-blink .comparison-after { visibility: hidden; }
.comparison-blink.show-after .comparison-before { visibility: hidden; }
.comparison-blink.show-after .comparison-after { visibility: visible; }
.comparison-difference .comparison-after,
.comparison-change-highlight .comparison-after { visibility: hidden; }
.comparison-difference .comparison-difference-rendered,
.comparison-change-highlight .comparison-difference-rendered {
  opacity: var(--comparison-value);
}
.comparison-difference.difference-fallback .comparison-after {
  visibility: visible;
  mix-blend-mode: difference;
  opacity: var(--comparison-value);
}
.comparison-control, .comparison-buttons {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.75rem;
  margin-top: 1rem;
}
.comparison-view-buttons { display: none; }
.is-enhanced .comparison-view-buttons { display: flex; }
.comparison-control input { width: min(32rem, 70vw); }
.comparison-status { text-align: center; color: var(--secondary); }
@media (max-width: 720px) {
  .composition-grid,
  .composition-grid[class*="columns-"] {
    grid-template-columns: 1fr;
  }
  .steps-layout { grid-template-columns: 1fr; }
  .step-navigation { position: static; max-height: none; }
  .step-controls { grid-column: 1; }
  .comparison-side-by-side .comparison-pair { grid-template-columns: 1fr; }
}
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    scroll-behavior: auto !important;
    transition-duration: 0.001ms !important;
    animation-duration: 0.001ms !important;
  }
}
@media print {
  :root {
    color-scheme: light;
    --background: #fff;
    --surface: #fff;
    --text: #000;
    --secondary: #333;
    --border: #777;
    --shadow: none;
  }
  body { min-width: 0; }
  .document-header, .composition {
    width: 100%;
    margin: 0;
  }
  .document-footer,
  .step-navigation,
  .step-controls,
  .comparison-control,
  .comparison-buttons,
  .comparison-status {
    display: none !important;
  }
  .steps-layout { display: block; }
  .is-enhanced .step-card[hidden] { display: block !important; }
  .step-card {
    break-inside: avoid;
    page-break-inside: avoid;
    box-shadow: none;
    margin-bottom: 1rem;
  }
  .composition-card, .comparison { box-shadow: none; }
  .comparison-side-by-side.show-before .comparison-pair,
  .comparison-side-by-side.show-after .comparison-pair {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
  .comparison-side-by-side .comparison-side {
    display: block !important;
  }
  .comparison-blink.poster-before .comparison-before { visibility: visible !important; }
  .comparison-blink.poster-before .comparison-after { visibility: hidden !important; }
  .comparison-blink.poster-after .comparison-before { visibility: hidden !important; }
  .comparison-blink.poster-after .comparison-after { visibility: visible !important; }
}
@media (forced-colors: active) {
  .composition-card, .step-card, .comparison, .step-navigation {
    box-shadow: none;
    border-width: 2px;
  }
}
"""#

    /// Comparison controls update predeclared class names instead of writing
    /// inline style attributes. This keeps the exported document functional
    /// under its strict `style-src` policy without granting `unsafe-inline`.
    private static let styleSource: String = {
        let comparisonValueRules = (0...100).map { value in
            let fraction = Double(value) / 100
            let inverse = 100 - value
            return """
            .comparison-wipe.comparison-value-\(value) { --comparison-value: \(value)%; }
            .comparison-overlay.comparison-value-\(value),
            .comparison-difference.comparison-value-\(value),
            .comparison-change-highlight.comparison-value-\(value) { --comparison-value: \(fraction); }
            .comparison-wipe.comparison-value-\(value)[data-axis="horizontal"] .comparison-after {
              clip-path: inset(0 \(inverse)% 0 0);
            }
            .comparison-wipe.comparison-value-\(value)[data-axis="vertical"] .comparison-after {
              clip-path: inset(0 0 \(inverse)% 0);
            }
            .comparison-overlay.comparison-value-\(value) .comparison-after {
              opacity: \(fraction);
            }
            .comparison-difference.comparison-value-\(value) .comparison-difference-rendered,
            .comparison-change-highlight.comparison-value-\(value) .comparison-difference-rendered {
              opacity: \(fraction);
            }
            """
        }.joined(separator: "\n")
        return "\(baseStyleSource)\n\(comparisonValueRules)"
    }()

    private static let scriptSource = #"""
(() => {
  "use strict";
  const root = document.documentElement;
  root.classList.add("is-enhanced");

  const clamp = (value, minimum, maximum) => Math.min(Math.max(value, minimum), maximum);

  document.querySelectorAll("[data-step-layout]").forEach((layout) => {
    const steps = Array.from(layout.querySelectorAll("[data-step]"));
    const links = Array.from(layout.querySelectorAll("[data-step-link]"));
    const previous = layout.querySelector("[data-step-previous]");
    const next = layout.querySelector("[data-step-next]");
    const status = layout.querySelector("[data-step-status]");
    if (!steps.length || !previous || !next || !status) return;

    let index = clamp(Number((location.hash.match(/^#step-(\d+)$/) || [])[1] || 1) - 1, 0, steps.length - 1);
    const show = (requested, updateHash) => {
      index = clamp(requested, 0, steps.length - 1);
      steps.forEach((step, stepIndex) => { step.hidden = stepIndex !== index; });
      links.forEach((link, linkIndex) => {
        if (linkIndex === index) link.setAttribute("aria-current", "step");
        else link.removeAttribute("aria-current");
      });
      previous.disabled = index === 0;
      next.disabled = index === steps.length - 1;
      const label = steps[index].dataset.stepLabel || "";
      const progress = `${index + 1} of ${steps.length}`;
      status.textContent = label ? `${label} (${progress})` : progress;
      if (updateHash) {
        try {
          history.replaceState(null, "", `#step-${index + 1}`);
        } catch (_) {
          location.hash = `step-${index + 1}`;
        }
      }
    };
    links.forEach((link, linkIndex) => {
      link.addEventListener("click", (event) => {
        event.preventDefault();
        show(linkIndex, true);
        steps[index].focus({ preventScroll: true });
      });
    });
    previous.addEventListener("click", () => show(index - 1, true));
    next.addEventListener("click", () => show(index + 1, true));
    layout.addEventListener("keydown", (event) => {
      const isRTL = getComputedStyle(layout).direction === "rtl";
      if (event.key === "ArrowLeft") { event.preventDefault(); show(index + (isRTL ? 1 : -1), true); }
      if (event.key === "ArrowRight") { event.preventDefault(); show(index + (isRTL ? -1 : 1), true); }
    });
    window.addEventListener("hashchange", () => {
      const match = location.hash.match(/^#step-(\d+)$/);
      if (match) show(Number(match[1]) - 1, false);
    });
    steps.forEach((step) => { step.tabIndex = -1; });
    show(index, false);
  });

  document.querySelectorAll("[data-comparison]").forEach((comparison) => {
    if (comparison.dataset.comparisonMode === "side-by-side") {
      const buttons = Array.from(comparison.querySelectorAll("[data-side-by-side-view]"));
      const status = comparison.querySelector("[data-side-by-side-status]");
      const before = comparison.querySelector('[data-side-by-side-view="before"]');
      const after = comparison.querySelector('[data-side-by-side-view="after"]');
      const show = (view) => {
        const resolved = ["both", "before", "after"].includes(view) ? view : "both";
        comparison.classList.toggle("show-before", resolved === "before");
        comparison.classList.toggle("show-after", resolved === "after");
        buttons.forEach((button) => {
          button.setAttribute(
            "aria-pressed",
            button.dataset.sideBySideView === resolved ? "true" : "false"
          );
        });
        if (status) {
          const beforeLabel = before?.textContent?.trim() || "Before";
          const afterLabel = after?.textContent?.trim() || "After";
          status.textContent = resolved === "both"
            ? `Showing ${beforeLabel} and ${afterLabel}`
            : `Showing ${resolved === "before" ? beforeLabel : afterLabel}`;
        }
      };
      buttons.forEach((button) => {
        button.addEventListener("click", () => show(button.dataset.sideBySideView));
      });
      show("both");
    }

    const initial = clamp(Number(comparison.dataset.initialValue || 50), 0, 100);
    const setValue = (requested) => {
      const value = Math.round(clamp(Number(requested), 0, 100));
      Array.from(comparison.classList).forEach((name) => {
        if (/^comparison-value-\d+$/.test(name)) comparison.classList.remove(name);
      });
      comparison.classList.add(`comparison-value-${value}`);
    };
    setValue(initial);

    const bindRange = (selector) => {
      const range = comparison.querySelector(selector);
      if (!range) return;
      range.addEventListener("input", () => setValue(range.value));
    };
    bindRange("[data-wipe-range]");
    bindRange("[data-overlay-range]");
    bindRange("[data-difference-range]");
    bindRange("[data-result-range]");

    if (comparison.dataset.comparisonMode !== "blink") return;
    const toggle = comparison.querySelector("[data-blink-toggle]");
    const before = comparison.querySelector("[data-blink-before]");
    const after = comparison.querySelector("[data-blink-after]");
    const status = comparison.querySelector("[data-blink-status]");
    if (!toggle || !before || !after || !status) return;

    const interval = clamp(Number(comparison.dataset.interval || 1000), 250, 10000);
    let timer = null;
    let showingAfter = comparison.dataset.poster === "after";
    const label = (side) => side?.querySelector("figcaption")?.textContent || "";
    const renderSide = () => {
      comparison.classList.toggle("show-after", showingAfter);
      status.textContent = showingAfter ? label(comparison.querySelector(".comparison-after")) : label(comparison.querySelector(".comparison-before"));
    };
    const stop = () => {
      if (timer !== null) window.clearInterval(timer);
      timer = null;
      toggle.textContent = "Play";
      toggle.setAttribute("aria-pressed", "false");
    };
    const play = () => {
      if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
        status.textContent = `${status.textContent}. Animation is paused because Reduce Motion is enabled.`;
        return;
      }
      timer = window.setInterval(() => { showingAfter = !showingAfter; renderSide(); }, interval);
      toggle.textContent = "Pause";
      toggle.setAttribute("aria-pressed", "true");
    };
    toggle.addEventListener("click", () => { if (timer === null) play(); else stop(); });
    before.addEventListener("click", () => { stop(); showingAfter = false; renderSide(); });
    after.addEventListener("click", () => { stop(); showingAfter = true; renderSide(); });
    window.addEventListener("beforeprint", () => {
      stop();
      showingAfter = comparison.dataset.poster === "after";
      renderSide();
    });
    renderSide();
  });
})();
"""#
}

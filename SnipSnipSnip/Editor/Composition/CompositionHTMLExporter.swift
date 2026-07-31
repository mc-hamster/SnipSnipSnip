import AppKit
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

/// Generates the same line-and-dot lattice used by
/// `OutOfCapturePatternRenderer`, expressed as one repeatable SVG tile for
/// exported HTML. Keeping both diagonal families and the dots in one image
/// guarantees that browser layout cannot shift their coordinate systems apart.
nonisolated enum CompositionHTMLBrandPattern {
    struct Point: Hashable, Sendable {
        let x: Int
        let y: Int
    }

    struct Segment: Hashable, Sendable {
        let start: Point
        let end: Point
    }

    static let spacing = 34
    static let tileSize = spacing * 2
    static let lineWidth = 1
    static let dotDiameter = 5
    static let dotRadius = 2.5

    static var lineSegments: [Segment] {
        var segments: [Segment] = []

        // Rising diagonals use x - y = index × spacing.
        for index in -2...2 {
            let difference = index * spacing
            let startY = max(0, -difference)
            let endY = min(tileSize, tileSize - difference)
            guard startY < endY else { continue }
            segments.append(Segment(
                start: Point(x: startY + difference, y: startY),
                end: Point(x: endY + difference, y: endY)
            ))
        }

        // Falling diagonals use x + y = index × spacing.
        for index in 0...4 {
            let sum = index * spacing
            let startX = max(0, sum - tileSize)
            let endX = min(tileSize, sum)
            guard startX < endX else { continue }
            segments.append(Segment(
                start: Point(x: startX, y: sum - startX),
                end: Point(x: endX, y: sum - endX)
            ))
        }

        return segments
    }

    static var dotCenters: [Point] {
        (0...2).flatMap { row in
            (0...2).compactMap { column in
                guard (row + column).isMultiple(of: 2) else {
                    return nil
                }
                return Point(
                    x: column * spacing,
                    y: row * spacing
                )
            }
        }
    }

    static func svg(lineColor: String, dotColor: String) -> String {
        let path = lineSegments.map { segment in
            "M\(segment.start.x) \(segment.start.y)L\(segment.end.x) \(segment.end.y)"
        }.joined(separator: " ")
        let dots = dotCenters.map { point in
            "<circle cx=\"\(point.x)\" cy=\"\(point.y)\" r=\"\(dotRadius)\"/>"
        }.joined()

        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(tileSize)" height="\(tileSize)" viewBox="0 0 \(tileSize) \(tileSize)">
        <path d="\(path)" fill="none" stroke="\(lineColor)" stroke-opacity="0.10" stroke-width="\(lineWidth)" stroke-linecap="round"/>
        <g fill="\(dotColor)" fill-opacity="0.10">\(dots)</g>
        </svg>
        """
    }

    static func dataURL(lineColor: String, dotColor: String) -> String {
        let data = Data(svg(
            lineColor: lineColor,
            dotColor: dotColor
        ).utf8)
        return "data:image/svg+xml;base64,\(data.base64EncodedString())"
    }
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

nonisolated struct CompositionHTMLComparison: Sendable {
    var mode: CompositionHTMLComparisonMode
    var beforeLabel: String
    var afterLabel: String
    var wipeAxis: CompositionHTMLComparisonAxis
    var wipePositionPercent: Int
    var overlayOpacityPercent: Int
    var blinkIntervalMilliseconds: Int
    var blinkPoster: CompositionHTMLComparisonSide
    var differenceVisibilityPercent: Int

    init(
        mode: CompositionHTMLComparisonMode,
        beforeLabel: String = "Before",
        afterLabel: String = "After",
        wipeAxis: CompositionHTMLComparisonAxis? = nil,
        wipePositionPercent: Int? = nil,
        overlayOpacityPercent: Int? = nil,
        blinkIntervalMilliseconds: Int? = nil,
        blinkPoster: CompositionHTMLComparisonSide? = nil,
        differenceVisibilityPercent: Int? = nil
    ) {
        let modeWipeAxis: CompositionHTMLComparisonAxis?
        let modeWipePosition: Int?
        let modeOverlayOpacity: Int?
        let modeBlinkInterval: Int?
        let modeBlinkPoster: CompositionHTMLComparisonSide?
        let modeDifferenceVisibility: Int?
        switch mode {
        case .wipe(let axis, let position):
            modeWipeAxis = axis
            modeWipePosition = position
            modeOverlayOpacity = nil
            modeBlinkInterval = nil
            modeBlinkPoster = nil
            modeDifferenceVisibility = nil
        case .overlay(let opacity):
            modeWipeAxis = nil
            modeWipePosition = nil
            modeOverlayOpacity = opacity
            modeBlinkInterval = nil
            modeBlinkPoster = nil
            modeDifferenceVisibility = nil
        case .blink(let interval, let poster):
            modeWipeAxis = nil
            modeWipePosition = nil
            modeOverlayOpacity = nil
            modeBlinkInterval = interval
            modeBlinkPoster = poster
            modeDifferenceVisibility = nil
        case .difference(let intensity):
            modeWipeAxis = nil
            modeWipePosition = nil
            modeOverlayOpacity = nil
            modeBlinkInterval = nil
            modeBlinkPoster = nil
            modeDifferenceVisibility = intensity
        case .sideBySide, .renderedDifference, .renderedChangeHighlight:
            modeWipeAxis = nil
            modeWipePosition = nil
            modeOverlayOpacity = nil
            modeBlinkInterval = nil
            modeBlinkPoster = nil
            modeDifferenceVisibility = nil
        }
        self.mode = mode
        self.beforeLabel = beforeLabel
        self.afterLabel = afterLabel
        self.wipeAxis = wipeAxis ?? modeWipeAxis ?? .horizontal
        self.wipePositionPercent = min(
            max(wipePositionPercent ?? modeWipePosition ?? 50, 0),
            100
        )
        self.overlayOpacityPercent = min(
            max(overlayOpacityPercent ?? modeOverlayOpacity ?? 50, 0),
            100
        )
        self.blinkIntervalMilliseconds = min(
            max(blinkIntervalMilliseconds ?? modeBlinkInterval ?? 1_000, 250),
            10_000
        )
        self.blinkPoster = blinkPoster ?? modeBlinkPoster ?? .before
        self.differenceVisibilityPercent = min(
            max(
                differenceVisibilityPercent
                    ?? modeDifferenceVisibility
                    ?? 100,
                0
            ),
            100
        )
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
    var renderedChangeHighlight: CompositionHTMLItem?

    init(
        title: String,
        layout: CompositionHTMLLayout,
        items: [CompositionHTMLItem],
        renderedDifference: CompositionHTMLItem? = nil,
        renderedChangeHighlight: CompositionHTMLItem? = nil,
        languageTag: String = "en"
    ) {
        self.title = title
        self.layout = layout
        self.items = items
        self.renderedDifference = renderedDifference
        self.renderedChangeHighlight = renderedChangeHighlight
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
    case changeHighlightImageEncodingFailed
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
        case .changeHighlightImageEncodingFailed:
            return "The rendered change highlight could not be encoded for interactive HTML export."
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
/// resources are losslessly optimized, metadata-free PNG data URLs plus
/// exporter-owned CSS and JavaScript whose exact SHA-256 hashes are listed in
/// the policy. User text is emitted only as escaped HTML text or attributes; it
/// is never interpolated into CSS or JavaScript.
nonisolated enum CompositionHTMLExporter {
    static let maximumImagePixelCount = 100_000_000
    static let maximumAggregateImagePixelCount = 134_217_728
    static let maximumDocumentBytes = 256 * 1_048_576

    static func data(for document: CompositionHTMLDocument) throws -> Data {
        try checkedData(for: html(for: document))
    }

    /// Performs the lossless image compression and file write away from the
    /// caller's executor. Composition export is commonly initiated by the main
    /// actor, and PNG filtering is intentionally CPU-intensive.
    static func write(
        _ document: CompositionHTMLDocument,
        to destination: URL,
        progress: CompositionOutputProgressHandler? = nil
    ) async throws {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data = try await dataForWriting(
                document,
                progress: progress
            )
            try Task.checkCancellation()
            await progress?(
                CompositionOutputProgressUpdate(
                    phase: .saving,
                    detail: String(localized: "Saving Interactive HTML…"),
                    fractionCompleted: 0.95
                )
            )
            try data.write(to: destination, options: .atomic)
            try Task.checkCancellation()
            await progress?(
                CompositionOutputProgressUpdate(
                    phase: .finalizing,
                    detail: String(localized: "Finishing Interactive HTML export…"),
                    fractionCompleted: 0.98
                )
            )
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func html(for document: CompositionHTMLDocument) throws -> String {
        try Task.checkCancellation()
        try validate(document)
        let encoded = try encodeSynchronously(document)
        return renderHTML(document, encoded: encoded)
    }

    private static func renderHTML(
        _ document: CompositionHTMLDocument,
        encoded: EncodedDocument
    ) -> String {
        let body = renderBody(
            title: document.title,
            layout: document.layout,
            items: encoded.items,
            renderedDifference: encoded.renderedDifference,
            renderedChangeHighlight: encoded.renderedChangeHighlight
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

    private struct EncodedItem: Sendable {
        let title: String
        let caption: String?
        let accessibilityLabel: String
        let stepLabel: String?
        let showsStepNumber: Bool
        let pngDataURL: String
    }

    private struct EncodedDocument: Sendable {
        let items: [EncodedItem]
        let renderedDifference: EncodedItem?
        let renderedChangeHighlight: EncodedItem?
    }

    private enum EncodingFailure: Sendable {
        case item(Int)
        case difference
        case changeHighlight

        var exportError: CompositionHTMLExportError {
            switch self {
            case .item(let index):
                .imageEncodingFailed(index: index)
            case .difference:
                .differenceImageEncodingFailed
            case .changeHighlight:
                .changeHighlightImageEncodingFailed
            }
        }
    }

    private struct EncodingRequest: Sendable {
        let position: Int
        let item: CompositionHTMLItem
        let failure: EncodingFailure
    }

    private static func checkedData(for html: String) throws -> Data {
        try Task.checkCancellation()
        let data = Data(html.utf8)
        try Task.checkCancellation()
        guard data.count <= maximumDocumentBytes else {
            throw CompositionHTMLExportError.documentTooLarge(
                maximumBytes: maximumDocumentBytes
            )
        }
        return data
    }

    private static func dataForWriting(
        _ document: CompositionHTMLDocument,
        progress: CompositionOutputProgressHandler?
    ) async throws -> Data {
        try Task.checkCancellation()
        try validate(document)
        let encoded = try await encodeConcurrently(
            document,
            progress: progress
        )
        try Task.checkCancellation()
        await progress?(
            CompositionOutputProgressUpdate(
                phase: .assembling,
                detail: String(localized: "Building Interactive HTML…"),
                fractionCompleted: 0.90
            )
        )
        return try checkedData(for: renderHTML(document, encoded: encoded))
    }

    private static func encodeSynchronously(
        _ document: CompositionHTMLDocument
    ) throws -> EncodedDocument {
        let requests = encodingRequests(for: document)
        let results = try requests.map { request in
            try Task.checkCancellation()
            return try encode(request.item, failure: request.failure)
        }
        return assembleEncodedDocument(
            results,
            source: document
        )
    }

    private static func encodeConcurrently(
        _ document: CompositionHTMLDocument,
        progress: CompositionOutputProgressHandler?
    ) async throws -> EncodedDocument {
        let requests = encodingRequests(for: document)
        await progress?(
            CompositionOutputProgressUpdate(
                phase: .encoding,
                detail: String(localized: "Encoding images…"),
                fractionCompleted: 0.15
            )
        )
        let largestImagePixels = requests.map {
            $0.item.image.width * $0.item.image.height
        }.max() ?? 1
        // Keep normalized RGBA working buffers near 64 MB while still letting
        // ordinary comparison frames use up to four available cores.
        let memoryLimitedWorkers = max(
            1,
            16_000_000 / max(largestImagePixels, 1)
        )
        let workerCount = min(
            requests.count,
            min(4, memoryLimitedWorkers)
        )
        var results = [EncodedItem?](
            repeating: nil,
            count: requests.count
        )
        var completedRequestCount = 0

        try await withThrowingTaskGroup(
            of: (Int, EncodedItem).self
        ) { group in
            var nextRequestIndex = 0

            func addNextRequest() {
                guard nextRequestIndex < requests.count else {
                    return
                }
                let request = requests[nextRequestIndex]
                nextRequestIndex += 1
                group.addTask {
                    try Task.checkCancellation()
                    return (
                        request.position,
                        try encode(
                            request.item,
                            failure: request.failure
                        )
                    )
                }
            }

            for _ in 0..<workerCount {
                addNextRequest()
            }
            while let (position, item) = try await group.next() {
                results[position] = item
                completedRequestCount += 1
                let detail = String.localizedStringWithFormat(
                    String(localized: "Encoding image %lld of %lld…"),
                    Int64(completedRequestCount),
                    Int64(requests.count)
                )
                await progress?(
                    CompositionOutputProgressUpdate(
                        phase: .encoding,
                        detail: detail,
                        fractionCompleted: 0.15
                            + 0.70 * (
                                Double(completedRequestCount)
                                    / Double(requests.count)
                            )
                    )
                )
                addNextRequest()
            }
        }

        return assembleEncodedDocument(
            results.compactMap { $0 },
            source: document
        )
    }

    private static func encodingRequests(
        for document: CompositionHTMLDocument
    ) -> [EncodingRequest] {
        var requests = document.items.enumerated().map { index, item in
            EncodingRequest(
                position: index,
                item: item,
                failure: .item(index)
            )
        }
        if let renderedDifference = document.renderedDifference {
            requests.append(EncodingRequest(
                position: requests.count,
                item: renderedDifference,
                failure: .difference
            ))
        }
        if let renderedChangeHighlight = document.renderedChangeHighlight {
            requests.append(EncodingRequest(
                position: requests.count,
                item: renderedChangeHighlight,
                failure: .changeHighlight
            ))
        }
        return requests
    }

    private static func assembleEncodedDocument(
        _ results: [EncodedItem],
        source document: CompositionHTMLDocument
    ) -> EncodedDocument {
        let items = Array(results.prefix(document.items.count))
        var position = document.items.count
        let difference: EncodedItem?
        if document.renderedDifference != nil {
            difference = results[position]
            position += 1
        } else {
            difference = nil
        }
        let changeHighlight: EncodedItem?
        if document.renderedChangeHighlight != nil {
            changeHighlight = results[position]
        } else {
            changeHighlight = nil
        }
        return EncodedDocument(
            items: items,
            renderedDifference: difference,
            renderedChangeHighlight: changeHighlight
        )
    }

    private static func validate(_ document: CompositionHTMLDocument) throws {
        guard !document.items.isEmpty else {
            throw CompositionHTMLExportError.emptyComposition
        }
        if case .comparison(let comparison) = document.layout {
            guard document.items.count == 2 else {
                throw CompositionHTMLExportError.comparisonRequiresExactlyTwoItems
            }
            if case .renderedDifference = comparison.mode,
               document.renderedDifference == nil {
                throw CompositionHTMLExportError.renderedComparisonResultRequired
            }
            if case .renderedChangeHighlight = comparison.mode,
               document.renderedChangeHighlight == nil {
                throw CompositionHTMLExportError.renderedComparisonResultRequired
            }
        }
        var aggregatePixels = 0
        let renderedResults = [
            document.renderedDifference,
            document.renderedChangeHighlight,
        ].compactMap { $0 }
        for (index, item) in (document.items + renderedResults)
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

    private static func encode(
        _ item: CompositionHTMLItem,
        failure: EncodingFailure
    ) throws -> EncodedItem {
        do {
            try Task.checkCancellation()
            let pngData = try CompositionHTMLPNGEncoder.data(for: item.image)
            try Task.checkCancellation()
            return EncodedItem(
                title: item.title,
                caption: item.caption,
                accessibilityLabel: item.accessibilityLabel,
                stepLabel: item.stepLabel,
                showsStepNumber: item.showsStepNumber,
                pngDataURL: "data:image/png;base64,\(pngData.base64EncodedString())"
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure.exportError
        }
    }

    private static func renderBody(
        title: String,
        layout: CompositionHTMLLayout,
        items: [EncodedItem],
        renderedDifference: EncodedItem?,
        renderedChangeHighlight: EncodedItem?
    ) -> String {
        let resolvedTitle = title.isEmpty ? "Composition" : title
        let productWebsite = escape(
            AppLinks.snipSnipSnipProduct.absoluteString
        )
        let brandLogo = brandLogoDataURL == nil
            ? ""
            : "<span class=\"brand-logo\" aria-hidden=\"true\"></span>"
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
                renderedDifference: renderedDifference,
                renderedChangeHighlight: renderedChangeHighlight
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
          <p class="brand-attribution">\(brandLogo)<span>Created with <a href="\(productWebsite)" target="_blank" rel="noopener noreferrer external" referrerpolicy="no-referrer" aria-label="Visit the SnipSnipSnip website">SnipSnipSnip</a></span></p>
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
        renderedDifference: EncodedItem?,
        renderedChangeHighlight: EncodedItem?
    ) -> String {
        let before = items[0]
        let after = items[1]
        let beforeLabel = escape(comparison.beforeLabel)
        let afterLabel = escape(comparison.afterLabel)
        let initialMode: String
        let initialValue: Int
        switch comparison.mode {
        case .sideBySide:
            initialMode = "side-by-side"
            initialValue = 50
        case .wipe:
            initialMode = "wipe"
            initialValue = comparison.wipePositionPercent
        case .overlay:
            initialMode = "overlay"
            initialValue = comparison.overlayOpacityPercent
        case .blink:
            initialMode = "blink"
            initialValue = 50
        case .difference:
            initialMode = "difference"
            initialValue = comparison.differenceVisibilityPercent
        case .renderedDifference:
            initialMode = "difference"
            initialValue = 100
        case .renderedChangeHighlight:
            initialMode = "change-highlight"
            initialValue = 100
        }
        let modeOptions = [
            ("side-by-side", "Side by Side"),
            ("wipe", "Wipe"),
            ("overlay", "Overlay"),
            ("blink", "Blink"),
            ("difference", "Difference"),
        ] + (renderedChangeHighlight == nil
            ? []
            : [("change-highlight", "Highlight Changes")])
        let options = modeOptions.map { value, label in
            let selected = value == initialMode ? " selected" : ""
            return "<option value=\"\(value)\"\(selected)>\(label)</option>"
        }.joined(separator: "\n")
        let differenceMarkup: String
        if let renderedDifference {
            differenceMarkup = """
            <figure class="comparison-layer comparison-result comparison-difference-rendered">
              <figcaption class="comparison-caption">Difference</figcaption>
              <img src="\(renderedDifference.pngDataURL)" alt="\(escape(renderedDifference.accessibilityLabel))">
            </figure>
            """
        } else {
            differenceMarkup = ""
        }
        let changeHighlightMarkup: String
        if let renderedChangeHighlight {
            changeHighlightMarkup = """
            <figure class="comparison-layer comparison-result comparison-change-highlight-rendered">
              <figcaption class="comparison-caption">Highlight Changes</figcaption>
              <img src="\(renderedChangeHighlight.pngDataURL)" alt="\(escape(renderedChangeHighlight.accessibilityLabel))">
            </figure>
            """
        } else {
            changeHighlightMarkup = ""
        }
        let initialSideClass: String
        if comparison.blinkPoster == .after {
            initialSideClass = initialMode == "blink"
                ? " show-after poster-after"
                : " poster-after"
        } else {
            initialSideClass = " poster-before"
        }
        let differenceFallbackClass = renderedDifference == nil
            ? " difference-fallback"
            : ""
        func hiddenUnless(_ mode: String) -> String {
            mode == initialMode ? "" : " hidden"
        }
        let initialHelp: String
        switch initialMode {
        case "wipe":
            initialHelp = "Drag the divider on the image, or use the Reveal After control."
        case "overlay":
            initialHelp = "Adjust how strongly After appears over Before."
        case "blink":
            initialHelp = "Choose a side or play the comparison automatically."
        case "difference":
            initialHelp = "Brighter pixels show where Before and After differ."
        case "change-highlight":
            initialHelp = "Highlighted areas show the changes detected by SnipSnipSnip."
        default:
            initialHelp = "View both images together, or focus on either one."
        }
        let initialStatus = initialMode == "side-by-side"
            ? "Showing \(beforeLabel) and \(afterLabel)"
            : "Using \(modeOptions.first { $0.0 == initialMode }?.1 ?? "comparison")"
        let axis = comparison.wipeAxis.rawValue
        let leftToRightSelected = comparison.wipeAxis == .horizontal
            ? " selected"
            : ""
        let topToBottomSelected = comparison.wipeAxis == .vertical
            ? " selected"
            : ""
        let changeHighlightControls: String
        if renderedChangeHighlight == nil {
            changeHighlightControls = ""
        } else {
            changeHighlightControls = """
            <div class="comparison-mode-controls" data-controls-for="change-highlight"\(hiddenUnless("change-highlight"))>
              <label class="comparison-control">Result Visibility
                <input type="range" min="0" max="100" value="100" data-change-highlight-range>
                <output data-change-highlight-output>100%</output>
              </label>
            </div>
            """
        }
        return """
        <section class="comparison comparison-value-\(initialValue) comparison-zoom-100\(initialSideClass)\(differenceFallbackClass)" data-comparison data-comparison-mode="\(initialMode)" data-active-mode="\(initialMode)" data-axis="\(axis)" data-initial-value="\(initialValue)" data-wipe-position="\(comparison.wipePositionPercent)" data-overlay-opacity="\(comparison.overlayOpacityPercent)" data-difference-visibility="\(comparison.differenceVisibilityPercent)" data-interval="\(comparison.blinkIntervalMilliseconds)" data-poster="\(comparison.blinkPoster.rawValue)" data-before-label="\(beforeLabel)" data-after-label="\(afterLabel)" aria-label="\(beforeLabel) and \(afterLabel) comparison">
          <div class="comparison-toolbar" aria-label="Comparison viewer controls">
            <label class="comparison-mode-control" for="comparison-mode">Compare Using
              <select id="comparison-mode" data-mode-select>
              \(options)
              </select>
            </label>
            <div class="comparison-zoom-controls" role="group" aria-label="Zoom">
              <button type="button" data-zoom-out>Zoom Out</button>
              <button type="button" data-zoom-fit aria-pressed="true">Fit</button>
              <button type="button" data-zoom-in>Zoom In</button>
              <output data-zoom-status>Fit</output>
            </div>
          </div>
          <p class="comparison-help" data-mode-help>\(initialHelp)</p>
          <div class="comparison-labels" aria-hidden="true">
            <span class="comparison-label comparison-label-before">\(beforeLabel)</span>
            <span class="comparison-label comparison-label-after">\(afterLabel)</span>
            <span class="comparison-label comparison-label-difference">Difference</span>
            <span class="comparison-label comparison-label-change-highlight">Highlight Changes</span>
          </div>
          <div class="comparison-viewport" data-comparison-viewport>
            <div class="comparison-stage" data-comparison-stage>
              <figure class="comparison-layer comparison-before">
                <figcaption class="comparison-caption">\(beforeLabel)</figcaption>
                <img src="\(before.pngDataURL)" alt="\(escape(before.accessibilityLabel))">
              </figure>
              <figure class="comparison-layer comparison-after">
                <figcaption class="comparison-caption">\(afterLabel)</figcaption>
                <img src="\(after.pngDataURL)" alt="\(escape(after.accessibilityLabel))">
              </figure>
              \(differenceMarkup)
              \(changeHighlightMarkup)
              <span class="comparison-divider" aria-hidden="true"></span>
            </div>
          </div>
          <div class="comparison-mode-controls" data-controls-for="side-by-side"\(hiddenUnless("side-by-side"))>
            <div class="comparison-buttons" aria-label="Side by Side view">
              <button type="button" data-side-by-side-view="both" aria-pressed="true">Show Both</button>
              <button type="button" data-side-by-side-view="before" aria-pressed="false">\(beforeLabel)</button>
              <button type="button" data-side-by-side-view="after" aria-pressed="false">\(afterLabel)</button>
            </div>
          </div>
          <div class="comparison-mode-controls comparison-control-stack" data-controls-for="wipe"\(hiddenUnless("wipe"))>
            <label class="comparison-control">Reveal After
              <input type="range" min="0" max="100" value="\(comparison.wipePositionPercent)" data-wipe-range aria-label="Reveal \(afterLabel)">
              <output data-wipe-output>\(comparison.wipePositionPercent)%</output>
            </label>
            <label class="comparison-control">Direction
              <select data-wipe-axis>
                <option value="horizontal"\(leftToRightSelected)>Left to Right</option>
                <option value="vertical"\(topToBottomSelected)>Top to Bottom</option>
              </select>
            </label>
          </div>
          <div class="comparison-mode-controls" data-controls-for="overlay"\(hiddenUnless("overlay"))>
            <label class="comparison-control">After Opacity
              <input type="range" min="0" max="100" value="\(comparison.overlayOpacityPercent)" data-overlay-range>
              <output data-overlay-output>\(comparison.overlayOpacityPercent)%</output>
            </label>
          </div>
          <div class="comparison-mode-controls comparison-control-stack" data-controls-for="blink"\(hiddenUnless("blink"))>
            <div class="comparison-buttons" aria-label="Blink controls">
              <button type="button" data-blink-before>\(beforeLabel)</button>
              <button type="button" data-blink-toggle aria-pressed="false">Play</button>
              <button type="button" data-blink-after>\(afterLabel)</button>
            </div>
            <label class="comparison-control">Time Per Image
              <input type="range" min="250" max="10000" step="250" value="\(comparison.blinkIntervalMilliseconds)" data-blink-interval>
              <output data-blink-interval-output></output>
            </label>
          </div>
          <div class="comparison-mode-controls" data-controls-for="difference"\(hiddenUnless("difference"))>
            <label class="comparison-control">Result Visibility
              <input type="range" min="0" max="100" value="\(comparison.differenceVisibilityPercent)" data-difference-range>
              <output data-difference-output>\(comparison.differenceVisibilityPercent)%</output>
            </label>
          </div>
          \(changeHighlightControls)
          <p class="comparison-status" aria-live="polite" data-comparison-status>\(initialStatus)</p>
          <noscript><p>The selected comparison view is shown. Enable JavaScript to switch views, zoom, and use the interactive controls.</p></noscript>
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

    private static let brandLogoDataURL: String? = {
        guard let asset = NSDataAsset(
            name: "HTMLExportLogo",
            bundle: .main
        ) else {
            return nil
        }
        return "data:image/png;base64,\(asset.data.base64EncodedString())"
    }()

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
html {
  color: var(--text);
  background-color: var(--background);
  background-repeat: repeat;
  background-position: 0 0;
  background-attachment: fixed;
}
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
.brand-attribution {
  display: inline-flex;
  align-items: center;
  gap: 0.55rem;
  margin: 0;
}
.brand-logo {
  display: block;
  width: 2rem;
  height: 2rem;
  flex: 0 0 auto;
  border-radius: 0.45rem;
  background-position: center;
  background-repeat: no-repeat;
  background-size: contain;
}
.document-footer a {
  color: inherit;
  font-weight: 600;
  text-underline-offset: 0.14em;
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
.comparison-toolbar {
  display: none;
  align-items: end;
  justify-content: space-between;
  gap: 1rem;
  margin-bottom: 0.75rem;
}
.is-enhanced .comparison-toolbar { display: flex; }
.comparison-mode-control {
  display: grid;
  gap: 0.3rem;
  color: var(--secondary);
  font-size: 0.875rem;
  font-weight: 600;
}
select {
  min-height: 2.25rem;
  border: 1px solid var(--border);
  border-radius: 0.55rem;
  color: var(--text);
  background: var(--surface);
  padding: 0.4rem 2rem 0.4rem 0.65rem;
  font: inherit;
}
.comparison-zoom-controls {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 0.45rem;
  flex-wrap: wrap;
}
.comparison-zoom-controls output {
  min-width: 3.5rem;
  color: var(--secondary);
  text-align: end;
}
.comparison-help {
  min-height: 1.4rem;
  margin: 0 0 0.75rem;
  color: var(--secondary);
}
.comparison-labels {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 1rem;
  padding: 0.65rem 0.75rem 0.45rem;
  border-radius: 0.55rem 0.55rem 0 0;
  color: #fff;
  background: #000;
  font-weight: 700;
}
.comparison-label-after { text-align: end; }
.comparison-label-difference,
.comparison-label-change-highlight {
  display: none;
  grid-column: 1 / -1;
}
.comparison[data-active-mode="side-by-side"] .comparison-labels {
  display: none;
}
.comparison[data-active-mode="difference"] .comparison-label-before,
.comparison[data-active-mode="difference"] .comparison-label-after,
.comparison[data-active-mode="change-highlight"] .comparison-label-before,
.comparison[data-active-mode="change-highlight"] .comparison-label-after {
  display: none;
}
.comparison[data-active-mode="difference"] .comparison-label-difference,
.comparison[data-active-mode="change-highlight"] .comparison-label-change-highlight {
  display: block;
}
.comparison-viewport {
  max-height: 75vh;
  overflow: auto;
  overscroll-behavior: contain;
  border-radius: 0.55rem;
  background: #000;
}
.comparison:not([data-active-mode="side-by-side"])
  .comparison-labels + .comparison-viewport {
  border-radius: 0 0 0.55rem 0.55rem;
}
.comparison.comparison-is-fit .comparison-viewport {
  max-height: none;
  overflow: hidden;
}
.comparison-stage {
  display: grid;
  position: relative;
  width: var(--comparison-zoom, 100%);
  min-width: 0;
  margin-inline: auto;
  border-radius: 0.55rem;
  background: #000;
}
.comparison-layer {
  grid-area: 1 / 1;
  margin: 0;
  min-width: 0;
  overflow: hidden;
}
.comparison-layer img {
  width: 100%;
  user-select: none;
  -webkit-user-drag: none;
}
.comparison-caption {
  position: absolute;
  width: 1px;
  height: 1px;
  margin: -1px;
  padding: 0;
  overflow: hidden;
  clip: rect(0 0 0 0);
  clip-path: inset(50%);
  white-space: nowrap;
  border: 0;
}
.comparison-result { display: none; }
.comparison[data-active-mode="side-by-side"] .comparison-stage {
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 1rem;
  padding: 0.75rem;
}
.comparison[data-active-mode="side-by-side"] .comparison-before {
  grid-area: 1 / 1;
}
.comparison[data-active-mode="side-by-side"] .comparison-after {
  grid-area: 1 / 2;
}
.comparison[data-active-mode="side-by-side"] .comparison-caption {
  position: static;
  width: auto;
  height: auto;
  margin: 0 0 0.45rem;
  padding: 0.3rem 0.55rem;
  overflow: visible;
  clip: auto;
  clip-path: none;
  white-space: normal;
  border: 0;
  color: #fff;
  background: transparent;
  font-weight: 700;
}
.comparison[data-active-mode="side-by-side"].show-before .comparison-stage,
.comparison[data-active-mode="side-by-side"].show-after .comparison-stage {
  grid-template-columns: minmax(0, 1fr);
}
.comparison[data-active-mode="side-by-side"].show-before .comparison-after,
.comparison[data-active-mode="side-by-side"].show-after .comparison-before {
  display: none;
}
.comparison[data-active-mode="side-by-side"].show-before .comparison-before,
.comparison[data-active-mode="side-by-side"].show-after .comparison-after {
  grid-area: 1 / 1;
}
.comparison[data-active-mode="wipe"] .comparison-stage {
  cursor: ew-resize;
}
.comparison[data-active-mode="wipe"][data-axis="vertical"] .comparison-stage {
  cursor: ns-resize;
}
.comparison[data-active-mode="wipe"][data-axis="horizontal"] .comparison-after {
  clip-path: inset(0 calc(100% - var(--comparison-position)) 0 0);
}
.comparison[data-active-mode="wipe"][data-axis="vertical"] .comparison-after {
  clip-path: inset(0 0 calc(100% - var(--comparison-position)) 0);
}
.comparison-divider {
  display: none;
  position: absolute;
  z-index: 4;
  pointer-events: none;
  background: #fff;
  box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.55);
}
.is-enhanced .comparison[data-active-mode="wipe"] .comparison-divider {
  display: block;
}
.comparison[data-active-mode="wipe"][data-axis="horizontal"] .comparison-divider {
  top: 0;
  bottom: 0;
  left: var(--comparison-position);
  width: 3px;
  transform: translateX(-1.5px);
}
.comparison[data-active-mode="wipe"][data-axis="vertical"] .comparison-divider {
  right: 0;
  left: 0;
  top: var(--comparison-position);
  height: 3px;
  transform: translateY(-1.5px);
}
.comparison-divider::after {
  content: "↔";
  position: absolute;
  top: 50%;
  left: 50%;
  display: grid;
  width: 2.4rem;
  height: 2.4rem;
  place-items: center;
  border: 2px solid #fff;
  border-radius: 50%;
  color: #fff;
  background: rgba(0, 0, 0, 0.76);
  transform: translate(-50%, -50%);
  font-weight: 700;
}
.comparison[data-active-mode="wipe"][data-axis="vertical"] .comparison-divider::after {
  content: "↕";
}
.comparison[data-active-mode="overlay"] .comparison-after {
  opacity: var(--comparison-opacity);
}
.comparison[data-active-mode="blink"] .comparison-after { visibility: hidden; }
.comparison[data-active-mode="blink"].show-after .comparison-before { visibility: hidden; }
.comparison[data-active-mode="blink"].show-after .comparison-after { visibility: visible; }
.comparison[data-active-mode="difference"] .comparison-after,
.comparison[data-active-mode="change-highlight"] .comparison-after {
  visibility: hidden;
}
.comparison[data-active-mode="difference"] .comparison-difference-rendered,
.comparison[data-active-mode="change-highlight"] .comparison-change-highlight-rendered {
  display: block;
  opacity: var(--comparison-opacity);
}
.comparison[data-active-mode="difference"].difference-fallback .comparison-after {
  visibility: visible;
  mix-blend-mode: difference;
  opacity: var(--comparison-opacity);
}
.comparison-mode-controls {
  display: none;
  margin-top: 1rem;
}
.is-enhanced .comparison-mode-controls { display: block; }
.comparison-mode-controls[hidden] { display: none !important; }
.comparison-control,
.comparison-buttons {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.75rem;
  flex-wrap: wrap;
}
.is-enhanced .comparison-control-stack {
  display: grid;
  gap: 0.75rem;
}
.comparison-control input { width: min(32rem, 70vw); }
.comparison-control output {
  min-width: 3.5rem;
  color: var(--secondary);
}
.comparison-buttons button[aria-pressed="true"],
.comparison-zoom-controls button[aria-pressed="true"] {
  border-color: var(--accent);
  color: var(--text);
  font-weight: 700;
  box-shadow: inset 0 0 0 1px var(--accent);
}
.comparison-status {
  min-height: 1.4rem;
  margin-bottom: 0;
  text-align: center;
  color: var(--secondary);
}
@media (max-width: 720px) {
  .composition-grid,
  .composition-grid[class*="columns-"] {
    grid-template-columns: 1fr;
  }
  .steps-layout { grid-template-columns: 1fr; }
  .step-navigation { position: static; max-height: none; }
  .step-controls { grid-column: 1; }
  .comparison-toolbar { align-items: stretch; flex-direction: column; }
  .comparison-zoom-controls { justify-content: flex-start; }
  .comparison[data-active-mode="side-by-side"] .comparison-stage {
    grid-template-columns: 1fr;
  }
  .comparison[data-active-mode="side-by-side"] .comparison-before {
    grid-area: 1 / 1;
  }
  .comparison[data-active-mode="side-by-side"] .comparison-after {
    grid-area: 2 / 1;
  }
}
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    scroll-behavior: auto !important;
    transition-duration: 0.001ms !important;
    animation-duration: 0.001ms !important;
  }
}
@media (prefers-contrast: more) {
  html { background-image: none; }
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
  html { background: #fff; }
  body { min-width: 0; }
  .document-header, .composition {
    width: 100%;
    margin: 0;
  }
  .document-footer,
  .step-navigation,
  .step-controls,
  .comparison-toolbar,
  .comparison-help,
  .comparison-mode-controls,
  .comparison-control,
  .comparison-buttons,
  .comparison-status,
  .comparison-divider {
    display: none !important;
  }
  .comparison-viewport {
    max-height: none;
    overflow: visible;
  }
  .comparison-stage { width: 100% !important; }
  .steps-layout { display: block; }
  .is-enhanced .step-card[hidden] { display: block !important; }
  .step-card {
    break-inside: avoid;
    page-break-inside: avoid;
    box-shadow: none;
    margin-bottom: 1rem;
  }
  .composition-card, .comparison { box-shadow: none; }
  .comparison[data-active-mode="side-by-side"].show-before .comparison-stage,
  .comparison[data-active-mode="side-by-side"].show-after .comparison-stage {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
  .comparison[data-active-mode="side-by-side"] .comparison-before {
    grid-area: 1 / 1;
  }
  .comparison[data-active-mode="side-by-side"] .comparison-after {
    grid-area: 1 / 2;
  }
  .comparison[data-active-mode="side-by-side"] .comparison-layer {
    display: block !important;
  }
  .comparison[data-active-mode="blink"].poster-before .comparison-before { visibility: visible !important; }
  .comparison[data-active-mode="blink"].poster-before .comparison-after { visibility: hidden !important; }
  .comparison[data-active-mode="blink"].poster-after .comparison-before { visibility: hidden !important; }
  .comparison[data-active-mode="blink"].poster-after .comparison-after { visibility: visible !important; }
}
@media (forced-colors: active) {
  html { background-image: none; }
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
        let brandLogoRule = brandLogoDataURL.map {
            #".brand-logo { background-image: url("\#($0)"); }"#
        } ?? ".brand-logo { display: none; }"
        let lightPattern = CompositionHTMLBrandPattern.dataURL(
            lineColor: "#33549c",
            dotColor: "#294794"
        )
        let darkPattern = CompositionHTMLBrandPattern.dataURL(
            lineColor: "#9eb8fa",
            dotColor: "#b3ccff"
        )
        let brandPatternRules = """
        html {
          background-image: url("\(lightPattern)");
          background-size: \(CompositionHTMLBrandPattern.tileSize)px \(CompositionHTMLBrandPattern.tileSize)px;
        }
        @media (prefers-color-scheme: dark) {
          html { background-image: url("\(darkPattern)"); }
        }
        """
        let comparisonValueRules = (0...100).map { value in
            let fraction = Double(value) / 100
            let inverse = 100 - value
            return """
            .comparison.comparison-value-\(value) {
              --comparison-position: \(value)%;
              --comparison-opacity: \(fraction);
            }
            .comparison.comparison-value-\(value)[data-active-mode="wipe"][data-axis="horizontal"] .comparison-after {
              clip-path: inset(0 \(inverse)% 0 0);
            }
            .comparison.comparison-value-\(value)[data-active-mode="wipe"][data-axis="vertical"] .comparison-after {
              clip-path: inset(0 0 \(inverse)% 0);
            }
            .comparison.comparison-value-\(value)[data-active-mode="overlay"] .comparison-after {
              opacity: \(fraction);
            }
            .comparison.comparison-value-\(value)[data-active-mode="difference"] .comparison-difference-rendered,
            .comparison.comparison-value-\(value)[data-active-mode="change-highlight"] .comparison-change-highlight-rendered {
              opacity: \(fraction);
            }
            """
        }.joined(separator: "\n")
        let comparisonZoomRules = stride(from: 50, through: 200, by: 25).map {
            ".comparison.comparison-zoom-\($0) { --comparison-zoom: \($0)%; }"
        }.joined(separator: "\n")
        let comparisonFitRules = stride(from: 10, through: 100, by: 5).map {
            ".comparison.comparison-fit-\($0) { --comparison-zoom: \($0)%; }"
        }.joined(separator: "\n")
        return """
        \(baseStyleSource)
        \(brandLogoRule)
        \(brandPatternRules)
        \(comparisonValueRules)
        \(comparisonZoomRules)
        \(comparisonFitRules)
        """
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
    const modeSelect = comparison.querySelector("[data-mode-select]");
    const modeControls = Array.from(comparison.querySelectorAll("[data-controls-for]"));
    const status = comparison.querySelector("[data-comparison-status]");
    const help = comparison.querySelector("[data-mode-help]");
    const stage = comparison.querySelector("[data-comparison-stage]");
    const viewport = comparison.querySelector("[data-comparison-viewport]");
    if (!modeSelect || !status || !help || !stage || !viewport) return;

    const beforeLabel = comparison.dataset.beforeLabel || "Before";
    const afterLabel = comparison.dataset.afterLabel || "After";
    const modes = Array.from(modeSelect.options).map((option) => option.value);
    const zoomLevels = [50, 75, 100, 125, 150, 175, 200];
    const reduceMotionQuery = window.matchMedia(
      "(prefers-reduced-motion: reduce)"
    );
    const hash = new URLSearchParams(location.hash.replace(/^#/, ""));
    const numberFrom = (name, fallback, minimum, maximum) => {
      const rawValue = hash.get(name);
      if (rawValue === null || rawValue === "") return fallback;
      const value = Number(rawValue);
      return Number.isFinite(value) ? clamp(value, minimum, maximum) : fallback;
    };
    const requestedMode = hash.get("view");
    const requestedSide = hash.get("side");
    const requestedAxis = hash.get("axis");
    const requestedZoomValue = hash.get("zoom");
    const requestedZoom = numberFrom("zoom", 100, 50, 200);
    const nearestZoom = zoomLevels.reduce((nearest, value) =>
      Math.abs(value - requestedZoom) < Math.abs(nearest - requestedZoom)
        ? value
        : nearest
    );
    const state = {
      mode: modes.includes(requestedMode)
        ? requestedMode
        : comparison.dataset.activeMode,
      side: ["both", "before", "after"].includes(requestedSide)
        ? requestedSide
        : "both",
      axis: ["horizontal", "vertical"].includes(requestedAxis)
        ? requestedAxis
        : comparison.dataset.axis,
      wipe: Math.round(numberFrom(
        "reveal",
        Number(comparison.dataset.wipePosition || 50),
        0,
        100
      )),
      overlay: Math.round(numberFrom(
        "opacity",
        Number(comparison.dataset.overlayOpacity || 50),
        0,
        100
      )),
      difference: Math.round(numberFrom(
        "difference",
        Number(comparison.dataset.differenceVisibility || 100),
        0,
        100
      )),
      highlight: Math.round(numberFrom("highlight", 100, 0, 100)),
      interval: Math.round(numberFrom(
        "interval",
        Number(comparison.dataset.interval || 1000),
        250,
        10000
      ) / 250) * 250,
      zoom: requestedZoomValue === null
          || requestedZoomValue === ""
          || requestedZoomValue === "fit"
        ? "fit"
        : nearestZoom,
      showingAfter: comparison.dataset.poster === "after",
      motionOverride: false,
    };
    const sideButtons = Array.from(
      comparison.querySelectorAll("[data-side-by-side-view]")
    );
    const wipeRange = comparison.querySelector("[data-wipe-range]");
    const wipeOutput = comparison.querySelector("[data-wipe-output]");
    const axisSelect = comparison.querySelector("[data-wipe-axis]");
    const overlayRange = comparison.querySelector("[data-overlay-range]");
    const overlayOutput = comparison.querySelector("[data-overlay-output]");
    const differenceRange = comparison.querySelector("[data-difference-range]");
    const differenceOutput = comparison.querySelector("[data-difference-output]");
    const highlightRange = comparison.querySelector("[data-change-highlight-range]");
    const highlightOutput = comparison.querySelector("[data-change-highlight-output]");
    const blinkInterval = comparison.querySelector("[data-blink-interval]");
    const blinkIntervalOutput = comparison.querySelector("[data-blink-interval-output]");
    const blinkToggle = comparison.querySelector("[data-blink-toggle]");
    const blinkBefore = comparison.querySelector("[data-blink-before]");
    const blinkAfter = comparison.querySelector("[data-blink-after]");
    const zoomOut = comparison.querySelector("[data-zoom-out]");
    const zoomFit = comparison.querySelector("[data-zoom-fit]");
    const zoomIn = comparison.querySelector("[data-zoom-in]");
    const zoomStatus = comparison.querySelector("[data-zoom-status]");
    let timer = null;

    const replaceNumberClass = (prefix, requested) => {
      const value = Math.round(Number(requested));
      Array.from(comparison.classList).forEach((name) => {
        if (name.startsWith(prefix)) comparison.classList.remove(name);
      });
      comparison.classList.add(`${prefix}${value}`);
      return value;
    };
    const setValue = (requested) =>
      replaceNumberClass("comparison-value-", clamp(Number(requested), 0, 100));
    const clearZoomClasses = () => {
      Array.from(comparison.classList).forEach((name) => {
        if (
          name.startsWith("comparison-zoom-")
          || name.startsWith("comparison-fit-")
        ) {
          comparison.classList.remove(name);
        }
      });
    };
    const updateZoomControls = (index, isFit) => {
      zoomOut.disabled = !isFit && index === 0;
      zoomIn.disabled = !isFit && index === zoomLevels.length - 1;
      zoomFit.setAttribute("aria-pressed", isFit ? "true" : "false");
      zoomStatus.textContent = isFit ? "Fit" : `${state.zoom}%`;
    };
    const setZoom = (requested) => {
      const index = clamp(
        zoomLevels.indexOf(requested),
        0,
        zoomLevels.length - 1
      );
      state.zoom = zoomLevels[index];
      comparison.classList.remove("comparison-is-fit");
      clearZoomClasses();
      comparison.classList.add(`comparison-zoom-${state.zoom}`);
      updateZoomControls(index, false);
    };
    let pendingFitFrame = null;
    const setFit = () => {
      state.zoom = "fit";
      clearZoomClasses();
      comparison.classList.add("comparison-is-fit");
      comparison.classList.add("comparison-zoom-100");
      updateZoomControls(zoomLevels.indexOf(100), true);
      if (pendingFitFrame !== null) {
        window.cancelAnimationFrame(pendingFitFrame);
      }
      pendingFitFrame = window.requestAnimationFrame(() => {
        pendingFitFrame = null;
        if (state.zoom !== "fit") return;
        const comparisonBounds = comparison.getBoundingClientRect();
        const viewportBounds = viewport.getBoundingClientRect();
        const stageHeightAtFullWidth = stage.getBoundingClientRect().height;
        const chromeHeight = Math.max(
          comparisonBounds.height - viewportBounds.height,
          0
        );
        const availableComparisonHeight = Math.max(
          window.innerHeight - Math.max(comparisonBounds.top, 0) - 16,
          0
        );
        const availableStageHeight = Math.max(
          availableComparisonHeight - chromeHeight,
          0
        );
        const rawFitPercent = stageHeightAtFullWidth > 0
          ? availableStageHeight / stageHeightAtFullWidth * 100
          : 100;
        const fitPercent = clamp(
          Math.floor(rawFitPercent / 5) * 5,
          10,
          100
        );
        clearZoomClasses();
        comparison.classList.add(`comparison-fit-${fitPercent}`);
      });
    };
    const applyZoom = () => {
      if (state.zoom === "fit") setFit();
      else setZoom(state.zoom);
    };

    const formatInterval = (milliseconds) => {
      const seconds = milliseconds / 1000;
      return `${Number.isInteger(seconds) ? seconds : seconds.toFixed(2)} sec`;
    };
    const blinkPlayLabel = () =>
      reduceMotionQuery.matches && !state.motionOverride
        ? "Play Anyway"
        : "Play";
    const stopBlink = () => {
      if (timer !== null) window.clearInterval(timer);
      timer = null;
      if (blinkToggle) {
        blinkToggle.textContent = blinkPlayLabel();
        blinkToggle.setAttribute("aria-pressed", "false");
      }
    };

    const updateHash = () => {
      const values = new URLSearchParams();
      values.set("view", state.mode);
      values.set("zoom", state.zoom);
      values.set("side", state.side);
      values.set("axis", state.axis);
      values.set("reveal", state.wipe);
      values.set("opacity", state.overlay);
      values.set("difference", state.difference);
      values.set("highlight", state.highlight);
      values.set("interval", state.interval);
      const nextHash = `#${values.toString()}`;
      try {
        history.replaceState(null, "", nextHash);
      } catch (_) {
        location.hash = nextHash;
      }
    };

    const updateStatus = () => {
      switch (state.mode) {
      case "side-by-side":
        status.textContent = state.side === "both"
          ? `Showing ${beforeLabel} and ${afterLabel}`
          : `Showing ${state.side === "before" ? beforeLabel : afterLabel}`;
        break;
      case "wipe":
        status.textContent = `${state.wipe}% of ${afterLabel} revealed`;
        break;
      case "overlay":
        status.textContent = `${afterLabel} opacity: ${state.overlay}%`;
        break;
      case "blink":
        if (
          timer === null
          && reduceMotionQuery.matches
          && !state.motionOverride
        ) {
          status.textContent =
            "Blink is ready. To respect Reduce Motion, it starts paused.";
        } else {
          status.textContent = timer === null
            ? `Showing ${state.showingAfter ? afterLabel : beforeLabel}`
            : `Alternating ${beforeLabel} and ${afterLabel}`;
        }
        break;
      case "difference":
        status.textContent = `Difference visibility: ${state.difference}%`;
        break;
      case "change-highlight":
        status.textContent = `Highlighted changes visibility: ${state.highlight}%`;
        break;
      }
    };

    const render = (persist) => {
      if (state.mode !== "blink") stopBlink();
      comparison.dataset.activeMode = state.mode;
      comparison.dataset.comparisonMode = state.mode;
      comparison.dataset.axis = state.axis;
      modeSelect.value = state.mode;
      modeControls.forEach((controls) => {
        controls.hidden = controls.dataset.controlsFor !== state.mode;
      });
      comparison.classList.toggle(
        "show-before",
        state.mode === "side-by-side" && state.side === "before"
      );
      comparison.classList.toggle(
        "show-after",
        (state.mode === "side-by-side" && state.side === "after")
          || (state.mode === "blink" && state.showingAfter)
      );
      sideButtons.forEach((button) => {
        button.setAttribute(
          "aria-pressed",
          button.dataset.sideBySideView === state.side ? "true" : "false"
        );
      });
      if (wipeRange) wipeRange.value = state.wipe;
      if (wipeOutput) wipeOutput.textContent = `${state.wipe}%`;
      if (axisSelect) axisSelect.value = state.axis;
      if (overlayRange) overlayRange.value = state.overlay;
      if (overlayOutput) overlayOutput.textContent = `${state.overlay}%`;
      if (differenceRange) differenceRange.value = state.difference;
      if (differenceOutput) differenceOutput.textContent = `${state.difference}%`;
      if (highlightRange) highlightRange.value = state.highlight;
      if (highlightOutput) highlightOutput.textContent = `${state.highlight}%`;
      if (blinkInterval) blinkInterval.value = state.interval;
      if (blinkIntervalOutput) {
        blinkIntervalOutput.textContent = formatInterval(state.interval);
      }
      if (blinkToggle && timer === null) {
        blinkToggle.textContent = blinkPlayLabel();
        blinkToggle.setAttribute("aria-pressed", "false");
      }
      const value = state.mode === "wipe"
        ? state.wipe
        : state.mode === "overlay"
          ? state.overlay
          : state.mode === "difference"
            ? state.difference
            : state.mode === "change-highlight"
              ? state.highlight
              : 50;
      setValue(value);
      applyZoom();
      const helpByMode = {
        "side-by-side": "View both images together, or focus on either one.",
        wipe: "Drag the divider on the image, or use the Reveal After control.",
        overlay: `Adjust how strongly ${afterLabel} appears over ${beforeLabel}.`,
        blink: reduceMotionQuery.matches && !state.motionOverride
          ? `Choose ${beforeLabel} or ${afterLabel}, or choose Play Anyway to alternate them.`
          : "Choose a side or play the comparison automatically.",
        difference: `Brighter pixels show where ${beforeLabel} and ${afterLabel} differ.`,
        "change-highlight": "Highlighted areas show the changes detected by SnipSnipSnip.",
      };
      help.textContent = helpByMode[state.mode] || "";
      updateStatus();
      if (persist) updateHash();
    };

    const playBlink = (allowReducedMotion) => {
      if (reduceMotionQuery.matches && !state.motionOverride) {
        if (!allowReducedMotion) {
          render(false);
          return;
        }
        state.motionOverride = true;
        render(false);
      }
      timer = window.setInterval(() => {
        state.showingAfter = !state.showingAfter;
        comparison.classList.toggle("show-after", state.showingAfter);
        updateStatus();
      }, state.interval);
      blinkToggle.textContent = "Pause";
      blinkToggle.setAttribute("aria-pressed", "true");
      updateStatus();
    };

    modeSelect.addEventListener("change", () => {
      state.mode = modes.includes(modeSelect.value)
        ? modeSelect.value
        : "side-by-side";
      render(true);
    });
    sideButtons.forEach((button) => {
      button.addEventListener("click", () => {
        state.side = button.dataset.sideBySideView;
        render(true);
      });
    });
    wipeRange?.addEventListener("input", () => {
      state.wipe = Math.round(Number(wipeRange.value));
      render(true);
    });
    axisSelect?.addEventListener("change", () => {
      state.axis = axisSelect.value === "vertical" ? "vertical" : "horizontal";
      render(true);
    });
    overlayRange?.addEventListener("input", () => {
      state.overlay = Math.round(Number(overlayRange.value));
      render(true);
    });
    differenceRange?.addEventListener("input", () => {
      state.difference = Math.round(Number(differenceRange.value));
      render(true);
    });
    highlightRange?.addEventListener("input", () => {
      state.highlight = Math.round(Number(highlightRange.value));
      render(true);
    });
    blinkInterval?.addEventListener("input", () => {
      const wasPlaying = timer !== null;
      stopBlink();
      state.interval = Math.round(Number(blinkInterval.value) / 250) * 250;
      render(true);
      if (wasPlaying) playBlink(false);
    });
    blinkToggle?.addEventListener("click", () => {
      if (timer === null) playBlink(true);
      else {
        stopBlink();
        updateStatus();
      }
    });
    blinkBefore?.addEventListener("click", () => {
      stopBlink();
      state.showingAfter = false;
      render(true);
    });
    blinkAfter?.addEventListener("click", () => {
      stopBlink();
      state.showingAfter = true;
      render(true);
    });

    zoomOut.addEventListener("click", () => {
      const index = state.zoom === "fit"
        ? zoomLevels.indexOf(100)
        : zoomLevels.indexOf(state.zoom);
      setZoom(zoomLevels[Math.max(index - 1, 0)]);
      updateHash();
    });
    zoomFit.addEventListener("click", () => {
      setFit();
      viewport.scrollTo({ top: 0, left: 0 });
      updateHash();
    });
    zoomIn.addEventListener("click", () => {
      const index = state.zoom === "fit"
        ? zoomLevels.indexOf(100)
        : zoomLevels.indexOf(state.zoom);
      setZoom(zoomLevels[Math.min(index + 1, zoomLevels.length - 1)]);
      updateHash();
    });

    let draggingWipe = false;
    const updateWipeFromPointer = (event) => {
      const bounds = stage.getBoundingClientRect();
      const fraction = state.axis === "horizontal"
        ? (event.clientX - bounds.left) / bounds.width
        : (event.clientY - bounds.top) / bounds.height;
      state.wipe = Math.round(clamp(fraction * 100, 0, 100));
      if (wipeRange) wipeRange.value = state.wipe;
      if (wipeOutput) wipeOutput.textContent = `${state.wipe}%`;
      setValue(state.wipe);
      updateStatus();
    };
    stage.addEventListener("pointerdown", (event) => {
      if (state.mode !== "wipe") return;
      draggingWipe = true;
      stage.setPointerCapture?.(event.pointerId);
      updateWipeFromPointer(event);
      event.preventDefault();
    });
    stage.addEventListener("pointermove", (event) => {
      if (!draggingWipe) return;
      updateWipeFromPointer(event);
      event.preventDefault();
    });
    const finishWipeDrag = () => {
      if (!draggingWipe) return;
      draggingWipe = false;
      updateHash();
    };
    stage.addEventListener("pointerup", finishWipeDrag);
    stage.addEventListener("pointercancel", finishWipeDrag);

    window.addEventListener("resize", () => {
      if (state.zoom === "fit") setFit();
    });
    stage.querySelectorAll("img").forEach((image) => {
      if (!image.complete) {
        image.addEventListener("load", () => {
          if (state.zoom === "fit") setFit();
        }, { once: true });
      }
    });
    reduceMotionQuery.addEventListener?.("change", () => {
      if (reduceMotionQuery.matches) {
        state.motionOverride = false;
        stopBlink();
      }
      if (state.mode === "blink") render(false);
    });

    window.addEventListener("beforeprint", () => {
      stopBlink();
      state.showingAfter = comparison.dataset.poster === "after";
      render(false);
    });
    render(false);
  });
})();
"""#
}

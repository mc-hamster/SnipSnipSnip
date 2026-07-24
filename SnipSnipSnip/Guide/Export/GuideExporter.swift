import AppKit
import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

nonisolated enum GuideExportError: LocalizedError {
    case noSteps
    case sourceVideoUnavailable
    case renderingFailed
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSteps: "The Guide has no included steps to export."
        case .sourceVideoUnavailable: "This Guide has no source video. Full Motion and Action Highlights are unavailable, but slideshow MP4 remains available."
        case .renderingFailed: "A Guide step could not be rendered."
        case .writerFailed(let reason): "The Guide export failed: \(reason)"
        }
    }
}

nonisolated struct GuideExportResult: Sendable {
    var outputs: [URL]
    var failures: [GuideExportFormat: String]
}

nonisolated enum GuideExportProgressPhase: String, Sendable {
    case preparing
    case renderingSteps
    case encoding
    case packaging
    case finalizing
}

nonisolated struct GuideExportProgressUpdate: Sendable, Equatable {
    var format: GuideExportFormat
    var phase: GuideExportProgressPhase
    var detail: String
    var completedUnits: Int64
    var totalUnits: Int64?
    var overallFraction: Double?
}

typealias GuideExportProgressHandler = @Sendable (GuideExportProgressUpdate) -> Void

nonisolated private final class GuideFormatProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatIndex: Int
    private let formatCount: Int
    private let handler: GuideExportProgressHandler?
    private var lastLocalFraction: Double = 0

    init(formatIndex: Int, formatCount: Int, handler: GuideExportProgressHandler?) {
        self.formatIndex = formatIndex
        self.formatCount = max(formatCount, 1)
        self.handler = handler
    }

    func report(_ update: GuideExportProgressUpdate) {
        guard let handler else { return }
        lock.lock()
        var delivered = update
        if let fraction = update.overallFraction {
            lastLocalFraction = max(lastLocalFraction, min(max(fraction, 0), 1))
            delivered.overallFraction = (Double(formatIndex) + lastLocalFraction) / Double(formatCount)
        } else {
            delivered.overallFraction = nil
        }
        lock.unlock()
        handler(delivered)
    }
}

nonisolated enum GuideVideoTrackGeometry {
    static func orientedGeometry(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> (renderSize: CGSize, layerTransform: CGAffineTransform)? {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return nil }
        let transformed = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        guard transformed.width > 0, transformed.height > 0 else { return nil }
        let normalized = preferredTransform.concatenating(
            CGAffineTransform(translationX: -transformed.minX, y: -transformed.minY)
        )
        return (transformed.size, normalized)
    }

    static func fittedGeometry(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> (layerTransform: CGAffineTransform, contentRect: CGRect)? {
        guard let oriented = orientedGeometry(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        ), renderSize.width > 0, renderSize.height > 0 else { return nil }
        let scale = min(
            renderSize.width / oriented.renderSize.width,
            renderSize.height / oriented.renderSize.height
        )
        guard scale.isFinite, scale > 0 else { return nil }
        let size = CGSize(
            width: oriented.renderSize.width * scale,
            height: oriented.renderSize.height * scale
        )
        let origin = CGPoint(
            x: (renderSize.width - size.width) / 2,
            y: (renderSize.height - size.height) / 2
        )
        let transform = oriented.layerTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
        return (transform, CGRect(origin: origin, size: size))
    }
}

// AVFoundation documents `cancelExport()` as the cross-thread cancellation
// mechanism. This wrapper confines that one intentional handoff.
nonisolated private final class GuideExportSessionCancellation: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

nonisolated enum GuideExporter {
    /// Word constrains a guide card to roughly six printed inches. Rendering at
    /// this width preserves approximately 300 dpi for the actual screenshot
    /// area after the card's caption and side margins are applied.
    private static let documentCardWidth = 2_000

    static func exportAll(
        document: EditableGuideDocument,
        formats: Set<GuideExportFormat>,
        directory: URL,
        progress: GuideExportProgressHandler? = nil
    ) async -> GuideExportResult {
        var outputs: [URL] = []
        var failures: [GuideExportFormat: String] = [:]
        let orderedFormats = formats.sorted(by: { $0.rawValue < $1.rawValue })
        for (index, format) in orderedFormats.enumerated() {
            if Task.isCancelled { break }
            let reporter = GuideFormatProgressReporter(
                formatIndex: index,
                formatCount: orderedFormats.count,
                handler: progress
            )
            reporter.report(GuideExportProgressUpdate(
                format: format,
                phase: .preparing,
                detail: "Preparing \(format.label)…",
                completedUnits: 0,
                totalUnits: nil,
                overallFraction: nil
            ))
            var succeeded = false
            do {
                let url = try await export(
                    document: document,
                    format: format,
                    directory: directory,
                    progress: reporter.report
                )
                outputs.append(url)
                succeeded = true
            } catch is CancellationError {
                break
            } catch {
                failures[format] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            if succeeded {
                reporter.report(GuideExportProgressUpdate(
                    format: format,
                    phase: .finalizing,
                    detail: "Finished \(format.label).",
                    completedUnits: 1,
                    totalUnits: 1,
                    overallFraction: 1
                ))
            } else if let reason = failures[format] {
                reporter.report(GuideExportProgressUpdate(
                    format: format,
                    phase: .finalizing,
                    detail: "\(format.label) failed: \(reason)",
                    completedUnits: 0,
                    totalUnits: nil,
                    overallFraction: nil
                ))
            }
        }
        return GuideExportResult(outputs: outputs, failures: failures)
    }

    static func export(
        document: EditableGuideDocument,
        format: GuideExportFormat,
        directory: URL,
        progress: GuideExportProgressHandler? = nil
    ) async throws -> URL {
        try Task.checkCancellation()
        let steps = GuideStepNumbering.exportSteps(from: document.project.steps)
        guard !steps.isEmpty else { throw GuideExportError.noSteps }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try GuideStorageGuardrails.ensureCanExport(
            document: document,
            format: format,
            directory: directory
        )
        cleanupStaleTemporaryArtifacts()
        let basename = filenameBase(project: document.project, format: format)
        switch format {
        case .pdf:
            let url = fileURL(in: directory, basename: basename, extension: "pdf")
            try writePDF(steps: steps, document: document, to: url, progress: progress)
            return url
        case .docx:
            let url = fileURL(in: directory, basename: basename, extension: "docx")
            try writeDOCX(steps: steps, document: document, to: url, progress: progress)
            return url
        case .gif, .apng:
            let ext = format == .gif ? "gif" : "png"
            let url = fileURL(in: directory, basename: basename, extension: ext)
            try writeAnimated(steps: steps, document: document, format: format, to: url, progress: progress)
            return url
        case .stepImages:
            let url = directory.appendingPathComponent(basename, isDirectory: true)
            try writeStepImages(steps: steps, document: document, to: url, progress: progress)
            return url
        case .slideshowMP4:
            let url = fileURL(in: directory, basename: basename, extension: "mp4")
            try await writeSlideshow(steps: steps, document: document, to: url, progress: progress)
            return url
        case .fullMotionMP4:
            let url = fileURL(in: directory, basename: basename, extension: "mp4")
            try await writeMediaTimeline(document: document, highlightsOnly: false, format: format, to: url, progress: progress)
            return url
        case .highlightMP4:
            let url = fileURL(in: directory, basename: basename, extension: "mp4")
            try await writeMediaTimeline(document: document, highlightsOnly: true, format: format, to: url, progress: progress)
            return url
        case .zip:
            let url = fileURL(in: directory, basename: basename, extension: "zip")
            try await writeZIP(steps: steps, document: document, to: url, progress: progress)
            return url
        }
    }

    private static func renderedCard(
        step: GuideStep,
        document: EditableGuideDocument,
        cardWidth: Int = 1_440
    ) throws -> CGImage {
        try Task.checkCancellation()
        guard let image = document.stepImages[step.id],
              let card = GuideRenderer.renderStepCard(
                step: step,
                image: image,
                theme: document.project.theme,
                cardWidth: cardWidth,
                advancedEdit: document.advancedEdits[step.id],
                logo: document.logoImage
              ) else {
            throw GuideExportError.renderingFailed
        }
        return card
    }

    private static func writePDF(
        steps: [GuideStep],
        document: EditableGuideDocument,
        to destination: URL,
        progress: GuideExportProgressHandler?
    ) throws {
        try atomicFile(destination) { url in
            let settings = document.project.exportSettings
            let usesA4 = settings.pdfPaper == .a4 || (settings.pdfPaper == .automatic && Locale.current.measurementSystem == .metric)
            var mediaBox = usesA4 ? CGRect(x: 0, y: 0, width: 595, height: 842) : CGRect(x: 0, y: 0, width: 612, height: 792)
            if settings.pdfOrientation == .landscape { mediaBox.size = CGSize(width: mediaBox.height, height: mediaBox.width) }
            guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw GuideExportError.renderingFailed }
            if document.project.exportSettings.includesCoverWhenTitled,
               !document.project.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                context.beginPDFPage(nil)
                drawPDFText(document.project.title, in: mediaBox.insetBy(dx: 56, dy: 72), size: 38, context: context, invisible: false)
                context.endPDFPage()
            }
            let cardWidth = Int(1_440 * Double(min(max(settings.pdfDPI, 144), 300)) / 216.0)
            let groupSize = document.project.exportSettings.usesCompactPDFLayout ? 2 : 1
            var completedSteps = 0
            for start in stride(from: 0, to: steps.count, by: groupSize) {
                try Task.checkCancellation()
                let group = Array(steps[start..<min(start + groupSize, steps.count)])
                context.beginPDFPage(nil)
                let margin = min(max(document.project.theme.pageMargin, 18), min(mediaBox.width, mediaBox.height) / 3)
                let pageInset = mediaBox.insetBy(dx: margin, dy: margin)
                let slotHeight = pageInset.height / CGFloat(group.count)
                for (index, step) in group.enumerated() {
                    try Task.checkCancellation()
                    let slot = CGRect(x: pageInset.minX, y: pageInset.maxY - CGFloat(index + 1) * slotHeight, width: pageInset.width, height: slotHeight).insetBy(dx: 0, dy: group.count == 1 ? 0 : 12)
                    let image = try renderedCard(step: step, document: document, cardWidth: cardWidth)
                    let scale = min(slot.width / CGFloat(image.width), slot.height / CGFloat(image.height))
                    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    context.draw(image, in: CGRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2, width: size.width, height: size.height))
                    // Preserve the polished raster card while also embedding selectable/searchable caption text.
                    drawPDFText("\(step.sequence). \(step.caption)", in: slot, size: 12, context: context, invisible: true)
                }
                context.endPDFPage()
                completedSteps += group.count
                reportStepProgress(
                    format: .pdf,
                    completed: completedSteps,
                    total: steps.count,
                    progress: progress
                )
            }
            context.closePDF()
        }
    }

    /// Builds a portable Office Open XML package directly so Word export works in
    /// the sandbox without requiring a local Word or Python installation.
    private static func writeDOCX(
        steps: [GuideStep],
        document: EditableGuideDocument,
        to destination: URL,
        progress: GuideExportProgressHandler?
    ) throws {
        try atomicFile(destination) { url in
            let writer = try GuideZIPWriter.Stream(url: url)
            do {
                try writer.add(name: "[Content_Types].xml", data: Data(docxContentTypes.utf8))
                try writer.add(name: "_rels/.rels", data: Data(docxRootRelationships.utf8))
                var relationships = """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                """
                var imageSizes: [CGSize] = []
                imageSizes.reserveCapacity(steps.count)
                for (index, step) in steps.enumerated() {
                    try Task.checkCancellation()
                    let card = try renderedCard(step: step, document: document, cardWidth: documentCardWidth)
                    imageSizes.append(CGSize(width: card.width, height: card.height))
                    try writer.add(name: "word/media/step-\(index + 1).png", data: ImageExporter.pngData(for: card))
                    relationships += "<Relationship Id=\"rId\(index + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/step-\(index + 1).png\"/>"
                    reportStepProgress(
                        format: .docx,
                        completed: index + 1,
                        total: steps.count,
                        progress: progress
                    )
                }
                relationships += "</Relationships>"
                try writer.add(name: "word/_rels/document.xml.rels", data: Data(relationships.utf8))
                try writer.add(
                    name: "word/document.xml",
                    data: Data(docxDocumentXML(title: document.project.title, imageSizes: imageSizes).utf8)
                )
                try writer.finish()
            } catch {
                writer.cancel()
                throw error
            }
        }
    }

    private static let docxContentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Default Extension="png" ContentType="image/png"/>
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    private static let docxRootRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static func docxDocumentXML(title: String, imageSizes: [CGSize]) -> String {
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Guide" : title
        var body = docxParagraph(heading, size: 36, bold: true, centered: true)
        for (index, size) in imageSizes.enumerated() {
            if index > 0 { body += "<w:p><w:pPr><w:pageBreakBefore/></w:pPr></w:p>" }
            // A rendered card already includes the step number, caption, and
            // optional note. Adding them as document paragraphs duplicates the
            // visible instruction in Word and Pages.
            body += docxImage(index: index + 1, size: size)
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
          <w:body>
            \(body)
            <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>
          </w:body>
        </w:document>
        """
    }

    private static func docxParagraph(_ text: String, size: Int, bold: Bool = false, centered: Bool = false) -> String {
        let alignment = centered ? "<w:jc w:val=\"center\"/>" : ""
        let weight = bold ? "<w:b/>" : ""
        return "<w:p><w:pPr>\(alignment)<w:spacing w:after=\"160\"/></w:pPr><w:r><w:rPr>\(weight)<w:sz w:val=\"\(size)\"/></w:rPr><w:t xml:space=\"preserve\">\(docxEscapedText(text))</w:t></w:r></w:p>"
    }

    private static func docxImage(index: Int, size: CGSize) -> String {
        let maximumWidth: Double = 5_700_000
        let maximumHeight: Double = 6_300_000
        // DrawingML measures images in EMUs. Screenshots are treated as 96-DPI
        // images, then constrained to the printable page area.
        let emusPerPixel: Double = 9_525
        let naturalWidth = Double(size.width) * emusPerPixel
        let naturalHeight = Double(size.height) * emusPerPixel
        let scale = min(maximumWidth / naturalWidth, maximumHeight / naturalHeight, 1)
        let width = max(1, Int(naturalWidth * scale))
        let height = max(1, Int(naturalHeight * scale))
        return """
        <w:p><w:pPr><w:jc w:val="center"/><w:spacing w:after="200"/></w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(width)" cy="\(height)"/><wp:docPr id="\(index)" name="Guide step \(index)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="Guide step \(index).png"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rId\(index)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """
    }

    private static func docxEscapedText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func drawPDFText(_ text: String, in rect: CGRect, size: CGFloat, context: CGContext, invisible: Bool) {
        context.saveGState()
        context.setTextDrawingMode(invisible ? .invisible : .fill)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil),
            .foregroundColor: CGColor(gray: 0.08, alpha: 1)
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private static func writeAnimated(
        steps: [GuideStep],
        document: EditableGuideDocument,
        format: GuideExportFormat,
        to destination: URL,
        progress: GuideExportProgressHandler?
    ) throws {
        try atomicFile(destination) { url in
            let type = format == .gif ? UTType.gif.identifier : UTType.png.identifier
            let transitionCount = document.project.exportSettings.usesCrossfade
                && document.project.exportSettings.crossfadeDuration > 0
                ? max(steps.count - 1, 0) * 2
                : 0
            guard let output = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, steps.count + transitionCount, nil) else { throw GuideExportError.renderingFailed }
            if format == .gif {
                CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            } else {
                CGImageDestinationSetProperties(output, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
            }
            var current = try renderedCard(step: steps[0], document: document)
            for index in steps.indices {
                try Task.checkCancellation()
                let duration = min(max(steps[index].duration, 0.5), 5)
                let next = index + 1 < steps.count
                    ? try renderedCard(step: steps[index + 1], document: document)
                    : nil
                let crossfade = document.project.exportSettings.usesCrossfade && next != nil
                    ? min(max(document.project.exportSettings.crossfadeDuration, 0), min(0.2, duration / 2))
                    : 0
                addAnimatedFrame(current, duration: duration - crossfade, format: format, to: output)
                if crossfade > 0, let next {
                    for frameIndex in 1...2 {
                        let fraction = CGFloat(frameIndex) / 3
                        addAnimatedFrame(
                            blend(current, next, fraction: fraction) ?? current,
                            duration: crossfade / 2,
                            format: format,
                            to: output
                        )
                    }
                }
                if let next { current = next }
                reportStepProgress(
                    format: format,
                    completed: index + 1,
                    total: steps.count,
                    progress: progress
                )
            }
            guard CGImageDestinationFinalize(output) else { throw GuideExportError.renderingFailed }
        }
    }

    private static func addAnimatedFrame(
        _ image: CGImage,
        duration: Double,
        format: GuideExportFormat,
        to output: CGImageDestination
    ) {
        let properties: CFDictionary = format == .gif
            ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: duration]] as CFDictionary
            : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: duration]] as CFDictionary
        CGImageDestinationAddImage(output, image, properties)
    }

    private static func blend(_ first: CGImage, _ second: CGImage, fraction: CGFloat) -> CGImage? {
        let width = max(first.width, second.width)
        let height = max(first.height, second.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(first, in: rect)
        context.setAlpha(fraction)
        context.draw(second, in: rect)
        return context.makeImage()
    }

    private static func writeStepImages(
        steps: [GuideStep],
        document: EditableGuideDocument,
        to destination: URL,
        progress: GuideExportProgressHandler?
    ) throws {
        cleanupInterruptedTemporaryFiles(for: destination)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            "\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        for (index, step) in steps.enumerated() {
            try Task.checkCancellation()
            let card = try renderedCard(step: step, document: document)
            let isJPEG = document.project.exportSettings.stepImageFormat == .jpeg
            let ext = isJPEG ? "jpg" : "png"
            let data = try isJPEG ? ImageExporter.jpegData(for: card) : ImageExporter.pngData(for: card)
            try data.write(to: temporary.appendingPathComponent(String(format: "%03d-%@.%@", index + 1, safeComponent(step.caption), ext)), options: .atomic)
            reportStepProgress(
                format: .stepImages,
                completed: index + 1,
                total: steps.count,
                progress: progress
            )
        }
        try replace(destination, with: temporary)
    }

    private static func writeSlideshow(
        steps: [GuideStep],
        document: EditableGuideDocument,
        to destination: URL,
        progress: GuideExportProgressHandler?
    ) async throws {
        let firstCard = try renderedCard(step: steps[0], document: document)
        try await atomicFileAsync(destination) { url in
            let width = 1440
            let height = firstCard.height
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            defer { if writer.status == .writing { writer.cancelWriting() } }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
            guard writer.canAdd(input) else { throw GuideExportError.renderingFailed }
            writer.add(input)
            guard writer.startWriting() else { throw GuideExportError.writerFailed(writer.error?.localizedDescription ?? "Could not start the video writer.") }
            writer.startSession(atSourceTime: .zero)
            var time = CMTime.zero
            var currentImage = firstCard
            for index in steps.indices {
                try Task.checkCancellation()
                let step = steps[index]
                let duration = max(step.duration, 0.05)
                try await waitUntilReady(input, writer: writer)
                guard let buffer = pixelBuffer(image: currentImage, width: width, height: height), adaptor.append(buffer, withPresentationTime: time) else {
                    throw GuideExportError.writerFailed(writer.error?.localizedDescription ?? "Could not write a slideshow frame.")
                }
                let nextImage = index + 1 < steps.count
                    ? try renderedCard(step: steps[index + 1], document: document)
                    : nil
                if document.project.exportSettings.usesCrossfade, let nextImage {
                    let fade = min(max(document.project.exportSettings.crossfadeDuration, 0), min(0.2, duration / 2))
                    for fadeIndex in 1...4 {
                        try Task.checkCancellation()
                        try await waitUntilReady(input, writer: writer)
                        let fraction = CGFloat(fadeIndex) / 5
                        guard let blended = blend(currentImage, nextImage, fraction: fraction),
                              let buffer = pixelBuffer(image: blended, width: width, height: height),
                              adaptor.append(buffer, withPresentationTime: CMTimeAdd(time, CMTime(seconds: duration - fade + fade * Double(fadeIndex) / 5, preferredTimescale: 600))) else {
                            throw GuideExportError.writerFailed(writer.error?.localizedDescription ?? "Could not write a slideshow transition.")
                        }
                    }
                }
                time = CMTimeAdd(time, CMTime(seconds: duration, preferredTimescale: 600))
                if let nextImage { currentImage = nextImage }
                reportStepProgress(
                    format: .slideshowMP4,
                    completed: index + 1,
                    total: steps.count,
                    progress: progress
                )
            }
            try await waitUntilReady(input, writer: writer)
            guard let finalBuffer = pixelBuffer(image: currentImage, width: width, height: height),
                  adaptor.append(finalBuffer, withPresentationTime: time) else {
                throw GuideExportError.writerFailed(writer.error?.localizedDescription ?? "Could not write the final slideshow frame.")
            }
            input.markAsFinished()
            progress?(GuideExportProgressUpdate(
                format: .slideshowMP4,
                phase: .finalizing,
                detail: "Finalizing slideshow video…",
                completedUnits: Int64(steps.count),
                totalUnits: Int64(steps.count),
                overallFraction: nil
            ))
            await writer.finishWriting()
            guard writer.status == .completed else { throw GuideExportError.writerFailed(writer.error?.localizedDescription ?? "Could not finish the slideshow.") }
        }
    }

    private static func reportStepProgress(
        format: GuideExportFormat,
        completed: Int,
        total: Int,
        progress: GuideExportProgressHandler?
    ) {
        let boundedTotal = max(total, 1)
        progress?(GuideExportProgressUpdate(
            format: format,
            phase: .renderingSteps,
            detail: "Rendering step \(completed) of \(total)…",
            completedUnits: Int64(completed),
            totalUnits: Int64(total),
            overallFraction: Double(completed) / Double(boundedTotal)
        ))
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            if writer.status == .failed || writer.status == .cancelled {
                throw GuideExportError.writerFailed(writer.error?.localizedDescription ?? "The media writer stopped before the export completed.")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func writeMediaTimeline(
        document: EditableGuideDocument,
        highlightsOnly: Bool,
        format: GuideExportFormat,
        to destination: URL,
        progress: GuideExportProgressHandler?
    ) async throws {
        guard !document.mediaSegmentURLs.isEmpty else { throw GuideExportError.sourceVideoUnavailable }
        do {
            try await atomicFileAsync(destination) { url in
            let composition = AVMutableComposition()
            guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw GuideExportError.renderingFailed }
            var audioTrack: AVMutableCompositionTrack?
            var insertion = CMTime.zero
            var placedClips: [PlacedGuideMediaClip] = []
            let clips = highlightsOnly ? highlightClips(document: document) : document.project.timeline.segments.map {
                GuideMediaClip(segment: $0, start: 0, duration: $0.duration)
            }
            for (clipIndex, clip) in clips.enumerated() {
                try Task.checkCancellation()
                guard let segmentURL = document.mediaSegmentURLs[clip.segment.id] else { continue }
                let asset = AVURLAsset(url: segmentURL)
                let duration = try await asset.load(.duration)
                let start = min(max(clip.start, 0), duration.seconds)
                let end = min(max(start + clip.duration, start), duration.seconds)
                let range = CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600)
                )
                guard range.duration > .zero else { continue }
                guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
                let naturalSize = try await sourceVideo.load(.naturalSize)
                let preferredTransform = try await sourceVideo.load(.preferredTransform)
                guard let oriented = GuideVideoTrackGeometry.orientedGeometry(
                    naturalSize: naturalSize,
                    preferredTransform: preferredTransform
                ) else { continue }
                try videoTrack.insertTimeRange(range, of: sourceVideo, at: insertion)
                if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                    if audioTrack == nil {
                        audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    try audioTrack?.insertTimeRange(range, of: sourceAudio, at: insertion)
                }
                placedClips.append(PlacedGuideMediaClip(
                    clip: clip,
                    outputStart: insertion.seconds,
                    naturalSize: naturalSize,
                    preferredTransform: preferredTransform,
                    orientedSize: oriented.renderSize
                ))
                insertion = CMTimeAdd(insertion, range.duration)
                let completed = clipIndex + 1
                progress?(GuideExportProgressUpdate(
                    format: format,
                    phase: .preparing,
                    detail: "Preparing video segment \(completed) of \(clips.count)…",
                    completedUnits: Int64(completed),
                    totalUnits: Int64(clips.count),
                    overallFraction: 0.4 * Double(completed) / Double(max(clips.count, 1))
                ))
            }
            let outputSize = commonVideoRenderSize(for: placedClips)
            guard !placedClips.isEmpty, outputSize.width > 0, outputSize.height > 0, insertion > .zero else {
                throw GuideExportError.sourceVideoUnavailable
            }
            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw GuideExportError.renderingFailed }
            guard session.supportedFileTypes.contains(.mp4) else { throw GuideExportError.renderingFailed }
            if let videoComposition = mediaVideoComposition(
                    track: videoTrack,
                    renderSize: outputSize,
                    duration: insertion.seconds,
                    placedClips: placedClips,
                    document: document
               ) {
                session.videoComposition = videoComposition
            }
            session.outputURL = url
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            do {
                let cancellation = GuideExportSessionCancellation(session)
                progress?(GuideExportProgressUpdate(
                    format: format,
                    phase: .encoding,
                    detail: "Finalizing video…",
                    completedUnits: Int64(placedClips.count),
                    totalUnits: Int64(clips.count),
                    overallFraction: nil
                ))
                try await withTaskCancellationHandler(
                    operation: { try await session.export(to: url, as: .mp4) },
                    onCancel: { cancellation.session.cancelExport() }
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let cocoaError = error as NSError
                let reason = cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSFileNoSuchFileError
                    ? "The media export stopped before producing output."
                    : error.localizedDescription
                throw GuideExportError.writerFailed(reason)
            }
            }
        } catch let error as GuideExportError {
            throw error
        } catch {
            throw GuideExportError.writerFailed(error.localizedDescription)
        }
    }

    private struct GuideMediaClip {
        var segment: GuideTimelineSegment
        var start: Double
        var duration: Double
    }

    private struct PlacedGuideMediaClip {
        var clip: GuideMediaClip
        var outputStart: Double
        var naturalSize: CGSize
        var preferredTransform: CGAffineTransform
        var orientedSize: CGSize
    }

    private static func commonVideoRenderSize(for clips: [PlacedGuideMediaClip]) -> CGSize {
        let width = clips.map(\.orientedSize.width).max() ?? 0
        let height = clips.map(\.orientedSize.height).max() ?? 0
        func evenDimension(_ value: CGFloat) -> CGFloat {
            let rounded = max(Int(value.rounded(.up)), 0)
            return CGFloat(rounded.isMultiple(of: 2) ? rounded : rounded + 1)
        }
        return CGSize(width: evenDimension(width), height: evenDimension(height))
    }

    private static func highlightClips(document: EditableGuideDocument) -> [GuideMediaClip] {
        var clips: [GuideMediaClip] = []
        for step in document.project.steps where step.isIncluded && !step.isDeleted {
            guard let segment = document.project.timeline.segments.first(where: {
                step.capturedAt >= $0.startedAt && step.capturedAt <= $0.startedAt.addingTimeInterval($0.duration)
            }) else { continue }
            let event = step.capturedAt.timeIntervalSince(segment.startedAt)
            let start = max(0, event - 0.75)
            let end = min(segment.duration, event + 1.25)
            if var previous = clips.last,
               previous.segment.id == segment.id,
               start - (previous.start + previous.duration) <= 0.4,
               start >= previous.start {
                previous.duration = max(previous.start + previous.duration, end) - previous.start
                clips[clips.count - 1] = previous
            } else {
                clips.append(GuideMediaClip(segment: segment, start: start, duration: max(0, end - start)))
            }
        }
        return clips
    }

    private static func mediaVideoComposition(
        track: AVCompositionTrack,
        renderSize: CGSize,
        duration: Double,
        placedClips: [PlacedGuideMediaClip],
        document: EditableGuideDocument
    ) -> AVVideoComposition? {
        guard renderSize.width > 0, renderSize.height > 0, duration > 0 else { return nil }
        var layerConfiguration = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        for placed in placedClips {
            guard let fitted = GuideVideoTrackGeometry.fittedGeometry(
                naturalSize: placed.naturalSize,
                preferredTransform: placed.preferredTransform,
                renderSize: renderSize
            ) else { continue }
            layerConfiguration.setTransform(
                fitted.layerTransform,
                at: CMTime(seconds: placed.outputStart, preferredTimescale: 600)
            )
        }
        let layerInstruction = AVVideoCompositionLayerInstruction(configuration: layerConfiguration)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [layerInstruction],
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: duration, preferredTimescale: 600)
            )
        ))

        func composition(animationTool: AVVideoCompositionCoreAnimationTool? = nil) -> AVVideoComposition {
            AVVideoComposition(configuration: .init(
                animationTool: animationTool,
                frameDuration: CMTime(value: 1, timescale: 30),
                instructions: [instruction],
                renderSize: renderSize
            ))
        }

        let parent = CALayer()
        let video = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        video.frame = parent.frame
        parent.addSublayer(video)

        let keyframes = cursorKeyframes(
            samples: document.project.timeline.cursorSamples,
            placedClips: placedClips,
            project: document.project,
            renderSize: renderSize,
            duration: duration
        )
        // Even without cursor samples, keep this composition so a rotated
        // source track receives its preferred transform.
        guard keyframes.count > 1 else { return composition() }
        for trailIndex in stride(from: 3, through: 1, by: -1) {
            let trail = CAShapeLayer()
            trail.path = CGPath(ellipseIn: CGRect(x: -5, y: -5, width: 10, height: 10), transform: nil)
            trail.fillColor = CGColor(red: 0.95, green: 0.15, blue: 0.12, alpha: 0.16 * CGFloat(4 - trailIndex))
            trail.add(positionAnimation(keyframes: keyframes, duration: duration, delay: Double(trailIndex) * 0.035), forKey: "guideCursorTrail")
            parent.addSublayer(trail)
        }
        let cursor = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 24))
        path.addLine(to: CGPoint(x: 6, y: 18))
        path.addLine(to: CGPoint(x: 11, y: 30))
        path.addLine(to: CGPoint(x: 16, y: 28))
        path.addLine(to: CGPoint(x: 11, y: 16))
        path.addLine(to: CGPoint(x: 20, y: 16))
        path.closeSubpath()
        cursor.path = path
        cursor.fillColor = CGColor(gray: 1, alpha: 1)
        cursor.strokeColor = CGColor(gray: 0, alpha: 0.9)
        cursor.lineWidth = 2
        cursor.shadowColor = CGColor(gray: 0, alpha: 0.8)
        cursor.shadowOpacity = 0.45
        cursor.shadowRadius = 2
        cursor.add(positionAnimation(keyframes: keyframes, duration: duration), forKey: "guideCursor")
        parent.addSublayer(cursor)

        if document.project.theme.showsClickHighlight {
            for time in eventOutputTimes(placedClips: placedClips, project: document.project) where time < duration {
                guard let nearest = keyframes.min(by: { abs($0.time - time) < abs($1.time - time) }) else { continue }
                let ring = CAShapeLayer()
                ring.path = CGPath(ellipseIn: CGRect(x: -22, y: -22, width: 44, height: 44), transform: nil)
                ring.position = nearest.point
                ring.fillColor = CGColor(red: 0.9, green: 0.12, blue: 0.1, alpha: 0.18)
                ring.strokeColor = CGColor(red: 0.9, green: 0.12, blue: 0.1, alpha: 0.8)
                ring.lineWidth = 3
                ring.opacity = 0
                ring.add(clickHighlightOpacityAnimation(eventTime: time), forKey: "guideClick")
                parent.addSublayer(ring)
            }
        }
        let animationTool = AVVideoCompositionCoreAnimationTool(configuration: .init(
            postProcessingAsVideoLayer: video,
            containingLayer: parent
        ))
        return composition(animationTool: animationTool)
    }

    private struct CursorKeyframe {
        var time: Double
        var point: CGPoint
    }

    private static func cursorKeyframes(
        samples: [GuideCursorSample],
        placedClips: [PlacedGuideMediaClip],
        project: GuideProject,
        renderSize: CGSize,
        duration: Double
    ) -> [CursorKeyframe] {
        var result: [CursorKeyframe] = []
        for placed in placedClips {
            guard let fitted = GuideVideoTrackGeometry.fittedGeometry(
                naturalSize: placed.naturalSize,
                preferredTransform: placed.preferredTransform,
                renderSize: renderSize
            ) else { continue }
            let crop = placed.clip.segment.sourceCoordinateRect
                ?? project.timeline.sourceCoordinateRect
                ?? guideMediaCropRect(project.source)
            guard crop.width > 0, crop.height > 0 else { continue }
            let segmentStart = placed.clip.segment.startedAt.timeIntervalSince(project.createdAt)
            let clipStart = segmentStart + placed.clip.start
            let clipEnd = clipStart + placed.clip.duration
            for sample in samples where sample.timestampSeconds >= clipStart && sample.timestampSeconds <= clipEnd {
                guard let point = GuideMediaCursorGeometry.renderPoint(
                    fromCaptureGlobalPoint: sample.point,
                    cropRect: crop,
                    renderSize: fitted.contentRect.size,
                    coordinateContract: project.resolvedCoordinateContract
                ) else { continue }
                result.append(CursorKeyframe(
                    time: min(max(placed.outputStart + sample.timestampSeconds - clipStart, 0), duration),
                    point: CGPoint(
                        x: fitted.contentRect.minX + point.x,
                        y: fitted.contentRect.minY + point.y
                    )
                ))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    private static func positionAnimation(keyframes: [CursorKeyframe], duration: Double, delay: Double = 0) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "position")
        animation.values = keyframes.map { NSValue(point: $0.point) }
        animation.keyTimes = keyframes.map { NSNumber(value: min(max(($0.time + delay) / duration, 0), 1)) }
        animation.duration = duration
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.calculationMode = .linear
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        return animation
    }

    static func clickHighlightOpacityAnimation(eventTime: Double) -> CAKeyframeAnimation {
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 0]
        opacity.keyTimes = [0, 0.15, 1]
        opacity.beginTime = AVCoreAnimationBeginTimeAtZero + eventTime
        opacity.duration = 0.45
        opacity.isRemovedOnCompletion = false
        opacity.fillMode = .both
        return opacity
    }

    private static func eventOutputTimes(placedClips: [PlacedGuideMediaClip], project: GuideProject) -> [Double] {
        project.steps.filter {
            $0.isIncluded && !$0.isDeleted && ($0.eventKind == .click || $0.eventKind == .doubleClick)
        }.compactMap { step in
            placedClips.compactMap { placed -> Double? in
                let start = placed.clip.segment.startedAt.addingTimeInterval(placed.clip.start)
                let end = start.addingTimeInterval(placed.clip.duration)
                guard step.capturedAt >= start, step.capturedAt <= end else { return nil }
                return placed.outputStart + step.capturedAt.timeIntervalSince(start)
            }.first
        }
    }

    private static func guideMediaCropRect(_ source: GuideCaptureSource) -> CGRect {
        switch source {
        case .window(_, _, _, let frame), .app(_, _, _, let frame):
            return frame.insetBy(dx: -frame.width * 0.12, dy: -frame.height * 0.12)
        case .region(let rect): return rect
        case .displays:
            let ids: [CGDirectDisplayID]
            switch source {
            case .displays(.selected(let selected)): ids = selected
            default: ids = []
            }
            if let first = ids.first { return CGDisplayBounds(first) }
            return NSScreen.main?.frame ?? .zero
        }
    }

    private static func writeZIP(
        steps: [GuideStep],
        document: EditableGuideDocument,
        to destination: URL,
        progress: GuideExportProgressHandler?
    ) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("GuideZIPExports-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        var nestedExports: [URL] = []
        let nestedFormats = document.project.exportSettings.formats
            .filter { $0 != .zip && $0 != .stepImages }
            .sorted { $0.rawValue < $1.rawValue }
        for (index, format) in nestedFormats.enumerated() {
            try Task.checkCancellation()
            progress?(GuideExportProgressUpdate(
                format: .zip,
                phase: .preparing,
                detail: "Creating \(format.label) for the ZIP…",
                completedUnits: Int64(index),
                totalUnits: Int64(nestedFormats.count),
                overallFraction: nestedFormats.isEmpty ? 0.2 : 0.2 * Double(index) / Double(nestedFormats.count)
            ))
            do {
                let url = try await export(document: document, format: format, directory: temporary)
                guard !url.hasDirectoryPath else {
                    throw GuideExportError.writerFailed("\(format.label) produced an unexpected directory.")
                }
                nestedExports.append(url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                throw GuideExportError.writerFailed("ZIP could not include \(format.label): \(reason)")
            }
        }

        let sourceMedia: [(index: Int, url: URL)]
        if document.project.exportSettings.includesSourceMediaInZIP {
            sourceMedia = try document.project.timeline.segments.enumerated().map { index, segment in
                guard let url = document.mediaSegmentURLs[segment.id],
                      FileManager.default.fileExists(atPath: url.path) else {
                    throw GuideExportError.writerFailed(
                        "ZIP could not include source media segment \(index + 1) because its file is unavailable."
                    )
                }
                return (index, url)
            }
        } else {
            sourceMedia = []
        }

        try atomicFile(destination) { url in
            let writer = try GuideZIPWriter.Stream(url: url)
            do {
                let totalEntries = max(steps.count + nestedExports.count + sourceMedia.count + 1, 1)
                var completedEntries = 0
                func reportEntry(_ detail: String, partial: Double = 0) {
                    let packagingFraction = (Double(completedEntries) + min(max(partial, 0), 1)) / Double(totalEntries)
                    progress?(GuideExportProgressUpdate(
                        format: .zip,
                        phase: .packaging,
                        detail: detail,
                        completedUnits: Int64(completedEntries),
                        totalUnits: Int64(totalEntries),
                        overallFraction: 0.2 + (0.8 * packagingFraction)
                    ))
                }
                var markdown = "# \(document.project.title.isEmpty ? "Guide" : document.project.title)\n\n"
                for (index, step) in steps.enumerated() {
                    let name = String(format: "steps/%03d.png", index + 1)
                    let card = try renderedCard(step: step, document: document)
                    try writer.add(name: name, data: ImageExporter.pngData(for: card))
                    completedEntries += 1
                    reportEntry("Packaging step \(index + 1) of \(steps.count)…")
                    markdown += "## \(index + 1). \(step.caption)\n\n![Step \(index + 1)](\(name))\n\n\(step.note)\n\n"
                }
                try writer.add(name: "Guide.md", data: Data(markdown.utf8))
                completedEntries += 1
                reportEntry("Packaging Guide instructions…")
                for nested in nestedExports {
                    try writer.addFile(name: "exports/\(nested.lastPathComponent)", url: nested) { written, total in
                        let partial = total > 0 ? Double(written) / Double(total) : 0
                        reportEntry("Packaging \(nested.lastPathComponent)…", partial: partial)
                    }
                    completedEntries += 1
                    reportEntry("Packaged \(nested.lastPathComponent).")
                }
                for entry in sourceMedia {
                    try Task.checkCancellation()
                    try writer.addFile(name: String(format: "source-media/%03d.mp4", entry.index + 1), url: entry.url) { written, total in
                        let partial = total > 0 ? Double(written) / Double(total) : 0
                        reportEntry("Packaging source video \(entry.index + 1)…", partial: partial)
                    }
                    completedEntries += 1
                    reportEntry("Packaged source video \(entry.index + 1).")
                }
                try writer.finish()
            } catch {
                writer.cancel()
                throw error
            }
        }
    }

    private static func pixelBuffer(image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2, width: size.width, height: size.height))
        return buffer
    }

    private static func filenameBase(project: GuideProject, format: GuideExportFormat) -> String {
        let title = project.title.isEmpty ? "Untitled" : safeComponent(project.title)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        var value = project.exportSettings.filenameTemplate
        value = value.replacingOccurrences(of: "{title}", with: title)
        value = value.replacingOccurrences(of: "{guide}", with: "Guide")
        value = value.replacingOccurrences(of: "{steps}", with: String(project.steps.filter { $0.isIncluded && !$0.isDeleted }.count))
        value = value.replacingOccurrences(of: "{export}", with: format.rawValue)
        value = value.replacingOccurrences(of: "{yyyy-MM-dd-HH-mm-ss}", with: formatter.string(from: Date()))
        let cleaned = value.replacingOccurrences(of: "[^A-Za-z0-9_.-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let base = cleaned.isEmpty ? "SnipSnipSnip-Guide-\(formatter.string(from: Date()))" : cleaned
        if !project.exportSettings.filenameTemplate.contains("{export}"), [.fullMotionMP4, .highlightMP4, .slideshowMP4].contains(format) {
            return base + "-" + format.rawValue
        }
        return base
    }
    private static func safeComponent(_ value: String) -> String { String(value.prefix(48)).replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
    private static func fileURL(in directory: URL, basename: String, extension pathExtension: String) -> URL {
        directory.appendingPathComponent("\(basename).\(pathExtension)", isDirectory: false)
    }
    private static func temporaryFileURL(for destination: URL) -> URL {
        let pathExtension = destination.pathExtension
        let stem = destination.deletingPathExtension().lastPathComponent
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        return destination.deletingLastPathComponent()
            // AVAssetExportSession rejects hidden output names even when the
            // extension identifies a supported media container.
            .appendingPathComponent("\(stem).\(UUID().uuidString).tmp\(suffix)", isDirectory: false)
    }
    private static func atomicFile(_ destination: URL, writer: (URL) throws -> Void) throws {
        cleanupInterruptedTemporaryFiles(for: destination)
        let temp = temporaryFileURL(for: destination)
        defer { try? FileManager.default.removeItem(at: temp) }
        try writer(temp); try replace(destination, with: temp)
    }
    private static func atomicFileAsync(_ destination: URL, writer: (URL) async throws -> Void) async throws {
        cleanupInterruptedTemporaryFiles(for: destination)
        let temp = temporaryFileURL(for: destination)
        defer { try? FileManager.default.removeItem(at: temp) }
        try await writer(temp)
        guard FileManager.default.fileExists(atPath: temp.path) else {
            throw GuideExportError.writerFailed("The media encoder did not produce an output file.")
        }
        do {
            try replace(destination, with: temp)
        } catch {
            throw GuideExportError.writerFailed(
                "Could not finalize the temporary export (destination exists: \(FileManager.default.fileExists(atPath: destination.path))). \(error.localizedDescription)"
            )
        }
    }
    private static func replace(_ destination: URL, with temporary: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: destination) }
    }

    private static func cleanupInterruptedTemporaryFiles(for destination: URL) {
        let directory = destination.deletingLastPathComponent()
        let stem = destination.deletingPathExtension().lastPathComponent + "."
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.lastPathComponent.hasPrefix(stem) && url.lastPathComponent.contains(".tmp") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func cleanupStaleTemporaryArtifacts() {
        let directory = FileManager.default.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.lastPathComponent.hasPrefix("GuideImages-") || url.lastPathComponent.hasPrefix("GuideZIPExports-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }
}

nonisolated enum GuideZIPWriter {
    static func write(entries: [(String, Data)], to url: URL) throws {
        let writer = try Stream(url: url)
        do {
            for (name, data) in entries { try writer.add(name: name, data: data) }
            try writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
    }

    final class Stream {
        private struct Record {
            var name: Data
            var crc: UInt32
            var size: UInt64
            var offset: UInt64
            var flags: UInt16
        }

        private let handle: FileHandle
        private let url: URL
        private var records: [Record] = []
        private var offset: UInt64 = 0
        private var isFinished = false

        init(url: URL) throws {
            self.url = url
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        }

        deinit { try? handle.close() }

        func add(name: String, data: Data) throws {
            try Task.checkCancellation()
            let nameData = Data(name.utf8)
            guard nameData.count <= Int(UInt16.max) else { throw GuideExportError.writerFailed("A ZIP entry name was too long.") }
            let crc = try GuideZIPWriter.crc32(data)
            let size = UInt64(data.count)
            let usesZIP64Size = size >= UInt64(UInt32.max)
            let extra = usesZIP64Size ? GuideZIPWriter.zip64Extra([size, size]) : Data()
            var local = Data()
            local.appendLE(UInt32(0x04034b50))
            local.appendLE(UInt16(usesZIP64Size ? 45 : 20))
            local.appendLE(UInt16(0))
            local.appendLE(UInt16(0))
            local.appendLE(UInt16(0)); local.appendLE(UInt16(0))
            local.appendLE(crc)
            local.appendLE(usesZIP64Size ? UInt32.max : UInt32(size))
            local.appendLE(usesZIP64Size ? UInt32.max : UInt32(size))
            local.appendLE(UInt16(nameData.count)); local.appendLE(UInt16(extra.count))
            local.append(nameData); local.append(extra)
            let localOffset = offset
            try handle.write(contentsOf: local)
            try handle.write(contentsOf: data)
            records.append(Record(name: nameData, crc: crc, size: size, offset: localOffset, flags: 0))
            offset += UInt64(local.count + data.count)
        }

        func addFile(
            name: String,
            url: URL,
            progress: ((UInt64, UInt64) -> Void)? = nil
        ) throws {
            try Task.checkCancellation()
            let source = try FileHandle(forReadingFrom: url)
            defer { try? source.close() }
            let size64 = try source.seekToEnd()
            try source.seek(toOffset: 0)
            let nameData = Data(name.utf8)
            guard nameData.count <= Int(UInt16.max) else {
                throw GuideExportError.writerFailed("A ZIP entry name was too long.")
            }
            let usesZIP64Size = size64 >= UInt64(UInt32.max)
            let extra = usesZIP64Size ? GuideZIPWriter.zip64Extra([size64, size64]) : Data()
            var local = Data()
            local.appendLE(UInt32(0x04034b50))
            local.appendLE(UInt16(usesZIP64Size ? 45 : 20))
            local.appendLE(UInt16(0x0008)) // CRC and sizes follow the streamed payload.
            local.appendLE(UInt16(0))
            local.appendLE(UInt16(0)); local.appendLE(UInt16(0))
            local.appendLE(UInt32(0))
            local.appendLE(usesZIP64Size ? UInt32.max : UInt32(0))
            local.appendLE(usesZIP64Size ? UInt32.max : UInt32(0))
            local.appendLE(UInt16(nameData.count)); local.appendLE(UInt16(extra.count))
            local.append(nameData); local.append(extra)
            let localOffset = offset
            try handle.write(contentsOf: local)
            var crcState: UInt32 = 0xffffffff
            var bytesWritten: UInt64 = 0
            while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                crcState = try GuideZIPWriter.updateCRC32(crcState, with: chunk)
                try handle.write(contentsOf: chunk)
                bytesWritten += UInt64(chunk.count)
                progress?(bytesWritten, size64)
            }
            let crc = crcState ^ 0xffffffff
            var descriptor = Data()
            descriptor.appendLE(UInt32(0x08074b50))
            descriptor.appendLE(crc)
            if usesZIP64Size {
                descriptor.appendLE(size64); descriptor.appendLE(size64)
            } else {
                descriptor.appendLE(UInt32(size64)); descriptor.appendLE(UInt32(size64))
            }
            try handle.write(contentsOf: descriptor)
            records.append(Record(name: nameData, crc: crc, size: size64, offset: localOffset, flags: 0x0008))
            offset += UInt64(local.count) + size64 + UInt64(descriptor.count)
        }

        func finish() throws {
            guard !isFinished else { return }
            try Task.checkCancellation()
            let centralOffset = offset
            var centralSize: UInt64 = 0
            var archiveNeedsZIP64 = false
            for record in records {
                try Task.checkCancellation()
                let sizeNeedsZIP64 = record.size >= UInt64(UInt32.max)
                let offsetNeedsZIP64 = record.offset >= UInt64(UInt32.max)
                var zip64Values: [UInt64] = []
                if sizeNeedsZIP64 { zip64Values.append(contentsOf: [record.size, record.size]) }
                if offsetNeedsZIP64 { zip64Values.append(record.offset) }
                let extra = GuideZIPWriter.zip64Extra(zip64Values)
                let needsZIP64 = !zip64Values.isEmpty
                archiveNeedsZIP64 = archiveNeedsZIP64 || needsZIP64
                var entry = Data()
                entry.appendLE(UInt32(0x02014b50))
                entry.appendLE(UInt16(needsZIP64 ? 45 : 20)); entry.appendLE(UInt16(needsZIP64 ? 45 : 20))
                entry.appendLE(record.flags); entry.appendLE(UInt16(0))
                entry.appendLE(UInt16(0)); entry.appendLE(UInt16(0))
                entry.appendLE(record.crc)
                entry.appendLE(sizeNeedsZIP64 ? UInt32.max : UInt32(record.size))
                entry.appendLE(sizeNeedsZIP64 ? UInt32.max : UInt32(record.size))
                entry.appendLE(UInt16(record.name.count)); entry.appendLE(UInt16(extra.count))
                entry.appendLE(UInt16(0)); entry.appendLE(UInt16(0)); entry.appendLE(UInt16(0)); entry.appendLE(UInt32(0))
                entry.appendLE(offsetNeedsZIP64 ? UInt32.max : UInt32(record.offset))
                entry.append(record.name); entry.append(extra)
                try handle.write(contentsOf: entry)
                centralSize += UInt64(entry.count)
            }
            let end = GuideZIPWriter.endRecords(
                recordCount: UInt64(records.count),
                centralSize: centralSize,
                centralOffset: centralOffset,
                forceZIP64: archiveNeedsZIP64
            )
            try handle.write(contentsOf: end)
            try handle.synchronize()
            try handle.close()
            isFinished = true
        }

        func cancel() {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            isFinished = true
        }
    }

    static func endRecords(
        recordCount: UInt64,
        centralSize: UInt64,
        centralOffset: UInt64,
        forceZIP64: Bool = false
    ) -> Data {
        let usesZIP64 = forceZIP64
            || recordCount >= UInt64(UInt16.max)
            || centralSize >= UInt64(UInt32.max)
            || centralOffset >= UInt64(UInt32.max)
        var result = Data()
        if usesZIP64 {
            let zip64EndOffset = centralOffset + centralSize
            result.appendLE(UInt32(0x06064b50))
            result.appendLE(UInt64(44))
            result.appendLE(UInt16(45)); result.appendLE(UInt16(45))
            result.appendLE(UInt32(0)); result.appendLE(UInt32(0))
            result.appendLE(recordCount); result.appendLE(recordCount)
            result.appendLE(centralSize); result.appendLE(centralOffset)
            result.appendLE(UInt32(0x07064b50))
            result.appendLE(UInt32(0)); result.appendLE(zip64EndOffset); result.appendLE(UInt32(1))
        }
        result.appendLE(UInt32(0x06054b50))
        result.appendLE(UInt16(0)); result.appendLE(UInt16(0))
        result.appendLE(usesZIP64 ? UInt16.max : UInt16(recordCount))
        result.appendLE(usesZIP64 ? UInt16.max : UInt16(recordCount))
        result.appendLE(usesZIP64 ? UInt32.max : UInt32(centralSize))
        result.appendLE(usesZIP64 ? UInt32.max : UInt32(centralOffset))
        result.appendLE(UInt16(0))
        return result
    }

    private static func zip64Extra(_ values: [UInt64]) -> Data {
        guard !values.isEmpty else { return Data() }
        var extra = Data()
        extra.appendLE(UInt16(0x0001))
        extra.appendLE(UInt16(values.count * MemoryLayout<UInt64>.size))
        values.forEach { extra.appendLE($0) }
        return extra
    }

    private static func crc32(_ data: Data) throws -> UInt32 {
        try updateCRC32(0xffffffff, with: data) ^ 0xffffffff
    }

    private static func updateCRC32(_ initial: UInt32, with data: Data) throws -> UInt32 {
        var crc = initial
        for (index, byte) in data.enumerated() {
            if index.isMultiple(of: 65_536) { try Task.checkCancellation() }
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb88320 & (0 &- (crc & 1))) }
        }
        return crc
    }
}

nonisolated private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
}

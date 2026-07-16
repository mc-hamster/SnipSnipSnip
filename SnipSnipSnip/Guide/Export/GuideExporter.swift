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
        progress: (@MainActor (GuideExportFormat, Double) -> Void)? = nil
    ) async -> GuideExportResult {
        var outputs: [URL] = []
        var failures: [GuideExportFormat: String] = [:]
        for (index, format) in formats.sorted(by: { $0.rawValue < $1.rawValue }).enumerated() {
            if Task.isCancelled { break }
            if let progress { await progress(format, Double(index) / Double(max(formats.count, 1))) }
            do {
                let url = try await export(document: document, format: format, directory: directory)
                outputs.append(url)
            } catch is CancellationError {
                break
            } catch {
                failures[format] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            if let progress { await progress(format, Double(index + 1) / Double(max(formats.count, 1))) }
        }
        return GuideExportResult(outputs: outputs, failures: failures)
    }

    static func export(document: EditableGuideDocument, format: GuideExportFormat, directory: URL) async throws -> URL {
        try Task.checkCancellation()
        let steps = document.project.steps.filter { $0.isIncluded && !$0.isDeleted }
        guard !steps.isEmpty else { throw GuideExportError.noSteps }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let basename = filenameBase(project: document.project, format: format)
        switch format {
        case .pdf:
            let url = fileURL(in: directory, basename: basename, extension: "pdf")
            try writePDF(steps: steps, document: document, to: url)
            return url
        case .docx:
            let url = fileURL(in: directory, basename: basename, extension: "docx")
            try writeDOCX(steps: steps, document: document, to: url)
            return url
        case .gif, .apng:
            let ext = format == .gif ? "gif" : "png"
            let url = fileURL(in: directory, basename: basename, extension: ext)
            try writeAnimated(steps: steps, document: document, format: format, to: url)
            return url
        case .stepImages:
            let url = directory.appendingPathComponent(basename, isDirectory: true)
            try writeStepImages(steps: steps, document: document, to: url)
            return url
        case .slideshowMP4:
            let url = fileURL(in: directory, basename: basename, extension: "mp4")
            try await writeSlideshow(steps: steps, document: document, to: url)
            return url
        case .fullMotionMP4:
            let url = fileURL(in: directory, basename: basename, extension: "mp4")
            try await writeMediaTimeline(document: document, highlightsOnly: false, to: url)
            return url
        case .highlightMP4:
            let url = fileURL(in: directory, basename: basename, extension: "mp4")
            try await writeMediaTimeline(document: document, highlightsOnly: true, to: url)
            return url
        case .zip:
            let url = fileURL(in: directory, basename: basename, extension: "zip")
            try await writeZIP(steps: steps, document: document, to: url)
            return url
        }
    }

    private static func renderedCards(steps: [GuideStep], document: EditableGuideDocument, cardWidth: Int = 1440) throws -> [(GuideStep, CGImage)] {
        var cards: [(GuideStep, CGImage)] = []
        cards.reserveCapacity(steps.count)
        for step in steps {
            try Task.checkCancellation()
            guard let image = document.stepImages[step.id],
                  let card = GuideRenderer.renderStepCard(step: step, image: image, theme: document.project.theme, cardWidth: cardWidth, advancedEdit: document.advancedEdits[step.id], logo: document.logoImage) else { throw GuideExportError.renderingFailed }
            cards.append((step, card))
        }
        return cards
    }

    private static func writePDF(steps: [GuideStep], document: EditableGuideDocument, to destination: URL) throws {
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
            let cards = try renderedCards(
                steps: steps,
                document: document,
                cardWidth: Int(1_440 * Double(min(max(settings.pdfDPI, 144), 300)) / 216.0)
            )
            let pageGroups = document.project.exportSettings.usesCompactPDFLayout
                ? stride(from: 0, to: cards.count, by: 2).map { Array(cards[$0..<min($0 + 2, cards.count)]) }
                : cards.map { [$0] }
            for group in pageGroups {
                try Task.checkCancellation()
                context.beginPDFPage(nil)
                let margin = min(max(document.project.theme.pageMargin, 18), min(mediaBox.width, mediaBox.height) / 3)
                let pageInset = mediaBox.insetBy(dx: margin, dy: margin)
                let slotHeight = pageInset.height / CGFloat(group.count)
                for (index, pair) in group.enumerated() {
                    try Task.checkCancellation()
                    let slot = CGRect(x: pageInset.minX, y: pageInset.maxY - CGFloat(index + 1) * slotHeight, width: pageInset.width, height: slotHeight).insetBy(dx: 0, dy: group.count == 1 ? 0 : 12)
                    let image = pair.1
                    let scale = min(slot.width / CGFloat(image.width), slot.height / CGFloat(image.height))
                    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    context.draw(image, in: CGRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2, width: size.width, height: size.height))
                    // Preserve the polished raster card while also embedding selectable/searchable caption text.
                    drawPDFText("\(pair.0.sequence). \(pair.0.caption)", in: slot, size: 12, context: context, invisible: true)
                }
                context.endPDFPage()
            }
            context.closePDF()
        }
    }

    /// Builds a portable Office Open XML package directly so Word export works in
    /// the sandbox without requiring a local Word or Python installation.
    private static func writeDOCX(steps: [GuideStep], document: EditableGuideDocument, to destination: URL) throws {
        let cards = try renderedCards(
            steps: steps,
            document: document,
            cardWidth: documentCardWidth
        )
        var entries: [(String, Data)] = [
            ("[Content_Types].xml", Data(docxContentTypes.utf8)),
            ("_rels/.rels", Data(docxRootRelationships.utf8))
        ]
        var relationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        """
        for (index, pair) in cards.enumerated() {
            try Task.checkCancellation()
            entries.append(("word/media/step-\(index + 1).png", try ImageExporter.pngData(for: pair.1)))
            relationships += "<Relationship Id=\"rId\(index + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/step-\(index + 1).png\"/>"
        }
        relationships += "</Relationships>"
        entries.append(("word/_rels/document.xml.rels", Data(relationships.utf8)))
        entries.append(("word/document.xml", Data(docxDocumentXML(title: document.project.title, cards: cards).utf8)))
        try atomicFile(destination) { url in try GuideZIPWriter.write(entries: entries, to: url) }
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

    private static func docxDocumentXML(title: String, cards: [(GuideStep, CGImage)]) -> String {
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Guide" : title
        var body = docxParagraph(heading, size: 36, bold: true, centered: true)
        for (index, pair) in cards.enumerated() {
            if index > 0 { body += "<w:p><w:pPr><w:pageBreakBefore/></w:pPr></w:p>" }
            // A rendered card already includes the step number, caption, and
            // optional note. Adding them as document paragraphs duplicates the
            // visible instruction in Word and Pages.
            body += docxImage(index: index + 1, image: pair.1)
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

    private static func docxImage(index: Int, image: CGImage) -> String {
        let maximumWidth: Double = 5_700_000
        let maximumHeight: Double = 6_300_000
        // DrawingML measures images in EMUs. Screenshots are treated as 96-DPI
        // images, then constrained to the printable page area.
        let emusPerPixel: Double = 9_525
        let naturalWidth = Double(image.width) * emusPerPixel
        let naturalHeight = Double(image.height) * emusPerPixel
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

    private static func writeAnimated(steps: [GuideStep], document: EditableGuideDocument, format: GuideExportFormat, to destination: URL) throws {
        let cards = try renderedCards(steps: steps, document: document)
        var frames: [(CGImage, Double)] = []
        for index in cards.indices {
            try Task.checkCancellation()
            let duration = min(max(cards[index].0.duration, 0.5), 5)
            let crossfade = document.project.exportSettings.usesCrossfade && index + 1 < cards.count
                ? min(max(document.project.exportSettings.crossfadeDuration, 0), min(0.2, duration / 2))
                : 0
            frames.append((cards[index].1, duration - crossfade))
            if crossfade > 0 {
                for frameIndex in 1...2 {
                    let fraction = CGFloat(frameIndex) / 3
                    frames.append((blend(cards[index].1, cards[index + 1].1, fraction: fraction) ?? cards[index].1, crossfade / 2))
                }
            }
        }
        try atomicFile(destination) { url in
            let type = format == .gif ? UTType.gif.identifier : UTType.png.identifier
            guard let output = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames.count, nil) else { throw GuideExportError.renderingFailed }
            if format == .gif {
                CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            } else {
                CGImageDestinationSetProperties(output, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
            }
            for (image, duration) in frames {
                try Task.checkCancellation()
                let properties: CFDictionary = format == .gif
                    ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: duration]] as CFDictionary
                    : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: duration]] as CFDictionary
                CGImageDestinationAddImage(output, image, properties)
            }
            guard CGImageDestinationFinalize(output) else { throw GuideExportError.renderingFailed }
        }
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

    private static func writeStepImages(steps: [GuideStep], document: EditableGuideDocument, to destination: URL) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("GuideImages-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        for (index, pair) in try renderedCards(steps: steps, document: document).enumerated() {
            try Task.checkCancellation()
            let isJPEG = document.project.exportSettings.stepImageFormat == .jpeg
            let ext = isJPEG ? "jpg" : "png"
            let data = try isJPEG ? ImageExporter.jpegData(for: pair.1) : ImageExporter.pngData(for: pair.1)
            try data.write(to: temporary.appendingPathComponent(String(format: "%03d-%@.%@", index + 1, safeComponent(pair.0.caption), ext)), options: .atomic)
        }
        try replace(destination, with: temporary)
    }

    private static func writeSlideshow(steps: [GuideStep], document: EditableGuideDocument, to destination: URL) async throws {
        let cards = try renderedCards(steps: steps, document: document)
        try await atomicFileAsync(destination) { url in
            let width = 1440
            let height = cards.first?.1.height ?? 900
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
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
            for index in cards.indices {
                try Task.checkCancellation()
                let step = cards[index].0
                let image = cards[index].1
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                guard let buffer = pixelBuffer(image: image, width: width, height: height), adaptor.append(buffer, withPresentationTime: time) else {
                    throw GuideExportError.writerFailed(writer.error?.localizedDescription ?? "Could not write a slideshow frame.")
                }
                if document.project.exportSettings.usesCrossfade, index + 1 < cards.count {
                    let fade = min(document.project.exportSettings.crossfadeDuration, min(0.2, step.duration / 2))
                    for fadeIndex in 1...4 {
                        try Task.checkCancellation()
                        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                        let fraction = CGFloat(fadeIndex) / 5
                        guard let blended = blend(image, cards[index + 1].1, fraction: fraction),
                              let buffer = pixelBuffer(image: blended, width: width, height: height),
                              adaptor.append(buffer, withPresentationTime: CMTimeAdd(time, CMTime(seconds: step.duration - fade + fade * Double(fadeIndex) / 5, preferredTimescale: 600))) else {
                            throw GuideExportError.writerFailed(writer.error?.localizedDescription ?? "Could not write a slideshow transition.")
                        }
                    }
                }
                time = CMTimeAdd(time, CMTime(seconds: step.duration, preferredTimescale: 600))
            }
            if let finalImage = cards.last?.1, let finalBuffer = pixelBuffer(image: finalImage, width: width, height: height) {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                _ = adaptor.append(finalBuffer, withPresentationTime: time)
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw GuideExportError.writerFailed(writer.error?.localizedDescription ?? "Could not finish the slideshow.") }
        }
    }

    private static func writeMediaTimeline(document: EditableGuideDocument, highlightsOnly: Bool, to destination: URL) async throws {
        guard !document.mediaSegmentURLs.isEmpty else { throw GuideExportError.sourceVideoUnavailable }
        do {
            try await atomicFileAsync(destination) { url in
            let composition = AVMutableComposition()
            guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw GuideExportError.renderingFailed }
            var audioTrack: AVMutableCompositionTrack?
            var insertion = CMTime.zero
            var placedClips: [(clip: GuideMediaClip, outputStart: Double)] = []
            var outputSize: CGSize?
            let clips = highlightsOnly ? highlightClips(document: document) : document.project.timeline.segments.map {
                GuideMediaClip(segment: $0, start: 0, duration: $0.duration)
            }
            for clip in clips {
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
                if let sourceVideo = try await asset.loadTracks(withMediaType: .video).first {
                    if outputSize == nil { outputSize = try await sourceVideo.load(.naturalSize) }
                    try videoTrack.insertTimeRange(range, of: sourceVideo, at: insertion)
                }
                if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                    if audioTrack == nil {
                        audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    try audioTrack?.insertTimeRange(range, of: sourceAudio, at: insertion)
                }
                placedClips.append((clip, insertion.seconds))
                insertion = CMTimeAdd(insertion, range.duration)
            }
            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw GuideExportError.renderingFailed }
            guard session.supportedFileTypes.contains(.mp4) else { throw GuideExportError.renderingFailed }
            if let outputSize, insertion > .zero,
               let videoComposition = mediaVideoComposition(
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
        placedClips: [(clip: GuideMediaClip, outputStart: Double)],
        document: EditableGuideDocument
    ) -> AVMutableVideoComposition? {
        guard renderSize.width > 0, renderSize.height > 0, duration > 0 else { return nil }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        instruction.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: track)]
        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)

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
        guard keyframes.count > 1 else { return nil }
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
        composition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
        return composition
    }

    private struct CursorKeyframe {
        var time: Double
        var point: CGPoint
    }

    private static func cursorKeyframes(
        samples: [GuideCursorSample],
        placedClips: [(clip: GuideMediaClip, outputStart: Double)],
        project: GuideProject,
        renderSize: CGSize,
        duration: Double
    ) -> [CursorKeyframe] {
        let crop = guideMediaCropRect(project.source)
        guard crop.width > 0, crop.height > 0 else { return [] }
        var result: [CursorKeyframe] = []
        for placed in placedClips {
            let segmentStart = placed.clip.segment.startedAt.timeIntervalSince(project.createdAt)
            let clipStart = segmentStart + placed.clip.start
            let clipEnd = clipStart + placed.clip.duration
            for sample in samples where sample.timestampSeconds >= clipStart && sample.timestampSeconds <= clipEnd {
                guard let point = GuideMediaCursorGeometry.renderPoint(
                    fromCaptureGlobalPoint: sample.point,
                    cropRect: crop,
                    renderSize: renderSize,
                    coordinateContract: project.resolvedCoordinateContract
                ) else { continue }
                result.append(CursorKeyframe(
                    time: min(max(placed.outputStart + sample.timestampSeconds - clipStart, 0), duration),
                    point: point
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

    private static func eventOutputTimes(placedClips: [(clip: GuideMediaClip, outputStart: Double)], project: GuideProject) -> [Double] {
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

    private static func writeZIP(steps: [GuideStep], document: EditableGuideDocument, to destination: URL) async throws {
        var entries: [(String, Data)] = []
        var markdown = "# \(document.project.title.isEmpty ? "Guide" : document.project.title)\n\n"
        for (index, pair) in try renderedCards(steps: steps, document: document).enumerated() {
            try Task.checkCancellation()
            let name = String(format: "steps/%03d.png", index + 1)
            entries.append((name, try ImageExporter.pngData(for: pair.1)))
            markdown += "## \(index + 1). \(pair.0.caption)\n\n![Step \(index + 1)](\(name))\n\n\(pair.0.note)\n\n"
        }
        entries.append(("Guide.md", Data(markdown.utf8)))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("GuideZIPExports-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        for format in document.project.exportSettings.formats where format != .zip && format != .stepImages {
            try Task.checkCancellation()
            if let url = try? await export(document: document, format: format, directory: temporary),
               !url.hasDirectoryPath,
               let data = try? Data(contentsOf: url) {
                entries.append(("exports/\(url.lastPathComponent)", data))
            }
        }
        if document.project.exportSettings.includesSourceMediaInZIP {
            for (index, segment) in document.project.timeline.segments.enumerated() {
                try Task.checkCancellation()
                if let url = document.mediaSegmentURLs[segment.id], let data = try? Data(contentsOf: url) {
                    entries.append((String(format: "source-media/%03d.mp4", index + 1), data))
                }
            }
        }
        try atomicFile(destination) { url in try GuideZIPWriter.write(entries: entries, to: url) }
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
        let temp = temporaryFileURL(for: destination)
        defer { try? FileManager.default.removeItem(at: temp) }
        try writer(temp); try replace(destination, with: temp)
    }
    private static func atomicFileAsync(_ destination: URL, writer: (URL) async throws -> Void) async throws {
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
}

nonisolated private enum GuideZIPWriter {
    static func write(entries: [(String, Data)], to url: URL) throws {
        var output = Data(); var central = Data(); var offset: UInt32 = 0
        for (name, data) in entries {
            try Task.checkCancellation()
            let nameData = Data(name.utf8); let crc = try crc32(data); let size = UInt32(data.count)
            var local = Data(); local.appendLE(UInt32(0x04034b50)); local.appendLE(UInt16(20)); local.appendLE(UInt16(0)); local.appendLE(UInt16(0)); local.appendLE(UInt16(0)); local.appendLE(UInt16(0)); local.appendLE(crc); local.appendLE(size); local.appendLE(size); local.appendLE(UInt16(nameData.count)); local.appendLE(UInt16(0)); local.append(nameData); local.append(data)
            output.append(local)
            var record = Data(); record.appendLE(UInt32(0x02014b50)); record.appendLE(UInt16(20)); record.appendLE(UInt16(20)); record.appendLE(UInt16(0)); record.appendLE(UInt16(0)); record.appendLE(UInt16(0)); record.appendLE(UInt16(0)); record.appendLE(crc); record.appendLE(size); record.appendLE(size); record.appendLE(UInt16(nameData.count)); record.appendLE(UInt16(0)); record.appendLE(UInt16(0)); record.appendLE(UInt16(0)); record.appendLE(UInt16(0)); record.appendLE(UInt32(0)); record.appendLE(offset); record.append(nameData); central.append(record)
            offset += UInt32(local.count)
        }
        output.append(central); output.appendLE(UInt32(0x06054b50)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(entries.count)); output.appendLE(UInt16(entries.count)); output.appendLE(UInt32(central.count)); output.appendLE(offset); output.appendLE(UInt16(0)); try output.write(to: url, options: .atomic)
    }
    private static func crc32(_ data: Data) throws -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for (index, byte) in data.enumerated() {
            if index.isMultiple(of: 65_536) { try Task.checkCancellation() }
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb88320 & (0 &- (crc & 1))) }
        }
        return crc ^ 0xffffffff
    }
}

nonisolated private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
}

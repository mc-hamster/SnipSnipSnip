import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ImageExportFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg
    case pdf

    var id: String { rawValue }

    var label: String {
        metadata.label
    }

    var fileExtension: String {
        metadata.fileExtension
    }

    var contentType: UTType {
        metadata.contentType
    }

    private var metadata: ImageExportFormatMetadata {
        switch self {
        case .png:
            return ImageExportFormatMetadata(label: "PNG", fileExtension: "png", contentType: .png)
        case .jpeg:
            return ImageExportFormatMetadata(label: "JPEG", fileExtension: "jpg", contentType: .jpeg)
        case .pdf:
            return ImageExportFormatMetadata(label: "PDF", fileExtension: "pdf", contentType: .pdf)
        }
    }
}

nonisolated private struct ImageExportFormatMetadata {
    let label: String
    let fileExtension: String
    let contentType: UTType
}

nonisolated enum ImageExportWriteMode {
    case stagedReplacement
    case direct
}

nonisolated struct ImageExportOptions: Equatable {
    static let `default` = ImageExportOptions()
    static let minimumJPEGQuality: CGFloat = 0.1
    static let maximumJPEGQuality: CGFloat = 1

    var jpegQuality: CGFloat = 0.9

    var sanitized: ImageExportOptions {
        var copy = self
        copy.jpegQuality = Self.sanitizedJPEGQuality(copy.jpegQuality)
        return copy
    }

    static func sanitizedJPEGQuality(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else {
            return ImageExportOptions.default.jpegQuality
        }

        return min(max(value, minimumJPEGQuality), maximumJPEGQuality)
    }
}

enum ImageExportError: LocalizedError {
    case encodingFailed
    case pdfEncodingFailed
    case shareUnavailable
    case transparentPresentationRequiresPNG

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "The image could not be encoded."
        case .pdfEncodingFailed:
            return "The PDF document could not be encoded."
        case .shareUnavailable:
            return "The current window is not available for sharing."
        case .transparentPresentationRequiresPNG:
            return "Transparent background with shadow requires PNG export. Use Export PNG, Copy, or Share, or switch the presentation background to Solid."
        }
    }
}

enum ImageExporter {
    nonisolated private enum EncodingPlan {
        case imageIO(type: UTType, properties: CFDictionary?)
        case pdf
    }

    nonisolated static func dragOutFormat(
        requestedFormat: ImageExportFormat,
        requiresPNGForFaithfulExport: Bool
    ) -> ImageExportFormat {
        requiresPNGForFaithfulExport ? .png : requestedFormat
    }

    nonisolated static func editedFilename(
        suggestedFilename: String,
        format: ImageExportFormat
    ) -> String {
        let baseName = (suggestedFilename as NSString).deletingPathExtension
        let normalizedBaseName = baseName.isEmpty ? suggestedFilename : baseName
        return "\(normalizedBaseName)-edited.\(format.fileExtension)"
    }

    nonisolated static func pngData(for image: CGImage) throws -> Data {
        try encodedData(for: image, plan: encodingPlan(for: .png))
    }

    nonisolated static func jpegData(for image: CGImage, compressionFactor: CGFloat = ImageExportOptions.default.jpegQuality) throws -> Data {
        try encodedData(for: image, plan: .imageIO(
            type: .jpeg,
            properties: metadataStrippingProperties([
                kCGImageDestinationLossyCompressionQuality: ImageExportOptions.sanitizedJPEGQuality(compressionFactor)
            ])
        ))
    }

    nonisolated static func pdfData(for image: CGImage) throws -> Data {
        let mediaBox = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let data = NSMutableData()

        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ImageExportError.pdfEncodingFailed
        }

        context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()

        return data as Data
    }

    #if DEBUG
    nonisolated static func metadataStrippingPropertiesForTests(_ extra: [CFString: Any] = [:]) -> [String: Any] {
        metadataStrippingProperties(extra) as NSDictionary as? [String: Any] ?? [:]
    }
    #endif

    nonisolated static func data(
        for image: CGImage,
        format: ImageExportFormat,
        options: ImageExportOptions = .default
    ) throws -> Data {
        try encodedData(for: image, plan: encodingPlan(for: format, options: options.sanitized))
    }

    static func copyToClipboard(_ image: CGImage) throws {
        try copyPNGDataToClipboard(pngData(for: image))
    }

    static func copyPNGDataToClipboard(_ data: Data) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    @MainActor
    static func save(
        _ image: CGImage,
        suggestedFilename: String,
        format: ImageExportFormat,
        options: ImageExportOptions = .default
    ) async throws {
        guard let url = await destinationURL(suggestedFilename: suggestedFilename, format: format) else {
            return
        }

        try await write(image, format: format, to: url, options: options)
    }

    @MainActor
    static func destinationURL(suggestedFilename: String, format: ImageExportFormat) async -> URL? {
        let panel = destinationPanel(suggestedFilename: suggestedFilename, format: format)
        return await presentSavePanel(panel)
    }

    @MainActor
    static func presentSavePanel(_ panel: NSSavePanel) async -> URL? {
        await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    @MainActor
    static func destinationPanel(suggestedFilename: String, format: ImageExportFormat) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFilenameForPanel(from: suggestedFilename, format: format)
        return panel
    }

    nonisolated static func write(
        _ image: CGImage,
        format: ImageExportFormat,
        to url: URL,
        mode: ImageExportWriteMode = .stagedReplacement,
        options: ImageExportOptions = .default
    ) async throws {
        let sanitizedOptions = options.sanitized
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let outputURL = mode == .direct ? url : stagingURL(for: url)
            let didStartAccessing = url.startAccessingSecurityScopedResource()

            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                if mode == .direct {
                    let encodedData = try data(for: image, format: format, options: sanitizedOptions)
                    try Task.checkCancellation()
                    try encodedData.write(to: outputURL)
                } else {
                    try encodedWrite(for: image, plan: encodingPlan(for: format, options: sanitizedOptions), to: outputURL)
                }

                try Task.checkCancellation()
                if mode == .stagedReplacement {
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: outputURL, to: url)
                }
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                throw error
            }
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @MainActor
    static func share(_ image: CGImage) throws {
        let targetView = NSApp.keyWindow?.contentView
            ?? NSApp.mainWindow?.contentView
            ?? NSApp.windows.first(where: { $0.isVisible })?.contentView

        guard let targetView else {
            throw ImageExportError.shareUnavailable
        }

        let nsImage = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        let picker = NSSharingServicePicker(items: [nsImage])
        picker.show(relativeTo: targetView.bounds, of: targetView, preferredEdge: .minY)
    }

    private static func suggestedFilenameForPanel(from suggestedFilename: String, format: ImageExportFormat) -> String {
        let baseName = (suggestedFilename as NSString).deletingPathExtension
        let normalizedBaseName = baseName.isEmpty ? suggestedFilename : baseName
        return "\(normalizedBaseName).\(format.fileExtension)"
    }

    nonisolated private static func encodingPlan(
        for format: ImageExportFormat,
        options: ImageExportOptions = .default
    ) -> EncodingPlan {
        switch format {
        case .png:
            return .imageIO(type: .png, properties: metadataStrippingProperties())
        case .jpeg:
            return .imageIO(
                type: .jpeg,
                properties: metadataStrippingProperties([
                    kCGImageDestinationLossyCompressionQuality: options.sanitized.jpegQuality
                ])
            )
        case .pdf:
            return .pdf
        }
    }

    nonisolated private static func encodedData(for image: CGImage, plan: EncodingPlan) throws -> Data {
        switch plan {
        case let .imageIO(type, properties):
            return try encodedData(for: image, type: type, properties: properties)
        case .pdf:
            return try pdfData(for: image)
        }
    }

    nonisolated private static func encodedWrite(for image: CGImage, plan: EncodingPlan, to url: URL) throws {
        switch plan {
        case let .imageIO(type, properties):
            try encodedWrite(for: image, type: type, properties: properties, to: url)
        case .pdf:
            try pdfWrite(image, to: url)
        }
    }

    nonisolated private static func encodedData(for image: CGImage, type: UTType, properties: CFDictionary?) throws -> Data {
        let normalizedImage = try normalizedImageForEncoding(image)
        let data = NSMutableData()

        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ImageExportError.encodingFailed
        }

        CGImageDestinationAddImage(destination, normalizedImage, properties)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageExportError.encodingFailed
        }

        return data as Data
    }

    nonisolated private static func encodedWrite(for image: CGImage, type: UTType, properties: CFDictionary?, to url: URL) throws {
        let normalizedImage = try normalizedImageForEncoding(image)

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageExportError.encodingFailed
        }

        CGImageDestinationAddImage(destination, normalizedImage, properties)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageExportError.encodingFailed
        }
    }

    nonisolated private static func pdfWrite(_ image: CGImage, to url: URL) throws {
        let mediaBox = CGRect(x: 0, y: 0, width: image.width, height: image.height)

        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ImageExportError.pdfEncodingFailed
        }

        context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()
    }

    nonisolated private static func metadataStrippingProperties(_ extra: [CFString: Any] = [:]) -> CFDictionary {
        var properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [:],
            kCGImagePropertyGPSDictionary: [:],
            kCGImagePropertyTIFFDictionary: [:],
            kCGImagePropertyIPTCDictionary: [:]
        ]

        for (key, value) in extra {
            properties[key] = value
        }

        return properties as CFDictionary
    }

    nonisolated private static func stagingURL(for destinationURL: URL) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
    }

    nonisolated private static func normalizedImageForEncoding(_ image: CGImage) throws -> CGImage {
        guard image.width > 0,
              image.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ImageExportError.encodingFailed
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        guard let normalizedImage = context.makeImage() else {
            throw ImageExportError.encodingFailed
        }

        return normalizedImage
    }
}

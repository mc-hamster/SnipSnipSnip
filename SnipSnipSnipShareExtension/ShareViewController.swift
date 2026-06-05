import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class ShareViewController: NSViewController {
    private var hasStartedImport = false
    private let statusLabel = NSTextField(labelWithString: "Opening in SnipSnipSnip...")

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 96))
        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            statusLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor)
        ])

        view = containerView
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        guard !hasStartedImport else {
            return
        }

        hasStartedImport = true
        importFirstSharedImage()
    }

    private func importFirstSharedImage() {
        guard let provider = firstImageProvider() else {
            failImport("SnipSnipSnip could not find an image in this share.")
            return
        }

        let suggestedName = provider.suggestedName

        provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] item, error in
            let result: SharedImageLoadResult

            if let error {
                result = .failure(error.localizedDescription)
            } else if let item {
                do {
                    result = .success(try Self.pngData(from: item))
                } catch {
                    result = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            } else {
                result = .failure(SharedImageImportError.unreadableImage.errorDescription ?? "The shared image could not be read.")
            }

            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                switch result {
                case .success(let imageData):
                    do {
                        try self.openContainingApp(withPNGData: imageData, sourceName: suggestedName)
                    } catch {
                        self.failImport((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    }
                case .failure(let message):
                    self.failImport(message)
                }
            }
        }
    }

    private func firstImageProvider() -> NSItemProvider? {
        let inputItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []

        for item in inputItems {
            for provider in item.attachments ?? [] where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                return provider
            }
        }

        return nil
    }

    private func openContainingApp(withPNGData imageData: Data, sourceName: String?) throws {
        let pasteboardName = "com.oontz.SnipSnipSnip.share.\(UUID().uuidString)"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
        pasteboard.clearContents()

        guard pasteboard.setData(imageData, forType: .png) else {
            throw SharedImageImportError.pasteboardWriteFailed
        }

        guard let url = appImportURL(
            pasteboardName: pasteboardName,
            sourceName: sourceName
        ) else {
            throw SharedImageImportError.invalidImportURL
        }

        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if success {
                    self.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self.failImport("SnipSnipSnip could not be opened.")
                }
            }
        }
    }

    private func appImportURL(pasteboardName: String, sourceName: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "snipsnipsnip"
        components.host = "import-pasteboard"
        components.queryItems = [
            URLQueryItem(name: "name", value: pasteboardName),
            URLQueryItem(name: "source", value: sourceName)
        ]
        return components.url
    }

    private func failImport(_ message: String) {
        statusLabel.stringValue = message
        let error = NSError(
            domain: "com.oontz.Snipsnipsnip.ShareExtension",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        extensionContext?.cancelRequest(withError: error)
    }

    nonisolated private static func pngData(from item: NSSecureCoding) throws -> Data {
        if let image = item as? NSImage {
            return try pngData(from: image)
        }

        if let data = item as? Data {
            return try pngData(fromImageData: data)
        }

        if let url = item as? URL {
            let data = try Data(contentsOf: url)
            return try pngData(fromImageData: data)
        }

        throw SharedImageImportError.unreadableImage
    }

    nonisolated private static func pngData(from image: NSImage) throws -> Data {
        guard let data = image.tiffRepresentation else {
            throw SharedImageImportError.unreadableImage
        }

        return try pngData(fromImageData: data)
    }

    nonisolated private static func pngData(fromImageData data: Data) throws -> Data {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw SharedImageImportError.unreadableImage
        }

        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outputData, UTType.png.identifier as CFString, 1, nil) else {
            throw SharedImageImportError.unreadableImage
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw SharedImageImportError.unreadableImage
        }

        return outputData as Data
    }
}

nonisolated private enum SharedImageLoadResult: Sendable {
    case success(Data)
    case failure(String)
}

private enum SharedImageImportError: LocalizedError {
    case unreadableImage
    case pasteboardWriteFailed
    case invalidImportURL

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "The shared image could not be read."
        case .pasteboardWriteFailed:
            return "The shared image could not be prepared for import."
        case .invalidImportURL:
            return "SnipSnipSnip could not create an import request."
        }
    }
}

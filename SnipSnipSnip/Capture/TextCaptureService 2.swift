import AppKit

nonisolated enum TextCaptureError: LocalizedError {
    case noText
    case clipboardUnavailable

    var errorDescription: String? {
        switch self {
        case .noText: "No text was found. Try selecting a smaller, clearer area. Your clipboard has not changed."
        case .clipboardUnavailable: "Text could not be copied. Please try Capture Text again."
        }
    }
}

/// Direct text capture never installs a screenshot or writes a history file.
@MainActor
struct TextCaptureService {
    var recognizer: any CaptureTextRecognizing = VisionCaptureTextRecognizer()

    func copyText(in image: CGImage, isPrivate: Bool, pasteboard: any PasteboardServicing) async throws {
        let text = try await recognizer.recognizeText(in: image)
        try Task.checkCancellation()
        try Self.writeText(text, isPrivate: isPrivate, pasteboard: pasteboard)
    }

    static func writeText(_ text: String, isPrivate: Bool, pasteboard: any PasteboardServicing) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TextCaptureError.noText }
        var representations = [PasteboardRepresentationSnapshot(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))]
        if isPrivate {
            representations.append(PasteboardRepresentationSnapshot(typeIdentifier: "org.nspasteboard.ConcealedType", data: Data()))
        }
        guard ClipboardPasteboardTransaction.commit(pasteboard: pasteboard,
            preparedItems: [PasteboardItemSnapshot(representations: representations)], fallbackWrite: { false }) else {
            throw TextCaptureError.clipboardUnavailable
        }
    }
}

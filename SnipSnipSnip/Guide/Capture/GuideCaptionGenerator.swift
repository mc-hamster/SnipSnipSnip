#if !APP_STORE_BUILD
import ApplicationServices
#endif
import CoreGraphics
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

nonisolated struct GuideCaptionResult: Equatable, Sendable {
    var metadata: GuideTargetMetadata?
    var deterministicCaption: String
}

nonisolated struct GuideCaptionGenerator: Sendable {
    let accessibility: any AccessibilityPlatform

    #if !APP_STORE_BUILD
    func immediateCaption(for event: GuideClassifiedEvent, at point: CGPoint) -> GuideCaptionResult {
        let metadata = targetMetadata(at: point)
        return GuideCaptionResult(metadata: metadata, deterministicCaption: deterministicCaption(for: event, metadata: metadata))
    }

    /// Typed input is associated with keyboard focus rather than the mouse. We
    /// intentionally retain no characters from the event itself; the resulting
    /// step describes the field, not the value a person entered.
    func textEntryCaption(at point: CGPoint, fromPrintableKeyEvent: Bool = false) -> GuideCaptionResult? {
        if let observation = focusedTextEntryObservation() {
            return observation.caption
        }
        var metadata = focusedTargetMetadata() ?? targetMetadata(at: point)
        guard Self.allowsTextEntryCapture(
            metadata: metadata,
            fromPrintableKeyEvent: fromPrintableKeyEvent
        ) else { return nil }
        // The rendered frame may intentionally show what the person entered,
        // but the editable Guide metadata must not retain that value separately.
        metadata?.safeValue = nil
        return GuideCaptionResult(metadata: metadata, deterministicCaption: deterministicCaption(for: .textEntry, metadata: metadata))
    }

    /// Value polling remains deliberately strict so arbitrary accessibility
    /// changes cannot masquerade as typing. A printable key event is direct
    /// evidence of text entry and supports custom/web editors that do not expose
    /// a standard AX text role or readable AXValue.
    static func allowsTextEntryCapture(
        metadata: GuideTargetMetadata?,
        fromPrintableKeyEvent: Bool
    ) -> Bool {
        guard metadata?.isSecure != true else { return false }
        if fromPrintableKeyEvent { return true }
        guard let metadata else { return false }
        return isTextEntryTarget(metadata)
    }

    /// Polling the focused field catches edits that do not arrive as observable
    /// key-down events, including paste, dictation, and input-method composition.
    /// Only a process-local hash survives this call; entered text is never kept.
    func focusedTextEntryObservation() -> GuideTextEntryObservation? {
        guard accessibility.isProcessTrusted(),
              let element = accessibility.focusedElement() else { return nil }
        var metadata = targetMetadata(for: element)
        guard !metadata.isSecure,
              Self.isTextEntryTarget(metadata),
              let value = textValue(of: element) else { return nil }

        let target = GuideTextEntryTargetIdentity(
            processID: metadata.processID,
            windowID: metadata.windowID,
            role: metadata.role,
            identifier: metadata.identifier,
            frame: metadata.frame
        )
        metadata.safeValue = nil
        let caption = GuideCaptionResult(
            metadata: metadata,
            deterministicCaption: deterministicCaption(for: .textEntry, metadata: metadata)
        )
        return GuideTextEntryObservation(
            target: target,
            valueFingerprint: value.hashValue,
            caption: caption
        )
    }

    /// Lets an app-scoped Guide follow keyboard focus even when the pointer has
    /// not generated an interaction in the newly focused window yet.
    func focusedWindowID(forProcessID processID: pid_t) -> CGWindowID? {
        guard accessibility.isProcessTrusted(),
              let element = accessibility.focusedElement(),
              let identity = accessibility.windowIdentity(for: element),
              identity.ownerPID == processID else { return nil }
        return identity.windowID
    }

    func recognizeFallbackText(in image: CGImage, privateCapture: Bool) async -> String? {
        guard !privateCapture else { return nil }
        let value = try? await CaptureTextRecognizer.recognizeText(in: image)
        let normalized = value.map(CaptureTextRecognizer.normalizedRecognizedText) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    func refineCaption(
        deterministic: String,
        metadata: GuideTargetMetadata?,
        recognizedText: String?,
        privateCapture: Bool
    ) async -> String? {
        guard !privateCapture else { return nil }
#if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let prompt = """
        Rewrite this software instruction as one short imperative sentence. Do not invent UI names or actions.
        Existing instruction: \(deterministic)
        Role: \(metadata?.role ?? "unknown")
        Label: \(metadata?.label ?? metadata?.title ?? "unknown")
        Visible text: \(recognizedText ?? "none")
        """
        do {
            let session = LanguageModelSession(instructions: "Write concise, factual software guide steps. Return only the instruction sentence.")
            let response = try await session.respond(to: prompt)
            let candidate = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.count >= 4, candidate.count <= 160, !candidate.contains("\n") else { return nil }
            return candidate
        } catch { return nil }
#else
        return nil
#endif
    }

    private func targetMetadata(at point: CGPoint) -> GuideTargetMetadata? {
        guard accessibility.isProcessTrusted() else { return nil }
        let result = accessibility.element(at: point, from: accessibility.systemWideElement())
        guard result.status == .success, let element = result.element else { return nil }
        return targetMetadata(for: element)
    }

    private func focusedTargetMetadata() -> GuideTargetMetadata? {
        guard accessibility.isProcessTrusted(), let element = accessibility.focusedElement() else { return nil }
        return targetMetadata(for: element)
    }

    private func targetMetadata(for element: AccessibilityElementHandle) -> GuideTargetMetadata {
        let role = string("AXRole", from: element)
        let subrole = string("AXSubrole", from: element)
        let isSecure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        let identity = accessibility.windowIdentity(for: element)
        return GuideTargetMetadata(
            role: role,
            title: string("AXTitle", from: element),
            label: string("AXLabel", from: element) ?? string("AXDescription", from: element),
            elementDescription: string("AXHelp", from: element),
            safeValue: isSecure ? nil : string("AXValue", from: element),
            identifier: string("AXIdentifier", from: element),
            actions: accessibility.copyActionNames(from: element).names,
            frame: accessibility.frame(of: element),
            processID: identity?.ownerPID ?? accessibility.processIdentifier(for: element).processID,
            windowID: identity?.windowID,
            isSecure: isSecure
        )
    }

    private static func isTextEntryTarget(_ metadata: GuideTargetMetadata) -> Bool {
        switch metadata.role {
        case "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox": true
        default: false
        }
    }

    private func string(_ name: String, from element: AccessibilityElementHandle) -> String? {
        let value = accessibility.copyAttribute(name, from: element).value
        if let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return string }
        return nil
    }

    private func textValue(of element: AccessibilityElementHandle) -> String? {
        let value = accessibility.copyAttribute("AXValue", from: element).value
        if let string = value as? String {
            return string
        }
        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }
        return nil
    }

    private func deterministicCaption(for event: GuideClassifiedEvent, metadata: GuideTargetMetadata?) -> String {
        let name = metadata?.label ?? metadata?.title ?? metadata?.safeValue
        switch event {
        case .click:
            if metadata?.role == "AXMenuItem" { return "Choose \(name ?? "the menu item")." }
            return "Click \(name ?? "the highlighted control")."
        case .doubleClick: return "Open \(name ?? "the highlighted item")."
        case .selection: return "Select text in \(metadata?.label ?? metadata?.title ?? "the highlighted area")."
        case .textEntry: return "Enter text in \(metadata?.label ?? metadata?.title ?? metadata?.elementDescription ?? "the highlighted text field")."
        case .scroll(let direction, _): return "Scroll \(direction) in \(name ?? "the highlighted area")."
        case .gesture(let direction): return "Swipe \(direction)."
        case .shortcut(let shortcut): return "Press \(shortcut)."
        case .manual: return "Review this step."
        case .ignored: return ""
        }
    }
    #else
    func immediateCaption(for event: GuideClassifiedEvent, at point: CGPoint) -> GuideCaptionResult {
        _ = event
        _ = point
        return GuideCaptionResult(metadata: nil, deterministicCaption: "Review this step.")
    }

    func textEntryCaption(at point: CGPoint, fromPrintableKeyEvent: Bool = false) -> GuideCaptionResult? {
        _ = point
        _ = fromPrintableKeyEvent
        return nil
    }

    static func allowsTextEntryCapture(
        metadata: GuideTargetMetadata?,
        fromPrintableKeyEvent: Bool
    ) -> Bool {
        guard metadata?.isSecure != true else { return false }
        if fromPrintableKeyEvent { return true }
        switch metadata?.role {
        case "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox": return true
        default: return false
        }
    }

    func focusedTextEntryObservation() -> GuideTextEntryObservation? { nil }

    func focusedWindowID(forProcessID processID: pid_t) -> CGWindowID? {
        _ = processID
        return nil
    }

    func recognizeFallbackText(in image: CGImage, privateCapture: Bool) async -> String? {
        _ = image
        _ = privateCapture
        return nil
    }

    func refineCaption(
        deterministic: String,
        metadata: GuideTargetMetadata?,
        recognizedText: String?,
        privateCapture: Bool
    ) async -> String? {
        _ = deterministic
        _ = metadata
        _ = recognizedText
        _ = privateCapture
        return nil
    }
    #endif
}

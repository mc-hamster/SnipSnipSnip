import CryptoKit
import Foundation

nonisolated struct PresentationSceneValidationError: LocalizedError, Equatable {
    var message: String

    var errorDescription: String? { message }
}

nonisolated enum PresentationSceneValidator {
    static let maximumSceneBytes = 4 * 1_024 * 1_024
    static let maximumCanvasDimension = 16_384
    static let maximumCanvasPixels = 134_217_728
    static let maximumGeometryMagnitude: CGFloat = 1_000_000

    static func validate(
        svgText: String,
        source: PresentationSceneSource,
        fileURL: URL? = nil
    ) throws -> (metadata: PresentationSceneMetadata, sanitizedSVGText: String) {
        guard svgText.utf8.count <= maximumSceneBytes else {
            throw PresentationSceneValidationError(message: "Scene SVG exceeds safe resource bounds.")
        }
        if svgText.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil {
            throw PresentationSceneValidationError(message: "Scene SVG must not declare a DTD.")
        }
        guard let data = svgText.data(using: .utf8) else {
            throw PresentationSceneValidationError(message: "Scene is not valid UTF-8.")
        }

        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever, .nodePreserveWhitespace])
        } catch {
            throw PresentationSceneValidationError(message: "Scene SVG could not be parsed.")
        }

        if document.dtd != nil {
            throw PresentationSceneValidationError(message: "Scene SVG must not declare a DTD.")
        }
        try rejectStylesheetInstructions(in: document)

        guard let metadataElement = findMetadataElement(in: document.rootElement()) else {
            throw PresentationSceneValidationError(message: "Scene SVG is missing metadata id=\"snipsnipsnip-scene\".")
        }

        let metadataText = metadataElement.stringValue ?? ""
        guard let metadataData = metadataText.data(using: .utf8) else {
            throw PresentationSceneValidationError(message: "Scene metadata is not valid UTF-8.")
        }

        let metadata: PresentationSceneMetadata
        do {
            metadata = try JSONDecoder().decode(PresentationSceneMetadata.self, from: metadataData)
        } catch {
            throw PresentationSceneValidationError(message: "Scene metadata JSON could not be decoded.")
        }

        try validate(metadata: metadata, source: source)
        try validateElements(in: document, metadata: metadata)

        return (metadata, document.xmlString(options: []))
    }

    private static func validate(metadata: PresentationSceneMetadata, source: PresentationSceneSource) throws {
        guard metadata.schema == PresentationSceneMetadata.schema else {
            throw PresentationSceneValidationError(message: "Scene metadata has an unsupported schema.")
        }

        guard metadata.schemaVersion == PresentationSceneMetadata.supportedSchemaVersion else {
            throw PresentationSceneValidationError(message: "Scene metadata has an unsupported schema version.")
        }

        guard !metadata.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PresentationSceneValidationError(message: "Scene metadata requires an id.")
        }

        guard !metadata.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PresentationSceneValidationError(message: "Scene metadata requires a name.")
        }

        guard metadata.version > 0 else {
            throw PresentationSceneValidationError(message: "Scene metadata version must be greater than zero.")
        }

        guard metadata.canvas.width > 0, metadata.canvas.height > 0 else {
            throw PresentationSceneValidationError(message: "Scene metadata canvas must have positive width and height.")
        }
        guard metadata.canvas.width <= maximumCanvasDimension, metadata.canvas.height <= maximumCanvasDimension,
              metadata.canvas.width * metadata.canvas.height <= maximumCanvasPixels else {
            throw PresentationSceneValidationError(message: "Scene canvas exceeds safe resource bounds.")
        }

        if source == .bundled {
            guard metadata.id.hasPrefix("builtin.") else {
                throw PresentationSceneValidationError(message: "Bundled scene IDs must use the builtin. prefix.")
            }
        } else if metadata.id.hasPrefix("builtin.") {
            throw PresentationSceneValidationError(message: "User scene IDs must not use the builtin. prefix.")
        }

        var seenSlotIDs = Set<String>()
        for slot in metadata.slots {
            guard !slot.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PresentationSceneValidationError(message: "Scene metadata contains an empty slot id.")
            }
            guard seenSlotIDs.insert(slot.id).inserted else {
                throw PresentationSceneValidationError(message: "Scene metadata contains duplicate slot id \(slot.id).")
            }
            let scales = [slot.minScale, slot.maxScale, slot.maxAutoEnlargement].compactMap { $0 }
            guard scales.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= maximumGeometryMagnitude }),
                  slot.minScale == nil || slot.maxScale == nil || slot.minScale! <= slot.maxScale! else {
                throw PresentationSceneValidationError(message: "Scene slot scale limits exceed safe resource bounds.")
            }
        }

        let screenshotSlots = metadata.slots.filter { $0.id == PresentationSceneStore.primaryScreenshotSlotID && $0.type == .image }
        guard screenshotSlots.count == 1, screenshotSlots[0].required else {
            throw PresentationSceneValidationError(message: "Scene metadata must include one required primaryScreenshot image slot.")
        }
    }

    private static func validateElements(in document: XMLDocument, metadata: PresentationSceneMetadata) throws {
        let allowedSlotIDs = Set(metadata.slots.map(\.id))
        var primaryScreenshotElementCount = 0

        try visitElements(in: document.rootElement()) { element in
            let elementName = (element.localName ?? element.name)?.lowercased() ?? ""
            if elementName == "script" || elementName == "foreignobject" || animationElementNames.contains(elementName) {
                throw PresentationSceneValidationError(message: "Scene SVG contains unsupported <\(element.name ?? elementName)> content.")
            }
            if elementName == "style" {
                try validateCSSReferences(element.stringValue ?? "")
            }

            for attribute in element.attributes ?? [] {
                let attributeName = attribute.name?.lowercased() ?? ""
                let attributeValue = attribute.stringValue ?? ""
                let lowerValue = attributeValue.lowercased()

                if attributeName.hasPrefix("on") {
                    throw PresentationSceneValidationError(message: "Scene SVG contains event-handler attributes.")
                }

                if attributeName == "data-sss-slot", !allowedSlotIDs.contains(attributeValue) {
                    throw PresentationSceneValidationError(message: "Scene SVG element references unknown slot \(attributeValue).")
                }

                if lowerValue.contains("http://")
                    || lowerValue.contains("https://")
                    || lowerValue.contains("file:")
                    || lowerValue.contains("data:") {
                    throw PresentationSceneValidationError(message: "Scene SVG must not reference remote, file, or embedded data URLs.")
                }
                if attributeName == "href" || attributeName.hasSuffix(":href") {
                    let reference = attributeValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if reference.hasPrefix("snipsnipsnip:"),
                       !allowedSlotIDs.contains(String(reference.dropFirst("snipsnipsnip:".count))) {
                        throw PresentationSceneValidationError(message: "Scene SVG references unknown slot \(reference).")
                    }
                    guard reference.hasPrefix("#")
                        || (reference.hasPrefix("snipsnipsnip:") && allowedSlotIDs.contains(String(reference.dropFirst("snipsnipsnip:".count)))) else {
                        throw PresentationSceneValidationError(message: "Scene SVG must not reference external resources.")
                    }
                }
                if attributeName == "xml:base", !attributeValue.isEmpty {
                    throw PresentationSceneValidationError(message: "Scene SVG must not reference external resources through xml:base.")
                }
                try validateCSSReferences(attributeValue)

                for slotID in snipSlotReferences(in: attributeValue) where !allowedSlotIDs.contains(slotID) {
                    throw PresentationSceneValidationError(message: "Scene SVG references unknown slot \(slotID).")
                }
            }

            if elementName == "image",
               element.attribute(forName: "data-sss-slot")?.stringValue == PresentationSceneStore.primaryScreenshotSlotID {
                for name in ["x", "y", "width", "height"] {
                    if let raw = element.attribute(forName: name)?.stringValue,
                       let number = PresentationSceneGeometryResolver.length(raw, default: 0) {
                        guard abs(number) <= maximumGeometryMagnitude,
                              (name == "x" || name == "y" || number > 0) else {
                            throw PresentationSceneValidationError(message: "Scene screenshot slot exceeds safe resource bounds.")
                        }
                    } else if let raw = element.attribute(forName: name)?.stringValue {
                        let numeric = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "px", with: "")
                        if let number = Double(numeric), !number.isFinite {
                            throw PresentationSceneValidationError(message: "Scene screenshot slot exceeds safe resource bounds.")
                        }
                    }
                }
                primaryScreenshotElementCount += 1
            }
        }

        guard primaryScreenshotElementCount == 1 else {
            throw PresentationSceneValidationError(message: "Scene SVG must include exactly one image element for primaryScreenshot.")
        }
    }

    private static let animationElementNames: Set<String> = [
        "animate",
        "animatemotion",
        "animatetransform",
        "set",
    ]

    private static func rejectStylesheetInstructions(in node: XMLNode) throws {
        if node.kind == .processingInstruction, node.name?.lowercased() == "xml-stylesheet" {
            throw PresentationSceneValidationError(message: "Scene SVG must not reference external stylesheets.")
        }
        for child in node.children ?? [] { try rejectStylesheetInstructions(in: child) }
    }

    private static func validateCSSReferences(_ value: String) throws {
        // CSS escapes and comments cannot be allowed to conceal resource syntax.
        let withoutComments = value.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        let decoded = NSMutableString(string: withoutComments)
        for match in cssEscapePattern.matches(in: withoutComments, range: NSRange(location: 0, length: decoded.length)).reversed() {
            let replacement: String
            if match.range(at: 1).location != NSNotFound,
               let scalarValue = UInt32((withoutComments as NSString).substring(with: match.range(at: 1)), radix: 16),
               let scalar = UnicodeScalar(scalarValue) {
                replacement = String(scalar)
            } else if match.range(at: 2).location != NSNotFound {
                let character = (withoutComments as NSString).substring(with: match.range(at: 2))
                replacement = character == "\n" || character == "\r" ? "" : character
            } else {
                replacement = ""
            }
            decoded.replaceCharacters(in: match.range, with: replacement)
        }
        let css = decoded as String
        if css.range(of: "@import", options: .caseInsensitive) != nil {
            throw PresentationSceneValidationError(message: "Scene SVG must not reference external stylesheets.")
        }
        for match in cssURLPattern.matches(in: css, range: NSRange(location: 0, length: (css as NSString).length)) {
            let reference = (css as NSString).substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard reference.hasPrefix("#") else {
                throw PresentationSceneValidationError(message: "Scene SVG must not reference external resources in CSS.")
            }
        }
    }

    private static let cssEscapePattern = try! NSRegularExpression(pattern: #"\\(?:([0-9a-fA-F]{1,6})[ \t\r\n\f]?|([\s\S]))"#)
    private static let cssURLPattern = try! NSRegularExpression(pattern: #"url\s*\(([^)]*)\)"#, options: [.caseInsensitive])

    private static func findMetadataElement(in element: XMLElement?) -> XMLElement? {
        guard let element else {
            return nil
        }

        if element.attribute(forName: "id")?.stringValue == "snipsnipsnip-scene" {
            return element
        }

        for child in element.children ?? [] {
            if let childElement = child as? XMLElement,
               let match = findMetadataElement(in: childElement) {
                return match
            }
        }

        return nil
    }

    private static func visitElements(in element: XMLElement?, _ body: (XMLElement) throws -> Void) throws {
        guard let element else {
            return
        }

        try body(element)

        for child in element.children ?? [] {
            try visitElements(in: child as? XMLElement, body)
        }
    }

    static func snipSlotReferences(in value: String) -> [String] {
        var references: [String] = []
        var searchRange = value.startIndex..<value.endIndex

        while let range = value.range(of: "snipsnipsnip:", range: searchRange) {
            var index = range.upperBound
            var slotID = ""

            while index < value.endIndex {
                let character = value[index]
                if character.isLetter || character.isNumber || character == "_" || character == "-" {
                    slotID.append(character)
                    index = value.index(after: index)
                } else {
                    break
                }
            }

            if !slotID.isEmpty {
                references.append(slotID)
            }

            searchRange = index..<value.endIndex
        }

        return references
    }
}

nonisolated struct PresentationSceneStore {
    static let primaryScreenshotSlotID = "primaryScreenshot"
    static let bundledDirectoryName = "Bundled"
    static let userDirectoryName = "User"
    static let bundledManifestFilename = ".snipsnipsnip-bundled-scenes.json"
    static let configuredRootDefaultsKey = "appModel.presentationScenesRootPath"
    static let bundledSceneResourceFilenames = [
        "safari-browser-light.svg",
        "phone-story-dark.svg",
        "social-card-clean.svg",
        "mac-window-light.svg",
    ]

    var rootURL: URL
    var bundledResourceURLs: [URL]
    var appVersion: String
    var fileManager: FileManager

    nonisolated init(
        rootURL: URL = PresentationSceneStore.defaultRootURL,
        bundledResourceURLs: [URL] = PresentationSceneStore.defaultBundledResourceURLs(),
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "debug",
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.bundledResourceURLs = bundledResourceURLs
        self.appVersion = appVersion
        self.fileManager = fileManager
    }

    static var defaultRootURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("SnipSnipSnip", isDirectory: true)
            .appendingPathComponent("Presentation Scenes", isDirectory: true)
    }

    static func configuredRootURL(in defaults: UserDefaults) -> URL {
        guard let path = defaults.string(forKey: configuredRootDefaultsKey),
              !path.isEmpty else {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                return FileManager.default.temporaryDirectory
                    .appendingPathComponent("SnipSnipSnipTests", isDirectory: true)
                    .appendingPathComponent("Presentation Scenes", isDirectory: true)
            }
            return defaultRootURL
        }

        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func defaultBundledResourceURLs(bundle: Bundle = .main) -> [URL] {
        let nestedURLs = bundle.urls(forResourcesWithExtension: "svg", subdirectory: "PresentationScenes") ?? []
        let flatURLs = bundledSceneResourceFilenames.compactMap { filename -> URL? in
            let basename = (filename as NSString).deletingPathExtension
            return bundle.url(forResource: basename, withExtension: "svg")
        }
        let urlsByPath = Dictionary(grouping: nestedURLs + flatURLs, by: \.path).compactMap { $0.value.first }
        return urlsByPath.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func reload() throws -> PresentationSceneStoreResult {
        var diagnostics: [PresentationSceneDiagnostic] = []
        let bundledURL = rootURL.appendingPathComponent(Self.bundledDirectoryName, isDirectory: true)
        let userURL = rootURL.appendingPathComponent(Self.userDirectoryName, isDirectory: true)

        try fileManager.createDirectory(at: bundledURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userURL, withIntermediateDirectories: true)

        var manifest = loadManifest(from: bundledURL)
        syncBundledResources(
            into: bundledURL,
            manifest: &manifest,
            diagnostics: &diagnostics
        )
        saveManifest(manifest, to: bundledURL)

        let bundledScenes = loadScenes(in: bundledURL, source: .bundled, manifest: manifest, diagnostics: &diagnostics)
        let userScenes = loadScenes(in: userURL, source: .user, manifest: nil, diagnostics: &diagnostics)
        let winners = resolveDuplicates(bundledScenes + userScenes, diagnostics: &diagnostics)

        return PresentationSceneStoreResult(
            rootURL: rootURL,
            scenes: winners.sorted {
                if $0.source != $1.source {
                    return $0.source == .bundled
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            diagnostics: diagnostics
        )
    }

    private func syncBundledResources(
        into bundledURL: URL,
        manifest: inout BundledSceneManifest,
        diagnostics: inout [PresentationSceneDiagnostic]
    ) {
        for resourceURL in bundledResourceURLs {
            do {
                let svgText = try String(contentsOf: resourceURL, encoding: .utf8)
                let validated = try PresentationSceneValidator.validate(svgText: svgText, source: .bundled, fileURL: resourceURL)
                let shippedHash = sha256(svgText)
                let existingRecord = manifest.records.first { $0.id == validated.metadata.id }
                let preferredFilename = existingRecord?.filename ?? resourceURL.lastPathComponent
                let preferredURL = bundledURL.appendingPathComponent(preferredFilename)

                if fileManager.fileExists(atPath: preferredURL.path) {
                    let currentText = (try? String(contentsOf: preferredURL, encoding: .utf8)) ?? ""
                    let currentHash = sha256(currentText)
                    if let existingRecord, currentHash == existingRecord.sha256 {
                        if validated.metadata.version > existingRecord.version || shippedHash != existingRecord.sha256 {
                            try svgText.write(to: preferredURL, atomically: true, encoding: .utf8)
                        }
                        manifest.upsert(BundledSceneManifestRecord(
                            id: validated.metadata.id,
                            version: validated.metadata.version,
                            filename: preferredFilename,
                            sha256: shippedHash,
                            lastSyncedAppVersion: appVersion
                        ))
                    } else if currentHash == shippedHash {
                        manifest.upsert(BundledSceneManifestRecord(
                            id: validated.metadata.id,
                            version: validated.metadata.version,
                            filename: preferredFilename,
                            sha256: shippedHash,
                            lastSyncedAppVersion: appVersion
                        ))
                    } else {
                        diagnostics.append(PresentationSceneDiagnostic(
                            severity: .warning,
                            message: "Bundled scene was modified; preserved existing copy and wrote the shipped scene beside it.",
                            fileURL: preferredURL,
                            sceneID: validated.metadata.id
                        ))
                        let updateURL = uniqueBundledUpdateURL(
                            baseName: validated.metadata.name,
                            version: validated.metadata.version,
                            directoryURL: bundledURL
                        )
                        try svgText.write(to: updateURL, atomically: true, encoding: .utf8)
                        manifest.upsert(BundledSceneManifestRecord(
                            id: validated.metadata.id,
                            version: validated.metadata.version,
                            filename: updateURL.lastPathComponent,
                            sha256: shippedHash,
                            lastSyncedAppVersion: appVersion
                        ))
                    }
                } else {
                    try svgText.write(to: preferredURL, atomically: true, encoding: .utf8)
                    manifest.upsert(BundledSceneManifestRecord(
                        id: validated.metadata.id,
                        version: validated.metadata.version,
                        filename: preferredFilename,
                        sha256: shippedHash,
                        lastSyncedAppVersion: appVersion
                    ))
                }
            } catch {
                diagnostics.append(PresentationSceneDiagnostic(
                    severity: .error,
                    message: "Bundled scene could not be synced: \(error.localizedDescription)",
                    fileURL: resourceURL
                ))
            }
        }
    }

    private func loadScenes(
        in directoryURL: URL,
        source: PresentationSceneSource,
        manifest: BundledSceneManifest?,
        diagnostics: inout [PresentationSceneDiagnostic]
    ) -> [PresentationSceneDefinition] {
        let urls = ((try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
        .filter { $0.pathExtension.lowercased() == "svg" }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        return urls.compactMap { url in
            do {
                let svgText = try String(contentsOf: url, encoding: .utf8)
                let validated = try PresentationSceneValidator.validate(svgText: svgText, source: source, fileURL: url)
                let record = manifest?.records.first { $0.filename == url.lastPathComponent }
                let isUserModifiedBundled = source == .bundled
                    && record.map { sha256(svgText) != $0.sha256 } ?? true

                if isUserModifiedBundled {
                    diagnostics.append(PresentationSceneDiagnostic(
                        severity: .info,
                        message: "Bundled scene has local modifications.",
                        fileURL: url,
                        sceneID: validated.metadata.id
                    ))
                }

                return PresentationSceneDefinition(
                    metadata: validated.metadata,
                    sanitizedSVGText: validated.sanitizedSVGText,
                    source: source,
                    fileURL: url,
                    isUserModifiedBundled: isUserModifiedBundled
                )
            } catch {
                diagnostics.append(PresentationSceneDiagnostic(
                    severity: .error,
                    message: error.localizedDescription,
                    fileURL: url
                ))
                return nil
            }
        }
    }

    private func resolveDuplicates(
        _ scenes: [PresentationSceneDefinition],
        diagnostics: inout [PresentationSceneDiagnostic]
    ) -> [PresentationSceneDefinition] {
        Dictionary(grouping: scenes, by: \.id).compactMap { id, candidates in
            if candidates.count > 1 {
                diagnostics.append(PresentationSceneDiagnostic(
                    severity: .warning,
                    message: "Multiple scenes use id \(id); showing the highest-precedence copy.",
                    sceneID: id
                ))
            }

            return candidates.sorted { lhs, rhs in
                if lhs.version != rhs.version {
                    return lhs.version > rhs.version
                }
                return duplicateRank(lhs) > duplicateRank(rhs)
            }.first
        }
    }

    private func duplicateRank(_ scene: PresentationSceneDefinition) -> Int {
        switch scene.source {
        case .user:
            return 3
        case .bundled:
            return scene.isUserModifiedBundled ? 2 : 1
        }
    }

    private func uniqueBundledUpdateURL(baseName: String, version: Int, directoryURL: URL) -> URL {
        let sanitizedBase = sanitizedFilename(baseName)
        let candidates = [
            "\(sanitizedBase) (Bundled v\(version)).svg",
            "\(sanitizedBase) (Bundled Update).svg",
        ]

        for filename in candidates {
            let url = directoryURL.appendingPathComponent(filename)
            if !fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        var index = 2
        while true {
            let url = directoryURL.appendingPathComponent("\(sanitizedBase) (Bundled Update \(index)).svg")
            if !fileManager.fileExists(atPath: url.path) {
                return url
            }
            index += 1
        }
    }

    private func sanitizedFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let scalarView = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(scalarView).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Scene" : result
    }

    private func loadManifest(from bundledURL: URL) -> BundledSceneManifest {
        let url = bundledURL.appendingPathComponent(Self.bundledManifestFilename)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(BundledSceneManifest.self, from: data) else {
            return BundledSceneManifest(records: [])
        }
        return manifest
    }

    private func saveManifest(_ manifest: BundledSceneManifest, to bundledURL: URL) {
        let url = bundledURL.appendingPathComponent(Self.bundledManifestFilename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(manifest) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated private struct BundledSceneManifest: Codable, Equatable {
    var records: [BundledSceneManifestRecord]

    mutating func upsert(_ record: BundledSceneManifestRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }
}

nonisolated private struct BundledSceneManifestRecord: Codable, Equatable {
    var id: String
    var version: Int
    var filename: String
    var sha256: String
    var lastSyncedAppVersion: String
}

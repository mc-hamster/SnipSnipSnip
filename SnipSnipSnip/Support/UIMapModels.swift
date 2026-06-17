import CoreGraphics
import Foundation

nonisolated struct UIMapSnapshot: Codable, Equatable, Sendable {
    var capturedAt: Date
    var sourceRect: CGRect
    var elements: [UIMapElement]
    var diagnostics: UIMapCaptureDiagnosticsSummary? = nil

    var isEmpty: Bool {
        elements.isEmpty
    }

    var elementCount: Int {
        elements.reduce(0) { $0 + $1.flattenedCount }
    }

    var availableRoles: [String] {
        Array(Set(allElements.compactMap(\.role))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var allElements: [UIMapElement] {
        elements.flatMap(\.flattened)
    }

    func element(matching id: UUID) -> UIMapElement? {
        for element in elements {
            if let match = element.element(matching: id) {
                return match
            }
        }

        return nil
    }

    func parentHierarchy(for id: UUID) -> [UIMapElement] {
        for element in elements {
            if let hierarchy = element.parentHierarchy(for: id) {
                return hierarchy
            }
        }

        return []
    }

    func searchableText() -> String {
        allElements
            .flatMap(\.searchTokens)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

nonisolated enum UIMapElementSource: String, Codable, Equatable, Sendable {
    case accessibility
    case ocrSupplement
}

nonisolated struct UIMapCaptureDiagnosticsSummary: Codable, Equatable, Sendable {
    var axWindowMatchConfidence: CGFloat?
    var accessibilityElementCount: Int
    var ocrSupplementElementCount: Int
    var didHitBudgetLimit: Bool
    var didHitTimeLimit: Bool

    init(
        axWindowMatchConfidence: CGFloat? = nil,
        accessibilityElementCount: Int,
        ocrSupplementElementCount: Int,
        didHitBudgetLimit: Bool,
        didHitTimeLimit: Bool
    ) {
        self.axWindowMatchConfidence = axWindowMatchConfidence
        self.accessibilityElementCount = accessibilityElementCount
        self.ocrSupplementElementCount = ocrSupplementElementCount
        self.didHitBudgetLimit = didHitBudgetLimit
        self.didHitTimeLimit = didHitTimeLimit
    }
}

nonisolated struct UIMapElement: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String?
    var accessibilityLabel: String?
    var accessibilityIdentifier: String?
    var role: String?
    var roleDescription: String?
    var valueDescription: String?
    var source: UIMapElementSource
    var documentRect: CGRect
    var owningApplication: String?
    var bundleIdentifier: String?
    var overlayParentHierarchy: String?
    var children: [UIMapElement]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case accessibilityLabel
        case accessibilityIdentifier
        case role
        case roleDescription
        case valueDescription
        case source
        case documentRect
        case owningApplication
        case bundleIdentifier
        case overlayParentHierarchy
        case children
    }

    init(
        id: UUID = UUID(),
        name: String? = nil,
        accessibilityLabel: String? = nil,
        accessibilityIdentifier: String? = nil,
        role: String? = nil,
        roleDescription: String? = nil,
        valueDescription: String? = nil,
        source: UIMapElementSource? = nil,
        documentRect: CGRect,
        owningApplication: String? = nil,
        bundleIdentifier: String? = nil,
        overlayParentHierarchy: String? = nil,
        children: [UIMapElement] = []
    ) {
        self.id = id
        self.name = name.normalizedUIMapText
        self.accessibilityLabel = accessibilityLabel.normalizedUIMapText
        self.accessibilityIdentifier = accessibilityIdentifier.normalizedUIMapText
        self.role = role.normalizedUIMapText
        self.roleDescription = roleDescription.normalizedUIMapText
        self.valueDescription = valueDescription.normalizedUIMapText
        self.source = source ?? Self.inferredSource(roleDescription: self.roleDescription)
        self.documentRect = documentRect.gscIntegralStandardized
        self.owningApplication = owningApplication.normalizedUIMapText
        self.bundleIdentifier = bundleIdentifier.normalizedUIMapText
        self.overlayParentHierarchy = overlayParentHierarchy.normalizedUIMapText
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name).normalizedUIMapText
        accessibilityLabel = try container.decodeIfPresent(String.self, forKey: .accessibilityLabel).normalizedUIMapText
        accessibilityIdentifier = try container.decodeIfPresent(String.self, forKey: .accessibilityIdentifier).normalizedUIMapText
        role = try container.decodeIfPresent(String.self, forKey: .role).normalizedUIMapText
        roleDescription = try container.decodeIfPresent(String.self, forKey: .roleDescription).normalizedUIMapText
        valueDescription = try container.decodeIfPresent(String.self, forKey: .valueDescription).normalizedUIMapText
        source = try container.decodeIfPresent(UIMapElementSource.self, forKey: .source)
            ?? Self.inferredSource(roleDescription: roleDescription)
        documentRect = try container.decode(CGRect.self, forKey: .documentRect).gscIntegralStandardized
        owningApplication = try container.decodeIfPresent(String.self, forKey: .owningApplication).normalizedUIMapText
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier).normalizedUIMapText
        overlayParentHierarchy = try container.decodeIfPresent(String.self, forKey: .overlayParentHierarchy).normalizedUIMapText
        children = try container.decodeIfPresent([UIMapElement].self, forKey: .children) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(accessibilityLabel, forKey: .accessibilityLabel)
        try container.encodeIfPresent(accessibilityIdentifier, forKey: .accessibilityIdentifier)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(roleDescription, forKey: .roleDescription)
        try container.encodeIfPresent(valueDescription, forKey: .valueDescription)
        try container.encode(source, forKey: .source)
        try container.encode(documentRect, forKey: .documentRect)
        try container.encodeIfPresent(owningApplication, forKey: .owningApplication)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(overlayParentHierarchy, forKey: .overlayParentHierarchy)
        try container.encode(children, forKey: .children)
    }

    var displayName: String {
        name ?? accessibilityLabel ?? accessibilityIdentifier ?? roleDescription ?? role ?? "Element"
    }

    var typeLabel: String {
        roleDescription ?? role?.replacingOccurrences(of: "AX", with: "") ?? "Element"
    }

    var flattened: [UIMapElement] {
        [self] + children.flatMap(\.flattened)
    }

    var flattenedCount: Int {
        1 + children.reduce(0) { $0 + $1.flattenedCount }
    }

    var searchTokens: [String] {
        [
            name,
            accessibilityLabel,
            accessibilityIdentifier,
            role,
            roleDescription,
            valueDescription,
            owningApplication,
            bundleIdentifier,
            overlayParentHierarchy
        ].compactMap { $0 }
    }

    var isShowAllOverlayCandidate: Bool {
        if isStructuralAccessibilityRole || isShowAllOverlayDecoration {
            return false
        }

        if isTextAccessibilityRole {
            return hasMeaningfulOverlayText
        }

        if isControlAccessibilityRole {
            return true
        }

        return children.isEmpty && hasMeaningfulOverlayText
    }

    var isRecognizedTextSupplement: Bool {
        source == .ocrSupplement
    }

    func matches(searchQuery: String, roleFilter: String?) -> Bool {
        let roleMatches: Bool
        if let roleFilter, !roleFilter.isEmpty {
            roleMatches = role == roleFilter || roleDescription == roleFilter
        } else {
            roleMatches = true
        }

        guard roleMatches else {
            return false
        }

        let normalizedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return true
        }

        return searchTokens.contains {
            $0.range(of: normalizedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    func containsMatch(searchQuery: String, roleFilter: String?) -> Bool {
        matches(searchQuery: searchQuery, roleFilter: roleFilter)
            || children.contains { $0.containsMatch(searchQuery: searchQuery, roleFilter: roleFilter) }
    }

    func element(matching id: UUID) -> UIMapElement? {
        if self.id == id {
            return self
        }

        for child in children {
            if let match = child.element(matching: id) {
                return match
            }
        }

        return nil
    }

    func parentHierarchy(for id: UUID) -> [UIMapElement]? {
        if self.id == id {
            return []
        }

        for child in children {
            if let childHierarchy = child.parentHierarchy(for: id) {
                return [self] + childHierarchy
            }
        }

        return nil
    }

    private var normalizedRole: String {
        role?.lowercased() ?? ""
    }

    private var normalizedRoleDescription: String {
        roleDescription?.lowercased() ?? ""
    }

    private static func inferredSource(roleDescription: String?) -> UIMapElementSource {
        let normalizedRoleDescription = roleDescription?.lowercased() ?? ""
        if normalizedRoleDescription == "recognized text"
            || normalizedRoleDescription == "recognized text group" {
            return .ocrSupplement
        }

        return .accessibility
    }

    private var isStructuralAccessibilityRole: Bool {
        let structuralRoles = [
            "axapplication",
            "axbrowser",
            "axcell",
            "axcolumn",
            "axgroup",
            "axlayoutarea",
            "axlayoutitem",
            "axlist",
            "axoutline",
            "axrow",
            "axscrollarea",
            "axsplitgroup",
            "axtable",
            "axtabgroup",
            "axtoolbar",
            "axwindow"
        ]

        return structuralRoles.contains(normalizedRole)
            || normalizedRoleDescription == "group"
            || normalizedRoleDescription == "window"
    }

    private var isTextAccessibilityRole: Bool {
        normalizedRole == "axstatictext"
            || normalizedRole == "axtext"
            || normalizedRoleDescription == "text"
            || normalizedRoleDescription == "recognized text"
    }

    private var isShowAllOverlayDecoration: Bool {
        normalizedRole == "axvalueindicator"
            || normalizedRoleDescription.contains("value indicator")
            || normalizedRoleDescription.contains("scroll bar")
            || normalizedRoleDescription.contains("increment page")
            || normalizedRoleDescription.contains("decrement page")
    }

    private var hasMeaningfulOverlayText: Bool {
        [
            name,
            accessibilityLabel,
            accessibilityIdentifier,
            valueDescription
        ].compactMap { $0 }.contains { $0.isMeaningfulUIMapOverlayText }
    }

    private var isControlAccessibilityRole: Bool {
        let controlRoles = [
            "axbutton",
            "axcheckbox",
            "axcombobox",
            "aximage",
            "axlink",
            "axmenu",
            "axmenubaritem",
            "axmenuitem",
            "axpopbutton",
            "axpopover",
            "axradiobutton",
            "axsearchfield",
            "axslider",
            "axstatictext",
            "axswitch",
            "axtextarea",
            "axtextfield"
        ]

        return controlRoles.contains(normalizedRole)
            || normalizedRoleDescription.contains("button")
            || normalizedRoleDescription.contains("checkbox")
            || normalizedRoleDescription.contains("image")
            || normalizedRoleDescription.contains("link")
            || normalizedRoleDescription.contains("menu")
            || normalizedRoleDescription.contains("radio")
            || normalizedRoleDescription.contains("search")
            || normalizedRoleDescription.contains("slider")
            || normalizedRoleDescription.contains("text")
    }
}

private extension String {
    nonisolated var isMeaningfulUIMapOverlayText: Bool {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 1,
              value.rangeOfCharacter(from: .alphanumerics) != nil,
              !value.looksLikeInternalBundleIdentifier else {
            return false
        }

        return true
    }

    nonisolated private var looksLikeInternalBundleIdentifier: Bool {
        let lowercasedValue = lowercased()
        if lowercasedValue.contains("*") {
            return true
        }

        if lowercasedValue.hasPrefix("com.")
            || lowercasedValue.hasPrefix("org.")
            || lowercasedValue.hasPrefix("net.") {
            return true
        }

        let dotParts = lowercasedValue.split(separator: ".")
        return dotParts.count >= 3
            && dotParts.prefix(2).allSatisfy {
                $0.allSatisfy { character in
                    character.isLetter || character.isNumber || character == "-"
                }
            }
    }
}

nonisolated struct UIMapOverlayOptions: Codable, Equatable, Sendable {
    var showsOutline = true
    var outlineColor: RGBAColor? = nil
    var showsSource = false
    var showsLabel = false
    var showsAccessibilityLabel = false
    var showsIdentifier = false
    var showsRole = false
    var showsValue = false
    var showsCoordinates = false
    var showsDimensions = false
    var showsOwningApplication = false
    var showsBundleIdentifier = false
    var showsParentHierarchy = false

    init(
        showsOutline: Bool = true,
        outlineColor: RGBAColor? = nil,
        showsSource: Bool = false,
        showsLabel: Bool = false,
        showsAccessibilityLabel: Bool = false,
        showsIdentifier: Bool = false,
        showsRole: Bool = false,
        showsValue: Bool = false,
        showsCoordinates: Bool = false,
        showsDimensions: Bool = false,
        showsOwningApplication: Bool = false,
        showsBundleIdentifier: Bool = false,
        showsParentHierarchy: Bool = false
    ) {
        self.showsOutline = showsOutline
        self.outlineColor = outlineColor
        self.showsSource = showsSource
        self.showsLabel = showsLabel
        self.showsAccessibilityLabel = showsAccessibilityLabel
        self.showsIdentifier = showsIdentifier
        self.showsRole = showsRole
        self.showsValue = showsValue
        self.showsCoordinates = showsCoordinates
        self.showsDimensions = showsDimensions
        self.showsOwningApplication = showsOwningApplication
        self.showsBundleIdentifier = showsBundleIdentifier
        self.showsParentHierarchy = showsParentHierarchy
    }

    private enum CodingKeys: String, CodingKey {
        case showsOutline
        case outlineColor
        case showsSource
        case showsLabel
        case showsAccessibilityLabel
        case showsIdentifier
        case showsRole
        case showsValue
        case showsCoordinates
        case showsDimensions
        case showsOwningApplication
        case showsBundleIdentifier
        case showsParentHierarchy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsOutline = try container.decodeIfPresent(Bool.self, forKey: .showsOutline) ?? true
        outlineColor = try container.decodeIfPresent(RGBAColor.self, forKey: .outlineColor)
        showsSource = try container.decodeIfPresent(Bool.self, forKey: .showsSource) ?? false
        showsLabel = try container.decodeIfPresent(Bool.self, forKey: .showsLabel) ?? false
        showsAccessibilityLabel = try container.decodeIfPresent(Bool.self, forKey: .showsAccessibilityLabel) ?? false
        showsIdentifier = try container.decodeIfPresent(Bool.self, forKey: .showsIdentifier) ?? false
        showsRole = try container.decodeIfPresent(Bool.self, forKey: .showsRole) ?? false
        showsValue = try container.decodeIfPresent(Bool.self, forKey: .showsValue) ?? false
        showsCoordinates = try container.decodeIfPresent(Bool.self, forKey: .showsCoordinates) ?? false
        showsDimensions = try container.decodeIfPresent(Bool.self, forKey: .showsDimensions) ?? false
        showsOwningApplication = try container.decodeIfPresent(Bool.self, forKey: .showsOwningApplication) ?? false
        showsBundleIdentifier = try container.decodeIfPresent(Bool.self, forKey: .showsBundleIdentifier) ?? false
        showsParentHierarchy = try container.decodeIfPresent(Bool.self, forKey: .showsParentHierarchy) ?? false
    }
}

private extension Optional where Wrapped == String {
    nonisolated var normalizedUIMapText: String? {
        guard let value = self else {
            return nil
        }

        let normalized = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalized.isEmpty ? nil : normalized
    }
}

import CoreGraphics
import Foundation

nonisolated struct UIMapSnapshot: Codable, Equatable, Sendable {
    var capturedAt: Date
    var sourceRect: CGRect
    var elements: [UIMapElement]

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

nonisolated struct UIMapElement: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String?
    var accessibilityLabel: String?
    var accessibilityIdentifier: String?
    var role: String?
    var roleDescription: String?
    var valueDescription: String?
    var documentRect: CGRect
    var owningApplication: String?
    var bundleIdentifier: String?
    var children: [UIMapElement]

    init(
        id: UUID = UUID(),
        name: String? = nil,
        accessibilityLabel: String? = nil,
        accessibilityIdentifier: String? = nil,
        role: String? = nil,
        roleDescription: String? = nil,
        valueDescription: String? = nil,
        documentRect: CGRect,
        owningApplication: String? = nil,
        bundleIdentifier: String? = nil,
        children: [UIMapElement] = []
    ) {
        self.id = id
        self.name = name.normalizedUIMapText
        self.accessibilityLabel = accessibilityLabel.normalizedUIMapText
        self.accessibilityIdentifier = accessibilityIdentifier.normalizedUIMapText
        self.role = role.normalizedUIMapText
        self.roleDescription = roleDescription.normalizedUIMapText
        self.valueDescription = valueDescription.normalizedUIMapText
        self.documentRect = documentRect.gscIntegralStandardized
        self.owningApplication = owningApplication.normalizedUIMapText
        self.bundleIdentifier = bundleIdentifier.normalizedUIMapText
        self.children = children
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
            bundleIdentifier
        ].compactMap { $0 }
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
}

nonisolated struct UIMapOverlayOptions: Codable, Equatable, Sendable {
    var showsOutline = true
    var showsLabel = true
    var showsIdentifier = false
    var showsRole = false
    var showsCoordinates = false
    var showsDimensions = false
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

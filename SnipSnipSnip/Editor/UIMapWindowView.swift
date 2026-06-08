import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct UIMapWindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if !FeatureFlags.uiMapEnabled {
                UIMapEmptyStateView(
                    title: "UI Map Unavailable",
                    systemImage: "rectangle.3.group",
                    message: "This build does not include UI Map."
                )
            } else if let controller = model.editorController,
                      let uiMap = controller.uiMapSnapshot {
                UIMapPanelView(controller: controller, uiMap: uiMap)
            } else {
                UIMapEmptyStateView(
                    title: "No UI Map",
                    systemImage: "rectangle.3.group",
                    message: "Capture a screenshot with UI Map enabled, or open a document that already contains UI Map metadata."
                )
            }
        }
        .frame(minWidth: 360, minHeight: 480)
    }
}

private struct UIMapPanelView: View {
    @ObservedObject var controller: EditorController
    let uiMap: UIMapSnapshot
    @State private var searchQuery = ""
    @State private var roleFilter = ""

    private var visibleElements: [UIMapElement] {
        uiMap.elements.compactMap {
            filteredElement($0, searchQuery: searchQuery, roleFilter: roleFilter.isEmpty ? nil : roleFilter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            if visibleElements.isEmpty {
                UIMapEmptyStateView(
                    title: "No Matches",
                    systemImage: "magnifyingglass",
                    message: "Try a different search term or element type."
                )
            } else {
                HSplitView {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(visibleElements) { element in
                                UIMapTreeNodeView(
                                    element: element,
                                    depth: 0,
                                    searchQuery: searchQuery,
                                    roleFilter: roleFilter.isEmpty ? nil : roleFilter,
                                    selectedElementID: controller.selectedUIMapElementID,
                                    onSelect: controller.selectUIMapElement
                                )
                            }
                        }
                        .padding(10)
                    }
                    .frame(minWidth: 180)

                    details
                        .frame(minWidth: 160)
                }
            }
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search name, role, label, or identifier", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)

                Picker("Type", selection: $roleFilter) {
                    Text("All Types").tag("")
                    ForEach(uiMap.availableRoles, id: \.self) { role in
                        Text(role.replacingOccurrences(of: "AX", with: "")).tag(role)
                    }
                }
                .frame(width: 150)
            }

            HStack {
                Text("\(uiMap.elementCount) captured element\(uiMap.elementCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Export JSON...") {
                    exportUIMap()
                }
                .controlSize(.small)
                .help("Export structured UI Map metadata for debugging or review.")

                Button(controller.showsAllUIMapElements ? "Hide All" : "Show All") {
                    controller.showsAllUIMapElements.toggle()
                }
                .controlSize(.small)
                .help(controller.showsAllUIMapElements
                    ? "Hide UI Map outlines for unselected elements."
                    : "Show outlines for captured UI controls and leaf elements on the screenshot."
                )

                if controller.selectedUIMapElement != nil {
                    Button("Clear Selection") {
                        controller.selectUIMapElement(nil)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let element = controller.selectedUIMapElement {
                    Text("Selected Element")
                        .font(.headline)

                    metadataRows(for: element)

                    Divider()

                    overlayOptions
                } else {
                    UIMapEmptyStateView(
                        title: "Select an Element",
                        systemImage: "cursorarrow.click",
                        message: "Choose an item in the tree to inspect metadata and show its region on the screenshot."
                    )
                    .frame(minHeight: 220)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
    }

    private func metadataRows(for element: UIMapElement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            UIMapMetadataRow(label: "Name", value: element.name)
            UIMapMetadataRow(label: "Accessibility Label", value: element.accessibilityLabel)
            UIMapMetadataRow(label: "Accessibility Identifier", value: element.accessibilityIdentifier)
            UIMapMetadataRow(label: "Role", value: element.roleDescription ?? element.role)
            UIMapMetadataRow(label: "Value", value: element.valueDescription)
            UIMapMetadataRow(label: "Position", value: "\(Int(element.documentRect.minX)), \(Int(element.documentRect.minY))")
            UIMapMetadataRow(label: "Size", value: "\(Int(element.documentRect.width)) x \(Int(element.documentRect.height))")
            UIMapMetadataRow(label: "Owning Application", value: element.owningApplication)
            UIMapMetadataRow(label: "Bundle Identifier", value: element.bundleIdentifier)

            let hierarchy = uiMap.parentHierarchy(for: element.id)
            if !hierarchy.isEmpty {
                UIMapMetadataRow(
                    label: "Parent Hierarchy",
                    value: hierarchy.map(\.displayName).joined(separator: " > ")
                )
            }
        }
    }

    private var overlayOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display")
                .font(.subheadline.weight(.semibold))

            Toggle("Show outline", isOn: overlayBinding(\.showsOutline))
            Toggle("Show label", isOn: overlayBinding(\.showsLabel))
            Toggle("Show identifier", isOn: overlayBinding(\.showsIdentifier))
            Toggle("Show role", isOn: overlayBinding(\.showsRole))
            Toggle("Show coordinates", isOn: overlayBinding(\.showsCoordinates))
            Toggle("Show dimensions", isOn: overlayBinding(\.showsDimensions))
        }
    }

    private func overlayBinding(_ keyPath: WritableKeyPath<UIMapOverlayOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.uiMapOverlayOptions[keyPath: keyPath] },
            set: { newValue in
                var options = controller.uiMapOverlayOptions
                options[keyPath: keyPath] = newValue
                controller.uiMapOverlayOptions = options
            }
        )
    }

    private func exportUIMap() {
        let export = UIMapExportDocument(
            capture: controller.capture,
            uiMap: uiMap,
            selectedElementID: controller.selectedUIMapElementID
        )
        let panel = NSSavePanel()
        panel.title = "Export UI Map"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(sanitizedFilenameStem(controller.capture.sourceName))-UI-Map.json"

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }

        do {
            try export.jsonData().write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func sanitizedFilenameStem(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let sanitized = value
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "UI-Map" : sanitized
    }

    private func filteredElement(_ element: UIMapElement, searchQuery: String, roleFilter: String?) -> UIMapElement? {
        let filteredChildren = element.children.compactMap {
            filteredElement($0, searchQuery: searchQuery, roleFilter: roleFilter)
        }

        if element.matches(searchQuery: searchQuery, roleFilter: roleFilter) || !filteredChildren.isEmpty {
            var copy = element
            copy.children = filteredChildren
            return copy
        }

        return nil
    }
}

private struct UIMapTreeNodeView: View {
    let element: UIMapElement
    let depth: Int
    let searchQuery: String
    let roleFilter: String?
    let selectedElementID: UUID?
    let onSelect: (UUID?) -> Void
    @State private var isExpanded = true

    private var isSelected: Bool {
        selectedElementID == element.id
    }

    private var isSearchMatch: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && element.matches(searchQuery: searchQuery, roleFilter: roleFilter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if element.children.isEmpty {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)
                } else {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .frame(width: 14)
                }

                Button {
                    onSelect(element.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: iconName(for: element))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(element.displayName)
                                .font(.body)
                                .lineLimit(1)

                            Text(element.typeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, CGFloat(depth) * 14)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            if isExpanded {
                ForEach(element.children) { child in
                    UIMapTreeNodeView(
                        element: child,
                        depth: depth + 1,
                        searchQuery: searchQuery,
                        roleFilter: roleFilter,
                        selectedElementID: selectedElementID,
                        onSelect: onSelect
                    )
                }
            }
        }
    }

    private var rowBackground: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor.opacity(0.16))
        }

        if isSearchMatch {
            return AnyShapeStyle(Color.yellow.opacity(0.18))
        }

        return AnyShapeStyle(Color.clear)
    }

    private func iconName(for element: UIMapElement) -> String {
        let role = element.role ?? ""

        if role.contains("Button") {
            return "rectangle.inset.filled"
        }
        if role.contains("TextField") || role.contains("TextArea") {
            return "text.cursor"
        }
        if role.contains("CheckBox") {
            return "checkmark.square"
        }
        if role.contains("RadioButton") {
            return "largecircle.fill.circle"
        }
        if role.contains("Menu") {
            return "menucard"
        }
        if role.contains("Table") {
            return "tablecells"
        }
        if role.contains("List") {
            return "list.bullet"
        }
        if role.contains("Image") {
            return "photo"
        }
        if role.contains("Window") {
            return "macwindow"
        }

        return "rectangle.3.group"
    }
}

private struct UIMapMetadataRow: View {
    let label: String
    let value: String?

    var body: some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct UIMapEmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: 280)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

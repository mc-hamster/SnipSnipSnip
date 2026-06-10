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
            } else if model.editorController?.isProcessingUIMap == true {
                UIMapEmptyStateView(
                    title: "UI Map Processing",
                    systemImage: "hourglass",
                    message: "Window UI Map metadata is being captured in the background."
                )
            } else if let controller = model.editorController,
                      controller.capture.kind != .window {
                UIMapEmptyStateView(
                    title: "No UI Map",
                    systemImage: "rectangle.3.group",
                    message: "UI Map is available for Window captures only."
                )
            } else {
                UIMapEmptyStateView(
                    title: "No UI Map",
                    systemImage: "rectangle.3.group",
                    message: "No UI Map metadata was available for this window. Open a document that already contains UI Map metadata to inspect it."
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
    @State private var showsPinnedOnly = false
    @State private var collapsedElementIDs: Set<UUID> = []
    @FocusState private var treeHasKeyboardFocus: Bool

    private var pinnedElementIDs: Set<UUID> {
        Set(controller.snapshot.pinnedUIMapElementIDs)
    }

    private var visibleElements: [UIMapElement] {
        uiMap.elements.compactMap {
            filteredElement(
                $0,
                searchQuery: searchQuery,
                roleFilter: roleFilter.isEmpty ? nil : roleFilter,
                showsPinnedOnly: showsPinnedOnly,
                pinnedElementIDs: pinnedElementIDs
            )
        }
    }

    private var navigationEntries: [UIMapNavigationEntry] {
        visibleElements.flatMap {
            flattenedNavigationEntries(from: $0, depth: 0, parentID: nil)
        }
    }

    private var isFiltering: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !roleFilter.isEmpty
            || showsPinnedOnly
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            if visibleElements.isEmpty {
                UIMapEmptyStateView(
                    title: emptyResultsTitle,
                    systemImage: emptyResultsSystemImage,
                    message: emptyResultsMessage
                )
            } else {
                HSplitView {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(visibleElements) { element in
                                    UIMapTreeNodeView(
                                        element: element,
                                        depth: 0,
                                        searchQuery: searchQuery,
                                        roleFilter: roleFilter.isEmpty ? nil : roleFilter,
                                        selectedElementID: controller.selectedUIMapElementID,
                                        pinnedElementIDs: pinnedElementIDs,
                                        isExpanded: isExpanded(element),
                                        isFiltering: isFiltering,
                                        collapsedElementIDs: collapsedElementIDs,
                                        onSelect: selectElement,
                                        onTogglePin: controller.togglePinnedUIMapElement,
                                        onToggleExpansion: toggleExpansion
                                    )
                                    .id(element.id)
                                }
                            }
                            .padding(10)
                        }
                        .frame(minWidth: 180)
                        .focusable()
                        .focused($treeHasKeyboardFocus)
                        .onMoveCommand(perform: handleMoveCommand)
                        .onChange(of: controller.selectedUIMapElementID) { _, elementID in
                            scrollSelectedElement(elementID, using: proxy)
                        }
                        .onAppear {
                            treeHasKeyboardFocus = true
                        }
                    }

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

                Toggle("Pinned Only", isOn: $showsPinnedOnly)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Show only pinned UI Map elements in the tree, keeping parent rows for context.")

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

    private var emptyResultsTitle: String {
        showsPinnedOnly && pinnedElementIDs.isEmpty ? "No Pinned Elements" : "No Matches"
    }

    private var emptyResultsSystemImage: String {
        showsPinnedOnly && pinnedElementIDs.isEmpty ? "pin.slash" : "magnifyingglass"
    }

    private var emptyResultsMessage: String {
        if showsPinnedOnly && pinnedElementIDs.isEmpty {
            return "Pin UI Map elements from the screenshot, inspector, or this panel to show them here."
        }

        if showsPinnedOnly {
            return "No pinned elements match the current search or type filter."
        }

        return "Try a different search term or element type."
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let element = controller.selectedUIMapElement {
                    Text("Selected Element")
                        .font(.headline)

                    Button(controller.isUIMapElementPinned(element.id) ? "Unpin" : "Pin") {
                        controller.togglePinnedUIMapElement(element.id)
                    }
                    .controlSize(.small)
                    .help(controller.isUIMapElementPinned(element.id)
                        ? "Remove this UI Map overlay from copied, shared, and exported screenshots."
                        : "Keep this UI Map overlay visible in copied, shared, and exported screenshots."
                    )

                    if controller.isUIMapElementPinned(element.id) {
                        Label("Pinned overlays are included when copying, sharing, or exporting.", systemImage: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

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
            UIMapMetadataRow(
                label: "Source",
                value: element.isRecognizedTextSupplement ? "OCR supplement text" : "Accessibility element"
            )
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

    private func selectElement(_ elementID: UUID?) {
        controller.selectUIMapElement(elementID)
        treeHasKeyboardFocus = true
    }

    private func isExpanded(_ element: UIMapElement) -> Bool {
        isFiltering || !collapsedElementIDs.contains(element.id)
    }

    private func toggleExpansion(_ elementID: UUID) {
        if collapsedElementIDs.contains(elementID) {
            collapsedElementIDs.remove(elementID)
        } else {
            collapsedElementIDs.insert(elementID)
        }
    }

    private func flattenedNavigationEntries(from element: UIMapElement, depth: Int, parentID: UUID?) -> [UIMapNavigationEntry] {
        var entries = [
            UIMapNavigationEntry(
                element: element,
                depth: depth,
                parentID: parentID
            )
        ]

        guard isExpanded(element) else {
            return entries
        }

        entries += element.children.flatMap {
            flattenedNavigationEntries(from: $0, depth: depth + 1, parentID: element.id)
        }
        return entries
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        let entries = navigationEntries
        guard !entries.isEmpty else {
            return
        }

        guard let selectedElementID = controller.selectedUIMapElementID,
              let currentIndex = entries.firstIndex(where: { $0.id == selectedElementID }) else {
            selectElement(entries[0].id)
            return
        }

        switch direction {
        case .up:
            selectElement(entries[max(currentIndex - 1, 0)].id)
        case .down:
            selectElement(entries[min(currentIndex + 1, entries.count - 1)].id)
        case .left:
            moveLeft(from: entries[currentIndex])
        case .right:
            moveRight(from: entries[currentIndex], in: entries, at: currentIndex)
        @unknown default:
            break
        }
    }

    private func moveLeft(from entry: UIMapNavigationEntry) {
        if !entry.element.children.isEmpty, isExpanded(entry.element) {
            collapsedElementIDs.insert(entry.id)
            return
        }

        if let parentID = entry.parentID {
            selectElement(parentID)
        }
    }

    private func moveRight(from entry: UIMapNavigationEntry, in entries: [UIMapNavigationEntry], at index: Int) {
        guard !entry.element.children.isEmpty else {
            return
        }

        if !isExpanded(entry.element) {
            collapsedElementIDs.remove(entry.id)
            return
        }

        let nextIndex = index + 1
        if nextIndex < entries.count, entries[nextIndex].parentID == entry.id {
            selectElement(entries[nextIndex].id)
        }
    }

    private func scrollSelectedElement(_ elementID: UUID?, using proxy: ScrollViewProxy) {
        guard let elementID,
              navigationEntries.contains(where: { $0.id == elementID }) else {
            return
        }

        withAnimation(.snappy(duration: 0.12)) {
            proxy.scrollTo(elementID, anchor: .center)
        }
    }

    private func exportUIMap() {
        let export = UIMapExportDocument(
            capture: controller.capture,
            uiMap: uiMap,
            selectedElementID: controller.selectedUIMapElementID,
            pinnedElementIDs: controller.snapshot.pinnedUIMapElementIDs
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

    private func filteredElement(
        _ element: UIMapElement,
        searchQuery: String,
        roleFilter: String?,
        showsPinnedOnly: Bool,
        pinnedElementIDs: Set<UUID>
    ) -> UIMapElement? {
        let filteredChildren = element.children.compactMap {
            filteredElement(
                $0,
                searchQuery: searchQuery,
                roleFilter: roleFilter,
                showsPinnedOnly: showsPinnedOnly,
                pinnedElementIDs: pinnedElementIDs
            )
        }

        let matchesPinnedFilter = !showsPinnedOnly || pinnedElementIDs.contains(element.id)
        if (element.matches(searchQuery: searchQuery, roleFilter: roleFilter) && matchesPinnedFilter)
            || !filteredChildren.isEmpty {
            var copy = element
            copy.children = filteredChildren
            return copy
        }

        return nil
    }
}

private struct UIMapNavigationEntry: Identifiable {
    let element: UIMapElement
    let depth: Int
    let parentID: UUID?

    var id: UUID {
        element.id
    }
}

private struct UIMapTreeNodeView: View {
    let element: UIMapElement
    let depth: Int
    let searchQuery: String
    let roleFilter: String?
    let selectedElementID: UUID?
    let pinnedElementIDs: Set<UUID>
    let isExpanded: Bool
    let isFiltering: Bool
    let collapsedElementIDs: Set<UUID>
    let onSelect: (UUID?) -> Void
    let onTogglePin: (UUID) -> Void
    let onToggleExpansion: (UUID) -> Void

    private var isSelected: Bool {
        selectedElementID == element.id
    }

    private var isPinned: Bool {
        pinnedElementIDs.contains(element.id)
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
                        .foregroundStyle(element.isRecognizedTextSupplement ? Color.orange.opacity(0.8) : Color.secondary.opacity(0.45))
                        .frame(width: 14)
                } else {
                    Button {
                        onToggleExpansion(element.id)
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
                            .foregroundStyle(isSelected ? Color.accentColor : sourceColor)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(element.displayName)
                                .font(.body)
                                .lineLimit(1)

                            Text(element.typeLabel)
                                .font(.caption)
                                .foregroundStyle(element.isRecognizedTextSupplement ? Color.orange : Color.secondary)
                                .lineLimit(1)
                        }

                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(Color.orange)
                                .help("Pinned")
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
            .contextMenu {
                Button(isPinned ? "Unpin" : "Pin") {
                    onTogglePin(element.id)
                }
            }
            .id(element.id)

            if isExpanded {
                ForEach(element.children) { child in
                    UIMapTreeNodeView(
                        element: child,
                        depth: depth + 1,
                        searchQuery: searchQuery,
                        roleFilter: roleFilter,
                        selectedElementID: selectedElementID,
                        pinnedElementIDs: pinnedElementIDs,
                        isExpanded: isFiltering || !collapsedElementIDs.contains(child.id),
                        isFiltering: isFiltering,
                        collapsedElementIDs: collapsedElementIDs,
                        onSelect: onSelect,
                        onTogglePin: onTogglePin,
                        onToggleExpansion: onToggleExpansion
                    )
                }
            }
        }
    }

    private var sourceColor: Color {
        element.isRecognizedTextSupplement ? .orange : .secondary
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

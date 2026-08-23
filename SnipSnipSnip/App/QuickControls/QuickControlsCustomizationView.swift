import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

private struct QuickControlsSectionDragItem: Codable, Transferable {
    let categoryRawValue: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

struct QuickControlsCustomizationView: View {
    @ObservedObject var quickControls: QuickControlsModel
    let dismiss: () -> Void

    @State private var selectedKind: QuickControlKind?
    @State private var searchText = ""
    @State private var isConfirmingDefaultRestore = false

    var body: some View {
        VStack(spacing: 0) {
            customizationHeader

            Divider()

            HSplitView {
                controlLibrary
                    .frame(minWidth: 230, idealWidth: 260, maxWidth: 300)

                paletteDesigner
                    .frame(minWidth: 650, idealWidth: 780)
            }
        }
        .frame(minWidth: 920, minHeight: 620)
        .onAppear {
            selectedKind = selectedKind ?? quickControls.preferences.items.first?.kind
        }
        .confirmationDialog(
            "Restore the default Quick Controls layout?",
            isPresented: $isConfirmingDefaultRestore,
            titleVisibility: .visible
        ) {
            Button("Restore Default Layout", role: .destructive) {
                quickControls.restoreDefaultLayout()
                selectedKind = quickControls.preferences.items.first?.kind
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the current controls, order, presentation, and screen edge.")
        }
    }

    private var customizationHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Customize Quick Controls")
                    .font(.title2.weight(.semibold))
                Text("Changes save immediately. Arrange controls and section headers directly in the Dock Preview.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(quickControls.isVisible ? "Hide Quick Controls" : "Show Quick Controls") {
                quickControls.toggleVisibility()
            }

            Button("Close", action: dismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private var controlLibrary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Controls")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

            List {
                ForEach(filteredCatalog, id: \.category) { group in
                    Section(group.category.label) {
                        ForEach(group.kinds) { kind in
                            libraryRow(for: kind)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, prompt: "Find a Control")
            .overlay {
                if filteredCatalog.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .background(.background)
    }

    private func libraryRow(for kind: QuickControlKind) -> some View {
        let isAdded = quickControls.configuredKinds.contains(kind)

        return Button {
            if isAdded {
                removeFromLibrary(kind)
            } else {
                addFromLibrary(kind)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: kind.systemImage)
                    .frame(width: 18)
                Text(kind.label)
                    .lineLimit(2)
                Spacer(minLength: 6)
                if isAdded {
                    Text("Added")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isAdded
                ? String(localized: "Remove \(kind.label)")
                : String(localized: "Add \(kind.label)")
        )
        .accessibilityHint(
            isAdded
                ? "Remove this control from the dock."
                : "Add after the selected control."
        )
        .help(
            isAdded
                ? String(localized: "Remove \(kind.label)")
                : String(localized: "Add \(kind.label)")
        )
    }

    private func addFromLibrary(_ kind: QuickControlKind) {
        if quickControls.add(kind, after: selectedKind) {
            selectedKind = kind
        }
    }

    private func removeFromLibrary(_ kind: QuickControlKind) {
        let removedIndex = quickControls.preferences.items.firstIndex { $0.kind == kind }
        guard quickControls.remove(kind) else {
            return
        }
        guard selectedKind == kind else {
            return
        }
        if let removedIndex, !quickControls.preferences.items.isEmpty {
            selectedKind = quickControls.preferences.items[
                min(removedIndex, quickControls.preferences.items.count - 1)
            ].kind
        } else {
            selectedKind = nil
        }
    }

    private var paletteDesigner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Dock Preview")
                    .font(.headline)
                Spacer()
                Text("The dock fits its controls automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    QuickControlsDesignerCanvas(
                        quickControls: quickControls,
                        selectedKind: $selectedKind
                    )
                    .padding(28)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.separator)
                }
                .onChange(of: selectedKind) { _, kind in
                    guard let kind else {
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(kind, anchor: .center)
                    }
                }
            }

            selectedControlEditor
            dockSettingsEditor

            HStack {
                Button("Restore Default Layout") {
                    isConfirmingDefaultRestore = true
                }
                Spacer()
                Text("Drag a control or section header, or use the available Move actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private var selectedControlEditor: some View {
        GroupBox("Selected Control") {
            if let selectedKind,
               let item = quickControls.preferences.items.first(where: { $0.kind == selectedKind }) {
                let sectionItems = QuickControlsDockGrouping
                    .sections(for: quickControls.preferences.items)
                    .first(where: { $0.category == item.kind.category })?
                    .items ?? []
                let selectedIndex = sectionItems.firstIndex { $0.kind == selectedKind } ?? 0

                HStack(spacing: 12) {
                    Label(item.kind.label, systemImage: item.kind.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 150, alignment: .leading)

                    Spacer(minLength: 0)

                    Button("Move Earlier", systemImage: "arrow.left") {
                        quickControls.moveItem(selectedKind, by: -1)
                    }
                    .disabled(selectedIndex == 0)
                    .help(String(localized: "Move \(item.kind.label) Earlier"))

                    Button("Move Later", systemImage: "arrow.right") {
                        quickControls.moveItem(selectedKind, by: 1)
                    }
                    .disabled(selectedIndex == sectionItems.count - 1)
                    .help(String(localized: "Move \(item.kind.label) Later"))

                    Button("Remove", systemImage: "minus.circle", role: .destructive) {
                        removeFromLibrary(selectedKind)
                    }
                    .help(String(localized: "Remove \(item.kind.label)"))
                }
                .padding(.vertical, 2)
            } else {
                Text("Add a control from the library, or select one in the preview.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var dockSettingsEditor: some View {
        GroupBox("Dock Settings") {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Presentation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Presentation", selection: Binding(
                        get: { quickControls.preferences.resolvedDockState },
                        set: { quickControls.setDockState($0) }
                    )) {
                        ForEach(QuickControlsDockState.allCases) { state in
                            Text(state.label).tag(state)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Screen Edge")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Screen Edge", selection: Binding(
                        get: { quickControls.preferences.resolvedDockEdge },
                        set: { quickControls.setDockEdge($0) }
                    )) {
                        ForEach(QuickControlsDockEdge.allCases) { edge in
                            Text(edge.label).tag(edge)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }

    private var filteredCatalog: [(category: QuickControlCategory, kinds: [QuickControlKind])] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else {
            return quickControls.catalogByCategory
        }

        return quickControls.catalogByCategory.compactMap { group in
            let kinds = group.kinds.filter {
                $0.label.localizedCaseInsensitiveContains(trimmedSearch)
                    || group.category.label.localizedCaseInsensitiveContains(trimmedSearch)
            }
            return kinds.isEmpty ? nil : (group.category, kinds)
        }
    }
}

private struct QuickControlsDesignerCanvas: View {
    @ObservedObject var quickControls: QuickControlsModel
    @Binding var selectedKind: QuickControlKind?
    @State private var draggedControlKind: QuickControlKind?

    var body: some View {
        let size = quickControls.preferences.resolvedPanelSize
        let presentation = quickControls.preferences.resolvedDockState

        QuickControlsDockShell(
            presentation: presentation,
            edge: quickControls.preferences.resolvedDockEdge,
            status: nil,
            statusSymbol: "hourglass",
            togglePresentation: quickControls.toggleDockState
        ) {
            if quickControls.preferences.items.isEmpty {
                QuickControlsEmptyState(presentation: presentation, customize: nil)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: presentation == .expanded ? 6 : 5) {
                        ForEach(QuickControlsDockGrouping.sections(for: quickControls.preferences.items)) { section in
                            QuickControlsDesignerSection(
                                section: section,
                                presentation: presentation,
                                quickControls: quickControls,
                                selectedKind: $selectedKind,
                                draggedControlKind: $draggedControlKind
                            )
                        }
                    }
                    .padding(.horizontal, presentation == .expanded ? 8 : 3)
                    .padding(.top, QuickControlsDockMetrics.contentTopPadding)
                    .padding(.bottom, QuickControlsDockMetrics.contentBottomPadding)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(width: size.width, height: size.height)
        .environmentObject(quickControls)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Controls Dock Preview")
        .accessibilityIdentifier("quickControls.customization.preview")
    }

}

private struct QuickControlsDesignerSection: View {
    let section: QuickControlsDockSection
    let presentation: QuickControlsDockState
    @ObservedObject var quickControls: QuickControlsModel
    @Binding var selectedKind: QuickControlKind?
    @Binding var draggedControlKind: QuickControlKind?

    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: presentation == .expanded ? 6 : 5) {
            QuickControlsDockSectionHeader(
                category: section.category,
                presentation: presentation
            )
            .overlay(alignment: presentation == .expanded ? .trailing : .center) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: presentation == .expanded ? 9 : 7, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, presentation == .expanded ? 7 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .draggable(QuickControlsSectionDragItem(categoryRawValue: section.category.rawValue))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(section.category.label) Section")
            .accessibilityHint("Drag this section header to change its position.")
            .accessibilityAction(named: "Move Section Earlier") {
                quickControls.moveSection(section.category, by: -1)
            }
            .accessibilityAction(named: "Move Section Later") {
                quickControls.moveSection(section.category, by: 1)
            }
            .help("Drag \(section.category.label) Section")

            ForEach(section.items) { item in
                QuickControlsDesignerTile(
                    item: item,
                    presentation: presentation,
                    state: quickControls.tileState(for: item.kind),
                    isSelected: selectedKind == item.kind,
                    select: { selectedKind = item.kind },
                    moveRelativeToTarget: { source, insertionEdge in
                        let didMove = switch insertionEdge {
                        case .before:
                            quickControls.moveItem(source, before: item.kind)
                        case .after:
                            quickControls.moveItem(source, after: item.kind)
                        }
                        if didMove {
                            selectedKind = source
                        }
                        return didMove
                    },
                    draggedControlKind: $draggedControlKind
                )
                .id(item.kind)
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: QuickControlsSectionDragItem.self) { values, _ in
            guard let source = values.compactMap({
                QuickControlCategory(rawValue: $0.categoryRawValue)
            }).first,
                  source != section.category else {
                return false
            }
            quickControls.moveSection(source, before: section.category)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
    }

}

private enum QuickControlInsertionEdge {
    case before
    case after
}

private struct QuickControlsDesignerTile: View {
    let item: QuickControlItem
    let presentation: QuickControlsDockState
    let state: QuickControlTileState
    let isSelected: Bool
    let select: () -> Void
    let moveRelativeToTarget: (QuickControlKind, QuickControlInsertionEdge) -> Bool
    @Binding var draggedControlKind: QuickControlKind?

    @State private var insertionEdge: QuickControlInsertionEdge?

    var body: some View {
        Button(action: select) {
            QuickControlDockLabel(
                kind: item.kind,
                presentation: presentation,
                state: state
            )
        }
        .buttonStyle(QuickControlDockButtonStyle(
            presentation: presentation,
            isOn: state.isOn,
            isSelected: isSelected
        ))
        .overlay(alignment: insertionEdge == .before ? .top : .bottom) {
            if insertionEdge != nil {
                QuickControlInsertionIndicator()
                    .offset(y: insertionEdge == .before ? -4 : 4)
                    .allowsHitTesting(false)
            }
        }
        .onDrag {
            draggedControlKind = item.kind
            return NSItemProvider(object: item.kind.rawValue as NSString)
        }
        .onDrop(
            of: [.plainText],
            delegate: QuickControlTileDropDelegate(
                target: item.kind,
                targetHeight: QuickControlsDockMetrics.expandedControlHeight,
                draggedKind: $draggedControlKind,
                insertionEdge: $insertionEdge,
                moveRelativeToTarget: moveRelativeToTarget
            )
        )
        .accessibilityLabel(item.kind.label)
        .accessibilityValue(isSelected ? "Selected" : "Not Selected")
        .accessibilityHint("Select this control. Drag toward the top or bottom of another control to move it before or after.")
        .help(String(localized: "Select or Drag \(item.kind.label)"))
    }
}

private struct QuickControlInsertionIndicator: View {
    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .frame(width: 6, height: 6)
            Capsule()
                .frame(height: 3)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 3)
        .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 0, x: 0, y: 1)
        .accessibilityHidden(true)
    }
}

private struct QuickControlTileDropDelegate: DropDelegate {
    let target: QuickControlKind
    let targetHeight: CGFloat
    @Binding var draggedKind: QuickControlKind?
    @Binding var insertionEdge: QuickControlInsertionEdge?
    let moveRelativeToTarget: (QuickControlKind, QuickControlInsertionEdge) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        guard let draggedKind else {
            return false
        }
        return draggedKind != target && draggedKind.category == target.category
    }

    func dropEntered(info: DropInfo) {
        updateInsertionEdge(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            insertionEdge = nil
            return DropProposal(operation: .forbidden)
        }
        updateInsertionEdge(for: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        insertionEdge = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedKind,
              let insertionEdge,
              validateDrop(info: info) else {
            self.insertionEdge = nil
            return false
        }
        let didMove = moveRelativeToTarget(draggedKind, insertionEdge)
        self.insertionEdge = nil
        self.draggedKind = nil
        return didMove
    }

    private func updateInsertionEdge(for info: DropInfo) {
        guard validateDrop(info: info) else {
            insertionEdge = nil
            return
        }
        insertionEdge = info.location.y < targetHeight / 2 ? .before : .after
    }
}

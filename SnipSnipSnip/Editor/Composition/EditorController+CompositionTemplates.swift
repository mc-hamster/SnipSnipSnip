import CoreGraphics
import Foundation

extension EditorController {
    var compatibleCompositionTemplates: [CompositionTemplate] {
        guard let composition else { return [] }
        return compositionTemplates.filter {
            $0.isCompatible(itemCount: composition.items.count)
        }
    }

    func reloadCompositionTemplateLibrary() {
        replaceCompositionTemplateLibrary(
            CompositionTemplateStore.allTemplates(in: defaults)
        )
    }

    func applyCompositionTemplate(id: String) {
        guard var composition,
              let template = compositionTemplates.first(where: { $0.id == id }),
              template.isCompatible(itemCount: composition.items.count) else {
            errorMessage = "This composition template is not compatible with the current item count."
            return
        }

        do {
            try CompositionTemplateStore.validate(template)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        composition.layout = template.layout
        composition.canvas.appearance = template.appearance
        composition.steps = template.steps

        let targetCanvasSize = template.layout.freeformCanvasSize
            ?? normalizedFreeformCanvasSize(for: composition)
        var generatedLinkGroups: [Int: UUID] = [:]

        if !template.itemSettings.isEmpty {
            for index in composition.items.indices where template.itemSettings.indices.contains(index) {
                let settings = template.itemSettings[index]
                let linkGroupID = settings.framing.linkGroupIndex.map { groupIndex in
                    if let existing = generatedLinkGroups[groupIndex] {
                        return existing
                    }
                    let generated = UUID()
                    generatedLinkGroups[groupIndex] = generated
                    return generated
                }
                composition.items[index].framing = settings.framing.framing(
                    linkGroupID: linkGroupID
                )
                composition.items[index].weight = settings.weight
                composition.items[index].opacity = settings.opacity
                composition.items[index].zIndex = settings.zIndex
                if let normalizedFrame = settings.normalizedFreeformFrame {
                    composition.items[index].freeformFrame = CGRect(
                        x: normalizedFrame.minX * targetCanvasSize.width,
                        y: normalizedFrame.minY * targetCanvasSize.height,
                        width: normalizedFrame.width * targetCanvasSize.width,
                        height: normalizedFrame.height * targetCanvasSize.height
                    )
                } else if composition.layout.mode == .freeform {
                    composition.items[index].freeformFrame = nil
                }
            }
        } else if composition.layout.sizingMode == .equal {
            for index in composition.items.indices {
                composition.items[index].weight = 1
            }
        }

        composition.comparison = template.comparison.settings(items: composition.items)
        for index in composition.items.indices {
            switch composition.layout.mode {
            case .compare:
                if composition.items[index].id == composition.comparison.primaryItemID {
                    composition.items[index].semanticRole = .before
                } else if composition.items[index].id == composition.comparison.secondaryItemID {
                    composition.items[index].semanticRole = .after
                } else {
                    composition.items[index].semanticRole = .standard
                }
            case .steps:
                composition.items[index].semanticRole = .step
            default:
                composition.items[index].semanticRole = .standard
            }
        }

        if composition.layout.mode == .compare,
           composition.comparison.keepsViewsLinked,
           let primaryID = composition.comparison.primaryItemID,
           let secondaryID = composition.comparison.secondaryItemID,
           let primaryIndex = composition.items.firstIndex(where: { $0.id == primaryID }),
           let secondaryIndex = composition.items.firstIndex(where: { $0.id == secondaryID }),
           composition.items[primaryIndex].framing.linkGroupID == nil,
           composition.items[secondaryIndex].framing.linkGroupID == nil {
            let groupID = UUID()
            composition.items[primaryIndex].framing.linkGroupID = groupID
            composition.items[secondaryIndex].framing.linkGroupID = groupID
        }

        composition.repairComparisonSelection()
        execute(
            ApplyCompositionTemplateCommand(
                composition: composition,
                templateName: template.name
            )
        )
        showNotice("Applied \(template.name).")
    }

    @discardableResult
    func saveCurrentCompositionAsTemplate(named requestedName: String) -> String? {
        guard let composition else {
            errorMessage = "Add another capture before saving a composition template."
            return nil
        }

        do {
            let name = try uniqueCompositionTemplateName(requestedName)
            let template = makeCompositionTemplate(
                from: composition,
                id: "user.\(UUID().uuidString)",
                name: name
            )
            try CompositionTemplateStore.upsert(template, in: defaults)
            reloadCompositionTemplateLibrary()
            showNotice("Saved \(name) as a composition template.")
            return template.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func renameCompositionTemplate(id: String, name requestedName: String) {
        guard var template = compositionTemplates.first(where: { $0.id == id }),
              !template.isBuiltIn else {
            return
        }
        do {
            template.name = try uniqueCompositionTemplateName(
                requestedName,
                excluding: id
            )
            try CompositionTemplateStore.upsert(template, in: defaults)
            reloadCompositionTemplateLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func duplicateCompositionTemplate(id: String) -> String? {
        guard var template = compositionTemplates.first(where: { $0.id == id }),
              let itemCount = composition?.items.count else {
            return nil
        }
        do {
            template.id = "user.\(UUID().uuidString)"
            template.name = try uniqueCompositionTemplateName("\(template.name) Copy")
            template.source = .user
            template.itemCount = .exact(itemCount)
            template.itemSettings = Array(template.itemSettings.prefix(itemCount))
            try CompositionTemplateStore.upsert(template, in: defaults)
            reloadCompositionTemplateLibrary()
            return template.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteCompositionTemplate(id: String) {
        do {
            try CompositionTemplateStore.delete(id: id, in: defaults)
            reloadCompositionTemplateLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func compositionTemplateExportData(id: String) throws -> Data {
        guard let template = compositionTemplates.first(where: { $0.id == id }) else {
            throw CompositionTemplateStoreError.missingTemplate
        }
        return try CompositionTemplateStore.exportData(for: template)
    }

    @discardableResult
    func importCompositionTemplates(from data: Data) -> [String] {
        guard let itemCount = composition?.items.count else {
            errorMessage = "Open a composition before importing a template."
            return []
        }
        do {
            let decoded = try CompositionTemplateStore.importedTemplates(
                from: data,
                exactItemCount: itemCount
            )
            var imported: [CompositionTemplate] = []
            imported.reserveCapacity(decoded.count)
            for var template in decoded {
                template.name = try uniqueCompositionTemplateName(template.name)
                try CompositionTemplateStore.upsert(template, in: defaults)
                imported.append(template)
                // Refresh between entries so multi-template imports also receive
                // deterministic, collision-free names.
                reloadCompositionTemplateLibrary()
            }
            showNotice(imported.count == 1
                ? "Imported \(imported[0].name)."
                : "Imported \(imported.count) composition templates.")
            return imported.map(\.id)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    private func makeCompositionTemplate(
        from composition: CompositionSnapshot,
        id: String,
        name: String
    ) -> CompositionTemplate {
        let canvasSize = normalizedFreeformCanvasSize(for: composition)
        var templateLayout = composition.layout
        if templateLayout.mode == .freeform,
           templateLayout.freeformCanvasSize == nil {
            templateLayout.freeformCanvasSize = canvasSize
        }
        var linkGroupIndices: [UUID: Int] = [:]
        var nextLinkGroupIndex = 0

        let settings = composition.items.map { item in
            let linkGroupIndex = item.framing.linkGroupID.map { linkGroupID in
                if let existing = linkGroupIndices[linkGroupID] {
                    return existing
                }
                let generated = nextLinkGroupIndex
                nextLinkGroupIndex += 1
                linkGroupIndices[linkGroupID] = generated
                return generated
            }
            let normalizedFrame = item.freeformFrame.map { frame in
                CGRect(
                    x: frame.minX / canvasSize.width,
                    y: frame.minY / canvasSize.height,
                    width: frame.width / canvasSize.width,
                    height: frame.height / canvasSize.height
                )
            }
            return CompositionTemplateItemSettings(
                framing: CompositionTemplateFraming(
                    item.framing,
                    linkGroupIndex: linkGroupIndex
                ),
                weight: item.weight,
                opacity: item.opacity,
                normalizedFreeformFrame: normalizedFrame,
                zIndex: item.zIndex
            )
        }

        return CompositionTemplate(
            id: id,
            name: name,
            source: .user,
            itemCount: .exact(composition.items.count),
            layout: templateLayout,
            appearance: composition.canvas.appearance,
            comparison: CompositionTemplateComparisonSettings(
                composition.comparison,
                items: composition.items
            ),
            steps: composition.steps,
            itemSettings: settings
        )
    }

    private func normalizedFreeformCanvasSize(
        for composition: CompositionSnapshot
    ) -> CGSize {
        if let configured = composition.layout.freeformCanvasSize,
           configured.width.isFinite,
           configured.height.isFinite,
           configured.width > 0,
           configured.height > 0 {
            return configured
        }

        let union = composition.items.compactMap(\.freeformFrame).reduce(CGRect.null) {
            $0.union($1)
        }
        guard !union.isNull, union.width > 0, union.height > 0 else {
            return CGSize(width: 1_200, height: 800)
        }
        return CGSize(
            width: max(union.maxX, union.width, 1),
            height: max(union.maxY, union.height, 1)
        )
    }

    private func uniqueCompositionTemplateName(
        _ requestedName: String,
        excluding excludedID: String? = nil
    ) throws -> String {
        let baseName = try CompositionTemplateStore.normalizedName(requestedName)
        let existingNames = Set(
            compositionTemplates
                .filter { $0.id != excludedID }
                .map { $0.name.lowercased() }
        )
        guard existingNames.contains(baseName.lowercased()) else {
            return baseName
        }

        for suffix in 2...9_999 {
            let candidate = "\(baseName) \(suffix)"
            if !existingNames.contains(candidate.lowercased()) {
                return candidate
            }
        }
        throw CompositionTemplateStoreError.invalidName
    }
}

nonisolated private struct ApplyCompositionTemplateCommand: DocumentCommand {
    let composition: CompositionSnapshot
    let templateName: String

    var label: String { "Apply \(templateName) Template" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        var updated = snapshot
        updated.composition = composition
        return updated
    }
}

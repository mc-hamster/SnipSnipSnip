import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

final class CompositionTemplateStoreTests: XCTestCase {
    func testBuiltInAndExactCountCompatibilityIsDeterministic() {
        let cleanGrid = CompositionTemplateStore.builtInTemplates.first {
            $0.id == "builtin.clean-grid"
        }
        let sideBySide = CompositionTemplateStore.builtInTemplates.first {
            $0.id == "builtin.side-by-side"
        }

        XCTAssertTrue(cleanGrid?.isCompatible(itemCount: 1) == true)
        XCTAssertTrue(cleanGrid?.isCompatible(itemCount: 200) == true)
        XCTAssertFalse(sideBySide?.isCompatible(itemCount: 1) == true)
        XCTAssertTrue(sideBySide?.isCompatible(itemCount: 2) == true)

        var exact = try! XCTUnwrap(cleanGrid)
        exact.itemCount = .exact(3)
        XCTAssertFalse(exact.isCompatible(itemCount: 2))
        XCTAssertTrue(exact.isCompatible(itemCount: 3))
        XCTAssertFalse(exact.isCompatible(itemCount: 4))
    }

    func testBuiltInTemplatesAndAppearanceThemesAreVisuallyDistinct() throws {
        let templates = CompositionTemplateStore.builtInTemplates
        let clean = try XCTUnwrap(templates.first { $0.id == "builtin.clean-grid" })
        let compare = try XCTUnwrap(templates.first { $0.id == "builtin.side-by-side" })
        let steps = try XCTUnwrap(templates.first { $0.id == "builtin.numbered-steps" })
        let freeform = try XCTUnwrap(templates.first { $0.id == "builtin.freeform-board" })

        XCTAssertEqual(CompositionAppearanceTheme.allCases.count, 4)
        XCTAssertNotEqual(clean.appearance, compare.appearance)
        XCTAssertNotEqual(compare.appearance, steps.appearance)
        XCTAssertNotEqual(steps.appearance, freeform.appearance)
        XCTAssertEqual(clean.appearance, CompositionAppearanceTheme.clean.appearance)
        XCTAssertEqual(compare.appearance, CompositionAppearanceTheme.cards.appearance)
        XCTAssertEqual(steps.appearance, CompositionAppearanceTheme.documentation.appearance)
        XCTAssertEqual(freeform.appearance, CompositionAppearanceTheme.dark.appearance)
    }

    func testUserTemplateStorageAndExchangePreserveLayoutFramingAndComparisonSettings() throws {
        let suiteName = "CompositionTemplateStoreTests.roundTrip.\(UUID())"
        let defaults = makeDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var template = try XCTUnwrap(CompositionTemplateStore.builtInTemplates.first)
        template.id = "user.\(UUID())"
        template.name = "Custom layout"
        template.source = .user
        template.itemCount = .exact(2)
        template.layout = CompositionLayoutConfiguration(
            mode: .freeform, gridColumns: 2, targetAspectRatio: 1.5,
            freeformCanvasSize: CGSize(width: 900, height: 600), sizingMode: .weighted, orientation: .custom
        )
        template.appearance = CompositionAppearanceTheme.documentation.appearance
        template.appearance.captionFontName = "Helvetica"
        template.appearance.captionTextAlignment = .trailing
        template.appearance.titleTextAlignment = .center
        template.comparison.mode = .blink
        template.comparison.primaryItemIndex = 1
        template.comparison.secondaryItemIndex = 0
        template.comparison.registrationMode = .manual
        template.comparison.manualRegistrationOffset = CGSize(width: 7, height: -3)
        template.comparison.blinkInterval = 1.5
        template.comparison.blinkCrossfadeDuration = 0.2
        template.comparison.blinkLoops = false
        template.comparison.posterFrame = .primary
        template.steps = CompositionStepsSettings(
            flow: .grid, gridColumns: 2, numberingStyle: .uppercaseRoman,
            startIndex: 4, showsCaptions: false, connectorStyle: .line, itemsPerPage: 1
        )
        template.itemSettings = [0, 1].map { index in
            CompositionTemplateItemSettings(
                framing: CompositionTemplateFraming(
                    CompositionItemFraming(contentMode: .fill, scale: 1.25, offset: CGSize(width: 0.1, height: -0.2)),
                    linkGroupIndex: 0
                ),
                weight: CGFloat(index + 1), opacity: 0.75,
                normalizedFreeformFrame: CGRect(x: CGFloat(index) / 2, y: 0.1, width: 0.4, height: 0.6),
                zIndex: 1 - index
            )
        }

        try CompositionTemplateStore.upsert(template, in: defaults)
        XCTAssertEqual(CompositionTemplateStore.allTemplates(in: defaults).first { $0.id == template.id }, template)
        let exported = try CompositionTemplateStore.exportData(for: template)
        let imported = try XCTUnwrap(CompositionTemplateStore.importedTemplates(from: exported, exactItemCount: 2).first)
        XCTAssertNotEqual(imported.id, template.id)
        var expected = template
        expected.id = imported.id
        XCTAssertEqual(imported, expected)
        let destinationItems = [CompositionItem(assetID: UUID()), CompositionItem(assetID: UUID())]
        let comparison = imported.comparison.settings(items: destinationItems)
        XCTAssertEqual(comparison.primaryItemID, destinationItems[1].id)
        XCTAssertEqual(comparison.secondaryItemID, destinationItems[0].id)
    }

    func testImportedTemplateRejectsUnsafeNumberingAndGeometryBeforeApplying() throws {
        let base = try XCTUnwrap(CompositionTemplateStore.builtInTemplates.first)
        let invalidSettings: [(String, (inout CompositionTemplate) -> Void)] = [
            ("overflowing step number", { $0.steps.startIndex = Int.max }),
            ("unbounded Roman numbering", { $0.steps.startIndex = 1_000_001 }),
            ("empty page size", { $0.steps.itemsPerPage = 0 }),
            ("invalid step grid", { $0.steps.gridColumns = 0 }),
            ("unbounded canvas", { $0.layout.freeformCanvasSize = CGSize(width: 1e100, height: 600) }),
            ("unbounded aspect ratio", { $0.layout.targetAspectRatio = 1e100 }),
            ("unbounded font size", { $0.appearance.captionFontSize = 1e100 }),
            ("unbounded freeform item", { template in
                template.itemSettings = [CompositionTemplateItemSettings(
                    framing: CompositionTemplateFraming(CompositionItemFraming(), linkGroupIndex: nil),
                    weight: 1, opacity: 1,
                    normalizedFreeformFrame: CGRect(x: 1e100, y: 0, width: 1, height: 1), zIndex: 0
                )]
            }),
            ("invalid comparison opacity", { $0.comparison.overlayOpacity = 2 }),
            ("crossfade longer than interval", { $0.comparison.blinkCrossfadeDuration = 20 }),
        ]

        for (name, mutate) in invalidSettings {
            var template = base
            mutate(&template)
            // Encode the exchange directly: exportData correctly refuses these
            // values, but imported files need the same check before application.
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(template))
            let data = try JSONSerialization.data(withJSONObject: [
                "format": "com.snipsnipsnip.composition-template", "version": 1, "templates": [object],
            ])
            XCTAssertThrowsError(try CompositionTemplateStore.importedTemplates(from: data, exactItemCount: 2), name) {
                XCTAssertEqual($0 as? CompositionTemplateStoreError, .invalidTemplate, name)
            }
        }

        for start in [-1_000_000, 1_000_000] {
            var template = base
            template.steps.startIndex = start
            XCTAssertNoThrow(try CompositionTemplateStore.validate(template), "Persistable boundary values remain supported")
        }
    }

    @MainActor
    func testSavedTemplateContainsNoDocumentIdentityOrContent() throws {
        let itemID = UUID()
        let assetID = UUID()
        let linkedItemID = UUID()
        let linkedAssetID = UUID()
        let secretTitle = "Never export this title"
        let secretCaption = "Never export this caption"
        let defaults = isolatedDefaults()
        let items = [
            CompositionItem(
                id: itemID,
                assetID: assetID,
                title: secretTitle,
                caption: secretCaption
            ),
            CompositionItem(
                id: linkedItemID,
                assetID: linkedAssetID,
                title: "Second secret title",
                caption: "Second secret caption"
            ),
        ]
        let controller = makeController(
            items: items,
            defaults: defaults,
            canvasTitle: "Never export this canvas title"
        )

        let templateID = try XCTUnwrap(
            controller.saveCurrentCompositionAsTemplate(named: "Safe Structure")
        )
        let data = try controller.compositionTemplateExportData(id: templateID)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains(itemID.uuidString))
        XCTAssertFalse(json.contains(assetID.uuidString))
        XCTAssertFalse(json.contains(linkedItemID.uuidString))
        XCTAssertFalse(json.contains(linkedAssetID.uuidString))
        XCTAssertFalse(json.contains(secretTitle))
        XCTAssertFalse(json.contains(secretCaption))
        XCTAssertFalse(json.contains("Never export this canvas title"))
        XCTAssertTrue(json.contains("Safe Structure"))
    }

    @MainActor
    func testApplyingTemplatePreservesItemContentAndRegeneratesLinkIdentity() throws {
        let first = CompositionItem(
            assetID: UUID(),
            title: "Settings Before",
            caption: "Open General"
        )
        let second = CompositionItem(
            assetID: UUID(),
            title: "Settings After",
            caption: "Turn on the option"
        )
        let originalLinkID = UUID()
        var sourceItems = [first, second]
        sourceItems[0].framing = CompositionItemFraming(
            contentMode: .fill,
            horizontalAlignment: .leading,
            verticalAlignment: .top,
            scale: 1.4,
            offset: CGSize(width: 0.12, height: -0.08),
            linkGroupID: originalLinkID
        )
        sourceItems[1].framing = CompositionItemFraming(
            contentMode: .fill,
            horizontalAlignment: .leading,
            verticalAlignment: .top,
            scale: 1.4,
            offset: CGSize(width: 0.12, height: -0.08),
            linkGroupID: originalLinkID
        )
        sourceItems[0].weight = 2
        sourceItems[1].weight = 1

        let defaults = isolatedDefaults()
        let sourceController = makeController(
            items: sourceItems,
            defaults: defaults,
            layout: CompositionLayoutConfiguration(
                mode: .row,
                sizingMode: .weighted,
                orientation: .landscape
            )
        )
        let templateID = try XCTUnwrap(
            sourceController.saveCurrentCompositionAsTemplate(named: "Linked Compare")
        )

        let destinationItems = [
            CompositionItem(assetID: UUID(), title: "Destination One", caption: "Keep One"),
            CompositionItem(assetID: UUID(), title: "Destination Two", caption: "Keep Two"),
        ]
        let destinationController = makeController(
            items: destinationItems,
            defaults: defaults,
            layout: CompositionLayoutConfiguration(mode: .column)
        )
        let originalIDs = destinationController.composition!.items.map(\.id)
        let originalAssetIDs = destinationController.composition!.items.map(\.assetID)
        let originalTitles = destinationController.composition!.items.map(\.title)
        let originalCaptions = destinationController.composition!.items.map(\.caption)

        destinationController.applyCompositionTemplate(id: templateID)

        let applied = try XCTUnwrap(destinationController.composition)
        XCTAssertEqual(applied.layout.mode, .row)
        XCTAssertEqual(applied.layout.sizingMode, .weighted)
        XCTAssertEqual(applied.items.map(\.id), originalIDs)
        XCTAssertEqual(applied.items.map(\.assetID), originalAssetIDs)
        XCTAssertEqual(applied.items.map(\.title), originalTitles)
        XCTAssertEqual(applied.items.map(\.caption), originalCaptions)
        XCTAssertEqual(applied.items.map(\.weight), [2, 1])
        XCTAssertEqual(applied.items[0].framing.linkGroupID, applied.items[1].framing.linkGroupID)
        XCTAssertNotNil(applied.items[0].framing.linkGroupID)
        XCTAssertNotEqual(applied.items[0].framing.linkGroupID, originalLinkID)
    }

    @MainActor
    func testImportCreatesExactCountUserTemplateWithFreshIdentity() throws {
        let defaults = isolatedDefaults()
        let controller = makeController(
            items: (0..<3).map { _ in CompositionItem(assetID: UUID()) },
            defaults: defaults
        )
        let builtIn = try XCTUnwrap(
            CompositionTemplateStore.builtInTemplates.first {
                $0.id == "builtin.clean-grid"
            }
        )
        let data = try CompositionTemplateStore.exportData(for: builtIn)

        let importedIDs = controller.importCompositionTemplates(from: data)

        let importedID = try XCTUnwrap(importedIDs.first)
        let imported = try XCTUnwrap(
            controller.compositionTemplates.first { $0.id == importedID }
        )
        XCTAssertEqual(imported.source, .user)
        XCTAssertEqual(imported.itemCount, .exact(3))
        XCTAssertNotEqual(imported.id, builtIn.id)
        XCTAssertTrue(imported.isCompatible(itemCount: 3))
        XCTAssertFalse(imported.isCompatible(itemCount: 2))
    }

    @MainActor
    private func makeController(
        items: [CompositionItem],
        defaults: UserDefaults,
        layout: CompositionLayoutConfiguration = CompositionLayoutConfiguration(),
        canvasTitle: String? = nil
    ) -> EditorController {
        var snapshot = makeEditorSnapshot()
        var composition = CompositionSnapshot(
            items: items,
            selectedItemIDs: Array(items.prefix(1).map(\.id)),
            layout: layout
        )
        composition.canvas.title = canvasTitle ?? ""
        composition.repairComparisonSelection()
        snapshot.composition = composition
        return EditorController(
            capture: makeCapturedScreenshot(),
            session: makeEditorDocumentSession(initialSnapshot: snapshot),
            defaults: defaults,
            capabilities: testCapabilities
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "CompositionTemplateStoreTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
        return defaults
    }
}

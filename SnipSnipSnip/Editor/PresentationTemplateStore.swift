import Foundation

enum PresentationTemplateStore {
    private static let userTemplatesKey = "presentationTemplates.userTemplates"
    private static let defaultTemplateIDKey = "presentationTemplates.defaultTemplateID"

    static func allTemplates(in defaults: UserDefaults) -> [PresentationTemplate] {
        PresentationTemplate.builtInTemplates + userTemplates(in: defaults)
    }

    static func userTemplates(in defaults: UserDefaults) -> [PresentationTemplate] {
        guard let data = defaults.data(forKey: userTemplatesKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([PresentationTemplate].self, from: data)
                .filter { !$0.isBuiltIn }
        } catch {
            defaults.removeObject(forKey: userTemplatesKey)
            return []
        }
    }

    static func saveUserTemplates(_ templates: [PresentationTemplate], in defaults: UserDefaults) {
        let userTemplates = templates.filter { !$0.isBuiltIn }
        guard let data = try? JSONEncoder().encode(userTemplates) else {
            return
        }

        defaults.set(data, forKey: userTemplatesKey)
    }

    static func defaultTemplateID(in defaults: UserDefaults) -> String? {
        guard let id = defaults.string(forKey: defaultTemplateIDKey),
              allTemplates(in: defaults).contains(where: { $0.id == id }) else {
            return nil
        }

        return id
    }

    static func setDefaultTemplateID(_ id: String?, in defaults: UserDefaults) {
        guard let id else {
            defaults.removeObject(forKey: defaultTemplateIDKey)
            return
        }

        guard allTemplates(in: defaults).contains(where: { $0.id == id }) else {
            return
        }

        defaults.set(id, forKey: defaultTemplateIDKey)
    }

    static func defaultPresentation(in defaults: UserDefaults) -> ScreenshotPresentation {
        guard let id = defaultTemplateID(in: defaults),
              let template = allTemplates(in: defaults).first(where: { $0.id == id }) else {
            return .plain
        }

        return template.presentation
    }

    static func uniqueTemplateName(_ requestedName: String, existingNames: [String]) -> String {
        let base = requestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Custom Style"
            : requestedName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard existingNames.contains(base) else {
            return base
        }

        var index = 2
        while existingNames.contains("\(base) \(index)") {
            index += 1
        }

        return "\(base) \(index)"
    }
}

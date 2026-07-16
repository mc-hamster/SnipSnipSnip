import CoreGraphics
import Foundation

@MainActor
protocol GuideCommand {
    var name: String { get }
    func apply(to controller: GuideEditorController)
    func undo(on controller: GuideEditorController)
}

@MainActor
struct GuideProjectCommand: GuideCommand {
    let name: String
    let before: GuideProject
    let after: GuideProject

    func apply(to controller: GuideEditorController) { controller.replaceProjectWithoutCommand(after) }
    func undo(on controller: GuideEditorController) { controller.replaceProjectWithoutCommand(before) }
}

@MainActor
struct GuideInsertStepCommand: GuideCommand {
    let name = "Add Step"
    let step: GuideStep
    let image: CGImage
    let index: Int

    func apply(to controller: GuideEditorController) { controller.insertStepWithoutCommand(step, image: image, at: index) }
    func undo(on controller: GuideEditorController) { controller.removeStepWithoutCommand(id: step.id) }
}

@MainActor
struct GuideAdvancedEditCommand: GuideCommand {
    let name = "Advanced Edit"
    let stepID: UUID
    let before: EditableScreenshotDocument?
    let after: EditableScreenshotDocument

    func apply(to controller: GuideEditorController) { controller.replaceAdvancedEditWithoutCommand(after, stepID: stepID) }
    func undo(on controller: GuideEditorController) { controller.replaceAdvancedEditWithoutCommand(before, stepID: stepID) }
}

@MainActor
struct GuideLogoCommand: GuideCommand {
    let name = "Change Guide Logo"
    let before: CGImage?
    let after: CGImage?
    func apply(to controller: GuideEditorController) { controller.replaceLogoWithoutCommand(after) }
    func undo(on controller: GuideEditorController) { controller.replaceLogoWithoutCommand(before) }
}

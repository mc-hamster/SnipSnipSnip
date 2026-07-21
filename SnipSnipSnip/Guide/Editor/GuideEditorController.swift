import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class GuideEditorController: ObservableObject {
    @Published private(set) var project: GuideProject
    @Published private(set) var stepImages: [UUID: CGImage]
    @Published private(set) var stepThumbnails: [UUID: CGImage] = [:]
    @Published var selection: Set<UUID> = []
    @Published var searchQuery = ""
    @Published var notice: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var logoImage: CGImage?
    var mediaSegmentURLs: [UUID: URL]
    private(set) var advancedEdits: [UUID: EditableScreenshotDocument]
    @Published var advancedEditorController: EditorController?
    private var advancedEditorStepID: UUID?
    private var undoCommands: [any GuideCommand] = []
    private var redoCommands: [any GuideCommand] = []
    private var lastCommandDate = Date.distantPast
    private let documentGeneration = UUID()
    private let thumbnailLoader = GuideThumbnailLoader()
    private var thumbnailTasks: [UUID: Task<Void, Never>] = [:]
    private var imageRevisions: [UUID: Int] = [:]
    private static let maximumUndoCommands = 50

    init(document: EditableGuideDocument) {
        project = document.project
        stepImages = document.stepImages
        logoImage = document.logoImage
        mediaSegmentURLs = document.mediaSegmentURLs
        advancedEdits = document.advancedEdits
        selection = Set(document.project.steps.first.map { [$0.id] } ?? [])
        imageRevisions = Dictionary(uniqueKeysWithValues: document.project.steps.map { ($0.id, 0) })
        if let firstID = document.project.steps.first?.id {
            requestThumbnail(for: firstID, priority: .userInitiated)
            prefetchThumbnails(after: firstID)
        }
    }

    deinit {
        thumbnailTasks.values.forEach { $0.cancel() }
    }

    var selectedStep: GuideStep? { project.steps.first { selection.contains($0.id) } }
    var includedSteps: [GuideStep] { project.steps.filter { $0.isIncluded && !$0.isDeleted } }

    func requestThumbnail(for stepID: UUID, priority: TaskPriority = .utility) {
        guard stepThumbnails[stepID] == nil,
              thumbnailTasks[stepID] == nil,
              project.steps.contains(where: { $0.id == stepID }),
              let image = stepImages[stepID] else { return }
        let generation = documentGeneration
        let revision = imageRevisions[stepID, default: 0]
        thumbnailTasks[stepID] = Task(priority: priority) { @MainActor [weak self, thumbnailLoader] in
            guard !Task.isCancelled else { return }
            let thumbnail = await thumbnailLoader.thumbnail(of: image)
            guard !Task.isCancelled,
                  let self,
                  documentGeneration == generation,
                  imageRevisions[stepID] == revision,
                  project.steps.contains(where: { $0.id == stepID }) else { return }
            if let thumbnail {
                stepThumbnails[stepID] = thumbnail
            }
            thumbnailTasks[stepID] = nil
        }
    }

    func prefetchThumbnails(after stepID: UUID, count: Int = 6) {
        guard let index = project.steps.firstIndex(where: { $0.id == stepID }) else { return }
        let end = min(index + max(count, 0) + 1, project.steps.count)
        guard index + 1 < end else { return }
        for step in project.steps[(index + 1)..<end] {
            requestThumbnail(for: step.id)
        }
    }

    func editableDocument(previewImage: CGImage? = nil) -> EditableGuideDocument {
        EditableGuideDocument(project: project, stepImages: stepImages, previewImage: previewImage, logoImage: logoImage, mediaSegmentURLs: mediaSegmentURLs, advancedEdits: advancedEdits)
    }

    func update(name: String, coalescingKey: String? = nil, mutation: (inout GuideProject) -> Void) {
        let before = project
        var after = project
        mutation(&after)
        after.normalizeStepSequence()
        guard before != after else { return }
        execute(GuideProjectCommand(name: name, coalescingKey: coalescingKey, before: before, after: after))
    }

    func updateCaption(stepID: UUID, caption: String) {
        update(name: "Edit Caption", coalescingKey: "caption-\(stepID.uuidString)") { project in
            guard let index = project.steps.firstIndex(where: { $0.id == stepID }) else { return }
            project.steps[index].caption = caption
            project.steps[index].captionRevision += 1
            project.steps[index].userEditedCaption = true
        }
    }

    func reorder(from offsets: IndexSet, to destination: Int) {
        update(name: "Reorder Steps") { $0.steps.move(fromOffsets: offsets, toOffset: destination) }
    }

    func deleteSelected() {
        let ids = selection
        update(name: "Delete Steps") { project in
            for index in project.steps.indices where ids.contains(project.steps[index].id) { project.steps[index].isDeleted = true }
        }
        selection.removeAll()
    }

    func restore(stepID: UUID) { update(name: "Restore Step") { project in if let i = project.steps.firstIndex(where: { $0.id == stepID }) { project.steps[i].isDeleted = false } } }
    func setIncluded(_ included: Bool, stepID: UUID) { update(name: included ? "Include Step" : "Exclude Step") { project in if let i = project.steps.firstIndex(where: { $0.id == stepID }) { project.steps[i].isIncluded = included } } }

    func addStep(_ step: GuideStep, image: CGImage, at index: Int? = nil) {
        execute(GuideInsertStepCommand(step: step, image: image, index: index ?? project.steps.count))
    }

    func addImportedImage(_ image: CGImage, caption: String = "Review this image.", advancedEdit: EditableScreenshotDocument? = nil) {
        let size = CGSize(width: image.width, height: image.height)
        let step = GuideStep(
            sequence: project.steps.count + 1,
            eventKind: .manual,
            caption: caption,
            session: GuideStepSession(
                sourceCoordinateRect: CGRect(origin: .zero, size: size),
                sourcePixelSize: size
            )
        )
        addStep(step, image: image)
        if let advancedEdit { replaceAdvancedEditWithoutCommand(advancedEdit, stepID: step.id) }
    }

    func duplicateSelected() {
        let selected = project.steps.filter { selection.contains($0.id) }
        guard !selected.isEmpty else { return }
        var newSelection: Set<UUID> = []
        for original in selected {
            guard let image = stepImages[original.id] else { continue }
            var copy = original
            copy.id = UUID()
            copy.caption += " (Copy)"
            copy.capturedAt = Date()
            addStep(copy, image: image, at: (project.steps.firstIndex(where: { $0.id == original.id }) ?? project.steps.count) + 1)
            newSelection.insert(copy.id)
        }
        selection = newSelection
    }

    func moveSelection(by offset: Int) {
        guard !selection.isEmpty else { return }
        update(name: offset < 0 ? "Move Steps Up" : "Move Steps Down") { project in
            let indices = project.steps.indices.filter { selection.contains(project.steps[$0].id) }
            let ordered = offset < 0 ? indices : indices.reversed()
            for index in ordered {
                let destination = index + offset
                guard project.steps.indices.contains(destination), !selection.contains(project.steps[destination].id) else { continue }
                project.steps.swapAt(index, destination)
            }
        }
    }

    func setDurationForSelection(_ duration: Double) {
        let ids = selection
        update(name: "Change Step Durations") { project in
            for index in project.steps.indices where ids.contains(project.steps[index].id) {
                project.steps[index].duration = min(max(duration, 0.5), 5)
            }
        }
    }

    func beginAdvancedEdit(capabilities: AppCapabilitySnapshot) {
        guard let step = selectedStep, let image = stepImages[step.id] else { return }
        let document = advancedEdits[step.id]
        let capture = document?.capture ?? CapturedScreenshot(
            image: image,
            kind: .region,
            sourceName: "Guide Step \(step.sequence)",
            sourceRect: step.session.sourceCoordinateRect,
            capturedAt: step.capturedAt
        )
        advancedEditorController = document.map {
            EditorController(capture: $0.capture, session: $0.session, capabilities: capabilities)
        } ?? EditorController(capture: capture, capabilities: capabilities)
        advancedEditorStepID = step.id
    }

    func commitAdvancedEdit() {
        guard let editor = advancedEditorController, let stepID = advancedEditorStepID else { return }
        editor.commitPendingTextEdits()
        let document = EditableScreenshotDocument(capture: editor.capture, session: editor.documentSession)
        execute(GuideAdvancedEditCommand(stepID: stepID, before: advancedEdits[stepID], after: document))
        advancedEditorController = nil
        advancedEditorStepID = nil
    }

    func cancelAdvancedEdit() {
        advancedEditorController = nil
        advancedEditorStepID = nil
    }

    func replaceAdvancedEditWithoutCommand(_ document: EditableScreenshotDocument?, stepID: UUID) {
        advancedEdits[stepID] = document
        var updated = project
        if let index = updated.steps.firstIndex(where: { $0.id == stepID }) {
            updated.steps[index].session.annotationSessionAsset = document == nil ? nil : "advanced.sss"
        }
        replaceProjectWithoutCommand(updated)
    }

    func setLogo(_ image: CGImage?) { execute(GuideLogoCommand(before: logoImage, after: image)) }

    func updateMarker(stepID: UUID, target: CGPoint? = nil, tail: CGPoint? = nil) {
        update(name: "Move Step Marker") { project in
            guard let index = project.steps.firstIndex(where: { $0.id == stepID }),
                  var marker = project.steps[index].session.marker else { return }
            if let target { marker.target = clamped(target, to: project.steps[index].session.sourcePixelSize) }
            if let tail { marker.tail = clamped(tail, to: project.steps[index].session.sourcePixelSize) }
            project.steps[index].session.marker = marker
        }
    }

    func updateMarkerLength(stepID: UUID, length: Double) {
        update(name: "Change Marker Length", coalescingKey: "marker-length-\(stepID.uuidString)") { project in
            guard let index = project.steps.firstIndex(where: { $0.id == stepID }),
                  var marker = project.steps[index].session.marker else { return }
            let vector = CGPoint(x: marker.tail.x - marker.target.x, y: marker.tail.y - marker.target.y)
            let magnitude = max(hypot(vector.x, vector.y), 0.001)
            marker.length = length
            let requestedLength = CGFloat(length)
            marker.tail = clamped(
                CGPoint(
                    x: marker.target.x + vector.x / magnitude * requestedLength,
                    y: marker.target.y + vector.y / magnitude * requestedLength
                ),
                to: project.steps[index].session.sourcePixelSize
            )
            project.steps[index].session.marker = marker
        }
    }

    func replaceLogoWithoutCommand(_ image: CGImage?) {
        logoImage = image
        var updated = project
        updated.theme.logoAsset = image == nil ? nil : "brand/logo.png"
        replaceProjectWithoutCommand(updated)
        objectWillChange.send()
    }

    func undo() {
        guard let command = undoCommands.popLast() else { return }
        command.undo(on: self)
        redoCommands.append(command)
        lastCommandDate = .distantPast
        updateCommandState()
    }

    func redo() {
        guard let command = redoCommands.popLast() else { return }
        command.apply(to: self)
        undoCommands.append(command)
        trimUndoHistory()
        lastCommandDate = .distantPast
        updateCommandState()
    }

    func execute(_ command: any GuideCommand) {
        command.apply(to: self)
        let now = Date()
        if let incoming = command as? GuideProjectCommand,
           let key = incoming.coalescingKey,
           now.timeIntervalSince(lastCommandDate) <= 0.8,
           let previous = undoCommands.last as? GuideProjectCommand,
           previous.coalescingKey == key {
            undoCommands[undoCommands.count - 1] = GuideProjectCommand(
                name: incoming.name,
                coalescingKey: key,
                before: previous.before,
                after: incoming.after
            )
        } else {
            undoCommands.append(command)
            trimUndoHistory()
        }
        lastCommandDate = now
        redoCommands.removeAll()
        updateCommandState()
    }

    func replaceProjectWithoutCommand(_ project: GuideProject) { self.project = project }

    func insertStepWithoutCommand(_ step: GuideStep, image: CGImage, at index: Int) {
        project.steps.insert(step, at: min(max(index, 0), project.steps.count))
        stepImages[step.id] = image
        imageRevisions[step.id, default: 0] += 1
        requestThumbnail(for: step.id, priority: .userInitiated)
        project.normalizeStepSequence()
        selection = [step.id]
    }

    func removeStepWithoutCommand(id: UUID) {
        thumbnailTasks[id]?.cancel()
        thumbnailTasks[id] = nil
        imageRevisions[id, default: 0] += 1
        project.steps.removeAll { $0.id == id }
        stepImages[id] = nil
        stepThumbnails[id] = nil
        project.normalizeStepSequence()
        selection.remove(id)
    }

    private func updateCommandState() {
        canUndo = !undoCommands.isEmpty
        canRedo = !redoCommands.isEmpty
    }

    private func trimUndoHistory() {
        if undoCommands.count > Self.maximumUndoCommands {
            undoCommands.removeFirst(undoCommands.count - Self.maximumUndoCommands)
        }
    }

    private func clamped(_ point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), max(size.width, 0)),
            y: min(max(point.y, 0), max(size.height, 0))
        )
    }
}

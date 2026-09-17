import Foundation

extension VideoEditorController {
    var selectedZoom: VideoZoom? {
        session.effects.zooms.first { $0.id == selectedZoomID }
            ?? session.effects.zooms.last { $0.start <= currentTimeSeconds && currentTimeSeconds <= $0.end }
            ?? session.effects.zooms.first
    }

    func selectZoom(_ id: UUID) {
        guard let zoom = session.effects.zooms.first(where: { $0.id == id }) else { return }
        endContinuousEdit()
        selectedZoomID = id
        inspectorSection = .zooms
        scrub(to: (zoom.start + zoom.end) / 2)
    }

    func moveZoomTarget(_ id: UUID, to point: VideoPoint) {
        guard point.isFinite else { return }
        var effects = session.effects
        guard let index = effects.zooms.firstIndex(where: { $0.id == id }) else { return }
        selectedZoomID = id
        effects.zooms[index].center = point.clamped
        effects.zooms[index].followsCursor = false
        perform(.effects(effects, name: String(localized: "Move Zoom Target")))
    }

    func previewZoom(_ id: UUID) {
        guard let zoom = session.effects.zooms.first(where: { $0.id == id }) else { return }
        endContinuousEdit()
        selectedZoomID = id
        scrub(to: zoom.start)
        playTrimmedPreview()
    }
}

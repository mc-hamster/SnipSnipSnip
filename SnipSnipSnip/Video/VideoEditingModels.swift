import CoreGraphics
import Foundation

/// Times are seconds in the original media; positions are normalized, top-left/y-down.
/// Source events remain separate from all editing decisions.
nonisolated struct VideoInteractionTrack: Codable, Equatable, Sendable {
    var samples: [VideoCursorSample] = []
    var clicks: [VideoClick] = []
    var shortcuts: [VideoShortcut] = []

    func normalized(duration: Double) -> Self {
        Self(
            samples: samples.filter { $0.time.isFinite && $0.time >= 0 && $0.time <= duration && $0.position.isFinite }
                .sorted { $0.time < $1.time },
            clicks: clicks.filter { $0.time.isFinite && $0.time >= 0 && $0.time <= duration && $0.position.isFinite }
                .sorted { $0.time < $1.time },
            shortcuts: shortcuts.filter { $0.time.isFinite && $0.time >= 0 && $0.time <= duration && !$0.label.isEmpty }
                .sorted { $0.time < $1.time }
        )
    }

    func cursor(at time: Double, smooth: Bool) -> VideoPoint? {
        guard let first = samples.first, time >= first.time else { return nil }
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if samples[middle].time < time { lower = middle + 1 } else { upper = middle }
        }
        let next = samples[min(lower, samples.count - 1)]
        let previous = samples[max(lower - 1, 0)]
        if next.time <= time && !next.visible { return nil }
        // Do not interpolate across pauses, missing data, or entry/exit from the source.
        guard previous.visible, time - previous.time < 0.25 else { return nil }
        guard next.visible, next.time - previous.time < 0.25 else { return previous.position }
        let fraction = bounded((time - previous.time) / max(next.time - previous.time, 0.0001), 0...1)
        if !smooth { return previous.position.interpolated(to: next.position, fraction: fraction) }
        var sumX = 0.0, sumY = 0.0, weight = 0.0
        // A short, symmetric Gaussian window removes jitter without trailing behind clicks.
        for index in max(lower - 5, 0)..<min(lower + 6, samples.count) {
            let sample = samples[index]
            let distance = sample.time - time
            guard sample.visible, abs(distance) < 0.14 else { continue }
            let w = exp(-(distance * distance) / (2 * 0.045 * 0.045))
            sumX += sample.position.x * w
            sumY += sample.position.y * w
            weight += w
        }
        return weight > 0 ? VideoPoint(x: sumX / weight, y: sumY / weight) : previous.position
    }
}

nonisolated struct VideoPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    static let center = Self(x: 0.5, y: 0.5)
    var isFinite: Bool { x.isFinite && y.isFinite }
    var clamped: Self { Self(x: bounded(x, 0...1), y: bounded(y, 0...1)) }
    func interpolated(to other: Self, fraction: Double) -> Self {
        Self(x: x + (other.x - x) * fraction, y: y + (other.y - y) * fraction)
    }
}

nonisolated struct VideoCursorSample: Codable, Equatable, Sendable {
    var time: Double
    var position: VideoPoint
    var visible: Bool = true
}

nonisolated struct VideoClick: Codable, Equatable, Sendable {
    var time: Double
    var position: VideoPoint
}

nonisolated struct VideoShortcut: Codable, Equatable, Sendable {
    var time: Double
    var label: String
}

nonisolated struct VideoTimeRange: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var duration: Double { max(end - start, 0) }
}

nonisolated struct VideoZoom: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var scale: Double = 1.8
    var followsCursor = true
    var center: VideoPoint = .center
    var transitionDuration: Double = 0.45

    func amount(at time: Double) -> Double {
        guard time >= start, time <= end else { return 0 }
        let transition = min(transitionDuration, (end - start) / 2)
        let t = bounded(min(time - start, end - time) / max(transition, 0.001), 0...1)
        return t * t * (3 - 2 * t)
    }
}

nonisolated struct VideoEffects: Codable, Equatable, Sendable {
    var presentation: ScreenshotPresentation = .plain
    var zooms: [VideoZoom] = []
    var showsCursor = true
    var smoothsCursor = false
    var cursorScale: Double = 1
    var showsClicks = true
    var showsShortcuts = true
    var audioVolume: Double = 1
    var motionBlur: Double = 0

    func normalized(duration: Double) -> Self {
        var result = self
        result.cursorScale = bounded(cursorScale, 0.75...4)
        result.audioVolume = bounded(audioVolume, 0...2)
        result.motionBlur = bounded(motionBlur, 0...1)
        result.zooms = zooms.compactMap { zoom in
            var zoom = zoom
            zoom.start = bounded(zoom.start, 0...max(duration, 0))
            zoom.end = bounded(zoom.end, zoom.start...max(duration, zoom.start))
            zoom.scale = bounded(zoom.scale, 1...4)
            zoom.center = zoom.center.clamped
            zoom.transitionDuration = bounded(zoom.transitionDuration, 0.15...2)
            return zoom.end - zoom.start >= 0.1 ? zoom : nil
        }.sorted { $0.start < $1.start }
        return result
    }

    static func initial(for recording: CapturedVideoRecording) -> Self {
        var result = Self()
        result.showsCursor = recording.preferences.showsCursor
        result.showsClicks = recording.preferences.showsMouseClicks
        return result
    }
}

nonisolated enum VideoSmartZooms {
    static func suggest(track: VideoInteractionTrack, duration: Double) -> [VideoZoom] {
        var result: [VideoZoom] = []
        for click in track.clicks {
            let start = max(click.time - 0.7, 0)
            let end = min(click.time + 2, duration)
            guard end - start >= 0.5 else { continue }
            if let previous = result.last, start - previous.end < 0.8 {
                result[result.count - 1].end = end
            } else {
                result.append(VideoZoom(start: start, end: end, center: click.position.clamped))
            }
        }
        return result
    }
}

nonisolated enum VideoEditCommand {
    case trimStart(Double)
    case trimEnd(Double)
    case poster(Double)
    case effects(VideoEffects, name: String)
    case cut(VideoTimeRange)
    case restoreCut(UUID)
    case reset

    var name: String {
        switch self {
        case .trimStart, .trimEnd: "Trim Video"
        case .poster: "Change Preview Image"
        case .effects(_, let name): name
        case .cut: "Remove Section"
        case .restoreCut: "Restore Section"
        case .reset: "Reset Video Edits"
        }
    }

    func applying(to session: VideoEditorSession, recording: CapturedVideoRecording) -> VideoEditorSession {
        var next = session
        switch self {
        case .trimStart(let time): next.trimStartSeconds = bounded(time, 0...max(next.trimEndSeconds - 0.1, 0))
        case .trimEnd(let time): next.trimEndSeconds = bounded(time, min(next.trimStartSeconds + 0.1, recording.duration)...max(recording.duration, 0))
        case .poster(let time): next.posterTimeSeconds = time
        case .effects(let effects, _): next.effects = effects
        case .cut(let range):
            var proposed = next
            proposed.removedRanges.append(range)
            if VideoEditTimeline(session: proposed, duration: recording.duration).duration >= 0.1 { next = proposed }
        case .restoreCut(let id): next.removedRanges.removeAll { $0.id == id }
        case .reset:
            next = .fullDuration(recording.duration)
            next.effects = .initial(for: recording)
        }
        return next.normalized(for: recording.duration)
    }
}

/// One timing map is used for MP4, animated exports, and duration estimates.
nonisolated struct VideoEditTimeline: Sendable {
    let ranges: [VideoTimeRange]
    var duration: Double { ranges.reduce(0) { $0 + $1.duration } }

    init(session: VideoEditorSession, duration: Double) {
        let start = bounded(session.trimStartSeconds, 0...max(duration, 0))
        let end = bounded(session.trimEndSeconds, start...max(duration, start))
        var cursor = start
        var result: [VideoTimeRange] = []
        for cut in session.removedRanges.sorted(by: { $0.start < $1.start }) {
            let cutStart = bounded(cut.start, start...end)
            let cutEnd = bounded(cut.end, cutStart...end)
            if cutStart > cursor { result.append(VideoTimeRange(start: cursor, end: cutStart)) }
            cursor = max(cursor, cutEnd)
        }
        if cursor < end { result.append(VideoTimeRange(start: cursor, end: end)) }
        ranges = result
    }

    func sourceTime(for outputTime: Double) -> Double {
        var remaining = max(outputTime, 0)
        for range in ranges {
            if remaining < range.duration { return range.start + remaining }
            remaining -= range.duration
        }
        return ranges.last?.end ?? 0
    }
}

nonisolated private func bounded(_ value: Double, _ range: ClosedRange<Double>) -> Double {
    value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
}

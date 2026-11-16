import CoreGraphics
import Foundation

/// SVG slot coordinates are retained for framing controls; the affine map puts
/// them into the logical canvas before the renderer's preview pixel scale.
nonisolated struct PresentationSceneGeometry: Equatable {
    let localSlotRect: CGRect
    let localToLogicalCanvas: CGAffineTransform

    var logicalSlotBounds: CGRect { localSlotRect.applying(localToLogicalCanvas) }
}

nonisolated enum PresentationSceneGeometryResolver {
    static func geometry(in document: XMLDocument, canvasSize: CGSize) -> PresentationSceneGeometry? {
        guard let root = document.rootElement(), (root.localName ?? root.name)?.lowercased() == "svg",
              !containsCSSTransform(root),
              let path = pathToPrimarySlot(in: root),
              let slot = path.last,
              let x = length(slot.attribute(forName: "x")?.stringValue, default: 0),
              let y = length(slot.attribute(forName: "y")?.stringValue, default: 0),
              let width = length(slot.attribute(forName: "width")?.stringValue, default: 1),
              let height = length(slot.attribute(forName: "height")?.stringValue, default: 1),
              width > 0, height > 0,
              let rootMapping = rootMapping(root, canvasSize: canvasSize) else { return nil }

        var mapping = CGAffineTransform.identity
        for element in path.dropFirst().reversed() {
            // A nested viewport or CSS transform needs SVG layout, which this
            // coordinate resolver intentionally does not pretend to reproduce.
            guard (element.localName ?? element.name)?.lowercased() != "svg",
                  let transform = transform(element.attribute(forName: "transform")?.stringValue) else { return nil }
            mapping = mapping.concatenating(transform)
        }
        mapping = mapping.concatenating(rootMapping)
        let determinant = mapping.a * mapping.d - mapping.b * mapping.c
        guard isFinite(mapping), determinant.isFinite, abs(determinant) > 0.000000001 else { return nil }
        let localRect = CGRect(x: x, y: y, width: width, height: height)
        let bounds = localRect.applying(mapping)
        let safeCoordinateLimit = CGFloat(Int.max / 16)
        guard [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY, bounds.width, bounds.height]
            .allSatisfy({ $0.isFinite && abs($0) <= safeCoordinateLimit }) else { return nil }
        return PresentationSceneGeometry(localSlotRect: localRect,
            localToLogicalCanvas: mapping)
    }

    static func transform(_ source: String?) -> CGAffineTransform? {
        guard let source else { return .identity }
        let text = source as NSString
        var result = CGAffineTransform.identity
        var previousEnd = 0
        for match in transformPattern.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            guard separatorsOnly(text.substring(with: NSRange(location: previousEnd, length: match.range.location - previousEnd))),
                  let values = numbers(text.substring(with: match.range(at: 2))) else { return nil }
            let operation: CGAffineTransform
            switch text.substring(with: match.range(at: 1)) {
            case "matrix" where values.count == 6:
                operation = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            case "translate" where values.count == 1 || values.count == 2:
                operation = CGAffineTransform(translationX: values[0], y: values.count == 2 ? values[1] : 0)
            case "scale" where values.count == 1 || values.count == 2:
                operation = CGAffineTransform(scaleX: values[0], y: values.count == 2 ? values[1] : values[0])
            case "rotate" where values.count == 1 || values.count == 3:
                let radians = values[0] * .pi / 180
                let cosine = cos(radians), sine = sin(radians)
                let cx = values.count == 3 ? values[1] : 0
                let cy = values.count == 3 ? values[2] : 0
                operation = CGAffineTransform(a: cosine, b: sine, c: -sine, d: cosine,
                    tx: cx - cosine * cx + sine * cy, ty: cy - sine * cx - cosine * cy)
            case "skewX" where values.count == 1:
                operation = CGAffineTransform(a: 1, b: 0, c: tan(values[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewY" where values.count == 1:
                operation = CGAffineTransform(a: 1, b: tan(values[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default:
                return nil
            }
            guard isFinite(operation) else { return nil }
            // SVG lists are nested coordinate systems: translate then scale
            // means scale local points before translating them into the parent.
            result = operation.concatenating(result)
            previousEnd = NSMaxRange(match.range)
        }
        guard separatorsOnly(text.substring(from: previousEnd)), isFinite(result) else { return nil }
        return result
    }

    private static func rootMapping(_ root: XMLElement, canvasSize: CGSize) -> CGAffineTransform? {
        guard let width = length(root.attribute(forName: "width")?.stringValue, default: canvasSize.width),
              let height = length(root.attribute(forName: "height")?.stringValue, default: canvasSize.height),
              width > 0, height > 0,
              let rootTransform = transform(root.attribute(forName: "transform")?.stringValue) else { return nil }
        var viewport = CGAffineTransform.identity
        if let rawViewBox = root.attribute(forName: "viewBox")?.stringValue {
            guard let box = numbers(rawViewBox), box.count == 4, box[2] > 0, box[3] > 0 else { return nil }
            var tokens = (root.attribute(forName: "preserveAspectRatio")?.stringValue ?? "xMidYMid meet")
                .split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if tokens.first == "defer" { tokens.removeFirst() }
            let alignment = tokens.first ?? "xMidYMid"
            let scaleX = width / box[2], scaleY = height / box[3]
            if alignment == "none" {
                viewport = CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY, tx: -box[0] * scaleX, ty: -box[1] * scaleY)
            } else {
                let factors: [String: CGPoint] = [
                    "xMinYMin": CGPoint(x: 0, y: 0), "xMidYMin": CGPoint(x: 0.5, y: 0), "xMaxYMin": CGPoint(x: 1, y: 0),
                    "xMinYMid": CGPoint(x: 0, y: 0.5), "xMidYMid": CGPoint(x: 0.5, y: 0.5), "xMaxYMid": CGPoint(x: 1, y: 0.5),
                    "xMinYMax": CGPoint(x: 0, y: 1), "xMidYMax": CGPoint(x: 0.5, y: 1), "xMaxYMax": CGPoint(x: 1, y: 1),
                ]
                guard let factor = factors[alignment] else { return nil }
                let mode = tokens.count > 1 ? tokens[1] : "meet"
                guard mode == "meet" || mode == "slice", tokens.count <= 2 else { return nil }
                let scale = mode == "slice" ? max(scaleX, scaleY) : min(scaleX, scaleY)
                viewport = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                    tx: (width - box[2] * scale) * factor.x - box[0] * scale,
                    ty: (height - box[3] * scale) * factor.y - box[1] * scale)
            }
        }
        return viewport.concatenating(rootTransform)
            .concatenating(CGAffineTransform(scaleX: canvasSize.width / width, y: canvasSize.height / height))
    }

    private static func pathToPrimarySlot(in element: XMLElement) -> [XMLElement]? {
        if (element.localName ?? element.name)?.lowercased() == "image",
           element.attribute(forName: "data-sss-slot")?.stringValue == PresentationSceneStore.primaryScreenshotSlotID {
            return [element]
        }
        for child in element.children ?? [] {
            if let child = child as? XMLElement, let path = pathToPrimarySlot(in: child) { return [element] + path }
        }
        return nil
    }

    private static func containsCSSTransform(_ element: XMLElement) -> Bool {
        let css = (element.localName ?? element.name)?.lowercased() == "style" ? element.stringValue : element.attribute(forName: "style")?.stringValue
        if let css, css.lowercased().contains("transform") || css.contains("\\") { return true }
        return (element.children ?? []).contains { ($0 as? XMLElement).map(containsCSSTransform) ?? false }
    }

    static func length(_ value: String?, default fallback: CGFloat) -> CGFloat? {
        guard let value else { return fallback }
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("px") { text.removeLast(2) }
        guard let number = Double(text), number.isFinite else { return nil }
        return CGFloat(number)
    }

    private static func numbers(_ source: String) -> [CGFloat]? {
        let text = source as NSString
        var values: [CGFloat] = []
        var previousEnd = 0
        for match in numberPattern.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            guard separatorsOnly(text.substring(with: NSRange(location: previousEnd, length: match.range.location - previousEnd))),
                  let value = Double(text.substring(with: match.range)), value.isFinite else { return nil }
            values.append(CGFloat(value))
            previousEnd = NSMaxRange(match.range)
        }
        return separatorsOnly(text.substring(from: previousEnd)) ? values : nil
    }

    private static func separatorsOnly(_ source: String) -> Bool {
        source.allSatisfy { $0.isWhitespace || $0 == "," }
    }

    private static func isFinite(_ transform: CGAffineTransform) -> Bool {
        [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite)
    }

    private static let transformPattern = try! NSRegularExpression(pattern: #"([A-Za-z]+)\s*\(([^)]*)\)"#)
    private static let numberPattern = try! NSRegularExpression(pattern: #"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?"#)
}

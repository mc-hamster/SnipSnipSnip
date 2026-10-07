import CoreGraphics
import Foundation

nonisolated enum AutomationValueParser {
    static func rect(_ value: String) -> CGRect? {
        let fields = value.split(separator: ",", omittingEmptySubsequences: false)
        let parts = fields.compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard fields.count == 4, parts.count == 4, parts.allSatisfy(\.isFinite) else {
            return nil
        }

        return CGRect(
            x: parts[0],
            y: parts[1],
            width: parts[2],
            height: parts[3]
        ).gscIntegralStandardized
    }
}

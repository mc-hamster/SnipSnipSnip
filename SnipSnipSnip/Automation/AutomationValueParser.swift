import CoreGraphics
import Foundation

nonisolated enum AutomationValueParser {
    static func rect(_ value: String) -> CGRect? {
        let parts = value
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard parts.count == 4 else {
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

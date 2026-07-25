import AppKit
import Foundation

@MainActor
enum AppAccessibility {
    static func announce(_ message: String, priority: NSAccessibilityPriorityLevel = .medium) {
        guard !message.isEmpty, let application = NSApp else {
            return
        }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue,
            ]
        )
    }
}

nonisolated enum AccessibilityValueFormatter {
    static func geometry(_ rect: CGRect) -> String {
        let standardized = rect.gscIntegralStandardized
        return "x \(Int(standardized.minX)), y \(Int(standardized.minY)), width \(Int(standardized.width)), height \(Int(standardized.height))"
    }

    static func time(_ seconds: Double) -> String {
        Duration.seconds(max(seconds, 0)).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1)))
    }

    static func percentage(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    static func color(_ color: RGBAColor) -> String {
        let red = Int((color.red * 255).rounded())
        let green = Int((color.green * 255).rounded())
        let blue = Int((color.blue * 255).rounded())
        let alpha = Int((color.alpha * 100).rounded())
        return "red \(red), green \(green), blue \(blue), opacity \(alpha) percent"
    }
}

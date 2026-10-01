import SwiftUI

struct SettingsSearchNavigation: Equatable {
    let id = UUID()
    let targetID: String
}

private struct SettingsSearchNavigationKey: EnvironmentKey {
    static let defaultValue: SettingsSearchNavigation? = nil
}

extension EnvironmentValues {
    var settingsSearchNavigation: SettingsSearchNavigation? {
        get { self[SettingsSearchNavigationKey.self] }
        set { self[SettingsSearchNavigationKey.self] = newValue }
    }
}

private struct SettingsSearchTarget: ViewModifier {
    let targetID: String
    @Environment(\.settingsSearchNavigation) private var navigation
    @State private var highlighted = false

    func body(content: Content) -> some View {
        content
            .id(targetID)
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .task(id: navigation?.id) {
                highlighted = navigation?.targetID == targetID
                guard highlighted else { return }
                do {
                    try await Task.sleep(for: .seconds(2))
                    highlighted = false
                } catch { /* A new search destination supersedes this highlight. */ }
            }
    }
}

extension View {
    func settingsSearchTarget(_ targetID: String) -> some View {
        modifier(SettingsSearchTarget(targetID: targetID))
    }
}

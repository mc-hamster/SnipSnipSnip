import AppKit
import SwiftUI

/// The compact clipboard palette is an intentional alternative to the app's workspace chrome.
struct ClipboardPaletteSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }
}

struct ClipboardScopePicker: View {
    @Binding var selection: ClipboardItemFilter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(ClipboardItemFilter.allCases) { filter in
                        Button { selection = filter } label: {
                            Text(filter.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(selection == filter ? Color(nsColor: .windowBackgroundColor) : .primary)
                                .padding(.horizontal, 13)
                                .frame(height: 30)
                                .background(selection == filter ? Color.primary : Color(nsColor: .textBackgroundColor), in: Capsule())
                                .overlay(Capsule().strokeBorder(contrast == .increased ? Color.primary : .clear))
                        }
                        .buttonStyle(.plain)
                        .id(filter)
                        .accessibilityAddTraits(selection == filter ? .isSelected : [])
                        .accessibilityIdentifier("clipboard.scope.\(filter.rawValue)")
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selection) { _, value in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { proxy.scrollTo(value) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Content Type")
        .accessibilityIdentifier("clipboard.scope")
    }
}

import SwiftUI

struct ScreenshotOutputSizeControl: View {
    @ObservedObject var controller: EditorController
    let appearance: ScreenshotOutputAppearance
    @State private var isPresented = false
    @State private var widthDraft = "1200"

    private var originalSize: CGSize? { try? controller.originalOutputPixelSize(for: appearance) }
    private var outputSize: CGSize? { originalSize.flatMap { try? controller.screenshotOutputSize.pixelSize(for: $0) } }
    private var customSize: ScreenshotOutputSize? {
        guard let width = Int(widthDraft), let originalSize,
              (try? ScreenshotOutputSize.customWidth(width).pixelSize(for: originalSize)) != nil else { return nil }
        return .customWidth(width)
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label(controller.screenshotOutputSize == .original ? "Size" : controller.screenshotOutputSize.label, systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .help("Choose pixel dimensions for Copy, Export, Share, and Drag. The editable original stays unchanged.")
        .accessibilityLabel("Output Size")
        .accessibilityValue("\(controller.screenshotOutputSize.label), \(dimensions(outputSize))")
        .accessibilityIdentifier("editor.output.size")
        .popover(isPresented: $isPresented) {
            Form {
                Section("Output Size") {
                    Picker("Size", selection: Binding(get: { mode }, set: { setMode($0) })) {
                        Text("Original Size").tag(0)
                        Text("Half Size").tag(1)
                        Text("Custom Width").tag(2)
                    }
                    .pickerStyle(.radioGroup)
                    if mode == 2 || editingCustom {
                        TextField("Width (px)", text: $widthDraft)
                            .accessibilityIdentifier("editor.output.width")
                        Text("Height adjusts automatically to keep the proportions.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let customSize, let originalSize {
                            Text(dimensions(try? customSize.pixelSize(for: originalSize))).monospacedDigit()
                        } else {
                            Text("Enter a valid width within the output limits.").foregroundStyle(.secondary)
                        }
                        Button("Apply Width") {
                            if let customSize { controller.screenshotOutputSize = customSize; editingCustom = false }
                        }
                        .disabled(customSize == nil)
                    }
                    LabeledContent("Output", value: dimensions(outputSize))
                        .monospacedDigit()
                    Text("Applies to copied, exported, shared, and dragged still images. Original pixels and editable files stay unchanged. This choice lasts while this document is open.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Close") { isPresented = false }.keyboardShortcut(.cancelAction)
                }
            }
            .formStyle(.grouped)
            .frame(width: 390, height: mode == 2 || editingCustom ? 490 : 350)
        }
        .onChange(of: isPresented) { _, opened in
            if opened {
                editingCustom = false
                if case let .customWidth(width) = controller.screenshotOutputSize { widthDraft = String(width) }
                else if let outputSize { widthDraft = String(Int(outputSize.width)) }
            }
        }
    }

    @State private var editingCustom = false
    private var mode: Int {
        if editingCustom { return 2 }
        switch controller.screenshotOutputSize { case .original: return 0; case .half: return 1; case .customWidth: return 2 }
    }
    private func setMode(_ value: Int) {
        editingCustom = value == 2
        if value == 0 { controller.screenshotOutputSize = .original }
        if value == 1 { controller.screenshotOutputSize = .half }
    }
    private func dimensions(_ size: CGSize?) -> String {
        guard let size else { return String(localized: "Size unavailable") }
        return "\(Int(size.width)) × \(Int(size.height)) px"
    }
}

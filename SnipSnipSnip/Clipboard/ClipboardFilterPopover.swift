import SwiftUI

struct ClipboardFilterPopover: View {
    @Binding var time: ClipboardTimeFilter
    @Binding var source: String?
    @Binding var collection: String?
    let sources: [(label: String, value: String)]
    let collections: [String]
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Filter Clipboard History").font(.headline)
                Spacer()
                Button("Close", action: dismiss)
            }
            Form {
                Picker("When", selection: $time) {
                    ForEach(ClipboardTimeFilter.allCases) { Text($0.label).tag($0) }
                }
                Picker("Source", selection: $source) {
                    Text("All Sources").tag(String?.none)
                    ForEach(sources, id: \.value) { Text($0.label).tag(Optional($0.value)) }
                    if let source, !sources.contains(where: { $0.value == source }) {
                        Text(source).tag(Optional(source))
                    }
                }
                Picker("Collection", selection: $collection) {
                    Text("All Collections").tag(String?.none)
                    ForEach(collections, id: \.self) { Text($0).tag(Optional($0)) }
                    if let collection, !collections.contains(collection) {
                        Text(collection).tag(Optional(collection))
                    }
                }
            }
            .pickerStyle(.menu)
            Button("Reset Filters") {
                time = .all
                source = nil
                collection = nil
            }
            .disabled(time == .all && source == nil && collection == nil)
            Text("Filters apply as you choose them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 330)
    }
}

struct ClipboardActiveFilter: View {
    let title: String
    let symbol: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title).lineLimit(1)
                Image(systemName: "xmark").font(.caption2)
            }
        }
        .controlSize(.small)
        .help(String(localized: "Remove filter: \(title)"))
        .accessibilityLabel(String(localized: "Remove filter: \(title)"))
    }
}

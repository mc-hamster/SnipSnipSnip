import SwiftUI

/// A plain-language, transactional front door for capture and composition.
///
/// This view only edits `CreationWorkflowModel.draft`. Starting the selected
/// plan remains the model's responsibility, so dismissing the sheet never
/// changes a document or capture preference.
struct CreationQuickStartView: View {
    @ObservedObject var creation: CreationWorkflowModel
    @State private var isShowingMoreSources = false
    @State private var isShowingFineTuning = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker(
                        "What do you want to make?",
                        selection: goalChoice
                    ) {
                        ForEach(CreationGoalChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .accessibilityIdentifier("creation.goal")

                    Text(goalChoice.wrappedValue.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if goalChoice.wrappedValue == .instructions {
                    Section("How do you want to build it?") {
                        Picker("Method", selection: instructionMethod) {
                            if creation.isGuideCreationAvailable {
                                Text(WorkflowVocabulary.Instructions.recordGuide)
                                    .tag(InstructionCreationMethod.recordAsIWork)
                            }
                            Text(
                                WorkflowVocabulary.Instructions
                                    .buildStepsManually
                            )
                                .tag(InstructionCreationMethod.addCaptures)
                        }
                        .pickerStyle(.radioGroup)
                        .accessibilityIdentifier("creation.instructions.method")

                        Text(instructionMethodDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if creation.draft.goal != .instructions(.recordAsIWork) {
                    Section("Where will the first image come from?") {
                        Picker("Source", selection: sourceChoice) {
                            if creation.capabilities.isEnabled(.regionCapture) {
                                Text(WorkflowVocabulary.Source.region)
                                    .tag(CreationSourceChoice.region)
                            }
                            if creation.capabilities.isEnabled(.windowCapture) {
                                Text(WorkflowVocabulary.Source.window)
                                    .tag(CreationSourceChoice.window)
                            }
                            if creation.capabilities.isEnabled(.fullscreenCapture) {
                                Text(WorkflowVocabulary.Source.screen)
                                    .tag(CreationSourceChoice.screen)
                            }
                            if !creation.availableExistingSources.isEmpty {
                                Text(WorkflowVocabulary.Source.existingImage)
                                    .tag(CreationSourceChoice.addExisting)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .accessibilityIdentifier("creation.source")

                        if sourceChoice.wrappedValue == .addExisting {
                            Picker("Add from", selection: existingSource) {
                                ForEach(creation.availableExistingSources) {
                                    source in
                                    Label(
                                        source.label,
                                        systemImage: source.systemImage
                                    )
                                    .tag(source)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier(
                                "creation.source.existing"
                            )
                        }

                        if hasFineTuningSources {
                            DisclosureGroup(
                                "More ways to capture",
                                isExpanded: $isShowingMoreSources
                            ) {
                                VStack(alignment: .leading, spacing: 8) {
                                    if creation.capabilities.isEnabled(
                                        .scrollingCapture
                                    ) {
                                        fineTuningSourceButton(
                                            "Capture \(WorkflowVocabulary.Source.scrollingContent)",
                                            systemImage:
                                                "arrow.up.and.down.text.horizontal",
                                            source: .scrolling
                                        )
                                    }
                                    if creation.capabilities.isEnabled(
                                        .connectedDeviceCapture
                                    ) {
                                        fineTuningSourceButton(
                                            "Capture a \(WorkflowVocabulary.Source.connectedDevice)",
                                            systemImage: "iphone.gen3",
                                            source: .connectedDevice
                                        )
                                    }
                                    if creation.capabilities.isEnabled(
                                        .screenInspector
                                    ) {
                                        fineTuningSourceButton(
                                            String(
                                                localized:
                                                    "Use Screen Inspector"
                                            ),
                                            systemImage: "scope",
                                            source: .screenInspector
                                        )
                                    }
                                }
                                .padding(.top, 6)
                            }
                        }

                        if usesCaptureOptions {
                            DisclosureGroup(
                                "Fine-tune",
                                isExpanded: $isShowingFineTuning
                            ) {
                                VStack(alignment: .leading, spacing: 12) {
                                    if creation.draft.source
                                        .supportsCaptureDelay {
                                        Picker(
                                            "Delay",
                                            selection:
                                                $creation.draft.captureDelay
                                        ) {
                                            ForEach(CaptureDelay.allCases) {
                                                delay in
                                                Text(delay.label).tag(delay)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .accessibilityIdentifier(
                                            "creation.fineTune.delay"
                                        )
                                    }

                                    if creation.draft.source
                                        .supportsPointerCapture {
                                        Toggle(
                                            "Include Pointer",
                                            isOn:
                                                $creation.draft.includesCursor
                                        )
                                        .accessibilityIdentifier(
                                            "creation.fineTune.cursor"
                                        )
                                    }

                                    if creation.capabilities.isEnabled(
                                        .privateCapture
                                    ) {
                                        Toggle(
                                            "Private Capture",
                                            isOn:
                                                $creation.draft.privateCapture
                                        )
                                        .accessibilityIdentifier(
                                            "creation.fineTune.private"
                                        )
                                    }

                                    if creation.capabilities.isEnabled(.uiMap),
                                       creation.draft.source == .window {
                                        Toggle(
                                            "Capture UI Map",
                                            isOn:
                                                $creation.draft
                                                .windowUIMapEnabled
                                        )
                                        .accessibilityIdentifier(
                                            "creation.fineTune.uiMap"
                                        )
                                    }

                                    Text(
                                        "These choices apply only to this creation and do not change your capture defaults."
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(
                                        horizontal: false,
                                        vertical: true
                                    )
                                }
                                .padding(.top, 6)
                            }
                        }
                    }
                } else {
                    Section("What will you capture?") {
                        Label(
                            "Your Guide will ask which app, window, or screen to capture.",
                            systemImage: "list.number"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Label(
                        creation.draft.plan(
                            for: creation.capabilities
                        ).summary,
                        systemImage: goalChoice.wrappedValue.systemImage
                    )
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("creation.summary")

                    if let error = creation.startErrorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("creation.error")
                    }
                } header: {
                    Text("Ready")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 10) {
                Button("Cancel", action: creation.cancelQuickStart)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(primaryActionTitle) {
                    creation.commitQuickStart()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("creation.start")
            }
            .padding(16)
        }
        // Keep the transactional footer inside the minimum 900 × 600 editor
        // window. The grouped form scrolls when needed, while Cancel and the
        // single primary action remain visible at every supported window size.
        .frame(width: 520, height: 440)
        .accessibilityIdentifier("creation.quickStart")
    }

    private var primaryActionTitle: String {
        creation.draft.plan(for: creation.capabilities).primaryActionTitle
    }

    private var goalChoice: Binding<CreationGoalChoice> {
        Binding(
            get: { CreationGoalChoice(creation.draft.goal) },
            set: { choice in
                switch choice {
                case .screenshot:
                    creation.draft.goal = .screenshot
                case .comparison:
                    creation.draft.goal = .comparison
                case .instructions:
                    let method: InstructionCreationMethod
                    if case .instructions(let current) =
                        creation.draft.goal
                    {
                        method = current
                    } else {
                        method = creation.isGuideCreationAvailable
                            ? .recordAsIWork
                            : .addCaptures
                    }
                    creation.draft.goal = .instructions(method)
                case .combineImages:
                    creation.draft.goal = .combineImages
                }
            }
        )
    }

    private var instructionMethod: Binding<InstructionCreationMethod> {
        Binding(
            get: {
                if case .instructions(let method) = creation.draft.goal {
                    return method
                }
                return creation.isGuideCreationAvailable
                    ? .recordAsIWork
                    : .addCaptures
            },
            set: { creation.draft.goal = .instructions($0) }
        )
    }

    private var instructionMethodDetail: String {
        switch instructionMethod.wrappedValue {
        case .recordAsIWork:
            return String(
                localized:
                    "Record a Guide while you work; editable steps are created automatically."
            )
        case .addCaptures:
            return String(
                localized:
                    "Build Steps manually by capturing or importing each step, then add captions and numbering."
            )
        }
    }

    private var sourceChoice: Binding<CreationSourceChoice> {
        Binding(
            get: { CreationSourceChoice(creation.draft.source) },
            set: { choice in
                switch choice {
                case .region:
                    creation.draft.source = .region
                case .window:
                    creation.draft.source = .window
                case .screen:
                    creation.draft.source = .screen
                case .addExisting:
                    creation.draft.source = .existing(
                        creation.availableExistingSources.first ?? .files
                    )
                case .more:
                    break
                }
            }
        )
    }

    private var existingSource: Binding<CreationExistingSource> {
        Binding(
            get: {
                if case .existing(let source) = creation.draft.source,
                   creation.availableExistingSources.contains(source) {
                    return source
                }
                if case .existing(.recentSnips) = creation.draft.source,
                   creation.availableExistingSources.contains(.captureHistory) {
                    return .captureHistory
                }
                if case .existing(.archive) = creation.draft.source {
                    if creation.availableExistingSources.contains(.captureHistory) {
                        return .captureHistory
                    }
                    if creation.availableExistingSources.contains(.archive) {
                        return .archive
                    }
                }
                return creation.availableExistingSources.first ?? .files
            },
            set: { creation.draft.source = .existing($0) }
        )
    }

    private var hasFineTuningSources: Bool {
        creation.capabilities.isEnabled(.scrollingCapture)
            || creation.capabilities.isEnabled(.connectedDeviceCapture)
            || creation.capabilities.isEnabled(.screenInspector)
    }

    private var usesCaptureOptions: Bool {
        switch creation.draft.source {
        case .existing:
            return false
        case .region, .window, .screen, .scrolling,
             .connectedDevice, .screenInspector:
            return true
        }
    }

    private func fineTuningSourceButton(
        _ title: String,
        systemImage: String,
        source: CreationSource
    ) -> some View {
        Button {
            creation.draft.source = source
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if creation.draft.source == source {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(
            creation.draft.source == source
                ? String(localized: "Selected")
                : String(localized: "Not selected")
        )
    }
}

private enum CreationGoalChoice: String, CaseIterable, Identifiable {
    case screenshot
    case comparison
    case instructions
    case combineImages

    var id: String { rawValue }

    init(_ goal: CreationGoal) {
        switch goal {
        case .screenshot:
            self = .screenshot
        case .comparison:
            self = .comparison
        case .instructions:
            self = .instructions
        case .combineImages:
            self = .combineImages
        }
    }

    var label: String {
        switch self {
        case .screenshot:
            return String(localized: "Capture a screenshot")
        case .comparison:
            return String(localized: "Compare two versions")
        case .instructions:
            return String(localized: "Explain a process")
        case .combineImages:
            return String(localized: "Combine images")
        }
    }

    var detail: String {
        switch self {
        case .screenshot:
            return String(
                localized: "Capture, mark up, and share one image."
            )
        case .comparison:
            return String(
                localized:
                    "Show Before and After together or highlight what changed."
            )
        case .instructions:
            return String(
                localized:
                    "Record a Guide or build numbered Steps manually."
            )
        case .combineImages:
            return String(
                localized:
                    "Arrange several captures and images as one result."
            )
        }
    }

    var systemImage: String {
        switch self {
        case .screenshot:
            return "camera.viewfinder"
        case .comparison:
            return "rectangle.split.2x1"
        case .instructions:
            return "list.number"
        case .combineImages:
            return "rectangle.3.group"
        }
    }
}

private enum CreationSourceChoice: String, CaseIterable, Identifiable {
    case region
    case window
    case screen
    case addExisting
    case more

    var id: String { rawValue }

    init(_ source: CreationSource) {
        switch source {
        case .region:
            self = .region
        case .window:
            self = .window
        case .screen:
            self = .screen
        case .existing:
            self = .addExisting
        case .scrolling, .connectedDevice, .screenInspector:
            self = .more
        }
    }
}

private extension CreationExistingSource {
    var label: String {
        switch self {
        case .files:
            return String(localized: "Files")
        case .clipboard:
            return String(localized: "Clipboard")
        case .recentSnips:
            return WorkflowVocabulary.Library.recentSnips
        case .captureHistory:
            return WorkflowVocabulary.Library.snipLibrary
        case .archive:
            return WorkflowVocabulary.Library.snipLibrary
        }
    }

    var systemImage: String {
        switch self {
        case .files:
            return "photo.on.rectangle.angled"
        case .clipboard:
            return "doc.on.clipboard"
        case .recentSnips:
            return "clock"
        case .captureHistory:
            return "clock.arrow.circlepath"
        case .archive:
            return "archivebox"
        }
    }
}

struct CreationExistingSourcePickerView: View {
    let sourceTitle: String
    let recentEntries: [DocumentHistoryEntry]
    let historyEntries: [DocumentHistoryEntry]
    let onChoose: (DocumentHistoryEntry, Bool) -> Void
    let onCancel: () -> Void
    @State private var selectedEntryID: UUID?
    @State private var libraryScope = CreationExistingSourceScope.recent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(sourceTitle)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "Choose the exact capture to use. Editable keeps its source items and annotations; Image uses only its rendered preview."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            if !recentEntries.isEmpty && !historyEntries.isEmpty {
                Picker(
                    WorkflowVocabulary.Library.snipLibrary,
                    selection: $libraryScope
                ) {
                    Text(WorkflowVocabulary.Library.recentSnips)
                        .tag(CreationExistingSourceScope.recent)
                    Text(WorkflowVocabulary.Library.snipHistory)
                        .tag(CreationExistingSourceScope.history)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .onChange(of: libraryScope) {
                    selectedEntryID = nil
                }
            }

            Divider()

            if visibleEntries.isEmpty {
                ContentUnavailableView(
                    "Nothing Available",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(
                        "There are no Snip Library items yet."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleEntries, selection: $selectedEntryID) { entry in
                    HStack(spacing: 12) {
                        DocumentPreviewThumbnailView(
                            packageURL: entry.packageURL,
                            thumbnailSize: CGSize(
                                width: 96,
                                height: 64
                            ),
                            cornerRadius: 8
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            Text(
                                entry.savedAt.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text(entry.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)
                    }
                    .padding(.vertical, 4)
                    .tag(entry.id)
                    .accessibilityLabel(entry.title)
                    .accessibilityValue(
                        entry.id == selectedEntryID
                            ? "Selected"
                            : "Not selected"
                    )
                    .accessibilityIdentifier(
                        "creation.existing.entry.\(entry.id.uuidString)"
                    )
                }
                .accessibilityIdentifier("creation.existing.list")
            }

            Divider()

            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Use as Image") {
                    choose(flattened: true)
                }
                .disabled(selectedEntry == nil)

                Button("Use Editable Capture") {
                    choose(flattened: false)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedEntry == nil)
            }
            .padding(16)
        }
        .frame(width: 580, height: 520)
        .accessibilityIdentifier("creation.existing.picker")
    }

    private var selectedEntry: DocumentHistoryEntry? {
        guard let selectedEntryID else {
            return nil
        }
        return visibleEntries.first { $0.id == selectedEntryID }
    }

    private var visibleEntries: [DocumentHistoryEntry] {
        if recentEntries.isEmpty {
            return historyEntries
        }
        if historyEntries.isEmpty {
            return recentEntries
        }
        return libraryScope == .recent ? recentEntries : historyEntries
    }

    private func choose(flattened: Bool) {
        guard let selectedEntry else {
            return
        }
        onChoose(selectedEntry, flattened)
    }
}

private enum CreationExistingSourceScope: String, Hashable {
    case recent
    case history
}

struct CreationConnectedDevicePickerView: View {
    let devices: [ConnectedAppleDevice]
    let isLoading: Bool
    let emptyStateMessage: String
    let onRefresh: () -> Void
    let onChoose: (ConnectedAppleDevice) -> Void
    let onCancel: () -> Void
    @State private var selectedDeviceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Choose a Connected Device")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "Choose the exact iPhone or iPad to capture for this result."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            Group {
                if isLoading, devices.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for connected devices…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                } else if devices.isEmpty {
                    ContentUnavailableView(
                        "No Connected Devices",
                        systemImage: "iphone.slash",
                        description: Text(emptyStateMessage)
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                } else {
                    List(devices, selection: $selectedDeviceID) {
                        device in
                        HStack(spacing: 12) {
                            Image(systemName: "iphone.gen3")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                                .frame(width: 34)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name)
                                    .font(
                                        .subheadline.weight(.semibold)
                                    )
                                if let modelName = device.modelName,
                                   !modelName.isEmpty,
                                   modelName != device.name {
                                    Text(modelName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .tag(device.id)
                        .accessibilityIdentifier(
                            "creation.device.\(device.id)"
                        )
                    }
                    .accessibilityIdentifier("creation.device.list")
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Refresh", action: onRefresh)
                    .disabled(isLoading)

                Spacer()

                Button("Use Device") {
                    guard let selectedDevice else {
                        return
                    }
                    onChoose(selectedDevice)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedDevice == nil)
            }
            .padding(16)
        }
        .frame(width: 500, height: 430)
        .accessibilityIdentifier("creation.device.picker")
        .onAppear(perform: onRefresh)
    }

    private var selectedDevice: ConnectedAppleDevice? {
        guard let selectedDeviceID else {
            return nil
        }
        return devices.first { $0.id == selectedDeviceID }
    }
}

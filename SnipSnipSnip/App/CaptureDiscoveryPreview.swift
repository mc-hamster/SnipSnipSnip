import SwiftUI

enum CaptureDiscoveryItem: String, Hashable {
    case overview
    case captureRegion
    case captureWindow
    case captureScreen
    case captureScrolling
    case repeatLast
    case presets
    case comparison
    case steps
    case combinedImage
    case recordRegion
    case recordWindow
    case recordScreen
    case guide
    case connectedDevice
    case screenRuler
    case screenInspector
    case clipboardHistory
    case timer
    case cursor
    case privateCapture

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Capture it. Explain it. Present it."
        case .captureRegion: "Capture a Region"
        case .captureWindow: "Capture a Window"
        case .captureScreen: "Capture a Screen"
        case .captureScrolling: "Capture Scrolling Content"
        case .repeatLast: "Repeat Last Capture"
        case .presets: "Run a Capture Preset"
        case .comparison: "Create a Comparison"
        case .steps: "Create Steps"
        case .combinedImage: "Create a Combined Image"
        case .recordRegion: "Record a Region"
        case .recordWindow: "Record a Window"
        case .recordScreen: "Record a Screen"
        case .guide: "Record a Guide"
        case .connectedDevice: "Record a Connected Device"
        case .screenRuler: "Measure with Screen Rulers"
        case .screenInspector: "Inspect the Screen"
        case .clipboardHistory: "Open Clipboard History"
        case .timer: "Set a Capture Timer"
        case .cursor: "Include the Cursor"
        case .privateCapture: "Use Private Capture"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .overview:
            "Point to an action to see what it creates or opens."
        case .captureRegion:
            "Drag around anything to create an editable Screenshot."
        case .captureWindow:
            "Choose a window and capture it without the surrounding desktop."
        case .captureScreen:
            "Capture the configured screen or all connected displays."
        case .captureScrolling:
            "Collect content beyond the visible viewport as one Screenshot."
        case .repeatLast:
            "Run the previous capture again when its source is still available."
        case .presets:
            "Reuse a saved target, timer, cursor, and output workflow."
        case .comparison:
            "Capture Before and After, then reveal what changed."
        case .steps:
            "Build an ordered, captioned sequence of screenshots."
        case .combinedImage:
            "Arrange several captures or images as one result."
        case .recordRegion:
            "Record activity inside a selected area of the screen."
        case .recordWindow:
            "Choose one window and record its activity as Video."
        case .recordScreen:
            "Record a complete screen, then trim and export the Video."
        case .guide:
            "Capture your actions and turn them into editable instructions."
        case .connectedDevice:
            "Open a live iPhone or iPad preview and record its screen."
        case .screenRuler:
            "Place horizontal or vertical pixel rulers above other apps."
        case .screenInspector:
            "Magnify pixels, sample colors, and measure spacing without taking a screenshot."
        case .clipboardHistory:
            "Find copied text, links, files, images, and recent screenshots."
        case .timer:
            "Wait before capture so you can prepare menus or pointer position."
        case .cursor:
            "Add the pointer as an editable overlay where capture supports it."
        case .privateCapture:
            "Keep new captures out of history, recovery, Clipboard History, and OCR indexing."
        }
    }

    var shortcut: String? {
        switch self {
        case .captureRegion: "⌘⇧1"
        case .captureWindow: "⌘⇧2"
        case .captureScreen: "⌘⇧3"
        case .repeatLast: "⌘⇧7"
        case .guide: "⌘⇧9"
        case .screenInspector: "⌘⇧8"
        case .clipboardHistory: "⌘⇧V"
        default: nil
        }
    }

    var illustrationKind: CaptureDiscoveryIllustration.Kind {
        switch self {
        case .overview: .overview
        case .captureRegion: .captureRegion
        case .captureWindow: .captureWindow
        case .captureScreen: .captureScreen
        case .captureScrolling: .scroll
        case .repeatLast: .repeatLast
        case .presets: .presets
        case .comparison: .comparison
        case .steps: .steps
        case .combinedImage: .combined
        case .recordRegion: .recordRegion
        case .recordWindow: .recordWindow
        case .recordScreen: .recordScreen
        case .guide: .guide
        case .connectedDevice: .device
        case .screenRuler: .ruler
        case .screenInspector: .inspector
        case .clipboardHistory: .clipboard
        case .timer: .timer
        case .cursor: .cursor
        case .privateCapture: .privacy
        }
    }
}

struct CaptureDiscoveryPreview: View {
    let item: CaptureDiscoveryItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GroupBox {
            VStack(spacing: 12) {
                CaptureDiscoveryIllustration(
                    kind: item.illustrationKind,
                    animates: !reduceMotion
                )
                .frame(maxWidth: .infinity, minHeight: 142, maxHeight: 142)

                VStack(spacing: 5) {
                    Text(item.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    Text(item.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if let shortcut = item.shortcut {
                        Text(shortcut)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(item.title))
        .accessibilityHint(Text(item.detail))
        .id(item)
        .transition(.opacity)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: item
        )
    }
}

struct CaptureDiscoveryIllustration: View {
    enum Kind: Hashable {
        case overview
        case captureRegion
        case captureWindow
        case captureScreen
        case scroll
        case repeatLast
        case presets
        case comparison
        case steps
        case combined
        case recordRegion
        case recordWindow
        case recordScreen
        case guide
        case device
        case ruler
        case inspector
        case clipboard
        case timer
        case cursor
        case privacy
    }

    let kind: Kind
    let animates: Bool
    @State private var progress: CGFloat = 0

    private let accent = Color.accentColor

    var body: some View {
        ZStack {
            switch kind {
            case .overview:
                overview
            case .captureRegion:
                captureRegion
            case .captureWindow:
                captureWindow
            case .captureScreen:
                captureScreen
            case .scroll:
                scroll
            case .repeatLast:
                repeatLast
            case .presets:
                presets
            case .comparison:
                comparison
            case .steps:
                steps
            case .combined:
                combined
            case .recordRegion:
                recordRegion
            case .recordWindow:
                recordWindow
            case .recordScreen:
                recordScreen
            case .guide:
                guide
            case .device:
                device
            case .ruler:
                ruler
            case .inspector:
                inspector
            case .clipboard:
                clipboard
            case .timer:
                timer
            case .cursor:
                cursor
            case .privacy:
                privacy
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
        }
        .onAppear {
            guard animates else {
                progress = 1
                return
            }
            withAnimation(.easeInOut(duration: 0.72)) {
                progress = 1
            }
        }
        .accessibilityHidden(true)
    }

    private var overview: some View {
        HStack(spacing: 12) {
            discoveryCard(title: "Screenshot", systemImage: "viewfinder")
                .offset(y: (1 - progress) * 14)
            discoveryCard(title: "Steps", systemImage: "list.number")
                .offset(y: (1 - progress) * 22)
            discoveryCard(title: "Video", systemImage: "record.circle")
                .offset(y: (1 - progress) * 30)
        }
        .opacity(0.35 + progress * 0.65)
    }

    private var captureRegion: some View {
        ZStack {
            desktopBackdrop
            RoundedRectangle(cornerRadius: 4)
                .stroke(accent, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                .frame(
                    width: 52 + progress * 92,
                    height: 30 + progress * 48
                )
                .overlay {
                    selectionHandles
                }
                .offset(x: 12, y: 5)
            Image(systemName: "cursorarrow")
                .font(.title3)
                .foregroundStyle(.primary)
                .offset(
                    x: -72 + progress * 128,
                    y: -42 + progress * 76
                )
            metricBadge("640 × 420")
                .offset(x: 58, y: 50)
                .opacity(progress)
        }
    }

    private var captureWindow: some View {
        ZStack {
            appWindow(tint: Color.secondary.opacity(0.18))
                .offset(x: -54, y: 18)
                .opacity(0.6)
            appWindow(tint: accent.opacity(0.18))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(accent, lineWidth: 2)
                }
                .offset(x: -5 + progress * 44, y: 9 - progress * 22)
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(accent)
                .offset(x: 90, y: -45)
                .scaleEffect(0.6 + progress * 0.4)
        }
    }

    private var captureScreen: some View {
        ZStack {
            monitorFrame
            Rectangle()
                .fill(accent.opacity(0.28))
                .frame(width: 205, height: 3)
                .offset(y: -43 + progress * 82)
                .clipShape(.rect(cornerRadius: 8))
            HStack(spacing: 5) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text("Entire screen")
                    .font(.caption2.weight(.medium))
            }
            .offset(x: -60, y: -45)
        }
    }

    private var scroll: some View {
        ZStack {
            appWindow(tint: Color.secondary.opacity(0.1))
                .offset(x: -42)
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent, lineWidth: 2)
                .frame(width: 112, height: 92)
                .offset(x: -42)
            VStack(spacing: 7) {
                ForEach(0..<8, id: \.self) { index in
                    Capsule()
                        .fill(index == 2 ? accent.opacity(0.8) : Color.secondary.opacity(0.25))
                        .frame(width: index.isMultiple(of: 2) ? 76 : 56, height: 5)
                }
            }
            .offset(x: -42, y: 20 - progress * 37)
            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(index == 1 ? accent.opacity(0.25) : Color.secondary.opacity(0.12))
                        .frame(width: 62, height: 31)
                }
            }
            .offset(x: 82)
            Image(systemName: "arrow.right")
                .foregroundStyle(accent)
                .offset(x: 25)
                .opacity(progress)
        }
    }

    private var repeatLast: some View {
        HStack(spacing: 22) {
            resultThumbnail(label: "Last")
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(accent)
                .rotationEffect(.degrees(-135 + progress * 135))
            resultThumbnail(label: "New")
                .opacity(0.2 + progress * 0.8)
                .scaleEffect(0.82 + progress * 0.18)
        }
    }

    private var presets: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 11) {
                sliderRow(icon: "timer", offset: -18 + progress * 18)
                sliderRow(icon: "cursorarrow", offset: 12 - progress * 12)
                sliderRow(icon: "folder", offset: -10 + progress * 10)
            }
            .offset(x: -58)
            Image(systemName: "arrow.right")
                .foregroundStyle(accent)
                .offset(x: 18)
                .opacity(progress)
            RoundedRectangle(cornerRadius: 10)
                .fill(accent.opacity(0.15))
                .frame(width: 86, height: 96)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "star.fill").foregroundStyle(accent)
                        Text("Daily Capture").font(.caption2.weight(.semibold))
                        Text("PNG • Desktop").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
                .offset(x: 78)
                .scaleEffect(0.82 + progress * 0.18)
        }
    }

    private var comparison: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.13))
                .frame(width: 230, height: 112)
                .overlay(alignment: .topLeading) {
                    Text("BEFORE")
                        .font(.system(size: 8, weight: .bold))
                        .padding(7)
                }
                .overlay(alignment: .topTrailing) {
                    Text("AFTER")
                        .font(.system(size: 8, weight: .bold))
                        .padding(7)
                }
            Rectangle()
                .fill(accent.opacity(0.22))
                .frame(width: 115, height: 112)
                .clipShape(.rect(cornerRadius: 8))
                .offset(x: 57)
            Rectangle()
                .fill(accent)
                .frame(width: 2, height: 120)
                .offset(x: -72 + progress * 72)
            Circle()
                .fill(accent)
                .frame(width: 12, height: 12)
                .offset(x: -72 + progress * 72)
        }
    }

    private var steps: some View {
        HStack(alignment: .center, spacing: 10) {
            ForEach(1...3, id: \.self) { number in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 70, height: 90)
                    .overlay(alignment: .topLeading) {
                        Text("\(number)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(accent, in: .circle)
                            .padding(5)
                    }
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 4) {
                            Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 44, height: 4)
                            Capsule().fill(Color.secondary.opacity(0.18)).frame(width: 34, height: 4)
                        }
                        .padding(8)
                    }
                    .offset(y: (1 - progress) * CGFloat(number - 1) * 12)
                    .opacity(0.45 + progress * 0.55)
            }
        }
    }

    private var combined: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                .frame(width: 230, height: 112)
            HStack(spacing: 6) {
                imageTile(color: Color.secondary.opacity(0.18), size: CGSize(width: 92, height: 94))
                    .offset(x: (1 - progress) * -28)
                VStack(spacing: 6) {
                    imageTile(color: accent.opacity(0.25), size: CGSize(width: 102, height: 44))
                        .offset(x: (1 - progress) * 36, y: (1 - progress) * -18)
                    imageTile(color: Color.secondary.opacity(0.15), size: CGSize(width: 102, height: 44))
                        .offset(x: (1 - progress) * 36, y: (1 - progress) * 18)
                }
            }
        }
    }

    private var recordRegion: some View {
        ZStack {
            desktopBackdrop
            RoundedRectangle(cornerRadius: 5)
                .stroke(accent, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                .frame(width: 58 + progress * 92, height: 34 + progress * 48)
            recordingBadge.offset(x: -92, y: -53)
            waveform.offset(x: 75, y: 49).opacity(progress)
        }
    }

    private var recordWindow: some View {
        ZStack {
            appWindow(tint: accent.opacity(0.12))
                .overlay { RoundedRectangle(cornerRadius: 9).stroke(accent, lineWidth: 2) }
                .scaleEffect(0.88 + progress * 0.12)
            recordingBadge.offset(x: -90, y: -52)
            timeline.offset(y: 55)
        }
    }

    private var recordScreen: some View {
        ZStack {
            monitorFrame
            recordingBadge.offset(x: -96, y: -54)
            Rectangle()
                .fill(accent)
                .frame(width: 20 + progress * 175, height: 3)
                .offset(x: -88 + progress * 87, y: 48)
        }
    }

    private var guide: some View {
        ZStack {
            appWindow(tint: Color.secondary.opacity(0.12))
                .frame(width: 148)
                .offset(x: -62)
            Image(systemName: "cursorarrow.click.2")
                .font(.title2)
                .foregroundStyle(accent)
                .offset(x: -84 + progress * 42, y: -28 + progress * 34)
            Image(systemName: "arrow.right")
                .foregroundStyle(accent)
                .offset(x: 27)
                .opacity(progress)
            VStack(spacing: 6) {
                ForEach(1...3, id: \.self) { number in
                    HStack(spacing: 6) {
                        Text("\(number)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(accent, in: .circle)
                        Capsule().fill(Color.secondary.opacity(0.2)).frame(width: 46, height: 5)
                    }
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 8))
            .offset(x: 85)
            .opacity(0.2 + progress * 0.8)
        }
    }

    private var device: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .stroke(accent, lineWidth: 2)
                .frame(width: 72, height: 124)
                .overlay(alignment: .top) {
                    Capsule().fill(accent).frame(width: 22, height: 4).padding(.top, 7)
                }
                .overlay {
                    VStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 4).fill(accent.opacity(0.2)).frame(width: 48, height: 36)
                        ForEach(0..<3, id: \.self) { _ in
                            Capsule().fill(Color.secondary.opacity(0.2)).frame(width: 44, height: 4)
                        }
                    }
                    .offset(y: 4 - progress * 9)
                }
            recordingBadge.offset(x: -68, y: -46)
            waveform.offset(x: 78, y: 28).opacity(progress)
        }
    }

    private var ruler: some View {
        ZStack {
            desktopBackdrop.opacity(0.55)
            RoundedRectangle(cornerRadius: 5)
                .fill(accent.opacity(0.18))
                .frame(width: 90 + progress * 150, height: 38)
            HStack(spacing: 11) {
                ForEach(0..<11, id: \.self) { index in
                    Rectangle()
                        .fill(accent)
                        .frame(width: 1, height: index.isMultiple(of: 5) ? 22 : 12)
                }
            }
            HStack(spacing: 7) {
                Image(systemName: "arrow.left")
                Text("248 px").font(.caption2.monospacedDigit().weight(.semibold))
                Image(systemName: "arrow.right")
            }
            .offset(y: 42)
            .opacity(progress)
        }
    }

    private var inspector: some View {
        ZStack {
            miniatureWindow.offset(x: -36, y: 12).opacity(0.45)
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: 88, height: 88)
                .overlay {
                    InspectorGrid()
                        .clipShape(.circle)
                }
                .overlay { Circle().stroke(accent, lineWidth: 2) }
                .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
                .offset(x: -8 + progress * 38, y: 6 - progress * 13)
            metricBadge("#A3D65E")
                .offset(x: 92, y: -34)
                .opacity(progress)
            HStack(spacing: 6) {
                Rectangle().fill(accent).frame(width: 34, height: 2)
                Text("128 px").font(.caption2.monospacedDigit())
            }
            .offset(x: 34, y: 48)
        }
    }

    private var clipboard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 212, height: 116)
            RoundedRectangle(cornerRadius: 4)
                .fill(accent.opacity(0.75))
                .frame(width: 54, height: 14)
                .offset(y: -61)
            VStack(spacing: 7) {
                clipboardRow(icon: "text.alignleft", width: 104)
                    .offset(x: (1 - progress) * -28)
                clipboardRow(icon: "link", width: 86)
                    .offset(x: (1 - progress) * 32)
                clipboardRow(icon: "photo", width: 112)
                    .offset(x: (1 - progress) * -36)
                clipboardRow(icon: "doc", width: 94)
                    .offset(x: (1 - progress) * 24)
            }
            .clipShape(.rect(cornerRadius: 8))
        }
    }

    private var timer: some View {
        ZStack {
            desktopBackdrop.opacity(0.5)
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: 100, height: 100)
                .overlay { Circle().stroke(accent, lineWidth: 2) }
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            ForEach(0..<12, id: \.self) { tick in
                Capsule()
                    .fill(tick.isMultiple(of: 3) ? accent : Color.secondary.opacity(0.3))
                    .frame(width: 2, height: tick.isMultiple(of: 3) ? 10 : 6)
                    .offset(y: -42)
                    .rotationEffect(.degrees(Double(tick) * 30))
            }
            Rectangle()
                .fill(accent)
                .frame(width: 3, height: 34)
                .offset(y: -16)
                .rotationEffect(.degrees(-120 + progress * 210), anchor: .bottom)
            Text(progress < 0.5 ? "3" : "1")
                .font(.title2.monospacedDigit().bold())
                .offset(y: 18)
        }
    }

    private var cursor: some View {
        ZStack {
            desktopBackdrop
            Circle()
                .fill(accent.opacity(0.18))
                .frame(width: 34, height: 34)
                .offset(x: -70 + progress * 115, y: -30 + progress * 54)
                .scaleEffect(1.35 - progress * 0.35)
            Image(systemName: "cursorarrow")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.primary)
                .offset(x: -70 + progress * 115, y: -30 + progress * 54)
            HStack(spacing: 5) {
                Image(systemName: "square.3.layers.3d")
                Text("Editable overlay").font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor), in: .capsule)
            .offset(x: 66, y: -44)
            .opacity(progress)
        }
    }

    private var privacy: some View {
        ZStack {
            HStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("History").font(.caption2)
                }
                VStack(spacing: 8) {
                    Image(systemName: "text.viewfinder")
                    Text("OCR").font(.caption2)
                }
                VStack(spacing: 8) {
                    Image(systemName: "clipboard")
                    Text("Clipboard").font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
            .opacity(1 - progress * 0.78)
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(accent)
                .scaleEffect(0.68 + progress * 0.32)
                .opacity(0.25 + progress * 0.75)
        }
    }

    private func discoveryCard(
        title: String,
        systemImage: String
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(accent)
            Text(title)
                .font(.caption2.weight(.semibold))
            Capsule()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 42, height: 4)
        }
        .frame(width: 78, height: 94)
        .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.16))
        }
    }

    private var desktopBackdrop: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.secondary.opacity(0.1))
            .frame(width: 244, height: 118)
            .overlay(alignment: .top) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(Color.secondary.opacity(0.32))
                            .frame(width: 6, height: 6)
                    }
                    Spacer()
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 50, height: 5)
                }
                .padding(9)
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.09))
                    .frame(width: 48, height: 82)
                    .padding(.leading, 9)
                    .padding(.top, 20)
            }
            .overlay(alignment: .trailing) {
                VStack(alignment: .leading, spacing: 9) {
                    Capsule().fill(accent.opacity(0.22)).frame(width: 92, height: 8)
                    Capsule().fill(Color.secondary.opacity(0.18)).frame(width: 130, height: 6)
                    Capsule().fill(Color.secondary.opacity(0.14)).frame(width: 108, height: 6)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 132, height: 36)
                }
                .padding(.trailing, 14)
                .padding(.top, 22)
            }
    }

    private func appWindow(tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(tint)
            .frame(width: 164, height: 104)
            .overlay(alignment: .top) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(Color.secondary.opacity(0.34))
                            .frame(width: 6, height: 6)
                    }
                    Spacer()
                }
                .padding(8)
            }
            .overlay {
                VStack(alignment: .leading, spacing: 8) {
                    Capsule().fill(accent.opacity(0.28)).frame(width: 94, height: 7)
                    Capsule().fill(Color.secondary.opacity(0.2)).frame(width: 122, height: 5)
                    Capsule().fill(Color.secondary.opacity(0.16)).frame(width: 78, height: 5)
                }
                .padding(.top, 16)
            }
    }

    private var selectionHandles: some View {
        ZStack {
            Circle().fill(accent).frame(width: 7, height: 7).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Circle().fill(accent).frame(width: 7, height: 7).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            Circle().fill(accent).frame(width: 7, height: 7).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            Circle().fill(accent).frame(width: 7, height: 7).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private func metricBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: .capsule)
            .overlay { Capsule().strokeBorder(Color.secondary.opacity(0.2)) }
    }

    private var monitorFrame: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 224, height: 104)
                .overlay {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 5).fill(accent.opacity(0.22)).frame(width: 76, height: 58)
                            VStack(alignment: .leading, spacing: 7) {
                                Capsule().fill(Color.secondary.opacity(0.22)).frame(width: 82, height: 6)
                                Capsule().fill(Color.secondary.opacity(0.16)).frame(width: 64, height: 6)
                                Capsule().fill(Color.secondary.opacity(0.16)).frame(width: 74, height: 6)
                            }
                        }
                    }
                }
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.22)) }
            Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 46, height: 4)
        }
    }

    private func resultThumbnail(label: String) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.11))
            .frame(width: 84, height: 94)
            .overlay {
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(accent.opacity(0.2))
                        .frame(width: 58, height: 42)
                    Text(label).font(.caption2.weight(.semibold))
                    Capsule().fill(Color.secondary.opacity(0.2)).frame(width: 44, height: 4)
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.16)) }
    }

    private func sliderRow(icon: String, offset: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 14)
                .foregroundStyle(accent)
            Capsule()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 84, height: 6)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(accent)
                        .frame(width: 13, height: 13)
                        .offset(x: 36 + offset)
                }
        }
    }

    private func imageTile(color: Color, size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(color)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 3) {
                    Rectangle().fill(accent.opacity(0.45)).frame(width: 12, height: 20)
                    Rectangle().fill(accent.opacity(0.28)).frame(width: 14, height: 30)
                    Rectangle().fill(accent.opacity(0.36)).frame(width: 11, height: 24)
                }
                .padding(7)
            }
    }

    private var recordingBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
                .scaleEffect(0.7 + progress * 0.3)
            Text("REC")
                .font(.system(size: 9, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: .capsule)
        .overlay { Capsule().strokeBorder(Color.secondary.opacity(0.2)) }
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach([8, 18, 28, 14, 24, 10], id: \.self) { height in
                Capsule()
                    .fill(accent)
                    .frame(width: 3, height: CGFloat(height) * (0.45 + progress * 0.55))
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.16)) }
    }

    private var timeline: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.18)).frame(width: 190, height: 5)
            Capsule().fill(accent).frame(width: 18 + progress * 142, height: 5)
            Circle().fill(accent).frame(width: 12, height: 12).offset(x: 12 + progress * 142)
        }
    }

    private func clipboardRow(icon: String, width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(accent)
                .frame(width: 14)
            Capsule().fill(Color.secondary.opacity(0.2)).frame(width: width, height: 5)
            Spacer(minLength: 0)
        }
        .frame(width: 172, height: 18)
    }

    private var miniatureWindow: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.12))
            .frame(width: 126, height: 78)
            .overlay(alignment: .top) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(Color.secondary.opacity(0.32)).frame(width: 6, height: 6)
                    }
                    Spacer()
                }
                .padding(8)
            }
    }
}

private struct InspectorGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 14
            var path = Path()
            for x in stride(from: 0, through: size.width, by: spacing) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0, through: size.height, by: spacing) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.secondary.opacity(0.25)), lineWidth: 1)

            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(
                Path(CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)),
                with: .color(.accentColor.opacity(0.75))
            )
        }
    }
}

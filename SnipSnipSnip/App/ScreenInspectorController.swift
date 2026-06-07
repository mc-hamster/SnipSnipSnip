import AppKit
import Combine
import Carbon
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import SwiftUI

@MainActor
final class ScreenInspectorCoordinator: ObservableObject {
    private enum Shortcut: UInt32, CaseIterable {
        case freeze = 1
        case copyHex = 2
        case copyRGB = 3
        case snip = 4
        case measure = 5

        var keyCode: UInt32 {
            switch self {
            case .freeze:
                return UInt32(kVK_ANSI_F)
            case .copyHex:
                return UInt32(kVK_ANSI_H)
            case .copyRGB:
                return UInt32(kVK_ANSI_R)
            case .snip:
                return UInt32(kVK_ANSI_S)
            case .measure:
                return UInt32(kVK_ANSI_M)
            }
        }
    }

    private static let hotKeySignature = OSType(0x5353494E)
    private static let eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

    @Published private(set) var isVisible = false

    private var windowController: ScreenInspectorWindowController?
    private var preferences: ScreenInspectorPreferences
    private var onPreferencesChange: (ScreenInspectorPreferences) -> Void
    private var onSnip: (ScreenInspectorSample) -> Void
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [Shortcut: EventHotKeyRef] = [:]

    init(
        preferences: ScreenInspectorPreferences = .default,
        onPreferencesChange: @escaping (ScreenInspectorPreferences) -> Void = { _ in },
        onSnip: @escaping (ScreenInspectorSample) -> Void = { _ in }
    ) {
        self.preferences = preferences.sanitized()
        self.onPreferencesChange = onPreferencesChange
        self.onSnip = onSnip
    }

    func setPreferencesChangeHandler(_ handler: @escaping (ScreenInspectorPreferences) -> Void) {
        onPreferencesChange = handler
    }

    func setSnipHandler(_ handler: @escaping (ScreenInspectorSample) -> Void) {
        onSnip = handler
    }

    deinit {
        MainActor.assumeIsolated {
            unregisterHotKeys()

            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
            }
        }
    }

    func updatePreferences(_ preferences: ScreenInspectorPreferences) {
        let sanitizedPreferences = preferences.sanitized()
        guard self.preferences != sanitizedPreferences else {
            return
        }

        self.preferences = sanitizedPreferences
        windowController?.model.preferences = sanitizedPreferences
    }

    func present() {
        if let windowController {
            windowController.showWindow(nil)
            windowController.window?.orderFrontRegardless()
            isVisible = true
            return
        }

        let model = ScreenInspectorWindowModel(preferences: preferences, onSnip: { [weak self] sample in
            self?.onSnip(sample)
        })
        let controller = ScreenInspectorWindowController(
            model: model,
            onPreferencesChange: { [weak self] preferences in
                self?.preferences = preferences
                self?.onPreferencesChange(preferences)
            },
            onClose: { [weak self] in
                self?.windowController = nil
                self?.isVisible = false
                self?.unregisterHotKeys()
            }
        )

        windowController = controller
        isVisible = true
        registerHotKeys()
        controller.showWindow(nil)
        controller.window?.orderFrontRegardless()
    }

    func toggle() {
        isVisible ? close() : present()
    }

    func close() {
        windowController?.close()
        windowController = nil
        isVisible = false
        unregisterHotKeys()
    }

    private func registerHotKeys() {
        guard hotKeyRefs.isEmpty else {
            return
        }

        installEventHandlerIfNeeded()

        for shortcut in Shortcut.allCases {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: shortcut.rawValue)
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                UInt32(cmdKey | optionKey),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            guard status == noErr, let hotKeyRef else {
                continue
            }

            hotKeyRefs[shortcut] = hotKeyRef
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else {
            return
        }

        let handler: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else {
                return OSStatus(eventNotHandledErr)
            }

            let coordinator = Unmanaged<ScreenInspectorCoordinator>
                .fromOpaque(userData)
                .takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr,
                  hotKeyID.signature == ScreenInspectorCoordinator.hotKeySignature,
                  let shortcut = Shortcut(rawValue: hotKeyID.id) else {
                return status
            }

            DispatchQueue.main.async {
                coordinator.handle(shortcut)
            }
            return noErr
        }

        var eventType = Self.eventType
        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )
    }

    private func handle(_ shortcut: Shortcut) {
        guard isVisible else {
            return
        }

        switch shortcut {
        case .freeze:
            windowController?.model.toggleFrozen()
        case .copyHex:
            windowController?.model.copyColorAsHex()
        case .copyRGB:
            windowController?.model.copyColorAsRGB()
        case .snip:
            windowController?.model.snipCurrentSample()
        case .measure:
            windowController?.model.toggleMeasurementPoint()
        }
    }

    private func unregisterHotKeys() {
        hotKeyRefs.values.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
    }
}

@MainActor
final class ScreenInspectorWindowModel: ObservableObject {
    @Published var preferences: ScreenInspectorPreferences
    @Published var sample: ScreenInspectorSample?
    @Published var isFrozen = false
    @Published private(set) var measurement: ScreenInspectorMeasurement?

    private let sampler = ScreenInspectorSampler()
    private let onSnip: (ScreenInspectorSample) -> Void
    private var timer: Timer?
    private var pendingSampleTask: Task<Void, Never>?
    private var lensDisplaySize = CGSize(width: 256, height: 256)
    private var measurementStart: CGPoint?
    private var isMeasurementLocked = false

    init(preferences: ScreenInspectorPreferences, onSnip: @escaping (ScreenInspectorSample) -> Void = { _ in }) {
        self.preferences = preferences.sanitized()
        self.onSnip = onSnip
    }

    var cursorCoordinateDescription: String {
        guard let sample else {
            return "x: --  y: --"
        }

        return "x: \(Int(round(sample.cursorLocation.x)))  y: \(Int(round(sample.cursorLocation.y)))"
    }

    var colorDescription: String {
        sample?.color.hexString ?? "#------"
    }

    var measurementDescription: String {
        measurement?.description ?? "distance: --"
    }

    var measurementButtonTitle: String {
        if measurementStart == nil || isMeasurementLocked {
            return "Measure"
        }

        return "Lock"
    }

    func start() {
        guard timer == nil else {
            return
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pendingSampleTask?.cancel()
        pendingSampleTask = nil
    }

    func setFrozen(_ isFrozen: Bool) {
        self.isFrozen = isFrozen
        if !isFrozen {
            refresh()
        }
    }

    func copyColorAsHex() {
        copy(sample?.color.hexString)
    }

    func copyColorAsRGB() {
        copy(sample?.color.rgbString)
    }

    func toggleFrozen() {
        setFrozen(!isFrozen)
    }

    func snipCurrentSample() {
        guard let sample else {
            return
        }

        onSnip(sample)
    }

    func toggleMeasurementPoint() {
        guard let sample else {
            return
        }

        if measurementStart == nil || isMeasurementLocked {
            measurementStart = sample.cursorLocation
            isMeasurementLocked = false
            measurement = ScreenInspectorMeasurement(start: sample.cursorLocation, end: sample.cursorLocation)
            return
        }

        if let measurementStart {
            isMeasurementLocked = true
            measurement = ScreenInspectorMeasurement(start: measurementStart, end: sample.cursorLocation)
        }
    }

    func clearMeasurement() {
        measurementStart = nil
        isMeasurementLocked = false
        measurement = nil
    }

    func updateLensDisplaySize(_ size: CGSize) {
        let sanitizedSize = CGSize(
            width: max(size.width.rounded(), 1),
            height: max(size.height.rounded(), 1)
        )
        guard abs(sanitizedSize.width - lensDisplaySize.width) >= 1 ||
            abs(sanitizedSize.height - lensDisplaySize.height) >= 1
        else {
            return
        }

        lensDisplaySize = sanitizedSize
        if !isFrozen {
            refresh()
        }
    }

    private func refresh() {
        guard !isFrozen, pendingSampleTask == nil else {
            return
        }

        let location = NSEvent.mouseLocation
        let zoomLevel = preferences.zoomLevel
        let lensDisplaySize = lensDisplaySize
        pendingSampleTask = Task { @MainActor [weak self] in
            let sample = try? await self?.sampler.sample(
                around: location,
                zoomLevel: zoomLevel,
                lensDisplaySize: lensDisplaySize
            )
            guard let self, !Task.isCancelled else {
                return
            }

            self.pendingSampleTask = nil
            guard !self.isFrozen else {
                return
            }

            if let sample {
                self.sample = sample
                self.updateMeasurement(with: sample.cursorLocation)
            }
        }
    }

    private func updateMeasurement(with point: CGPoint) {
        guard let measurementStart, !isMeasurementLocked else {
            return
        }

        measurement = ScreenInspectorMeasurement(start: measurementStart, end: point)
    }

    private func copy(_ value: String?) {
        guard let value else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

@MainActor
final class ScreenInspectorWindowController: NSWindowController {
    let model: ScreenInspectorWindowModel

    private let onPreferencesChange: (ScreenInspectorPreferences) -> Void
    private let onClose: () -> Void
    private var cancellables: Set<AnyCancellable> = []
    private var hasNotifiedClose = false

    init(
        model: ScreenInspectorWindowModel,
        onPreferencesChange: @escaping (ScreenInspectorPreferences) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.onPreferencesChange = onPreferencesChange
        self.onClose = onClose

        let panel = NSPanel(
            contentRect: Self.initialFrame(),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(ScreenInspectorWindowID.prefix + UUID().uuidString)
        panel.title = "Screen Inspector"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = CGSize(width: 420, height: 430)
        panel.contentView = NSHostingView(
            rootView: ScreenInspectorWindowView(
                model: model,
                onClose: { [weak panel] in
                    panel?.close()
                }
            )
        )

        super.init(window: panel)
        panel.delegate = self
        observePreferences()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        model.start()
    }

    override func close() {
        super.close()
        notifyClosed()
    }

    private static func initialFrame() -> CGRect {
        let visibleFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 160, y: 160, width: 900, height: 600)
        let size = CGSize(width: 420, height: 540)

        return CGRect(
            x: visibleFrame.maxX - size.width - 24,
            y: visibleFrame.maxY - size.height - 24,
            width: size.width,
            height: size.height
        )
    }

    private func observePreferences() {
        model.$preferences
            .dropFirst()
            .sink { [weak self] preferences in
                self?.onPreferencesChange(preferences.sanitized())
            }
            .store(in: &cancellables)
    }

    private func notifyClosed() {
        guard !hasNotifiedClose else {
            return
        }

        hasNotifiedClose = true
        model.stop()
        onClose()
    }
}

extension ScreenInspectorWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        notifyClosed()
    }
}

private struct ScreenInspectorWindowView: View {
    @ObservedObject var model: ScreenInspectorWindowModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            magnifiedImage
                .frame(minWidth: 220, minHeight: 220)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.88))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.24), lineWidth: 1)
                )

            metadata
            controls
        }
        .padding(14)
        .frame(minWidth: 392, minHeight: 410)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var magnifiedImage: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = model.sample?.image {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    Text("Screen Recording permission required")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding()
                }

                if model.preferences.showsPixelGrid {
                    PixelGridOverlay(zoomLevel: model.preferences.zoomLevel)
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
                }

                if model.preferences.showsCrosshair {
                    CrosshairOverlay()
                        .stroke(Color.white.opacity(0.85), lineWidth: 1)
                        .shadow(color: .black.opacity(0.8), radius: 1)
                }

                if let sample = model.sample, let measurement = model.measurement {
                    MeasurementOverlay(sample: sample, measurement: measurement, zoomLevel: model.preferences.zoomLevel)
                        .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .shadow(color: .black.opacity(0.9), radius: 1)
                }
            }
            .onAppear {
                model.updateLensDisplaySize(proxy.size)
            }
            .onChange(of: proxy.size) { _, size in
                model.updateLensDisplaySize(size)
            }
        }
    }

    private var metadata: some View {
        HStack(spacing: 12) {
            Text(model.cursorCoordinateDescription)
                .monospacedDigit()
                .lineLimit(1)

            if let color = model.sample?.color {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(
                        red: Double(color.red) / 255,
                        green: Double(color.green) / 255,
                        blue: Double(color.blue) / 255,
                        opacity: Double(color.alpha) / 255
                    ))
                    .frame(width: 26, height: 20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.primary.opacity(0.25), lineWidth: 1)
                    )

                Text(color.compactRGBString)
                    .foregroundStyle(.secondary)
                    .monospaced()
                    .lineLimit(1)
            }

            Text(model.colorDescription)
                .fontWeight(.semibold)
                .monospaced()
                .lineLimit(1)

            Text(model.measurementDescription)
                .foregroundStyle(model.measurement == nil ? .secondary : .primary)
                .fontWeight(model.measurement == nil ? .regular : .semibold)
                .monospaced()
                .lineLimit(1)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Zoom", selection: preferencesBinding(\.zoomLevel)) {
                ForEach(ScreenInspectorZoomLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Toggle("Grid", isOn: preferencesBinding(\.showsPixelGrid))
                Toggle("Crosshair", isOn: preferencesBinding(\.showsCrosshair))
            }

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Button("\(model.isFrozen ? "Unfreeze" : "Freeze") ⌥⌘F") {
                        model.toggleFrozen()
                    }
                    .frame(minWidth: 96)
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Freeze or unfreeze the inspector. Shortcut: Option-Command-F.")

                    Button("Snip ⌥⌘S", action: model.snipCurrentSample)
                        .frame(minWidth: 78)
                        .disabled(model.sample == nil)
                        .keyboardShortcut("s", modifiers: [.command, .option])
                        .help("Open the current inspector sample in the editor. Shortcut: Option-Command-S.")

                    Button("Close Esc", action: onClose)
                        .frame(minWidth: 78)
                        .keyboardShortcut(.escape, modifiers: [])
                }

                HStack(spacing: 8) {
                    Button("Copy HEX ⌥⌘H", action: model.copyColorAsHex)
                        .frame(minWidth: 98)
                        .disabled(model.sample == nil)
                        .keyboardShortcut("h", modifiers: [.command, .option])
                        .help("Copy the current color as HEX. Shortcut: Option-Command-H.")

                    Button("Copy RGB ⌥⌘R", action: model.copyColorAsRGB)
                        .frame(minWidth: 98)
                        .disabled(model.sample == nil)
                        .keyboardShortcut("r", modifiers: [.command, .option])
                        .help("Copy the current color as RGB. Shortcut: Option-Command-R.")

                    Button("\(model.measurementButtonTitle) ⌥⌘M", action: model.toggleMeasurementPoint)
                        .frame(minWidth: 98)
                        .disabled(model.sample == nil)
                        .keyboardShortcut("m", modifiers: [.command, .option])
                        .help("Set the first point, then lock the current cursor as the second point. Shortcut: Option-Command-M.")

                    Button("Clear", action: model.clearMeasurement)
                        .frame(minWidth: 54)
                        .disabled(model.measurement == nil)
                        .help("Clear the distance measurement.")
                }
            }
            .font(.caption)
        }
    }

    private func preferencesBinding<Value>(_ keyPath: WritableKeyPath<ScreenInspectorPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.preferences[keyPath: keyPath] },
            set: { value in
                var preferences = model.preferences
                preferences[keyPath: keyPath] = value
                model.preferences = preferences.sanitized()
            }
        )
    }
}

private struct PixelGridOverlay: Shape {
    let zoomLevel: ScreenInspectorZoomLevel

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing = CGFloat(zoomLevel.rawValue)

        var x = rect.midX.truncatingRemainder(dividingBy: spacing)
        while x <= rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += spacing
        }

        var y = rect.midY.truncatingRemainder(dividingBy: spacing)
        while y <= rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }

        return path
    }
}

private struct CrosshairOverlay: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct MeasurementOverlay: Shape {
    let sample: ScreenInspectorSample
    let measurement: ScreenInspectorMeasurement
    let zoomLevel: ScreenInspectorZoomLevel

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: lensPoint(for: measurement.start, in: rect))
        path.addLine(to: lensPoint(for: measurement.end, in: rect))
        return path
    }

    private func lensPoint(for point: CGPoint, in rect: CGRect) -> CGPoint {
        let zoom = CGFloat(zoomLevel.rawValue)
        return CGPoint(
            x: rect.midX + (point.x - sample.cursorLocation.x) * zoom,
            y: rect.midY + (point.y - sample.cursorLocation.y) * zoom
        )
    }
}

private final class ScreenInspectorSampler {
    func sample(
        around appKitLocation: CGPoint,
        zoomLevel: ScreenInspectorZoomLevel,
        lensDisplaySize: CGSize
    ) async throws -> ScreenInspectorSample? {
        guard let captureLocation = CursorCaptureGeometry.captureGlobalPoint(fromAppKitGlobalPoint: appKitLocation) else {
            return nil
        }

        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(appKitLocation) }
        let screenScale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let cursorPixelLocation = screen.map { screen in
            let pixelWidth = screen.frame.width * screenScale
            let pixelHeight = screen.frame.height * screenScale
            return CGPoint(
                x: min(max((appKitLocation.x - screen.frame.minX) * screenScale, 0), pixelWidth),
                y: min(max((screen.frame.maxY - appKitLocation.y) * screenScale, 0), pixelHeight)
            )
        } ?? captureLocation
        let samplePixelWidth = max(Int((lensDisplaySize.width / CGFloat(zoomLevel.rawValue)).rounded()), 1)
        let samplePixelHeight = max(Int((lensDisplaySize.height / CGFloat(zoomLevel.rawValue)).rounded()), 1)
        let samplePointSize = CGSize(
            width: CGFloat(samplePixelWidth) / max(screenScale, 1),
            height: CGFloat(samplePixelHeight) / max(screenScale, 1)
        )
        let captureRect = CGRect(
            x: captureLocation.x - samplePointSize.width / 2,
            y: captureLocation.y - samplePointSize.height / 2,
            width: samplePointSize.width,
            height: samplePointSize.height
        ).integral

        let configuration = SCScreenshotConfiguration()
        configuration.width = samplePixelWidth
        configuration.height = samplePixelHeight
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr

        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
            SCScreenshotManager.captureScreenshot(rect: captureRect, configuration: configuration) { output, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let image = output?.sdrImage else {
                    continuation.resume(throwing: ScreenCaptureError.windowImageUnavailable)
                    return
                }

                continuation.resume(returning: image)
            }
        }

        let color = centerPixelColor(in: image) ?? ScreenInspectorPixelColor(red: 0, green: 0, blue: 0, alpha: 0)
        return ScreenInspectorSample(image: image, cursorLocation: cursorPixelLocation, sourceRect: captureRect, color: color)
    }

    private func centerPixelColor(in image: CGImage) -> ScreenInspectorPixelColor? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return nil
        }

        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .none
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(width / 2),
                y: -CGFloat(height / 2),
                width: CGFloat(width),
                height: CGFloat(height)
            )
        )

        return ScreenInspectorPixelColor(red: pixel[0], green: pixel[1], blue: pixel[2], alpha: pixel[3])
    }
}

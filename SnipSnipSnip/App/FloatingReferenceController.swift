import AppKit
import Combine
import SwiftUI

struct FloatingReferenceRequest {
    let title: String
    let subtitle: String?
    let image: CGImage
}

@MainActor
final class FloatingReferenceCoordinator: ObservableObject {
    @Published private(set) var activeReferenceCount = 0

    private var windowControllers: [UUID: FloatingReferenceWindowController] = [:]

    var hasActiveReferences: Bool {
        activeReferenceCount > 0
    }

    func present(_ request: FloatingReferenceRequest) {
        let model = FloatingReferenceWindowModel(request: request)
        let windowController = FloatingReferenceWindowController(
            model: model,
            onClose: { [weak self] id in
                self?.windowControllers[id] = nil
                self?.refreshCounts()
            }
        )

        windowControllers[model.id] = windowController
        refreshCounts()
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    func closeAll() {
        for controller in Array(windowControllers.values) {
            controller.close()
        }

        windowControllers.removeAll()
        refreshCounts()
    }

    private func refreshCounts() {
        activeReferenceCount = windowControllers.count
    }
}

enum FloatingReferenceZoomAction {
    case zoomOut
    case zoomIn
    case fit
}

struct FloatingReferenceZoomRequest: Equatable {
    let id = UUID()
    let action: FloatingReferenceZoomAction
}

@MainActor
final class FloatingReferenceWindowModel: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let image: CGImage
    let pixelSize: CGSize

    @Published var opacity: Double = 1
    @Published var zoomRequest: FloatingReferenceZoomRequest?

    init(request: FloatingReferenceRequest) {
        title = request.title
        subtitle = request.subtitle
        image = request.image
        pixelSize = CGSize(width: request.image.width, height: request.image.height)
    }
}

@MainActor
final class FloatingReferenceWindowController: NSWindowController {
    let model: FloatingReferenceWindowModel

    private var cancellables: Set<AnyCancellable> = []
    private let onClose: (UUID) -> Void

    init(
        model: FloatingReferenceWindowModel,
        onClose: @escaping (UUID) -> Void
    ) {
        self.model = model
        self.onClose = onClose

        let initialSize = Self.initialWindowSize(for: model.pixelSize)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = model.title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: 240, height: 180)
        panel.contentView = NSHostingView(
            rootView: FloatingReferenceWindowView(
                model: model,
                onClose: { [weak panel] in
                    panel?.performClose(nil)
                }
            )
        )

        super.init(window: panel)
        panel.delegate = self
        observeModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("FloatingReferenceWindowController is programmatic-only; use init(model:onClose:) instead of init(coder:).")
    }

    override func close() {
        super.close()
        onClose(model.id)
    }

    private static func initialWindowSize(for pixelSize: CGSize) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            return CGSize(width: 520, height: 340)
        }

        let aspectRatio = pixelSize.width / pixelSize.height
        let maxSize = CGSize(width: 720, height: 520)
        let minSize = CGSize(width: 300, height: 220)
        var size = pixelSize

        if size.width > maxSize.width {
            size.width = maxSize.width
            size.height = size.width / aspectRatio
        }

        if size.height > maxSize.height {
            size.height = maxSize.height
            size.width = size.height * aspectRatio
        }

        if size.width < minSize.width {
            size.width = minSize.width
            size.height = size.width / aspectRatio
        }

        if size.height < minSize.height {
            size.height = minSize.height
            size.width = size.height * aspectRatio
        }

        return CGSize(
            width: min(max(size.width, minSize.width), maxSize.width),
            height: min(max(size.height, minSize.height), maxSize.height)
        )
    }

    private func observeModel() {
        model.$opacity
            .sink { [weak self] opacity in
                self?.window?.alphaValue = max(0.35, min(opacity, 1))
            }
            .store(in: &cancellables)
    }
}

extension FloatingReferenceWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        onClose(model.id)
    }
}

private struct FloatingReferenceWindowView: View {
    @ObservedObject var model: FloatingReferenceWindowModel
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.16)
                .ignoresSafeArea()

            ZoomableReferenceImageView(model: model)
                .padding(.top, 38)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .help("Floating reference image. Scroll to pan, pinch to zoom, or use the zoom buttons.")

            controls
                .padding(8)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var controls: some View {
        HStack(spacing: 8) {
            ZStack {
                Image(systemName: "line.horizontal.3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)

                WindowDragHandleView()
                    .frame(width: 30, height: 30)
            }
            .help("Drag to move this floating reference.")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            .help(referenceTitleHelp)

            Spacer(minLength: 8)

            Button {
                model.zoomRequest = FloatingReferenceZoomRequest(action: .zoomOut)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help("Zoom out.")

            Button {
                model.zoomRequest = FloatingReferenceZoomRequest(action: .fit)
            } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help("Fit image to the reference window.")

            Button {
                model.zoomRequest = FloatingReferenceZoomRequest(action: .zoomIn)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help("Zoom in.")

            Divider()
                .frame(height: 18)
                .opacity(0.28)

            Button {
                model.opacity = 1
            } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.caption)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(model.opacity >= 0.995)
            .help("Reset opacity to 100%.")

            ClickToSlideOpacityControl(value: $model.opacity, range: 0.35...1)
                .frame(width: 96, height: 20)
                .help("Set reference opacity. Click anywhere on the track or drag the knob.")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help("Close this floating reference.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
        }
    }

    private var referenceTitleHelp: String {
        if let subtitle = model.subtitle {
            return "\(model.title) - \(subtitle)"
        }

        return model.title
    }
}

private struct ZoomableReferenceImageView: NSViewRepresentable {
    @ObservedObject var model: FloatingReferenceWindowModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ZoomableReferenceScrollView {
        let scrollView = ZoomableReferenceScrollView()
        scrollView.configure(image: model.image)
        return scrollView
    }

    func updateNSView(_ nsView: ZoomableReferenceScrollView, context: Context) {
        nsView.configure(image: model.image)

        if let request = model.zoomRequest,
           request.id != context.coordinator.lastZoomRequestID {
            context.coordinator.lastZoomRequestID = request.id
            nsView.applyZoomAction(request.action)
        }
    }

    final class Coordinator {
        var lastZoomRequestID: UUID?
    }
}

private final class ZoomableReferenceScrollView: NSScrollView {
    private let imageView = NSImageView()
    private var currentImage: CGImage?
    private var didFitInitialImage = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.15
        maxMagnification = 8
        usesPredominantAxisScrolling = false
        documentView = imageView

        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleNone
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("FloatingReferenceScrollView is programmatic-only; use init(image:) instead of init(coder:).")
    }

    override func layout() {
        super.layout()

        if !didFitInitialImage {
            fitImageToViewport()
            didFitInitialImage = true
        }
    }

    func configure(image: CGImage) {
        guard currentImage !== image else {
            return
        }

        currentImage = image
        imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        imageView.frame = NSRect(x: 0, y: 0, width: image.width, height: image.height)
        didFitInitialImage = false
        needsLayout = true
    }

    func applyZoomAction(_ action: FloatingReferenceZoomAction) {
        switch action {
        case .zoomOut:
            setMagnification(max(minMagnification, magnification / 1.25), centeredAt: viewportCenter)
        case .zoomIn:
            setMagnification(min(maxMagnification, magnification * 1.25), centeredAt: viewportCenter)
        case .fit:
            fitImageToViewport()
        }
    }

    private var viewportCenter: NSPoint {
        NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
    }

    private func fitImageToViewport() {
        guard let image = currentImage else {
            return
        }

        let viewportSize = contentView.bounds.size
        guard viewportSize.width > 1, viewportSize.height > 1 else {
            return
        }

        let widthScale = viewportSize.width / CGFloat(image.width)
        let heightScale = viewportSize.height / CGFloat(image.height)
        let fitScale = min(max(min(widthScale, heightScale), minMagnification), maxMagnification)
        setMagnification(fitScale, centeredAt: NSPoint(x: CGFloat(image.width) / 2, y: CGFloat(image.height) / 2))
    }
}

private struct WindowDragHandleView: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleNSView {
        DragHandleNSView()
    }

    func updateNSView(_ nsView: DragHandleNSView, context: Context) {}
}

private final class DragHandleNSView: NSView {
    override var acceptsFirstResponder: Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct ClickToSlideOpacityControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private let knobDiameter: CGFloat = 14
    private let trackHeight: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let progress = progress(for: value)
            let trackWidth = max(proxy.size.width - knobDiameter, 1)
            let knobOffset = trackWidth * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(height: trackHeight)
                    .padding(.horizontal, knobDiameter / 2)

                Capsule()
                    .fill(Color.accentColor.opacity(0.82))
                    .frame(width: knobOffset + knobDiameter / 2, height: trackHeight)
                    .padding(.leading, knobDiameter / 2)

                Circle()
                    .fill(Color.primary.opacity(0.94))
                    .frame(width: knobDiameter, height: knobDiameter)
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.75)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 2, x: 0, y: 1)
                    .offset(x: knobOffset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        updateValue(from: drag.location.x, in: proxy.size.width)
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reference opacity")
        .accessibilityValue("\(Int(round(value * 100))) percent")
        .accessibilityAdjustableAction { direction in
            let step = 0.05

            switch direction {
            case .increment:
                value = clamped(value + step)
            case .decrement:
                value = clamped(value - step)
            @unknown default:
                break
            }
        }
    }

    private func updateValue(from x: CGFloat, in width: CGFloat) {
        let trackWidth = max(width - knobDiameter, 1)
        let normalizedX = min(max(x - knobDiameter / 2, 0), trackWidth)
        let progress = Double(normalizedX / trackWidth)
        value = clamped(range.lowerBound + progress * (range.upperBound - range.lowerBound))
    }

    private func progress(for value: Double) -> CGFloat {
        CGFloat((clamped(value) - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

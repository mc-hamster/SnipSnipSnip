import AppKit
import Carbon
import Foundation

nonisolated enum GlobalHotKeyKey: String, CaseIterable, Codable, Identifiable {
    case one
    case two
    case three
    case four
    case five
    case six
    case seven
    case eight
    case nine
    case zero
    case r
    case t
    case w
    case f
    case i
    case g

    var id: String { rawValue }

    var label: String {
        switch self {
        case .one:
            return "1"
        case .two:
            return "2"
        case .three:
            return "3"
        case .four:
            return "4"
        case .five:
            return "5"
        case .six:
            return "6"
        case .seven:
            return "7"
        case .eight:
            return "8"
        case .nine:
            return "9"
        case .zero:
            return "0"
        case .r:
            return "R"
        case .t:
            return "T"
        case .w:
            return "W"
        case .f:
            return "F"
        case .i:
            return "I"
        case .g:
            return "G"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .one:
            return UInt32(kVK_ANSI_1)
        case .two:
            return UInt32(kVK_ANSI_2)
        case .three:
            return UInt32(kVK_ANSI_3)
        case .four:
            return UInt32(kVK_ANSI_4)
        case .five:
            return UInt32(kVK_ANSI_5)
        case .six:
            return UInt32(kVK_ANSI_6)
        case .seven:
            return UInt32(kVK_ANSI_7)
        case .eight:
            return UInt32(kVK_ANSI_8)
        case .nine:
            return UInt32(kVK_ANSI_9)
        case .zero:
            return UInt32(kVK_ANSI_0)
        case .r:
            return UInt32(kVK_ANSI_R)
        case .t:
            return UInt32(kVK_ANSI_T)
        case .w:
            return UInt32(kVK_ANSI_W)
        case .f:
            return UInt32(kVK_ANSI_F)
        case .i:
            return UInt32(kVK_ANSI_I)
        case .g:
            return UInt32(kVK_ANSI_G)
        }
    }
}

nonisolated enum GlobalHotKeyAction: UInt32, CaseIterable {
    case region = 1
    case window = 2
    case fullscreen = 3
    case frontmostWindow = 4
    case repeatLastCapture = 5
    case screenInspector = 6
    case guide = 7

    var label: String {
        switch self {
        case .region:
            return "Region"
        case .window:
            return "Window"
        case .fullscreen:
            return "Fullscreen"
        case .frontmostWindow:
            return "Frontmost Window"
        case .repeatLastCapture:
            return "Repeat"
        case .screenInspector:
            return "Screen Inspector"
        case .guide:
            return "Guide"
        }
    }

    static let defaultKeys: [GlobalHotKeyAction: GlobalHotKeyKey] = [
        .region: .one,
        .window: .two,
        .fullscreen: .three,
        .frontmostWindow: .four,
        .repeatLastCapture: .r,
        .screenInspector: .i,
        .guide: .g
    ]
}

final class GlobalHotKeyCoordinator {
    private static let signature = OSType(0x53535348)
    private static let eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

    private let actionHandler: (GlobalHotKeyAction) -> Void
    private let presetHandler: (UUID) -> Void
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventsByID: [UInt32: GlobalHotKeyEvent] = [:]
    private var notificationObservers: [NSObjectProtocol] = []
    private var isEnabled = false
    private var actionKeys: [GlobalHotKeyAction: GlobalHotKeyKey] = GlobalHotKeyAction.defaultKeys
    private var presetKeys: [UUID: GlobalHotKeyKey] = [:]

    init(
        actionHandler: @escaping (GlobalHotKeyAction) -> Void,
        presetHandler: @escaping (UUID) -> Void = { _ in }
    ) {
        self.actionHandler = actionHandler
        self.presetHandler = presetHandler
        installEventHandlerIfNeeded()
        observeApplicationActivity()
    }

    deinit {
        MainActor.assumeIsolated {
            unregisterAllHotKeys()

            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
            }

            notificationObservers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        refreshRegistrations()
    }

    func setActionKeys(_ actionKeys: [GlobalHotKeyAction: GlobalHotKeyKey]) {
        self.actionKeys = actionKeys
        refreshRegistrations()
    }

    func setPresetKeys(_ presetKeys: [UUID: GlobalHotKeyKey]) {
        self.presetKeys = presetKeys
        refreshRegistrations()
    }

    private func observeApplicationActivity() {
        notificationObservers = [
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshRegistrations()
                }
            },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshRegistrations()
                }
            }
        ]
    }

    private func refreshRegistrations() {
        guard isEnabled, let app = NSApp, !app.isActive else {
            unregisterAllHotKeys()
            return
        }

        registerAllHotKeys()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else {
            return
        }

        let handler: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else {
                return OSStatus(eventNotHandledErr)
            }

            let coordinator = Unmanaged<GlobalHotKeyCoordinator>
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
                  hotKeyID.signature == GlobalHotKeyCoordinator.signature,
                  let registeredEvent = coordinator.eventsByID[hotKeyID.id] else {
                return status
            }

            DispatchQueue.main.async {
                switch registeredEvent {
                case .action(let action): coordinator.actionHandler(action)
                case .preset(let id): coordinator.presetHandler(id)
                }
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

    private func registerAllHotKeys() {
        guard hotKeyRefs.isEmpty else {
            return
        }

        for action in GlobalHotKeyAction.allCases {
            let key = actionKeys[action] ?? GlobalHotKeyAction.defaultKeys[action] ?? .one
            register(key: key, id: action.rawValue, event: .action(action))
        }

        for (offset, entry) in presetKeys.sorted(by: { $0.key.uuidString < $1.key.uuidString }).enumerated() {
            register(key: entry.value, id: UInt32(1_000 + offset), event: .preset(entry.key))
        }
    }

    private func register(key: GlobalHotKeyKey, id: UInt32, event: GlobalHotKeyEvent) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            key.keyCode,
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
            return
        }

        hotKeyRefs[id] = hotKeyRef
        eventsByID[id] = event
    }

    private func unregisterAllHotKeys() {
        hotKeyRefs.values.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        eventsByID.removeAll()
    }
}

private enum GlobalHotKeyEvent {
    case action(GlobalHotKeyAction)
    case preset(UUID)
}

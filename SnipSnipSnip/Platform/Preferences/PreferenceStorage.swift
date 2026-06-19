import Foundation

nonisolated protocol PreferenceStorage {
    func object(forKey defaultName: String) -> Any?
    func data(forKey defaultName: String) -> Data?
    func string(forKey defaultName: String) -> String?
    func integer(forKey defaultName: String) -> Int
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: PreferenceStorage {}

nonisolated struct CodablePreference<Value: Codable> {
    private let key: String
    private let defaultValue: Value
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        key: String,
        defaultValue: Value,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder()
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.decoder = decoder
        self.encoder = encoder
    }

    func load(from storage: PreferenceStorage) -> Value {
        guard let data = storage.data(forKey: key),
              let value = try? decoder.decode(Value.self, from: data) else {
            return defaultValue
        }

        return value
    }

    func save(_ value: Value, to storage: PreferenceStorage) {
        guard let data = try? encoder.encode(value) else {
            return
        }

        storage.set(data, forKey: key)
    }
}

nonisolated struct AppPreferenceStores {
    let storage: PreferenceStorage
    let capture: CapturePreferenceStore
    let editor: EditorPreferenceStore
    let clipboard: ClipboardPreferenceStore
    let automation: AutomationPreferenceStore
    let archive: ArchivePreferenceStore
    let screenTools: ScreenToolPreferenceStore
    let video: VideoPreferenceStore
    let lifecycle: LifecyclePreferenceStore

    init(storage: PreferenceStorage) {
        self.storage = storage
        self.capture = CapturePreferenceStore(storage: storage)
        self.editor = EditorPreferenceStore(storage: storage)
        self.clipboard = ClipboardPreferenceStore(storage: storage)
        self.automation = AutomationPreferenceStore(storage: storage)
        self.archive = ArchivePreferenceStore(storage: storage)
        self.screenTools = ScreenToolPreferenceStore(storage: storage)
        self.video = VideoPreferenceStore(storage: storage)
        self.lifecycle = LifecyclePreferenceStore(storage: storage)
    }
}

import Combine
import Foundation

nonisolated struct ScreenshotCopyRequestKey: Equatable {
    let contentRevision: Int
    let appearance: ScreenshotOutputAppearance
    let outputSize: ScreenshotOutputSize
    var isPrivate = false
}

/// Owns transient output jobs independently of document edits and Undo.
@MainActor
final class ScreenshotOutputActivity: ObservableObject {
    @Published private(set) var isCopying = false
    @Published private(set) var showsCopyProgress = false
    @Published private(set) var isExporting = false
    @Published private(set) var showsExportProgress = false

    private struct CopyRequest {
        let key: ScreenshotCopyRequestKey
        let render: () async throws -> Data
        let deliver: (Data) throws -> Void
        let didSucceed: () -> Void
        let didFail: (Error) -> Void
        var completions: [(Bool) -> Void]
    }

    private let progressDelay: Duration
    private var currentCopy: CopyRequest?
    private var pendingCopy: CopyRequest?
    private var copyProgressTask: Task<Void, Never>?
    private var exportProgressTask: Task<Void, Never>?
    private var exportID: UUID?

    init(progressDelay: Duration = .milliseconds(150)) {
        self.progressDelay = progressDelay
    }

    func copy(
        key: ScreenshotCopyRequestKey,
        render: @escaping () async throws -> Data,
        deliver: @escaping (Data) throws -> Void,
        didSucceed: @escaping () -> Void,
        didFail: @escaping (Error) -> Void,
        completion: ((Bool) -> Void)?
    ) {
        if currentCopy?.key == key, pendingCopy == nil {
            if let completion { currentCopy?.completions.append(completion) }
            return
        }
        if pendingCopy?.key == key {
            if let completion { pendingCopy?.completions.append(completion) }
            return
        }
        let request = CopyRequest(
            key: key, render: render, deliver: deliver,
            didSucceed: didSucceed, didFail: didFail,
            completions: completion.map { [$0] } ?? []
        )
        if isCopying {
            let superseded = pendingCopy
            pendingCopy = request
            superseded?.completions.forEach { $0(false) }
            return
        }
        isCopying = true
        copyProgressTask = Task { [weak self, progressDelay] in
            do { try await Task.sleep(for: progressDelay) } catch { return }
            guard let self, self.isCopying else { return }
            self.showsCopyProgress = true
        }
        runCopy(request)
    }

    private func runCopy(_ request: CopyRequest) {
        currentCopy = request
        Task {
            var succeeded = false
            do {
                let data = try await request.render()
                // A later, changed result wins; an older render never overwrites it.
                if pendingCopy == nil {
                    try request.deliver(data)
                    succeeded = true
                    request.didSucceed()
                }
            } catch {
                if pendingCopy == nil { request.didFail(error) }
            }
            let completions = currentCopy?.completions ?? []
            currentCopy = nil
            let next = pendingCopy
            pendingCopy = nil
            if let next {
                runCopy(next)
            } else {
                copyProgressTask?.cancel()
                copyProgressTask = nil
                showsCopyProgress = false
                isCopying = false
            }
            completions.forEach { $0(succeeded) }
        }
    }

    /// Reserve the export action while the destination panel is also open.
    func beginExport() -> UUID? {
        guard !isExporting else { return nil }
        let id = UUID()
        exportID = id
        isExporting = true
        return id
    }

    func beginExportRendering(id: UUID) {
        guard exportID == id else { return }
        exportProgressTask?.cancel()
        exportProgressTask = Task { [weak self, progressDelay] in
            do { try await Task.sleep(for: progressDelay) } catch { return }
            guard let self, self.exportID == id else { return }
            self.showsExportProgress = true
        }
    }

    func finishExport(id: UUID) {
        guard exportID == id else { return }
        exportProgressTask?.cancel()
        exportProgressTask = nil
        exportID = nil
        showsExportProgress = false
        isExporting = false
    }
}

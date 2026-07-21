import Foundation
import UniformTypeIdentifiers

extension DocumentWorkflowModel {
    func exportCurrentGuide() {
        exportCurrentGuide(showProgressWindow: true)
    }

    func promisedGuidePayload() -> PromisedFilePayload? {
        guard let controller = guideEditorController,
              let format = controller.project.exportSettings.formats.sorted(by: { $0.rawValue < $1.rawValue }).first else { return nil }
        let document = controller.editableDocument(
            previewImage: GuideRenderer.renderPreview(project: controller.project, images: controller.stepImages)
        )
        let fileExtension: String
        let contentType: UTType
        switch format {
        case .pdf: fileExtension = "pdf"; contentType = .pdf
        case .docx: fileExtension = "docx"; contentType = UTType(filenameExtension: "docx") ?? .data
        case .gif: fileExtension = "gif"; contentType = .gif
        case .apng: fileExtension = "png"; contentType = .png
        case .fullMotionMP4, .highlightMP4, .slideshowMP4: fileExtension = "mp4"; contentType = .mpeg4Movie
        case .zip: fileExtension = "zip"; contentType = .zip
        case .stepImages: fileExtension = "zip"; contentType = .zip
        }
        let title = controller.project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = "SnipSnipSnip-Guide-\(title.isEmpty ? "Untitled" : title).\(fileExtension)"
        return PromisedFilePayload(suggestedFilename: filename, contentType: contentType) { destination in
            if format == .stepImages {
                let images = try await GuideExporter.export(document: document, format: .stepImages, directory: destination.deletingLastPathComponent())
                let entries = try FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil).compactMap { url -> (String, Data)? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return (url.lastPathComponent, data)
                }
                try GuideZIPWriterForDragOut.write(entries: entries, to: destination)
                try? FileManager.default.removeItem(at: images)
                return
            }
            let generated = try await GuideExporter.export(document: document, format: format, directory: destination.deletingLastPathComponent())
            guard generated.standardizedFileURL != destination.standardizedFileURL else { return }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: generated, to: destination)
        }
    }

    func exportCurrentGuide(showProgressWindow: Bool) {
        guard let controller = guideEditorController,
              let directory = dependencies.panels.selectExportDirectory() else { return }
        // Preview artwork is not an export input. Avoid rendering it on the
        // main actor before the background job begins.
        let document = controller.editableDocument()
        let formats = controller.project.exportSettings.formats
        pendingGuideExportTask?.cancel()
        pendingGuideExportWorkerTask?.cancel()
        lastGuideExportURLs = []
        guideExportIsActive = true
        guideExportProgress = nil
        guideExportStatus = "Preparing Guide export…"
        guideExportCurrentFormat = nil
        guideExportCancellationRequested = false
        let exportID = UUID()
        activeGuideExportID = exportID
        if showProgressWindow {
            GuideExportProgressWindowController.shared.show(workflow: self)
        }
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            await GuideExporter.exportAll(
                document: document,
                formats: formats,
                directory: directory,
                progress: { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeGuideExportID == exportID else { return }
                        self.guideExportCurrentFormat = update.format
                        self.guideExportProgress = update.overallFraction
                        self.guideExportStatus = update.detail
                    }
                }
            )
        }
        pendingGuideExportWorkerTask = worker
        pendingGuideExportTask = Task { @MainActor [weak self, weak controller] in
            guard let self else { return }
            let result = await worker.value
            guard activeGuideExportID == exportID else { return }
            guideExportIsActive = false
            guideExportProgress = nil
            guideExportCurrentFormat = nil
            pendingGuideExportWorkerTask = nil
            activeGuideExportID = nil
            lastGuideExportURLs = result.outputs
            if Task.isCancelled || guideExportCancellationRequested {
                guideExportStatus = "Guide export cancelled. Completed files were kept."
                return
            }
            if result.failures.isEmpty {
                controller?.notice = "Exported \(result.outputs.count) Guide files."
                guideExportStatus = "Exported \(result.outputs.count) Guide files."
                if !result.outputs.isEmpty { systemServices.workspace.activateFileViewerSelecting(result.outputs) }
            } else {
                let failures = result.failures.map { "\($0.key.label): \($0.value)" }.joined(separator: "\n")
                presentError("Some Guide exports failed.\n\(failures)")
                guideExportStatus = "Some formats failed; successful files were kept."
            }
        }
    }

    func cancelGuideExport() {
        guard pendingGuideExportWorkerTask != nil else { return }
        guideExportCancellationRequested = true
        guideExportStatus = "Cancelling Guide export…"
        pendingGuideExportTask?.cancel()
        pendingGuideExportWorkerTask?.cancel()
    }

    func showGuideExportProgress() {
        GuideExportProgressWindowController.shared.show(workflow: self)
    }

    func revealGuideExports() {
        guard !lastGuideExportURLs.isEmpty else { return }
        systemServices.workspace.activateFileViewerSelecting(lastGuideExportURLs)
    }

    func copyGuideExports() {
        guard !lastGuideExportURLs.isEmpty else { return }
        dependencies.panels.copyExportedFiles(lastGuideExportURLs)
    }

    func shareGuideExports() {
        guard !lastGuideExportURLs.isEmpty else { return }
        dependencies.panels.shareExportedFiles(lastGuideExportURLs)
    }

    func addRecentSnip(_ entry: DocumentHistoryEntry, to guide: GuideEditorController) {
        do {
            let document = try recoveryStore.restoreDocument(from: entry)
            guide.addImportedImage(document.capture.image, caption: entry.historySummary, advancedEdit: document)
        } catch {
            present(error)
        }
    }

    func exportCurrentAutomationGuide(
        _ format: GuideAutomationExportFormat,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope {
        guard let controller = guideEditorController else {
            return .failure(requestID: request.id, code: .noActiveGuide, message: "There is no open Guide to export.")
        }
        guard !controller.includedSteps.isEmpty else {
            return .failure(requestID: request.id, code: .guideHasNoSteps, message: "The Guide has no included steps.")
        }
        if [.fullMotionMP4, .highlightMP4].contains(format.guideFormat), controller.mediaSegmentURLs.isEmpty {
            return .failure(requestID: request.id, code: .guideSourceMediaUnavailable, message: "This Guide has no source media for the requested MP4 export.")
        }
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? systemServices.files.temporaryDirectory
        let document = controller.editableDocument(
            previewImage: GuideRenderer.renderPreview(project: controller.project, images: controller.stepImages)
        )
        do {
            let url = try await GuideExporter.export(document: document, format: format.guideFormat, directory: directory)
            return .success(
                requestID: request.id,
                payload: .guide(AutomationGuideSummary(
                    state: "exported",
                    stepCount: controller.includedSteps.count,
                    source: nil,
                    sourceVideoEnabled: !controller.mediaSegmentURLs.isEmpty
                )),
                outputs: [.init(kind: .savedFile, url: url, message: format.rawValue)]
            )
        } catch let error as GuideExportError {
            let code: AutomationErrorCode = error.localizedDescription.contains("source video") ? .guideSourceMediaUnavailable : .outputFailed
            return .failure(requestID: request.id, code: code, message: error.localizedDescription)
        } catch {
            return .failure(requestID: request.id, code: .outputFailed, message: error.localizedDescription)
        }
    }
}

nonisolated private enum GuideZIPWriterForDragOut {
    static func write(entries: [(String, Data)], to url: URL) throws {
        var output = Data(); var central = Data(); var offset: UInt32 = 0
        for (name, data) in entries {
            let nameData = Data(name.utf8); let crc = crc32(data); let size = UInt32(data.count)
            var local = Data(); local.le(UInt32(0x04034b50)); local.le(UInt16(20)); local.le(UInt16(0)); local.le(UInt16(0)); local.le(UInt16(0)); local.le(UInt16(0)); local.le(crc); local.le(size); local.le(size); local.le(UInt16(nameData.count)); local.le(UInt16(0)); local.append(nameData); local.append(data)
            output.append(local)
            var record = Data(); record.le(UInt32(0x02014b50)); record.le(UInt16(20)); record.le(UInt16(20)); record.le(UInt16(0)); record.le(UInt16(0)); record.le(UInt16(0)); record.le(UInt16(0)); record.le(crc); record.le(size); record.le(size); record.le(UInt16(nameData.count)); record.le(UInt16(0)); record.le(UInt16(0)); record.le(UInt16(0)); record.le(UInt16(0)); record.le(UInt32(0)); record.le(offset); record.append(nameData); central.append(record)
            offset += UInt32(local.count)
        }
        output.append(central); output.le(UInt32(0x06054b50)); output.le(UInt16(0)); output.le(UInt16(0)); output.le(UInt16(entries.count)); output.le(UInt16(entries.count)); output.le(UInt32(central.count)); output.le(offset); output.le(UInt16(0)); try output.write(to: url, options: .atomic)
    }
    private static func crc32(_ data: Data) -> UInt32 { var crc: UInt32 = 0xffffffff; for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb88320 & (0 &- (crc & 1))) } }; return crc ^ 0xffffffff }
}

nonisolated private extension Data {
    mutating func le<T: FixedWidthInteger>(_ input: T) { var value = input.littleEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
}

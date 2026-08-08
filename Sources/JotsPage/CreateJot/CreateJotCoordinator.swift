/*
 Jottre: Minimalistic jotting for iPhone, iPad and Mac.
 Copyright (C) 2021-2026 Anton Lorani

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

import UniformTypeIdentifiers
import UIKit

@MainActor
final class CreateJotCoordinator: Coordinator {

    var onEnd: (() -> Void)?

    private var retainedInfoAlertCoordinator: Coordinator?
    private var documentPickerAdapter: DocumentPickerAdapter?

    private let navigation: Navigation
    private let repository: CreateJotRepositoryProtocol
    private let directory: CreateJotCoordinatorFactory.Directory?
    private let externalFileImportService: ExternalFileImportServiceProtocol
    private let initialPDFData: Data?
    private let initialPDFName: String?

    init(
        navigation: Navigation,
        repository: CreateJotRepositoryProtocol,
        directory: CreateJotCoordinatorFactory.Directory?,
        externalFileImportService: ExternalFileImportServiceProtocol,
        initialPDFData: Data? = nil,
        initialPDFName: String? = nil
    ) {
        self.navigation = navigation
        self.repository = repository
        self.directory = directory
        self.externalFileImportService = externalFileImportService
        self.initialPDFData = initialPDFData
        self.initialPDFName = initialPDFName
    }

    func start() {
        if let initialPDFData {
            showNameAlert(pdfData: initialPDFData, suggestedName: initialPDFName)
            return
        }

        let alert = UIAlertController(
            title: L10n.Jots.Create.title,
            message: nil,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.Jots.Create.blankNote, style: .default) { [weak self] _ in
            self?.showNameAlert(pdfData: nil)
        })
        alert.addAction(UIAlertAction(title: L10n.Jots.Create.fromPDF, style: .default) { [weak self] _ in
            self?.presentPDFPicker()
        })
        alert.addAction(UIAlertAction(
            title: String(localized: "jots.create.import_jot", defaultValue: "Import .jot"),
            style: .default
        ) { [weak self] _ in
            self?.presentJotPicker()
        })
        alert.addAction(UIAlertAction(title: L10n.Action.cancel, style: .cancel) { [weak self] _ in
            self?.onEnd?()
        })
        navigation.present(alert, animated: true)
    }

    private func showNameAlert(pdfData: Data?, suggestedName: String? = nil) {
        let alertController = UIAlertController(
            title: L10n.Jots.Create.title,
            message: nil,
            preferredStyle: .alert
        )
        alertController.addTextField { textField in
            textField.placeholder = L10n.Jots.Create.namePlaceholder
            textField.text = suggestedName
            textField.autocapitalizationType = .sentences
            textField.returnKeyType = .done
        }
        alertController.addAction(
            UIAlertAction(title: L10n.Action.create, style: .default) { [weak self] _ in
                guard
                    let self,
                    let name = alertController.textFields?.first?.text,
                    !name.isEmpty
                else { return }
                handleCreateJot(name: name, pdfData: pdfData)
            }
        )
        alertController.addAction(UIAlertAction(title: L10n.Action.cancel, style: .cancel) { [weak self] _ in
            self?.onEnd?()
        })
        navigation.present(alertController, animated: true)
    }

    private func presentPDFPicker() {
        let adapter = DocumentPickerAdapter(
            externalFileImportService: externalFileImportService,
            onPick: { @MainActor [weak self] result in
                guard let self else { return }
                documentPickerAdapter = nil
                if result.documents.isEmpty {
                    showInfoAlert(
                        title: L10n.EditJot.PDF.Error.importFailed,
                        message: result.failedNames.joined(separator: "\n")
                    )
                } else if result.selectedCount == 1, let document = result.documents.first {
                    showNameAlert(pdfData: document.data, suggestedName: document.name)
                } else {
                    handleCreateJots(
                        pdfs: result.documents,
                        failedNames: result.failedNames
                    )
                }
            },
            onCancel: { @MainActor [weak self] in
                self?.onEnd?()
            }
        )
        documentPickerAdapter = adapter
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        picker.delegate = adapter
        picker.allowsMultipleSelection = true
        navigation.present(picker, animated: true)
    }

    private func handleCreateJots(
        pdfs: [(data: Data, name: String)],
        failedNames: [String] = []
    ) {
        Task { [weak self] in
            guard let self else { return }
            var failedNames = failedNames
            for pdf in pdfs {
                do {
                    _ = try await repository.createJot(name: pdf.name, directory: directory, pdfData: pdf.data)
                } catch {
                    failedNames.append(pdf.name)
                }
            }
            if !failedNames.isEmpty {
                showInfoAlert(
                    title: L10n.Jots.Create.Error.generic,
                    message: failedNames.joined(separator: "\n")
                )
            } else {
                onEnd?()
            }
        }
    }

    private func presentJotPicker() {
        let jotType = UTType(filenameExtension: JotFile.Info.fileExtension) ?? .data
        let adapter = DocumentPickerAdapter(
            externalFileImportService: externalFileImportService,
            onPick: { @MainActor [weak self] result in
                guard let self else { return }
                documentPickerAdapter = nil
                if let document = result.documents.first {
                    showJotImportAlert(data: document.data, suggestedName: document.name)
                } else {
                    showInfoAlert(
                        title: L10n.EditJot.PDF.Error.importFailed,
                        message: result.failedNames.joined(separator: "\n")
                    )
                }
            },
            onCancel: { @MainActor [weak self] in self?.onEnd?() }
        )
        documentPickerAdapter = adapter
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [jotType], asCopy: true)
        picker.delegate = adapter
        picker.allowsMultipleSelection = false
        navigation.present(picker, animated: true)
    }

    private func showJotImportAlert(data: Data, suggestedName: String?) {
        let alertController = UIAlertController(
            title: String(localized: "jots.import.jot.title", defaultValue: "Import Note"),
            message: nil, preferredStyle: .alert
        )
        alertController.addTextField { textField in
            textField.placeholder = L10n.Jots.Create.namePlaceholder
            textField.text = suggestedName
            textField.autocapitalizationType = .sentences
            textField.returnKeyType = .done
        }
        alertController.addAction(
            UIAlertAction(title: L10n.Action.create, style: .default) { [weak self] _ in
                guard
                    let self,
                    let name = alertController.textFields?.first?.text,
                    !name.isEmpty
                else { return }
                self.handleImportJot(name: name, data: data)
            }
        )
        alertController.addAction(UIAlertAction(title: L10n.Action.cancel, style: .cancel) { [weak self] _ in
            self?.onEnd?()
        })
        navigation.present(alertController, animated: true)
    }

    private func handleImportJot(name: String, data: Data) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let jotFileInfo = try await repository.importJotFile(name: name, data: data, directory: directory)
                navigation.open(url: EditJotURL(jotFileInfo: jotFileInfo))
                onEnd?()
            } catch CreateJotRepository.Failure.fileExists {
                showInfoAlert(title: L10n.Jots.Create.Error.fileExists(name), message: nil)
            } catch {
                showInfoAlert(title: L10n.Jots.Create.Error.generic, message: error.localizedDescription)
            }
        }
    }

    private func handleCreateJot(name: String, pdfData: Data?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await createAndOpen(name: name, pdfData: pdfData)
            } catch CreateJotRepository.Failure.fileExists {
                showInfoAlert(title: L10n.Jots.Create.Error.fileExists(name), message: nil)
            } catch {
                showInfoAlert(title: L10n.Jots.Create.Error.generic, message: error.localizedDescription)
            }
        }
    }

    private func createAndOpen(name: String, pdfData: Data?) async throws {
        let jotFileInfo = try await repository.createJot(name: name, directory: directory, pdfData: pdfData)
        navigation.open(url: EditJotURL(jotFileInfo: jotFileInfo))
        onEnd?()
    }

    private func showInfoAlert(title: String, message: String?) {
        let infoAlertCoordinator = InfoAlertCoordinator(
            navigation: navigation,
            title: title,
            message: message
        )
        retainedInfoAlertCoordinator = infoAlertCoordinator
        infoAlertCoordinator.onEnd = { [weak self] in
            self?.retainedInfoAlertCoordinator = nil
            self?.onEnd?()
        }
        infoAlertCoordinator.start()
    }
}

private struct DocumentPickerImportResult: Sendable {

    let documents: [(data: Data, name: String)]
    let selectedCount: Int
    let failedNames: [String]
}

@MainActor
private final class DocumentPickerAdapter: NSObject, UIDocumentPickerDelegate {

    private let externalFileImportService: ExternalFileImportServiceProtocol

    private let onPick: @MainActor @Sendable (DocumentPickerImportResult) -> Void
    private let onCancel: @MainActor @Sendable () -> Void
    private weak var pickerController: UIDocumentPickerViewController?
    private var pendingURLs: [URL] = []
    private var pendingSelectionTask: Task<Void, Never>?

    init(
        externalFileImportService: ExternalFileImportServiceProtocol,
        onPick: @MainActor @Sendable @escaping (DocumentPickerImportResult) -> Void,
        onCancel: @MainActor @Sendable @escaping () -> Void
    ) {
        self.externalFileImportService = externalFileImportService
        self.onPick = onPick
        self.onCancel = onCancel
    }

    deinit {
        pendingSelectionTask?.cancel()
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard !urls.isEmpty else {
            onCancel()
            return
        }
        pickerController = controller
        for url in urls where !pendingURLs.contains(url) {
            pendingURLs.append(url)
        }

        // Some File Provider implementations report one selected file per
        // delegate callback. Do not dismiss the picker after the first callback;
        // wait briefly for the rest of the same Open operation and import once.
        pendingSelectionTask?.cancel()
        pendingSelectionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            await self?.finishPendingSelection()
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingSelectionTask?.cancel()
        pendingSelectionTask = nil
        pendingURLs.removeAll(keepingCapacity: true)
        onCancel()
    }

    private func finishPendingSelection() async {
        let urls = pendingURLs
        pendingURLs.removeAll(keepingCapacity: true)
        pendingSelectionTask = nil
        guard !urls.isEmpty else { return }

        // `asCopy: true` has already materialized local copies. Read those
        // copies directly instead of coordinating them again for uploading.
        let externalFileImportService = externalFileImportService
        let importTask = Task.detached {
            var documents: [(data: Data, name: String)] = []
            var failedNames: [String] = []
            for url in urls {
                let name = url.deletingPathExtension().lastPathComponent
                do {
                    let data = try externalFileImportService.readFileCoordinated(fileURL: url)
                    documents.append((data: data, name: name))
                } catch {
                    failedNames.append(name)
                }
            }
            return DocumentPickerImportResult(
                documents: documents,
                selectedCount: urls.count,
                failedNames: failedNames
            )
        }
        if let pickerController {
            await Self.dismissIfNeeded(pickerController)
        }
        onPick(await importTask.value)
    }

    @MainActor
    private static func dismissIfNeeded(
        _ controller: UIDocumentPickerViewController
    ) async {
        guard controller.presentingViewController != nil, controller.viewIfLoaded?.window != nil else {
            return
        }

        if controller.isBeingDismissed, let transitionCoordinator = controller.transitionCoordinator {
            await withCheckedContinuation { continuation in
                transitionCoordinator.animate(alongsideTransition: nil) { _ in
                    continuation.resume()
                }
            }
            return
        }

        await withCheckedContinuation { continuation in
            controller.dismiss(animated: true) {
                continuation.resume()
            }
        }
    }
}

@MainActor
final class CreateJotBatchCoordinator: Coordinator {

    var onEnd: (() -> Void)?

    private let navigation: Navigation
    private let repository: CreateJotRepositoryProtocol
    private let directory: CreateJotCoordinatorFactory.Directory?
    private let pdfs: [(data: Data, name: String)]

    init(
        navigation: Navigation,
        repository: CreateJotRepositoryProtocol,
        directory: CreateJotCoordinatorFactory.Directory?,
        pdfs: [(data: Data, name: String)]
    ) {
        self.navigation = navigation
        self.repository = repository
        self.directory = directory
        self.pdfs = pdfs
    }

    func start() {
        Task { [weak self] in
            guard let self else { return }
            for pdf in pdfs {
                _ = try? await repository.createJot(name: pdf.name, directory: directory, pdfData: pdf.data)
            }
            onEnd?()
        }
    }
}

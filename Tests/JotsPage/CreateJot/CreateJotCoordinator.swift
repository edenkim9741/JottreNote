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

    init(
        navigation: Navigation,
        repository: CreateJotRepositoryProtocol,
        directory: CreateJotCoordinatorFactory.Directory?,
        externalFileImportService: ExternalFileImportServiceProtocol,
        initialPDFData: Data? = nil
    ) {
        self.navigation = navigation
        self.repository = repository
        self.directory = directory
        self.externalFileImportService = externalFileImportService
        self.initialPDFData = initialPDFData
    }

    func start() {
        if let initialPDFData {
            showNameAlert(pdfData: initialPDFData)
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
        alert.addAction(UIAlertAction(title: L10n.Action.cancel, style: .cancel) { [weak self] _ in
            self?.onEnd?()
        })
        navigation.present(alert, animated: true)
    }

    private func showNameAlert(pdfData: Data?) {
        let alertController = UIAlertController(
            title: L10n.Jots.Create.title,
            message: nil,
            preferredStyle: .alert
        )
        alertController.addTextField { textField in
            textField.placeholder = L10n.Jots.Create.namePlaceholder
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
            onPick: { @MainActor [weak self] data in
                guard let self else { return }
                // Explicitly dismiss picker first so it's fully gone before presenting next alert.
                // completion fires even if nothing is presented (picker already auto-dismissed).
                navigation.dismiss(animated: true) { [weak self, data] in
                    Task { @MainActor [weak self, data] in
                        guard let self else { return }
                        if let data {
                            showNameAlert(pdfData: data)
                        } else {
                            showInfoAlert(title: L10n.EditJot.PDF.Error.importFailed, message: nil)
                        }
                    }
                }
            },
            onCancel: { @MainActor [weak self] in
                self?.onEnd?()
            }
        )
        documentPickerAdapter = adapter
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        picker.delegate = adapter
        picker.allowsMultipleSelection = false
        navigation.present(picker, animated: true)
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

private final class DocumentPickerAdapter: NSObject, UIDocumentPickerDelegate {

    private let externalFileImportService: ExternalFileImportServiceProtocol

    private let onPick: @MainActor @Sendable (Data?) -> Void
    private let onCancel: @MainActor @Sendable () -> Void

    init(
        externalFileImportService: ExternalFileImportServiceProtocol,
        onPick: @MainActor @Sendable @escaping (Data?) -> Void,
        onCancel: @MainActor @Sendable @escaping () -> Void
    ) {
        self.externalFileImportService = externalFileImportService
        self.onPick = onPick
        self.onCancel = onCancel
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first else {
            Task { @MainActor [onCancel] in onCancel() }
            return
        }
        // Read on a background thread so the main thread stays free for the dismiss animation.
        Task.detached { [url, externalFileImportService, onPick] in
            let data: Data?
            do {
                // Import to the app's temp directory first so the file stays available even if the provider revokes access.
                let imported = try externalFileImportService.importAndReadFile(sourceURL: url)
                data = imported.data
            } catch {
                data = nil
            }
            await MainActor.run { onPick(data) }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Task { @MainActor [onCancel] in onCancel() }
    }
}

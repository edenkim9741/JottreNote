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

import UIKit

@MainActor
protocol CreateJotCoordinatorFactoryProtocol: Sendable {

    func make(
        navigation: Navigation,
        directory: CreateJotCoordinatorFactory.Directory?,
        pdfData: Data?,
        pdfName: String?
    ) -> Coordinator

    func makeBatch(
        navigation: Navigation,
        directory: CreateJotCoordinatorFactory.Directory?,
        pdfs: [(data: Data, name: String)]
    ) -> Coordinator
}

extension CreateJotCoordinatorFactoryProtocol {

    func make(
        navigation: Navigation,
        directory: CreateJotCoordinatorFactory.Directory?,
        pdfData: Data?
    ) -> Coordinator {
        make(navigation: navigation, directory: directory, pdfData: pdfData, pdfName: nil)
    }
}

struct CreateJotCoordinatorFactory: CreateJotCoordinatorFactoryProtocol {

    struct Directory: Hashable, Sendable {
        let url: URL
    }

    let repository: CreateJotRepositoryProtocol
    let externalFileImportService: ExternalFileImportServiceProtocol

    func make(
        navigation: Navigation,
        directory: Directory?,
        pdfData: Data? = nil,
        pdfName: String? = nil
    ) -> Coordinator {
        CreateJotCoordinator(
            navigation: navigation,
            repository: repository,
            directory: directory,
            externalFileImportService: externalFileImportService,
            initialPDFData: pdfData,
            initialPDFName: pdfName
        )
    }

    func makeBatch(
        navigation: Navigation,
        directory: Directory?,
        pdfs: [(data: Data, name: String)]
    ) -> Coordinator {
        CreateJotBatchCoordinator(
            repository: repository,
            directory: directory,
            pdfs: pdfs,
            logger: OSLogLogger(category: "CreateJotBatchCoordinator")
        )
    }
}

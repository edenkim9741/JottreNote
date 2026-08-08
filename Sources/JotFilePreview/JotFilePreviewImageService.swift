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

import PencilKit
import UIKit

struct JotFilePreviewImageService: JotFilePreviewImageServiceProtocol {

    enum Constants {

        static let size = CGSize(width: 160, height: 160)
    }

    enum Failure: Error {
        case couldNotRenderImage
        case fileNotDownloaded
    }

    private let jotFileService: JotFileServiceProtocol

    init(jotFileService: JotFileServiceProtocol) {
        self.jotFileService = jotFileService
    }

    func getPreviewImageData(
        jotFileInfo: JotFile.Info,
        userInterfaceStyle: UIUserInterfaceStyle,
        displayScale: CGFloat
    ) async throws -> Data {
        let jotFile = try jotFileService.readJotFile(jotFileInfo: jotFileInfo)
        let drawing = try PKDrawing(data: jotFile.jot.drawing)
        let pdfData = jotFile.jot.pdfData

        let aspectRatio = Constants.size.width / Constants.size.height
        let rect = CGRect(
            x: .zero,
            y: .zero,
            width: jotFile.jot.width,
            height: jotFile.jot.width / aspectRatio
        )
        let scale = displayScale * Constants.size.width / jotFile.jot.width

        let backgroundPageImage: UIImage? = if let pdfData {
            try? await MainActor.run {
                let service = PDFLoadService()
                let result = try service.load(
                    data: pdfData,
                    normalizedPageSize: CGSize(
                        width: jotFile.jot.width,
                        height: jotFile.jot.width * (4.0 / 3.0)
                    )
                )
                let previewPageSize = CGSize(
                    width: Constants.size.width,
                    height: Constants.size.width * result.pageSize.height / result.pageSize.width
                )
                return service.renderPage(
                    from: result,
                    at: 0,
                    targetSize: previewPageSize,
                    scale: displayScale
                )
            }
        } else { nil }

        let traitCollection = UITraitCollection(userInterfaceStyle: userInterfaceStyle)

        let image = await MainActor.run {
            let renderer = UIGraphicsImageRenderer(size: Constants.size)
            return renderer.image { context in
                traitCollection.performAsCurrent {
                    UIColor.systemBackground.setFill()
                    context.fill(CGRect(origin: .zero, size: Constants.size))

                    if let backgroundPageImage {
                        backgroundPageImage.draw(in: CGRect(origin: .zero, size: backgroundPageImage.size))
                    }

                    let drawingImage = drawing.image(from: rect, scale: scale)
                    drawingImage.draw(in: CGRect(origin: .zero, size: Constants.size))
                }
            }
        }

        guard let imageData = image.pngData() else {
            throw Failure.couldNotRenderImage
        }

        return imageData
    }
}

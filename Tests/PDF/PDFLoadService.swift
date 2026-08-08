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

import PDFKit
import UIKit

/// Loads and normalizes PDFs for rendering behind a `PKCanvasView`.
///
/// Normalization target matches Jottre's internal canvas coordinate system:
/// - Drawing width: 1200
/// - "iPad portrait" height baseline: 1600 (maps to ~1024pt when scaled to screen)
///
/// Pages are rendered into a fixed-size bitmap and the PDF page content is aspect-fit and centered.
@MainActor
final class PDFLoadService {

    struct Result {
        let pages: [UIImage]
        let pageSize: CGSize
    }

    enum Failure: Error {
        case couldNotParse
    }

    /// Default normalized page size for iPad portrait baseline.
    static let defaultNormalizedPageSize = CGSize(width: 1200, height: 1600)

    func load(
        data: Data,
        normalizedPageSize: CGSize = PDFLoadService.defaultNormalizedPageSize
    ) throws -> Result {
        guard let document = PDFDocument(data: data) else {
            throw Failure.couldNotParse
        }

        var pages: [UIImage] = []
        pages.reserveCapacity(document.pageCount)

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let image = render(
                page: page,
                targetSize: normalizedPageSize
            )
            pages.append(image)
        }

        return Result(pages: pages, pageSize: normalizedPageSize)
    }

    // MARK: - Private

    private func render(page: PDFPage, targetSize: CGSize) -> UIImage {
        let pageBounds = page.bounds(for: .mediaBox)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = min(UIScreen.main.scale, 2)
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: targetSize))

            guard pageBounds.width > 0, pageBounds.height > 0 else {
                return
            }

            // Aspect-fit inside the normalized canvas size.
            let scale = min(targetSize.width / pageBounds.width, targetSize.height / pageBounds.height)
            let scaledSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)

            // Center the page in the target bitmap.
            let offsetX = (targetSize.width - scaledSize.width) / 2
            let offsetY = (targetSize.height - scaledSize.height) / 2

            // PDF coordinate system is bottom-left; UIKit is top-left.
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: offsetX, y: offsetY + scaledSize.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
            ctx.cgContext.restoreGState()
        }
    }
}

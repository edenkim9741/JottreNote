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

@preconcurrency import PencilKit
import UIKit

protocol ShareJotRepositoryProtocol: Sendable {

    func exportJot(
        jotFileInfo: JotFile.Info,
        format: ShareFormat
    ) async throws -> URL
}

struct ShareJotRepository: ShareJotRepositoryProtocol {

    private enum Constants {
        static let ruledLineSpacing = CGFloat(32)
        static let pageSpacing = CGFloat(32)
        static let drawingScale = CGFloat(2)
        static let maximumRasterPixels = CGFloat(32_000_000)
        static let jpegCompressionQuality = CGFloat(0.9)
        static let maximumPageCount = 10_000
    }

    enum Failure: Error {
        case couldNotRenderImage
    }

    private let jotFileService: JotFileServiceProtocol
    private let fileService: FileServiceProtocol

    init(
        jotFileService: JotFileServiceProtocol,
        fileService: FileServiceProtocol
    ) {
        self.jotFileService = jotFileService
        self.fileService = fileService
    }

    func exportJot(
        jotFileInfo: JotFile.Info,
        format: ShareFormat
    ) async throws -> URL {
        let jotFile = try jotFileService.readJotFile(jotFileInfo: jotFileInfo)
        let drawing = try PKDrawing(data: jotFile.jot.drawing)
        let temporaryDirectory = fileService.temporaryDirectory()
        let background = makeBackground(jot: jotFile.jot)

        return try await exportOnMainActor(
            drawing: drawing,
            background: background,
            format: format,
            url:
                temporaryDirectory
                .appendingPathComponent(jotFileInfo.name)
                .appendingPathExtension(format.fileExtension)
        )
    }

    @MainActor
    private func exportOnMainActor(
        drawing: PKDrawing,
        background: Background,
        format: ShareFormat,
        url: URL
    ) throws -> URL {
        switch format {
        case .pdf:
            return try exportPDF(drawing: drawing, background: background, url: url)
        case .jpg:
            return try exportRaster(
                drawing: drawing,
                background: background,
                format: .jpg,
                url: url
            )
        case .png:
            return try exportRaster(
                drawing: drawing,
                background: background,
                format: .png,
                url: url
            )
        }
    }

    // MARK: - PDF

    @MainActor
    private func exportPDF(
        drawing: PKDrawing,
        background: Background,
        url: URL
    ) throws -> URL {
        let pageBounds = CGRect(origin: .zero, size: background.pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        let layers = JotDrawingLayerPartition(drawing: drawing)

        // Stream pages straight to disk. `pdfData` retained the whole output plus
        // every autoreleased page bitmap and could terminate the app on long notes.
        try renderer.writePDF(to: url) { rendererContext in
            for pageIndex in 0..<background.totalPages {
                autoreleasepool {
                    rendererContext.beginPage()
                    renderPageFoundation(
                        background,
                        logicalPageIndex: pageIndex,
                        in: pageBounds,
                        context: rendererContext.cgContext
                    )

                    let pageY = CGFloat(pageIndex) * background.pageStride
                    let canvasRect = CGRect(
                        x: 0,
                        y: pageY,
                        width: background.pageSize.width,
                        height: background.pageSize.height
                    )
                    renderPDFContent(
                        background,
                        logicalPageIndex: pageIndex,
                        in: pageBounds,
                        context: rendererContext.cgContext
                    )
                    VectorInkRenderer.draw(
                        drawing: layers.highlighter,
                        canvasRect: canvasRect,
                        pageBounds: pageBounds,
                        context: rendererContext.cgContext
                    )
                    VectorInkRenderer.draw(
                        drawing: layers.foreground,
                        canvasRect: canvasRect,
                        pageBounds: pageBounds,
                        context: rendererContext.cgContext
                    )
                }
            }
        }
        return url
    }

    // MARK: - JPG / PNG

    @MainActor
    private func exportRaster(
        drawing: PKDrawing,
        background: Background,
        format: ShareFormat,
        url: URL
    ) throws -> URL {
        let layers = JotDrawingLayerPartition(drawing: drawing)
        let rect = CGRect(
            x: 0,
            y: 0,
            width: background.pageSize.width,
            height: background.contentHeight
        )
        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.opaque = true
        rendererFormat.scale = rasterScale(for: rect)

        let image = UIGraphicsImageRenderer(bounds: rect, format: rendererFormat).image { rendererContext in
            rendererContext.cgContext.setFillColor(gray: 0.92, alpha: 1)
            rendererContext.cgContext.fill(rect)

            for pageIndex in 0..<background.totalPages {
                autoreleasepool {
                    let pageOriginY = CGFloat(pageIndex) * background.pageStride
                    let pageRect = CGRect(
                        x: 0,
                        y: pageOriginY,
                        width: background.pageSize.width,
                        height: background.pageSize.height
                    )
                    renderPageFoundation(
                        background,
                        logicalPageIndex: pageIndex,
                        in: pageRect,
                        context: rendererContext.cgContext
                    )
                    renderPDFContent(
                        background,
                        logicalPageIndex: pageIndex,
                        in: pageRect,
                        context: rendererContext.cgContext
                    )
                    let highlighterImage = renderDrawingImage(
                        drawing: layers.highlighter,
                        rect: pageRect,
                        scale: rendererFormat.scale
                    )
                    highlighterImage.draw(
                        in: pageRect,
                        blendMode: .multiply,
                        alpha: 1
                    )
                    let foregroundImage = renderDrawingImage(
                        drawing: layers.foreground,
                        rect: pageRect,
                        scale: rendererFormat.scale
                    )
                    foregroundImage.draw(in: pageRect)
                }
            }
        }

        let data: Data?
        switch format {
        case .jpg:
            data = image.jpegData(compressionQuality: Constants.jpegCompressionQuality)
        case .png:
            data = image.pngData()
        case .pdf:
            data = nil
        }
        guard let data else { throw Failure.couldNotRenderImage }
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Page layout and rendering

    private struct Background {
        let document: PDFRenderDocument?
        let pageSize: CGSize
        let logicalToPDFPage: [Int?]
        let totalPages: Int

        var pageStride: CGFloat { pageSize.height + Constants.pageSpacing }

        var contentHeight: CGFloat {
            CGFloat(totalPages) * pageSize.height
                + CGFloat(max(0, totalPages - 1)) * Constants.pageSpacing
        }

        func pdfPageIndex(at logicalIndex: Int) -> Int? {
            guard document != nil, logicalToPDFPage.indices.contains(logicalIndex) else { return nil }
            return logicalToPDFPage[logicalIndex]
        }
    }

    private func makeBackground(jot: Jot) -> Background {
        let defaultSize = CGSize(width: jot.width, height: jot.width * (4.0 / 3.0))
        guard
            let pdfData = jot.pdfData,
            let result = try? PDFLoadService().load(data: pdfData, normalizedPageSize: defaultSize)
        else {
            let safeExtraPages = min(max(0, jot.extraPages), Constants.maximumPageCount - 1)
            return Background(
                document: nil,
                pageSize: defaultSize,
                logicalToPDFPage: [],
                totalPages: 1 + safeExtraPages
            )
        }

        let pdfPageCount = min(result.pageCount, Constants.maximumPageCount)
        let safeExtraPages = min(
            max(0, jot.extraPages),
            Constants.maximumPageCount - pdfPageCount
        )
        let legacySlots = Array(pdfPageCount..<(pdfPageCount + safeExtraPages))
        let sourceSlots = jot.pdfInsertedPageSlots.isEmpty ? legacySlots : jot.pdfInsertedPageSlots
        let maximumSlot = min(
            Constants.maximumPageCount,
            pdfPageCount + min(sourceSlots.count, Constants.maximumPageCount - pdfPageCount)
        )
        let slots = Array(Set(sourceSlots.filter { $0 >= 0 && $0 < maximumSlot })).sorted()
        let totalPages = max(1, pdfPageCount + slots.count)
        let slotSet = Set(slots)
        var nextPDFPage = 0
        let logicalToPDFPage: [Int?] = (0..<totalPages).map { logicalPage in
            guard !slotSet.contains(logicalPage), nextPDFPage < pdfPageCount else { return nil }
            defer { nextPDFPage += 1 }
            return nextPDFPage
        }
        return Background(
            document: result.document,
            pageSize: result.pageSize,
            logicalToPDFPage: logicalToPDFPage,
            totalPages: totalPages
        )
    }

    @MainActor
    private func renderPageFoundation(
        _ background: Background,
        logicalPageIndex: Int,
        in rect: CGRect,
        context: CGContext
    ) {
        if background.pdfPageIndex(at: logicalPageIndex) != nil {
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(rect)
        } else {
            drawRuledPage(in: rect, context: context)
        }
    }

    @MainActor
    private func renderPDFContent(
        _ background: Background,
        logicalPageIndex: Int,
        in rect: CGRect,
        context: CGContext
    ) {
        guard
            let document = background.document,
            let pageIndex = background.pdfPageIndex(at: logicalPageIndex)
        else { return }
        document.drawPage(
            at: pageIndex,
            in: rect,
            context: context,
            fillsBackground: false
        )
    }

    @MainActor
    private func drawRuledPage(in rect: CGRect, context: CGContext) {
        context.setFillColor(red: 0.99, green: 0.97, blue: 0.90, alpha: 1)
        context.fill(rect)
        context.setStrokeColor(gray: 0.62, alpha: 0.55)
        context.setLineWidth(0.5)
        var lineY = rect.minY + Constants.ruledLineSpacing
        while lineY < rect.maxY {
            context.move(to: CGPoint(x: rect.minX, y: lineY))
            context.addLine(to: CGPoint(x: rect.maxX, y: lineY))
            context.strokePath()
            lineY += Constants.ruledLineSpacing
        }
    }

    @MainActor
    private func renderDrawingImage(drawing: PKDrawing, rect: CGRect, scale: CGFloat) -> UIImage {
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: rect, scale: max(0.1, scale))
        }
        return image
    }

    private func rasterScale(for rect: CGRect) -> CGFloat {
        let logicalPixels = rect.width * rect.height
        guard logicalPixels.isFinite, logicalPixels > 0 else { return 1 }
        return max(0.1, min(Constants.drawingScale, sqrt(Constants.maximumRasterPixels / logicalPixels)))
    }
}

extension ShareFormat {

    fileprivate var fileExtension: String {
        switch self {
        case .pdf: "pdf"
        case .jpg: "jpg"
        case .png: "png"
        }
    }
}

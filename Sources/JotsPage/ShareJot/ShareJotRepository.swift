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
        static let vectorInkSampleDistance = CGFloat(1.5)
        static let minimumVectorInkRadius = CGFloat(0.1)
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
                    renderVectorInk(
                        drawing: layers.highlighter,
                        canvasRect: canvasRect,
                        pageBounds: pageBounds,
                        context: rendererContext.cgContext
                    )
                    renderVectorInk(
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

    /// Writes PencilKit ink as filled PDF paths. `PKDrawing.image` must not be
    /// used here because it embeds a fixed-resolution bitmap in the PDF.
    @MainActor
    private func renderVectorInk(
        drawing: PKDrawing,
        canvasRect: CGRect,
        pageBounds: CGRect,
        context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        context.clip(to: pageBounds)
        context.translateBy(x: -canvasRect.minX, y: -canvasRect.minY)

        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        for stroke in drawing.strokes where stroke.renderBounds.intersects(canvasRect) {
            guard let vectorPath = makeVectorPath(for: stroke) else { continue }
            let color = stroke.ink.color.resolvedColor(with: lightTraits)

            context.saveGState()
            context.concatenate(stroke.transform)
            if let mask = stroke.mask {
                context.addPath(mask.cgPath)
                context.clip()
            }
            context.setFillColor(color.cgColor)
            context.setAlpha(vectorPath.opacity)
            if stroke.ink.inkType == .marker {
                context.setBlendMode(.multiply)
            }
            context.addPath(vectorPath.path)
            context.fillPath()
            context.restoreGState()
        }
    }

    private struct VectorInkPath {
        let path: CGPath
        let opacity: CGFloat
    }

    @MainActor
    private func makeVectorPath(for stroke: PKStroke) -> VectorInkPath? {
        let path = CGMutablePath()
        var opacityTotal = CGFloat.zero
        var opacitySampleCount = 0

        let ranges = stroke.maskedPathRanges
        if ranges.isEmpty {
            let points: [PKStrokePoint]
            if stroke.path.count > 1 {
                points = Array(
                    stroke.path.interpolatedPoints(
                        in: 0...CGFloat(stroke.path.count - 1),
                        by: .distance(Constants.vectorInkSampleDistance)
                    )
                )
            } else {
                points = Array(stroke.path)
            }
            appendVectorOutline(
                points: points,
                to: path,
                opacityTotal: &opacityTotal,
                opacitySampleCount: &opacitySampleCount
            )
        } else {
            for range in ranges {
                let points = Array(
                    stroke.path.interpolatedPoints(
                        in: range,
                        by: .distance(Constants.vectorInkSampleDistance)
                    )
                )
                appendVectorOutline(
                    points: points,
                    to: path,
                    opacityTotal: &opacityTotal,
                    opacitySampleCount: &opacitySampleCount
                )
            }
        }

        guard !path.isEmpty else { return nil }
        let opacity =
            opacitySampleCount > 0
            ? max(0, min(1, opacityTotal / CGFloat(opacitySampleCount)))
            : 1
        return VectorInkPath(path: path, opacity: opacity)
    }

    @MainActor
    private func appendVectorOutline(
        points: [PKStrokePoint],
        to path: CGMutablePath,
        opacityTotal: inout CGFloat,
        opacitySampleCount: inout Int
    ) {
        let samples = points.compactMap { point -> (location: CGPoint, radius: CGFloat)? in
            guard point.location.x.isFinite, point.location.y.isFinite else { return nil }
            let radius = CGFloat(
                max(
                    Double(Constants.minimumVectorInkRadius),
                    max(abs(point.size.width), abs(point.size.height)) * 0.5
                )
            )
            opacityTotal += max(0, min(1, point.opacity))
            opacitySampleCount += 1
            return (point.location, radius)
        }
        guard let first = samples.first else { return }

        if samples.count == 1 {
            path.addEllipse(
                in: CGRect(
                    x: first.location.x - first.radius,
                    y: first.location.y - first.radius,
                    width: first.radius * 2,
                    height: first.radius * 2
                )
            )
            return
        }

        var leftEdge: [CGPoint] = []
        var rightEdge: [CGPoint] = []
        leftEdge.reserveCapacity(samples.count)
        rightEdge.reserveCapacity(samples.count)

        for index in samples.indices {
            let previous = samples[index > samples.startIndex ? samples.index(before: index) : index].location
            let next = samples[
                index < samples.index(before: samples.endIndex)
                    ? samples.index(after: index)
                    : index
            ].location
            let tangent = CGPoint(x: next.x - previous.x, y: next.y - previous.y)
            let length = hypot(tangent.x, tangent.y)
            let normal =
                length > 0.0001
                ? CGPoint(x: -tangent.y / length, y: tangent.x / length)
                : CGPoint(x: 0, y: 1)
            let sample = samples[index]
            leftEdge.append(
                CGPoint(
                    x: sample.location.x + normal.x * sample.radius,
                    y: sample.location.y + normal.y * sample.radius
                )
            )
            rightEdge.append(
                CGPoint(
                    x: sample.location.x - normal.x * sample.radius,
                    y: sample.location.y - normal.y * sample.radius
                )
            )
        }

        path.move(to: leftEdge[0])
        for point in leftEdge.dropFirst() {
            path.addLine(to: point)
        }
        for point in rightEdge.reversed() {
            path.addLine(to: point)
        }
        path.closeSubpath()

        for sample in [first, samples[samples.index(before: samples.endIndex)]] {
            path.addEllipse(
                in: CGRect(
                    x: sample.location.x - sample.radius,
                    y: sample.location.y - sample.radius,
                    width: sample.radius * 2,
                    height: sample.radius * 2
                )
            )
        }
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

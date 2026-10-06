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

import CoreGraphics
import UIKit

/// Immutable Core Graphics PDF storage used by metadata readers, exporters and
/// background page rasterization. Each render slot owns an independent
/// `CGPDFDocument`, allowing a small amount of safe parallelism without sharing
/// one Core Graphics document across drawing threads.
final class PDFRenderDocument: @unchecked Sendable {

    private final class RenderSlot {
        let document: CGPDFDocument
        let lock = NSLock()

        init(document: CGPDFDocument) {
            self.document = document
        }
    }

    private let renderSlots: [RenderSlot]
    private let renderSlotSelectionLock = NSLock()
    private var nextRenderSlotIndex = 0
    private let storedPageCount: Int

    var pageCount: Int {
        storedPageCount
    }

    init?(data: Data) {
        guard !data.isEmpty else { return nil }

        // Core Graphics does not guarantee that one CGPDFDocument can render
        // multiple pages concurrently. Keep a small pool of independent
        // documents instead: nearby page bitmaps can be prepared in parallel
        // without serializing every draw behind a single document lock.
        let renderSlotCount = min(3, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        var slots: [RenderSlot] = []
        for _ in 0..<renderSlotCount {
            guard
                let provider = CGDataProvider(data: data as CFData),
                let document = CGPDFDocument(provider),
                document.numberOfPages > 0,
                document.isUnlocked
            else { continue }
            slots.append(RenderSlot(document: document))
        }
        guard let firstDocument = slots.first?.document else { return nil }
        renderSlots = slots
        storedPageCount = firstDocument.numberOfPages
    }

    /// Jottre uses zero-based page indices; Core Graphics PDF pages are one-based.
    func bounds(at index: Int) -> CGRect {
        withPage(at: index) { page in
            PDFPageRenderer.displayBounds(for: page)
        } ?? .zero
    }

    func drawPage(
        at index: Int,
        in rect: CGRect,
        context: CGContext,
        fillsBackground: Bool = true
    ) {
        // CGPDFPage draws the page content stream only; PDF annotations are not
        // part of that stream. PencilKit remains the sole visible ink layer in
        // the editor, so Jotttrenote annotations cannot become ghost strokes.
        withPage(at: index) { page in
            PDFPageRenderer.draw(
                page: page,
                in: rect,
                context: context,
                fillsBackground: fillsBackground
            )
        }
    }

    @discardableResult
    private func withPage<T>(at index: Int, _ operation: (CGPDFPage) -> T) -> T? {
        guard index >= 0, index < storedPageCount else { return nil }

        renderSlotSelectionLock.lock()
        let startingIndex = nextRenderSlotIndex
        nextRenderSlotIndex = (nextRenderSlotIndex + 1) % renderSlots.count
        renderSlotSelectionLock.unlock()

        // Prefer an idle renderer. If every slot is busy, wait on the next
        // round-robin slot so work remains bounded and fairly distributed.
        for offset in 0..<renderSlots.count {
            let slot = renderSlots[(startingIndex + offset) % renderSlots.count]
            guard slot.lock.try() else { continue }
            defer { slot.lock.unlock() }
            guard !Task.isCancelled else { return nil }
            guard let page = slot.document.page(at: index + 1) else { return nil }
            return operation(page)
        }

        let slot = renderSlots[startingIndex]
        slot.lock.lock()
        defer { slot.lock.unlock() }
        guard !Task.isCancelled else { return nil }
        guard let page = slot.document.page(at: index + 1) else { return nil }
        return operation(page)
    }
}

/// Parses a PDF and maps its first page to Jottre's normalized canvas width.
///
/// The PDF pages stay vector-backed. Callers render only the page and resolution
/// they currently need instead of eagerly allocating a full-size bitmap per page.
struct PDFLoadService: Sendable {

    struct Result: Sendable {
        let document: PDFRenderDocument
        let pageSize: CGSize

        var pageCount: Int { document.pageCount }
    }

    enum Failure: Error {
        case couldNotParse
        case emptyDocument
    }

    static let defaultNormalizedPageSize = CGSize(width: 1200, height: 1600)

    func load(
        data: Data,
        normalizedPageSize: CGSize = PDFLoadService.defaultNormalizedPageSize
    ) throws -> Result {
        guard let document = PDFRenderDocument(data: data) else {
            throw Failure.couldNotParse
        }
        let firstPageBounds = document.bounds(at: 0)
        guard firstPageBounds.width > 0, firstPageBounds.height > 0 else {
            throw Failure.emptyDocument
        }

        return Result(
            document: document,
            pageSize: makeTargetSize(pageBounds: firstPageBounds, normalizedPageSize: normalizedPageSize)
        )
    }

    func renderPage(
        from result: Result,
        at index: Int,
        targetSize: CGSize,
        scale: CGFloat,
        fillsBackground: Bool = true
    ) -> UIImage? {
        guard
            targetSize.width.isFinite,
            targetSize.height.isFinite,
            targetSize.width > 0,
            targetSize.height > 0,
            index >= 0,
            index < result.pageCount
        else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = max(1, scale)
        format.opaque = fillsBackground
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { rendererContext in
            result.document.drawPage(
                at: index,
                in: CGRect(origin: .zero, size: targetSize),
                context: rendererContext.cgContext,
                fillsBackground: fillsBackground
            )
        }
    }

    private func makeTargetSize(pageBounds: CGRect, normalizedPageSize: CGSize) -> CGSize {
        guard
            normalizedPageSize.width.isFinite,
            normalizedPageSize.width > 0
        else { return Self.defaultNormalizedPageSize }

        guard pageBounds.width > 0, pageBounds.height > 0 else {
            return normalizedPageSize
        }

        let height = normalizedPageSize.width * pageBounds.height / pageBounds.width
        guard height.isFinite, height > 0 else { return normalizedPageSize }
        return CGSize(width: normalizedPageSize.width, height: height)
    }

}

/// Shared Core Graphics PDF renderer. `CGPDFPage` keeps PDF content vector-based,
/// handles rotated/cropped pages through its drawing transform, and avoids PDFKit's
/// appearance-dependent thumbnail path.
enum PDFPageRenderer {

    static func validBounds(for page: CGPDFPage) -> CGRect {
        let cropBounds = page.getBoxRect(.cropBox)
        if cropBounds.width.isFinite, cropBounds.height.isFinite,
            cropBounds.width > 0, cropBounds.height > 0
        {
            return cropBounds
        }
        let mediaBounds = page.getBoxRect(.mediaBox)
        guard
            mediaBounds.width.isFinite,
            mediaBounds.height.isFinite,
            mediaBounds.width > 0,
            mediaBounds.height > 0
        else { return .zero }
        return mediaBounds
    }

    /// The PDF page boxes are expressed before the page's intrinsic rotation is
    /// applied. `getDrawingTransform` does apply that rotation, so using the raw
    /// box size for the destination creates a portrait canvas for a landscape
    /// page (or vice versa) and leaves a large letterbox around the PDF.
    static func displayBounds(for page: CGPDFPage) -> CGRect {
        let bounds = validBounds(for: page)
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        let normalizedRotation = ((page.rotationAngle % 360) + 360) % 360
        if normalizedRotation == 90 || normalizedRotation == 270 {
            return CGRect(origin: .zero, size: CGSize(width: bounds.height, height: bounds.width))
        }
        return CGRect(origin: .zero, size: bounds.size)
    }

    static func draw(
        page: CGPDFPage,
        in rect: CGRect,
        context: CGContext,
        fillsBackground: Bool = true
    ) {
        guard
            rect.width.isFinite,
            rect.height.isFinite,
            rect.width > 0,
            rect.height > 0
        else { return }

        context.saveGState()
        if fillsBackground {
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(rect)
        }

        // UIKit contexts are Y-down while PDF contexts are Y-up. Reflect only the
        // destination page rectangle, then let Core Graphics account for crop-box
        // origins and page rotation.
        context.translateBy(x: 0, y: rect.minY + rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let cropBounds = page.getBoxRect(.cropBox)
        let mediaBounds = page.getBoxRect(.mediaBox)
        let box: CGPDFBox? =
            if cropBounds.width.isFinite,
                cropBounds.height.isFinite,
                cropBounds.width > 0,
                cropBounds.height > 0
            {
                .cropBox
            } else if mediaBounds.width.isFinite,
                mediaBounds.height.isFinite,
                mediaBounds.width > 0,
                mediaBounds.height > 0
            {
                .mediaBox
            } else {
                nil
            }
        guard let box else {
            context.restoreGState()
            return
        }
        // `CGPDFPage.getDrawingTransform` does not enlarge a page when the
        // destination is larger than the PDF's point size. For example, an A4
        // page (595 x 842) stays at scale 1 and is merely centered in Jottre's
        // 1200-wide canvas, which creates the very large margin seen in the
        // editor. Ask it only for the crop-origin/rotation transform at the
        // PDF's native displayed size, then apply the required enlargement
        // ourselves.
        let nativeDisplayBounds = displayBounds(for: page)
        guard nativeDisplayBounds.width > 0, nativeDisplayBounds.height > 0 else {
            context.restoreGState()
            return
        }
        let pageTransform = page.getDrawingTransform(
            box,
            rect: nativeDisplayBounds,
            rotate: 0,
            preserveAspectRatio: false
        )
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(
            x: rect.width / nativeDisplayBounds.width,
            y: rect.height / nativeDisplayBounds.height
        )
        context.concatenate(pageTransform)
        context.drawPDFPage(page)
        context.restoreGState()
    }
}

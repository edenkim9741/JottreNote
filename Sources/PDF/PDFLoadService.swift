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

import Compression
import CoreGraphics
import UIKit

/// Removes a no-op soft mask emitted by some iLovePDF documents.
///
/// The affected files wrap an opaque, page-sized color rectangle in a
/// luminosity mask whose form is itself a solid white rectangle. The mask is
/// mathematically equivalent to no mask at all, but Core Graphics clips it to
/// roughly half of the form's width. Replacing only that exact mask with
/// `/None` keeps the original PDF vector content intact and avoids carrying a
/// second PDF renderer just for this producer bug.
enum PDFCompatibilitySanitizer {

    private struct SoftMask {
        let range: Range<Int>
        let objectNumber: Int
        let generation: Int
    }

    private static let producerMarker = Data("/Producer (iLovePDF)".utf8)
    private static let softMaskMarker = Data("/SMask".utf8)
    private static let streamMarker = Data("stream".utf8)
    private static let maximumDictionaryLength = 4_096
    private static let maximumObjectHeaderLength = 65_536
    private static let maximumDecodedMaskLength = 65_536

    static func removingRedundantOpaqueSoftMasks(from data: Data) -> Data {
        guard
            data.range(of: producerMarker) != nil,
            let masks = softMasks(in: data),
            !masks.isEmpty
        else { return data }

        let redundantRanges = masks.compactMap { mask -> Range<Int>? in
            isOpaqueWhiteMask(
                objectNumber: mask.objectNumber,
                generation: mask.generation,
                in: data
            ) ? mask.range : nil
        }
        guard !redundantRanges.isEmpty else { return data }

        var sanitized = data
        let replacementPrefix = Data("/SMask /None".utf8)
        for range in redundantRanges where range.count >= replacementPrefix.count {
            var replacement = Data(repeating: UInt8(ascii: " "), count: range.count)
            replacement.replaceSubrange(0..<replacementPrefix.count, with: replacementPrefix)
            sanitized.replaceSubrange(range, with: replacement)
        }
        return sanitized
    }

    /// `nil` means malformed PDF syntax. In that case the original data is
    /// deliberately left untouched.
    private static func softMasks(in data: Data) -> [SoftMask]? {
        var result: [SoftMask] = []
        var searchStart = data.startIndex

        while searchStart < data.endIndex,
            let markerRange = data.range(
                of: softMaskMarker,
                in: searchStart..<data.endIndex
            )
        {
            searchStart = markerRange.upperBound
            let dictionaryStart = skipWhitespace(in: data, from: markerRange.upperBound)
            guard dictionaryStart + 1 < data.endIndex else { continue }

            // Image masks commonly use `/SMask 12 0 R`; only direct soft-mask
            // dictionaries are candidates for this compatibility repair.
            guard data[dictionaryStart] == UInt8(ascii: "<"),
                data[dictionaryStart + 1] == UInt8(ascii: "<")
            else {
                continue
            }
            guard let dictionaryEnd = matchingDictionaryEnd(in: data, from: dictionaryStart) else {
                return nil
            }

            let fullRange = markerRange.lowerBound..<dictionaryEnd
            let dictionary = String(
                decoding: data[dictionaryStart..<dictionaryEnd],
                as: UTF8.self
            )
            guard
                dictionary.range(
                    of: #"/S\s*/Luminosity(?:\s|/|>|$)"#,
                    options: .regularExpression
                ) != nil
            else { continue }
            guard let reference = objectReference(after: "/G", in: dictionary) else {
                continue
            }
            result.append(
                SoftMask(
                    range: fullRange,
                    objectNumber: reference.objectNumber,
                    generation: reference.generation
                )
            )
        }
        return result
    }

    private static func matchingDictionaryEnd(in data: Data, from start: Int) -> Int? {
        var index = start
        var depth = 0
        let limit = min(data.endIndex, start + maximumDictionaryLength)

        while index + 1 < limit {
            let pair = (data[index], data[index + 1])
            if pair == (UInt8(ascii: "<"), UInt8(ascii: "<")) {
                depth += 1
                index += 2
                continue
            }
            if pair == (UInt8(ascii: ">"), UInt8(ascii: ">")) {
                depth -= 1
                index += 2
                if depth == 0 { return index }
                continue
            }
            index += 1
        }
        return nil
    }

    private static func objectReference(
        after name: String,
        in dictionary: String
    ) -> (objectNumber: Int, generation: Int)? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = escapedName + #"\s+(\d+)\s+(\d+)\s+R(?:\s|/|>|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(dictionary.startIndex..<dictionary.endIndex, in: dictionary)
        guard let match = expression.firstMatch(in: dictionary, range: fullRange),
            let objectRange = Range(match.range(at: 1), in: dictionary),
            let generationRange = Range(match.range(at: 2), in: dictionary),
            let objectNumber = Int(dictionary[objectRange]),
            let generation = Int(dictionary[generationRange])
        else {
            return nil
        }
        return (objectNumber, generation)
    }

    private static func isOpaqueWhiteMask(
        objectNumber: Int,
        generation: Int,
        in data: Data
    ) -> Bool {
        let objectMarker = Data("\(objectNumber) \(generation) obj".utf8)
        var searchStart = data.startIndex

        while searchStart < data.endIndex,
            let objectRange = data.range(
                of: objectMarker,
                in: searchStart..<data.endIndex
            )
        {
            searchStart = objectRange.upperBound
            guard isTokenBoundary(in: data, before: objectRange.lowerBound),
                isTokenBoundary(in: data, after: objectRange.upperBound)
            else {
                continue
            }

            let headerLimit = min(data.endIndex, objectRange.upperBound + maximumObjectHeaderLength)
            guard
                let streamRange = data.range(
                    of: streamMarker,
                    in: objectRange.upperBound..<headerLimit
                )
            else { continue }

            let header = String(
                decoding: data[objectRange.upperBound..<streamRange.lowerBound],
                as: UTF8.self
            )
            guard header.contains("/Subtype /Form"),
                header.contains("/Filter /FlateDecode"),
                header.contains("/S /Transparency"),
                let length = firstInteger(after: "/Length", in: header),
                length > 0,
                let bounds = boundingBox(in: header)
            else {
                continue
            }

            let encodedStart = streamDataStart(in: data, after: streamRange.upperBound)
            guard encodedStart + length <= data.endIndex else { continue }
            let encoded = Data(data[encodedStart..<(encodedStart + length)])
            guard let decoded = inflate(encoded),
                isFullBoundsOpaqueWhiteFill(decoded, bounds: bounds)
            else {
                continue
            }
            return true
        }
        return false
    }

    private static func firstInteger(after name: String, in text: String) -> Int? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = escapedName + #"\s+(\d+)(?:\s|/|>|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: fullRange),
            let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[valueRange])
    }

    private static func boundingBox(in header: String) -> CGRect? {
        let number = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        let pattern =
            #"/BBox\s*\[\s*("# + number + #")\s+("# + number
            + #")\s+("# + number + #")\s+("# + number + #")\s*\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(header.startIndex..<header.endIndex, in: header)
        guard let match = expression.firstMatch(in: header, range: fullRange) else { return nil }
        let values: [CGFloat] = (1...4).compactMap { index in
            guard let range = Range(match.range(at: index), in: header),
                let value = Double(header[range])
            else { return nil }
            return CGFloat(value)
        }
        guard values.count == 4 else { return nil }
        return CGRect(
            x: values[0],
            y: values[1],
            width: values[2] - values[0],
            height: values[3] - values[1]
        )
    }

    private static func inflate(_ encoded: Data) -> Data? {
        // PDF FlateDecode streams use the zlib wrapper (RFC 1950), while
        // Compression's COMPRESSION_ZLIB algorithm consumes the raw DEFLATE
        // payload. Validate and remove the two-byte header and the
        // trailing Adler-32 before decoding.
        guard encoded.count > 6 else { return nil }
        let compressionMethod = encoded[encoded.startIndex]
        let flags = encoded[encoded.startIndex + 1]
        let header = (UInt16(compressionMethod) << 8) | UInt16(flags)
        guard compressionMethod & 0x0F == 8,
            header % 31 == 0,
            flags & 0x20 == 0
        else {
            return nil
        }
        let payloadStart = encoded.startIndex + 2
        let payloadEnd = encoded.endIndex - 4
        let payload = Data(encoded[payloadStart..<payloadEnd])

        var decoded = Data(count: maximumDecodedMaskLength)
        let decodedCount = decoded.withUnsafeMutableBytes { destination in
            payload.withUnsafeBytes { source in
                guard let destinationAddress = destination.bindMemory(to: UInt8.self).baseAddress,
                    let sourceAddress = source.bindMemory(to: UInt8.self).baseAddress
                else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationAddress,
                    destination.count,
                    sourceAddress,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount > 0, decodedCount < maximumDecodedMaskLength else { return nil }
        decoded.count = decodedCount
        return decoded
    }

    /// Recognizes the exact iLovePDF mask program: identity transform, a
    /// rectangle equal to the form BBox, DeviceRGB white, full fill.
    private static func isFullBoundsOpaqueWhiteFill(
        _ decoded: Data,
        bounds: CGRect
    ) -> Bool {
        let tokens = String(decoding: decoded, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard tokens.count == 35 else { return false }

        let fixed: [Int: String] = [
            0: "q", 1: "q", 2: "1", 3: "0", 4: "0", 5: "1", 6: "0", 7: "0", 8: "cm",
            9: "0", 10: "0", 11: "m", 12: "0", 14: "l", 17: "l", 19: "0", 20: "l", 21: "h",
            22: "/OV1", 23: "gs", 24: "/DeviceRGB", 25: "cs", 26: "1", 27: "1", 28: "1", 29: "scn",
            30: "/Gs1", 31: "gs", 32: "f", 33: "Q", 34: "Q",
        ]
        guard fixed.allSatisfy({ tokens[$0.key] == $0.value }),
            let height1 = Double(tokens[13]),
            let width1 = Double(tokens[15]),
            let height2 = Double(tokens[16]),
            let width2 = Double(tokens[18])
        else {
            return false
        }

        let epsilon = 0.01
        return abs(bounds.minX) < epsilon
            && abs(bounds.minY) < epsilon
            && abs(Double(bounds.width) - width1) < epsilon
            && abs(Double(bounds.width) - width2) < epsilon
            && abs(Double(bounds.height) - height1) < epsilon
            && abs(Double(bounds.height) - height2) < epsilon
    }

    private static func streamDataStart(in data: Data, after streamKeywordEnd: Int) -> Int {
        guard streamKeywordEnd < data.endIndex else { return streamKeywordEnd }
        if data[streamKeywordEnd] == UInt8(ascii: "\r") {
            let next = streamKeywordEnd + 1
            if next < data.endIndex, data[next] == UInt8(ascii: "\n") { return next + 1 }
            return next
        }
        if data[streamKeywordEnd] == UInt8(ascii: "\n") { return streamKeywordEnd + 1 }
        return streamKeywordEnd
    }

    private static func skipWhitespace(in data: Data, from start: Int) -> Int {
        var index = start
        while index < data.endIndex, isPDFWhitespace(data[index]) { index += 1 }
        return index
    }

    private static func isTokenBoundary(in data: Data, before index: Int) -> Bool {
        index == data.startIndex || isPDFWhitespace(data[index - 1])
    }

    private static func isTokenBoundary(in data: Data, after index: Int) -> Bool {
        index == data.endIndex || isPDFWhitespace(data[index])
    }

    private static func isPDFWhitespace(_ byte: UInt8) -> Bool {
        byte == 0 || byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32
    }
}

/// Immutable Core Graphics PDF storage used by both the main thread and
/// `CATiledLayer`'s background rendering threads. Core Graphics can ask a tiled
/// layer to draw several tiles concurrently, so access to a document is
/// serialized here rather than leaking a queue-bound PDFKit object into those
/// callbacks.
final class PDFRenderDocument: @unchecked Sendable {

    private let document: CGPDFDocument
    private let lock = NSLock()

    var pageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return document.numberOfPages
    }

    init?(data: Data) {
        let compatibleData = PDFCompatibilitySanitizer.removingRedundantOpaqueSoftMasks(from: data)
        guard
            !compatibleData.isEmpty,
            let provider = CGDataProvider(data: compatibleData as CFData),
            let document = CGPDFDocument(provider),
            document.numberOfPages > 0,
            document.isUnlocked
        else { return nil }
        self.document = document
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
        guard index >= 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard index < document.numberOfPages else { return nil }
        guard let page = document.page(at: index + 1) else { return nil }
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

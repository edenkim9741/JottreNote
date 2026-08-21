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

import Foundation
@preconcurrency import PencilKit

struct Jot: Codable, Sendable {

    static let currentVersion = 3
    static let defaultWidth = CGFloat(1200)

    private static let emptyDrawingData = PKDrawing().dataRepresentation()

    static func makeEmpty() -> Jot {
        Jot(
            drawing: emptyDrawingData,
            width: defaultWidth
        )
    }

    var version: Int
    let drawing: Data
    let width: CGFloat
    // NOTE: Kept for backwards compatibility.
    var lastModified: Double?
    var pdfData: Data?
    var extraPages: Int
    var pdfInsertedPageSlots: [Int]
    // Per-stroke page index mapping. Each entry corresponds to the stroke at the
    // same index inside the `PKDrawing.strokes` array. Used to record which
    // logical page an ink stroke was created on so we can remove or query
    // all strokes for a specific page efficiently.
    var strokePageIndices: [Int]

    init(
        version: Int = Self.currentVersion,
        drawing: Data,
        width: CGFloat = Self.defaultWidth,
        lastModified: Double? = .zero,
        pdfData: Data? = nil,
        extraPages: Int = 0,
        pdfInsertedPageSlots: [Int] = [],
        strokePageIndices: [Int] = []
    ) {
        self.version = version
        self.drawing = drawing
        self.width = width
        self.lastModified = lastModified
        self.pdfData = pdfData
        self.extraPages = extraPages
        self.pdfInsertedPageSlots = pdfInsertedPageSlots
        self.strokePageIndices = strokePageIndices
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case drawing
        case width
        case lastModified
        case pdfData
        case extraPages
        case pdfInsertedPageSlots
        case strokePageIndices
    }

    /// Older Jottre files predate the PDF/page metadata fields. Synthesized
    /// `Decodable` ignores property defaults and would reject those files with
    /// `keyNotFound`, so optional fields are decoded explicitly here.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)

        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        drawing = try values.decode(Data.self, forKey: .drawing)
        width = try values.decodeIfPresent(CGFloat.self, forKey: .width) ?? Self.defaultWidth
        lastModified = try values.decodeIfPresent(Double.self, forKey: .lastModified)
        pdfData = try values.decodeIfPresent(Data.self, forKey: .pdfData)
        extraPages = try values.decodeIfPresent(Int.self, forKey: .extraPages) ?? 0
        pdfInsertedPageSlots = try values.decodeIfPresent(
            [Int].self,
            forKey: .pdfInsertedPageSlots
        ) ?? []
        strokePageIndices = try values.decodeIfPresent(
            [Int].self,
            forKey: .strokePageIndices
        ) ?? []

        guard width.isFinite, width > 0, extraPages >= 0 else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid jot geometry or page count."
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(drawing, forKey: .drawing)
        try values.encode(width, forKey: .width)
        try values.encodeIfPresent(lastModified, forKey: .lastModified)
        try values.encodeIfPresent(pdfData, forKey: .pdfData)
        try values.encode(extraPages, forKey: .extraPages)
        try values.encode(pdfInsertedPageSlots, forKey: .pdfInsertedPageSlots)
        try values.encode(strokePageIndices, forKey: .strokePageIndices)
    }
}

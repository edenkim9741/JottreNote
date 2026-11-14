import XCTest
import UIKit
@preconcurrency import PencilKit
@testable import Jottre

final class ZoteroLocalJotBaselineTests: XCTestCase {
    func testSavedOuterJotMatchesCacheBaselineAfterRemovingNestedPDFPayload() throws {
        let sourcePDF = try JotHybridPDFBuilder.makeRuledPDF(
            pageSize: CGSize(width: 240, height: 320),
            pageCount: 1
        )
        let jot = Jot(
            drawing: PKDrawing().dataRepresentation(),
            width: 480,
            pdfData: sourcePDF,
            zoteroItemKey: "AB23CD45",
            zoteroFileName: "notes.pdf"
        )
        let cachedHybridPDF = try ZoteroLocalJotBaseline.canonicalHybrid(for: jot)
        var savedOuterJot = jot
        savedOuterJot.pdfData = cachedHybridPDF

        XCTAssertTrue(ZoteroLocalJotBaseline.matches(
            savedOuterJot,
            cachedMD5: ZoteroSyncService.md5Hex(cachedHybridPDF)
        ))
    }

    func testChangedOuterJotDoesNotMatchPreviousCacheBaseline() throws {
        let sourcePDF = try JotHybridPDFBuilder.makeRuledPDF(
            pageSize: CGSize(width: 240, height: 320),
            pageCount: 1
        )
        let original = Jot(
            drawing: PKDrawing().dataRepresentation(),
            width: 480,
            pdfData: sourcePDF,
            zoteroItemKey: "AB23CD45",
            zoteroFileName: "notes.pdf"
        )
        let cachedHybridPDF = try ZoteroLocalJotBaseline.canonicalHybrid(for: original)
        let savedOuterJot = Jot(
            drawing: original.drawing,
            width: 500,
            pdfData: cachedHybridPDF,
            zoteroItemKey: original.zoteroItemKey,
            zoteroFileName: original.zoteroFileName
        )

        XCTAssertFalse(ZoteroLocalJotBaseline.matches(
            savedOuterJot,
            cachedMD5: ZoteroSyncService.md5Hex(cachedHybridPDF)
        ))
    }
}

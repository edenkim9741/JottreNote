import Foundation

enum ZoteroLocalJotBaseline {
    static func matches(_ jot: Jot, cachedMD5: String?) -> Bool {
        guard let cachedMD5, let hybrid = try? canonicalHybrid(for: jot) else { return false }
        if let embeddedJotData = HybridPDFManager.embeddedJotData(in: jot.pdfData ?? Data()) {
            guard let embeddedJot = try? PropertyListDecoder().decode(Jot.self, from: embeddedJotData),
                  sameEditorState(jot, embeddedJot) else { return false }
            return ZoteroSyncService.md5Hex(jot.pdfData ?? Data()).caseInsensitiveCompare(cachedMD5) == .orderedSame
        }
        return ZoteroSyncService.md5Hex(hybrid).caseInsensitiveCompare(cachedMD5) == .orderedSame
    }

    static func canonicalHybrid(for jot: Jot) throws -> Data {
        guard let sourcePDF = jot.pdfData else { throw HybridPDFManager.Failure.invalidPDF }
        var embeddedJot = jot
        // The active .jot stores the complete Hybrid PDF in pdfData. The
        // embedded Jot written into that PDF intentionally omits pdfData.
        // Rebuild the same payload before comparing it with the cache baseline.
        embeddedJot.pdfData = nil
        let encodedJot = try JotHybridPDFBuilder.encodedJotData(embeddedJot)
        return try HybridPDFManager.embedJotPreservingSourcePDF(pdfData: sourcePDF, jotData: encodedJot)
    }

    private static func sameEditorState(_ lhs: Jot, _ rhs: Jot) -> Bool {
        lhs.version == rhs.version
            && lhs.drawing == rhs.drawing
            && lhs.width == rhs.width
            && rhs.pdfData == nil
            && lhs.extraPages == rhs.extraPages
            && lhs.pdfInsertedPageSlots == rhs.pdfInsertedPageSlots
            && lhs.strokePageIndices == rhs.strokePageIndices
            && lhs.trashedPages == rhs.trashedPages
            && lhs.zoteroItemKey == rhs.zoteroItemKey
            && lhs.zoteroFileName == rhs.zoteroFileName
    }
}

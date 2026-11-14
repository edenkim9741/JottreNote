import XCTest
@testable import Jottre
import UIKit
@preconcurrency import PencilKit

final class ZoteroRecoveryBackupTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoteroRecoveryBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testBackupCopiesLocalPDFJotAndAttachmentMetadataWithoutChangingSources() throws {
        let pdfURL = temporaryDirectory.appendingPathComponent("cached.pdf")
        let jotURL = temporaryDirectory.appendingPathComponent("working.jot")
        let pdfData = Data("local-pdf-cache".utf8)
        let jotData = Data("local-jot-state".utf8)
        try pdfData.write(to: pdfURL)
        try jotData.write(to: jotURL)
        let attachment = makeAttachment(cachePath: pdfURL.path)

        let backup = try ZoteroRecoveryBackup.create(
            attachment: attachment,
            localCacheURL: pdfURL,
            localJotURL: jotURL,
            rootDirectory: temporaryDirectory.appendingPathComponent("backups", isDirectory: true)
        )

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backup.localPDFURL)), pdfData)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backup.localJotURL)), jotData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.attachmentMetadataURL.path))
        XCTAssertEqual(try Data(contentsOf: pdfURL), pdfData)
        XCTAssertEqual(try Data(contentsOf: jotURL), jotData)
        XCTAssertNotEqual(backup.directoryURL.lastPathComponent, attachment.key)
    }

    func testBackupRecordsMissingLocalFilesWithoutInventingCopies() throws {
        let jotURL = temporaryDirectory.appendingPathComponent("missing.jot")
        let backup = try ZoteroRecoveryBackup.create(
            attachment: makeAttachment(cachePath: nil),
            localCacheURL: nil,
            localJotURL: jotURL,
            rootDirectory: temporaryDirectory.appendingPathComponent("backups", isDirectory: true)
        )

        XCTAssertNil(backup.localPDFURL)
        XCTAssertNil(backup.localJotURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.attachmentMetadataURL.path))
    }

    func testBackupFailureDoesNotChangeLocalFiles() throws {
        let directoryURL = temporaryDirectory.appendingPathComponent("not-a-file", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let jotURL = temporaryDirectory.appendingPathComponent("working.jot")
        let jotData = Data("local-jot-state".utf8)
        try jotData.write(to: jotURL)

        XCTAssertThrowsError(try ZoteroRecoveryBackup.create(
            attachment: makeAttachment(cachePath: directoryURL.path),
            localCacheURL: directoryURL,
            localJotURL: jotURL,
            rootDirectory: temporaryDirectory.appendingPathComponent("backups", isDirectory: true)
        ))
        XCTAssertEqual(try Data(contentsOf: jotURL), jotData)
    }

    func testRestoreActionIsLimitedToFailedOrMissingRemotePDFAttachments() {
        var normalCloudPDF = makeAttachment(cachePath: nil)
        normalCloudPDF.syncStatus = .cloudOnly
        XCTAssertFalse(ZoteroRemoteRestoreEligibility.shouldOffer(
            for: normalCloudPDF,
            hasLocalFile: false,
            lastOpenFailed: false
        ))
        XCTAssertTrue(ZoteroRemoteRestoreEligibility.shouldOffer(
            for: normalCloudPDF,
            hasLocalFile: false,
            lastOpenFailed: false,
            pendingRemoteDownload: true
        ))

        var failedPDF = normalCloudPDF
        failedPDF.syncError = "previous failure"
        XCTAssertTrue(ZoteroRemoteRestoreEligibility.shouldOffer(
            for: failedPDF,
            hasLocalFile: false,
            lastOpenFailed: false
        ))

        var missingDownloadedPDF = normalCloudPDF
        missingDownloadedPDF.syncStatus = .downloaded
        XCTAssertTrue(ZoteroRemoteRestoreEligibility.shouldOffer(
            for: missingDownloadedPDF,
            hasLocalFile: false,
            lastOpenFailed: false
        ))

        var localOnlyCopy = failedPDF
        localOnlyCopy.isLocalOnly = true
        XCTAssertFalse(ZoteroRemoteRestoreEligibility.shouldOffer(
            for: localOnlyCopy,
            hasLocalFile: false,
            lastOpenFailed: true
        ))

        var conflictCopy = failedPDF
        conflictCopy.isConflict = true
        XCTAssertFalse(ZoteroRemoteRestoreEligibility.shouldOffer(
            for: conflictCopy,
            hasLocalFile: false,
            lastOpenFailed: true
        ))
    }

    func testConfirmedRemoteInstallCanReplaceDirtyAttachmentAndLeavesOldCacheForCaller() throws {
        let root = temporaryDirectory.appendingPathComponent("cache", isDirectory: true)
        let store = ZoteroCacheStore(
            rootDirectory: root,
            pdfCacheDirectory: temporaryDirectory.appendingPathComponent("cache-files", isDirectory: true)
        )
        let userID = "recovery-test-\(UUID().uuidString)"
        let key = "AB23CD45"
        let oldPDFURL = temporaryDirectory.appendingPathComponent("old.pdf")
        let oldPDF = try JotHybridPDFBuilder.makeRuledPDF(pageSize: CGSize(width: 200, height: 300), pageCount: 1)
        let remotePDF = try JotHybridPDFBuilder.makeRuledPDF(pageSize: CGSize(width: 300, height: 200), pageCount: 1)
        try oldPDF.write(to: oldPDFURL)
        var snapshot = ZoteroCacheSnapshot.empty(userID: userID)
        snapshot.attachments[key] = ZoteroAttachment(
            key: key,
            parentItemKey: nil,
            contentType: "application/pdf",
            filename: "recovery.pdf",
            localCachePath: oldPDFURL.path,
            syncStatus: .dirty,
            version: 1,
            md5: ZoteroSyncService.md5Hex(oldPDF),
            modificationTimeMilliseconds: 1,
            syncError: "previous download error"
        )
        try store.save(snapshot)

        let installed = try store.installUserApprovedRemoteRecovery(
            key: key,
            data: remotePDF,
            remoteVersion: 2,
            remoteMD5: ZoteroSyncService.md5Hex(remotePDF),
            userID: userID
        )

        let attachment = try XCTUnwrap(installed.snapshot.attachments[key])
        XCTAssertEqual(attachment.syncStatus, .downloaded)
        XCTAssertEqual(attachment.version, 2)
        XCTAssertNil(attachment.syncError)
        XCTAssertNotEqual(attachment.localCachePath, oldPDFURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(attachment.localCachePath)))
        XCTAssertEqual(installed.previousCacheURL, oldPDFURL)
        XCTAssertEqual(try Data(contentsOf: oldPDFURL), oldPDF,
            "The old cache stays available until the caller finishes the backup-aware install")
    }

    func testConfirmedRemoteInstallRejectsInvalidRemoteBaselineWithoutChangingDirtyCache() throws {
        let root = temporaryDirectory.appendingPathComponent("cache", isDirectory: true)
        let store = ZoteroCacheStore(
            rootDirectory: root,
            pdfCacheDirectory: temporaryDirectory.appendingPathComponent("cache-files", isDirectory: true)
        )
        let userID = "recovery-test-\(UUID().uuidString)"
        let key = "CD34EF56"
        let oldPDFURL = temporaryDirectory.appendingPathComponent("old.pdf")
        let oldPDF = try JotHybridPDFBuilder.makeRuledPDF(pageSize: CGSize(width: 200, height: 300), pageCount: 1)
        let remotePDF = try JotHybridPDFBuilder.makeRuledPDF(pageSize: CGSize(width: 300, height: 200), pageCount: 1)
        try oldPDF.write(to: oldPDFURL)
        var snapshot = ZoteroCacheSnapshot.empty(userID: userID)
        snapshot.attachments[key] = ZoteroAttachment(
            key: key,
            parentItemKey: nil,
            contentType: "application/pdf",
            filename: "recovery.pdf",
            localCachePath: oldPDFURL.path,
            syncStatus: .dirty,
            version: 1,
            md5: ZoteroSyncService.md5Hex(oldPDF),
            modificationTimeMilliseconds: 1,
            syncError: "preserve this error until install succeeds"
        )
        try store.save(snapshot)

        XCTAssertThrowsError(try store.installUserApprovedRemoteRecovery(
            key: key,
            data: remotePDF,
            remoteVersion: 2,
            remoteMD5: String(repeating: "0", count: 32),
            userID: userID
        ))

        let afterFailure = try XCTUnwrap(store.load(userID: userID).attachments[key])
        XCTAssertEqual(afterFailure.syncStatus, .dirty)
        XCTAssertEqual(afterFailure.localCachePath, oldPDFURL.path)
        XCTAssertEqual(afterFailure.syncError, "preserve this error until install succeeds")
        XCTAssertEqual(try Data(contentsOf: oldPDFURL), oldPDF)
    }

    private func makeAttachment(cachePath: String?) -> ZoteroAttachment {
        ZoteroAttachment(
            key: "AB23CD45",
            parentItemKey: "EF56GH78",
            contentType: "application/pdf",
            filename: "notes.pdf",
            localCachePath: cachePath,
            syncStatus: .dirty,
            version: 7,
            md5: "local-checksum",
            modificationTimeMilliseconds: 1_700_000_000_000
        )
    }
}

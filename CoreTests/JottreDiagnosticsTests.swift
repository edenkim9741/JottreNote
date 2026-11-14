import CoreFoundation
import Foundation
import XCTest

@testable import Jottre

final class JottreDiagnosticsTests: XCTestCase {
    private func serialized(_ event: [String: Any]) throws -> (object: [String: Any], paths: [String]) {
        var paths: [String] = []
        let safe = JottreDiagnostics.sanitizedJSONObject(event, nonFiniteNumberPaths: &paths)
        let data = try JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (decoded, paths)
    }

    func testNormalDiagnosticsNumbersKeepTheirValues() throws {
        let result = try serialized(["event": "persistence.success", "count": 4, "ratio": 0.625])

        XCTAssertEqual(result.object["count"] as? Int, 4)
        XCTAssertEqual(result.object["ratio"] as? Double, 0.625)
        XCTAssertTrue(result.paths.isEmpty)
    }

    func testPositiveInfinityBecomesNull() throws {
        let result = try serialized(["measurement": Double.infinity])

        XCTAssertTrue(result.object["measurement"] is NSNull)
        XCTAssertEqual(result.paths, ["measurement"])
    }

    func testNegativeInfinityBecomesNull() throws {
        let result = try serialized(["measurement": -Double.infinity])

        XCTAssertTrue(result.object["measurement"] is NSNull)
        XCTAssertEqual(result.paths, ["measurement"])
    }

    func testNaNBecomesNull() throws {
        let result = try serialized(["measurement": Double.nan])

        XCTAssertTrue(result.object["measurement"] is NSNull)
        XCTAssertEqual(result.paths, ["measurement"])
    }

    func testCGFloatInfinityBecomesNull() throws {
        let result = try serialized(["measurement": CGFloat.infinity])

        XCTAssertTrue(result.object["measurement"] is NSNull)
        XCTAssertEqual(result.paths, ["measurement"])
    }

    func testNestedDictionaryInfinityBecomesNullAndReportsKeyPath() throws {
        let result = try serialized(["geometry": ["scale": ["y": Double.infinity]]])
        let geometry = try XCTUnwrap(result.object["geometry"] as? [String: Any])
        let scale = try XCTUnwrap(geometry["scale"] as? [String: Any])

        XCTAssertTrue(scale["y"] is NSNull)
        XCTAssertEqual(result.paths, ["geometry.scale.y"])
    }

    func testArrayNaNBecomesNullAndReportsArrayIndex() throws {
        let result = try serialized(["bounds": [1.0, Double.nan, 3.0]])
        let bounds = try XCTUnwrap(result.object["bounds"] as? [Any])

        XCTAssertEqual(bounds[0] as? Double, 1)
        XCTAssertTrue(bounds[1] is NSNull)
        XCTAssertEqual(bounds[2] as? Double, 3)
        XCTAssertEqual(result.paths, ["bounds[1]"])
    }

    func testBooleanNSNumberAndIntegerKeepTheirTypes() throws {
        let result = try serialized([
            "swiftBoolean": true,
            "objcBoolean": NSNumber(value: true),
            "zero": NSNumber(value: 0),
            "one": NSNumber(value: 1)
        ])

        for key in ["swiftBoolean", "objcBoolean"] {
            let value = try XCTUnwrap(result.object[key] as? NSNumber)
            XCTAssertEqual(CFGetTypeID(value), CFBooleanGetTypeID(), "\(key) should remain a JSON boolean")
        }
        for key in ["zero", "one"] {
            let value = try XCTUnwrap(result.object[key] as? NSNumber)
            XCTAssertNotEqual(CFGetTypeID(value), CFBooleanGetTypeID(), "\(key) should remain a JSON number")
        }
        XCTAssertTrue(result.paths.isEmpty)
    }

    func testEmptySessionSerializes() throws {
        let result = try serialized([:])

        XCTAssertTrue(result.object.isEmpty)
        XCTAssertTrue(result.paths.isEmpty)
    }

    func testUnlinkedZoteroLocalPencilEventSerializes() throws {
        let result = try serialized([
            "event": "canvas.strokeCommitted",
            "zoteroConnected": false,
            "pageIndex": 0,
            "strokeCount": 1,
            "screenErrorPixels": 0.5
        ])

        XCTAssertEqual(result.object["event"] as? String, "canvas.strokeCommitted")
        XCTAssertEqual(result.object["zoteroConnected"] as? Bool, false)
        XCTAssertEqual(result.object["strokeCount"] as? Int, 1)
    }

    func testPDFSaveDiagnosticsSerializeNormally() throws {
        let result = try serialized([
            "event": "pdf.save.completed",
            "durationMilliseconds": 12.5,
            "byteCount": 8_192
        ])

        XCTAssertEqual(result.object["durationMilliseconds"] as? Double, 12.5)
        XCTAssertEqual(result.object["byteCount"] as? Int, 8_192)
        XCTAssertTrue(result.paths.isEmpty)
    }

    func testHighMagnificationMemorySampleWithNonFiniteGeometrySerializes() throws {
        let result = try serialized([
            "event": "canvas.memorySample",
            "relativeZoom": 12.0,
            "footprintBytes": 233_600_000,
            "expectedDrawingToOverlayScale": [1.0, CGFloat.infinity]
        ])
        let scales = try XCTUnwrap(result.object["expectedDrawingToOverlayScale"] as? [Any])

        XCTAssertEqual(result.object["relativeZoom"] as? Double, 12)
        XCTAssertTrue(scales[1] is NSNull)
        XCTAssertEqual(result.paths, ["expectedDrawingToOverlayScale[1]"])
    }
}

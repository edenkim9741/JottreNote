@preconcurrency import PencilKit
import XCTest

@testable import Jottre

@MainActor
final class JotToolSelectionHistoryTests: XCTestCase {
    func testDuplicateCallbacksDoNotOverwritePreviousAndRepeatedTapsSwapTools() {
        let history = JotToolSelectionHistory()
        let a = JotToolSelectionHistory.Selection(tool: PKInkingTool(.pen, color: .red, width: 2), itemIdentifier: "a")
        let b = JotToolSelectionHistory.Selection(tool: PKInkingTool(.pen, color: .blue, width: 5), itemIdentifier: "b")
        history.observe(a)
        history.observe(b)
        XCTAssertFalse(history.observe(b))
        XCTAssertEqual(history.previous, a)
        history.observe(history.previous!)
        XCTAssertEqual(history.current, a)
        XCTAssertEqual(history.previous, b)
        history.observe(history.previous!)
        XCTAssertEqual(history.current, b)
        XCTAssertEqual(history.previous, a)
    }

    func testInstalledItemIdentityDistinguishesTwoPensOfTheSameType() throws {
        let red = PKToolPickerInkingItem(type: .pen, color: .red, width: 2, identifier: "red")
        let blue = PKToolPickerInkingItem(type: .pen, color: .blue, width: 5, identifier: "blue")
        let picker = PKToolPicker(toolItems: [red, blue, PKToolPickerEraserItem(type: .bitmap)])
        picker.stateAutosaveName = nil
        let desired = JotToolSelectionHistory.Selection(tool: blue.inkingTool, itemIdentifier: blue.identifier)
        let selected = try XCTUnwrap(JotToolSelectionHistory.select(desired, in: picker))
        XCTAssertEqual(selected.selection, desired)
        XCTAssertEqual(picker.selectedToolItemIdentifier, "blue")
    }

    func testPenEraserPenRestoresFullSettingsAndHistory() throws {
        let pen = PKToolPickerInkingItem(type: .pen, color: .red, width: 3, identifier: "pen")
        let eraser = PKToolPickerEraserItem(type: .bitmap, width: 8)
        let picker = PKToolPicker(toolItems: [pen, eraser])
        picker.stateAutosaveName = nil
        let history = JotToolSelectionHistory()
        let original = JotToolSelectionHistory.Selection(tool: pen.inkingTool, itemIdentifier: pen.identifier)
        history.observe(try XCTUnwrap(JotToolSelectionHistory.select(original, in: picker)).selection)
        history.observe(
            try XCTUnwrap(
                JotToolSelectionHistory.select(
                    .init(tool: eraser.eraserTool, itemIdentifier: eraser.identifier),
                    in: picker
                )
            ).selection
        )
        XCTAssertEqual(history.lastNonEraser, original)
        history.observe(try XCTUnwrap(JotToolSelectionHistory.select(history.previous!, in: picker)).selection)
        XCTAssertEqual(history.current, original)
    }

    func testSettingsCanBeRestoredWhenAnItemHasTheSameIdentifierButDifferentColorAndWidth() throws {
        let item = PKToolPickerInkingItem(type: .pen, color: .blue, width: 5, identifier: "pen")
        let picker = PKToolPicker(toolItems: [item])
        picker.stateAutosaveName = nil
        let previous = PKInkingTool(.pen, color: .red, width: 2)
        let selection = try XCTUnwrap(
            JotToolSelectionHistory.select(.init(tool: previous, itemIdentifier: "pen"), in: picker)
        )
        XCTAssertTrue(JotToolSelectionHistory.toolsMatch(selection.selection.tool, previous))
        XCTAssertFalse(selection.picker === picker)
    }
}

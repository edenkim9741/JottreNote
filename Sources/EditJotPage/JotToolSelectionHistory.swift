@preconcurrency import PencilKit

/// Tool values and picker identity travel together. Repeated/asynchronous
/// observer callbacks must not turn the previous tool into the current tool.
@MainActor
final class JotToolSelectionHistory {
    struct Selection: Equatable {
        let tool: any PKTool
        let itemIdentifier: String?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.itemIdentifier == rhs.itemIdentifier && toolsMatch(lhs.tool, rhs.tool)
        }
    }

    private(set) var current: Selection?
    private(set) var previous: Selection?
    private(set) var lastNonEraser: Selection?

    @discardableResult
    func observe(_ selection: Selection) -> Bool {
        guard current != selection else { return false }
        previous = current
        current = selection
        if !(selection.tool is PKEraserTool) { lastNonEraser = selection }
        return true
    }

    nonisolated static func toolsMatch(_ lhs: any PKTool, _ rhs: any PKTool) -> Bool {
        if let lhs = lhs as? PKInkingTool, let rhs = rhs as? PKInkingTool { return lhs == rhs }
        if let lhs = lhs as? PKEraserTool, let rhs = rhs as? PKEraserTool { return lhs == rhs }
        return lhs is PKLassoTool && rhs is PKLassoTool
    }

    static func selection(in picker: PKToolPicker) -> Selection? {
        let item = picker.selectedToolItem
        guard let tool = tool(in: item) else { return nil }
        return Selection(tool: tool, itemIdentifier: item.identifier)
    }

    static func tool(in item: PKToolPickerItem) -> (any PKTool)? {
        if let item = item as? PKToolPickerInkingItem { return item.inkingTool }
        if let item = item as? PKToolPickerEraserItem { return item.eraserTool }
        if let item = item as? PKToolPickerLassoItem { return item.lassoTool }
        return nil
    }

    @discardableResult
    static func select(_ desired: Selection, in picker: PKToolPicker) -> (picker: PKToolPicker, selection: Selection)? {
        let items = picker.toolItems
        let identified = items.first { $0.identifier == desired.itemIdentifier }
        let exact = items.first { item in
            tool(in: item).map { toolsMatch($0, desired.tool) } ?? false
        }
        let sameKind = items.first { item in
            if let desired = desired.tool as? PKInkingTool, let item = item as? PKToolPickerInkingItem {
                return item.inkingTool.inkType == desired.inkType
            }
            if let desired = desired.tool as? PKEraserTool, let item = item as? PKToolPickerEraserItem {
                return item.eraserTool.eraserType == desired.eraserType
            }
            return desired.tool is PKLassoTool && item is PKToolPickerLassoItem
        }
        let matchingIdentity = identified.flatMap { item in
            tool(in: item).flatMap { toolsMatch($0, desired.tool) ? item : nil }
        }
        guard let item = matchingIdentity ?? exact ?? identified ?? sameKind else { return nil }
        var targetPicker = picker
        var targetItem = item
        if tool(in: item).map({ toolsMatch($0, desired.tool) }) != true {
            // Item settings are read-only. Rebuild just this item using public
            // APIs and retain every other item. The deprecated selectedTool
            // setter can crash for custom item identifiers on current iPadOS.
            if let ink = desired.tool as? PKInkingTool {
                if #available(iOS 26.0, *) {
                    targetItem = PKToolPickerInkingItem(
                        type: ink.inkType,
                        color: ink.color,
                        width: ink.width,
                        azimuth: ink.azimuth,
                        identifier: item.identifier
                    )
                } else {
                    targetItem = PKToolPickerInkingItem(
                        type: ink.inkType,
                        color: ink.color,
                        width: ink.width,
                        identifier: item.identifier
                    )
                }
                if let old = item as? PKToolPickerInkingItem, let new = targetItem as? PKToolPickerInkingItem {
                    new.allowsColorSelection = old.allowsColorSelection
                }
            } else if let eraser = desired.tool as? PKEraserTool {
                targetItem = PKToolPickerEraserItem(type: eraser.eraserType, width: eraser.width)
            } else {
                return nil
            }
            targetPicker = PKToolPicker(toolItems: items.map { $0 === item ? targetItem : $0 })
            targetPicker.stateAutosaveName = nil
            targetPicker.isRulerActive = picker.isRulerActive
            targetPicker.colorUserInterfaceStyle = picker.colorUserInterfaceStyle
            targetPicker.overrideUserInterfaceStyle = picker.overrideUserInterfaceStyle
            targetPicker.showsDrawingPolicyControls = picker.showsDrawingPolicyControls
            targetPicker.maximumSupportedContentVersion = picker.maximumSupportedContentVersion
            targetPicker.accessoryItem = picker.accessoryItem
        }
        targetPicker.selectedToolItemIdentifier = targetItem.identifier
        guard let actual = selection(in: targetPicker), toolsMatch(actual.tool, desired.tool) else {
            #if DEBUG
            print("[PencilTool] Picker failed to restore \(item.identifier) with the requested settings")
            #endif
            return nil
        }
        return (targetPicker, actual)
    }
}

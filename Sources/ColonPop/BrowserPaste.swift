import AppKit
import ApplicationServices

@MainActor
protocol BrowserPasteboard {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType]? { get }
    var pasteboardItems: [NSPasteboardItem]? { get }
    @discardableResult func clearContents() -> Int
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool
    @discardableResult func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: BrowserPasteboard {}

/// Chrome's web renderer handles the normal Paste command, including editor input events and undo.
@MainActor
final class BrowserPaste {
    static let shared = BrowserPaste()
    private let board: any BrowserPasteboard
    private var original: [NSPasteboardItem]?
    private var generation = 0
    private var timeout: DispatchWorkItem?

    init(board: any BrowserPasteboard = NSPasteboard.general) { self.board = board }

    func replace(_ literal: String, with glyph: String, in field: FocusField) -> SelectionWrite {
        func stillSelected() -> Bool {
            guard let current = FocusField.current(), field.sameEditor(as: current) else { return false }
            return current.hasSelected(literal)
        }
        guard stillSelected() else { return .unavailable }
        return withTemporaryText(glyph) {
            // A previously empty clipboard can leave Paste disabled until the emoji is staged.
            guard let menuItem = Self.pasteCommand(in: field.pid), stillSelected() else { return .failure }
            return AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
        }
    }

    func withTemporaryText(_ text: String, perform: () -> AXError) -> SelectionWrite {
        if original != nil, board.changeCount != generation { finish() }
        guard original == nil else { return .busy }
        let before = board.changeCount
        guard let items = snapshot(), board.changeCount == before else { return .unavailable }
        original = items
        generation = board.clearContents()
        guard board.setString(text, forType: .string) else { finish(); return .unavailable }
        generation = board.changeCount
        let result = perform()
        // A timeout can mean the browser already accepted the command. Give it time to read.
        if result == .success || result == .cannotComplete {
            let token = generation
            let finishIfCurrent: () -> Void = { [weak self] in
                if self?.generation == token { self?.finish() }
            }
            let restore = DispatchWorkItem(block: finishIfCurrent)
            timeout = restore
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: restore)
            return .issued(onVerified: finishIfCurrent)
        }
        finish()
        return .unavailable
    }

    func finish() {
        timeout?.cancel()
        timeout = nil
        guard let items = original else { return }
        original = nil
        guard board.changeCount == generation else { return } // A newer Copy belongs to the user.
        board.clearContents()
        if !items.isEmpty { board.writeObjects(items) }
    }

    private func snapshot() -> [NSPasteboardItem]? {
        let items = board.pasteboardItems ?? []
        if items.isEmpty { return (board.types ?? []).isEmpty ? [] : nil }
        var saved: [NSPasteboardItem] = []
        var bytes = 0
        // Inspect type names across all items before requesting any confidential or promised data.
        guard !items.flatMap(\.types).contains(where: {
            let name = $0.rawValue.lowercased()
            return name.contains("concealed") || name.contains("transient") || name.contains("promis")
        }) else { return nil }
        for item in items {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                bytes += data.count
                guard bytes <= 8 * 1024 * 1024, copy.setData(data, forType: type) else { return nil }
            }
            saved.append(copy)
        }
        return saved
    }

    private static func pasteCommand(in pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
            return value
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        guard let raw = attribute(app, kAXMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        for title in children(raw as! AXUIElement) {
            for menu in children(title) {
                for item in children(menu) {
                    guard let key = attribute(item, kAXMenuItemCmdCharAttribute) as? String, key.lowercased() == "v",
                          let modifiers = attribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber,
                          modifiers.intValue == 0 else { continue }
                    return item
                }
            }
        }
        return nil
    }
}

import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum SuffixEvidence {
    case text(String), unsupported, failed
}

enum ReplacementCheck {
    static func permits(_ literal: String, start: Int?, caret: NSRange?,
                        suffix: SuffixEvidence, simpleTextControl: Bool) -> Bool {
        if let caret {
            guard caret.length == 0, caret.location >= literal.utf16.count else { return false }
        } else if start != nil {
            return false
        }
        switch suffix {
        case .text(let text): return text == literal
        case .unsupported:
            guard simpleTextControl, let start, let caret else { return false }
            return caret.location - literal.utf16.count == start
        case .failed: return false
        }
    }
}

/// One snapshot of a focused input. Text reads are scoped to the shortcode.
@MainActor
protocol FocusedEditor {
    var pid: pid_t { get }
    var selection: NSRange? { get }
    var simpleTextControl: Bool { get }
    func sameEditor(as other: any FocusedEditor) -> Bool
    func text(in range: NSRange) -> SuffixEvidence
    func setSelection(_ range: NSRange) -> AXError
    func replaceSelectedText(with text: String) -> AXError
    func selectedText() -> String?
    func caretBounds() -> CGRect?
}

/// Holds an editor identity and a caret offset, never the editor's document.
struct FocusField: FocusedEditor {
    let pid: pid_t
    let element: AXUIElement
    let window: AXUIElement?
    let selection: NSRange?
    let simpleTextControl: Bool

    static func frontmostEditorPID() -> pid_t? {
        guard !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.bundleIdentifier != "com.tinyspeck.slackmacgap" else { return nil }
        return app.processIdentifier
    }

    static func current(prepareEditor: Bool = false) -> FocusField? {
        guard let pid = frontmostEditorPID() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.06)
        func readFocus() -> FocusField? {
            guard let focused = elementAttribute(appElement, kAXFocusedUIElementAttribute) else { return nil }
            return inspect(focused, pid: pid, allowAncestor: true)
        }
        if let field = readFocus() { return field }
        // Some Electron editors expose their text controls only after this opt-in.
        let manual = "AXManualAccessibility" as CFString
        var settable: DarwinBoolean = false
        guard prepareEditor, AXUIElementIsAttributeSettable(appElement, manual, &settable) == .success,
              settable.boolValue,
              AXUIElementSetAttributeValue(appElement, manual, kCFBooleanTrue) == .success else { return nil }
        return readFocus()
    }

    private static func inspect(_ element: AXUIElement, pid: pid_t, allowAncestor: Bool) -> FocusField? {
        AXUIElementSetMessagingTimeout(element, 0.06)
        let names = [kAXRoleAttribute, kAXSubroleAttribute, "AXProtectedContent",
                     kAXSelectedTextRangeAttribute, kAXWindowAttribute, "AXEditable"]
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw) == .success,
              let values = raw as? [AnyObject], values.count == names.count,
              let role = values[0] as? String else { return nil }
        guard role != kAXSecureTextFieldSubrole, values[1] as? String != kAXSecureTextFieldSubrole,
              values[2] as? Bool != true else { return nil }
        let simple = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
        guard !attributeReadFailed(values[3]) else { return nil }
        let selection = rangeValue(values[3])
        let editable = values[5] as? Bool
        if editable == false { return nil }
        var writableText: DarwinBoolean = false
        let customEditor = !simple && editable != true && selection != nil && role != kAXStaticTextRole &&
            AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writableText) == .success &&
            writableText.boolValue
        if simple || editable == true || customEditor {
            return FocusField(pid: pid, element: element, window: asElement(values[4]),
                              selection: selection, simpleTextControl: simple || editable == true)
        }
        if allowAncestor, let ancestor = elementAttribute(element, kAXEditableAncestorAttribute),
           !CFEqual(ancestor, element) {
            return inspect(ancestor, pid: pid, allowAncestor: false)
        }
        return nil
    }

    func sameEditor(as other: any FocusedEditor) -> Bool {
        guard let other = other as? FocusField, pid == other.pid, CFEqual(element, other.element) else { return false }
        switch (window, other.window) {
        case (let a?, let b?): return CFEqual(a, b)
        case (nil, nil): return true
        default: return false
        }
    }

    func setSelection(_ range: NSRange) -> AXError {
        guard let value = Self.axRange(range) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    }

    func selectedText() -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    func replaceSelectedText(with text: String) -> AXError {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
    }

    func caretBounds() -> CGRect? {
        guard let selection else { return nil }
        if let rect = bounds(in: NSRange(location: selection.location, length: 0)) { return rect }
        guard selection.location > 0,
              let previous = bounds(in: NSRange(location: selection.location - 1, length: 1)) else { return nil }
        return CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
    }

    private func bounds(in range: NSRange) -> CGRect? {
        guard let parameter = Self.axRange(range) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                          parameter, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(value) == .cgRect, AXValueGetValue(value, .cgRect, &rect),
              rect.height > 0, rect.height < 200, rect.minX.isFinite, rect.minY.isFinite else { return nil }
        return rect
    }

    func text(in range: NSRange) -> SuffixEvidence {
        guard let parameter = Self.axRange(range) else { return .failed }
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                                 parameter, &value)
        if status == .success, let text = value as? String { return .text(text) }
        let unsupported: [AXError] = [.parameterizedAttributeUnsupported, .attributeUnsupported, .notImplemented]
        guard unsupported.contains(status) || status == .noValue || status == .success else { return .failed }
        var attributed: CFTypeRef?
        let second = AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                                                                 parameter, &attributed)
        if second == .success, let result = attributed as? NSAttributedString { return .text(result.string) }
        return unsupported.contains(status) && unsupported.contains(second) ? .unsupported : .failed
    }

    private static func axRange(_ range: NSRange) -> AXValue? {
        var value = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &value)
    }

    private static func rangeValue(_ raw: AnyObject) -> NSRange? {
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func attributeReadFailed(_ raw: AnyObject) -> Bool {
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .axError else { return false }
        var error: AXError = .success
        guard AXValueGetValue(value, .axError, &error) else { return true }
        return error != .attributeUnsupported && error != .noValue && error != .notImplemented
    }

    private static func asElement(_ raw: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func elementAttribute(_ object: AXUIElement, _ name: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(object, name as CFString, &raw) == .success, let raw else { return nil }
        return asElement(raw)
    }
}

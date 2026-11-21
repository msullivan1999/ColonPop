import AppKit

extension FocusedEditor {
    func permitsStart(at location: Int?, keyboardBoundary: Bool) -> Bool {
        guard let location else { return keyboardBoundary }
        guard location > 0 else { return true }
        let units = min(location, 2)
        switch text(in: NSRange(location: location - units, length: units)) {
        case .text(let prefix): return Composer.canStart(after: prefix.last)
        case .unsupported, .failed: return keyboardBoundary
        }
    }
}

/// A confirmation retains the original editor and literal until the host has
/// processed the last physical keystroke. Only a read can be retried after a write.
@MainActor
final class Insertion {
    enum Step { case wait, selectBackwards(Int), replace(backspaces: Int), done, stop }

    let editor: any FocusedEditor
    let literal: String
    let glyph: String
    let accessibilityOnly: Bool
    let openingOffset: Int?
    private(set) var requestedSelection = false
    private var nativeWriteStart: Int?

    init(editor: any FocusedEditor, literal: String, glyph: String, openingOffset: Int?, accessibilityOnly: Bool) {
        self.editor = editor
        self.literal = literal
        self.glyph = glyph
        self.accessibilityOnly = accessibilityOnly
        self.openingOffset = openingOffset
    }

    func next(in current: any FocusedEditor, allowSelection: Bool) -> Step {
        guard editor.sameEditor(as: current) else { return .stop }
        let count = literal.utf16.count
        let caret = current.selection

        if let start = nativeWriteStart {
            // A setter may report success before the editor applies it. Never write twice.
            if case .text(let text) = current.text(in: NSRange(location: start, length: glyph.utf16.count)), text == glyph {
                return .done
            }
            if current.selectedText() == glyph { return .done }
            return .wait
        }
        if requestedSelection {
            if let caret, caret.length > 0, caret.length != count { return .stop }
            if current.selectedText() == literal { return replaceSelection(in: current) }
            if let caret, caret.length == count,
               case .text(let selected) = current.text(in: caret), selected == literal {
                return replaceSelection(in: current)
            }
            return .wait
        }
        if let caret, caret.length != 0 { return .stop }
        let evidence: SuffixEvidence
        if let caret, caret.location >= count {
            evidence = current.text(in: NSRange(location: caret.location - count, length: count))
        } else {
            evidence = .unsupported
        }
        if accessibilityOnly {
            guard allowSelection, let caret else { return .wait }
            let start: Int
            if case .text(let suffix) = evidence, suffix == literal {
                start = caret.location - count
            } else if let opening = openingOffset, caret.location == opening {
                start = opening
            } else {
                return .wait
            }
            let range = NSRange(location: start, length: count)
            guard case .text(let text) = current.text(in: range), text == literal else { return .wait }
            switch current.setSelection(range) {
            case .success, .cannotComplete: requestedSelection = true
            default: break
            }
            return .wait
        }
        if ReplacementCheck.permits(literal, start: openingOffset, caret: caret,
                                    suffix: evidence, simpleTextControl: editor.simpleTextControl && current.simpleTextControl) {
            return .replace(backspaces: count)
        }
        guard allowSelection else { return .wait }
        guard let start = openingOffset, let caret else {
            return verifyWithKeyboard(in: current)
        }
        let stalled = caret.location == start
        let advanced = caret.location >= count && caret.location - count == start
        // A positive mismatch at the live caret may be a different word.
        // Never delete it, even if it happens to have the same length.
        guard stalled || advanced else { return .wait }
        if !stalled, case .text = evidence { return .wait }

        let range = NSRange(location: start, length: count)
        if case .text(let value) = current.text(in: range), value == literal {
            switch current.setSelection(range) {
            case .success, .cannotComplete:
                requestedSelection = true
                return .wait
            default: break
            }
        }
        // Rich text fields can expose selected text while always reporting a
        // zero caret. Let the editor select the token, then read it before typing.
        return verifyWithKeyboard(in: current)
    }

    private func replaceSelection(in current: any FocusedEditor) -> Step {
        guard accessibilityOnly else { return .replace(backspaces: 0) }
        guard let range = current.selection, range.length == literal.utf16.count else { return .wait }
        nativeWriteStart = range.location
        _ = current.replaceSelectedText(with: glyph)
        return .wait
    }

    private func verifyWithKeyboard(in current: any FocusedEditor) -> Step {
        guard current.simpleTextControl, current.selectedText() == "" else { return .wait }
        requestedSelection = true
        return .selectBackwards(literal.utf16.count)
    }

    func cancelSelection(in current: any FocusedEditor, collapseWithArrow: () -> Void) {
        guard requestedSelection, editor.sameEditor(as: current) else { return }
        if let range = current.selection, range.length > 0, range.length <= literal.utf16.count {
            if current.setSelection(NSRange(location: NSMaxRange(range), length: 0)) == .success { return }
        }
        if let selected = current.selectedText(), !selected.isEmpty, selected.utf16.count <= literal.utf16.count {
            collapseWithArrow()
        }
    }
}

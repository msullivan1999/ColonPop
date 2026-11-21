import AppKit

extension FocusedEditor {
    func hasSelected(_ literal: String) -> Bool {
        if let selection, selection.length > 0, selection.length != literal.utf16.count { return false }
        if selectedText() == literal { return true }
        if let range = selection, range.length == literal.utf16.count,
           case .text(let text) = text(in: range) { return text == literal }
        return false
    }

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
    enum Step { case wait, selectBackwards(Int), replace(backspaces: Int), done, failed, stop }

    let editor: any FocusedEditor
    let literal: String
    let glyph: String
    let accessibilityOnly: Bool
    let openingOffset: Int?
    let browserEditor: Bool
    private(set) var requestedSelection = false
    private var requestedStart: Int?
    private var nativeWriteStart: Int?
    private var verifiedWrite: (() -> Void)?

    init(editor: any FocusedEditor, literal: String, glyph: String, openingOffset: Int?, accessibilityOnly: Bool) {
        self.editor = editor
        self.literal = literal
        self.glyph = glyph
        self.accessibilityOnly = accessibilityOnly
        self.openingOffset = openingOffset
        self.browserEditor = editor.browserEditor
    }

    func next(in current: any FocusedEditor, allowSelection: Bool) -> Step {
        guard editor.sameEditor(as: current) else { return .stop }
        let count = literal.utf16.count
        let caret = current.selection

        if let start = nativeWriteStart {
            // A setter may report success before the editor applies it. Never write twice.
            if current.selectedText() == glyph ||
                matchesInsertedText(in: current, at: start) {
                verifiedWrite?()
                verifiedWrite = nil
                return .done
            }
            return .wait
        }
        if requestedSelection {
            if let caret, caret.length > 0, caret.length != count { return .stop }
            if current.hasSelected(literal), !browserEditor || allowSelection {
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
        if accessibilityOnly || browserEditor {
            guard allowSelection, let caret else { return .wait }
            let start: Int
            if case .text(let suffix) = evidence, suffix == literal {
                start = caret.location - count
            } else if let opening = openingOffset, caret.location == opening || caret.location - count == opening {
                start = opening
            } else {
                return .wait
            }
            let range = NSRange(location: start, length: count)
            if case .text(let text) = current.text(in: range), text != literal { return .wait }
            // Selecting is reversible. Some web fields only reveal text after it is selected.
            switch current.setSelection(range) {
            case .success, .cannotComplete:
                requestedSelection = true
                requestedStart = start
            case .attributeUnsupported, .notImplemented:
                // Some Chrome controls expose a readable caret and suffix but no writable selection.
                // Keep keyboard insertion available only when the live suffix matches exactly.
                if browserEditor, !accessibilityOnly, case .text(let suffix) = evidence, suffix == literal {
                    nativeWriteStart = start
                    return .replace(backspaces: count)
                }
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

    private func matchesInsertedText(in current: any FocusedEditor, at start: Int) -> Bool {
        if case .text(let text) = current.text(in: NSRange(location: start, length: glyph.utf16.count)) {
            return text == glyph
        }
        // In a selection-only web control a change in length also distinguishes a paste
        // from merely collapsing the original selection. Never use this to authorize a write.
        return browserEditor && literal.utf16.count != glyph.utf16.count &&
            current.selection == NSRange(location: start + glyph.utf16.count, length: 0) && current.selectedText() == ""
    }

    private func replaceSelection(in current: any FocusedEditor) -> Step {
        guard accessibilityOnly || browserEditor else { return .replace(backspaces: 0) }
        let reported = current.selection.flatMap { $0.length == literal.utf16.count ? $0.location : nil }
        guard let start = reported ?? requestedStart else { return .wait }
        if browserEditor {
            switch current.replaceBrowserSelection(literal, with: glyph) {
            case .busy: return .wait
            case .unavailable:
                guard !accessibilityOnly else { return .failed }
                nativeWriteStart = start
                return .replace(backspaces: 0)
            case .issued(let onVerified):
                verifiedWrite = onVerified
                nativeWriteStart = start
                return .wait
            }
        }
        nativeWriteStart = start
        _ = current.replaceSelectedText(with: glyph)
        return .wait
    }

    private func verifyWithKeyboard(in current: any FocusedEditor) -> Step {
        guard current.simpleTextControl, current.selectedText() == "" else { return .wait }
        requestedSelection = true
        return .selectBackwards(literal.utf16.count)
    }

    func cancelSelection(in current: any FocusedEditor, collapseWithArrow: () -> Void) {
        guard requestedSelection, nativeWriteStart == nil, editor.sameEditor(as: current) else { return }
        if let range = current.selection, range.length > 0, range.length <= literal.utf16.count {
            if current.setSelection(NSRange(location: NSMaxRange(range), length: 0)) == .success { return }
        }
        if let selected = current.selectedText(), !selected.isEmpty, selected.utf16.count <= literal.utf16.count {
            collapseWithArrow()
        }
    }
}

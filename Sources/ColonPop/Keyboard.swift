import AppKit
import Carbon.HIToolbox

enum Keyboard {
    static let marker: Int64 = 0x436F6C6F6E506F70

    static func decode(_ event: CGEvent) -> InputKey {
        let flags = event.flags
        if !flags.intersection([.maskCommand, .maskControl]).isEmpty { return .other }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let special: InputKey?
        switch code {
        case kVK_Delete: special = .backspace
        case kVK_UpArrow: special = .up
        case kVK_DownArrow: special = .down
        case kVK_Return, kVK_ANSI_KeypadEnter: special = .enter
        case kVK_Tab: special = .tab
        case kVK_Escape: special = .escape
        default: special = nil
        }
        if let special {
            return flags.intersection([.maskAlternate, .maskShift]).isEmpty ? special : .other
        }
        var units = [UniChar](repeating: 0, count: 8)
        var count = 0
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
        if count > 0 { return .text(String(decoding: units.prefix(count), as: UTF16.self)) }
        if let text = NSEvent(cgEvent: event)?.characters, !text.isEmpty { return .text(text) }
        return .other
    }

    static func events(text: String, backspaces: Int) -> [CGEvent]? {
        let source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        guard var result = pairs(code: CGKeyCode(kVK_Delete), text: "\u{7f}", count: backspaces, source: source),
              let input = pairs(code: 0, text: text, count: 1, source: source) else { return nil }
        result.append(contentsOf: input)
        return result
    }

    static func arrowEvents(selectBackwards count: Int) -> [CGEvent]? {
        let source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        if count == 0 {
            return pairs(code: CGKeyCode(kVK_RightArrow), text: "\u{f703}", count: 1, flags: .maskNumericPad, source: source)
        }
        return pairs(code: CGKeyCode(kVK_LeftArrow), text: "\u{f702}", count: count,
                     flags: [.maskShift, .maskNumericPad], source: source)
    }

    private static func pairs(code: CGKeyCode, text: String, count: Int, flags: CGEventFlags = [],
                              source: CGEventSource?) -> [CGEvent]? {
        var result: [CGEvent] = []
        let units = Array(text.utf16)
        for _ in 0..<count {
            for down in [true, false] {
                let key = source.flatMap { CGEvent(keyboardEventSource: $0, virtualKey: code, keyDown: down) }
                guard let event = key ?? CGEvent(source: source) else { return nil }
                event.type = down ? .keyDown : .keyUp
                event.flags = flags
                event.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
                event.setIntegerValueField(.eventSourceUserData, value: marker)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                result.append(event)
            }
        }
        return result
    }
}

@MainActor
final class KeyboardMonitor {
    private var composer: Composer
    private let picker: any PickerSurface
    private let readEditor: @MainActor (Bool) -> (any FocusedEditor)?
    private let frontmostPID: @MainActor () -> pid_t?
    private let post: ([CGEvent], pid_t) -> Void
    private let canPost: () -> Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var target: (any FocusedEditor)?
    private var openingOffset: Int?
    private var opening: (pid: pid_t, boundary: Bool, length: Int)?
    private var retryOpening: Task<Void, Never>?
    private var pending: Insertion?
    private var scheduled: DispatchWorkItem?
    private var consumeMouseUp = false
    private var caretAnchor: CGRect?
    private var boundary = true
    private var consumedCodes: Set<Int64> = []
    private var redrawPending = false
    private var focusTimer: Timer?
    private var missedFocusPoll = false
    init(catalog: Catalog, picker: any PickerSurface,
         readEditor: @escaping @MainActor (Bool) -> (any FocusedEditor)? = { FocusField.current(prepareEditor: $0) },
         frontmostPID: @escaping @MainActor () -> pid_t? = { FocusField.frontmostEditorPID() },
         canPost: @escaping () -> Bool = { CGPreflightPostEventAccess() },
         post: @escaping ([CGEvent], pid_t) -> Void = { events, pid in events.forEach { $0.postToPid(pid) } }) {
        composer = Composer(catalog: catalog)
        self.picker = picker
        self.readEditor = readEditor
        self.frontmostPID = frontmostPID
        self.post = post
        self.canPost = canPost
        picker.onPick = { [weak self] candidate in self?.confirm(candidate) }
    }

    @discardableResult
    func start() -> Bool {
        if let tap {
            if CFMachPortIsValid(tap) {
                if CGEvent.tapIsEnabled(tap: tap) { return true }
                CGEvent.tapEnable(tap: tap, enable: true)
                if CGEvent.tapIsEnabled(tap: tap) { return true }
            }
            stop()
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { proxy, type, event, context in
            guard let context else { return .passUnretained(event) }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
            let pass = MainActor.assumeIsolated { monitor.receive(type, event, proxy: proxy) }
            return pass ? .passUnretained(event) : nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        self.tap = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        if CGEvent.tapIsEnabled(tap: port) { return true }
        stop()
        return false
    }

    func stop() {
        if let tap, CFMachPortIsValid(tap) { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        resetContext()
    }

    func resetContext() {
        cancelOpening()
        cancelPending()
        dismiss()
        boundary = true
        consumedCodes.removeAll()
        consumeMouseUp = false
    }

    func receive(_ type: CGEventType, _ event: CGEvent, proxy: CGEventTapProxy? = nil) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetContext()
            if let tap, AXIsProcessTrusted() { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Keyboard.marker else { return true }
        if type == .leftMouseUp {
            defer { consumeMouseUp = false }
            return !consumeMouseUp
        }
        if type != .keyDown && type != .keyUp {
            cancelOpening()
            cancelPending()
            if type == .leftMouseDown { consumeMouseUp = false }
            if target != nil, type == .leftMouseDown, let hit = picker.candidate(atQuartzPoint: event.location) {
                confirm(hit)
                consumeMouseUp = true
                return false
            }
            if target != nil, type == .leftMouseDown, picker.contains(quartzPoint: event.location) { return true }
            if target != nil { dismiss() }
            boundary = true
            return true
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return consumedCodes.remove(code) == nil }
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if repeating, consumedCodes.contains(code), target == nil { return false }
        if !repeating { consumedCodes.remove(code) }
        if IsSecureEventInputEnabled() {
            cancelOpening()
            cancelPending()
            if target != nil { dismiss() }
            boundary = true
            return true
        }
        let key = Keyboard.decode(event)
        if let request = opening {
            if case .text(let text) = key, Composer.isQueryCharacter(text), request.length < 96 {
                opening?.length += 1
            } else {
                cancelOpening()
            }
        }
        if let pending {
            // The next printable key may arrive before the scheduled main-loop
            // turn. Post a verified edit ahead of it in the same event stream.
            if case .text = key { _ = advance(pending, allowSelection: false, proxy: proxy) }
            cancelPending()
        }
        if let target {
            let current = readEditor(false)
            if current == nil, target.browserEditor, frontmostPID() == target.pid, target.stillOwnsFocus(),
               key == .enter || key == .tab, let index = composer.highlightedIndex {
                // A web renderer can briefly omit focus. Consume the visible choice now
                // so Return cannot submit a form. The edit still has to prove the same field.
                confirm(composer.matches[index])
                consumedCodes.insert(code)
                return false
            }
            guard let current, target.sameEditor(as: current) else {
                resetContext()
                return true
            }
            switch composer.handle(key) {
            case .pass:
                if composer.query == nil { dismiss() } else { redraw() }
                rememberBoundary(after: key)
                return true
            case .consume:
                if composer.query == nil { dismiss() } else { redraw() }
                consumedCodes.insert(code)
                return false
            case .insert(let candidate):
                let closingColon = key == .text(":")
                confirm(candidate, closingColon: closingColon)
                // An exact shortcode remains intact if a delayed editor cannot be verified.
                if closingColon { return true }
                consumedCodes.insert(code)
                return false
            }
        }
        if key == .text(":"), !repeating {
            if let field = readEditor(true) {
                let offset = field.selection?.location
                if field.permitsStart(at: offset, keyboardBoundary: boundary) { begin(in: field, at: offset) }
            } else if let pid = frontmostPID() {
                recoverOpening(in: pid)
            }
        }
        rememberBoundary(after: key)
        return true
    }

    private func begin(in field: any FocusedEditor, at offset: Int?, query: String = "") {
        target = field
        openingOffset = offset
        caretAnchor = field.caretBounds()
        composer.begin(query)
        redraw()
        watchFocus()
    }

    // A newly activated editor may expose its AX tree after delivering the colon.
    // Keep only a count until an editable, non-secure field proves the literal at its caret.
    private func recoverOpening(in pid: pid_t) {
        cancelOpening()
        opening = (pid, boundary, 0)
        retryOpening = Task { [weak self] in
            for delay in [20, 45, 80] {
                do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) } catch { return }
                guard let self, let request = self.opening else { return }
                guard !IsSecureEventInputEnabled(), self.frontmostPID() == request.pid else { break }
                guard let field = self.readEditor(false), field.pid == request.pid,
                      let caret = field.selection, caret.length == 0, caret.location > request.length else { continue }
                let start = caret.location - request.length - 1
                guard case .text(let literal) = field.text(in: NSRange(location: start, length: request.length + 1)),
                      literal.first == ":", literal.utf8.count == request.length + 1,
                      literal.dropFirst().allSatisfy({ Composer.isQueryCharacter(String($0)) }),
                      field.permitsStart(at: start, keyboardBoundary: request.boundary) else { continue }
                self.begin(in: field, at: start, query: String(literal.dropFirst()))
                break
            }
            self?.opening = nil
            self?.retryOpening = nil
        }
    }

    private func cancelOpening() {
        retryOpening?.cancel()
        retryOpening = nil
        opening = nil
    }

    private func rememberBoundary(after key: InputKey) {
        switch key {
        case .text(let text): boundary = Composer.canStart(after: text.last)
        case .enter, .tab, .other, .backspace, .up, .down: boundary = true
        case .escape: break
        }
    }

    private func confirm(_ candidate: Candidate, closingColon: Bool = false) {
        guard let target, let literal = composer.literal else { return }
        let edit = Insertion(editor: target, literal: literal + (closingColon ? ":" : ""), glyph: candidate.glyph,
                             openingOffset: openingOffset, accessibilityOnly: !canPost())
        pending = edit
        dismiss()
        schedule(edit, attempt: 0)
    }

    private func schedule(_ edit: Insertion, attempt: Int) {
        let delays = edit.browserEditor ? [0, 12, 24, 40, 60, 80, 120, 180, 260, 300] : [0, 12, 24, 40, 60, 80]
        guard attempt < delays.count else {
            let stillInEditor = !IsSecureEventInputEnabled() && readEditor(false).map { edit.editor.sameEditor(as: $0) } == true
            cancelPending()
            if stillInEditor { picker.showInsertionFailure(needsKeyboardAccess: edit.accessibilityOnly) }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pending === edit else { return }
            let canProbe = (1..<(delays.count - 1)).contains(attempt)
            if !self.advance(edit, allowSelection: canProbe) {
                self.schedule(edit, attempt: attempt + 1)
            }
        }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delays[attempt]), execute: work)
    }

    /// Returns true once the edit is complete or cancelled. A tap proxy is
    /// valid only while processing the physical event that supplied it.
    private func advance(_ edit: Insertion, allowSelection: Bool, proxy: CGEventTapProxy? = nil) -> Bool {
        guard !IsSecureEventInputEnabled() else { cancelPending(); return true }
        guard let current = readEditor(false) else { return false }
        switch edit.next(in: current, allowSelection: allowSelection) {
        case .replace(let backspaces):
            guard let events = Keyboard.events(text: edit.glyph, backspaces: backspaces) else { cancelPending(); return true }
            if !edit.browserEditor {
                pending = nil
                scheduled?.cancel()
                scheduled = nil
            }
            boundary = true
            if let proxy { events.forEach { $0.tapPostEvent(proxy) } }
            else { post(events, current.pid) }
            return !edit.browserEditor
        case .selectBackwards(let count):
            guard let keys = Keyboard.arrowEvents(selectBackwards: count) else { cancelPending(); return true }
            post(keys, current.pid)
            return false
        case .done:
            pending = nil
            scheduled = nil
            boundary = true
            return true
        case .failed:
            cancelPending()
            picker.showInsertionFailure(needsKeyboardAccess: edit.accessibilityOnly)
            return true
        case .stop: cancelPending(); return true
        case .wait: return false
        }
    }

    private func cancelPending() {
        scheduled?.cancel()
        scheduled = nil
        let edit = pending
        pending = nil
        if let edit, edit.requestedSelection, !IsSecureEventInputEnabled(), let current = readEditor(false) {
            edit.cancelSelection(in: current) {
                if !edit.accessibilityOnly, let arrow = Keyboard.arrowEvents(selectBackwards: 0) { post(arrow, current.pid) }
            }
        }
    }

    private func redraw() {
        guard !redrawPending else { return }
        redrawPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.redrawPending = false
            guard self.target != nil, self.composer.query != nil else { return }
            self.picker.show(self.composer.matches, selected: self.composer.highlightedIndex, quartzCaret: self.caretAnchor)
        }
    }

    private func watchFocus() {
        missedFocusPoll = false
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let target = self.target else { return }
                if let current = self.readEditor(false) {
                    self.missedFocusPoll = false
                    if !target.sameEditor(as: current) { self.resetContext() }
                } else if !self.missedFocusPoll, target.browserEditor, target.stillOwnsFocus() {
                    self.missedFocusPoll = true
                } else {
                    self.resetContext()
                }
            }
        }
        timer.tolerance = 0.08
        RunLoop.main.add(timer, forMode: .common)
        focusTimer = timer
    }

    private func dismiss() {
        focusTimer?.invalidate()
        focusTimer = nil
        target = nil
        openingOffset = nil
        caretAnchor = nil
        composer.cancel()
        picker.hide()
    }
}

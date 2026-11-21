import AppKit
import Carbon.HIToolbox

/// Runs in a separate process. Only the ordinary menu-bar process owns the event tap.
@MainActor
final class PickerCheck: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    private struct Failure: Error {
        let message: String
        let blocked: Bool
        init(_ message: String, blocked: Bool = false) {
            self.message = message
            self.blocked = blocked
        }
    }

    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 214),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let editor = NSTextView(frame: NSRect(x: 22, y: 22, width: 476, height: 78))
    private let status = NSTextField(wrappingLabelWithString: "Opening the picker check…")
    private var listenerPID: pid_t = 0
    private var passed = 0
    private var manual = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "ColonPop Picker Check"
        window.isReleasedWhenClosed = false
        window.center()
        status.frame = NSRect(x: 22, y: 112, width: 476, height: 76)
        status.font = .systemFont(ofSize: 14)
        editor.isRichText = false
        editor.delegate = self
        editor.textContainerInset = NSSize(width: 8, height: 6)
        editor.wantsLayer = true
        editor.layer?.cornerRadius = 6
        editor.layer?.borderWidth = 1
        editor.layer?.borderColor = NSColor.separatorColor.cgColor
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.setAccessibilityLabel("Picker check text")
        window.contentView?.addSubview(status)
        window.contentView?.addSubview(editor)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        Task { await run() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func run() async {
        do {
            guard AXIsProcessTrusted() else {
                throw Failure("Open ColonPop Setup to allow Accessibility for this copy.", blocked: true)
            }
            let app = try await listener()
            listenerPID = app.processIdentifier
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(editor)
            try await wait("The check window did not receive keyboard focus.") { self.ownsFocus }
            if !CGPreflightPostEventAccess() {
                if CommandLine.arguments.contains("--exit-after-check") {
                    throw Failure("The automated check needs keyboard insertion permission.", blocked: true)
                }
                manual = true
                status.stringValue = "Type :wave below and press Return. You can also click the waving hand in the picker."
                return
            }
            let catalog = try Catalog.bundled()

            start("Opening suggestions on the first colon", prefix: "Before ", suffix: " after")
            try await typeText(":")
            try await wait("The editor received a colon, but the picker did not open.") { self.panelFrame() != nil }
            try await wait("The opening colon did not reach the editor.") { self.editor.string == "Before : after" }
            pass()
            status.stringValue = "Checking Return in the middle of a sentence…"
            try await typeText("wave")
            try await key(kVK_Return, "\r")
            try await expect("Before 👋 after", "Return did not replace the shortcode.")
            pass()

            start("Clicking the second suggestion")
            try await typeText(":w")
            let matches = catalog.search("w")
            try await wait("The picker did not display two suggestions.") {
                self.editor.string == ":w" && (self.panelFrame()?.height ?? 0) >= 2 * PopupPlacement.rowHeight + 34
            }
            guard matches.count > 1, let frame = panelFrame() else { throw Failure("The second suggestion was unavailable.") }
            let row = PopupPlacement.rowFrame(1, in: frame.size)
            let point = CGPoint(x: frame.minX + row.midX, y: frame.maxY - row.midY)
            try clickRow(at: point)
            try await expect(matches[1].glyph, "Clicking the second suggestion did not insert its emoji.")
            pass()

            start("Keeping the shortcode on Escape")
            try await typeText(":wave")
            try await wait("The picker did not reopen for Escape.") { self.panelFrame() != nil }
            try await key(kVK_Escape, "\u{1b}")
            try await expect(":wave", "Escape changed the typed text or left the picker open.")
            pass()

            start("Inserting a complete shortcode")
            try await typeText(":tada:")
            try await expect("🎉", "The closing colon did not insert the exact match.")
            pass()

            start("Leaving the colon in a time alone")
            try await typeText("12:")
            try await wait("The time did not reach the editor.") { self.editor.string == "12:" }
            for _ in 0..<8 {
                guard panelFrame() == nil else { throw Failure("Suggestions opened inside a time.") }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            try await typeText("30")
            try await expect("12:30", "The time changed.")
            pass()
            finish("All \(passed) checks passed in the test editor.", code: 0)
        } catch let failure as Failure {
            finish("\(passed) checks passed. \(failure.message)", code: failure.blocked ? 77 : 1)
        } catch {
            finish("The check stopped. \(error.localizedDescription)", code: 1)
        }
    }

    private func listener() async throws -> NSRunningApplication {
        let url = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard url.pathExtension == "app", let id = Bundle.main.bundleIdentifier else {
            throw Failure("Run the check from the packaged ColonPop.app.", blocked: true)
        }
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != getpid() }
        if let app = copies.first {
            guard copies.count == 1, app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == url else {
                throw Failure("Quit the other running copies of ColonPop, then run the check again.", blocked: true)
            }
            return app
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        return try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    func textDidChange(_ notification: Notification) {
        if manual, editor.string.contains("👋") {
            status.stringValue = "The waving hand was inserted. You can try another shortcode in this field."
        }
    }

    private var ownsFocus: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() && window.isKeyWindow && window.firstResponder === editor
    }

    private func start(_ title: String, prefix: String = "", suffix: String = "") {
        status.stringValue = title + "…"
        editor.string = prefix + suffix
        editor.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
    }

    private func pass() {
        passed += 1
        print("PASS \(status.stringValue)")
    }

    private func finish(_ message: String, code: Int32) {
        status.stringValue = message
        print(message)
        if CommandLine.arguments.contains("--exit-after-check") { exit(code) }
    }

    private func wait(_ message: String, until condition: () -> Bool) async throws {
        for _ in 0..<120 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw Failure(message)
    }

    private func expect(_ text: String, _ message: String) async throws {
        try await wait(message) { self.ownsFocus && self.editor.string == text && self.panelFrame() == nil }
    }

    // WindowServer supplies the actual on-screen bounds, independent of the monitor's model.
    private func panelFrame() -> CGRect? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        for window in windows ?? [] where window[kCGWindowOwnerPID as String] as? pid_t == listenerPID &&
            window[kCGWindowLayer as String] as? Int == NSWindow.Level.popUpMenu.rawValue {
            if let bounds = window[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: bounds), rect.height > 34 { return rect }
        }
        return nil
    }

    private func typeText(_ text: String) async throws {
        let codes: [Character: Int] = [":": kVK_ANSI_Semicolon, "w": kVK_ANSI_W, "a": kVK_ANSI_A, "v": kVK_ANSI_V,
                                       "e": kVK_ANSI_E, "t": kVK_ANSI_T, "d": kVK_ANSI_D, "1": kVK_ANSI_1,
                                       "2": kVK_ANSI_2, "3": kVK_ANSI_3, "0": kVK_ANSI_0]
        for ch in text {
            guard let code = codes[ch] else { throw Failure("Unknown test character.") }
            try await key(code, String(ch), flags: ch == ":" ? .maskShift : [])
        }
    }

    private func key(_ code: Int, _ text: String, flags: CGEventFlags = []) async throws {
        guard ownsFocus, !IsSecureEventInputEnabled() else { throw Failure("The check lost keyboard focus or Secure Input is active.", blocked: true) }
        let units = Array(text.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else {
                throw Failure("macOS could not create a test keystroke.")
            }
            event.flags = flags
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.post(tap: .cghidEventTap)
        }
        try await Task.sleep(nanoseconds: 45_000_000)
    }

    private func clickRow(at point: CGPoint) throws {
        guard ownsFocus, !IsSecureEventInputEnabled(), panelFrame()?.contains(point) == true else {
            throw Failure("The test editor or picker lost focus before the click.", blocked: true)
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
                throw Failure("macOS could not create a test click.")
            }
            event.post(tap: .cghidEventTap)
        }
    }
}

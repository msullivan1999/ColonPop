import AppKit
import Carbon.HIToolbox

/// Drives the production event handler in memory. Selection, Paste, the picker
/// and the DOM edit are real cross-process operations. The host never receives
/// synthesized keys and the test never installs a system-wide keyboard listener.
@main @MainActor
final class ChromeCheck: NSObject, NSApplicationDelegate {
    private struct Failure: Error { let reason: String }
    private var window: NSWindow!
    private let result = NSTextField(wrappingLabelWithString: "Checking the three local Chrome fields…")
    private let runID = "colonpop-" + UUID().uuidString.lowercased()
    private var chromePID: pid_t = 0

    static func main() {
        guard CGSessionCopyCurrentDictionary() != nil, !NSScreen.screens.isEmpty else {
            print("No logged-in macOS desktop. Chrome checks did not run.")
            exit(77)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = ChromeCheck()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 130),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ColonPop Browser Check"
        window.isReleasedWhenClosed = false
        result.frame = NSRect(x: 18, y: 14, width: 474, height: 92)
        window.contentView?.addSubview(result)
        window.center()
        window.orderFrontRegardless()
        Task { await run() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func run() async {
        guard AXIsProcessTrusted() else {
            finish("Accessibility is required for ColonPop Browser Check. Reopen the check after granting access.", code: 77)
            return
        }
        guard let fixture = Bundle.main.url(forResource: "chrome", withExtension: "html"),
              var url = URLComponents(url: fixture, resolvingAgainstBaseURL: false),
              let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            finish("The local test page or Google Chrome is missing.", code: 77)
            return
        }
        url.fragment = runID
        do {
            let browser = try await NSWorkspace.shared.open([url.url!], withApplicationAt: chrome, configuration: .init())
            chromePID = browser.processIdentifier
            let picker = Picker()
            let catalog = try Catalog.bundled()
            let fields = ["single", "multi", "rich"]
            for (index, id) in fields.enumerated() {
                try await wait("Chrome did not focus the \(id) fixture.") { self.fixtureIsFront(id) }
                let readFixture: @MainActor (Bool) -> (any FocusedEditor)? = { prepare in
                    guard self.fixtureIsFront(id), let field = FocusField.current(prepareEditor: prepare),
                          field.pid == self.chromePID else { return nil }
                    return field
                }
                try await wait("Chrome did not expose the starting caret for \(id).") {
                    readFixture(true)?.selection == NSRange(location: 7, length: 0)
                }
                let monitor = KeyboardMonitor(catalog: catalog, picker: picker, readEditor: readFixture,
                                              frontmostPID: { self.fixtureIsFront(id) ? self.chromePID : nil },
                                              canPost: { false })
                defer { monitor.resetContext() }
                for ch in ":wave" {
                    guard key(String(ch), code: ch == ":" ? kVK_ANSI_Semicolon : kVK_ANSI_A, monitor: monitor) else {
                        throw Failure(reason: "A printable key was swallowed in \(id).")
                    }
                }
                guard readFixture(false)?.setSelection(NSRange(location: 12, length: 0)) == .success else {
                    throw Failure(reason: "Chrome refused the fixture caret for \(id).")
                }
                try await wait("Chrome did not expose the typed shortcode in \(id).") {
                    readFixture(false)?.selection == NSRange(location: 12, length: 0)
                }
                guard !key("\r", code: kVK_Return, monitor: monitor) else {
                    throw Failure(reason: "Return passed through the picker in \(id).")
                }
                // The fixture advances only after Chrome fires input and the full DOM value is correct.
                let next = index + 1 < fields.count ? fields[index + 1] : "passed"
                try await wait("Chrome did not confirm the emoji and surrounding text in \(id).") { self.fixtureIsFront(next) }
                print("PASS " + id)
            }
            finish("All 3 Chrome fields passed. Return was consumed, surrounding text and rich formatting survived, and the form did not submit.", code: 0)
        } catch {
            finish((error as? Failure)?.reason ?? error.localizedDescription, code: 1)
        }
    }

    private func fixtureIsFront(_ state: String) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == chromePID else { return false }
        let app = AXUIElementCreateApplication(chromePID)
        var rawWindow: CFTypeRef?
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
              let rawWindow, CFGetTypeID(rawWindow) == AXUIElementGetTypeID(),
              AXUIElementCopyAttributeValue(rawWindow as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
              let text = title as? String else { return false }
        return text.hasPrefix(runID + " " + state)
    }

    private func key(_ text: String, code: Int, monitor: KeyboardMonitor) -> Bool {
        let event = CGEvent(source: nil)!
        event.type = .keyDown
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
        let units = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        let passed = monitor.receive(.keyDown, event)
        event.type = .keyUp
        _ = monitor.receive(.keyUp, event)
        return passed
    }

    private func wait(_ reason: String, until ready: () -> Bool) async throws {
        for _ in 0..<150 {
            if ready() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw Failure(reason: reason)
    }

    private func finish(_ message: String, code: Int32) {
        BrowserPaste.shared.finish()
        result.stringValue = message
        print(message)
        if CommandLine.arguments.contains("--exit-after-check") { exit(code) }
    }
}

import AppKit
import ApplicationServices
import ServiceManagement

enum AppState: Equatable {
    case accessibility, inputMonitoring, unavailable, nativeInsertion, ready, paused

    static func refresh(paused: Bool, trusted: Bool, canPost: Bool, canListen: @autoclosure () -> Bool,
                        start: () -> Bool, stop: () -> Void) -> Self {
        guard !paused, trusted else {
            stop()
            return paused ? .paused : .accessibility
        }
        guard start() else { return canListen() ? .unavailable : .inputMonitoring }
        return canPost ? .ready : .nativeInsertion
    }

    var heading: String {
        switch self {
        case .accessibility: return "Enable ColonPop"
        case .inputMonitoring: return "Allow keyboard input"
        case .unavailable: return "Reconnect the picker"
        case .nativeInsertion: return "Suggestions are on"
        case .ready: return "Ready to type"
        case .paused: return "ColonPop is paused"
        }
    }

    var detail: String {
        switch self {
        case .accessibility:
            return "Allow the copy of ColonPop shown below in Accessibility. If an older copy is already listed after an update, remove that entry and add this app."
        case .inputMonitoring:
            return "Your Mac also requires Input Monitoring. Turn on ColonPop there, then reopen the app if macOS asks."
        case .unavailable:
            return "macOS couldn’t connect the keyboard listener. Check ColonPop in Accessibility, then try again."
        case .nativeInsertion:
            return "The keyboard listener is running. ColonPop can insert in fields that support Accessibility editing. Allow keyboard insertion to use other fields."
        case .ready:
            return "In a text field, type :wave after a space or at the start of a line. Press Return to insert 👋. Escape keeps the text you typed."
        case .paused:
            return "Resume the picker whenever you want to use emoji shortcodes again."
        }
    }

    var buttonTitle: String {
        switch self {
        case .accessibility: return "Open Accessibility Settings…"
        case .inputMonitoring: return "Open Input Monitoring Settings…"
        case .unavailable: return "Try Again"
        case .nativeInsertion: return "Allow Keyboard Insertion…"
        case .ready: return "Done"
        case .paused: return "Resume Picker"
        }
    }
}

@MainActor
private final class WelcomeWindow {
    private let window: NSWindow
    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let action = NSButton(title: "", target: nil, action: nil)
    var onAction: (() -> Void)?
    var onTest: (() -> Void)?

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 304),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ColonPop"
        window.isReleasedWhenClosed = false
        window.center()
        let content = window.contentView!
        let sample = NSTextField(labelWithString: ":wave:   →   👋")
        sample.font = .monospacedSystemFont(ofSize: 24, weight: .medium)
        sample.frame = NSRect(x: 28, y: 241, width: 354, height: 36)
        heading.font = .systemFont(ofSize: 21, weight: .semibold)
        heading.frame = NSRect(x: 28, y: 196, width: 354, height: 30)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 28, y: 104, width: 354, height: 80)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = NSTextField(labelWithString: "Version \(version)  ·  \(Bundle.main.bundlePath)")
        build.font = .systemFont(ofSize: 11)
        build.textColor = .secondaryLabelColor
        build.lineBreakMode = .byTruncatingMiddle
        build.toolTip = Bundle.main.bundlePath
        build.isSelectable = true
        build.frame = NSRect(x: 28, y: 78, width: 354, height: 20)
        action.bezelStyle = .rounded
        action.controlSize = .large
        action.keyEquivalent = "\r"
        action.target = self
        action.action = #selector(pressed)
        let test = NSButton(title: "Test Picker…", target: self, action: #selector(testPressed))
        test.bezelStyle = .rounded
        test.sizeToFit()
        test.setFrameOrigin(NSPoint(x: 382 - test.frame.width, y: 24))
        for view in [sample, heading, detail, build, action, test] as [NSView] { content.addSubview(view) }
    }

    func update(_ state: AppState) {
        heading.stringValue = state.heading
        detail.stringValue = state.detail
        action.title = state.buttonTitle
        action.sizeToFit()
        action.setFrameOrigin(NSPoint(x: 25, y: 24))
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func close() { window.close() }
    @objc private func pressed() { onAction?() }
    @objc private func testPressed() { onTest?() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem?
    private var monitor: KeyboardMonitor?
    private let toggle = NSMenuItem(title: "", action: #selector(togglePicker), keyEquivalent: "")
    private let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private lazy var welcome = WelcomeWindow()
    private var timer: Timer?
    private var paused = false
    private var checkApp: NSRunningApplication?
    private var openingCheck = false
    private var state: AppState = .accessibility

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            monitor = try KeyboardMonitor(catalog: Catalog.bundled(), picker: Picker())
        } catch {
            let alert = NSAlert()
            alert.messageText = "ColonPop couldn’t load its emoji catalog."
            alert.informativeText = "Copy the complete ColonPop.app bundle to Applications and open it again."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        welcome.onAction = { [weak self] in self?.performSetupAction() }
        welcome.onTest = { [weak self] in self?.testPicker() }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        if let image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "ColonPop") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = ":)"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let setup = NSMenuItem(title: "ColonPop Setup…", action: #selector(showSetup), keyEquivalent: "")
        let test = NSMenuItem(title: "Test Picker…", action: #selector(testPicker), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit ColonPop", action: #selector(quitApp), keyEquivalent: "q")
        for actionItem in [setup, test, toggle, login, quit] { actionItem.target = self }
        menu.addItem(setup)
        menu.addItem(test)
        menu.addItem(toggle)
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(quit)
        item.menu = menu
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(self, selector: #selector(contextChanged(_:)), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(reconnect(_:)), name: name, object: nil)
        }
        refresh()
        if state != .ready { welcome.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        monitor?.stop()
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func refresh() {
        state = AppState.refresh(paused: paused, trusted: AXIsProcessTrusted(), canPost: CGPreflightPostEventAccess(),
                                 canListen: CGPreflightListenEventAccess(), start: { monitor?.start() == true },
                                 stop: { monitor?.stop() })
        welcome.update(state)
        toggle.title = paused ? "Resume Picker" : "Pause Picker"
        toggle.isEnabled = state == .ready || state == .nativeInsertion || state == .paused
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        item?.button?.appearsDisabled = state == .paused
        item?.button?.toolTip = "ColonPop — " + state.heading
        let interval: TimeInterval = state == .ready ? 15 : 3
        if state == .paused {
            timer?.invalidate()
            timer = nil
        } else if timer?.timeInterval != interval {
            timer?.invalidate()
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 0.4
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func performSetupAction() {
        switch state {
        case .ready: welcome.close()
        case .paused: togglePicker()
        case .unavailable: refresh()
        case .accessibility:
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
            openPrivacyPane("Privacy_Accessibility")
        case .nativeInsertion:
            _ = CGRequestPostEventAccess()
            openPrivacyPane("Privacy_Accessibility")
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
            openPrivacyPane("Privacy_ListenEvent")
        }
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func contextChanged(_ notification: Notification) { monitor?.resetContext() }
    @objc private func reconnect(_ notification: Notification) { monitor?.resetContext(); refresh() }
    @objc private func showSetup() { refresh(); welcome.show() }
    @objc private func testPicker() {
        if let checkApp, !checkApp.isTerminated {
            checkApp.activate(options: [.activateIgnoringOtherApps])
            return
        }
        guard !openingCheck else { return }
        openingCheck = true
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--test-picker"]
        config.createsNewApplicationInstance = true
        Task {
            defer { openingCheck = false }
            do { checkApp = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) }
            catch {
                let alert = NSAlert(error: error)
                alert.messageText = "Couldn’t open the picker check"
                alert.runModal()
            }
        }
    }
    @objc private func togglePicker() { paused.toggle(); refresh() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled: try SMAppService.mainApp.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t update Open at Login"
            alert.informativeText = "Open ColonPop from Applications and try again. " + error.localizedDescription
            alert.runModal()
        }
        refresh()
    }
}

@main
enum ColonPopApp {
    @MainActor static func main() {
        let checking = CommandLine.arguments.contains("--test-picker")
        if checking, CGSessionCopyCurrentDictionary() == nil || NSScreen.screens.isEmpty {
            print("Picker check requires a logged-in macOS desktop with a display. No live checks ran.")
            exit(77)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(checking ? .regular : .accessory)
        let delegate: any NSApplicationDelegate = checking ? PickerCheck() : AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

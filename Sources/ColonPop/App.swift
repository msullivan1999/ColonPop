import AppKit
import ApplicationServices
import ServiceManagement

enum SetupAction: String {
    case done = "Done"
    case accessibility = "Open Accessibility Settings…"
    case inputMonitoring = "Open Input Monitoring Settings…"
    case retry = "Try Again"
    case resume = "Resume Picker"
    case keyboardInsertion = "Allow Keyboard Insertion…"
}

enum AppState: Equatable {
    case accessibility, inputMonitoring, unavailable, nativeInsertion, ready, paused
    var pickerAvailable: Bool { self == .ready || self == .nativeInsertion }

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
            return "ColonPop uses Accessibility to insert the emoji you choose. Emoji search runs on your Mac, and ColonPop keeps no typing history."
        case .inputMonitoring:
            return "Your Mac also requires Input Monitoring. Turn on ColonPop there, then reopen the app if macOS asks."
        case .unavailable:
            return "macOS couldn’t connect the keyboard listener. Check ColonPop in Accessibility, then try again."
        case .nativeInsertion, .ready:
            return "Start after a space or at the beginning of a field. Use the arrow keys to choose an emoji, Return to insert it, or Escape to keep what you typed."
        case .paused:
            return "Resume the picker whenever you want to use emoji shortcodes again."
        }
    }

    var primaryAction: SetupAction {
        switch self {
        case .accessibility: return .accessibility
        case .inputMonitoring: return .inputMonitoring
        case .unavailable: return .retry
        case .nativeInsertion, .ready: return .done
        case .paused: return .resume
        }
    }

    var help: (title: String, text: String)? {
        switch self {
        case .accessibility:
            return ("Already enabled?", "In Privacy & Security, remove the old ColonPop entry and add the copy shown below. Reopen ColonPop if macOS asks.")
        case .nativeInsertion:
            return ("Trouble inserting?", "Some editors need keyboard input to replace a shortcode. You can allow ColonPop to send keystrokes to the field you’re typing in.")
        default: return nil
        }
    }
}

@MainActor
final class WelcomeWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 288),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let build = NSTextField(labelWithString: "")
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    private let action = NSButton(title: "", target: nil, action: nil)
    private let test = NSButton(title: "Test Picker…", target: nil, action: nil)
    private let disclosure = NSButton(title: "", target: nil, action: nil)
    private let helpBody = NSStackView()
    private let helpText = NSTextField(wrappingLabelWithString: "")
    private let keyboardInsertion = NSButton(title: SetupAction.keyboardInsertion.rawValue, target: nil, action: nil)
    private var displayed: AppState?
    var onAction: ((SetupAction) -> Void)?
    var onTest: (() -> Void)?

    init() {
        window.title = "ColonPop Setup"
        window.isReleasedWhenClosed = false
        window.center()
        let content = window.contentView!
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        detail.font = .systemFont(ofSize: 13)
        detail.preferredMaxLayoutWidth = 392
        detail.maximumNumberOfLines = 0
        let sample = NSTextField(labelWithString: ":wave:   →   👋")
        sample.font = .monospacedSystemFont(ofSize: 20, weight: .medium)
        sample.setAccessibilityLabel("Type a colon, the word wave, and a closing colon to insert a waving hand.")
        build.font = .systemFont(ofSize: 11)
        build.textColor = .secondaryLabelColor
        build.lineBreakMode = .byTruncatingMiddle
        build.cell?.usesSingleLineMode = true
        build.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        build.toolTip = Bundle.main.bundlePath
        build.isSelectable = true

        disclosure.isBordered = false
        disclosure.alignment = .left
        disclosure.imagePosition = .imageLeading
        disclosure.imageHugsTitle = true
        disclosure.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        disclosure.target = self
        disclosure.action = #selector(toggleHelp)
        disclosure.setAccessibilityRole(.disclosureTriangle)

        helpText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        helpText.preferredMaxLayoutWidth = 374
        helpText.maximumNumberOfLines = 0
        helpBody.orientation = .vertical
        helpBody.alignment = .leading
        helpBody.spacing = 6
        helpBody.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
        helpBody.addArrangedSubview(helpText)
        helpBody.addArrangedSubview(keyboardInsertion)
        keyboardInsertion.bezelStyle = .rounded
        keyboardInsertion.controlSize = .small
        keyboardInsertion.target = self
        keyboardInsertion.action = #selector(requestKeyboardInsertion)

        let info = NSStackView(views: [heading, detail, sample, disclosure, helpBody, build])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 9
        info.setCustomSpacing(16, after: detail)
        let divider = NSBox()
        divider.boxType = .separator
        for button in [test, action] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.target = self
        }
        test.action = #selector(testPressed)
        action.action = #selector(pressed)
        action.keyEquivalent = "\r"
        for view in [info, divider, test, action] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            info.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            info.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            info.widthAnchor.constraint(equalToConstant: 392),
            info.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            build.widthAnchor.constraint(lessThanOrEqualTo: info.widthAnchor),
            detail.widthAnchor.constraint(equalTo: info.widthAnchor),
            helpText.widthAnchor.constraint(equalToConstant: 374),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.topAnchor.constraint(greaterThanOrEqualTo: info.bottomAnchor, constant: 12),
            divider.bottomAnchor.constraint(equalTo: action.topAnchor, constant: -14),
            action.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            action.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            test.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            test.centerYAnchor.constraint(equalTo: action.centerYAnchor),
            test.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -12)
        ])
    }

    func update(_ state: AppState) {
        guard displayed != state else { return }
        displayed = state
        heading.stringValue = state.heading
        detail.stringValue = state.detail
        action.title = state.primaryAction.rawValue
        test.isHidden = !state.pickerAvailable
        disclosure.title = state.help?.title ?? ""
        disclosure.setAccessibilityLabel(disclosure.title)
        disclosure.isHidden = state.help == nil
        helpText.stringValue = state.help?.text ?? ""
        keyboardInsertion.isHidden = state != .nativeInsertion
        setHelpExpanded(false)
    }

    private func setHelpExpanded(_ expanded: Bool) {
        guard let displayed else { return }
        helpBody.isHidden = !expanded
        let chevron = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.forward", accessibilityDescription: nil)
        disclosure.image = chevron?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        disclosure.setAccessibilityExpanded(expanded)
        let showPath = displayed == .inputMonitoring || displayed == .unavailable || (displayed == .accessibility && expanded)
        build.stringValue = showPath ? "Version \(version)  ·  \(Bundle.main.bundlePath)" : "Version \(version)"

        let extraHeight = expanded ? ceil(helpBody.fittingSize.height) + 9 : 0
        let contentSize = NSSize(width: 440, height: 288 + extraHeight)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: window.isVisible) }
    }

    func show() {
        if !window.isVisible { setHelpExpanded(false) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }
    @objc private func pressed() {
        if let displayed { onAction?(displayed.primaryAction) }
    }
    @objc private func testPressed() { onTest?() }
    @objc private func toggleHelp() {
        if displayed?.help != nil { setHelpExpanded(helpBody.isHidden) }
    }
    @objc private func requestKeyboardInsertion() {
        if displayed == .nativeInsertion, !helpBody.isHidden { onAction?(.keyboardInsertion) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem?
    private var monitor: KeyboardMonitor?
    private let toggle = NSMenuItem(title: "", action: #selector(togglePicker), keyEquivalent: "")
    private let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let test = NSMenuItem(title: "Test Picker…", action: #selector(testPicker), keyEquivalent: "")
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
        welcome.onAction = { [weak self] action in self?.performSetupAction(action) }
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
        if !state.pickerAvailable { welcome.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrowserPaste.shared.finish()
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
        toggle.isEnabled = state.pickerAvailable || paused
        test.isEnabled = state.pickerAvailable
        let loginStatus = SMAppService.mainApp.status
        login.state = loginStatus == .enabled ? .on : .off
        login.title = loginStatus == .requiresApproval ? "Approve Open at Login…" : "Open at Login"
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

    private func performSetupAction(_ action: SetupAction) {
        switch action {
        case .done: welcome.close()
        case .resume: togglePicker()
        case .retry: refresh()
        case .accessibility:
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
            openPrivacyPane("Privacy_Accessibility")
        case .keyboardInsertion:
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

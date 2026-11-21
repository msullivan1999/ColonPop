import AppKit
import XCTest
@testable import ColonPop

@MainActor
final class WelcomeWindowTests: XCTestCase {
    private func makeSetup(_ state: AppState) -> WelcomeWindow {
        _ = NSApplication.shared
        let setup = WelcomeWindow()
        setup.update(state)
        return setup
    }

    private func visibleViews(in view: NSView) -> [NSView] {
        guard !view.isHidden else { return [] }
        return [view] + view.subviews.flatMap { visibleViews(in: $0) }
    }

    private func buttons(in setup: WelcomeWindow) -> [NSButton] {
        visibleViews(in: setup.window.contentView!).compactMap { $0 as? NSButton }
    }

    func testSetupExampleShowsHowToTypeTheFullShortcode() throws {
        let setup = makeSetup(.ready)
        let labels = visibleViews(in: setup.window.contentView!).compactMap { $0 as? NSTextField }
        let sample = try XCTUnwrap(labels.first { $0.stringValue.contains("👋") })
        XCTAssertEqual(sample.stringValue.split(whereSeparator: \.isWhitespace), [":wave:", "→", "👋"])
        XCTAssertTrue(sample.accessibilityLabel()?.contains("closing colon") == true)
    }

    func testReturnAndTestPickerUseTheirOwnActionsInBothWorkingStates() throws {
        for state in [AppState.nativeInsertion, .ready] {
            let setup = makeSetup(state)
            var actions: [SetupAction] = []
            var tests = 0
            setup.onAction = { actions.append($0) }
            setup.onTest = { tests += 1 }
            let defaults = buttons(in: setup).filter { $0.keyEquivalent == "\r" }
            XCTAssertEqual(defaults.map(\.title), ["Done"])
            try XCTUnwrap(defaults.first).performClick(nil)
            try XCTUnwrap(buttons(in: setup).first { $0.title == "Test Picker…" }).performClick(nil)
            XCTAssertEqual(actions, [.done])
            XCTAssertEqual(tests, 1)
        }
    }

    func testOptionalPermissionRequiresAnExpandedDisclosureAndAnExplicitClick() throws {
        let setup = makeSetup(.nativeInsertion)
        var actions: [SetupAction] = []
        setup.onAction = { actions.append($0) }
        let help = try XCTUnwrap(buttons(in: setup).first { $0.title == "Trouble inserting?" })
        let permissionTitle = SetupAction.keyboardInsertion.rawValue
        XCTAssertFalse(buttons(in: setup).contains { $0.title == permissionTitle })
        let initialFrame = setup.window.frame
        help.performClick(nil)
        setup.update(.nativeInsertion) // A periodic permission refresh must preserve the disclosure.
        XCTAssertTrue(help.isAccessibilityExpanded())
        XCTAssertGreaterThan(setup.window.frame.height, initialFrame.height)
        XCTAssertEqual(setup.window.frame.maxY, initialFrame.maxY, accuracy: 1)
        let permission = try XCTUnwrap(buttons(in: setup).first { $0.title == permissionTitle })
        XCTAssertEqual(permission.keyEquivalent, "")
        XCTAssertTrue(actions.isEmpty)
        permission.performClick(nil)
        XCTAssertEqual(actions, [.keyboardInsertion])
        help.performClick(nil)
        XCTAssertFalse(help.isAccessibilityExpanded())
        XCTAssertFalse(buttons(in: setup).contains { $0.title == permissionTitle })
        XCTAssertEqual(setup.window.frame.height, initialFrame.height, accuracy: 1)
        setup.update(.ready)
        XCTAssertFalse(buttons(in: setup).contains { $0 === help })
        _ = permission.sendAction(permission.action, to: permission.target)
        XCTAssertEqual(actions, [.keyboardInsertion])
    }

    func testFirstRunExplainsPrivacyAndRevealsRecoveryOnlyWhenRequested() throws {
        let setup = makeSetup(.accessibility)
        var actions: [SetupAction] = []
        setup.onAction = { actions.append($0) }
        func labels() -> [String] {
            visibleViews(in: setup.window.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
        }
        let help = try XCTUnwrap(buttons(in: setup).first { $0.title == "Already enabled?" })
        XCTAssertTrue(labels().contains { $0.contains("Emoji search runs on your Mac") && $0.contains("no typing history") })
        XCTAssertFalse(labels().contains { $0.contains("remove the old ColonPop entry") })
        XCTAssertFalse(labels().contains { $0.contains(Bundle.main.bundlePath) })
        help.performClick(nil)
        XCTAssertTrue(labels().contains { $0.contains("remove the old ColonPop entry") })
        XCTAssertTrue(labels().contains { $0.contains(Bundle.main.bundlePath) })
        XCTAssertTrue(actions.isEmpty)
        XCTAssertFalse(buttons(in: setup).contains { $0.title == SetupAction.keyboardInsertion.rawValue })
        try XCTUnwrap(buttons(in: setup).first { $0.keyEquivalent == "\r" }).performClick(nil)
        XCTAssertEqual(actions, [.accessibility])
        setup.update(.nativeInsertion)
        XCTAssertFalse(labels().contains { $0.contains("remove the old ColonPop entry") })
        XCTAssertFalse(buttons(in: setup).contains { $0.title == SetupAction.keyboardInsertion.rawValue })
    }
}

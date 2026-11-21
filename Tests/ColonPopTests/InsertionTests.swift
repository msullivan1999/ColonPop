import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ColonPop

/// Only the cross-process boundary is substituted. The monitor, composer,
/// picker geometry, edit scheduling, Quartz events and AppKit text editing are real.
@MainActor
private final class EditorFixture {
    let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 100))
    let pid: pid_t
    var reportedCaret: NSRange?
    var rangesReadable = true
    var rangeReadFails = false
    var ignoresSelection = false
    var selectionSupported = true
    var ignoresReplacement = false
    var nativeWrites = 0
    var browserEditor = false
    var browserWrites = 0
    var browserBusy = 0
    var ownsFocus = true

    init(_ before: String, _ after: String, pid: pid_t = 73) {
        self.pid = pid
        view.isRichText = false
        view.string = before + after
        view.setSelectedRange(NSRange(location: before.utf16.count, length: 0))
    }

    func snapshot(caret: NSRange? = nil) -> any FocusedEditor {
        Snapshot(host: self, selection: caret ?? reportedCaret ?? view.selectedRange())
    }

    private struct Snapshot: FocusedEditor {
        let host: EditorFixture
        let selection: NSRange?
        var pid: pid_t { host.pid }
        let simpleTextControl = true
        var browserEditor: Bool { host.browserEditor }
        func stillOwnsFocus() -> Bool { host.ownsFocus }
        func replaceBrowserSelection(_ literal: String, with glyph: String) -> SelectionWrite {
            if host.browserBusy > 0 { host.browserBusy -= 1; return .busy }
            guard selectedText() == literal else { return .unavailable }
            host.browserWrites += 1
            host.view.insertText(glyph, replacementRange: host.view.selectedRange())
            return .issued(onVerified: nil)
        }

        func sameEditor(as other: any FocusedEditor) -> Bool { (other as? Snapshot)?.host === host }
        func caretBounds() -> CGRect? { nil }
        func text(in range: NSRange) -> SuffixEvidence {
            if host.rangeReadFails { return .failed }
            guard host.rangesReadable else { return .unsupported }
            let string = host.view.string as NSString
            guard NSMaxRange(range) <= string.length else { return .failed }
            return .text(string.substring(with: range))
        }
        func replaceSelectedText(with text: String) -> AXError {
            host.nativeWrites += 1
            if !host.ignoresReplacement { host.view.setAccessibilitySelectedText(text) }
            return .success
        }
        func setSelection(_ range: NSRange) -> AXError {
            guard host.selectionSupported else { return .attributeUnsupported }
            if !host.ignoresSelection { host.view.setAccessibilitySelectedTextRange(range) }
            return .success
        }
        func selectedText() -> String? {
            (host.view.string as NSString).substring(with: host.view.selectedRange())
        }
    }
}

@MainActor
private final class TestPicker: PickerSurface {
    var onPick: ((Candidate) -> Void)?
    var items: [Candidate] = []
    var failureShown = false
    let top: CGFloat = 900
    // A screen to the left and above the main display.
    var frame: CGRect { CGRect(x: -600, y: 990, width: 300, height: CGFloat(items.count) * 34 + 34) }
    func hide() { items = [] }
    func showInsertionFailure(needsKeyboardAccess: Bool) { failureShown = true }
    func show(_ items: [Candidate], selected: Int?, quartzCaret: CGRect?) { self.items = items }
    func contains(quartzPoint: CGPoint) -> Bool { frame.contains(CGPoint(x: quartzPoint.x, y: top - quartzPoint.y)) }
    func candidate(atQuartzPoint point: CGPoint) -> Candidate? {
        PopupPlacement.rowIndex(atQuartzPoint: point, panel: frame, primaryTop: top, count: items.count).map { items[$0] }
    }
}

@MainActor
private final class InputFixture {
    static let catalog = try! Catalog.bundled()
    let picker = TestPicker()
    var host: EditorFixture
    var openingCaret: NSRange?
    var canPost = true
    var editorAvailable = true
    var posted: [[CGEvent]] = []
    lazy var monitor: KeyboardMonitor = KeyboardMonitor(catalog: Self.catalog, picker: picker, readEditor: { [unowned self] opening in
        self.editorAvailable ? self.host.snapshot(caret: opening ? self.openingCaret : nil) : nil
    }, frontmostPID: { [unowned self] in self.host.pid }, canPost: { [unowned self] in self.canPost }, post: { [unowned self] events, pid in
        self.deliver(events, to: pid)
    })

    private func deliver(_ events: [CGEvent], to pid: pid_t) {
        XCTAssertEqual(pid, host.pid)
        posted.append(events)
        for event in events where event.type == .keyDown {
            XCTAssertTrue(monitor.receive(.keyDown, event), "Generated events should pass through once")
            host.view.keyDown(with: NSEvent(cgEvent: event)!)
        }
    }

    init(_ before: String = "", _ after: String = "") { host = EditorFixture(before, after) }

    @discardableResult
    func key(_ characters: String, code: Int = kVK_ANSI_A, deliver: Bool = true) -> Bool {
        let event = CGEvent(source: nil)!
        event.type = .keyDown
        event.flags = []
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
        let units = Array(characters.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        let passed = monitor.receive(.keyDown, event)
        if passed && deliver { host.view.keyDown(with: NSEvent(cgEvent: event)!) }
        event.type = .keyUp
        XCTAssertEqual(monitor.receive(.keyUp, event), passed)
        return passed
    }

    func type(_ text: String) { for ch in text { XCTAssertTrue(key(String(ch))) } }

    func click(_ type: CGEventType, at point: CGPoint) -> Bool {
        let event = CGEvent(source: nil)!
        event.type = type
        event.location = point
        return monitor.receive(type, event)
    }

    func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Editor or picker did not reach the expected state", file: file, line: line)
    }
}

final class InsertionTests: XCTestCase {
    @MainActor
    func testChromeReturnReplacesOnlyTheVerifiedTokenWithEitherPermission() async throws {
        for canPost in [false, true] {
            let f = InputFixture("🧑🏾‍💻 ", " after")
            f.host.browserEditor = true
            f.canPost = canPost
            f.type(":wave")
            XCTAssertFalse(f.key("\r", code: kVK_Return))
            try await f.waitFor { f.host.view.string == "🧑🏾‍💻 👋 after" }
            XCTAssertEqual(f.host.browserWrites, 1)
            XCTAssertEqual(f.host.nativeWrites, 0)
            XCTAssertTrue(f.posted.isEmpty)
        }
    }

    @MainActor
    func testChromeDoesNotReceiveFormReturnWhileItsFocusTreeRefreshes() async throws {
        let f = InputFixture()
        f.host.browserEditor = true
        f.type(":wave")
        try await f.waitFor { !f.picker.items.isEmpty }
        f.editorAvailable = false
        XCTAssertFalse(f.key("\r", code: kVK_Return))
        XCTAssertEqual(f.host.view.string, ":wave")
        f.editorAvailable = true
        try await f.waitFor { f.host.view.string == "👋" }
    }

    @MainActor
    func testChromeWithoutWritableRangesCanStillReplaceAVerifiedShortcodeWithKeys() async throws {
        let f = InputFixture("Before ", " after")
        f.host.browserEditor = true
        f.host.selectionSupported = false
        f.type(":wave")
        XCTAssertFalse(f.key("\r", code: kVK_Return))
        try await f.waitFor { f.host.view.string == "Before 👋 after" }
        XCTAssertEqual(f.posted.count, 1)
        XCTAssertEqual(f.host.browserWrites, 0)
    }

    @MainActor
    func testChromePendingReturnCannotEditASecondField() async throws {
        let f = InputFixture()
        f.host.browserEditor = true
        let first = f.host
        f.type(":wave")
        f.editorAvailable = false
        XCTAssertFalse(f.key("\r", code: kVK_Return))
        f.host = EditorFixture(":wave", "", pid: first.pid)
        f.editorAvailable = true
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(first.view.string, ":wave")
        XCTAssertEqual(f.host.view.string, ":wave")
        XCTAssertEqual(first.browserWrites, 0)
    }

    @MainActor
    func testChromePassesReturnIfFocusActuallyLeftTheOriginalField() {
        let f = InputFixture()
        f.host.browserEditor = true
        f.type(":wave")
        f.editorAvailable = false
        f.host.ownsFocus = false
        XCTAssertTrue(f.key("\r", code: kVK_Return, deliver: false))
        XCTAssertEqual(f.host.browserWrites, 0)
    }

    @MainActor
    func testChromeWithOnlySelectedTextAvailableCanFinishAQueuedEditOnce() async throws {
        let f = InputFixture("Hello ", "!")
        f.host.browserEditor = true
        f.host.rangeReadFails = true
        f.host.browserBusy = 2
        f.canPost = false
        f.type(":wave")
        XCTAssertFalse(f.key("\t", code: kVK_Tab))
        try await f.waitFor { f.host.view.string == "Hello 👋!" }
        XCTAssertEqual(f.host.browserWrites, 1)
        XCTAssertFalse(f.picker.failureShown)
    }

    @MainActor
    func testLateEditorRecoversTheFirstColonAndQueryBeforeReturn() async throws {
        let f = InputFixture("Before ", " after")
        f.editorAvailable = false
        f.type(":wave")
        XCTAssertEqual(f.host.view.string, "Before :wave after")
        f.editorAvailable = true
        try await f.waitFor { f.picker.items.first?.glyph == "👋" }
        XCTAssertFalse(f.key("\r", code: kVK_Return))
        try await f.waitFor { f.host.view.string == "Before 👋 after" }
    }

    @MainActor
    func testLateEditorStillRejectsColonInURL() async throws {
        let f = InputFixture("https")
        f.editorAvailable = false
        f.type(":w")
        f.editorAvailable = true
        try await Task.sleep(nanoseconds: 230_000_000)
        XCTAssertTrue(f.picker.items.isEmpty)
        XCTAssertTrue(f.key("\r", code: kVK_Return))
        XCTAssertEqual(f.host.view.string, "https:w\n")
    }

    @MainActor
    func testDelayedOpeningCannotFollowFocusIntoAnotherProcess() async throws {
        let f = InputFixture()
        f.editorAvailable = false
        f.type(":wave")
        f.host = EditorFixture(":wave", "", pid: 99)
        f.editorAvailable = true
        try await Task.sleep(nanoseconds: 210_000_000)
        XCTAssertTrue(f.picker.items.isEmpty)
        XCTAssertTrue(f.key("\r", code: kVK_Return))
        XCTAssertTrue(f.posted.isEmpty)
    }

    @MainActor
    func testEscapeCancelsTheDelayedOpening() async throws {
        let f = InputFixture()
        f.editorAvailable = false
        f.type(":w")
        XCTAssertTrue(f.key("\u{1b}", code: kVK_Escape, deliver: false))
        f.editorAvailable = true
        try await Task.sleep(nanoseconds: 210_000_000)
        XCTAssertTrue(f.picker.items.isEmpty)
        XCTAssertEqual(f.host.view.string, ":w")
    }

    @MainActor
    func testFirstPhysicalColonShowsFavoritesWhenPostingIsDenied() async throws {
        let f = InputFixture()
        f.canPost = false
        XCTAssertTrue(f.key(":", code: kVK_ANSI_Semicolon))
        try await f.waitFor { !f.picker.items.isEmpty }
        XCTAssertEqual(f.host.view.string, ":")
        XCTAssertTrue(f.posted.isEmpty)
    }

    @MainActor
    func testNativeInsertionVerifiesAnEditInTheMiddleOfUnicodeText() async throws {
        let f = InputFixture("👩🏾‍💻 ", " tomorrow")
        f.canPost = false
        f.type(":wave")
        XCTAssertFalse(f.key("\r", code: kVK_Return))
        try await f.waitFor { f.host.view.string == "👩🏾‍💻 👋 tomorrow" }
        XCTAssertEqual(f.host.nativeWrites, 1)
        XCTAssertTrue(f.posted.isEmpty)
    }

    @MainActor
    func testNativeInsertionFromAClickUsesTheChosenRow() async throws {
        let f = InputFixture("(", ")")
        f.canPost = false
        f.type(":w")
        try await f.waitFor { f.picker.items.count >= 2 }
        let second = f.picker.items[1].glyph
        let row = PopupPlacement.rowFrame(1, in: f.picker.frame.size)
        let point = CGPoint(x: f.picker.frame.minX + row.midX, y: f.picker.top - f.picker.frame.minY - row.midY)
        XCTAssertFalse(f.click(.leftMouseDown, at: point))
        XCTAssertFalse(f.click(.leftMouseUp, at: point))
        try await f.waitFor { f.host.view.string == "(" + second + ")" }
        XCTAssertTrue(f.posted.isEmpty)
        XCTAssertEqual(f.host.nativeWrites, 1)
    }

    @MainActor
    func testIgnoringAnAccessibilityWriteShowsFailureWithoutRepeatingIt() async throws {
        let f = InputFixture()
        f.canPost = false
        f.host.ignoresReplacement = true
        f.type(":wave:")
        try await f.waitFor { f.picker.failureShown }
        XCTAssertEqual(f.host.view.string, ":wave:")
        XCTAssertEqual(f.host.nativeWrites, 1)
        XCTAssertTrue(f.posted.isEmpty)
    }

    @MainActor
    func testNativeInsertionCannotOverwriteAMismatchedShortcode() async throws {
        let f = InputFixture()
        f.canPost = false
        f.type(":wave")
        f.host.view.string = ":save"
        f.host.view.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertFalse(f.key("\t", code: kVK_Tab))
        try await f.waitFor { f.picker.failureShown }
        XCTAssertEqual(f.host.view.string, ":save")
        XCTAssertEqual(f.host.nativeWrites, 0)
        XCTAssertTrue(f.posted.isEmpty)
    }

    @MainActor
    func testUnavailablePrefixAfterTypedSpaceStillOpensPicker() async throws {
        let f = InputFixture("Hello")
        f.host.rangeReadFails = true
        f.type(" :w")
        try await f.waitFor { !f.picker.items.isEmpty }
        XCTAssertEqual(f.host.view.string, "Hello :w")
    }

    @MainActor
    func testUnavailablePrefixInsideTypedWordPassesReturnToEditor() {
        let f = InputFixture()
        f.host.rangeReadFails = true
        f.type("word:w")
        XCTAssertTrue(f.key("\r", code: kVK_Return))
        XCTAssertEqual(f.host.view.string, "word:w\n")
        XCTAssertTrue(f.posted.isEmpty)
    }

    @MainActor
    func testReadablePrefixAfterMouseMoveWinsOverKeyboardBoundary() {
        let f = InputFixture("https")
        XCTAssertTrue(f.click(.leftMouseDown, at: .zero))
        f.type(":w")
        XCTAssertTrue(f.key("\r", code: kVK_Return))
        XCTAssertEqual(f.host.view.string, "https:w\n")
    }

    @MainActor
    func testFocusUnavailableDuringQueryPassesReturnThrough() async throws {
        let f = InputFixture()
        f.type(":wave")
        try await f.waitFor { !f.picker.items.isEmpty }
        f.editorAvailable = false
        XCTAssertTrue(f.key("\r", code: kVK_Return))
        XCTAssertTrue(f.picker.items.isEmpty)
        XCTAssertEqual(f.host.view.string, ":wave\n")
        XCTAssertTrue(f.posted.isEmpty)
    }

    @MainActor
    func testClickOutsideDismissesAndKeepsLiteral() async throws {
        let f = InputFixture()
        f.type(":wave")
        try await f.waitFor { !f.picker.items.isEmpty }
        XCTAssertTrue(f.click(.leftMouseDown, at: .zero))
        XCTAssertTrue(f.click(.leftMouseUp, at: .zero))
        XCTAssertTrue(f.picker.items.isEmpty)
        XCTAssertTrue(f.key("\r", code: kVK_Return))
        XCTAssertEqual(f.host.view.string, ":wave\n")
    }

    @MainActor
    func testReturnCommitsWithStaleOpeningOffset() async throws {
        let f = InputFixture("🧑🏽‍💻 ", " next")
        f.openingCaret = NSRange(location: 0, length: 0)
        f.type(":wave")
        XCTAssertFalse(f.key("\r", code: kVK_Return))
        try await f.waitFor { f.host.view.string == "🧑🏽‍💻 👋 next" }
        XCTAssertEqual(f.posted.count, 1)
    }

    @MainActor
    func testMouseDownInsertsTheClickedRowAndConsumesMouseUp() async throws {
        let f = InputFixture(" ", "!")
        f.type(":w")
        try await f.waitFor { f.picker.items.count > 2 }
        let hit = f.picker.items[2]
        let panel = f.picker.frame
        let rect = PopupPlacement.rowFrame(2, in: panel.size)
        let point = CGPoint(x: panel.minX + rect.midX, y: f.picker.top - panel.minY - rect.midY)
        XCTAssertNil(f.picker.candidate(atQuartzPoint: CGPoint(x: point.x, y: f.picker.top - panel.minY - 5)))
        XCTAssertFalse(f.click(.leftMouseDown, at: point))
        XCTAssertFalse(f.click(.leftMouseUp, at: point))
        try await f.waitFor { f.host.view.string == " " + hit.glyph + "!" }
        XCTAssertEqual(f.posted.count, 1)
        XCTAssertTrue(f.click(.leftMouseUp, at: point))
    }

    @MainActor
    func testExactDelimiterWaitsForHostAndIsReplacedOnce() async throws {
        let f = InputFixture("(", ")")
        f.type(":tada")
        XCTAssertTrue(f.key(":", deliver: false))
        // The physical delimiter reached the tap before the editor updated its text.
        try await Task.sleep(nanoseconds: 17_000_000)
        f.host.view.insertText(":", replacementRange: f.host.view.selectedRange())
        try await f.waitFor { f.host.view.string == "(🎉)" }
        XCTAssertEqual(f.posted.count, 1)
    }

    @MainActor
    func testTabWithOpaqueRangeReadsVerifiesHostSelection() async throws {
        let f = InputFixture("Keep ", " end")
        f.host.reportedCaret = NSRange(location: 0, length: 0)
        f.host.rangesReadable = false
        f.type(":wave")
        XCTAssertFalse(f.key("\t", code: kVK_Tab))
        try await f.waitFor { f.host.view.string == "Keep 👋 end" }
        XCTAssertEqual(f.posted.count, 2)
        XCTAssertTrue(f.posted[0].allSatisfy { $0.flags.contains(.maskShift) })
    }

    @MainActor
    func testReportedSuccessWithoutSelectionPreservesLiteral() async throws {
        let f = InputFixture()
        f.host.reportedCaret = NSRange(location: 0, length: 0)
        f.host.ignoresSelection = true
        f.type(":wave")
        XCTAssertFalse(f.key("\r", code: kVK_Return))
        try await Task.sleep(nanoseconds: 330_000_000)
        XCTAssertEqual(f.host.view.string, ":wave")
        XCTAssertTrue(f.posted.isEmpty)
        XCTAssertTrue(f.picker.failureShown)
    }

    @MainActor
    func testConfirmedSelectionInAnEditorWithFrozenCaret() async throws {
        let f = InputFixture("", "!")
        f.host.reportedCaret = NSRange(location: 0, length: 0)
        f.type(":wave")
        XCTAssertFalse(f.key("\r", code: kVK_Return))
        try await f.waitFor { f.host.view.string == "👋!" }
        XCTAssertEqual(f.posted.first?.count, 2, "The verified selection needs one Unicode key pair")
    }

    @MainActor
    func testFocusChangeBeforeDeliveryPreservesBothEditors() async throws {
        let f = InputFixture()
        let first = f.host
        f.type(":wave")
        XCTAssertFalse(f.key("\r", code: kVK_Return))
        f.host = EditorFixture("another field", "", pid: first.pid)
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertTrue(f.posted.isEmpty)
        XCTAssertEqual(first.view.string, ":wave")
        XCTAssertEqual(f.host.view.string, "another field")
    }

    @MainActor
    func testTypingImmediatelyAfterReturnKeepsNextCharacter() {
        let f = InputFixture()
        f.type(":w")
        XCTAssertFalse(f.key("\r", code: kVK_Return))
        f.type(" next")
        let glyph = InputFixture.catalog.search("w")[0].glyph
        XCTAssertEqual(f.host.view.string, glyph + " next")
        XCTAssertEqual(f.posted.count, 1)
    }

    @MainActor
    func testChangedShortcodeIsNeverDeleted() async throws {
        let f = InputFixture()
        f.type(":wave")
        f.host.view.string = ":wove"
        f.host.view.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertFalse(f.key("\r", code: kVK_Return))
        try await f.waitFor { f.picker.failureShown }
        XCTAssertEqual(f.host.view.string, ":wove")
        XCTAssertTrue(f.posted.isEmpty)
    }
}

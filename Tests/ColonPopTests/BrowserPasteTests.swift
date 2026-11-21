import AppKit
import XCTest
@testable import ColonPop

@MainActor
private final class TestPasteboard: BrowserPasteboard {
    var changeCount = 0
    var pasteboardItems: [NSPasteboardItem]? = []
    var types: [NSPasteboard.PasteboardType]? { pasteboardItems?.flatMap(\.types) }
    func clearContents() -> Int { changeCount += 1; pasteboardItems = []; return changeCount }
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        let item = NSPasteboardItem()
        item.setString(string, forType: type)
        return writeObjects([item])
    }
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool {
        changeCount += 1
        pasteboardItems = objects.compactMap { $0 as? NSPasteboardItem }
        return true
    }
}

final class BrowserPasteTests: XCTestCase {
    @MainActor func testRestoresEveryItemAndFormatAfterVerifiedPaste() throws {
        let board = TestPasteboard()
        let first = NSPasteboardItem()
        first.setString("original", forType: .string)
        first.setData(Data([1, 3, 7]), forType: .rtf)
        let second = NSPasteboardItem()
        second.setString("second", forType: .string)
        XCTAssertTrue(board.writeObjects([first, second]))
        let paste = BrowserPaste(board: board)
        let result = paste.withTemporaryText("👋") {
            XCTAssertEqual(board.pasteboardItems?.first?.string(forType: .string), "👋")
            return .success
        }
        guard case .issued(let finish) = result else { return XCTFail("Paste was not issued") }
        finish?()
        let items = try XCTUnwrap(board.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].data(forType: .rtf), Data([1, 3, 7]))
        XCTAssertEqual(items.map { $0.string(forType: .string) }, ["original", "second"])
    }

    @MainActor func testNewerCopySurvivesAndAStaleCompletionCannotRestoreAnotherEdit() {
        let board = TestPasteboard()
        let paste = BrowserPaste(board: board)
        guard case .issued(let first) = paste.withTemporaryText("👋", perform: { .success }) else { return XCTFail() }
        XCTAssertTrue(board.setString("new user copy", forType: .string))
        guard case .issued(let second) = paste.withTemporaryText("🎉", perform: { .success }) else { return XCTFail() }
        first?()
        XCTAssertEqual(board.pasteboardItems?.first?.string(forType: .string), "🎉")
        second?()
        XCTAssertEqual(board.pasteboardItems?.first?.string(forType: .string), "new user copy")
    }

    @MainActor func testConfidentialClipboardIsLeftAlone() {
        let board = TestPasteboard()
        XCTAssertTrue(board.setString("test sentinel", forType: .init("org.nspasteboard.ConcealedType")))
        let initial = board.changeCount
        let result = BrowserPaste(board: board).withTemporaryText("👋") { XCTFail("Paste should not run"); return .failure }
        guard case .unavailable = result else { return XCTFail() }
        XCTAssertEqual(board.changeCount, initial)
    }

    @MainActor func testFailedMenuCommandImmediatelyRestoresAnEmptyBoard() {
        let board = TestPasteboard()
        let result = BrowserPaste(board: board).withTemporaryText("👋") { .actionUnsupported }
        guard case .unavailable = result else { return XCTFail() }
        XCTAssertEqual(board.pasteboardItems?.count, 0)
    }

    @MainActor func testUnacknowledgedPasteRestoresTheClipboardAndRejectsOverlappingPastes() async throws {
        let board = TestPasteboard()
        XCTAssertTrue(board.setString("original", forType: .string))
        let paste = BrowserPaste(board: board)
        guard case .issued = paste.withTemporaryText("👋", perform: { .cannotComplete }) else { return XCTFail() }
        let second = paste.withTemporaryText("🎉") { XCTFail("A second paste ran before the first finished"); return .failure }
        guard case .busy = second else { return XCTFail() }
        XCTAssertEqual(board.pasteboardItems?.first?.string(forType: .string), "👋")
        for _ in 0..<60 {
            if board.pasteboardItems?.first?.string(forType: .string) == "original" { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("The timed-out command left the temporary emoji on the clipboard")
    }

    @MainActor func testOversizedClipboardIsPreservedWithoutIssuingPaste() throws {
        let board = TestPasteboard()
        let item = NSPasteboardItem()
        let data = Data(repeating: 1, count: 8 * 1024 * 1024 + 1)
        XCTAssertTrue(item.setData(data, forType: .png))
        XCTAssertTrue(board.writeObjects([item]))
        let originalCount = board.changeCount
        let result = BrowserPaste(board: board).withTemporaryText("👋") { XCTFail("Paste should not run"); return .failure }
        guard case .unavailable = result else { return XCTFail() }
        XCTAssertEqual(board.changeCount, originalCount)
        XCTAssertEqual(try XCTUnwrap(board.pasteboardItems?.first?.data(forType: .png)).count, data.count)
    }
}

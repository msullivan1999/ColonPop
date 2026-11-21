import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ColonPop

final class ColonPopTests: XCTestCase {
    private static let catalog = try! Catalog.bundled()

    private func composing(_ value: String = "") -> Composer {
        var composer = Composer(catalog: Self.catalog)
        composer.begin()
        for character in value {
            XCTAssertEqual(composer.handle(.text(String(character))), .pass)
        }
        return composer
    }

    func testBundleAndExactShortcodes() {
        let catalog = Self.catalog
        XCTAssertEqual(catalog.count, 1875)
        let examples = ["+1": "👍", "-1": "👎", "thumbsup": "👍", "TaDa": "🎉", "party_popper": "🎉",
                        "flag-au": "🇦🇺", "woman_technologist": "👩‍💻", "skin-tone-4": "🏽", "heart": "❤️"]
        for (alias, glyph) in examples {
            XCTAssertEqual(catalog.exactMatch(alias)?.glyph, glyph, alias)
            XCTAssertEqual(catalog.search(alias).first?.glyph, glyph, alias)
        }
    }

    func testSearchDescriptionTagsLimitAndDistinctResults() {
        let catalog = Self.catalog
        XCTAssertEqual(catalog.search("").count, 6)
        XCTAssertTrue(catalog.search("hooray").contains { $0.glyph == "🎉" })
        XCTAssertTrue(catalog.search("coder").contains { $0.glyph == "👩‍💻" })
        let short = catalog.search("s")
        XCTAssertEqual(short.count, Catalog.rowLimit)
        XCTAssertEqual(Set(short.map(\.glyph)).count, short.count)
        XCTAssertTrue(catalog.search("xxxabsentxxx").isEmpty)
    }

    func testReturnTabAndExactDelimiter() {
        for key: InputKey in [.enter, .tab, .text(":")] {
            var composer = composing("wave")
            XCTAssertEqual(composer.handle(key), .insert(Self.catalog.exactMatch("wave")!))
        }
        var partial = composing("wom")
        let first = partial.matches[0]
        XCTAssertEqual(partial.handle(.enter), .insert(first))
        XCTAssertEqual(partial.handle(.text(":")), .pass)
        XCTAssertNil(partial.query)
    }

    func testNavigationWrapsAndQueryEditsResetSelection() {
        var composer = composing()
        XCTAssertEqual(composer.handle(.up), .consume)
        XCTAssertEqual(composer.selection, 5)
        XCTAssertEqual(composer.handle(.down), .consume)
        XCTAssertEqual(composer.selection, 0)
        XCTAssertEqual(composer.handle(.enter), .insert(composer.matches[0]))
        XCTAssertEqual(composer.handle(.text("s")), .pass)
        XCTAssertEqual(composer.handle(.down), .consume)
        XCTAssertEqual(composer.handle(.text("m")), .pass)
        XCTAssertEqual(composer.selection, 0)
        XCTAssertEqual(composer.handle(.backspace), .pass)
        XCTAssertEqual(composer.literal, ":s")
    }

    func testReturnHintOnlyHighlightsAnActionableChoice() {
        var composer = composing()
        XCTAssertNil(composer.highlightedIndex)
        XCTAssertEqual(composer.handle(.down), .consume)
        XCTAssertEqual(composer.highlightedIndex, 0)
        XCTAssertEqual(composer.handle(.enter), .insert(composer.matches[0]))
        composer = composing("wave")
        XCTAssertEqual(composer.highlightedIndex, 0)
        composer = composing("xyzxyz")
        XCTAssertNil(composer.highlightedIndex)
    }

    func testPlainColonAndUnmatchedNamesPreserveHostKeys() {
        for key: InputKey in [.enter, .tab, .text(":"), .backspace, .text(" ")] {
            var composer = composing()
            XCTAssertEqual(composer.handle(key), .pass)
            XCTAssertNil(composer.query)
        }
        for key: InputKey in [.enter, .tab, .down, .text(":")] {
            var composer = composing("xyzxyz")
            XCTAssertEqual(composer.handle(key), .pass)
            XCTAssertNil(composer.query)
        }
        var emptyResults = composing("xyzxyz")
        XCTAssertEqual(emptyResults.handle(.escape), .consume)
        XCTAssertNil(emptyResults.query)
    }

    func testEscapeNavigationAndLengthLimit() {
        var composer = composing("wa")
        XCTAssertEqual(composer.handle(.escape), .consume)
        XCTAssertNil(composer.query)
        composer = composing("wave")
        XCTAssertEqual(composer.handle(.other), .pass)
        XCTAssertNil(composer.query)
        composer = composing(String(repeating: "a", count: 96))
        XCTAssertEqual(composer.handle(.text("a")), .pass)
        XCTAssertNil(composer.query)
    }

    func testTriggerBoundaries() {
        for character: Character? in [nil, " ", "\n", "\t", "(", "[", "“", "👋", "❤️"] {
            XCTAssertTrue(Composer.canStart(after: character))
        }
        for character: Character in ["s", "2", "_", ":", "/", ".", "é", "@"] {
            XCTAssertFalse(Composer.canStart(after: character))
        }
    }

    func testReplacementUsesTheLiveSuffixAndGuardsUnreadableText() {
        let cursor = NSRange(location: 12, length: 0)
        func permitted(_ range: NSRange?, _ evidence: SuffixEvidence, start: Int? = 7, simple: Bool = true) -> Bool {
            ReplacementCheck.permits(":wave", start: start, caret: range, suffix: evidence, simpleTextControl: simple)
        }
        XCTAssertTrue(permitted(cursor, .text(":wave")))
        XCTAssertFalse(permitted(cursor, .text(":wove")))
        XCTAssertFalse(permitted(cursor, .failed))
        XCTAssertTrue(permitted(NSRange(location: 11, length: 0), .text(":wave")))
        XCTAssertFalse(permitted(NSRange(location: 11, length: 0), .unsupported))
        XCTAssertFalse(permitted(NSRange(location: 12, length: 1), .text(":wave")))
        XCTAssertFalse(permitted(NSRange(location: 3, length: 0), .text(":wave"), start: nil))
        XCTAssertFalse(permitted(nil, .unsupported))
        XCTAssertTrue(permitted(cursor, .unsupported))
        XCTAssertFalse(permitted(nil, .unsupported, start: nil, simple: false))
    }

    func testScreenCoordinatesAndEdgeClamping() {
        let quartz = CGRect(x: -970, y: -100, width: 0, height: 16)
        let anchor = PopupPlacement.appKitRect(quartz, primaryTop: 900)
        XCTAssertEqual(anchor, CGRect(x: -970, y: 984, width: 0, height: 16))
        let screen = CGRect(x: -1000, y: 900, width: 1000, height: 800)
        let size = CGSize(width: 300, height: 238)
        let above = PopupPlacement.frame(size: size, near: anchor, inside: screen)
        XCTAssertTrue(screen.contains(above))
        XCTAssertGreaterThan(above.minY, anchor.maxY)
        let below = PopupPlacement.frame(size: size, near: CGRect(x: -8, y: 1400, width: 0, height: 18), inside: screen)
        XCTAssertTrue(screen.contains(below))
        XCTAssertLessThan(below.maxY, 1400)
        XCTAssertEqual(below.maxX, screen.maxX - 6)
    }

    func testGeneratedUnicodeAndBackspacesAreDistinctPairedEvents() throws {
        let family = "👨‍👩‍👧‍👦"
        let events = try XCTUnwrap(Keyboard.events(text: family, backspaces: 3))
        XCTAssertEqual(events.count, 8)
        for (offset, event) in events.enumerated() {
            XCTAssertEqual(event.type, offset.isMultiple(of: 2) ? .keyDown : .keyUp)
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), Keyboard.marker)
            XCTAssertTrue(event.flags.isEmpty)
            if offset < 6 { XCTAssertEqual(Keyboard.decode(event), .backspace) }
        }
        let native = try XCTUnwrap(NSEvent(cgEvent: events[6]))
        XCTAssertEqual(native.characters, family)
    }

    func testModifiedKeysPassThroughAndLayoutTextDetectsColon() throws {
        let tab = try XCTUnwrap(CGEvent(source: nil))
        tab.type = .keyDown
        tab.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Tab))
        tab.flags = [.maskShift]
        XCTAssertEqual(Keyboard.decode(tab), .other)
        tab.flags = [.maskCommand]
        XCTAssertEqual(Keyboard.decode(tab), .other)
        tab.flags = []
        XCTAssertEqual(Keyboard.decode(tab), .tab)
        let colon = try XCTUnwrap(Keyboard.events(text: ":", backspaces: 0)?.first)
        colon.flags = [.maskAlternate, .maskShift]
        XCTAssertEqual(Keyboard.decode(colon), .text(":"))
        colon.flags = [.maskControl]
        XCTAssertEqual(Keyboard.decode(colon), .other)
    }

    @MainActor
    func testReplacementInNativeTextViewPreservesSurroundingUnicode() throws {
        let view = NSTextView(frame: .zero)
        let prefix = "Keep 🧑🏽‍💻 "
        let suffix = " and 🇦🇺"
        let alias = "woman_technologist"
        for useSelection in [true, false] {
            view.string = prefix + suffix
            view.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
            var composer = Composer(catalog: Self.catalog)
            composer.begin()
            view.insertText(":", replacementRange: view.selectedRange())
            for ch in alias {
                XCTAssertEqual(composer.handle(.text(String(ch))), .pass)
                view.insertText(String(ch), replacementRange: view.selectedRange())
            }
            let literal = try XCTUnwrap(composer.literal)
            let range = NSRange(location: view.selectedRange().location - literal.utf16.count, length: literal.utf16.count)
            let evidence = (view.string as NSString).substring(with: range)
            XCTAssertTrue(ReplacementCheck.permits(literal, start: prefix.utf16.count, caret: view.selectedRange(),
                                                   suffix: .text(evidence), simpleTextControl: true))
            guard case .insert(let hit) = composer.handle(.enter) else { return XCTFail("Expected a candidate") }
            if useSelection {
                view.setAccessibilitySelectedTextRange(range)
                view.setAccessibilitySelectedText(hit.glyph)
            } else {
                let events = try XCTUnwrap(Keyboard.events(text: hit.glyph, backspaces: literal.utf8.count))
                for event in events where event.type == .keyDown {
                    view.keyDown(with: try XCTUnwrap(NSEvent(cgEvent: event)))
                }
            }
            XCTAssertEqual(view.string, prefix + "👩‍💻" + suffix)
        }
    }
}

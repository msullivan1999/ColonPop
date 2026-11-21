import Foundation

enum InputKey: Equatable {
    case text(String), backspace, up, down, enter, tab, escape, other
}

enum KeyAction: Equatable {
    case pass, consume, insert(Candidate)
}

/// Tracks only the shortcode currently visible in the editor.
struct Composer {
    let catalog: Catalog
    private(set) var query: String?
    private(set) var matches: [Candidate] = []
    private(set) var selection = 0
    private var navigated = false

    init(catalog: Catalog) { self.catalog = catalog }

    var literal: String? { query.map { ":" + $0 } }
    var highlightedIndex: Int? {
        guard let query, !matches.isEmpty, !query.isEmpty || navigated else { return nil }
        return selection
    }

    static func canStart(after character: Character?) -> Bool {
        guard let character else { return true }
        return character.isWhitespace || "([{'\"“‘".contains(character)
            || character.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
    }

    mutating func begin(_ query: String = "") { update(query) }

    static func isQueryCharacter(_ text: String) -> Bool {
        guard text.utf8.count == 1, let byte = text.utf8.first else { return false }
        return (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
            || byte == 95 || byte == 43 || byte == 45
    }

    mutating func cancel() {
        query = nil
        matches = []
        selection = 0
        navigated = false
    }

    mutating func handle(_ key: InputKey) -> KeyAction {
        guard var query else { return .pass }
        switch key {
        case .text(":"):
            if let match = catalog.exactMatch(query) { return .insert(match) }
        case .text(let text):
            if Self.isQueryCharacter(text), query.utf8.count < 96 {
                update(query + text)
                return .pass
            }
        case .backspace:
            if !query.isEmpty {
                query.removeLast()
                update(query)
                return .pass
            }
        case .down, .up:
            if !matches.isEmpty {
                let step = key == .down ? 1 : -1
                if highlightedIndex == nil {
                    selection = key == .down ? 0 : matches.count - 1
                } else {
                    selection = (selection + step + matches.count) % matches.count
                }
                navigated = true
                return .consume
            }
        case .enter, .tab:
            if let highlightedIndex { return .insert(matches[highlightedIndex]) }
        case .escape:
            cancel()
            return .consume
        case .other:
            break
        }
        cancel()
        return .pass
    }

    private mutating func update(_ value: String) {
        query = value
        matches = catalog.search(value)
        selection = 0
        navigated = false
    }
}

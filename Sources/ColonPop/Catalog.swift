import Foundation

struct Candidate: Equatable {
    let glyph: String
    let alias: String
    let name: String
}

struct Catalog {
    static let rowLimit = 6
    private static let favorites = ["smile", "joy", "heart", "+1", "tada", "eyes"]

    private struct Entry {
        let glyph: String
        let aliases: [String]
        let name: String
        let words: [String]

        func candidate(_ alias: String) -> Candidate {
            Candidate(glyph: glyph, alias: alias, name: name)
        }
    }

    private let entries: [Entry]
    private let exact: [String: Candidate]
    var count: Int { entries.count }

    static func bundled() throws -> Catalog {
        var url = Bundle.main.url(forResource: "emoji", withExtension: "tsv")
        #if SWIFT_PACKAGE
        if url == nil { url = Bundle.module.url(forResource: "emoji", withExtension: "tsv") }
        #endif
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return try Catalog(tsv: String(contentsOf: url, encoding: .utf8))
    }

    init(tsv: String) throws {
        var entries: [Entry] = []
        var exact: [String: Candidate] = [:]
        for line in tsv.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 4 else { throw CocoaError(.fileReadCorruptFile) }
            let glyph = String(parts[0])
            var aliases = parts[1].split(separator: " ").map(String.init)
            guard !glyph.isEmpty, !aliases.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            let name = String(parts[2])
            let nameWords = name.lowercased().split {
                !$0.isASCII || !($0.isLetter || $0.isNumber)
            }.map(String.init)
            let descriptiveAlias = nameWords.joined(separator: "_")
            if !descriptiveAlias.isEmpty, !aliases.contains(descriptiveAlias) {
                aliases.append(descriptiveAlias)
            }
            let scalars = glyph.unicodeScalars
            if scalars.count == 2, scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) {
                let code = scalars.map { String(UnicodeScalar($0.value - 0x1F1E6 + 97)!) }.joined()
                aliases.append("flag-" + code)
            }
            let words = nameWords + parts[3].split(separator: " ").map(String.init)
            let entry = Entry(glyph: glyph, aliases: aliases, name: name, words: words)
            entries.append(entry)
            // An upstream shortcode takes precedence over a generated description.
            for alias in aliases where exact[alias] == nil { exact[alias] = entry.candidate(alias) }
            for upstream in parts[1].split(separator: " ").map(String.init) {
                exact[upstream] = entry.candidate(upstream)
            }
        }
        guard !entries.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        self.entries = entries
        self.exact = exact
    }

    func exactMatch(_ query: String) -> Candidate? { exact[query.lowercased()] }

    func search(_ input: String) -> [Candidate] {
        let query = input.lowercased()
        if query.isEmpty { return Self.favorites.compactMap { exact[$0] } }
        let exactHit = exact[query]
        var ranked: [(rank: Int, index: Int, candidate: Candidate)] = []
        for (index, entry) in entries.enumerated() where entry.glyph != exactHit?.glyph {
            if let alias = entry.aliases.first(where: { $0.hasPrefix(query) }) {
                ranked.append((1, index, entry.candidate(alias)))
            } else if entry.words.contains(where: { $0.hasPrefix(query) }) {
                ranked.append((2, index, entry.candidate(entry.aliases[0])))
            } else if query.count >= 3, let alias = entry.aliases.first(where: { $0.contains(query) }) {
                ranked.append((3, index, entry.candidate(alias)))
            }
        }
        ranked.sort { ($0.rank, $0.index) < ($1.rank, $1.index) }
        var result = exactHit.map { [$0] } ?? []
        result += ranked.prefix(Self.rowLimit - result.count).map(\.candidate)
        return result
    }
}

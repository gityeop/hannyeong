public enum RegisteredEntityReading {
    private struct Entity {
        let stem: String
        var symbol: Character? = nil
    }

    private static let entities = [
        Entity(stem: "gpt"), Entity(stem: "tlc"), Entity(stem: "tla", symbol: "+"), Entity(stem: "chatgpt"),
    ]
    private static let particlesAndConnectors: Set<String> = [
        "은", "는", "이", "가", "을", "를", "와", "과", "하고", "이랑", "랑",
        "에", "에도", "에서", "에서도", "에서는", "에서부터", "에게", "한테",
        "로", "으로", "로도", "으로도", "도", "만", "의", "부터", "까지", "보다", "처럼", "마다", "이나", "나",
        "이고", "이며", "이라서",
    ]

    public static func match(raw: String, before: String, separator: String?, candidates: [Candidate],
                             frequencies: @autoclosure () throws -> WordFrequencies) throws -> Candidate? {
        let startsWord = isWordStart(after: before)
        for entity in entities {
            if let symbol = entity.symbol {
                if raw == entity.stem, separator?.first == symbol, startsWord {
                    return candidates.first { $0.text == raw }
                }
                let spelling = entity.stem + String(symbol)
                // The symbol was committed as a separator. The following raw word contains only the tail.
                if before.hasSuffix(spelling), isWordStart(after: before.dropLast(spelling.count)),
                   let korean = candidates.first(where: { $0.splitIndex == nil && $0.text != raw }),
                   try isKoreanTail(korean.text, frequencies: frequencies) {
                    return korean
                }
            } else if raw.hasPrefix(entity.stem), startsWord {
                if raw == entity.stem { return candidates.first { $0.text == raw } }
                if let mixed = candidates.first(where: { $0.splitIndex == entity.stem.count }),
                   try isKoreanTail(String(mixed.text.dropFirst(entity.stem.count)), frequencies: frequencies) {
                    return mixed
                }
            }
        }
        return nil
    }

    private static func isWordStart(after before: some StringProtocol) -> Bool {
        guard let last = before.last else { return true }
        return !last.isLetter && !last.isNumber && last != "_"
    }

    private static func isKoreanTail(_ text: String, frequencies: () throws -> WordFrequencies) throws -> Bool {
        if particlesAndConnectors.contains(text) { return true }
        guard text.count >= 2 else { return false }
        return try (frequencies().korean[text] ?? 0) >= 5.0
    }
}

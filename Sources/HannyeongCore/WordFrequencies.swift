import Foundation

/// Zipf word frequencies bundled as rule-lexicon.json.
public struct WordFrequencies: Decodable, Sendable {
    public let english: [String: Double]
    public let korean: [String: Double]

    public static func load(_ url: URL) throws -> WordFrequencies {
        try JSONDecoder().decode(WordFrequencies.self, from: Data(contentsOf: url))
    }
}

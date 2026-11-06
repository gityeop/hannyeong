import Foundation
import XCTest
@testable import HannyeongCore

final class CompositionTests: XCTestCase {
    func testTwoSetCompositionAndShift() throws {
        for (raw, expected) in [("dkssud", "안녕"), ("gksrmf", "한글"),
                                ("rksk", "가나"), ("rkqt", "값"), ("Rk", "까")] {
            XCTAssertEqual(try HangulComposer.compose(raw), expected, raw)
        }
    }

    func testReplayingAfterBackspaceSeparatesFinalConsonant() throws {
        XCTAssertEqual(try HangulComposer.compose("rkqt"), "값")
        XCTAssertEqual(try HangulComposer.compose("rkq"), "갑")
        XCTAssertEqual(try HangulComposer.compose("rk"), "가")
        XCTAssertEqual(try HangulComposer.compose("r"), "ㄱ")
    }

    func testEnglishPrefixIsNotFedIntoKoreanSuffixComposition() throws {
        let candidates = try CandidateBuilder.candidates(for: "googlefh", includeSplits: true)
        XCTAssertEqual(candidates.first(where: { $0.splitIndex == 6 })?.text, "google로")
        XCTAssertTrue(candidates.contains(where: { $0.text == "googlefh" }))
        XCTAssertFalse(try CandidateBuilder.candidates(for: "googlefh", includeSplits: false)
            .contains(where: { $0.text == "google로" }))
    }

    func testRegisteredEntitiesRequireAWordStartAndAnAttachedKoreanTail() throws {
        let frequencies = try JSONDecoder().decode(WordFrequencies.self,
            from: Data(#"{"english":{},"korean":{"기능":5.09}}"#.utf8))
        func match(_ raw: String, before: String = "", separator: String? = nil) throws -> String? {
            try RegisteredEntityReading.match(raw: raw, before: before, separator: separator,
                candidates: CandidateBuilder.candidates(for: raw, includeSplits: true), frequencies: frequencies)?.text
        }

        XCTAssertEqual(try match("gptrk"), "gpt가")
        XCTAssertEqual(try match("gptrlsmd"), "gpt기능")
        XCTAssertEqual(try match("gptdpeh"), "gpt에도")
        XCTAssertEqual(try match("tlcdlrh"), "tlc이고")
        XCTAssertEqual(try match("gptdlau"), "gpt이며")
        XCTAssertEqual(try match("tlcdlfktj"), "tlc이라서")
        XCTAssertEqual(try match("chatgptdptjqnxj"), "chatgpt에서부터")
        XCTAssertEqual(try match("tla", separator: "+ "), "tla")
        XCTAssertEqual(try match("fh", before: "한글 tla+"), "로")
        XCTAssertEqual(try match("dptjeh", before: "tla+"), "에서도")
        XCTAssertEqual(try match("dptjsms", before: "tla+"), "에서는")
        for before in ["tla +", "tla+ ", "한글tla+", "xtla+", "gpt+"] {
            XCTAssertNil(try match("fh", before: before), before)
        }
        XCTAssertNil(try match("tla"))
        XCTAssertNil(try match("tla", separator: " +"))
        XCTAssertNil(try match("gptqzx"))
        XCTAssertNil(try match("qzxgkrh"))
        XCTAssertNil(try match("gksrmfgptgkrh"))
        XCTAssertNil(try match("gptrk", before: "한글"))
    }

    func testAmbiguousKeysKeepBothReadings() throws {
        XCTAssertEqual(try CandidateBuilder.candidates(for: "go", includeSplits: false).map(\.text), ["go", "해"])
        XCTAssertEqual(try CandidateBuilder.candidates(for: "to", includeSplits: false).map(\.text), ["to", "새"])
    }
}

import AppKit
import InputMethodKit
import HannyeongCore

/// The app reads rule-lexicon.json from its bundle; harnesses run from the repository root.
private let ruleLexicon = try! WordFrequencies.load(URL(fileURLWithPath: ".build/dependencies/rule-lexicon.json"))

// The 43 AppKit CompositionSession checks of NativeEncoderQA, run with the personal file that
// PersonalState.select chooses in a seeded temporary folder:
//   same    — a file for the bundled model already exists (revision 3)
//   other   — only the pre-0.2.1 unsuffixed file of another model exists (revision 9)
//   missing — the folder does not exist
// Usage: PersonalStateQA <runtime.json> <same|other|missing> <output.json>

@MainActor private final class Fixture {
    let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    var errors: [String] = []
    var session: CompositionSession!
    init(prefix: String, store: CorrectionStore, local: LocalDecisionClient) {
        view.isRichText = false; view.string = prefix
        view.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
        session = CompositionSession(client: view, corrections: store, localClient: local, wordFrequencies: ruleLexicon,
                                     selectCommittedText: { [view] expected in
                                         let end = view.selectedRange().location
                                         guard end >= expected.utf16.count else {
                                             throw LocalDecisionError(detail: "Native committed caret is before target")
                                         }
                                         let range = NSRange(location: end - expected.utf16.count, length: expected.utf16.count)
                                         guard view.selectCommittedText(in: range, expected: expected) else {
                                             throw LocalDecisionError(detail: "Native committed selection text changed")
                                         }
                                         return range
                                     }, confirmCommittedText: { [view] expected in
                                         let end = view.selectedRange().location
                                         guard end >= expected.utf16.count,
                                               (view.string as NSString).substring(with: NSRange(location: end - expected.utf16.count, length: expected.utf16.count)) == expected else {
                                             throw LocalDecisionError(detail: "Native commit suffix differs")
                                         }
                                         return end
                                     }, forwardHostEvent: { [view] event in view.applyHostEvent(event) }) { [weak self] in self?.errors.append($0) }
    }
    func key(_ text: String, code: UInt16 = 0) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: text.first?.isUppercase == true ? .shift : [],
            timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)!
        if !session.handle(event) {
            if code == 51 { view.deleteBackward(nil) }
            else if code == 36 { view.keyDown(with: event) }
            else { view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
    }
    func type(_ raw: String) { for char in raw { key(String(char)) } }
    func wait() async throws {
        for _ in 0..<3000 {
            guard errors.isEmpty else { throw LocalDecisionError(detail: errors.joined(separator: "; ")) }
            if !view.hasMarkedText() && !session.hasPendingRewrite { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LocalDecisionError(detail: "Composition did not finish")
    }
}

@main private struct PersonalStateQA {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("Personal state QA failed: \(error)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }

    private static func check(_ condition: Bool, _ detail: String) throws {
        if !condition { throw LocalDecisionError(detail: detail) }
    }

    private static func revision(_ url: URL) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return object["revision"] as! Int
    }

    @MainActor static func run() async throws {
        let arguments = CommandLine.arguments
        try check(arguments.count == 4 && ["same", "other", "missing"].contains(arguments[2]),
                  "Usage: PersonalStateQA <runtime.json> <same|other|missing> <output.json>")
        let runtime = try JSONDecoder().decode(LocalRuntimeConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        let modelID = try PersonalState.modelID(ofModel: URL(fileURLWithPath: runtime.model))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Hannyeong")
        let otherID = String(repeating: "0", count: 64)
        var seededRevision = 0
        var otherData: Data?
        switch arguments[2] {
        case "same":
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            seededRevision = 3
            try JSONSerialization.data(withJSONObject: ["modelID": modelID, "revision": 3, "entries": []])
                .write(to: folder.appendingPathComponent(PersonalState.fileName(for: modelID)))
        case "other":
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            otherData = try JSONSerialization.data(withJSONObject: ["modelID": otherID, "revision": 9, "entries": []])
            try otherData!.write(to: folder.appendingPathComponent(PersonalState.legacyName))
        default:
            break
        }
        let selection = try PersonalState.select(directory: folder, modelID: modelID)
        let expectedOrigin: PersonalStateSelection.Origin = arguments[2] == "same" ? .existing : .new
        try check(selection.origin == expectedOrigin, "Unexpected origin \(selection.origin)")
        let kept = folder.appendingPathComponent(PersonalState.fileName(for: otherID))
        try check(selection.otherModelFiles == (arguments[2] == "other" ? [kept] : []),
                  "Unexpected other-model files \(selection.otherModelFiles)")

        let store = CorrectionStore(url: folder.appendingPathComponent("corrections.json"))
        let personal = selection.url
        let local = LocalDecisionClient(runtime: runtime, personalURL: personal)
        _ = try await local.prepare()
        var outputs: [String: String] = [:]
        let cases = [("", "dkssud"), ("", "hello"), ("지금 ", "slackdptj"),
            ("If the tests pass, we can ", "go"), ("회의록은 ", "READMErk"),
            ("오늘은 ", "xptmxm"), ("먼저 ", "testgoqhrh"), ("", "a"), ("", "r"), ("", "API")]
        for (index, row) in cases.enumerated() {
            for (ending, suffix) in [" ", "? ", "\r"].enumerated() {
                let fixture = Fixture(prefix: row.0, store: store, local: local)
                fixture.type(row.1)
                if suffix == "\r" { fixture.key("\r", code: 36) }
                else { fixture.type(suffix) }
                try await fixture.wait()
                outputs["case\(index)-\(ending)"] = fixture.view.string
                guard !fixture.view.hasMarkedText() else { throw LocalDecisionError(detail: "Marked text remained") }
                if suffix == " " {
                    fixture.key("", code: 51); fixture.key("", code: 51)
                    outputs["delete\(index)"] = fixture.view.string
                }
            }
        }
        let corrected = Fixture(prefix: "나는 설거지부터 ", store: store, local: local)
        corrected.type("go? "); try await corrected.wait()
        _ = try corrected.session.prepareFeedback()
        try await corrected.session.applyFeedback(preferred: "해", scope: .context)
        guard corrected.view.string == "나는 설거지부터 해? " else { throw LocalDecisionError(detail: "F8 correction lost punctuation") }
        outputs["F8"] = corrected.view.string
        let restarted = LocalDecisionClient(runtime: runtime, personalURL: personal)
        _ = try await restarted.prepare()
        let replay = Fixture(prefix: "나는 설거지부터 ", store: store, local: restarted)
        replay.type("go "); try await replay.wait()
        guard replay.view.string == "나는 설거지부터 해 " else { throw LocalDecisionError(detail: "Correction restart failed") }
        outputs["restart"] = replay.view.string
        let other = Fixture(prefix: "If the tests pass, we can ", store: store, local: restarted)
        other.type("go "); try await other.wait()
        guard other.view.string == "If the tests pass, we can go " else { throw LocalDecisionError(detail: "Correction leaked into another context") }
        outputs["otherContext"] = other.view.string

        try check(try revision(personal) == seededRevision + 1,
                  "F8 did not update \(personal.lastPathComponent) exactly once")
        if let otherData {
            try check(try Data(contentsOf: kept) == otherData, "Another model's personal file changed")
            try check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(PersonalState.legacyName).path),
                      "Legacy file was not renamed")
        }
        try JSONEncoder().encode(outputs).write(to: URL(fileURLWithPath: arguments[3]))
        print("PASS \(outputs.count) AppKit CompositionSession checks with personal state case '\(arguments[2])': \(personal.lastPathComponent) (\(selection.origin)), revision \(seededRevision)→\(seededRevision + 1), other-model files kept: \(selection.otherModelFiles.map(\.lastPathComponent))")
    }
}

import AppKit
import HannyeongCore

/// Terminal returns the former marked-text start immediately after insertText.
/// Keep Terminal running for the input queue’s host lookup; text editing uses the native fixture.
@main
private struct TerminalShortcutQA {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let runtime = try JSONDecoder().decode(LocalRuntimeConfiguration.self,
                    from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
                try await run(runtime)
                print("PASS Terminal commit coordinates: pending and Space, reversal/restore, Korean notice and caret protection")
                exit(0)
            } catch {
                fputs("Terminal shortcut QA failed: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor private static func run(_ runtime: LocalRuntimeConfiguration) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults(suiteName: folder.lastPathComponent)!
        defer { defaults.removePersistentDomain(forName: folder.lastPathComponent) }
        let local = LocalDecisionClient(runtime: runtime, personalURL: folder.appendingPathComponent("personal.json"))
        for space in [false, true] {
            let store = CorrectionStore(url: folder.appendingPathComponent("\(space).json"))
            try store.record(raw: "terminal", before: "", rejected: "", preferred: "terminal", scope: .always)
            let view = NativeTextView(frame: .zero)
            view.string = "prefix "
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            let client = NativeInputClient()
            client.view = view
            let sessionErrors = NSMutableArray()
            let session = CompositionSession(client: client, corrections: store, localClient: local,
                previewDefaults: defaults, hostBundleID: "com.apple.Terminal") { sessionErrors.add($0) }
            for char in "terminal" { _ = session.handle(key(String(char))) }
            client.reportsCompositionStartAfterCommit = true
            if space {
                _ = session.handle(key(" ", code: 49))
                client.reportsCompositionStartAfterCommit = false
            }
            session.toggleLanguage()
            try require(sessionErrors.count == 0, "Right Command failed: \(sessionErrors)")
            let suffix = space ? " " : ""
            let korean = try HangulComposer.compose("terminal")
            try require(view.string == "prefix " + (space ? korean : "terminal") + suffix,
                        "Reversal changed the prefix or selected the wrong language")
            client.reportsCompositionStartAfterCommit = false
            session.toggleLanguage()
            try require(view.string == "prefix " + (space ? "terminal" : korean) + suffix,
                        "Second tap did not restore the previous reading")
            view.setSelectedRange(NSRange(location: 0, length: 0))
            let before = view.string
            session.toggleLanguage()
            try require(view.string == before && sessionErrors as! [String] == ["방금 입력한 단어를 바꾸지 못했습니다. 입력 위치를 확인해 주세요."],
                        "Moved caret was edited or its Korean notice was not shown")
            await session.finishLearning()
            try require(sessionErrors.count == 1, "Personal update failed: \(sessionErrors)")
        }
    }

    private static func key(_ text: String, code: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)!
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw LocalDecisionError(detail: message) }
    }
}
